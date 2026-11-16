import Foundation
import Testing
@testable import FleetCore

/// Run on the command of a hand step (owner feature `need_run`, API 1.197): which block has Run, where it runs, what a
/// run gives back, and the answer that goes to the hub. Example names and addresses only.
struct NeedRunTests {
    static let command = "gh auth logout -h github.com -u example-user"
    static let task = "On the Mac, in any folder, run:\n\n```\n\(command)\n```"

    static func need(id: Int = 7, todo: String = task, command: String? = NeedRunTests.command, on: String? = "mac",
                     answer: String? = nil, status: Int? = nil, output: String? = nil,
                     extra: [String: Any] = [:]) throws -> OwnerNeed {
        var fields: [String: Any] = ["id": id, "title": "Sign a login out of the Mac", "why": "An agent falls back to it.",
                                     "todo": todo, "raised": 100.0, "by": "manager"]
        if let command { fields["run_command"] = command }
        if let on { fields["run_on"] = on }
        if let answer { fields["answer"] = answer; fields["answered"] = 200.0 }
        if let status { fields["run_status"] = status }
        if let output { fields["run_output"] = output }
        fields.merge(extra) { _, b in b }
        return try JSONDecoder().decode(OwnerNeed.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    static func machine(_ name: String, address: String? = "100.64.0.20", user: String = "owner-example",
                        port: Int = 22, system: String = "macOS 27.2") throws -> MachineStatus {
        var fields: [String: Any] = ["agent": "agent-" + name, "machine": name, "role": "worker", "update": [:],
                                     "runtime": ["signed_in": true], "security": [:], "os": ["name": system],
                                     "access": ["ssh": ["user": user, "port": port, "available": true]]]
        if let address { fields["address"] = address }
        return try JSONDecoder().decode(MachineStatus.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    @Test func runStandsOnlyOnTheBlockThatShowsTheCommand() throws {
        #expect(NeedRun.command(of: try Self.need()) == Self.command)
        // an indented block in a numbered step is the same block, as the hub reads it
        #expect(NeedRun.command(of: try Self.need(todo: "1. Open Terminal.\n2. Run:\n   ```bash\n   \(Self.command)\n   ```"))
                == Self.command)
        #expect(NeedRun.command(of: try Self.need(todo: "Run `\(Self.command)` on the Mac.")) == nil)
        #expect(NeedRun.command(of: try Self.need(todo: "```\n\(Self.command) --force\n```")) == nil)
        #expect(NeedRun.command(of: try Self.need(command: nil)) == nil)
        #expect(NeedRun.command(of: try Self.need(on: nil)) == nil)
        #expect(NeedRun.command(of: try Self.need(on: "")) == nil)
        // an answered item has no Run, and neither has one whose task stays behind its link (a door call)
        #expect(NeedRun.command(of: try Self.need(answer: "Ran it on the owner's Mac", status: 0)) == nil)
        #expect(NeedRun.command(of: try Self.need(extra: ["door_call": String(repeating: "a", count: 64)])) == nil)
        #expect(NeedRun.command(of: try Self.need(extra: ["kind": "question"])) == nil)
    }

    @Test func aCommandIsOneLineOfPrintableASCIIWithNoSudo() {
        #expect(NeedRun.allowed(Self.command))
        #expect(NeedRun.allowed("visudo-check --help"))
        #expect(NeedRun.allowed("echo pseudo-sudo"))
        for refused in ["", " gh auth status", "gh auth status ", "gh auth status\necho done", "gh\tauth status",
                        "gh auth status\u{200B}", "echo caf\u{E9}", "gh auth status \u{2014} now", "```",
                        "sudo rm -rf /opt/example", "cd /tmp && sudo -v", "echo $(sudo id)", "x;sudo y", "echo then sudo",
                        "gh auth status" + String(repeating: " ", count: NeedRun.gapSpaces + 1) + "; echo more",
                        "echo " + String(repeating: "a", count: NeedRun.commandCharacters)] {
            #expect(!NeedRun.allowed(refused), "\(refused)")
        }
        #expect(NeedRun.allowed("echo " + String(repeating: "a", count: NeedRun.commandCharacters - 5)))
        #expect(NeedRun.allowed("gh auth status" + String(repeating: " ", count: NeedRun.gapSpaces) + "; echo more"))
    }

    @Test func itRunsOnThisMacOrOnAMacOfTheFleetThatThisMacReaches() throws {
        #expect(NeedRun.place(of: try Self.need(), machines: nil) == .thisMac)
        let studio = try Self.machine("studio-1")
        #expect(NeedRun.place(of: try Self.need(on: "studio-1"), machines: [studio])
                == .machine(name: "studio-1", address: "100.64.0.20", user: "owner-example", port: 22))
        // no reading of it, no address, a name that is no address, a user that is no plain name: no Run
        #expect(NeedRun.place(of: try Self.need(on: "studio-1"), machines: nil) == nil)
        #expect(NeedRun.place(of: try Self.need(on: "studio-2"), machines: [studio]) == nil)
        #expect(NeedRun.place(of: try Self.need(on: "studio-1"), machines: [try Self.machine("studio-1", address: nil)]) == nil)
        #expect(NeedRun.place(of: try Self.need(on: "studio-1"),
                              machines: [try Self.machine("studio-1", address: "studio.example.com")]) == nil)
        #expect(NeedRun.place(of: try Self.need(on: "studio-1"),
                              machines: [try Self.machine("studio-1", user: "-oProxyCommand=x")]) == nil)
        // a server of the fleet is no place of Run: a step there goes through the door
        #expect(NeedRun.place(of: try Self.need(on: "studio-1"),
                              machines: [try Self.machine("studio-1", system: "Ubuntu 24.04.1 LTS")]) == nil)
    }

    @Test func theAnswerHasTheHubsWords() {
        #expect(NeedRun.answerWords(on: "mac", status: 0) == "Ran it on the owner's Mac")
        #expect(NeedRun.answerWords(on: "studio-1", status: 0) == "Ran it on studio-1")
        #expect(NeedRun.answerWords(on: "studio-1", status: 2) == "Ran it on studio-1, exit status 2")
    }

    @Test func theOutputKeepsItsEndByTheHubsCountAndNoPartOfAWord() {
        let words = String(repeating: "word\u{1F600} ", count: 3000)        // 18,000 scalars
        let tail = NeedRun.tail(words)
        #expect(tail.unicodeScalars.count <= NeedRun.outputCharacters)
        #expect(tail.unicodeScalars.count > NeedRun.outputCharacters - 7)
        #expect(tail.hasPrefix("word\u{1F600} "))                  // the part of a word at the cut is gone
        // a cut inside a run with no white space keeps none of it: a login holds no white space
        #expect(NeedRun.tail(String(repeating: "x", count: NeedRun.outputCharacters + 1)) == "")
        #expect(NeedRun.tail("short\n") == "short\n")
    }

    @Test func theCommandGoesOnTheShellsInputBetweenItsStartLineAndItsEndLine() throws {
        let script = String(decoding: NeedRun.script("echo hi", marker: "founderizer-run-x"), as: UTF8.self)
        #expect(script == "printf '%s\\n' 'founderizer-run-x'\n{ echo hi\n} < /dev/null 2>&1\nprintf '\\n%s %s\\n' 'founderizer-run-x-end' \"$?\"\n")
        #expect(NeedRun.after(marker: "founderizer-run-x", in: "Last login\nfounderizer-run-x\nhi\n") == "hi\n")
        #expect(NeedRun.after(marker: "founderizer-run-x", in: "ssh: connect to host 100.64.0.20 port 22: refused\n") == nil)
        // the end line says the status, and the output is what came before it
        #expect(NeedRun.ending(marker: "founderizer-run-x", in: "hi\n\nfounderizer-run-x-end 3\n")! == ("hi\n", 3))
        #expect(NeedRun.ending(marker: "founderizer-run-x", in: "\nfounderizer-run-x-end 0\n")! == ("", 0))
        // no whole end line: the command ended the shell itself, or the connection went
        #expect(NeedRun.ending(marker: "founderizer-run-x", in: "hi\n") == nil)
        #expect(NeedRun.ending(marker: "founderizer-run-x", in: "hi\n\nfounderizer-run-x-end 12") == nil)
        #expect(NeedRun.ending(marker: "founderizer-run-x", in: "hi\n\nfounderizer-run-x-end 999\n") == nil)
    }

    @Test func aRunOnThisMacGivesItsExitStatusAndItsOutput() async {
        let job = NeedRunJob(command: "echo hello; echo oops >&2; exit 3", place: .thisMac, shell: "/bin/sh")
        #expect(await job.run() == .ran(status: 3, output: "hello\noops\n"))
        let quiet = NeedRunJob(command: "true", place: .thisMac, shell: "/bin/sh")
        #expect(await quiet.run() == .ran(status: 0, output: ""))
    }

    @Test func aRunOnThisMacStartsInTheHomeFolder() async {
        let job = NeedRunJob(command: "pwd", place: .thisMac, shell: "/bin/sh")
        #expect(await job.run() == .ran(status: 0, output: FileManager.default.homeDirectoryForCurrentUser.path + "\n"))
    }

    @Test func aCommandThatLeavesAProcessInTheBackgroundEndsWithItsShell() async {
        // the background process keeps the output's pipe open for 5 seconds: the run does not wait for it
        let job = NeedRunJob(command: "sleep 5 & echo started", place: .thisMac, shell: "/bin/sh")
        let started = ContinuousClock.now
        #expect(await job.run() == .ran(status: 0, output: "started\n"))
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    @Test func aRunReadsNoInputButTheCommand() async {
        // the command's own standard input is the rest of the script: nothing
        let job = NeedRunJob(command: "cat; echo end", place: .thisMac, shell: "/bin/sh")
        #expect(await job.run() == .ran(status: 0, output: "end\n"))
    }

    @Test func aCommandThatEndsTheShellItselfGivesTheShellsStatus() async {
        let job = NeedRunJob(command: "echo bye; exit 4", place: .thisMac, shell: "/bin/sh")
        #expect(await job.run() == .ran(status: 4, output: "bye\n"))
    }

    @Test func aMacOfTheFleetRunsOverSSHAndAMacNotReachedSendsNothing() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("need-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // a stand-in for ssh that checks its arguments and starts the remote side's shell with the script on its input
        let reaches = folder.appendingPathComponent("ssh-reaches")
        try """
            #!/bin/sh
            [ "$1" = "-T" ] || exit 9
            case "$*" in *"BatchMode=yes"*"-p 2222 owner-example@100.64.0.20"*) ;; *) exit 8 ;; esac
            exec /bin/sh
            """.write(to: reaches, atomically: true, encoding: .utf8)
        let refuses = folder.appendingPathComponent("ssh-refuses")
        try "#!/bin/sh\necho 'ssh: connect to host 100.64.0.20 port 2222: Connection refused' >&2\nexit 255\n"
            .write(to: refuses, atomically: true, encoding: .utf8)
        // as ssh does, it waits on after the shell there ended, while a process holds the session's output
        let waits = folder.appendingPathComponent("ssh-waits")
        try "#!/bin/sh\n/bin/sh\nsleep 8\n".write(to: waits, atomically: true, encoding: .utf8)
        for file in [reaches, refuses, waits] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let place = NeedRun.Place.machine(name: "studio-1", address: "100.64.0.20", user: "owner-example", port: 2222)
        let ran = NeedRunJob(command: "echo there", place: place, ssh: reaches.path)
        #expect(await ran.run() == .ran(status: 0, output: "there\n"))
        let refused = NeedRunJob(command: "echo there", place: place, ssh: refuses.path)
        #expect(await refused.run() == .notReached("ssh: connect to host 100.64.0.20 port 2222: Connection refused"))
        // a process that the command leaves in the background there keeps ssh's session open: the end line ends it
        let started = ContinuousClock.now
        let left = NeedRunJob(command: "sleep 5 & echo there", place: place, ssh: waits.path)
        #expect(await left.run() == .ran(status: 0, output: "there\n"))
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    /// The run of 16 November 2026: over ssh a command's error words come on a channel of their own, and the end line
    /// came first, so the answer lost gh's "not logged in to any hosts". A stand-in for ssh that gives the error
    /// channel a second late shows it.
    @Test func aCommandsErrorWordsComeBeforeItsEndLineOverSSH() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("need-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let splits = folder.appendingPathComponent("ssh-splits")
        try "#!/bin/bash\nexec 3>&2\n/bin/sh 2> >(sleep 1; cat >&3)\n".write(to: splits, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: splits.path)
        let place = NeedRun.Place.machine(name: "studio-1", address: "100.64.0.20", user: "owner-example", port: 22)
        let job = NeedRunJob(command: "echo out; echo 'not logged in to any hosts' >&2; false", place: place,
                             ssh: splits.path)
        #expect(await job.run() == .ran(status: 1, output: "out\nnot logged in to any hosts\n"))
    }

    @Test func stopEndsTheRunAndItsCommand() async throws {
        let job = NeedRunJob(command: "sleep 30; echo late", place: .thisMac, shell: "/bin/sh")
        let started = ContinuousClock.now
        async let outcome = job.run()
        try await Task.sleep(for: .milliseconds(400))
        job.stop()
        #expect(await outcome == .stopped)
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test func thePressOfRunIsAnAnswerThatTheHubWrites() throws {
        let hub = try #require(URL(string: "http://100.64.0.1:8765"))
        let request = PendingRequest(hub: hub, database: "generation-1", client: "test", needID: 7,
                                     ran: NeedRunResult(status: 1, output: "not logged in\n"),
                                     text: NeedRun.answerWords(on: "mac", status: 1))
        let body = try #require(JSONSerialization.jsonObject(with: try request.body()) as? [String: Any])
        #expect(body["answer"] == nil)
        let ran = try #require(body["ran"] as? [String: Any])
        #expect(ran["status"] as? Int == 1 && ran["output"] as? String == "not logged in\n")
        #expect(!request.answersInWords)
        // it is saved and read back as it was, and a request that an older version saved has no run
        let again = try JSONDecoder().decode(PendingRequest.self, from: try JSONEncoder().encode(request))
        #expect(again.ran == request.ran)
        var older = try #require(JSONSerialization.jsonObject(with: try JSONEncoder().encode(request)) as? [String: Any])
        older["ran"] = nil
        #expect(try JSONDecoder().decode(PendingRequest.self, from: JSONSerialization.data(withJSONObject: older)).ran == nil)
        // a run is no part of a message, a press or ticked options
        #expect(PendingRequest(hub: hub, database: "g", client: "t", ran: NeedRunResult(status: 0, output: ""), text: "x").ran == nil)
        #expect(PendingRequest(hub: hub, database: "g", client: "t", needID: 7, choice: 0,
                               ran: NeedRunResult(status: 0, output: ""), text: "x").ran == nil)
    }

    @Test func anAnswerByRunIsNoAnswerInWords() throws {
        let ran = try Self.need(answer: "Ran it on the owner's Mac", status: 0, output: "done\n")
        #expect(!ran.answeredInWords)
        let words = try Self.need(answer: "Someone uses that login on purpose")
        #expect(words.answeredInWords)
        // while the reading still has it open, the hub's words of a run are a press
        #expect(try Self.need().offers("Ran it on the owner's Mac"))
        #expect(!(try Self.need(command: nil, on: nil).offers("Ran it on the owner's Mac")))
    }
}
