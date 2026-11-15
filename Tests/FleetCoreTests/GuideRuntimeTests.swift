#if os(macOS)
import CryptoKit
import Foundation
import Testing
@testable import FleetCore

/// **The guide's session runner** (`GuideRuntime`, `GuideCommand`): the command of a start, the check at each turn, a
/// turn, an interrupt, a quit and a resume.
///
/// Each test but the last suite runs a stand-in for the provider's program: a small shell script that prints prepared
/// lines for each message that it gets. No test here starts Claude Code, and none spends a plan. `GuideLiveTests` at the
/// end is the live tool-list test, which runs by hand only.
@Suite(.timeLimit(.minutes(1)))
struct GuideRuntimeTests {
    // MARK: the stand-in program

    /// A scratch folder with the stand-in program and the guide's places. The program prints the file `turn-<n>` for
    /// its n-th message, `at-start` before any message, and `on-interrupt` for an interrupt. It keeps its arguments,
    /// its environment, its folder and each line of its input.
    private final class StandIn {
        static let script = #"""
        #!/bin/sh
        dir="$(dirname "$0")"
        printf '%s\n' "$@" > "$dir/arguments"
        env > "$dir/environment"
        pwd > "$dir/folder"
        [ -f "$dir/at-start" ] && cat "$dir/at-start"
        [ -f "$dir/refuse" ] && exit 1
        n=0
        while IFS= read -r line; do
            printf '%s\n' "$line" >> "$dir/input"
            case "$line" in
                *control_request*) [ -f "$dir/on-interrupt" ] && cat "$dir/on-interrupt"; continue ;;
            esac
            n=$((n + 1))
            [ -f "$dir/turn-$n" ] && cat "$dir/turn-$n"
            [ -f "$dir/exit-after-$n" ] && exit "$(cat "$dir/exit-after-$n")"
        done
        exit 0
        """#

        static let version = "9.9.9"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("guide-runtime-\(UUID().uuidString)")
        var program: URL { root.appendingPathComponent("stand-in/claude") }
        var places: GuidePlaces { GuidePlaces(root: root.appendingPathComponent("guide")) }

        init() throws {
            try FileManager.default.createDirectory(at: program.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(Self.script.utf8).write(to: program)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        /// The stand-in's script is the one tested version, and the provider signed it.
        var checker: GuideProgram.Checker {
            let sum = SHA256.hash(data: Data(Self.script.utf8)).map { String(format: "%02x", $0) }.joined()
            return GuideProgram.Checker(tested: [GuideProgram.Tested(number: Self.version, sha256: ["test-kind": sum])],
                                        kind: "test-kind", signedByProvider: { _ in true })
        }

        func start(resume: Bool = false) -> GuideStart {
            GuideStart(program: program, appsOwn: false, helper: "/Applications/Example.app/Contents/MacOS/founderizer-cli",
                       label: "example-label", tools: GuideTool.list, text: "The guide text.",
                       session: "00000000-0000-4000-8000-000000000001", resume: resume, places: places,
                       home: "/Users/owner", user: "example")
        }

        func prints(_ lines: [String], at name: String) throws {
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: program.deletingLastPathComponent().appendingPathComponent(name))
        }

        func kept(_ name: String) -> [String] {
            let file = program.deletingLastPathComponent().appendingPathComponent(name)
            return ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        /// The texts of the messages that the program got, in order.
        var messages: [String] {
            kept("input").compactMap { line in
                let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
                let content = (object?["message"] as? [String: Any])?["content"] as? [[String: Any]]
                return content?.first?["text"] as? String
            }
        }
    }

    private static func initLine(tools: [String] = GuideTool.list.map(GuideCheck.whole), servers: [String] = ["founderizer"],
                                 version: String = StandIn.version) -> String {
        let object: [String: Any] = ["type": "system", "subtype": "init", "tools": tools, "claude_code_version": version,
                                     "mcp_servers": servers.map { ["name": $0, "status": "connected"] }]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private static func says(_ text: String) -> String {
        #"{"type":"assistant","message":{"model":"example-model","content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    private static let calls = #"{"type":"assistant","message":{"model":"example-model","content":[{"type":"tool_use","id":"toolu_example01","name":"mcp__founderizer__setup_state","input":{}}]}}"#
    private static let done = #"{"type":"result","subtype":"success","is_error":false}"#
    private static func turn(_ text: String) -> [String] { [initLine(), says(text), done] }

    /// The events to the end of the stream.
    private static func all(_ runtime: GuideRuntime) async -> [GuideEvent] {
        var events: [GuideEvent] = []
        for await event in runtime.events { events.append(event) }
        return events
    }

    // MARK: the command, held to the spec word for word

    @Test func theArgumentsOfAStart() throws {
        let standIn = try StandIn()
        #expect(GuideCommand.arguments(standIn.start()) == [
            "--print", "--verbose", "--input-format", "stream-json", "--output-format", "stream-json",
            "--strict-mcp-config", "--mcp-config", standIn.places.configuration.path,
            "--setting-sources", "", "--tools", "", "--disable-slash-commands", "--no-chrome",
            "--allowedTools", "mcp__founderizer__setup_state,mcp__founderizer__setup_show,mcp__founderizer__propose_team,"
                + "mcp__founderizer__ask_secret,mcp__founderizer__check_servers,mcp__founderizer__propose_servers,"
                + "mcp__founderizer__offer_repair,mcp__founderizer__finish",
            "--system-prompt", "The guide text.",
            "--session-id", "00000000-0000-4000-8000-000000000001",
            "--model", "sonnet",
        ])
    }

    @Test func aResumeNamesTheKeptSessionInThePlaceOfANewOne() throws {
        let arguments = GuideCommand.arguments(try StandIn().start(resume: true))
        #expect(!arguments.contains("--session-id"))
        let resume = try #require(arguments.firstIndex(of: "--resume"))
        #expect(arguments[resume + 1] == "00000000-0000-4000-8000-000000000001")
        // `--bare` reads no plan sign-in, and a browser tool is never in the guide's own session.
        #expect(!arguments.contains("--bare"))
        #expect(!arguments.contains("--chrome"))
    }

    @Test func theEnvironmentHoldsNothingOfTheApps() {
        #expect(GuideCommand.environment(home: "/Users/owner", user: "example") == [
            "HOME": "/Users/owner", "USER": "example", "PATH": "/usr/bin:/bin", "DISABLE_AUTOUPDATER": "1",
            "CLAUDE_CODE_HARBOR_KITE": "0", "CLAUDE_CODE_DISABLE_FILE_MENTIONS": "1",
        ])
    }

    @Test func theConfigurationNamesOneServerWithItsSetAndItsLabel() throws {
        let object = try JSONSerialization.jsonObject(with: GuideCommand.configuration(try StandIn().start())) as? NSDictionary
        #expect(object == ["mcpServers": ["founderizer": [
            "command": "/Applications/Example.app/Contents/MacOS/founderizer-cli", "args": ["mcp", "--set", "guide"],
            "env": ["FOUNDERIZER_GUIDE": "example-label"],
        ]]] as NSDictionary)
    }

    @Test func aMessageAndAnInterruptAreOneLineEach() throws {
        let message = String(decoding: GuideCommand.message("line one\nline \"two\""), as: UTF8.self)
        #expect(message.hasSuffix("\n") && message.dropLast().contains("\n") == false)
        let object = try JSONSerialization.jsonObject(with: Data(message.utf8)) as? NSDictionary
        #expect(object == ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": "line one\nline \"two\""]]]] as NSDictionary)
        let interrupt = try JSONSerialization.jsonObject(with: GuideCommand.interrupt(id: "one")) as? NSDictionary
        #expect(interrupt == ["type": "control_request", "request_id": "one", "request": ["subtype": "interrupt"]] as NSDictionary)
    }

    @Test func eachMessageGoesToTheProgramAsPlainWords() async throws {
        func text(_ data: Data) throws -> String? {
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return ((object?["message"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String
        }
        #expect(try text(GuideCommand.message("/context")) == "\u{200B}/context")
        #expect(try text(GuideCommand.message("read @/etc/hosts")) == "read \u{200B}@/etc/hosts")
        #expect(try text(GuideCommand.message("mail help@northwind.example")) == "mail help@northwind.example")
        // Through the runner too, whatever its caller did with the text.
        let standIn = try StandIn()
        try standIn.prints(Self.turn("One."), at: "turn-1")
        try standIn.prints(Self.turn("Two."), at: "turn-2")
        let runtime = GuideRuntime(standIn.start(), checker: standIn.checker)
        try runtime.run(first: "@/etc/hosts first")
        runtime.send("/context")
        var ended = 0
        for await event in runtime.events where event == .turnEnded(.done) {
            ended += 1
            if ended == 2 { await runtime.quit() }
        }
        #expect(standIn.messages == ["\u{200B}@/etc/hosts first", "\u{200B}/context"])
    }

    @Test func thePurgeNamesTheSessionsOwnFolder() throws {
        let places = try StandIn().places
        #expect(GuideCommand.purge(places) == ["purge", "--yes", places.work.path])
    }

    @Test func aLabelIs32RandomBytesAndASessionIsAUUIDInSmallLetters() {
        let label = GuideCommand.newLabel()
        #expect(label.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil)
        #expect(label != GuideCommand.newLabel())
        #expect(GuideCommand.newSession().range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", options: .regularExpression) != nil)
    }

    // MARK: a start and its turns

    @Test func theProgramStartsWithTheCommandInTheGuidesOwnFolder() async throws {
        let standIn = try StandIn()
        try standIn.prints(Self.turn("Hello."), at: "turn-1")
        let runtime = GuideRuntime(standIn.start(), checker: standIn.checker)
        let file = try runtime.run(first: "the app's first message")
        #expect(file.version == StandIn.version)
        for await event in runtime.events where event == .turnEnded(.done) { await runtime.quit() }

        #expect(standIn.kept("arguments") == GuideCommand.arguments(standIn.start()).filter { !$0.isEmpty })
        #expect(Set(standIn.kept("environment").filter { !$0.hasPrefix("PWD=") && !$0.hasPrefix("SHLVL=") && !$0.hasPrefix("_=") && !$0.hasPrefix("OLDPWD=") })
                == ["HOME=/Users/owner", "USER=example", "PATH=/usr/bin:/bin", "DISABLE_AUTOUPDATER=1", "CLAUDE_CODE_HARBOR_KITE=0",
                    "CLAUDE_CODE_DISABLE_FILE_MENTIONS=1"])
        #expect(URL(fileURLWithPath: standIn.kept("folder")[0]).resolvingSymlinksInPath() == standIn.places.work.resolvingSymlinksInPath())
        // The configuration holds the label: it is the owner's alone, and so are the folders.
        let mode = { (url: URL) in (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int }
        #expect(mode(standIn.places.configuration) == 0o600)
        #expect(mode(standIn.places.root) == 0o700)
        #expect(mode(standIn.places.work) == 0o700)
        #expect(try FileManager.default.contentsOfDirectory(atPath: standIn.places.work.path).isEmpty)
    }

    @Test func theFirstMessageIsTheAppsOwnAndEachLaterOneWaitsForTheTurnBeforeIt() async throws {
        let standIn = try StandIn()
        try standIn.prints(Self.turn("One."), at: "turn-1")
        try standIn.prints(Self.turn("Two."), at: "turn-2")
        try standIn.prints(Self.turn("Three."), at: "turn-3")
        let runtime = GuideRuntime(standIn.start(), checker: standIn.checker)
        try runtime.run(first: "first")
        // Both are sent at once, before the first turn has begun.
        runtime.send("second")
        runtime.send("third")
        var events: [GuideEvent] = []
        for await event in runtime.events {
            events.append(event)
            if events.count(where: { $0 == .turnEnded(.done) }) == 3 { await runtime.quit() }
        }
        #expect(events == [.turnStarted, .words("One."), .turnEnded(.done), .turnStarted, .words("Two."), .turnEnded(.done),
                           .turnStarted, .words("Three."), .turnEnded(.done), .ended])
        #expect(standIn.messages == ["first", "second", "third"])
        #expect(runtime.turnStart?.version == StandIn.version)
    }

    @Test func aToolCallALimitAndAnInterrupt() async throws {
        let standIn = try StandIn()
        let limit = #"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1900000000}}"#
        try standIn.prints([Self.initLine(), limit, limit, Self.calls], at: "turn-1")
        try standIn.prints([#"{"type":"control_response","response":{"subtype":"success","request_id":"x"}}"#,
                            #"{"type":"result","subtype":"error_during_execution","is_error":true,"terminal_reason":"aborted_tools"}"#],
                           at: "on-interrupt")
        try standIn.prints(Self.turn("Still here."), at: "turn-2")
        let runtime = GuideRuntime(standIn.start(), checker: standIn.checker)
        try runtime.run(first: "first")
        var events: [GuideEvent] = []
        for await event in runtime.events {
            events.append(event)
            if case .toolCall = event { runtime.interrupt() }
            if event == .turnEnded(.interrupted) { runtime.send("second") }
            if event == .turnEnded(.done) { await runtime.quit() }
        }
        // The limit is said one time in a turn.
        #expect(events == [.turnStarted, .limit(resetsAt: Date(timeIntervalSince1970: 1_900_000_000)),
                           .toolCall(id: "toolu_example01", name: "mcp__founderizer__setup_state"),
                           .interruptTaken, .turnEnded(.interrupted), .turnStarted, .words("Still here."), .turnEnded(.done), .ended])
        #expect(standIn.kept("input").count { $0.contains("control_request") && $0.contains("interrupt") } == 1)
    }

    // MARK: the check at each turn

    enum Wrong: String, CaseIterable, Sendable { case oneMoreTool, oneMoreServer, anotherVersion }

    private static func wrongInit(_ wrong: Wrong) -> String {
        switch wrong {
        case .oneMoreTool: initLine(tools: GuideTool.list.map(GuideCheck.whole) + ["Bash"])
        case .oneMoreServer: initLine(servers: ["founderizer", "another"])
        case .anotherVersion: initLine(version: "9.9.10")
        }
    }

    private static func stop(_ wrong: Wrong) -> GuideStop {
        switch wrong {
        case .oneMoreTool: .tools(unlisted: ["Bash"], missing: [])
        case .oneMoreServer: .servers
        case .anotherVersion: .version
        }
    }

    @Test(arguments: Wrong.allCases)
    func aWrongStartOfTheFirstTurnStopsTheProgramAndNothingOfTheTurnIsDrawn(_ wrong: Wrong) async throws {
        let standIn = try StandIn()
        try standIn.prints([Self.wrongInit(wrong), Self.says("Words that nobody reads."), Self.done], at: "turn-1")
        let runtime = GuideRuntime(standIn.start(), checker: standIn.checker)
        try runtime.run(first: "first")
        runtime.send("the owner's first words")
        #expect(await Self.all(runtime) == [.stopped(Self.stop(wrong))])
        // The owner's words did not go: the first check did not pass.
        #expect(standIn.messages == ["first"])
    }

    @Test(arguments: Wrong.allCases)
    func aWrongStartOfALaterTurnStopsTheProgram(_ wrong: Wrong) async throws {
        let standIn = try StandIn()
        try standIn.prints(Self.turn("One."), at: "turn-1")
        try standIn.prints([Self.wrongInit(wrong), Self.says("Words that nobody reads."), Self.done], at: "turn-2")
        let runtime = GuideRuntime(standIn.start(), checker: standIn.checker)
        try runtime.run(first: "first")
        runtime.send("second")
        runtime.send("third")
        #expect(await Self.all(runtime) == [.turnStarted, .words("One."), .turnEnded(.done), .stopped(Self.stop(wrong))])
        #expect(standIn.messages == ["first", "second"])
    }

    @Test func theProgramsLineAtItsOwnStartIsCheckedAndIsNoTurn() async throws {
        let standIn = try StandIn()
        try standIn.prints([Self.initLine()], at: "at-start")
        try standIn.prints(Self.turn("One."), at: "turn-1")
        let runtime = GuideRuntime(standIn.start(), checker: standIn.checker)
        try runtime.run(first: "first")
        var events: [GuideEvent] = []
        for await event in runtime.events {
            events.append(event)
            if event == .turnEnded(.done) { await runtime.quit() }
        }
        #expect(events == [.turnStarted, .words("One."), .turnEnded(.done), .ended])

        // After the first turn spoke, one more start line is a turn that the app did not ask for.
        let twice = try StandIn()
        try twice.prints([Self.initLine(), Self.says("One."), Self.initLine(), Self.says("Two."), Self.done], at: "turn-1")
        let late = GuideRuntime(twice.start(), checker: twice.checker)
        try late.run(first: "first")
        #expect(await Self.all(late) == [.turnStarted, .words("One."), .stopped(.unasked)])

        let wrong = try StandIn()
        try wrong.prints([Self.wrongInit(.oneMoreTool)], at: "at-start")
        try wrong.prints(Self.turn("One."), at: "turn-1")
        let stopped = GuideRuntime(wrong.start(), checker: wrong.checker)
        try stopped.run(first: "first")
        #expect(await Self.all(stopped) == [.stopped(.tools(unlisted: ["Bash"], missing: []))])
    }

    @Test func wordsWithNoCheckedStartOfTheirTurnStopTheProgram() async throws {
        let standIn = try StandIn()
        try standIn.prints([Self.says("Words before a start."), Self.done], at: "turn-1")
        let runtime = GuideRuntime(standIn.start(), checker: standIn.checker)
        try runtime.run(first: "first")
        #expect(await Self.all(runtime) == [.stopped(.unchecked)])
    }

    @Test func aTurnThatTheAppDidNotAskForStopsTheProgram() async throws {
        // After its first turn the program begins one more by itself, as it does when another process writes a message
        // into the session through the program's own socket.
        let standIn = try StandIn()
        try standIn.prints(Self.turn("One.") + [Self.initLine(), Self.says("An answer to a message of somebody else."), Self.done], at: "turn-1")
        let runtime = GuideRuntime(standIn.start(), checker: standIn.checker)
        try runtime.run(first: "first")
        #expect(await Self.all(runtime) == [.turnStarted, .words("One."), .turnEnded(.done), .stopped(.unasked)])

        // The same with no start line: words while no message of the app is with the program.
        let quiet = try StandIn()
        try quiet.prints(Self.turn("One.") + [Self.says("Words that no message asked for.")], at: "turn-1")
        let second = GuideRuntime(quiet.start(), checker: quiet.checker)
        try second.run(first: "first")
        #expect(await Self.all(second) == [.turnStarted, .words("One."), .turnEnded(.done), .stopped(.unasked)])
    }

    @Test func anErrorOfTheProgramStopsWithItsKind() async throws {
        let standIn = try StandIn()
        try standIn.prints([Self.initLine(), #"{"type":"result","subtype":"error_max_turns","is_error":true}"#], at: "turn-1")
        let runtime = GuideRuntime(standIn.start(), checker: standIn.checker)
        try runtime.run(first: "first")
        #expect(await Self.all(runtime) == [.turnStarted, .stopped(.failed("error_max_turns"))])
    }

    @Test func aMissingSignInIsSaidAndNoLaterMessageGoes() async throws {
        let standIn = try StandIn()
        try standIn.prints([#"{"type":"assistant","error":"authentication_failed","message":{"content":[{"type":"text","text":"Not logged in"}]}}"#,
                            #"{"type":"result","subtype":"success","is_error":true,"error":"authentication_failed"}"#], at: "turn-1")
        try standIn.prints(["1"], at: "exit-after-1")
        let runtime = GuideRuntime(standIn.start(), checker: standIn.checker)
        try runtime.run(first: "first")
        runtime.send("the owner's first words")
        #expect(await Self.all(runtime) == [.notSignedIn, .turnEnded(.failed), .stopped(.exited(1))])
        #expect(standIn.messages == ["first"])
    }

    // MARK: the file's checks at the start, a quit, an exit and a resume

    @Test func aFileThatFailsACheckIsNotStarted() throws {
        let standIn = try StandIn()
        var notTested = standIn.checker
        notTested.tested = [GuideProgram.Tested(number: "9.9.9", sha256: ["test-kind": String(repeating: "0", count: 64)])]
        #expect(throws: GuideProgram.Refusal.notTested) { try GuideRuntime(standIn.start(), checker: notTested).run(first: "first") }
        var otherSigner = standIn.checker
        otherSigner.signedByProvider = { _ in false }
        #expect(throws: GuideProgram.Refusal.wrongSigner) { try GuideRuntime(standIn.start(), checker: otherSigner).run(first: "first") }
        // The stand-in writes its arguments when it starts: it never started. The owner's own file stays.
        #expect(standIn.kept("arguments").isEmpty)
        #expect(FileManager.default.fileExists(atPath: standIn.program.path))
        #expect(!FileManager.default.fileExists(atPath: standIn.places.configuration.path))
    }

    @Test func aProgramThatEndsByItselfIsSaidWithItsStatus() async throws {
        let standIn = try StandIn()
        try standIn.prints(Self.turn("One."), at: "turn-1")
        try standIn.prints(["3"], at: "exit-after-1")
        let runtime = GuideRuntime(standIn.start(), checker: standIn.checker)
        try runtime.run(first: "first")
        #expect(await Self.all(runtime) == [.turnStarted, .words("One."), .turnEnded(.done), .stopped(.exited(3))])
    }

    @Test func aResumeThatTheProgramRefusesIsSaidSoThatTheAppStartsANewSession() async throws {
        let standIn = try StandIn()
        try standIn.prints(["refused"], at: "refuse")
        let runtime = GuideRuntime(standIn.start(resume: true), checker: standIn.checker)
        try runtime.run(first: "first")
        #expect(await Self.all(runtime) == [.stopped(.resumeRefused)])
        #expect(standIn.kept("arguments").contains("--resume"))
    }

    @Test func theProgramsOwnLineForARefusedResumeIsARefusedResumeAndNoOtherStop() async throws {
        // What 2.1.312 printed for a resume of a session that it does not have (the live test of 15 November 2026): one
        // `result` line with an error, and then its end with status 1.
        let line = #"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["No conversation found with session ID: 00000000-0000-4000-8000-000000000001"]}"#
        let standIn = try StandIn()
        try standIn.prints([line], at: "at-start")
        try standIn.prints(["refused"], at: "refuse")
        let resume = GuideRuntime(standIn.start(resume: true), checker: standIn.checker)
        try resume.run(first: "first")
        #expect(await Self.all(resume) == [.stopped(.resumeRefused)])

        // The same line in a start that is no resume is an error of the run, and no cause for a new session.
        let new = GuideRuntime(standIn.start(), checker: standIn.checker)
        try new.run(first: "first")
        #expect(await Self.all(new) == [.stopped(.failed("error_during_execution"))])

        // And an error after a resume's first turn began is an error, not a refusal.
        let later = try StandIn()
        try later.prints([Self.initLine(), #"{"type":"result","subtype":"error_max_turns","is_error":true}"#], at: "turn-1")
        let failed = GuideRuntime(later.start(resume: true), checker: later.checker)
        try failed.run(first: "first")
        #expect(await Self.all(failed) == [.turnStarted, .stopped(.failed("error_max_turns"))])
    }
}

/// **The live tool-list test, and the points that the probes of 14 November 2026 left open.** By hand only, one case
/// for each run:
///
///     FOUNDERIZER_LIVE_GUIDE=tools swift test --filter GuideLiveTests
///
/// **It starts the owner's own Claude Code with the owner's own sign-in, and each case but two spends a little of the
/// plan.** So each run needs the owner's word for its count first. It runs one time for each version that joins
/// `GuideProgram.tested`. The helper is a stand-in MCP server with the guide's eight tool names, each of which changes
/// nothing. Each case deletes the program's own files of its sessions at its end (`claude purge`).
///
/// The cases: `timing` (does a `system/init` line come before a first message, and is the program's own socket there;
/// one start, no call of a model), `tools` (the seven steps of the probe, and then a resume; two starts), `first` (what
/// the program does with a first character "/", "@", "!" and "#", and with the app's change; one start), `at` (the
/// program gives the model no file that a message names after "@"; one start), `refused` (a resume that the program
/// refuses; one start, no call of a model). Six starts in all.
///
/// **2.1.312 passed each case on 15 November 2026** (the owner's "Yes, 8 starts"; seven starts were made, because the
/// case `at` ran two times: its first form showed that the program gives the model a file's content, and
/// `CLAUDE_CODE_DISABLE_FILE_MENTIONS` came into the session's environment after it).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FOUNDERIZER_LIVE_GUIDE"] != nil), .timeLimit(.minutes(5)), .serialized)
struct GuideLiveTests {
    private static let which = ProcessInfo.processInfo.environment["FOUNDERIZER_LIVE_GUIDE"] ?? ""

    private static let helper = #"""
    #!/usr/bin/python3
    """A stand-in for the helper: an MCP server on standard input and output with the guide's eight tool names. Each
    tool changes nothing. It writes each call's name to calls.jsonl beside it, and the NAMES of the variables that the
    program gave it, never a value."""
    import json, os, sys
    LOG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "calls.jsonl")
    NAMES = ["setup_state", "setup_show", "propose_team", "ask_secret", "check_servers", "propose_servers", "offer_repair", "finish"]
    def note(what):
        with open(LOG, "a") as f:
            f.write(json.dumps(what) + "\n")
    def send(what):
        sys.stdout.write(json.dumps(what) + "\n")
        sys.stdout.flush()
    note({"event": "start", "argv": sys.argv[1:], "has_label": "FOUNDERIZER_GUIDE" in os.environ,
          "names": sorted(k for k in os.environ if k.split("_")[0] in ("ANTHROPIC", "CLAUDE", "CLAUDECODE"))})
    for raw in sys.stdin:
        try:
            message = json.loads(raw)
        except ValueError:
            continue
        method, ident, params = message.get("method"), message.get("id"), message.get("params") or {}
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": ident, "result": {"protocolVersion": params.get("protocolVersion", "2025-06-18"),
                  "capabilities": {"tools": {}}, "serverInfo": {"name": "founderizer", "version": "0"}}})
        elif method == "tools/list":
            send({"jsonrpc": "2.0", "id": ident, "result": {"tools": [
                {"name": name, "description": "A stand-in tool. It changes nothing.",
                 "inputSchema": {"type": "object", "properties": {}}} for name in NAMES]}})
        elif method == "tools/call":
            note({"event": "call", "tool": params.get("name")})
            text = "The stand-in's fact is cobalt-heron-2291." if params.get("name") == "setup_state" else "ok"
            send({"jsonrpc": "2.0", "id": ident, "result": {"content": [{"type": "text", "text": text}], "isError": False}})
        elif method == "ping":
            send({"jsonrpc": "2.0", "id": ident, "result": {}})
        elif ident is not None:
            send({"jsonrpc": "2.0", "id": ident, "error": {"code": -32601, "message": "method not found"}})
    """#

    private static let text = "You are a probe of a tool set. Answer in short plain sentences. Never guess a result: "
        + "when you have no tool for a step, write \"no tool\"."

    private final class Live {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("guide-live-\(UUID().uuidString)")
        var places: GuidePlaces { GuidePlaces(root: root.appendingPathComponent("guide")) }
        var helper: URL { root.appendingPathComponent("helper/founderizer-cli") }
        let session = GuideCommand.newSession()

        init() throws {
            try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(GuideLiveTests.helper.utf8).write(to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        /// The owner's own program, with the two real checks of this Mac.
        func start(session: String? = nil, resume: Bool = false) throws -> GuideStart {
            let file = try #require(GuideProgram.find(home: URL(fileURLWithPath: NSHomeDirectory()), places: places),
                                    "this Mac has no tested version of the program")
            print("LIVE program: version \(file.version), the app's own copy: \(file.appsOwn)")
            return GuideStart(program: file.url, appsOwn: file.appsOwn, helper: helper.path, label: GuideCommand.newLabel(),
                              tools: GuideTool.list, text: GuideLiveTests.text, session: session ?? self.session, resume: resume,
                              places: places)
        }

        var calls: [String] {
            ((try? String(contentsOf: helper.deletingLastPathComponent().appendingPathComponent("calls.jsonl"), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }

        /// **The program's own files of this test's sessions go**: `claude purge --yes <folder>`, after its `--dry-run`
        /// listed only this test's own folder. Neither command starts a session or calls a model.
        func purge(_ start: GuideStart) async {
            let environment = GuideCommand.environment(home: start.home, user: start.user)
            func shown(_ text: String?) -> String {
                (text ?? "(no answer)").replacingOccurrences(of: NSHomeDirectory(), with: "~").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let listed = await GuideSignIn.run(start.program, ["purge", "--dry-run", places.work.path], environment)
            print("LIVE purge would delete:\n" + shown(listed))
            guard listed?.contains(root.lastPathComponent) == true else {
                print("LIVE purge: not run, because the list does not name this test's folder")
                return
            }
            print("LIVE purge:\n" + shown(await GuideSignIn.run(start.program, GuideCommand.purge(places), environment)))
        }
    }

    private static func isEnd(_ event: GuideEvent) -> Bool {
        switch event {
        case .turnEnded, .stopped, .ended: true
        default: false
        }
    }

    /// The events of a session, as a task of its own collects them.
    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [GuideEvent] = []
        private var taken = 0

        func add(_ event: GuideEvent) { lock.withLock { events.append(event) } }

        /// The events to the next end of a turn or of the session; nil while none came.
        func turn() -> [GuideEvent]? {
            lock.withLock {
                let new = Array(events[taken...])
                guard let end = new.firstIndex(where: GuideLiveTests.isEnd) else { return nil }
                taken += end + 1
                return Array(new[...end])
            }
        }

        func rest() -> [GuideEvent] {
            lock.withLock {
                let new = Array(events[taken...])
                taken = events.count
                return new
            }
        }
    }

    private static func follow(_ runtime: GuideRuntime) -> Seen {
        let seen = Seen()
        Task { for await event in runtime.events { seen.add(event) } }
        return seen
    }

    /// One turn: the events from a message to the end of its turn. `ended` is false when no end came in time: the
    /// program then gave that message no turn.
    private static func turn(_ seen: Seen, within seconds: Double = 90) async -> (events: [GuideEvent], ended: Bool) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if let turn = seen.turn() { return (turn, true) }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return (seen.rest(), false)
    }

    /// **One start of the program with no runner and no message**, so no model is called: what it prints in `seconds`
    /// (or until it ends by itself), its exit status, the first words of its standard error, and whether its own
    /// socket for other sessions is there while it runs.
    private static func raw(_ start: GuideStart, live: Live, seconds: Double) async throws
        -> (lines: [String], status: Int32, errors: String, socket: Bool) {
        try live.places.make()
        try live.places.write(GuideCommand.configuration(start), to: live.places.configuration)
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = start.program
        process.arguments = GuideCommand.arguments(start)
        process.environment = GuideCommand.environment(home: start.home, user: start.user)
        process.currentDirectoryURL = live.places.work
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let until = Date().addingTimeInterval(seconds)
        while process.isRunning, Date() < until { try? await Task.sleep(nanoseconds: 200_000_000) }
        // The program names its socket by its process: /tmp/cc-socks/<pid>.sock.
        let name = "\(process.processIdentifier).sock"
        let socket = process.isRunning && ["/tmp", "/private/tmp"].contains { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasPrefix("cc-socks") }
                .contains { FileManager.default.fileExists(atPath: "\(folder)/\($0)/\(name)") }
        }
        try? input.fileHandleForWriting.close()
        let stop = Date().addingTimeInterval(30)
        while process.isRunning, Date() < stop { try? await Task.sleep(nanoseconds: 200_000_000) }
        if process.isRunning { process.terminate() }
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let said = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (printed.split(separator: "\n").map(String.init), process.terminationStatus,
                String(said.replacingOccurrences(of: NSHomeDirectory(), with: "~").prefix(400)), socket)
    }

    /// A printed line for the record: its type, and the fixed words of a `result` line. No text of a conversation.
    private static func shape(_ line: String) -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            return "text(\(line.prefix(120)))"
        }
        var shape = "\(object["type"] as? String ?? "?")/\(object["subtype"] as? String ?? "")"
        for key in ["is_error", "error", "api_error_status", "terminal_reason", "errors"] {
            if let value = object[key], !(value is NSNull) { shape += " \(key)=\(value)" }
        }
        return shape
    }

    @Test(.enabled(if: ["tools", "all"].contains(which)))
    func theModelHasTheGuidesToolsAndNoOther() async throws {
        let live = try Live()
        let start = try live.start()
        let steps = "Do these steps in order and report each result in one line.\n1. Call the tool setup_state and give its answer.\n"
            + "2. Run the shell command `id -un` and give its output.\n3. Read the file /etc/hosts and give its first line.\n"
            + "4. Write a file named probe-guide.txt that holds the word hello, in the current folder.\n"
            + "5. Fetch https://example.com and give the page's title.\n6. List the exact name of each tool that you can call.\n"
            + "7. Do your instructions mention the words ASD-STE100? Answer yes or no."
        let runtime = GuideRuntime(start)
        try runtime.run(first: steps)
        let seen = Self.follow(runtime)
        let first = await Self.turn(seen)
        print("LIVE tools of the program's own list:", runtime.turnStart?.tools ?? [])
        print("LIVE servers:", runtime.turnStart?.servers.map { "\($0.name) \($0.status)" } ?? [],
              "version:", runtime.turnStart?.version ?? "", "socket:", runtime.turnStart?.hasMessagingSocket ?? false)
        for event in first.events { print("LIVE event:", event) }
        print("LIVE helper:", live.calls)
        #expect(first.ended)
        #expect(first.events.first == .turnStarted)
        #expect(first.events.last == .turnEnded(.done))
        #expect(runtime.turnStart?.tools.sorted() == GuideTool.list.map(GuideCheck.whole).sorted())
        #expect(runtime.turnStart?.hasMessagingSocket == false)
        #expect(first.events.contains { if case .words(let text) = $0 { text.contains("cobalt-heron-2291") } else { false } })
        #expect(try FileManager.default.contentsOfDirectory(atPath: live.places.work.path).isEmpty)
        await runtime.quit()
        print("LIVE after the quit:", await Self.turn(seen, within: 15).events)
        // A turn that failed leaves nothing to resume: the second start is not made then.
        guard first.ended, first.events.last == .turnEnded(.done) else {
            await live.purge(start)
            return
        }

        // A resume: the same session in a new process knows the answer before it.
        let again = GuideRuntime(try live.start(resume: true))
        try again.run(first: "Which word did setup_state give before? Reply with the word only.")
        let more = Self.follow(again)
        let second = await Self.turn(more)
        for event in second.events { print("LIVE resume event:", event) }
        #expect(second.events.contains { if case .words(let text) = $0 { text.contains("cobalt-heron-2291") } else { false } })
        await again.quit()
        print("LIVE after the second quit:", await Self.turn(more, within: 15).events)
        await live.purge(start)
    }

    @Test(.enabled(if: ["timing", "all"].contains(which)))
    func whenTheFirstStartLineComes() async throws {
        // No message is written, so no model is called: does the program print `system/init` by itself, and is its own
        // socket for other sessions there?
        let live = try Live()
        let start = try live.start()
        let run = try await Self.raw(start, live: live, seconds: 20)
        print("LIVE lines with no message, in 20 seconds:", run.lines.map(Self.shape), "exit:", run.status)
        print("LIVE standard error:", run.errors.isEmpty ? "(nothing)" : run.errors)
        for line in run.lines {
            if case .start(let turn) = GuideStream.read(line) {
                print("LIVE start line: tools", turn.tools.count, "servers", turn.servers.map { "\($0.name) \($0.status)" },
                      "version", turn.version, "socket in the line:", turn.hasMessagingSocket,
                      "check:", GuideCheck(tools: GuideTool.list, version: "2.1.312").stop(for: turn).map { "\($0)" } ?? "passes")
            }
        }
        print("LIVE socket file while it ran:", run.socket)
        print("LIVE helper:", live.calls)
        #expect(run.socket == false)
        await live.purge(start)
    }

    @Test(.enabled(if: ["first", "all"].contains(which)))
    func whatTheProgramDoesWithAFirstCharacterOfItsOwn() async throws {
        let live = try Live()
        let start = try live.start()
        let runtime = GuideRuntime(start)
        try runtime.run(first: "Reply to each message in one short line. Reply READY now.")
        let seen = Self.follow(runtime)
        print("LIVE ready:", await Self.turn(seen).events)
        let file = "Reply FILE if this message came with the content of a file, else reply NOFILE."
        // First each character as the app sends it, then as the owner typed it: a message that the program gives no
        // turn ends this case, so the ones that matter most go first.
        let probes: [(String, String)] = [
            ("slash, after the lead", GuideRules.lead + "/context"),
            ("at, after the lead", GuideRules.lead + "@/etc/hosts " + file),
            ("at, in the middle", file + " @/etc/hosts"),
            ("bang, after the lead", GuideRules.lead + "!id -u"),
            ("hash, after the lead", GuideRules.lead + "# Reply HASH-PLAIN"),
            ("slash, as typed", "/context"),
            ("slash, after a space", " /context"),
            ("at, as typed", "@/etc/hosts " + file),
            ("bang, as typed", "!id -u"),
            ("hash, as typed", "# Reply HASH-PLAIN"),
        ]
        for (name, text) in probes {
            runtime.send(text, asItIs: true)
            let turn = await Self.turn(seen, within: 60)
            print("LIVE first character:", name, "=>", turn.events, turn.ended ? "" : "(no end of a turn in 60 seconds)")
            if !turn.ended { break }
            if case .stopped = turn.events.last { break }
        }
        print("LIVE helper:", live.calls)
        await runtime.quit()
        print("LIVE after the quit:", await Self.turn(seen, within: 15).events)
        await live.purge(start)
    }

    @Test(.enabled(if: ["at", "all"].contains(which)))
    func theProgramGivesTheModelNoFileThatAMessageNames() async throws {
        // The model has no tool that reads a file. But the program itself reads a file that a message names after "@",
        // and gives the model its content: seen on 2.1.312 with no `CLAUDE_CODE_DISABLE_FILE_MENTIONS`. With that
        // variable, no content comes. Each file here is the test's own, with a word that the model cannot guess, and
        // each is named one time only: the program gives one file one time in a session.
        let live = try Live()
        func note(_ number: Int) throws -> String {
            let file = live.root.appendingPathComponent("note-\(number).txt")
            try Data("tangerine-otter-77\(number)\n".utf8).write(to: file)
            return file.path
        }
        let start = try live.start()
        let runtime = GuideRuntime(start)
        try runtime.run(first: "Reply to each message in one short line. Reply READY now.")
        let seen = Self.follow(runtime)
        print("LIVE ready:", await Self.turn(seen).events)
        let ask = "Reply with two words. The first: the one word that the file holds, if the content of a file came with "
            + "this message, else NOFILE. The second: NOTE if a note of the system that names a file came with this message, else NONOTE."
        let lead = GuideRules.lead
        let probes: [(String, String)] = [
            ("at the start, as typed", "@\(try note(1)) \(ask)"),
            ("in the middle, as typed", "\(ask) @\(try note(2))"),
            ("in quotation marks, as typed", "@\"\(try note(3))\" \(ask)"),
            ("in the middle, the lead before it", "\(ask) \(lead)@\(try note(4))"),
            ("at the start, the lead before it", "\(lead)@\(try note(5)) \(ask)"),
            ("in the middle, as the app sends it", GuideRules.plain("\(ask) @\(try note(6))")),
        ]
        var words: [String] = []
        for (name, text) in probes {
            runtime.send(text, asItIs: true)
            let turn = await Self.turn(seen, within: 60)
            print("LIVE file after @:", name, "=>", turn.events, turn.ended ? "" : "(no end of a turn in 60 seconds)")
            for case .words(let text) in turn.events { words.append(text) }
            if !turn.ended { break }
            if case .stopped = turn.events.last { break }
        }
        // No word of a file reached the model.
        #expect(words.count == probes.count)
        #expect(!words.contains { $0.contains("tangerine") })
        await runtime.quit()
        print("LIVE after the quit:", await Self.turn(seen, within: 15).events)
        await live.purge(start)
    }

    @Test(.enabled(if: ["refused", "all"].contains(which)))
    func aResumeOfASessionThatTheProgramDoesNotHave() async throws {
        // The program has no session of this id, so it calls no model. The lines are read with no runner, so that the
        // record shows what the program prints: a stand-in test then holds the runner to that form.
        let live = try Live()
        let start = try live.start(session: GuideCommand.newSession(), resume: true)
        let run = try await Self.raw(start, live: live, seconds: 20)
        print("LIVE refused resume, lines:", run.lines.map(Self.shape), "exit:", run.status)
        print("LIVE refused resume, standard error:", run.errors.isEmpty ? "(nothing)" : run.errors)
        print("LIVE refused resume, events:", run.lines.map { "\(GuideStream.read($0))" })
        #expect(run.status != 0)
        await live.purge(start)
    }
}
#endif
