import Darwin
import Foundation
import Testing
@testable import FleetOwnerAPI

/// A stand-in check of the other side: it takes every peer, or none.
struct StandInCheck: PeerCheck {
    let takes: Bool
    func accepts(socket: Int32) -> Bool { takes }
}

/// What a test's handler was asked, from the listener's own tasks.
final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [OwnerChannel.Request] = []
    func add(_ request: OwnerChannel.Request) { lock.lock(); list.append(request); lock.unlock() }
    var all: [OwnerChannel.Request] { lock.lock(); defer { lock.unlock() }; return list }
}

/// **The link's wire, its listener on a real socket, and its client**: in a folder of the test's own under the temporary
/// folder, with a stand-in check of the peer (and once the real check, against this test process itself). Each test
/// stops its listener and removes its folder.
final class OwnerChannelTests {
    let folder: URL
    let path: String

    init() {
        // Short: a local socket's path takes at most 104 bytes.
        folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fzl-\(UUID().uuidString.prefix(8))", isDirectory: true)
        path = folder.appendingPathComponent("app.sock").path
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    private func listener(takes: Bool = true, openMax: Int = OwnerChannel.openMax, asked: Asked = Asked(),
                          answer: @escaping @Sendable (OwnerChannel.Request) -> OwnerChannel.Answer = {
                              .result(.object(["tool": .string($0.tool)]))
                          }) -> ChannelListener {
        ChannelListener(path: path, check: StandInCheck(takes: takes), openMax: openMax) { request in
            asked.add(request)
            return answer(request)
        }
    }

    private func exchange(_ tool: String = "setup_state", takes: Bool = true) -> ChannelClient.Reach {
        ChannelClient.exchange(path: path, request: OwnerChannel.Request(set: "owner", tool: tool),
                               check: StandInCheck(takes: takes))
    }

    /// A raw client: connected, with nothing sent.
    private func raw() throws -> Int32 {
        let socket = OwnerChannel.newSocket()
        try #require(socket >= 0)
        try #require(OwnerChannel.connect(socket, to: path) == 0)
        return socket
    }

    /// Everything that the app wrote to a raw client until it closed.
    private func readAll(_ socket: Int32) -> String {
        var data = Data(), chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(socket, &chunk, chunk.count)
            guard count > 0 else { break }
            data.append(contentsOf: chunk[0..<count])
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Waits for the listener's count of open connections, by a count of looks (an event of its own queue each).
    private func open(_ listener: ChannelListener, becomes count: Int) -> Bool {
        for _ in 0..<500 {
            if listener.openCount == count { return true }
            usleep(10_000)
        }
        return listener.openCount == count
    }

    // ------------------------------------------------------------ the wire

    @Test func aRequestIsOneLineWithItsVersionAndItsSet() throws {
        let request = OwnerChannel.Request(set: "owner", tool: "setup_show",
                                           fields: ["page": .string("vps"), "seen": .string("a\nb")])
        let line = request.line
        #expect(line.last == 10 && line.dropLast().firstIndex(of: 10) == nil)
        let read = try OwnerChannel.Request.read(Data(line.dropLast())).get()
        #expect(read == request)
        #expect(JSONValue.parse(Data(line.dropLast()))?["v"] == .int(1))
        #expect(JSONValue.parse(Data(line.dropLast()))?["set"] == .string("owner"))
    }

    @Test func aRequestOfAnotherVersionOrShapeIsRefusedInWords() {
        func refused(_ text: String) -> String? {
            if case .failure(let refusal) = OwnerChannel.Request.read(Data(text.utf8)) { return refusal.text }
            return nil
        }
        #expect(refused(#"{"v": 2, "set": "owner", "tool": "setup_state"}"#)?.contains("different versions") == true)
        #expect(refused(#"{"set": "owner", "tool": "setup_state"}"#)?.contains("different versions") == true)
        #expect(refused("no json")?.hasPrefix("The app could not read this request") == true)
        #expect(refused(#"{"v": 1, "tool": "setup_state"}"#)?.contains("names no set") == true)
        #expect(refused(#"{"v": 1, "set": "owner", "tool": "setup_state", "fields": [1]}"#)
                == "The fields of setup_state must be one JSON object.")
        #expect(refused(#"{"v": 1, "set": "owner", "tool": "setup_state"}"#) == nil)
    }

    @Test func anAnswerIsAResultOrARefusalOfThisVersion() {
        for answer in [OwnerChannel.Answer.result(.object(["change": .int(3)])), .refused("no")] {
            let line = answer.line
            #expect(line.last == 10)
            #expect(OwnerChannel.Answer.read(Data(line.dropLast())) == answer)
        }
        #expect(OwnerChannel.Answer.read(Data(#"{"v": 2, "result": {}}"#.utf8)) == nil)
        #expect(OwnerChannel.Answer.read(Data(#"{"v": 1, "result": {}, "refused": "x"}"#.utf8)) == nil)
        #expect(OwnerChannel.Answer.read(Data(#"{"v": 1}"#.utf8)) == nil)
    }

    @Test func thePlaceIsTheAppsFolderAndALongOneIsRefusedInWords() {
        #expect(OwnerChannel.place(home: "/Users/someone")
                == "/Users/someone/Library/Application Support/Founderizer/app.sock")
        #expect(OwnerChannel.place(home: "/Users/someone/") == OwnerChannel.place(home: "/Users/someone"))
        // A user name of 40 letters still fits; one of 50 does not.
        #expect(OwnerChannel.tooLong(OwnerChannel.place(home: "/Users/" + String(repeating: "a", count: 40))) == nil)
        let long = OwnerChannel.place(home: "/Users/" + String(repeating: "a", count: 50))
        #expect(OwnerChannel.tooLong(long)?.contains("at most 99") == true)
        let tooLong = ChannelListener(path: long, check: StandInCheck(takes: true)) { _ in .refused("no") }
        guard case .cannot(let words) = tooLong.start() else { Issue.record("a long place listened"); return }
        #expect(words.contains("bytes long"))
        guard case .failed = ChannelClient.exchange(path: long, request: .init(set: "owner", tool: "x"),
                                                    check: StandInCheck(takes: true)) else {
            Issue.record("the program reached a long place")
            return
        }
    }

    // ------------------------------------------------------------ a real socket

    @Test func aPeerThatPassesGetsTheAnswerAndTheSocketIsTheUsersAlone() throws {
        let asked = Asked()
        let link = listener(asked: asked)
        defer { link.stop() }
        #expect(link.start() == .listening)
        #expect(exchange() == .answer(.result(.object(["tool": .string("setup_state")]))))
        #expect(asked.all.map(\.tool) == ["setup_state"] && asked.all.first?.set == "owner")
        var info = stat()
        #expect(stat(path, &info) == 0 && info.st_mode & 0o777 == 0o600 && info.st_mode & S_IFMT == S_IFSOCK)
        #expect(stat(folder.path, &info) == 0 && info.st_mode & 0o777 == 0o700)
        #expect(open(link, becomes: 0))
    }

    @Test func aPeerThatFailsTheCheckGetsOneRefusalLineAndNothingIsDone() throws {
        let asked = Asked()
        let link = listener(takes: false, asked: asked)
        defer { link.stop() }
        #expect(link.start() == .listening)
        #expect(exchange() == .answer(OwnerChannel.notOurs))
        // A raw client that sends its whole request still gets the one line, then the end.
        let socket = try raw()
        defer { close(socket) }
        let line = OwnerChannel.Request(set: "owner", tool: "setup_show").line
        _ = line.withUnsafeBytes { write(socket, $0.baseAddress, $0.count) }
        #expect(readAll(socket) == String(decoding: OwnerChannel.notOurs.line, as: UTF8.self))
        #expect(asked.all.isEmpty)
    }

    @Test func theProgramSendsNothingToAnAppThatFailsItsCheck() {
        let asked = Asked()
        let link = listener(asked: asked)
        defer { link.stop() }
        #expect(link.start() == .listening)
        #expect(exchange(takes: false) == .notTheApp)
        #expect(open(link, becomes: 0))
        #expect(asked.all.isEmpty)
    }

    @Test func nothingListensWhenNoAppRuns() {
        #expect(exchange() == .nothingListens)
    }

    @Test func aRequestTheAppCannotReadIsRefusedAndNotHandled() throws {
        let asked = Asked()
        let link = listener(asked: asked)
        defer { link.stop() }
        #expect(link.start() == .listening)
        let socket = try raw()
        defer { close(socket) }
        let bad = Data(#"{"v": 9, "set": "owner", "tool": "setup_state"}"#.utf8 + [10])
        _ = bad.withUnsafeBytes { write(socket, $0.baseAddress, $0.count) }
        #expect(readAll(socket).contains("different versions"))
        #expect(asked.all.isEmpty)
    }

    // ------------------------------------------------------------ bad clients

    /// A client that sends nothing holds one place, and the link still answers others.
    @Test func aSilentClientHoldsOnePlaceAndTheLinkStillAnswers() throws {
        let link = listener()
        defer { link.stop() }
        #expect(link.start() == .listening)
        let silent = try raw()
        defer { close(silent) }
        #expect(open(link, becomes: 1))
        #expect(exchange() == .answer(.result(.object(["tool": .string("setup_state")]))))
        #expect(open(link, becomes: 1))
    }

    /// One connection more than the bound ends the oldest: silent clients never hold the link for ever.
    @Test func oneMoreThanTheBoundEndsTheOldest() throws {
        let link = listener(openMax: 3)
        defer { link.stop() }
        #expect(link.start() == .listening)
        var sockets: [Int32] = []
        defer { sockets.forEach { close($0) } }
        for _ in 0..<5 { sockets.append(try raw()) }
        #expect(open(link, becomes: 3))
        // The two oldest were ended: each reads its end at once.
        #expect(readAll(sockets[0]).isEmpty && readAll(sockets[1]).isEmpty)
        #expect(exchange() == .answer(.result(.object(["tool": .string("setup_state")]))))
    }

    @Test func halfALineThenTheEndDoesNothing() throws {
        let asked = Asked()
        let link = listener(asked: asked)
        defer { link.stop() }
        #expect(link.start() == .listening)
        let socket = try raw()
        let half = Data(#"{"v": 1, "set": "owner", "tool": "setup_sh"#.utf8)
        _ = half.withUnsafeBytes { write(socket, $0.baseAddress, $0.count) }
        #expect(open(link, becomes: 1))
        close(socket)
        #expect(open(link, becomes: 0))
        #expect(asked.all.isEmpty)
    }

    /// 10 MB with no line end: refused after `requestMax`, and the app never holds the rest.
    @Test func aLineLongerThanTheBoundIsRefused() throws {
        let asked = Asked()
        let link = listener(asked: asked)
        defer { link.stop() }
        #expect(link.start() == .listening)
        let socket = try raw()
        defer { close(socket) }
        let sender = Thread {
            let block = Data(repeating: UInt8(ascii: "a"), count: 64 * 1024)
            for _ in 0..<160 {                           // 10 MB, until the app closes
                let sent = block.withUnsafeBytes { write(socket, $0.baseAddress, $0.count) }
                if sent <= 0 { break }
            }
        }
        sender.start()
        #expect(readAll(socket).contains("longer than the \(OwnerChannel.requestMax) bytes"))
        #expect(open(link, becomes: 0))
        #expect(asked.all.isEmpty)
    }

    /// A client that never reads its answer: the answer that does not fit waits, and the connection ends by the count.
    @Test func aClientThatNeverReadsEndsByTheCount() throws {
        let big = String(repeating: "b", count: 4 * 1024 * 1024)
        let link = listener(openMax: 2) { $0.tool == "big" ? .result(.string(big)) : .result(.object([:])) }
        defer { link.stop() }
        #expect(link.start() == .listening)
        let socket = try raw()
        defer { close(socket) }
        let line = OwnerChannel.Request(set: "owner", tool: "big").line
        _ = line.withUnsafeBytes { write(socket, $0.baseAddress, $0.count) }
        #expect(open(link, becomes: 1))
        #expect(exchange("small") == .answer(.result(.object([:]))))
        let other = try raw()
        defer { close(other) }
        let third = try raw()
        defer { close(third) }
        #expect(open(link, becomes: 2))
        #expect(exchange("small") == .answer(.result(.object([:]))))
    }

    // ------------------------------------------------------------ one listener for one user

    @Test func aSecondCopyFindsTheFirstAndDoesNotTakeItsPlace() {
        let first = listener()
        defer { first.stop() }
        #expect(first.start() == .listening)
        let second = listener()
        #expect(second.start() == .anotherListens)
        #expect(exchange() == .answer(.result(.object(["tool": .string("setup_state")]))))
    }

    /// **A copy that started while another one listens takes the link when that one ends** (a user's report of 15
    /// November 2026: after the app's own restart for an update, nobody listened). The second copy's wait has no clock:
    /// it ends when the first one's lock is free, and then the second one answers.
    @Test(.timeLimit(.minutes(1))) func aCopyThatStartedBesideAnotherTakesTheLinkWhenThatOneEnds() async {
        let first = listener()
        #expect(first.start() == .listening)
        let second = listener()
        defer { second.stop() }
        #expect(second.start() == .anotherListens)
        // The wait blocks its thread, so it has one of its own, and this test waits for its end with no pool thread held.
        let waited = Task.detached { () -> ChannelListener.Start in
            await withCheckedContinuation { resume in
                Thread.detachNewThread { resume.resume(returning: second.startWhenFree()) }
            }
        }
        // While the first copy lives, the second one does not listen, and the first one answers.
        try? await Task.sleep(for: .milliseconds(300))
        #expect(second.openCount == 0)
        #expect(exchange() == .answer(.result(.object(["tool": .string("setup_state")]))))
        let ended = ContinuousClock.now
        first.stop()
        #expect(await waited.value == .listening)
        // By the lock, not by the pause for a copy that holds no lock: well under `otherPause`.
        #expect(ContinuousClock.now - ended < .milliseconds(1500))
        #expect(exchange() == .answer(.result(.object(["tool": .string("setup_state")]))))
    }

    /// **The wait for the lock ends when its holder gives it back, and not before**: it has no clock of its own.
    @Test(.timeLimit(.minutes(1))) func theWaitForTheLockEndsWhenItsHolderEnds() async {
        let holder = listener()
        #expect(holder.start() == .listening)
        #expect(OwnerChannel.lockHeld(path))
        let place = path
        let waited = Task.detached { () -> ContinuousClock.Instant in
            await withCheckedContinuation { resume in
                Thread.detachNewThread {
                    OwnerChannel.waitForLock(place)
                    resume.resume(returning: ContinuousClock.now)
                }
            }
        }
        try? await Task.sleep(for: .milliseconds(400))
        let ended = ContinuousClock.now
        holder.stop()
        let returned = await waited.value
        #expect(returned >= ended)                              // not before the holder gave the lock back
        #expect(returned - ended < .milliseconds(1500))         // and at once after it
        // With nobody on the lock, and with no lock file at all, it returns at once.
        OwnerChannel.waitForLock(path)
        OwnerChannel.waitForLock(path + ".none")
    }

    /// With nobody on the link, `startWhenFree` is `start`.
    @Test func aCopyThatStartsAloneListensAtOnce() {
        let link = listener()
        defer { link.stop() }
        #expect(link.startWhenFree() == .listening)
        #expect(exchange() == .answer(.result(.object(["tool": .string("setup_state")]))))
    }

    @Test func aSocketThatNothingListensOnIsReplaced() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A crash: the socket file stays, and nothing listens on it.
        let dead = OwnerChannel.newSocket()
        var address = OwnerChannel.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(dead, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        close(dead)
        #expect(bound == 0 && FileManager.default.fileExists(atPath: path))
        #expect(!OwnerChannel.answers(path))
        let link = listener()
        defer { link.stop() }
        #expect(link.start() == .listening)
        #expect(exchange() == .answer(.result(.object(["tool": .string("setup_state")]))))
    }

    @Test func aFileThatIsNoSocketIsNeverReplaced() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: URL(fileURLWithPath: path))
        let link = listener()
        guard case .cannot(let words) = link.start() else { Issue.record("it listened"); return }
        #expect(words.contains("no socket"))
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "keep")
    }

    @Test func aStoppedListenerLeavesThePlaceToTheNext() {
        let first = listener()
        #expect(first.start() == .listening)
        first.stop()
        let next = listener()
        defer { next.stop() }
        #expect(next.start() == .listening)
    }

    // ------------------------------------------------------------ the real check, against this process

    /// **The check by code signature, from the socket's peer**: this test process is the peer of its own connection, so
    /// a requirement of its own code directory hash and its own path takes it, and one of another hash or another path
    /// does not. (The check of a release build, a Developer ID of the team, needs a signed build: not here.)
    @Test func theSignatureCheckReadsThePeerFromTheSocket() throws {
        let own = try #require(SignatureCheck.own())                 // the test runner is signed, ad hoc at least
        let asked = Asked()
        let link = ChannelListener(path: path, check: SignatureCheck(requirement: "cdhash H\"\(own.hash)\"",
                                                                     path: own.path)) { request in
            asked.add(request)
            return .result(.object([:]))
        }
        defer { link.stop() }
        #expect(link.start() == .listening)
        #expect(exchange() == .answer(.result(.object([:]))))
        let otherHash = String(repeating: "0", count: own.hash.count)
        for check in [SignatureCheck(requirement: "cdhash H\"\(otherHash)\"", path: own.path),
                      SignatureCheck(requirement: "cdhash H\"\(own.hash)\"", path: "/usr/bin/true")] {
            let reach = ChannelClient.exchange(path: path, request: .init(set: "owner", tool: "x"), check: check)
            #expect(reach == .notTheApp)
        }
        #expect(asked.all.count == 1)
        // A peer of a test build is the exact program of this own bundle: the same check from a path.
        let made = SignatureCheck.of(identifier: "com.founderizer.cli", expected: URL(fileURLWithPath: own.path))
        if SignatureCheck.ownSigning().team == nil {
            #expect(made == SignatureCheck(requirement: "cdhash H\"\(own.hash)\"", path: own.path))
        }
    }
}

extension OwnerChannelTests {
    /// **R1: an app's main executable, not its bundle's folder.** A small bundle, signed ad hoc in a folder of the test's
    /// own: its code's main executable is the program inside it, and that file and the bundle have one code directory
    /// hash, so the test build's check of its own app compares the right path.
    @Test func theMainExecutableOfABundleIsTheProgramInsideIt() throws {
        let bundle = folder.appendingPathComponent("Example.app", isDirectory: true)
        let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let executable = macOS.appendingPathComponent("Example")
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: executable.path)
        let plist: [String: Any] = ["CFBundleExecutable": "Example", "CFBundleIdentifier": "com.example.check",
                                    "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", bundle.path]
        sign.standardOutput = FileHandle.nullDevice
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        try #require(sign.terminationStatus == 0)
        var code: SecStaticCode?
        try #require(SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess)
        let made = try #require(code)
        let real = try #require(ProgramPlace.realPath(executable.path))
        #expect(SignatureCheck.mainExecutable(of: made) == real)
        let hash = try #require(SignatureCheck.codeDirectoryHash(of: real))
        #expect(SignatureCheck.codeDirectoryHash(of: bundle.path) == hash)
        var url: CFURL?
        _ = SecCodeCopyPath(made, [], &url)
        #expect((url as URL?).flatMap { ProgramPlace.realPath($0.path) } != real)       // the fault of round 1
    }

    /// **T3: the release requirement compiles**, for a made-up team and identifier; a team or an identifier with a quote,
    /// a space or nothing gives no check at all.
    @Test func theReleaseRequirementCompilesAndRefusesOddWords() throws {
        let text = try #require(SignatureCheck.requirement(team: "EXAMPLE123", identifier: "com.example.cli"))
        var made: SecRequirement?
        #expect(SecRequirementCreateWithString(text as CFString, [], &made) == errSecSuccess && made != nil)
        #expect(text.hasPrefix(SignatureCheck.developerID))
        #expect(text.hasSuffix(#" and certificate leaf[subject.OU] = "EXAMPLE123" and identifier "com.example.cli""#))
        for (team, identifier) in [("EXA\"MPLE", "com.example.cli"), ("EXAMPLE 1", "com.example.cli"),
                                   ("EXAMPLE123", "com.example\" or true"), ("EXAMPLE123", "com example"),
                                   ("", "com.example.cli"), ("EXAMPLE123", "")] {
            #expect(SignatureCheck.requirement(team: team, identifier: identifier) == nil, "\(team) \(identifier)")
        }
    }

    /// **S5: the identifiers are the program's own constants**, held to the app's `Info.plist` and to the scripts that
    /// sign the program.
    @Test func theIdentifiersAreTheAppsOwn() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: app.appendingPathComponent("Info.plist")), format: nil) as? [String: Any]
        #expect(plist?["CFBundleIdentifier"] as? String == OwnerChannel.appIdentifier)
        for script in ["release.sh", "run.sh"] {
            let text = try String(contentsOf: app.appendingPathComponent(script), encoding: .utf8)
            #expect(text.contains("--identifier \(OwnerChannel.programIdentifier)"), "\(script)")
        }
    }

    /// **S3: a full queue is not "the app does not run"**: with the lock held by a running copy and no connection
    /// taken, the program reads busy; with no lock held, nothing listens.
    @Test func aHeldLockWithNoConnectionIsBusy() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lock = Darwin.open(OwnerChannel.lockPath(path), O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        try #require(lock >= 0)
        defer { close(lock) }
        try #require(flock(lock, LOCK_EX | LOCK_NB) == 0)
        // No socket file: nothing listens, whatever holds the lock, and the program does not look at it (round 3, P1).
        #expect(exchange() == .nothingListens)
        // A socket file that refuses, with the lock held: busy.
        let dead = OwnerChannel.newSocket()
        var address = OwnerChannel.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(dead, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        close(dead)
        try #require(bound == 0)
        #expect(exchange() == .busy)
        _ = flock(lock, LOCK_UN)
        #expect(exchange() == .nothingListens)                  // the same file with no lock held: a crash
    }

    /// **P1: a lock that another process takes for moments does not keep the app from listening.** While a thread takes
    /// and frees a shared lock in a loop, as a program that looks during the app's start, the listener still starts.
    @Test func aLockTakenForMomentsDoesNotStopTheListener() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lockPath = OwnerChannel.lockPath(path)
        let file = Darwin.open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        try #require(file >= 0)
        try #require(flock(file, LOCK_SH | LOCK_NB) == 0)       // taken at the moment the listener starts
        let stop = Asked()
        let looker = Thread {
            var first = true
            while stop.all.isEmpty {
                if first { first = false } else { _ = flock(file, LOCK_SH) }
                usleep(1_000)
                _ = flock(file, LOCK_UN)
                usleep(1_000)
            }
            close(file)
        }
        looker.start()
        let link = listener()
        defer { link.stop() }
        let started = link.start()
        stop.add(.init(set: "", tool: "stop"))
        #expect(started == .listening)
        #expect(exchange() == .answer(.result(.object(["tool": .string("setup_state")]))))
    }

    /// **P2: with no descriptor left, the pause ends the oldest connection**, so that a connection that never ends by
    /// itself cannot hold the accepting for ever.
    @Test func thePauseForNoDescriptorEndsTheOldest() throws {
        let link = listener()
        defer { link.stop() }
        #expect(link.start() == .listening)
        let silent = try raw()
        defer { close(silent) }
        #expect(open(link, becomes: 1))
        link.queue.sync { link.pauseAccepting() }
        #expect(readAll(silent).isEmpty)                         // ended: its end reads at once
        #expect(open(link, becomes: 0))
        #expect(exchange() == .answer(.result(.object(["tool": .string("setup_state")]))))
    }

    /// **S6: the program's read has a bound of its own**: an app that took the call and never answers ends the read
    /// after its count of quiet reads, in words.
    @Test func theProgramEndsItsReadAfterItsBound() {
        let link = ChannelListener(path: path, check: StandInCheck(takes: true)) { _ in
            try? await Task.sleep(for: .seconds(20))            // cancelled by the stop below
            return .result(.object([:]))
        }
        defer { link.stop() }
        #expect(link.start() == .listening)
        let reach = ChannelClient.exchange(path: path, request: .init(set: "owner", tool: "setup_state"),
                                           check: StandInCheck(takes: true), quietReads: 3,
                                           readWait: timeval(tv_sec: 0, tv_usec: 50_000))
        #expect(reach == .failed(ChannelClient.noAnswer))
        #expect(ChannelClient.quietReads == 60)
    }

    /// **S2: a client that goes after its line ends its work**: the listener sees the close, cancels the task that
    /// makes the answer, and frees the place.
    @Test func aClientThatGoesAfterItsLineEndsItsWork() throws {
        let cancelled = Asked()
        let link = ChannelListener(path: path, check: StandInCheck(takes: true)) { request in
            try? await Task.sleep(for: .seconds(20))
            if Task.isCancelled { cancelled.add(request) }
            return .result(.object([:]))
        }
        defer { link.stop() }
        #expect(link.start() == .listening)
        let socket = try raw()
        let line = OwnerChannel.Request(set: "owner", tool: "setup_state").line
        _ = line.withUnsafeBytes { write(socket, $0.baseAddress, $0.count) }
        #expect(open(link, becomes: 1))
        close(socket)
        #expect(open(link, becomes: 0))
        for _ in 0..<500 where cancelled.all.isEmpty { usleep(10_000) }      // the patience of open(_:becomes:)
        #expect(cancelled.all.map(\.tool) == ["setup_state"])
    }

    /// **S7: a request line is read to `requestMax` and no further**: a line of exactly that size is taken, one byte
    /// more with no line end is refused.
    @Test func theRequestBoundIsExact() throws {
        let asked = Asked()
        let link = ChannelListener(path: path, check: StandInCheck(takes: true), requestMax: 120) { request in
            asked.add(request)
            return .result(.object([:]))
        }
        defer { link.stop() }
        #expect(link.start() == .listening)
        var line = OwnerChannel.Request(set: "owner", tool: "setup_state").line.dropLast()
        let pad = 120 - line.count
        line = Data(OwnerChannel.Request(set: "owner", tool: "setup_state" + String(repeating: "x", count: pad))
            .line.dropLast())
        try #require(line.count == 120)
        let fits = try raw()
        defer { close(fits) }
        let whole = line + [10]
        _ = whole.withUnsafeBytes { write(fits, $0.baseAddress, $0.count) }
        #expect(readAll(fits) == String(decoding: OwnerChannel.Answer.result(.object([:])).line, as: UTF8.self))
        let before = link.readCount
        let over = try raw()
        defer { close(over) }
        // Far more than the bound with no line end, at once, and the rest held back: the listener reads the bound and one
        // byte, refuses, and takes nothing more (round 3, P4). A listener with no bound reads all 4,000.
        let long = Data(repeating: UInt8(ascii: "a"), count: 4_000)
        _ = long.withUnsafeBytes { write(over, $0.baseAddress, $0.count) }
        #expect(readAll(over).contains("longer than the 120 bytes"))
        #expect(link.readCount - before == 121)
        #expect(asked.all.count == 1)
    }
}

extension SignatureCheck: Equatable {
    public static func == (a: SignatureCheck, b: SignatureCheck) -> Bool {
        a.requirement == b.requirement && a.path == b.path
    }
}
