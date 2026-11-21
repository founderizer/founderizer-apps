import Foundation
import Testing
@testable import FleetOwnerAPI

/// **A session's calls after an app update go to the new program** (`ProgramRelay`), as a new session would make them,
/// unless the client's list is old for the tool, and never twice. Until 20 November 2026 each call of such a session
/// was refused, and the app takes many versions a day. The in-test child is the real MCP server (`OwnerMCP`) of a
/// stand-in's tools, on line queues; the last tests start real child processes.
final class OwnerRelayTests {
    let home = Fixture.home()
    deinit { try? FileManager.default.removeItem(at: home) }

    /// Lines from an in-test child to the relay: each read waits for the next line, the child's end, or its deadline.
    final class Lines: @unchecked Sendable {
        private let condition = NSCondition()
        private var lines: [String] = []
        private var closed = false

        func put(_ line: String) {
            condition.lock()
            lines.append(line)
            condition.signal()
            condition.unlock()
        }

        func close() {
            condition.lock()
            closed = true
            condition.broadcast()
            condition.unlock()
        }

        func take(until deadline: Date) -> String? {
            condition.lock()
            defer { condition.unlock() }
            while lines.isEmpty && !closed {
                if !condition.wait(until: deadline) { return nil }
            }
            return lines.isEmpty ? nil : lines.removeFirst()
        }
    }

    /// A number that the closures of a test change.
    final class Value: @unchecked Sendable {
        private let lock = NSLock()
        private var number: Int
        init(_ number: Int) { self.number = number }
        var value: Int {
            get { lock.lock(); defer { lock.unlock() }; return number }
            set { lock.lock(); number = newValue; lock.unlock() }
        }
    }

    static let path = "/Applications/Founderizer.app/Contents/MacOS/founderizer-cli"

    /// The relay to an in-test new program, whose tools `newTools` gives at each start. `starts`, `stops` and `calls`
    /// count the children's starts and stops and the tools/call lines that reached them; `endAtCall`: each child ends
    /// when it reads a tools/call, with no answer.
    private func relay(build: Value, newTools: @escaping @Sendable () -> OwnerTools, starts: Value = Value(0),
                       stops: Value = Value(0), calls: Value = Value(0), endAtCall: Bool = false) -> ProgramRelay {
        ProgramRelay(path: Self.path, build: { build.value }, launch: {
            starts.value += 1
            let lines = Lines()
            let server = OwnerMCP(tools: newTools(), version: "new", sink: { lines.put($0) })
            return .child(ProgramRelay.Child(send: { line in
                                          if line.contains("\"tools/call\"") {
                                              calls.value += 1
                                              if endAtCall { lines.close(); return true }
                                          }
                                          server.take(line: line)
                                          return true
                                      },
                                      receive: { lines.take(until: $0) },
                                      stop: { stops.value += 1; lines.close() }))
        }, version: "old")
    }

    /// The fixture's table with one tool changed, or without it (`change` gives nil).
    private func table(_ name: String, _ change: (OwnerTable.Tool) -> OwnerTable.Tool?) -> OwnerTable {
        let t = Fixture.table
        return OwnerTable(tools: t.tools.compactMap { $0.name == name ? change($0) : $0 }, instructions: t.instructions,
                          protocolVersion: t.protocolVersion, supported: t.supported, pages: t.pages,
                          pageQuery: t.pageQuery, pageTakes: t.pageTakes, pageWords: t.pageWords, pageInPath: t.pageInPath,
                          historyWords: t.historyWords, costsWords: t.costsWords, mediaTypes: t.mediaTypes,
                          version: t.version)
    }

    private func tool(_ tool: OwnerTable.Tool, description: String? = nil, inputSchema: JSONValue? = nil,
                      annotations: JSONValue? = nil) -> OwnerTable.Tool {
        OwnerTable.Tool(name: tool.name, description: description ?? tool.description,
                        inputSchema: inputSchema ?? tool.inputSchema, annotations: annotations ?? tool.annotations,
                        kind: tool.kind, route: tool.route, fields: tool.fields, what: tool.what,
                        revisionPage: tool.revisionPage, requestIDFromArguments: tool.requestIDFromArguments,
                        feature: tool.feature, whole: tool.whole, nulls: tool.nulls)
    }

    @Test func aCallAfterAnUpdateGoesToTheNewProgramAndGivesItsWholeResult() throws {
        let hub = StandInHub(features: Fixture.everyFeature)
        let home = self.home
        let build = Value(216), starts = Value(0), stops = Value(0)
        let old = Fixture.tools(hub, home: home, ownBuild: 215, started: { build.value },
                                relay: relay(build: build, newTools: { Fixture.tools(hub, home: home) },
                                             starts: starts, stops: stops))
        let fresh = Fixture.tools(hub, home: home).callResult("fleet_overview", .object([:]))
        let before = hub.seen.count
        #expect(old.callResult("fleet_overview", .object([:])) == fresh)     // as a new session gets it
        #expect(hub.seen.count > before)
        #expect(try old.json("fleet_overview") == (try Fixture.tools(hub, home: home).json("fleet_overview")))
        #expect((starts.value, stops.value) == (1, 0))                          // one child for the session
        build.value = 217                                                       // the app was updated again
        _ = try old.json("fleet_overview")
        #expect((starts.value, stops.value) == (2, 1))                          // the old child is stopped
    }

    @Test func aToolThatTheClientsListIsOldForIsRefusedAndNeverSent() throws {
        let hub = StandInHub(features: Fixture.everyFeature)
        let home = self.home
        let base = Fixture.table
        let overview = try #require(base.tool("fleet_overview"))
        let release = try #require(base.tool("take_release"))
        #expect(overview.annotations["readOnlyHint"] == .bool(true) && release.annotations["readOnlyHint"] != .bool(true))
        let cases: [(OwnerTable, String, String)] = [
            (table("take_release") { self.tool($0, inputSchema: .object(["type": .string("object"), "properties":
                .object(["track": .object(["type": .string("string")])])])) },     // what the client sends to a write
             "take_release", OwnerTools.changed("take_release", path: Self.path)),
            (table("fleet_overview") { self.tool($0, annotations: .object(["readOnlyHint": .bool(false)])) },
             "fleet_overview", OwnerTools.changed("fleet_overview", path: Self.path)),   // a read became a write
            (table("take_release") { self.tool($0, description: $0.description + " It also signs a press.") },
             "take_release", OwnerTools.changed("take_release", path: Self.path)),     // a write's words
            (table("take_release") { self.tool($0, annotations: .object((($0.annotations.object ?? [:])
                .merging(["destructiveHint": .bool(true)]) { $1 }))) },               // another mark of a write
             "take_release", OwnerTools.changed("take_release", path: Self.path)),
            (table("take_release") { _ in nil }, "take_release", OwnerTools.gone("take_release")),
        ]
        for (newTable, name, words) in cases {
            let old = Fixture.tools(hub, home: home, ownBuild: 215, started: { 216 },
                                    relay: relay(build: Value(216), newTools: { Fixture.tools(hub, home: home,
                                                                                              table: newTable) }))
            let before = hub.seen.count
            #expect(old.refused(name, name == "take_release" ? ["request_id": .string(UUID().uuidString)] : [:])
                    == words)
            #expect(hub.seen.count == before)                                   // nothing reached the hub
        }
        // A read changes nothing, and the new program checks its own fields: a read whose words or fields changed still
        // goes (fleet_read's fields changed in 4 of 148 builds in 7 days, and each change ended it in every session).
        let words = table("fleet_overview") { self.tool($0, description: $0.description + " More words.") }
        let fields = table("fleet_overview") { self.tool($0, inputSchema: .object(["type": .string("object"),
            "properties": .object(["agent": .object(["type": .string("string")])])])) }
        for newTable in [words, fields] {
            let old = Fixture.tools(hub, home: home, ownBuild: 215, started: { 216 },
                                    relay: relay(build: Value(216), newTools: { Fixture.tools(hub, home: home, table: newTable) }))
            #expect(try old.json("fleet_overview") == (try Fixture.tools(hub, home: home).json("fleet_overview")))
        }
    }

    @Test func aNewProgramThatDoesNotTakeTheCallSaysThatNothingWasDone() {
        let hub = StandInHub(features: Fixture.everyFeature)
        let relay = ProgramRelay(path: Self.path, build: { 216 }, launch: { .none }, version: "old")
        let old = Fixture.tools(hub, home: home, ownBuild: 215, started: { 216 }, relay: relay)
        #expect(old.refused("fleet_overview")
                == "The Founderizer app was updated, and its new version did not take this call, so nothing was done. "
                + "Start a new session; until then, run \(Self.path) call fleet_overview '<json object>' in a shell.")
        #expect(old.refused("take_release")?.contains("run \(Self.path) write take_release '<json object>'") == true)
        #expect(Fixture.tools(hub, home: home, ownBuild: 215, started: { 216 }).refused("fleet_overview")
                == "The Founderizer app was updated. Start a new session.")       // no relay at all
        // A program behind the path that the check refused: no call goes to it, no command starts it, and it is not
        // started again (its own code runs before each check) until the build behind the path changes.
        let launches = Value(0), build = Value(216)
        let refused = ProgramRelay(path: Self.path, build: { build.value }, launch: {
            launches.value += 1
            return .refused
        }, version: "old")
        let checked = Fixture.tools(hub, home: home, ownBuild: 215, started: { build.value }, relay: refused)
        let words = checked.refused("fleet_overview")
        #expect(words == OwnerTools.untrusted("fleet_overview") && words?.contains(Self.path) == false)
        #expect(checked.refused("fleet_overview") == words && launches.value == 1)
        build.value = 217
        _ = checked.refused("fleet_overview")
        #expect(launches.value == 2)
    }

    @Test func aCallThatTheNewProgramMayHaveCarriedOutIsNeverSentAgain() {
        let hub = StandInHub(features: Fixture.everyFeature)
        let home = self.home
        let calls = Value(0), starts = Value(0)
        let old = Fixture.tools(hub, home: home, ownBuild: 215, started: { 216 },
                                relay: relay(build: Value(216), newTools: { Fixture.tools(hub, home: home) },
                                             starts: starts, calls: calls, endAtCall: true))
        // The words send the agent to read first, and offer no command that sends the call again.
        #expect(old.refused("take_release", ["request_id": .string(UUID().uuidString)])
                == OwnerTools.lost("take_release"))
        #expect((calls.value, starts.value) == (1, 1))
    }

    // ------------------------------------------------------------ real child processes

    /// A stand-in new program as a shell script: it answers only to `mcp --set owner`, logs each tools/call to `log`,
    /// and closes its input before each answer, so the next call finds it ended. A call's arguments steer it: `fail`
    /// answers a refusal, `ping` asks the relay a ping first and says whether it got the answer, `quiet` ends with no
    /// answer, `slow` waits with no answer.
    private func script(log: URL) throws -> URL {
        let script = home.appendingPathComponent("new-cli")
        try """
        #!/bin/sh
        [ "$1 $2 $3" = "mcp --set owner" ] || exit 3
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -nE 's/.*"id": *([0-9]+).*/\\1/p')
          [ -z "$id" ] && continue
          case "$line" in
            *'"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{}}\\n' "$id" ;;
            *'"tools/list"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"a_write","description":"Writes.","inputSchema":{"type":"object"},"annotations":{"readOnlyHint":false}}]}}\\n' "$id" ;;
            *'"tools/call"'*)
              printf '%s\\n' "$line" >> '\(log.path)'
              case "$line" in *quiet*) exit 0 ;; *slow*) exec sleep 60 ;; esac
              text="from the new program"; error=false
              case "$line" in *fail*) text="refused by the new program"; error=true ;; esac
              case "$line" in *ping*)
                printf '{"jsonrpc":"2.0","id":"p1","method":"ping"}\\n'
                IFS= read -r reply
                case "$reply" in *p1*) case "$reply" in *result*) text="pinged" ;; esac ;; esac ;;
              esac
              exec 0<&-
              printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"%s"}],"isError":%s}}\\n' "$id" "$text" "$error"
              exit 0 ;;
          esac
        done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private func answer(_ text: String, error: Bool = false) -> ProgramRelay.Answer {
        .answered(.object(["content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                           "isError": .bool(error)]))
    }

    @Test func aChildProcessIsReplacedWhenItEndedAndNeverGetsACallTwice() throws {
        let log = home.appendingPathComponent("calls.log")
        let script = try script(log: log)
        let relay = ProgramRelay(path: script.path, build: { 216 }, launch: {
            ProgramRelay.process(path: script.path, accepts: { _ in true })
        }, version: "old", startWait: 5, callWait: 1)
        let entry = ProgramRelay.entry(description: "Writes.", inputSchema: .object(["type": .string("object")]),
                                       annotations: .object(["readOnlyHint": .bool(false)]))
        func call(_ word: String) -> ProgramRelay.Answer {
            relay.call("a_write", arguments: .object(["say": .string(word)]), entry: entry, protocolVersion: "2025-06-18")
        }
        #expect(call("one") == answer("from the new program"))
        // That child closed its input: the next call's write fails, this process goes on (a SIGPIPE would end the
        // test run here), and a new child takes the call.
        #expect(call("two") == answer("from the new program"))
        #expect(call("fail") == answer("refused by the new program", error: true))   // its refusal, as it gave it
        #expect(call("ping") == answer("pinged"))          // the child's own request is answered, not read as a reply
        #expect(call("quiet") == .lost)                    // it took the call and ended: the call may have been made
        let asked = Date()
        #expect(call("slow") == .lost)                     // no answer before the deadline of 1 second, of the 60
        #expect(Date().timeIntervalSince(asked) < 20)
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 6)                          // each call reached one child once
        #expect(lines.filter { $0.contains("quiet") }.count == 1 && lines.filter { $0.contains("slow") }.count == 1)
    }

    @Test func aChildThatDoesNotStartInTimeOrIsNotSignedAsThisProgramTakesNothing() throws {
        let script = home.appendingPathComponent("silent-cli")
        try "#!/bin/sh\nexec sleep 60\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let entry = ProgramRelay.entry(description: "", inputSchema: .null, annotations: .null)
        let slow = ProgramRelay(path: script.path, build: { 216 }, launch: {
            ProgramRelay.process(path: script.path, accepts: { _ in true })
        }, version: "old", startWait: 1)
        let asked = Date()
        #expect(slow.call("a_read", arguments: nil, entry: entry, protocolVersion: "2025-06-18") == .silent)
        #expect(Date().timeIntervalSince(asked) < 20)       // the start's deadline of 1 second, of the 60
        // A script runs a program that is signed as no program of the app: the check stops it before any line.
        let requirement = SignatureCheck.requirement(team: "ABCDE12345", identifier: "com.example.cli")
        guard case .refused = ProgramRelay.process(path: script.path,
                                                   accepts: { ProgramRelay.meets($0, requirement: requirement) }) else {
            Issue.record("a child that does not meet the requirement was taken")
            return
        }
        #expect(!ProgramRelay.meets(getpid(), requirement: nil))           // no requirement takes no child
    }
}
