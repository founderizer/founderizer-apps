import Darwin
import Foundation
import Testing
@testable import FleetVaultCore

/// Synthetic values only: the saved value of the test login, and the key of the test agent.
private let secret = "SYNTHETIC-KEY-0123456789", agentKey = "SYNTHETIC-AGENT-KEY"
private let generation = "test-generation"
/// An address of this machine that no test connects to.
private let nowhere = "http://127.0.0.1:9"

/// True when the condition came in at most `seconds`.
private func wait(_ seconds: Double = 5, until condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !condition() { if Date() > end { return false }; usleep(2_000) }
    return true
}

/// One request of a test: the hub's fields, and what the curl child gets for a login whose address is `origin`.
private struct Request {
    let call: VaultCall
    let plan: VaultCall.Plan

    init(to origin: String = nowhere, method: String = "GET", path: String = "/v1/things", body: String? = nil,
         id: String = UUID().uuidString, attempt: Int = 2, db: String = generation, limit: Int = 3) throws {
        var fields: [String: Any] = ["request_id": id, "db": db, "attempt": attempt, "method": method, "path": path, "auth": "bearer"]
        fields["body"] = body
        call = try VaultCall(fields: fields)
        let value = try JSONSerialization.data(withJSONObject: ["username": "api-user", "password": secret, "url": origin])
        plan = try call.plan(for: VaultLogin(data: value, label: "Synthetic API"), limit: limit, plain: { $0 == "127.0.0.1" })
    }

    func scope(agent: String = "studio", task: String = "T-7", key: String = agentKey) throws -> VaultCallScope {
        try #require(VaultCallScope(db: call.db, task: task, attempt: call.attempt, caller: VaultCaller(agent: agent, key: key)))
    }
}

/// The result of work on a thread of its own.
private final class Later<Value: Sendable>: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private var result: Value?
    init(_ work: @escaping @Sendable () -> Value) {
        Thread.detachNewThread { self.result = work(); self.done.signal() }
    }
    /// The result, or nil when the work did not end in time.
    func value(in seconds: Double = 5) -> Value? {
        guard done.wait(timeout: .now() + seconds) == .success else { return nil }
        done.signal()
        return result
    }
}

/// A value that a test changes while other code reads it.
private final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var kept: Value
    init(_ value: Value) { kept = value }
    var value: Value {
        get { lock.withLock { kept } }
        set { lock.withLock { kept = newValue } }
    }
    func change(_ body: (inout Value) -> Void) { lock.withLock { body(&kept) } }
}

/// A journal that cannot be read.
private struct ClosedStore: VaultJournalStore {
    func load(limit: Int) throws -> Data? { throw VaultFailure.keychain }
    func save(_ data: Data) throws { throw VaultFailure.keychain }
}

/// Starts a program of the system for a test. It gets the given descriptors and no other one of the test process,
/// and no signal is blocked or ignored in it: a thread of the test can have every signal blocked, and a new process
/// keeps that. `group`: an existing process group that it joins.
private func launch(_ arguments: [String], environment: [String] = [], group: pid_t? = nil,
                    descriptors: [(child: Int32, parent: Int32)] = []) throws -> pid_t {
    var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
    posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
    defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
    for pair in descriptors { posix_spawn_file_actions_adddup2(&actions, pair.parent, pair.child) }
    var flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
    var defaults = sigset_t(), unblocked = sigset_t()
    sigfillset(&defaults); sigemptyset(&unblocked)
    posix_spawnattr_setsigdefault(&attributes, &defaults); posix_spawnattr_setsigmask(&attributes, &unblocked)
    if let group { flags |= POSIX_SPAWN_SETPGROUP; posix_spawnattr_setpgroup(&attributes, group) }
    posix_spawnattr_setflags(&attributes, Int16(flags))
    var argv = arguments.map { strdup($0) } + [nil], env = environment.map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) }; env.forEach { free($0) } }
    var pid: pid_t = 0
    guard posix_spawn(&pid, arguments[0], &actions, &attributes, &argv, &env) == 0 else { throw POSIXError(.ENOEXEC) }
    return pid
}

/// A process of the test that does nothing (`/bin/sleep`). The test takes its status one time, also when it fails.
private final class Sleeper {
    let pid: pid_t
    let start: Int
    private var status: Int32?
    init(group: pid_t? = nil) throws {
        pid = try launch(["/bin/sleep", "30"], group: group)
        start = VaultProcess.start(of: pid) ?? 0
    }
    deinit { _ = end() }
    /// Sends `signal`, if any, and waits for the end. The signal that ended the process, or 0 for an exit.
    @discardableResult func end(with signal: Int32? = SIGKILL) -> Int32 {
        if let status { return status & 0x7f }
        if let signal { kill(pid, signal) }
        var taken: Int32 = 0
        while waitpid(pid, &taken, 0) < 0 && errno == EINTR {}
        status = taken
        return taken & 0x7f
    }
}

/// What a program of the system writes to its standard output.
private func output(of program: String, _ arguments: String...) throws -> String {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: program); process.arguments = arguments
    process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// The descriptors of a process and the kind of each (1: a file, 2: a socket, 6: a pipe).
private func descriptors(of pid: pid_t) -> [Int32: UInt32] {
    let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard size > 0 else { return [:] }
    var list = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
    let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &list, size)
    return Dictionary(list.prefix(max(0, Int(used)) / MemoryLayout<proc_fdinfo>.stride).map { ($0.proc_fd, $0.proc_fdtype) }) { first, _ in first }
}

/// The parent of a process, as the system shows it.
private func parent(of pid: pid_t) -> pid_t? {
    var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
    var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info.kp_eproc.e_ppid
}

/// The records of the journal in a store, as the vault wrote them.
private func records(in store: FakeKeychainJournal) throws -> [[String: Any]] {
    let data = try #require(store.data)
    let journal = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(journal["v"] as? Int == 1)
    return try #require(journal["calls"] as? [[String: Any]])
}

/// A journal as an earlier vault process left it.
private func journal(_ calls: [[String: Any]]) throws -> Data { try JSONSerialization.data(withJSONObject: ["v": 1, "calls": calls]) }

private func identity(_ number: Int) -> String { String(format: "00000000-0000-4000-8000-%012d", number) }

/// One record of a journal for the test agent and its task attempt, with or without a process.
private func record(_ number: Int, child: (pid: pid_t, start: Int)? = nil) -> [String: Any] {
    var record: [String: Any] = ["request_id": identity(number), "agent": "studio", "db": generation, "job": number, "task": "T-7", "attempt": 2]
    if let child { record["child"] = ["pid": Int(child.pid), "start": child.start] }
    return record
}

private extension VaultCalls {
    /// `begin` for a new child, as the broker does it: a child that gets no record is abandoned.
    func start(_ request: Request, _ scope: VaultCallScope, job: Int = 31) throws -> (word: String, entry: Running?) {
        let child = try VaultCurl.start(withBody: request.plan.body != nil)
        switch begin(job: job, call: request.call, scope: scope, child: child) {
        case .started(let entry): return ("started", entry)
        case .stopped: child.abandon(); return ("stopped", nil)
        case .repeated: child.abandon(); return ("repeated", nil)
        case .unsaved: child.abandon(); return ("unsaved", nil)
        }
    }

    /// The request path of the broker after the release: the request on a thread of its own, then `end`.
    func send(_ entry: Running, _ plan: VaultCall.Plan, limit: Int = 30) -> Later<(result: VaultCurl.Result, canceled: Bool)> {
        Later {
            let result = entry.child.run(plan, keep: 1000, limit: limit)
            return (result, self.end(entry))
        }
    }
}

@Suite struct VaultCallsTests {
    private static let empty = LocalService.response(body: Data(#"{"ok":true}"#.utf8))

    // MARK: The child and its pipes

    @Test func theChildWaitsWithNothingToSendUntilItGetsItsRequest() throws {
        let service = try LocalService(.answer(Self.empty))
        defer { service.stop() }
        let request = try Request(to: service.origin)
        let child = try VaultCurl.start(withBody: false)
        #expect(VaultProcess.start(of: child.pid) == child.start && getpgid(child.pid) == child.pid)
        // It has opened its config, which is one more descriptor on the same pipe, and it waits there. It has its
        // standard input (a file: no body comes), its three pipes, and no descriptor of this process: the socket of
        // the service is not there.
        #expect(wait { descriptors(of: child.pid) == [0: 1, 1: 6, 2: 6, 3: 6, 4: 6] })
        #expect(service.received.isEmpty && VaultProcess.start(of: child.pid) == child.start)
        let result = child.run(request.plan, keep: 100, limit: 3)
        #expect(result.exit == 0 && result.note == Data("fleet 200\n".utf8) && result.kept == Data(#"{"ok":true}"#.utf8) && result.total == 11)
        #expect(service.waitForMessages(1))
        let parts = LocalService.parts(of: try #require(service.received.first))
        #expect(parts.lines.first == "GET /v1/things HTTP/1.1" && parts.body.isEmpty)
        #expect(parts.lines.contains("Authorization: Bearer " + secret) && parts.lines.contains("Host: 127.0.0.1:\(service.port)"))
        // The vault has the status of the child: no process has its pid.
        #expect(VaultProcess.state(of: child.pid) == .absent)
        #expect(kill(child.pid, 0) == -1 && errno == ESRCH)
        // Only the first call sends.
        let again = child.run(request.plan, keep: 100, limit: 3)
        #expect(again.status == result.status && again.total == 0 && again.note.isEmpty)
        child.abandon(); child.stop()

        // A child that gets no request: it sent nothing, and no process is left.
        let other = try VaultCurl.start(withBody: true)
        #expect(wait { descriptors(of: other.pid) == [0: 6, 1: 6, 2: 6, 3: 6, 4: 6] })
        other.abandon()
        #expect(VaultProcess.state(of: other.pid) == .absent)
        #expect(kill(other.pid, 0) == -1 && errno == ESRCH)
        let late = other.run(request.plan, keep: 100, limit: 3)
        #expect(late.total == 0 && late.note.isEmpty)
        // A plan with a body is not for a child that reads none: nothing goes to it.
        let mismatch = try VaultCurl.start(withBody: false).run(try Request(to: service.origin, method: "POST", body: "{}").plan, keep: 100, limit: 3)
        #expect(mismatch.exit == 2 && mismatch.total == 0)
        // A child that is dropped without `run` or `abandon` is ended too.
        var dropped: VaultCurl? = try VaultCurl.start(withBody: false)
        let pid = try #require(dropped?.pid)
        dropped = nil
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        #expect(service.received.count == 1)
    }

    @Test func theLiveChildHasTheFixedArgumentsAndNoValueInThemOrInItsEnvironment() throws {
        let service = try LocalService(.silent)
        defer { service.stop() }
        let request = try Request(to: service.origin, limit: 30)
        let child = try VaultCurl.start(withBody: false)
        let transfer = Later { child.run(request.plan, keep: 100, limit: 30) }
        defer { child.stop() }
        // The request is at the service, with the value. The child waits for the answer.
        #expect(service.waitForMessages(1))
        #expect(String(decoding: try #require(service.received.first), as: UTF8.self).contains("Authorization: Bearer " + secret))
        #expect(VaultCurl.program == "/usr/bin/curl" && VaultCurl.arguments == ["-q", "--config", "/dev/fd/3"])
        let command = try output(of: "/bin/ps", "-ww", "-o", "command=", "-p", "\(child.pid)")
        #expect(command == "/usr/bin/curl -q --config /dev/fd/3")
        // With `e`, ps adds the environment where the system shows it. This system shows it to the administrator only.
        let all = try output(of: "/bin/ps", "eww", "-p", "\(child.pid)")
        #expect(all.contains("/usr/bin/curl -q --config /dev/fd/3"))
        for text in [secret, "SYNTHETIC", "Bearer", "127.0.0.1", "things"] { #expect(!command.contains(text) && !all.contains(text)) }
        child.stop()
        let result = try #require(transfer.value())
        #expect(result.exit == nil && result.status & 0x7f == SIGKILL && result.note.isEmpty && result.total == 0)
    }

    @Test func theChildHasTheFixedEnvironmentAndNoVariableOfTheVault() throws {
        let service = try LocalService(.answer(Self.empty))
        defer { service.stop() }
        // This process has variables that the child must not get, and another search path than the child's.
        let own = ProcessInfo.processInfo.environment
        #expect(own["HOME"] != nil && own["USER"] != nil && own["PATH"] != "/usr/bin:/bin")
        #expect(VaultCurl.environment == ["PATH=/usr/bin:/bin", "LANG=en_US.UTF-8"])
        // curl itself says what its environment has: these config lines put four of its variables into a header,
        // or `none` for a variable that it does not have.
        let probe = ["PATH", "LANG", "HOME", "USER"].map { "variable = \"%\($0)=none\"\n" }.joined()
            + "expand-header = \"X-Environment: {{PATH}} {{LANG}} {{HOME}} {{USER}}\"\n"
        let config = String(decoding: try Request(to: service.origin).plan.config, as: UTF8.self)
        let address = try #require(config.range(of: "url = "))
        let probed = String(config[..<address.lowerBound]) + probe + String(config[address.lowerBound...])
        let plan = VaultCall.Plan(lead: nil, body: nil, config: Data(probed.utf8), forms: [])
        #expect(try VaultCurl.start(withBody: false).run(plan, keep: 100, limit: 3).exit == 0)
        let lines = LocalService.parts(of: try #require(service.received.first)).lines
        #expect(lines.contains("X-Environment: /usr/bin:/bin en_US.UTF-8 none none"))
    }

    @Test func aBodyArrivesCompleteAndALongAnswerIsCountedAndKeptOnlyToItsLimit() throws {
        // A body of the greatest size, with a text that shows a part that is lost or moved.
        let body = (0..<VaultCall.maxBody / 8).map { String(format: "%07d,", $0) }.joined()
        #expect(body.utf8.count == 65_536)
        let answer = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 / 251) })
        let service = try LocalService(.answer(LocalService.response(body: answer)))
        defer { service.stop() }
        let request = try Request(to: service.origin, method: "POST", body: body)
        let result = try VaultCurl.start(withBody: true).run(request.plan, keep: 1000, limit: 3)
        #expect(result.exit == 0 && result.note == Data("fleet 200\n".utf8))
        #expect(result.total == 300_000 && result.kept == answer.prefix(1000))
        let parts = LocalService.parts(of: try #require(service.received.first))
        #expect(parts.body == Data(body.utf8))
        #expect(parts.lines.first == "POST /v1/things HTTP/1.1" && parts.lines.contains("Content-Length: 65536"))
        #expect(parts.lines.contains("Content-Type: application/json") && parts.lines.contains("Authorization: Bearer " + secret))
        // Nothing is kept, and all of a short answer is kept.
        let none = try VaultCurl.start(withBody: false).run(try Request(to: service.origin).plan, keep: 0, limit: 3)
        #expect(none.exit == 0 && none.total == 300_000 && none.kept.isEmpty)
        let whole = try VaultCurl.start(withBody: false).run(try Request(to: service.origin).plan, keep: 400_000, limit: 3)
        #expect(whole.exit == 0 && whole.total == 300_000 && whole.kept == answer)
        #expect(service.received.count == 3)
    }

    @Test func aConfigThatIsCutShortSendsNothingOrTheCompleteRequest() throws {
        for body in [nil, String(repeating: #"{"n":1234567890}"#, count: 200)] {
            let service = try LocalService(.answer(Self.empty))
            defer { service.stop() }
            let request = try Request(to: service.origin, method: body == nil ? "GET" : "POST", body: body)
            let config = request.plan.config
            // The complete request, as the service gets it.
            let whole = try VaultCurl.start(withBody: body != nil).run(request.plan, keep: 100, limit: 3)
            #expect(whole.exit == 0 && service.waitForMessages(1))
            let complete = try #require(service.received.first)
            #expect(LocalService.parts(of: complete).body == Data((body ?? "").utf8))
            #expect(String(decoding: complete, as: UTF8.self).contains("Authorization: Bearer " + secret))
            // Every cut inside the last two lines (the address, and the line that permits a protocol), each line
            // end, no config at all, and three places inside each other line.
            let ends = config.indices.filter { config[$0] == 10 }.map { $0 + 1 }
            #expect(ends.count >= 12 && ends.last == config.count)
            let address = ends[ends.count - 3], last = ends[ends.count - 2]
            #expect(String(decoding: config[address..<last], as: UTF8.self) == "url = \"\(service.origin)/v1/things\"\n")
            var places = Set(address...config.count).union(ends).union([0])
            var from = 0
            for end in ends.dropLast(2) { places.formUnion([from + 1, (from + end) / 2, end - 2].filter { $0 > from && $0 < end }); from = end }
            let cuts = places.sorted()
            #expect(cuts.count > 80)
            let outcomes = Box((sent: [Int](), exits: Set<Int32>(), odd: [Int]()))
            DispatchQueue.concurrentPerform(iterations: cuts.count) { index in
                let plan = VaultCall.Plan(lead: request.plan.lead, body: request.plan.body, config: Data(config.prefix(cuts[index])), forms: [])
                let result = (try? VaultCurl.start(withBody: body != nil))?.run(plan, keep: 100, limit: 3)
                outcomes.change { all in
                    if result?.exit == 0, result?.note == Data("fleet 200\n".utf8) { all.sent.append(cuts[index]) }
                    else if let result, let exit = result.exit, exit != 0, VaultAnswer.status(in: result.note) == nil { all.exits.insert(exit) }
                    else { all.odd.append(cuts[index]) }
                }
            }
            let (sent, exits, odd) = outcomes.value
            // Each child ended in one of two ways: curl sent and got the answer, or curl ended before any connection
            // (no protocol permitted, no address, or a line that it cannot read).
            #expect(odd.isEmpty)
            #expect(exits.isSubset(of: [1, 2, 3, 26]))
            // Only a cut inside the last line sends, and the complete config sends, also without its last line end.
            #expect(sent.allSatisfy { $0 > last } && sent.contains(config.count) && sent.contains(config.count - 1))
            #expect(sent.count <= 4)
            // One more request, which is the last message of all: the service then has every message that came. It
            // has one complete request for each cut that sent, and nothing else.
            let final = try VaultCurl.start(withBody: false).run(try Request(to: service.origin, path: "/v1/last").plan, keep: 100, limit: 3)
            #expect(final.exit == 0)
            func isFinal(_ message: Data) -> Bool { String(decoding: message.prefix(13), as: UTF8.self) == "GET /v1/last " }
            #expect(wait { service.received.contains(where: isFinal) })
            let messages = service.received.filter { !isFinal($0) }
            #expect(messages.count == sent.count + 1 && messages.allSatisfy { $0 == complete })
        }
    }

    @Test func stopEndsTheGroupOfABlockedChildAtOnceAndSignalsNobodyAfterItsStatusIsTaken() throws {
        let silent = try LocalService(.silent)
        defer { silent.stop() }
        let blocked = try VaultCurl.start(withBody: false)
        // A second process in the child's group, as a process that the child started would be.
        let member = try Sleeper(group: blocked.pid)
        #expect(getpgid(member.pid) == blocked.pid)
        let request = try Request(to: silent.origin, limit: 30)
        let transfer = Later { blocked.run(request.plan, keep: 100, limit: 30) }
        #expect(silent.waitForMessages(1))
        let began = Date()
        blocked.stop()
        let result = try #require(transfer.value())
        #expect(Date().timeIntervalSince(began) < 2)                        // not after the 30 seconds of the transfer
        #expect(result.exit == nil && result.status & 0x7f == SIGKILL && result.note.isEmpty && result.total == 0)
        #expect(member.end(with: nil) == SIGKILL)                           // the whole group got the signal
        #expect(VaultProcess.state(of: blocked.pid) == .absent)
        #expect(kill(blocked.pid, 0) == -1 && errno == ESRCH)

        // After the vault took the status, the number of the child can be another process's. Here the group of the
        // child still exists, because a process of the test is in it: a signal to it would end that process.
        let service = try LocalService(.answer(Self.empty))
        defer { service.stop() }
        let finished = try VaultCurl.start(withBody: false)
        let bystander = try Sleeper(group: finished.pid)
        #expect(finished.run(try Request(to: service.origin).plan, keep: 100, limit: 3).exit == 0)
        #expect(getpgid(bystander.pid) == finished.pid && kill(finished.pid, 0) == -1)
        finished.stop(); finished.abandon(); finished.stop()
        // The first signal that it gets is the one of the test.
        #expect(bystander.end(with: SIGTERM) == SIGTERM)
    }

    @Test func aChildThatDoesNotEndInItsTimeIsEnded() throws {
        let service = try LocalService(.silent)
        defer { service.stop() }
        // curl ends by itself at its time limit: exit status 28, after the service got the request.
        let short = try Request(to: service.origin, limit: 1)
        let timed = Later { (try? VaultCurl.start(withBody: false))?.run(short.plan, keep: 100, limit: 1) }
        // A child with a longer limit than the vault's own: the vault ends it 10 seconds after its limit (here: 1 second).
        let long = try Request(to: service.origin, limit: 30)
        let began = Date()
        let late = try VaultCurl.start(withBody: false).run(long.plan, keep: 100, limit: -9)
        #expect(late.exit == nil && late.status & 0x7f == SIGKILL)
        #expect((0.9...4).contains(Date().timeIntervalSince(began)))
        let result = try #require(timed.value() ?? nil)
        #expect(result.exit == 28 && VaultAnswer.status(in: result.note) == nil)
        #expect(service.received.count == 2)
    }

    @Test func aServiceThatIsNotFoundOrNotReachedGivesTheExitStatusOfCurl() throws {
        let refused = try VaultCurl.start(withBody: false).run(try Request(to: "http://127.0.0.1:\(LocalService.closedPort())").plan, keep: 100, limit: 3)
        #expect(refused.exit == 7 && refused.total == 0 && VaultAnswer.status(in: refused.note) == nil)
        // A name with a label of 64 characters: no resolver can ask for it, so no network is used.
        let unknown = try VaultCurl.start(withBody: false).run(try Request(to: "https://" + String(repeating: "a", count: 64) + ".test").plan, keep: 100, limit: 3)
        #expect(unknown.exit == 6 && unknown.total == 0 && VaultAnswer.status(in: unknown.note) == nil)
    }

    @Test func aWriteToAChildThatEndedGivesNoSignalAndSendsNothing() throws {
        let service = try LocalService(.answer(Self.empty))
        defer { service.stop() }
        // More than a pipe holds, so the write cannot end before the child reads.
        let request = try Request(to: service.origin, method: "POST", body: String(repeating: "x", count: VaultCall.maxBody))
        let child = try VaultCurl.start(withBody: true)
        child.stop()
        #expect(wait { VaultProcess.state(of: child.pid) == .absent })
        let result = child.run(request.plan, keep: 100, limit: 3)
        #expect(result.exit == nil && result.status & 0x7f == SIGKILL && result.total == 0 && result.note.isEmpty)
        #expect(service.received.isEmpty)
    }

    // MARK: The descriptors of the vault

    /// The name of the variable that makes this test run its second part, in a process of its own.
    private static let again = "FLEET_VAULT_TEST_DESCRIPTORS"
    /// The test runs again only with the test program of the Swift package manager, which this run then has.
    private static var canRunAgain: Bool {
        CommandLine.arguments.contains("--test-bundle-path") || ProcessInfo.processInfo.environment[again] != nil
    }

    /// The system gives the lowest free descriptor to a file that opens, and in the vault that can be 0 to 3: the
    /// numbers that the child gets its pipes on. A test cannot free them in the process that runs all tests, so this
    /// test runs again in a process of its own: one time with the descriptors 0 to 2 open, and one time without.
    @Test(.enabled(if: canRunAgain)) func aRequestWorksWhenTheLowestDescriptorsOfTheVaultAreFree() throws {
        if let report = ProcessInfo.processInfo.environment[Self.again].flatMap({ Int32($0) }) { return try Self.requestsOnLowDescriptors(report: report) }
        let arguments = CommandLine.arguments
        let bundle = arguments[try #require(arguments.firstIndex(of: "--test-bundle-path")) + 1]
        let run = [arguments[0], "--test-bundle-path", bundle, "--filter", "VaultCallsTests/aRequestWorksWhenTheLowestDescriptorsOfTheVaultAreFree",
                   bundle, "--testing-library", "swift-testing"]
        // Descriptors of 10 or more, so that none is a number that the new process gets.
        func high(_ fd: Int32) -> Int32 { let copy = fcntl(fd, F_DUPFD_CLOEXEC, 10); close(fd); return copy }
        for (standard, expected) in [(true, "3 ok\n"), (false, "3 ok\n2 ok\n1 ok\n0 ok\n")] {
            var raw: [Int32] = [-1, -1]
            try #require(pipe(&raw) == 0)
            let report = (read: high(raw[0]), write: high(raw[1]))
            let null = (read: high(open("/dev/null", O_RDONLY)), write: high(open("/dev/null", O_WRONLY)))
            var descriptors = [(child: Int32(9), parent: report.write)]
            if standard { descriptors += [(0, null.read), (1, null.write), (2, null.write)] }
            let environment = ProcessInfo.processInfo.environment.map { $0.key + "=" + $0.value } + [Self.again + "=9"]
            let pid = try launch(run, environment: environment, descriptors: descriptors)
            for fd in [report.write, null.read, null.write] { close(fd) }
            // The report ends when the process ends. A process that does not end in time is ended.
            var text = Data(), buffer = [UInt8](repeating: 0, count: 4096), source = pollfd(fd: report.read, events: Int16(POLLIN), revents: 0)
            let end = Date().addingTimeInterval(30)
            while true {
                guard poll(&source, 1, Int32(max(0, end.timeIntervalSinceNow) * 1000)) > 0 else { if errno == EINTR { continue }; break }
                let count = read(report.read, &buffer, buffer.count)
                if count <= 0 { break }
                text.append(contentsOf: buffer[..<count])
            }
            close(report.read)
            if Date() >= end { kill(pid, SIGKILL) }
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            #expect(String(decoding: text, as: UTF8.self) == expected, "with the descriptors 0 to 2 \(standard ? "open" : "closed")")
            #expect(status == 0, "with the descriptors 0 to 2 \(standard ? "open" : "closed")")
        }
    }

    /// The second part, in its own process. For each of the descriptors 0 to 3 that is free there: a request without
    /// a body and one with a body, each started when that descriptor is the next one that the system gives. One line
    /// of the report for each descriptor.
    private static func requestsOnLowDescriptors(report: Int32) throws {
        var low: [Int32] = []
        while true {
            let fd = open("/dev/null", O_RDONLY | O_CLOEXEC)
            guard (0...3).contains(fd) else { close(fd); break }
            low.append(fd)
        }
        // The service comes after: its own descriptors are above 3.
        let service = try LocalService(.answer(empty))
        defer { service.stop() }
        var sent = 0
        for descriptor in low.reversed() {
            close(descriptor)
            var line = "\(descriptor)"
            for body in [nil, #"{"n":1}"#] {
                let free = wait { let next = open("/dev/null", O_RDONLY | O_CLOEXEC); close(next); return next == descriptor }
                let request = try Request(to: service.origin, method: body == nil ? "GET" : "POST", body: body)
                let child = try VaultCurl.start(withBody: body != nil)
                let result = child.run(request.plan, keep: 100, limit: 3)
                sent += 1
                let arrived = service.waitForMessages(sent, seconds: 2) && LocalService.parts(of: service.received[sent - 1]).body == Data((body ?? "").utf8)
                let good = free && result.exit == 0 && result.note == Data("fleet 200\n".utf8) && result.kept == Data(#"{"ok":true}"#.utf8) && arrived
                #expect(good)
                line += good ? "" : " failed (\(body == nil ? "no body" : "body"): free \(free), status \(result.status), note \(String(decoding: result.note, as: UTF8.self)), arrived \(arrived))"
            }
            line += line.contains("failed") ? "\n" : " ok\n"
            _ = line.withCString { Darwin.write(report, $0, strlen($0)) }
        }
    }

    // MARK: The start time of a process

    @Test func theStartTimeNamesAProcessUntilItEnds() throws {
        let process = try Sleeper(), other = try Sleeper()
        let start = try #require(VaultProcess.start(of: process.pid))
        #expect(VaultProcess.state(of: process.pid) == .running(start: start) && process.start == start)
        // In microseconds: it is a time of the last minute, and another process has another one.
        #expect((0..<60_000_000).contains(Int(Date().timeIntervalSince1970 * 1_000_000) - start))
        #expect(VaultProcess.start(of: other.pid) != start && VaultProcess.start(of: getpid()) != nil)
        // A process of another user (the system's first one) has an answer too.
        guard case .running(let first) = VaultProcess.state(of: 1) else { Issue.record("no answer for the first process"); return }
        #expect(first > 0 && first < start)
        // The same answer for as long as the process runs.
        #expect(VaultProcess.start(of: process.pid) == start)
        // Ended, and its parent has not taken the status: the system still has the pid, but nothing runs.
        kill(process.pid, SIGKILL)
        var info = siginfo_t()
        #expect(waitid(P_PID, id_t(process.pid), &info, WEXITED | WNOWAIT) == 0)
        #expect(kill(process.pid, 0) == 0)
        #expect(VaultProcess.state(of: process.pid) == .absent && VaultProcess.start(of: process.pid) == nil)
        // After its status is taken, and for a number that is no pid.
        #expect(process.end(with: nil) == SIGKILL)
        #expect(kill(process.pid, 0) == -1 && errno == ESRCH)
        #expect(VaultProcess.state(of: process.pid) == .absent && VaultProcess.start(of: process.pid) == nil)
        #expect(VaultProcess.state(of: -1) == .absent && VaultProcess.start(of: 2_000_000_000) == nil)
    }

    // MARK: The journal

    @Test func theJournalHasARequestAndItsProcessBeforeTheChildGetsAnything() throws {
        let service = try LocalService(.answer(Self.empty))
        defer { service.stop() }
        let store = FakeKeychainJournal(), calls = VaultCalls(store: store)
        let request = try Request(to: service.origin), scope = try request.scope()
        let child = try VaultCurl.start(withBody: false)
        guard case .started(let entry) = calls.begin(job: 31, call: request.call, scope: scope, child: child) else {
            Issue.record("the request did not start"); child.abandon(); return
        }
        // The record is in the store, with the exact process. The child still has nothing.
        let written: NSArray = [["request_id": request.call.requestID, "agent": "studio", "db": generation, "job": 31, "task": "T-7", "attempt": 2,
                                 "child": ["pid": Int(child.pid), "start": child.start]]]
        #expect(try records(in: store) as NSArray == written)
        #expect(service.received.isEmpty && VaultProcess.start(of: child.pid) == child.start)
        // The journal has no value, no key, no hash of a key and no address.
        let text = String(decoding: try #require(store.data), as: UTF8.self)
        for value in [secret, agentKey, scope.key, "things", "127.0.0.1"] { #expect(!text.contains(value)) }
        #expect(calls.release(entry))
        let result = child.run(request.plan, keep: 100, limit: 3)
        #expect(result.exit == 0 && service.received.count == 1)
        // After the end: the identity stays, and the process is not in the record.
        #expect(!calls.end(entry))
        let kept: NSArray = [["request_id": request.call.requestID, "agent": "studio", "db": generation, "job": 31, "task": "T-7", "attempt": 2]]
        #expect(try records(in: store) as NSArray == kept)
        #expect(!calls.release(entry) && !calls.end(entry))
        // The identity is the generation, the agent and the request: it never starts again, also under another job,
        // task, attempt or key, and also in a new vault process on the same journal.
        let later = try Request(to: service.origin, id: request.call.requestID, attempt: 3)
        for vault in [calls, VaultCalls(store: store)] {
            #expect(try vault.start(request, scope).word == "repeated")
            #expect(try vault.start(later, later.scope(task: "T-8", key: "ANOTHER-SYNTHETIC-KEY"), job: 32).word == "repeated")
        }
        #expect(try records(in: store) as NSArray == kept)
        // The same request number of another agent, or in another generation, is another request.
        let vault = VaultCalls(store: store)
        let foreign = try vault.start(request, request.scope(agent: "seo"))
        let elsewhere = try Request(to: service.origin, id: request.call.requestID, db: "other-generation")
        let moved = try vault.start(elsewhere, elsewhere.scope())
        #expect(foreign.word == "started" && moved.word == "started")
        #expect(try records(in: store).count == 3)
        for entry in [foreign.entry, moved.entry].compactMap({ $0 }) { vault.end(entry) }
        #expect(try records(in: store).allSatisfy { $0["child"] == nil })
        #expect(service.received.count == 1)
    }

    @Test func aRequestWithoutItsRecordInTheJournalGetsNothing() throws {
        let service = try LocalService(.answer(Self.empty))
        defer { service.stop() }
        let request = try Request(to: service.origin), scope = try request.scope()
        // A store that does not keep the record.
        let store = FakeKeychainJournal()
        store.fails = true
        let calls = VaultCalls(store: store)
        #expect(try calls.start(request, scope).word == "unsaved")
        #expect(try store.data == nil && calls.recover() && calls.cancel(Request(attempt: 9).scope()) == 0)
        // Nothing was recorded, so the request can start when the store works again.
        store.fails = false
        let started = try calls.start(request, scope)
        #expect(try started.word == "started" && records(in: store).count == 1)
        calls.end(try #require(started.entry))
        // A journal that the vault cannot use: no JSON, another version, a record without its fields, and a process
        // that cannot be a child of the vault. Its bytes stay as they are, and no process gets a signal.
        func child(_ pid: Int) -> String {
            #"{"v":1,"calls":[{"request_id":"\#(identity(1))","agent":"studio","db":"test-generation","job":1,"task":"T-7","attempt":2,"child":{"pid":\#(pid),"start":1}}]}"#
        }
        for content in ["", "not json", #"{"v":2,"calls":[]}"#, #"{"v":1,"calls":[{"request_id":"x"}]}"#, #"{"calls":[]}"#, child(1), child(0), child(-1)] {
            let store = FakeKeychainJournal()
            store.data = Data(content.utf8)
            let calls = VaultCalls(store: store)
            #expect(!calls.recover(), "\(content)")
            #expect(try calls.start(request, scope).word == "unsaved" && calls.cancel(scope) == nil && calls.isStopped(scope))
            #expect(store.data == Data(content.utf8))
        }
        // A journal that cannot be read at all.
        let closed = VaultCalls(store: ClosedStore())
        #expect(try !closed.recover() && closed.start(request, scope).word == "unsaved" && closed.cancel(scope) == nil)
        #expect(service.received.isEmpty)
    }

    @Test func aFullJournalDropsOnlyTheOldestFinishedIdentities() throws {
        // What an earlier vault process left: 255 finished requests.
        let store = FakeKeychainJournal()
        store.data = try journal((1...255).map { record($0) })
        let calls = VaultCalls(store: store)
        func request(_ number: Int) throws -> Request { try Request(id: identity(number)) }
        let scope = try request(0).scope()
        // One request that runs all the time, and three that end.
        let running = try #require(try calls.start(request(1000), scope).entry)
        for number in 1001...1003 { calls.end(try #require(try calls.start(request(number), scope).entry)) }
        let kept = try records(in: store)
        // The two oldest finished identities went. The newest 256 finished ones stay, and so does the record with a process.
        #expect(kept.compactMap { $0["request_id"] as? String } == (Array(3...255) + Array(1000...1003)).map(identity))
        #expect(kept.filter { $0["child"] == nil }.count == VaultCalls.kept && kept.count == VaultCalls.kept + 1)
        #expect((kept[253]["child"] as? [String: Any])?["pid"] as? Int == Int(running.child.pid))
        // A known identity does not start again. One that the journal dropped is new to the vault.
        for number in [3, 255, 1000, 1003] { #expect(try calls.start(request(number), scope).word == "repeated") }
        let dropped = try calls.start(request(1), scope)
        #expect(dropped.word == "started")
        calls.end(try #require(dropped.entry))
        calls.end(running)
        let last = try records(in: store)
        #expect(last.count == VaultCalls.kept + 1 && last.allSatisfy { $0["child"] == nil })
        #expect(last.first?["request_id"] as? String == identity(4) && last.last?["request_id"] as? String == identity(1))
    }

    // MARK: Cancel

    @Test func aCancelEndsARequestThatTheServiceHasAndProvesIt() throws {
        let service = try LocalService(.silent)
        defer { service.stop() }
        let store = FakeKeychainJournal(), calls = VaultCalls(store: store)
        let request = try Request(to: service.origin, limit: 30), scope = try request.scope()
        let entry = try #require(try calls.start(request, scope).entry)
        #expect(calls.release(entry))
        let sent = calls.send(entry, request.plan)
        #expect(service.waitForMessages(1))                                 // the request is at the service
        let pid = entry.child.pid
        #expect(VaultProcess.start(of: pid) == entry.child.start)
        #expect(calls.cancel(scope) == 1)
        // The proof is there when the cancel answers: the vault took the status, so no process has that pid.
        #expect(VaultProcess.start(of: pid) == nil)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        #expect(try records(in: store).count == 1 && records(in: store).first?["child"] == nil)
        let outcome = try #require(sent.value())
        #expect(outcome.canceled && outcome.result.exit == nil && outcome.result.status & 0x7f == SIGKILL)
        // The cancel again finds nothing. The request is known, and no other request of the task attempt starts.
        #expect(calls.cancel(scope) == 0 && calls.isStopped(scope))
        #expect(try calls.start(request, scope).word == "repeated")
        #expect(try calls.start(Request(to: service.origin), scope).word == "stopped")
        #expect(try service.received.count == 1 && records(in: store).count == 1)
    }

    @Test func aCancelBeforeARequestStopsItsTaskAttemptOnly() throws {
        let service = try LocalService(.answer(Self.empty))
        defer { service.stop() }
        let store = FakeKeychainJournal(), calls = VaultCalls(store: store)
        let request = try Request(to: service.origin), scope = try request.scope()
        #expect(!calls.isStopped(scope))
        #expect(calls.cancel(scope) == 0)                                   // nothing runs: nothing to end
        #expect(calls.isStopped(scope))
        #expect(try calls.start(request, scope).word == "stopped")
        #expect(store.data == nil && service.received.isEmpty)              // no record, and no request
        // Another attempt of the same task, another task, another agent, another generation and another key are not stopped.
        let next = try Request(to: service.origin, attempt: 3), moved = try Request(to: service.origin, db: "other-generation")
        let others = [try next.scope(), try request.scope(task: "T-8"), try request.scope(agent: "seo"), try moved.scope(),
                      try request.scope(key: "ANOTHER-SYNTHETIC-KEY")]
        #expect(others.allSatisfy { !calls.isStopped($0) })
        let started = try calls.start(next, others[0])
        #expect(started.word == "started")
        let entry = try #require(started.entry)
        #expect(calls.release(entry))
        #expect(entry.child.run(next.plan, keep: 100, limit: 3).exit == 0 && !calls.end(entry))
        #expect(service.received.count == 1)
        // The newest 1024 stopped scopes stay. A scope that comes again is new.
        for attempt in 100..<(100 + VaultCalls.stoppedKept - 1) { #expect(calls.cancel(try Request(attempt: attempt).scope()) == 0) }
        #expect(calls.isStopped(scope) && calls.cancel(scope) == 0)
        for attempt in 2000..<(2000 + VaultCalls.stoppedKept - 1) { #expect(calls.cancel(try Request(attempt: attempt).scope()) == 0) }
        #expect(calls.isStopped(scope))
        #expect(calls.cancel(try Request(attempt: 5000).scope()) == 0 && !calls.isStopped(scope))
    }

    @Test func aCancelBetweenTheRecordAndTheReleaseSendsNothing() throws {
        let service = try LocalService(.answer(Self.empty))
        defer { service.stop() }
        let store = FakeKeychainJournal(), calls = VaultCalls(store: store)
        let request = try Request(to: service.origin), scope = try request.scope()
        let entry = try #require(try calls.start(request, scope).entry)
        let pid = entry.child.pid
        // The cancel names the request, ends its child, and waits for the request path.
        let cancel = Later { calls.cancel(scope) }
        #expect(wait { calls.isStopped(scope) })
        #expect(!calls.release(entry))
        entry.child.abandon()
        #expect(calls.end(entry))
        #expect(cancel.value() == 1)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        #expect(try records(in: store).count == 1 && records(in: store).first?["child"] == nil)
        // The child never had a config: it could send nothing.
        #expect(service.received.isEmpty)
    }

    @Test func aCancelEndsOnlyTheRequestsOfItsOwnScope() throws {
        let service = try LocalService(.silent)
        defer { service.stop() }
        let store = FakeKeychainJournal(), calls = VaultCalls(store: store)
        let request = try Request(to: service.origin, limit: 30), scope = try request.scope()
        let entry = try #require(try calls.start(request, scope).entry)
        #expect(calls.release(entry))
        let sent = calls.send(entry, request.plan)
        #expect(service.waitForMessages(1))
        // Another key for the same task attempt: that caller does not end the request, and it gets no proof.
        #expect(calls.cancel(try request.scope(key: "ANOTHER-SYNTHETIC-KEY")) == nil)
        // Another agent, task, attempt and generation: nothing of theirs runs.
        #expect(calls.cancel(try request.scope(agent: "seo")) == 0)
        #expect(calls.cancel(try request.scope(task: "T-8")) == 0)
        #expect(calls.cancel(try Request(attempt: 3).scope()) == 0)
        #expect(calls.cancel(try Request(db: "other-generation").scope()) == 0)
        // No cancel named the request, its record has its process, and the process runs.
        #expect(calls.release(entry) && !calls.isStopped(scope))
        #expect(((try records(in: store)).first?["child"] as? [String: Any])?["pid"] as? Int == Int(entry.child.pid))
        #expect(VaultProcess.start(of: entry.child.pid) == entry.child.start && service.received.count == 1)
        // The caller of the request ends it.
        #expect(calls.cancel(scope) == 1)
        #expect(sent.value()?.canceled == true && VaultProcess.start(of: entry.child.pid) == nil)
        // Now the other key gets its answer too: no process of the task attempt is left.
        #expect(calls.cancel(try request.scope(key: "ANOTHER-SYNTHETIC-KEY")) == 0)
    }

    @Test func aTimeThatRanOutIsNoProof() throws {
        let service = try LocalService(.answer(Self.empty))
        defer { service.stop() }
        let store = FakeKeychainJournal(), calls = VaultCalls(store: store, patience: 0.2)
        let request = try Request(to: service.origin), scope = try request.scope()
        let entry = try #require(try calls.start(request, scope).entry)
        // The request path does not come, so nobody takes the status of the child. The child got the signal, but
        // the vault does not say that it is gone, and the record keeps its process.
        #expect(calls.cancel(scope) == nil)
        #expect(try records(in: store).first?["child"] != nil)
        #expect(calls.cancel(scope) == nil && !calls.release(entry))
        // The request path takes the status: now it is proved.
        #expect(calls.end(entry))
        #expect(calls.cancel(scope) == 0)
        #expect(try records(in: store).first?["child"] == nil)
        #expect(kill(entry.child.pid, 0) == -1 && service.received.isEmpty)
    }

    // MARK: What an earlier vault process left

    @Test func aNewVaultProcessEndsTheChildrenThatAnEarlierOneLeft() throws {
        let service = try LocalService(.silent)
        defer { service.stop() }
        let store = FakeKeychainJournal(), early = VaultCalls(store: store)
        // The earlier vault process has one child that waits for its request, and one whose request is at the service.
        let waiting = try Request(to: service.origin, limit: 30), sent = try Request(to: service.origin, limit: 30)
        let scope = try waiting.scope()
        let first = try #require(try early.start(waiting, scope).entry), second = try #require(try early.start(sent, scope).entry)
        let transfer = Later { second.child.run(sent.plan, keep: 100, limit: 30) }
        #expect(service.waitForMessages(1))
        #expect(try records(in: store).allSatisfy { $0["child"] != nil })
        // That process ends here: nothing of it acts any more. A new vault process reads the same journal.
        let calls = VaultCalls(store: store)
        #expect(calls.recover())
        for child in [first.child, second.child] { #expect(VaultProcess.start(of: child.pid) == nil) }
        #expect(try records(in: store).count == 2 && records(in: store).allSatisfy { $0["child"] == nil })
        // The identities stay: nothing is sent again. The task attempt has no process left.
        #expect(try calls.start(waiting, scope).word == "repeated")
        #expect(try calls.start(sent, scope).word == "repeated")
        #expect(calls.cancel(scope) == 0)
        // The children are children of the test process, so the test takes their status.
        let result = try #require(transfer.value())
        #expect(result.exit == nil && result.status & 0x7f == SIGKILL)
        first.child.abandon()
        #expect(service.received.count == 1)
    }

    @Test func aNewVaultProcessEndsOnlyTheExactProcessOfARecord() throws {
        // A process whose parent ended, as the child of a vault process that ended is.
        let orphan = try #require(pid_t(try output(of: "/bin/sh", "-c", "/bin/sleep 30 >/dev/null 2>&1 & echo $!")))
        let start = try #require(VaultProcess.start(of: orphan))
        defer { if VaultProcess.start(of: orphan) == start { kill(orphan, SIGKILL) } }
        #expect(wait { parent(of: orphan) == 1 })
        // A process that runs, in a record with its pid and another start time. The test process, in the same way.
        let bystander = try Sleeper()
        // A pid that no process has: the process ended, and its status was taken.
        let ended = try Sleeper()
        ended.end()
        let store = FakeKeychainJournal()
        store.data = try journal([record(1, child: (orphan, start)), record(2, child: (bystander.pid, bystander.start + 1)),
                                  record(3, child: (getpid(), 1)), record(4, child: (ended.pid, ended.start)), record(5)])
        let calls = VaultCalls(store: store)
        #expect(calls.recover())
        // The exact process is ended. The system's first process takes its status.
        #expect(VaultProcess.start(of: orphan) == nil)
        #expect(wait { kill(orphan, 0) == -1 })
        // No record has a process now, and each identity stays.
        let kept = try records(in: store)
        #expect(kept.compactMap { $0["request_id"] as? String } == (1...5).map(identity) && kept.allSatisfy { $0["child"] == nil })
        let scope = try Request().scope()
        for number in 1...5 { #expect(try calls.start(Request(id: identity(number)), scope).word == "repeated") }
        #expect(calls.cancel(scope) == 0)
        // The process with another start time got no signal: the first one that it gets is the one of the test.
        #expect(VaultProcess.start(of: bystander.pid) == bystander.start)
        #expect(bystander.end(with: SIGTERM) == SIGTERM)
    }

    @Test func aProcessOfAnEarlierVaultThatIsNotProvedGoneKeepsItsRecord() throws {
        // The pid of a process that ended and whose status was taken: a signal to it reaches nobody. What the system
        // says about that pid is the test's own answer here.
        let sleeper = try Sleeper()
        sleeper.end()
        let ended = (pid: sleeper.pid, start: sleeper.start), answer = Box(VaultProcess.State.unknown)
        let store = FakeKeychainJournal()
        store.data = try journal([record(1, child: ended)])
        let calls = VaultCalls(store: store, patience: 0.1) { pid in pid == ended.pid ? answer.value : .absent }
        let request = try Request(id: identity(1)), scope = try request.scope()
        func process() throws -> Int? { ((try records(in: store)).first?["child"] as? [String: Any])?["pid"] as? Int }
        // The system gives no answer: that proves nothing. The journal is read, and the record keeps its process.
        #expect(calls.recover())
        #expect(try process() == Int(ended.pid))
        #expect(calls.cancel(scope) == nil)
        #expect(try calls.start(request, scope).word == "repeated")
        // The exact process still runs after its signal: no proof, also after the time of the wait.
        answer.value = .running(start: ended.start)
        #expect(calls.recover() && calls.cancel(scope) == nil)
        #expect(try process() == Int(ended.pid))
        // A cancel of another task attempt does not wait for it and is not held by it.
        #expect(calls.cancel(try Request(attempt: 3).scope()) == 0)
        // A request of another attempt starts and ends, and the record stays through the saves.
        let other = try Request(attempt: 3, limit: 1)
        let started = try calls.start(other, try other.scope(task: "T-9"))
        #expect(started.word == "started")
        calls.end(try #require(started.entry))
        #expect(try records(in: store).count == 2 && process() == Int(ended.pid))
        // The system shows that the process is gone: now the record loses it.
        answer.value = .absent
        #expect(calls.cancel(scope) == 0)
        #expect(try process() == nil)
    }
}
