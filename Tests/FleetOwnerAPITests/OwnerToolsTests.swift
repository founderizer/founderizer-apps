import Darwin
import FleetCore
import Foundation
import Testing
@testable import FleetOwnerAPI

/// The table, the requests that each kind of tool builds, the four reads and the refusals, on a stand-in hub that opens
/// no port. Each request expected here is the one that `owner_mcp.py` builds for the same call.
struct OwnerTableTests {
    @Test func theTableIsReadWithEveryKind() throws {
        let table = Fixture.table
        var kinds: [OwnerTable.Kind: Int] = [:]
        for tool in table.tools { kinds[tool.kind, default: 0] += 1 }
        #expect(kinds[.swift] == 13)
        #expect(kinds[.later] == nil)
        #expect(Set(table.tools.filter { $0.kind == .swift }.map(\.name)) == OwnerTools.written)
        #expect(kinds[.absent] == 7)           // the six of the app's own pages, and connect_google (owner API 1.178)
        #expect(table.tools.filter(\.kind.built).count == 55)
        #expect(table.version.count == 64)
        let check = try #require(table.tool("check_machine"))
        #expect(check.kind == .plain && check.route == "/ui/machines/{agent}/check" && check.what == "the machine check")
        #expect(check.firstSentence == "Have one machine take its reading now.")
        let goal = try #require(table.tool("goal_state"))
        #expect(goal.kind == .withRevision && goal.revisionPage == "goal" && goal.feature == "goals")
        #expect(table.tool("which_hub")?.kind == .absent && table.tool("save_profile")?.kind == .swift)
        #expect(table.pages["devices"]?.route == "/ui/owner/devices")
        #expect(table.instructions.contains("Do not ask the owner in the chat"))
    }

    @Test func aTableThatIsNotOneIsRefusedInWords() {
        #expect(throws: OwnerTable.Unreadable.self) { try OwnerTable.parse(Data("{\"tools\": 3}".utf8)) }
        let missing = URL(fileURLWithPath: "/nonexistent/owner-tools.json")
        do {
            _ = try OwnerTable.load(from: missing)
            Issue.record("a missing table was read")
        } catch let unreadable as OwnerTable.Unreadable {
            #expect(unreadable.text.contains("found no table of its tools"))
        } catch {
            Issue.record("\(error)")
        }
    }

    @Test func theStandInIsTheAppsAddressOfNoHub() {
        #expect(OwnerTools.standIn == HubClient.defaultAddress)
        #expect(OwnerTools.hubBase(nil) == nil)
        #expect(OwnerTools.hubBase("") == nil)
        #expect(OwnerTools.hubBase(HubClient.defaultAddress) == nil)
        #expect(OwnerTools.hubBase("http://fleet.invalid:8765/") == nil)
        #expect(OwnerTools.hubBase("not an address") == nil)
        #expect(OwnerTools.hubBase("http://100.64.0.1:8765/") == "http://100.64.0.1:8765")
    }

    @Test func jsonIsWrittenAsPythonWritesIt() throws {
        let value = try #require(JSONValue.parse("{\"b\": [1, 2.5, true, null], \"a\": \"\u{e9}\\n\\\"\", \"c\": {}}"))
        #expect(value.dumps(indent: 1) == "{\n \"a\": \"\\u00e9\\n\\\"\",\n \"b\": [\n  1,\n  2.5,\n  true,\n  null\n ],\n \"c\": {}\n}")
        #expect(value.dumps() == "{\"a\": \"\\u00e9\\n\\\"\", \"b\": [1, 2.5, true, null], \"c\": {}}")
        #expect(JSONValue.parse("3") == .int(3) && JSONValue.parse("3.0") == .double(3) && JSONValue.parse("true") == .bool(true))
        #expect(OwnerHub.urlencode([("db", "g1"), ("query", "a b/c")]) == "db=g1&query=a+b%2Fc")
    }
}

final class OwnerRequestTests {
    let home = Fixture.home()
    deinit { try? FileManager.default.removeItem(at: home) }

    private func posted(_ hub: StandInHub) -> [Seen] { hub.seen.filter { $0.method == "POST" } }

    @Test func aPlainToolSendsItsFieldsToItsRouteWithAnEscapedPart() throws {
        let hub = StandInHub(features: Fixture.everyFeature)
        let tools = Fixture.tools(hub, home: home)
        let answer = try tools.json("check_machine", ["agent": .string("a/b?c")])
        #expect(answer["route"] == .string("/ui/machines/a%2Fb%3Fc/check"))
        let post = try #require(posted(hub).first)
        #expect(post.path == "/ui/machines/a%2Fb%3Fc/check")
        let body = try #require(post.body?.object)
        #expect(Set(body.keys) == ["request_id", "db"])
        #expect(body["db"] == .string("g1"))
        let rid = try #require(body["request_id"]?.string)
        #expect(UUID(uuidString: rid)?.uuidString.lowercased() == rid)
        // The owner API's headers: no Authorization and no Origin, and the program's own label on a command.
        #expect(post.header("Authorization") == nil && post.header("Origin") == nil)
        #expect(post.header("X-Fleet-Client") == "founderizer-cli/1/test")
        #expect(post.header("User-Agent") == "founderizer-cli/test")
        #expect(post.header("Content-Type") == "application/json")
        #expect(hub.seen.first?.path == "/ui/state" && hub.seen.first?.header("X-Fleet-Client") == nil)
    }

    @Test func aPlainToolLeavesANullOutAndTakesTheAgentsRequestID() throws {
        let hub = StandInHub(features: Fixture.everyFeature)
        let tools = Fixture.tools(hub, home: home)
        let rid = "6F1C2A3B-0000-4000-8000-00000000000A"
        _ = try tools.json("control_task", ["task": .int(7), "action": .string("pause"), "note": .null,
                                            "request_id": .string(rid)])
        let post = try #require(posted(hub).first)
        #expect(post.path == "/ui/tasks/7/control")
        #expect(post.body == .object(["action": .string("pause"), "request_id": .string(rid.lowercased()),
                                      "db": .string("g1")]))
        #expect(tools.refused("control_task", ["task": .int(7), "action": .string("pause"),
                                               "request_id": .string("not-one")])
                == "request_id must be a UUID, or absent so that this server makes one.")
        #expect(tools.refused("check_machine") == "give agent: this tool's route needs it, so the command was not sent.")
        #expect(tools.refused("check_machine", ["agent": .null]) == "give agent: this tool's route needs it, so the "
                + "command was not sent.")
    }

    @Test func aToolWithBaseCarriesTheSHA256OfTeamJSONReadJustBefore() throws {
        let hub = StandInHub(features: Fixture.everyFeature)
        let tools = Fixture.tools(hub, home: home)
        _ = try tools.json("activate_agent", ["agent": .string("worker-1"), "active": .bool(true)])
        #expect(hub.seen.map { "\($0.method) \($0.path)" } == ["GET /ui/state", "GET /ui/team",
                                                                "POST /ui/team/agents/worker-1"])
        #expect(hub.seen[1].query == "db=g1")
        let body = try #require(posted(hub).first?.body?.object)
        #expect(body["active"] == .bool(true) && body["base_sha256"] == .string("sha-1") && body["db"] == .string("g1"))
        #expect(Set(body.keys) == ["active", "base_sha256", "request_id", "db"])
    }

    @Test func aToolWithRevisionCarriesTheRevisionOfItsOwnThing() throws {
        let hub = StandInHub(features: Fixture.everyFeature)
        let tools = Fixture.tools(hub, home: home)
        _ = try tools.json("goal_state", ["id": .int(3), "action": .string("pause")])
        #expect(hub.seen.map { "\($0.method) \($0.path)" } == ["GET /ui/state", "GET /ui/goals/3", "POST /ui/goals/3/state"])
        #expect(posted(hub).first?.body?["base_revision"] == .int(12))
        #expect(posted(hub).first?.body?["action"] == .string("pause"))
        hub.revision = .null
        #expect(tools.refused("duty_state", ["id": .int(4), "action": .string("pause")])
                == "the hub gave no revision for responsibility 4, so this change cannot be bound to it.")
        #expect(tools.refused("trigger_state", ["action": .string("pause")])
                == "the page trigger is about one thing: give its id.")
    }

    @Test func aCommandHoldsTheLockForItsOneRequestAndAReadNever() throws {
        let hub = StandInHub(features: Fixture.everyFeature)
        let file = home.appendingPathComponent(".founderizer/lock").path
        hub.answer = { request in
            let handle = open(file, O_RDONLY)               // no file yet: nobody holds the lock
            defer { if handle >= 0 { close(handle) } }
            let free = handle < 0 || flock(handle, LOCK_EX | LOCK_NB) == 0
            if free, handle >= 0 { flock(handle, LOCK_UN) }
            let right = request.method == "POST" ? !free : free
            return right ? nil : (500, .object(["error": .string("the lock was wrong for \(request.method)")]))
        }
        let tools = Fixture.tools(hub, home: home)
        _ = try tools.json("take_release")
        _ = try tools.json("fleet_read", ["page": .string("health")])
        #expect(hub.seen.count == 3)
        var info = stat()
        #expect(stat(home.appendingPathComponent(".founderizer").path, &info) == 0 && info.st_mode & 0o077 == 0)
    }
}

final class OwnerReadTests {
    let home = Fixture.home()
    deinit { try? FileManager.default.removeItem(at: home) }

    @Test func fleetReadPutsTheSubjectInThePathAndTheWordsInTheQuery() throws {
        let hub = StandInHub(features: Fixture.everyFeature)
        let tools = Fixture.tools(hub, home: home)
        _ = try tools.json("fleet_read", ["page": .string("notes"), "agent": .string("a b")])
        _ = try tools.json("fleet_read", ["page": .string("trigger"), "id": .int(2), "before": .int(9), "limit": .int(5)])
        _ = try tools.json("fleet_read", ["page": .string("knowledge"), "path": .string("a/b.md")])
        let reads = hub.seen.filter { $0.path != "/ui/state" }.map { "\($0.path)?\($0.query ?? "")" }
        #expect(reads == ["/ui/notes/a%20b?db=g1", "/ui/triggers/2?db=g1&before=9&limit=5",
                          "/ui/knowledge?db=g1&path=a%2Fb.md"])
        // A word that the page's route does not read is refused before any request (owner_mcp.py PAGE_TAKES): the
        // hub would give the whole page, and the agent would take it for the narrowed one.
        let before = hub.seen.count
        #expect(tools.refused("fleet_read", ["page": .string("notes"), "agent": .string("a b"), "limit": .int(5)])
                == "the page notes takes no limit, so nothing was read: it needs agent.")
        #expect(tools.refused("fleet_read", ["page": .string("machines"), "agent": .string("w"), "id": .int(3)])
                == "the page machines takes no id or agent, so nothing was read: it takes only page, and gives all "
                   + "of it in one answer.")
        // A word that the schema does not have either (an older list's since), before the check of a whole number
        // that this program cannot carry and before a hub, as owner_mcp.py refuses it.
        #expect(tools.refused("fleet_read", ["page": .string("events"), "id": .int(5), "since": .int(100),
                                             "limit": .bigInt("100000000000000000000")])
                == "the page events takes no since, so nothing was read: it needs id, and takes after and limit.")
        #expect(hub.seen.count == before)
        #expect(tools.refused("fleet_read", ["page": .string("nothing")])?.hasPrefix("page must be one of: agent_messages, ") == true)
        #expect(tools.refused("fleet_read", ["page": .string("goal")]) == "the page goal is about one thing: give its id.")
        #expect(tools.refused("fleet_read", ["page": .string("goal"), "id": .bool(true)])
                == "the page goal is about one thing: give its id.")
        #expect(tools.refused("fleet_read", ["page": .string("notes"), "agent": .string("a/b")])
                == "the page notes is about one thing: give agent.")
    }

    @Test func historyAndCostsPassTheirOwnWords() throws {
        let hub = StandInHub(features: Fixture.everyFeature)
        let tools = Fixture.tools(hub, home: home)
        _ = try tools.json("search_history", ["agent": .string("worker-1"), "query": .string("a b"), "limit": .int(3),
                                              "other": .string("x")])
        _ = try tools.json("see_costs", ["from": .string("2026-11-01"), "minimum": .int(3), "by": .string("day")])
        let reads = hub.seen.filter { $0.path != "/ui/state" }.map { "\($0.path)?\($0.query ?? "")" }
        #expect(reads == ["/ui/history?db=g1&agent=worker-1&query=a+b&limit=3",
                          "/ui/costs?db=g1&from=2026-11-01&minimum=3&by=day"])
    }

    @Test func theOverviewIsTheStateWithItsThreePages() throws {
        let hub = StandInHub(features: Fixture.everyFeature)
        hub.state = [
            "time": .int(100),
            "agents": .array([.object(["name": .string("manager"), "role": .string("manager"), "secret": .string("x")])]),
            "tasks": .array([.object(["id": .int(1), "state": .string("working"), "title": .string("T")]),
                             .object(["id": .int(2), "state": .string("completed")])]),
            "needs": .array([.object(["id": .int(5), "answered": .bool(false)]), .object(["id": .int(6), "answered": .int(9)])]),
            "reports": .array((1...7).map { .int(Int64($0)) }),
        ]
        hub.answer = { $0.path == "/ui/servers" ? (403, .object(["error": .string("is not owner's machine")])) : nil }
        let tools = Fixture.tools(hub, home: home)
        let found = try tools.json("fleet_overview")
        #expect(found["hub"] == .string(hub.base) && found["generation"] == .string("g1") && found["time"] == .int(100))
        #expect(found["agents"]?.array?.first?.object?.keys.sorted()
                == ["active", "alive", "last_seen", "limit", "name", "reports_to", "role", "runtime"])
        #expect(found["open_tasks"]?.array?.count == 1 && found["finished_tasks"] == .int(1))
        #expect(found["needs_you"]?.array?.count == 1)
        #expect(found["reports"] == .array((3...7).map { .int(Int64($0)) }))
        #expect(found["health"] == .object(["page": .string("/ui/health")]))
        #expect(found["servers"]?["not_read"]?.string?.hasPrefix("The hub refused the servers, their readings") == true)
        #expect(found["goals"] == .array([]) && found["duties"] == .array([]))
    }
}

final class OwnerRefusalTests {
    let home = Fixture.home()
    deinit { try? FileManager.default.removeItem(at: home) }

    @Test func aRefusalOfTheOwnerAddressIsSaidAsOwnerMCPSaysIt() throws {
        let hub = StandInHub(features: Fixture.everyFeature)
        hub.answer = { $0.method == "POST" ? (403, .object(["error": .string("is not owner's machine")])) : nil }
        let tools = Fixture.tools(hub, home: home)
        #expect(tools.refused("take_release") == "The hub refused the update: is not owner's machine. This server is "
                + "the owner only while it runs on the Mac whose address is \"owner\" in team.json. Read the hub's own "
                + "words above; the install's claim is what sets that address.")
    }

    @Test func aNewGenerationIsReadAgainOnceAndTheCommandSentAgain() throws {
        let hub = StandInHub(features: Fixture.everyFeature)
        let tools = Fixture.tools(hub, home: home)
        _ = try tools.json("check_releases")
        hub.db = "g2"
        _ = try tools.json("check_releases")
        let posts = hub.seen.filter { $0.method == "POST" }
        #expect(posts.map { $0.body?["db"] } == [.string("g1"), .string("g1"), .string("g2")])
        #expect(posts[1].body?["request_id"] == posts[2].body?["request_id"])
        #expect(hub.seen.filter { $0.path == "/ui/state" }.count == 2)
    }

    @Test func aTeamJSONThatMovedIsTheHubsOwn409() throws {
        let hub = StandInHub(features: Fixture.everyFeature)
        hub.answer = { $0.method == "POST" ? (409, .object(["error": .string("team.json changed"), "sha256": .string("sha-2")])) : nil }
        let tools = Fixture.tools(hub, home: home)
        // The words say to make the change again from a new read, never to send it again as it was (OwnerHub.moved).
        #expect(tools.refused("remove_machine", ["server": .string("server-1")])
                == "The hub refused the removal of this server: team.json changed. Another change came after the read "
                + "that this command was made from: read it again, make the change again from what is there now, and "
                + "send that.")
    }

    @Test func aFieldOrARouteThatTheHubDoesNotKnowSaysTheHubCanBeOlder() throws {
        let hub = StandInHub(features: Fixture.everyFeature)
        hub.answer = { request in
            if request.path.hasSuffix("/check") { return (400, .object(["error": .string("unknown field foo"), "db": .string("g1")])) }
            if request.path.hasSuffix("/update") { return (404, .object(["error": .string("not found")])) }
            if request.path == "/ui/releases/auto" { return (400, .object(["error": .string("automatic must be true or false")])) }
            return nil
        }
        let tools = Fixture.tools(hub, home: home)
        #expect(tools.refused("check_machine", ["agent": .string("worker-1")])
                == "The hub refused the machine check (400): unknown field foo\n{\n \"db\": \"g1\"\n}\n" + OwnerHub.olderHub)
        #expect(tools.refused("update_machine", ["agent": .string("worker-1")])
                == "The hub refused the update (404): not found\n" + OwnerHub.olderHub)
        #expect(tools.refused("automatic_releases", ["automatic": .string("x")])
                == "The hub refused the automatic-update setting (400): automatic must be true or false")
    }

    @Test func withNoFleetEveryToolSaysSo() {
        for setting in [nil, HubClient.defaultAddress] as [String?] {
            let tools = Fixture.tools(nil, home: home, setting: .some(setting))
            for name in ["fleet_overview", "fleet_read", "take_release", "goal_state"] {
                #expect(tools.refused(name, ["page": .string("state")]) == OwnerTools.noFleet)
            }
        }
    }

    @Test func aToolWhoseFeatureTheHubLacksIsRefusedWithItsName() throws {
        let hub = StandInHub(features: Fixture.everyFeature.filter { $0 != "agent_move" })
        let tools = Fixture.tools(hub, home: home)
        let said = try #require(tools.refused("move_agent", ["agent": .string("worker-1"), "server": .string("server-2")]))
        #expect(said.hasPrefix("move_agent needs the hub's feature agent_move") && said.contains("older than the Founderizer app"))
        #expect(hub.seen.allSatisfy { $0.method == "GET" })
        hub.features = Fixture.everyFeature             // the hub updated during the session: read again, and it runs
        _ = try tools.json("move_agent", ["agent": .string("worker-1"), "server": .string("server-2")])
    }

    @Test func absentAndUnknownToolsAreRefusedAtTheCall() {
        let hub = StandInHub(features: Fixture.everyFeature)
        let tools = Fixture.tools(hub, home: home)
        #expect(tools.refused("install_hub")?.contains("the Founderizer app does that work itself, on its own pages") == true)
        #expect(tools.refused("nothing_here") == "No tool named nothing_here.")
        #expect(hub.seen.isEmpty)
        #expect(!tools.listed.contains { $0.name == "which_hub" })
        // And the three setup tools and the link's six write tools (save_bot_token, prepare_problem_report,
        // save_secret, grant_secret, share_secret, answer_secret_request).
        #expect(tools.listed.count == 68 + 3 + 6 && tools.listed.contains { $0.name == "save_profile" })
    }

    /// A table of a newer `owner_mcp.py` can name a `swift` tool that this program's code does not have: that tool is
    /// refused in plain words, as one of a later version, and not listed; the program does not crash.
    @Test func aSwiftToolThatTheCodeDoesNotHaveIsRefusedInWords() throws {
        let url = Bundle.module.url(forResource: "owner-tools", withExtension: "json", subdirectory: "Fixtures")!
        var root = try #require(JSONValue.parse(try Data(contentsOf: url))?.object)
        var list = try #require(root["tools"]?.array)
        var first = try #require(list.first?.object)
        first["name"] = .string("tool_of_the_future")
        first["kind"] = .string("swift")
        list.append(.object(first))
        root["tools"] = .array(list)
        let table = try OwnerTable.parse(Data(JSONValue.object(root).dumps().utf8))
        #expect(table.tool("tool_of_the_future")?.kind == .swift)
        let hub = StandInHub(features: Fixture.everyFeature)
        let tools = Fixture.tools(hub, home: home, table: table)
        #expect(tools.table.tool("tool_of_the_future")?.kind == .later)
        #expect(tools.refused("tool_of_the_future") == "tool_of_the_future is not in this version of the app yet. Ask "
                + "the owner to update the Founderizer app, or to use owner_mcp.py for it.")
        #expect(!tools.listed.contains { $0.name == "tool_of_the_future" })
        #expect(OwnerTools.verb(of: try #require(tools.table.tool("tool_of_the_future"))) == nil)
        #expect(hub.seen.isEmpty)
    }

    /// `call` takes each tool that the table marks as a read and that the program has; `write` each other one.
    @Test func theVerbsComeFromTheTablesMarks() {
        let tools = Fixture.tools(nil, home: home)
        let reads = Set(tools.listed.filter { OwnerTools.verb(of: $0) == .call }.map(\.name))
        // The four reads of the table, and the two setup tools of the link to the app (`OwnerSetupTools`).
        #expect(reads == ["fleet_overview", "fleet_read", "search_history", "see_costs", "setup_state", "setup_show",
                         "setup_diagnosis"])
        let writes = tools.listed.filter { OwnerTools.verb(of: $0) == .write }
        // And the link's six: save_bot_token, prepare_problem_report, save_secret, grant_secret, share_secret,
        // answer_secret_request.
        #expect(writes.count == 64 + 6)
        #expect(writes.allSatisfy { $0.annotations["readOnlyHint"] == .bool(false) })
        #expect(OwnerTools.verb(of: Fixture.table.tool("install_hub")!) == nil)
    }

}
