import Foundation
import Testing
@testable import FleetCore

/// Delete an agent (hub feature `agent_remove`; the owner's yes of 7 November 2026): who has Delete…, the words of its
/// confirmation, the steps and words of its server's removal job, and the command with its receipt. Synthetic data only.
struct AgentRemovalTests {
    /// The hub's servers (ui_fixture.py): box with scout, and `others` beside it; the newest job of box set to `job`.
    private func servers(others: [String] = [], job: [String: Any]? = nil) throws -> ServerList {
        let url = try #require(Bundle.module.url(forResource: "servers", withExtension: "json", subdirectory: "Fixtures"))
        var list = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var entries = try #require(list["servers"] as? [[String: Any]])
        entries[1]["agents"] = ["scout"] + others
        entries[1]["job"] = job ?? NSNull()
        list["servers"] = entries
        return try JSONDecoder().decode(ServerList.self, from: JSONSerialization.data(withJSONObject: list))
    }

    private func job(_ state: String, step: String? = "files", detail: String? = nil) -> [String: Any] {
        ["id": 8, "kind": "remove", "agent": "juno", "runtime": "claude", "state": state, "step": step ?? NSNull(),
         "detail": detail ?? NSNull(), "prompt": NSNull(), "created": 900.0, "updated": 990.0]
    }

    @Test func deleteIsOfferedForWorkersOnAHubThatTakesIt() {
        let features = [AgentRemoval.feature, "servers"]
        #expect(AgentRemoval.offered(role: "worker", features: features))
        #expect(AgentRemoval.offered(role: "lead", features: features))
        #expect(!AgentRemoval.offered(role: "manager", features: features), "the manager is never deleted")
        #expect(!AgentRemoval.offered(role: "worker", features: ["servers"]), "a hub without it")
        #expect(!AgentRemoval.offered(role: "worker", features: nil))
        #expect(!AgentRemoval.offered(role: nil, features: features), "an agent the hub does not list")
    }

    @Test func theConfirmationNamesTheServerAndTheAgentsThatStay() throws {
        #expect(AgentRemoval.question("juno") == "Delete Juno?")
        #expect(AgentRemoval.line("scout", in: try servers()) == "Its account and files on box go too.")
        #expect(AgentRemoval.line("scout", in: try servers(others: ["mia"])) == "Its account and files on box go too. Mia stays.")
        #expect(AgentRemoval.line("mia", in: try servers(others: ["mia", "leo"])) ==
                    "Its account and files on box go too. Scout and Leo stay.")
        #expect(AgentRemoval.line("nobody", in: try servers()) == nil, "an agent no server lists has nothing there")
        #expect(AgentRemoval.line("scout", in: nil) == nil)
    }

    @Test func theRemovalHasItsOwnStepsAndWords() throws {
        let running = try #require(try servers(job: job("running")).servers[1].job)
        #expect(Servers.steps(running).map(\.id) == ["service", "files", "user"])
        #expect(Servers.steps(running).map(\.title) == ["Its service", "Its files", "Its account"])
        #expect(Servers.steps(running, onMac: true).map(\.id) == ["service", "files"], "a Mac's agents share its user")
        #expect(Servers.jobWords(running) == "The files of Juno.")
        #expect(Servers.jobWords(try #require(try servers(job: job("queued", step: nil)).servers[1].job)) ==
                    "The server starts to remove Juno in a few seconds.")
        #expect(Servers.jobWords(try #require(try servers(job: job("done", step: "user")).servers[1].job)) ==
                    "Juno is removed from its server.")
        #expect(Servers.jobWords(try #require(try servers(job: job("failed", step: "user", detail: "No root.")).servers[1].job)) ==
                    "No root.")
        // The install's steps stay as they were.
        let install = try #require(try servers(job: ["id": 9, "kind": "install", "agent": "juno", "runtime": "claude",
                                                     "state": "running", "step": "user", "detail": NSNull(), "prompt": NSNull(),
                                                     "created": 900.0, "updated": 990.0]).servers[1].job)
        #expect(Servers.steps(install).map(\.id) == ["user", "runtime", "checkout", "service", "sign_in"])
    }

    @Test func theServersRowSaysTheRemoval() throws {
        func words(_ state: String) throws -> (String, Bool) {
            let box = try servers(job: job(state)).servers[1]
            let reading = try #require(box.reading)
            return Servers.state(box, helpers: [], time: reading.reported_at + 30, fresh: true)
        }
        #expect(try words("running") == ("Removing Juno…", false))
        #expect(try words("queued") == ("Removing Juno…", false))
        #expect(try words("failed") == ("Removal of Juno failed", true))
        #expect(try words("done").0 != "Removing Juno…")
    }

    @Test func theCommandSendsTheTeamItReadAndTakesItsOwnReceipt() async throws {
        let base = String(repeating: "a", count: 64), id = UUID()
        let hub = try OneAnswer(status: "200 OK") { _ in
            #"{"ok":true,"request_id":"\#(id.uuidString.lowercased())","client":"test","replayed":false,"agent":"juno","#
                + #""server":"box","job":12,"revision":"\#(String(repeating: "c", count: 40))","#
                + #""sha256":"\#(String(repeating: "d", count: 64))"}"#
        }
        let receipt = try await HubClient().removeAgent(hub: URL(string: "http://127.0.0.1:\(hub.port)")!, database: "db",
                                                        client: "test", requestID: id, agent: "juno", sha256: base)
        #expect((receipt.agent, receipt.server, receipt.job) == ("juno", "box", 12))
        #expect(hub.received.starts(with: Data("POST /ui/team/agents/juno/remove HTTP/1.1\r\n".utf8)))
        let body = try #require(try JSONSerialization.jsonObject(with: OneAnswer.body(of: hub.received)) as? [String: String])
        #expect(body == ["base_sha256": base, "db": "db", "request_id": id.uuidString.lowercased()])
    }

    @Test func anAgentWithNoServerHasNoJob() async throws {
        let id = UUID()
        let hub = try OneAnswer(status: "200 OK") { _ in
            #"{"ok":true,"request_id":"\#(id.uuidString.lowercased())","agent":"juno","server":null,"job":null,"#
                + #""revision":"r","sha256":"s"}"#
        }
        let receipt = try await HubClient().removeAgent(hub: URL(string: "http://127.0.0.1:\(hub.port)")!, database: "db",
                                                        client: "test", requestID: id, agent: "juno",
                                                        sha256: String(repeating: "a", count: 64))
        #expect(receipt.server == nil && receipt.job == nil)
    }

    @Test func aReceiptForAnotherAgentOrARefusalIsNotTaken() async throws {
        let id = UUID()
        let other = try OneAnswer(status: "200 OK") { _ in
            #"{"ok":true,"request_id":"\#(id.uuidString.lowercased())","agent":"mia","server":"box","job":3,"#
                + #""revision":"r","sha256":"s"}"#
        }
        await #expect(throws: HubError.self) {
            try await HubClient().removeAgent(hub: URL(string: "http://127.0.0.1:\(other.port)")!, database: "db",
                                              client: "test", requestID: id, agent: "juno", sha256: String(repeating: "a", count: 64))
        }
        let refused = try OneAnswer(status: "409 Conflict") { _ in #"{"error":"Juno has open tasks."}"# }
        do {
            _ = try await HubClient().removeAgent(hub: URL(string: "http://127.0.0.1:\(refused.port)")!, database: "db",
                                                  client: "test", agent: "juno", sha256: String(repeating: "a", count: 64))
            Issue.record("a refusal was taken")
        } catch let HubError.refusal(status, words) {
            #expect(status == 409 && words == "Juno has open tasks.")
        }
        await #expect(throws: HubError.self) {      // a name the hub would refuse never leaves this Mac
            try await HubClient().removeAgent(hub: URL(string: "http://127.0.0.1:1")!, database: "db", client: "test",
                                              agent: "Juno", sha256: String(repeating: "a", count: 64))
        }
    }
}
