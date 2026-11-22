import Foundation
import Testing
@testable import FleetOwnerAPI

/// **The three tools of a cloud in the program inside the app** (design 9, piece B2), on a stand-in of each cloud's
/// program that answers by rules, as test_owner_mcp's `Cloud.STAND_IN` does: the first rule whose `has` words are all in
/// the command, whose `after` words were each in an earlier command and whose `before` words were in none. No cloud and
/// no hub. The parity fixture holds these tools' commands and answers to `owner_mcp.py`'s (OwnerParityTests); these
/// tests hold the checks that the Swift code makes itself.
struct OwnerCloudTests {
    struct Rule {
        var has: [String]
        var after: [String] = []
        var before: [String] = []
        var exit: Int32 = 0
        var out = ""
        var error = ""
    }

    /// A stand-in of `aws`, `az` and `gcloud`: each command that it gets, and the answer of its rules.
    final class StandIn: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        var rules: [Rule]
        var present = true
        /// A gate at the first command: it says that the command started, and waits until the test lets it go on.
        var gate: (started: DispatchSemaphore, go: DispatchSemaphore)?

        init(_ rules: [Rule]) { self.rules = rules }

        var lines: [String] { lock.lock(); defer { lock.unlock() }; return seen }

        var programs: CloudPrograms {
            CloudPrograms(find: { [self] name in present ? "/stand-in/bin/" + name : nil }, run: { [self] _, argv, _ in
                lock.lock()
                let line = argv.joined(separator: " "), earlier = seen
                seen.append(line)
                lock.unlock()
                if earlier.isEmpty, let gate {
                    gate.started.signal()
                    _ = gate.go.wait(timeout: .now() + 20)
                }
                for rule in rules where rule.has.allSatisfy(line.contains)
                    && rule.after.allSatisfy({ word in earlier.contains { $0.contains(word) } })
                    && !rule.before.contains(where: { word in earlier.contains { $0.contains(word) } }) {
                    return .ended(exit: rule.exit, out: Data(rule.out.utf8), error: Data(rule.error.utf8))
                }
                return .ended(exit: 99, out: Data(), error: Data("no rule for: \(line)".utf8))
            })
        }
    }

    static let name = "agents-1"
    static let base: [String: JSONValue] = ["cloud": .string("aws"), "name": .string(name),
                                            "account": .string("123456789012"), "place": .string("eu-central-1")]

    /// The rules of an AWS account with nothing of the recipe in it, and an answer of `describe-instances` and
    /// `describe-security-groups` that a test gives.
    static func aws(groups: String = "[]", reservations: String = "[]", identity: String? = nil) -> [Rule] {
        [Rule(has: ["aws --version"], out: "aws-cli/2.42.1 Python/3.13.9 Darwin/25.1.0\n"),
         Rule(has: ["sts get-caller-identity"],
              out: identity ?? #"{"Account": "123456789012", "Arn": "arn:aws:sts::123456789012:assumed-role/Admin/pat"}"#),
         Rule(has: ["describe-vpcs"], out: #"{"Vpcs": [{"VpcId": "vpc-0a1b2c3d4e5f67890"}]}"#),
         Rule(has: ["describe-security-groups"], out: #"{"SecurityGroups": \#(groups)}"#),
         Rule(has: ["describe-security-group-rules"], out: #"{"SecurityGroupRules": []}"#),
         Rule(has: ["describe-instances"], out: #"{"Reservations": \#(reservations)}"#)]
    }

    static func tools(_ stand: StandIn, proved: Bool = true) -> OwnerTools {
        var table = Fixture.table
        table.cloudRecipes = OwnerParityTests.proved(table.cloudRecipes, proved)
        return Fixture.tools(nil, home: Fixture.home(), table: table, programs: stand.programs)
    }

    static func call(_ stand: StandIn, _ tool: String, _ arguments: [String: JSONValue],
                     proved: Bool = true) -> (text: String, isError: Bool) {
        tools(stand, proved: proved).call(tool, .object(arguments))
    }

    /// The same as B1's test 2: a value with a first "-", a space, a quote, "$", ";", "|", "&", a backslash or a new
    /// line, a range of addresses wider than /24, a private range, a private key file, and a field that the tool does
    /// not have, are refused before any program runs. Bug: a check that only the Python copy makes.
    @Test func aValueCannotBecomeAnOptionOrASecondCommand() throws {
        let stand = StandIn(Self.aws())
        for (field, value) in [("name", JSONValue.string("-agents")), ("name", .string("agents 1")),
                               ("name", .string("door")), ("account", .string("1234; rm")),
                               ("place", .string("eu-central-1\n")), ("size", .string("--t3.small")),
                               ("subnet", .string("subnet-$x")), ("profile", .string("-p")),
                               ("ssh_from", .string("0.0.0.0/0")), ("ssh_from", .string("198.51.100.0/23")),
                               ("ssh_from", .string("203.0.113.9/24")), ("ssh_from", .string("100.64.0.7")),
                               ("ssh_from", .string("10.0.0.0/24")), ("ssh_from", .string("172.20.0.0/24")),
                               ("ssh_from", .string("192.168.1.5")), ("ssh_from", .string("01.2.3.4")),
                               ("disk_gb", .string("30")), ("disk_gb", .int(4096)), ("use", .string("agent;")),
                               ("command", .string("aws iam list-roles"))] {
            var arguments = Self.base
            arguments["step"] = .string("open_ssh")
            arguments["ssh_from"] = .string("203.0.113.9")
            arguments[field] = value
            let (text, isError) = Self.call(stand, "cloud_step", arguments)
            #expect(isError && text.contains("Nothing ran"), "\(field) \(value.dumps()): \(text)")
        }
        // The range has two guards, the pattern of the data and the code: the code alone refuses a range wider than /24.
        let check = OwnerCloud.Tools(recipes: Fixture.table.cloudRecipes, programs: Fixture.noPrograms)
        for wide in ["198.51.100.0/23", "0.0.0.0/0", "100.64.0.0/24"] {
            #expect(throws: OwnerRefusal.self, "\(wide)") { try check.sshFrom(wide) }
        }
        #expect(try check.sshFrom("203.0.113.9") == "203.0.113.9/32")
        let folder = Fixture.home()
        defer { try? FileManager.default.removeItem(at: folder) }
        let privateKey = folder.appendingPathComponent("id_ed25519").path
        try Data("-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaA==\n-----END OPENSSH PRIVATE KEY-----\n".utf8)
            .write(to: URL(fileURLWithPath: privateKey))
        let two = folder.appendingPathComponent("two.pub").path
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEhvc3RLZXlPZlRoZUh1Yg"
        try Data("\(key)\n\(key)\n".utf8).write(to: URL(fileURLWithPath: two))
        for (path, said) in [(privateKey, "holds a private key"), (two, "not one line"),
                             (folder.appendingPathComponent("none.pub").path, "not a public key file")] {
            var arguments = Self.base
            arguments["step"] = .string("server")
            arguments["ssh_public_key_file"] = .string(path)
            let (text, isError) = Self.call(stand, "cloud_step", arguments)
            #expect(isError && text.contains(said), "\(path): \(text)")
        }
        #expect(stand.lines.isEmpty, "\(stand.lines)")
    }

    /// The same as B1's test 5: an instance with the name's tag and another client token, and a security group of the
    /// name with no tag of the recipe, are refused by name, and no delete is sent. Bug: a delete by name.
    @Test func aRemovalTakesOnlyAMarkedThing() {
        let other = #"[{"Instances": [{"InstanceId": "i-0fedcba987654321f", "ClientToken": "someone-else"}]}]"#
        let untagged = #"[{"GroupId": "sg-0fedcba987654321f", "GroupName": "founderizer-agents-1", "Tags": []}]"#
        for (step, rules, said) in [("server", Self.aws(reservations: other), "i-0fedcba987654321f"),
                                    ("firewall", Self.aws(groups: untagged), "sg-0fedcba987654321f")] {
            let stand = StandIn(rules)
            var arguments = Self.base
            arguments["step"] = .string(step)
            let (text, isError) = Self.call(stand, "cloud_remove", arguments)
            #expect(isError && text.contains(said) && text.contains("without this recipe's mark"), "\(step): \(text)")
            #expect(!stand.lines.contains { $0.contains("terminate-instances") || $0.contains("delete-security-group") },
                    "\(stand.lines)")
        }
    }

    /// The same as B1's test 6: the program is not there, its sign-in ended, or it is signed in to another account:
    /// the refusal has the admin's own step, no later command is sent, and no refusal asks for a key or a token. Bug:
    /// the step goes on.
    @Test func aMissingProgramASignOutAndAnotherAccountStopBeforeAnyChange() throws {
        let recipe = try #require(Fixture.table.cloudRecipes["clouds"]?["aws"])
        let missing = StandIn(Self.aws())
        missing.present = false
        var firewall = Self.base
        firewall["step"] = .string("firewall")
        let none = Self.call(missing, "cloud_look", Self.base)
        #expect(none.isError && none.text.contains(recipe["missing"]?.string ?? "-"), "\(none.text)")
        #expect(missing.lines.isEmpty)
        var signedOut = Self.aws()
        signedOut.insert(Rule(has: ["sts get-caller-identity"], exit: 253, error: "Unable to locate credentials."),
                         at: 1)
        let out = StandIn(signedOut)
        let said = Self.call(out, "cloud_step", firewall)
        #expect(said.isError && said.text.contains(recipe["signed_out"]?.string ?? "-"), "\(said.text)")
        #expect(out.lines.count == 2, "\(out.lines)")
        let other = StandIn(Self.aws(identity: #"{"Account": "999999999999", "Arn": "arn:aws:iam::999999999999:user/x"}"#))
        let elsewhere = Self.call(other, "cloud_step", firewall)
        #expect(elsewhere.isError && elsewhere.text.contains("999999999999"), "\(elsewhere.text)")
        #expect(other.lines.count == 2, "\(other.lines)")
        for text in [none.text, said.text, elsewhere.text] {
            #expect(text.range(of: "access key|secret|token|password", options: [.regularExpression, .caseInsensitive])
                    == nil, "\(text)")
        }
        let unproved = Self.call(StandIn(Self.aws()), "cloud_look", Self.base, proved: false)
        #expect(unproved.isError && unproved.text.contains("does not offer servers"), "\(unproved.text)")
    }

    /// **The program names no add_machine** (design 9, B2 test 3): it has no such tool, so neither its answers nor
    /// its refusals send the agent there, and its check is the app's own Add server page. Bug: `next` sends the agent
    /// to a tool that the program does not have.
    @Test func theProgramNamesNoAddMachine() {
        let table = Fixture.tools(nil, home: Fixture.home()).table
        #expect(table.tool("add_machine")?.kind == .absent)
        let step = table.tool("cloud_step")
        #expect(step?.kind == .swift && step?.description.contains("its Add server page") == true)
        #expect(step?.description.contains("check reads a server") == false, "\(step?.description ?? "")")
        let stand = StandIn(Self.aws())
        var check = Self.base
        check["step"] = .string("check")
        let unproved = Self.call(stand, "cloud_look", Self.base, proved: false)
        let refused = Self.call(stand, "cloud_step", check)
        #expect(refused.isError && refused.text.contains("Add server page"), "\(refused.text)")
        let recipe = Self.call(stand, "cloud_look", ["cloud": .string("aws")])
        for text in [unproved.text, refused.text, recipe.text] {
            #expect(!text.contains("add_machine") && !text.contains("install_hub"), "\(text)")
        }
        for (name, cloud) in (Fixture.table.cloudRecipes["clouds"]?.object ?? [:]) {
            #expect(cloud["steps"]?.array?.contains { $0["id"] == .string("join") && $0["app"] != nil } == true, "\(name)")
        }
    }

    /// **The program is found in absolute folders of the PATH only** (`CloudPrograms.find`, as `owner_mcp.py`'s
    /// `cloud_which`): no PATH, an empty one, an empty part and a relative part are not the working folder, and a folder
    /// or a file that does not run is no program. Bug: a file named aws in the AI client's working folder, which an agent
    /// or a cloned repository can write, runs with the admin's cloud login.
    @Test func theProgramIsFoundInAbsoluteFoldersOnly() throws {
        let folder = Fixture.home()
        defer { try? FileManager.default.removeItem(at: folder) }
        let bin = folder.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let aws = bin.appendingPathComponent("aws").path
        FileManager.default.createFile(atPath: aws, contents: Data("#!/bin/sh\necho x\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        try FileManager.default.createDirectory(at: bin.appendingPathComponent("az"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bin.appendingPathComponent("gcloud").path, contents: Data("x".utf8),
                                       attributes: [.posixPermissions: 0o644])
        #expect(CloudPrograms.find("aws", in: bin.path) == aws)
        #expect(CloudPrograms.find("aws", in: "/no/such/folder::.:bin:" + bin.path) == aws)
        // A relative part that leads from the working folder to this bin folder: it has an aws that runs, so only the
        // rule of absolute folders refuses it.
        let up = FileManager.default.currentDirectoryPath.split(separator: "/").map { _ in ".." }.joined(separator: "/")
        let relative = up + bin.path
        for path in [nil, "", ":", ".", "bin", "./bin", relative] as [String?] {
            #expect(CloudPrograms.find("aws", in: path) == nil, "\(path ?? "no PATH")")
        }
        #expect(CloudPrograms.find("az", in: bin.path) == nil)          // a folder
        #expect(CloudPrograms.find("gcloud", in: bin.path) == nil)      // a file that does not run
    }

    /// **The runner of this computer** (`CloudPrograms.thisComputer`, the one code that starts a real program): a
    /// program's output and its status, a program that fails, a program that does not end in its limit (stopped at that
    /// limit, not later), a program that ends and leaves a child that keeps its output open (the reads end at the same
    /// limit), a program that is killed at its limit (its next command never runs), and a path that is no program.
    /// Bug: a time-out that waits for the program, or for its output, long after its limit, or that lets the program run
    /// on, so that a cloud's command goes on after the tool said that it stopped.
    @Test func theRunnerOfThisComputerKeepsItsLimit() {
        let run = CloudPrograms.thisComputer.run
        guard case .ended(0, let out, _) = run("/bin/echo", ["echo", "hello"], 10) else {
            Issue.record("echo did not end with 0")
            return
        }
        #expect(String(decoding: out, as: UTF8.self) == "hello\n")
        guard case .ended(let failed, _, _) = run("/usr/bin/false", ["false"], 10) else {
            Issue.record("false did not end")
            return
        }
        #expect(failed == 1)
        let started = Date()
        guard case .timedOut = run("/bin/sleep", ["sleep", "30"], 0.5) else {
            Issue.record("sleep was not stopped at its limit")
            return
        }
        #expect(Date().timeIntervalSince(started) < 5)
        let open = Date()
        guard case .timedOut = run("/bin/sh", ["sh", "-c", "/bin/sleep 3 & exit 0"], 0.5) else {
            Issue.record("a child that keeps the output open was waited for")
            return
        }
        #expect(Date().timeIntervalSince(open) < 2.5)
        let folder = Fixture.home()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ran = folder.appendingPathComponent("ran").path
        guard case .timedOut = run("/bin/sh", ["sh", "-c", "/bin/sleep 1; /usr/bin/touch '\(ran)'"], 0.3) else {
            Issue.record("a program past its limit was not stopped")
            return
        }
        Thread.sleep(forTimeInterval: 2)
        #expect(!FileManager.default.fileExists(atPath: ran), "the program ran on after its limit")
        guard case .notStarted = run("/no/such/program", ["aws"], 10) else {
            Issue.record("a path that is no program started")
            return
        }
    }

    /// The runner's other outcomes reach the agent in words, as `owner_mcp.py`'s `cloud_program` says them: a command
    /// that did not end in its 120 seconds (it can still run, and nothing was sent again), a program that could not
    /// start, and an answer larger than 8 MiB. Bug: a refusal that hides what the program did.
    @Test func aTimeOutAStartThatFailsAndALongAnswerAreSaidInWords() {
        let outcomes: [(CloudPrograms.Outcome, String)] = [
            (.timedOut, "did not finish in 120 seconds, and it can still run. Nothing was sent again."),
            (.notStarted("No such file"), "aws could not run on this computer: No such file."),
            (.ended(exit: 0, out: Data(count: 8 * 1024 * 1024 + 1), error: Data()), "gave more than 8388608 bytes"),
        ]
        for (outcome, said) in outcomes {
            let programs = CloudPrograms(find: { "/stand-in/bin/" + $0 }, run: { _, _, _ in outcome })
            var table = Fixture.table
            table.cloudRecipes = OwnerParityTests.proved(table.cloudRecipes, true)
            let tools = Fixture.tools(nil, home: Fixture.home(), table: table, programs: programs)
            let (text, isError) = tools.call("cloud_look", .object(Self.base))
            #expect(isError && text.contains(said), "\(text)")
        }
    }

    /// **A cancel of a call that runs starts no other command of it** (the coordinator's D56, as `owner_mcp.py`'s
    /// `next_step`): the client cancels cloud_step firewall while its first read runs, and the command that makes the
    /// firewall is never sent, and the call gets no answer. A call that waits and is cancelled never starts. A cancel
    /// marks only a request that the server holds, as `Calls.cancel`: a cancel that came before its call, and an id that
    /// a new call takes after the answer step of a cancelled one, leave that call its answer. Bug: the admin stops a step
    /// that rents a server, and the program still sends it; or a cancel stays for the life of the program, and a later
    /// call with that id is never answered.
    @Test func aCancelledCallSendsNoChange() throws {
        let gate = (started: DispatchSemaphore(value: 0), go: DispatchSemaphore(value: 0))
        let stand = StandIn(Self.aws())
        stand.gate = gate
        final class Said: @unchecked Sendable {
            let lock = NSLock()
            var lines: [String] = []
            func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        }
        let said = Said()
        let mcp = OwnerMCP(tools: Self.tools(stand), version: "test", sink: { said.add($0) })
        func call(_ id: Int, _ arguments: [String: JSONValue], _ tool: String = "cloud_step") -> String {
            JSONValue.object(["jsonrpc": .string("2.0"), "id": .int(Int64(id)), "method": .string("tools/call"),
                              "params": .object(["name": .string(tool), "arguments": .object(arguments)])]).dumps()
        }
        var firewall = Self.base
        firewall["step"] = .string("firewall")
        mcp.take(line: call(7, firewall))
        mcp.take(line: call(8, Self.base, "cloud_look"))                // waits behind the call 7
        #expect(gate.started.wait(timeout: .now() + 20) == .success)
        for id in [7, 8] {
            mcp.take(line: #"{"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": \#(id)}}"#)
        }
        gate.go.signal()
        mcp.finish()
        #expect(stand.lines == ["aws --version"], "\(stand.lines)")
        #expect(said.lines.isEmpty, "\(said.lines)")
        mcp.take(line: #"{"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 9}}"#)
        mcp.take(line: call(9, Self.base, "cloud_look"))                // its cancel came first
        mcp.take(line: call(7, Self.base, "cloud_look"))                // the id of a cancelled call, after its answer step
        mcp.take(line: "[" + call(11, Self.base, "cloud_look")          // a call and its cancel in one batch
                     + #", {"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 11}}]"#)
        mcp.finish()
        let ids = said.lines.compactMap { JSONValue.parse($0)?["id"] }
        #expect(ids == [.int(9), .int(7)], "\(said.lines)")
        #expect(mcp.holding == 0)                                       // no id stays after its answer step
    }

    /// **A cancel reaches the new program after an app update** (the coordinator's D59): the session's program relays
    /// cloud_step firewall to the new program (`ProgramRelay`), the client cancels it while its first read runs there,
    /// and the relay sends the cancel to that program under the relay's own id: the command that makes the firewall is
    /// never sent, and the call gets no answer. The new program stays for the next call, and a call that the client
    /// cancelled before the relay sent it is never sent. Bug: the cancel stays in the old program, and a session that is
    /// older than the last update rents the server after the admin's Esc.
    @Test func aCancelAfterAnUpdateReachesTheNewProgram() throws {
        let gate = (started: DispatchSemaphore(value: 0), go: DispatchSemaphore(value: 0))
        let stand = StandIn(Self.aws())
        stand.gate = gate
        let forwarded = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var server: OwnerMCP? }
        let child = Box()
        let starts = OwnerRelayTests.Value(0), calls = OwnerRelayTests.Value(0)
        let relay = ProgramRelay(path: OwnerRelayTests.path, build: { 216 }, launch: {
            starts.value += 1
            let lines = OwnerRelayTests.Lines()
            let server = OwnerMCP(tools: Self.tools(stand), version: "new", sink: { lines.put($0) })
            child.server = server
            return .child(ProgramRelay.Child(send: { line in
                                                 if line.contains("\"tools/call\"") { calls.value += 1 }
                                                 server.take(line: line)
                                                 if line.contains("notifications/cancelled") { forwarded.signal() }
                                                 return true
                                             },
                                             receive: { lines.take(until: $0) }, stop: { lines.close() }))
        }, version: "old")
        var table = Fixture.table
        table.cloudRecipes = OwnerParityTests.proved(table.cloudRecipes, true)
        // The session's program has no programs of its own: only the relay can run the call.
        let old = Fixture.tools(nil, home: Fixture.home(), ownBuild: 215, started: { 216 }, table: table, relay: relay)
        final class Said: @unchecked Sendable {
            let lock = NSLock()
            var lines: [String] = []
            func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        }
        let said = Said()
        let mcp = OwnerMCP(tools: old, version: "old", sink: { said.add($0) })
        var firewall = Self.base
        firewall["step"] = .string("firewall")
        mcp.take(line: JSONValue.object(["jsonrpc": .string("2.0"), "id": .int(7), "method": .string("tools/call"),
                                         "params": .object(["name": .string("cloud_step"),
                                                            "arguments": .object(firewall)])]).dumps())
        #expect(gate.started.wait(timeout: .now() + 20) == .success)
        mcp.take(line: #"{"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 7}}"#)
        #expect(forwarded.wait(timeout: .now() + 5) == .success, "the cancel did not reach the new program")
        gate.go.signal()
        mcp.finish()
        child.server?.finish()
        #expect(stand.lines == ["aws --version"], "\(stand.lines)")
        #expect(said.lines.isEmpty, "\(said.lines)")
        let look = try #require(table.tool("cloud_look"))
        let entry = ProgramRelay.entry(description: look.description, inputSchema: look.inputSchema,
                                       annotations: look.annotations)
        #expect(relay.call("cloud_look", arguments: .object(Self.base), entry: entry,
                           protocolVersion: table.protocolVersion, cancelled: { true }) == .cancelled)
        #expect(calls.value == 1, "a call that was cancelled before the relay sent it reached the new program")
        guard case .answered = relay.call("cloud_look", arguments: .object(Self.base), entry: entry,
                                          protocolVersion: table.protocolVersion) else {
            Issue.record("the next call after a cancel got no answer")
            return
        }
        #expect(starts.value == 1, "the new program was started again after the cancel")
    }

    /// **No call of a cloud tool reaches the hub**: the program has no hub here, and the look of a recipe answers, with
    /// the data mark of the cloud's program and not of the hub. Bug: a cloud tool that needs a fleet, so that a cloud
    /// admin with no hub cannot use it.
    @Test func aCloudToolNeedsNoHub() {
        let (text, isError) = Self.call(StandIn(Self.aws()), "cloud_look", ["cloud": .string("aws")])
        #expect(!isError && text.hasPrefix(OwnerCloud.dataMark + "\n"), "\(text)")
    }
}
