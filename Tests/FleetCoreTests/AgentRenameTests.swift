import Foundation
import Testing
@testable import FleetCore

/// A new name for an agent (hub feature `agent_rename`, UI-API.md 1.45): the name rule of the field, which job of the
/// agent's server the Name row follows, and the command with its receipt. Synthetic data only.
struct AgentRenameTests {
    /// The hub's servers (ui_fixture.py), with the newest job of box, where scout is, set to `job`.
    private func servers(job: [String: Any]?) throws -> ServerList {
        let url = try #require(Bundle.module.url(forResource: "servers", withExtension: "json", subdirectory: "Fixtures"))
        var list = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var entries = try #require(list["servers"] as? [[String: Any]])
        entries[1]["job"] = job ?? NSNull()
        list["servers"] = entries
        return try JSONDecoder().decode(ServerList.self, from: JSONSerialization.data(withJSONObject: list))
    }

    private func job(_ kind: String, _ agent: String, _ state: String, detail: String? = nil) -> [String: Any] {
        ["id": 7, "kind": kind, "agent": agent, "runtime": "codex", "state": state, "step": "service",
         "detail": detail ?? NSNull(), "prompt": NSNull(), "created": 900.0, "updated": 990.0]
    }

    @Test func theFieldTakesAddAgentsNameRule() {
        let team = ["manager", "scout", "mia"]
        #expect(AgentRename.problem("max", agent: "scout", existing: team) == nil)
        #expect(AgentRename.problem("scout", agent: "scout", existing: team) == nil)       // Rename does nothing then
        #expect(AgentRename.problem("mia", agent: "scout", existing: team) == "An agent with this name exists.")
        for name in ["Max", "m", "max ", "1max", "owner", "hub", ""] {
            #expect(AgentRename.problem(name, agent: "scout", existing: team) ==
                        "Use a name of 2 to 31 characters: a-z, 0-9 and -, starting with a letter.", "\(name)")
        }
    }

    @Test func theRowFollowsTheRenameOfItsOwnAgentOnly() throws {
        #expect(AgentRename.job(of: "scout", in: try servers(job: job("rename", "scout", "running")))?.isOpen == true)
        #expect(AgentRename.job(of: "scout", in: try servers(job: job("rename", "scout", "queued")))?.isOpen == true)
        let stopped = AgentRename.job(of: "scout", in: try servers(job: job("rename", "scout", "failed", detail: "No network.")))
        #expect(stopped?.state == "failed" && stopped?.detail == "No network.")
        #expect(AgentRename.job(of: "scout", in: try servers(job: job("rename", "scout", "done"))) == nil)
        #expect(AgentRename.job(of: "scout", in: try servers(job: job("install", "scout", "running"))) == nil)
        #expect(AgentRename.job(of: "scout", in: try servers(job: job("prepare", "scout", "failed"))) == nil)
        #expect(AgentRename.job(of: "scout", in: try servers(job: nil)) == nil)
        #expect(AgentRename.job(of: "nobody", in: try servers(job: job("rename", "scout", "running"))) == nil)
        #expect(AgentRename.job(of: "scout", in: nil) == nil)
    }

    @Test func theCommandSendsTheNewNameAgainstTheTeamItRead() async throws {
        let base = String(repeating: "a", count: 64), id = UUID()
        let hub = try OneAnswer(status: "200 OK") { _ in
            #"{"ok":true,"request_id":"\#(id.uuidString.lowercased())","client":"test","replayed":false,"agent":"max","#
                + #""was":"scout","server":"box","job":9,"revision":"\#(String(repeating: "c", count: 40))","#
                + #""sha256":"\#(String(repeating: "d", count: 64))"}"#
        }
        let receipt = try await HubClient().renameAgent(hub: URL(string: "http://127.0.0.1:\(hub.port)")!, database: "db",
                                                        client: "test", requestID: id, agent: "scout", sha256: base, name: "max")
        #expect((receipt.agent, receipt.was, receipt.server, receipt.job) == ("max", "scout", "box", 9))
        #expect(hub.received.starts(with: Data("POST /ui/team/agents/scout/rename HTTP/1.1\r\n".utf8)))
        let body = try #require(try JSONSerialization.jsonObject(with: OneAnswer.body(of: hub.received)) as? [String: String])
        #expect(body == ["base_sha256": base, "name": "max", "db": "db", "request_id": id.uuidString.lowercased()])
    }

    @Test func aReceiptForAnotherNameIsNotTaken() async throws {
        let id = UUID()
        let hub = try OneAnswer(status: "200 OK") { _ in
            #"{"ok":true,"request_id":"\#(id.uuidString.lowercased())","agent":"other","was":"scout","server":"box","#
                + #""job":9,"revision":"r","sha256":"s"}"#
        }
        await #expect(throws: HubError.self) {
            try await HubClient().renameAgent(hub: URL(string: "http://127.0.0.1:\(hub.port)")!, database: "db", client: "test",
                                              requestID: id, agent: "scout", sha256: String(repeating: "a", count: 64),
                                              name: "max")
        }
        await #expect(throws: HubError.self) {      // a name the hub would refuse never leaves this Mac
            try await HubClient().renameAgent(hub: URL(string: "http://127.0.0.1:1")!, database: "db", client: "test",
                                              agent: "scout", sha256: String(repeating: "a", count: 64), name: "Max")
        }
    }
}
