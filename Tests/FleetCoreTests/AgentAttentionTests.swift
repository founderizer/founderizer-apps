import Foundation
import Testing
@testable import FleetCore

private let now = 10_000.0

private func agent(_ extra: [String: Any] = [:]) throws -> FleetAgent {
    var fields: [String: Any] = ["name": "vps", "role": "worker", "runtime": "codex", "can": [String](), "last_seen": now - 5]
    fields.merge(extra) { _, b in b }
    return try JSONDecoder().decode(FleetAgent.self, from: JSONSerialization.data(withJSONObject: fields))
}

private func machine(reported: Double = now - 30, runtime: [String: Any] = ["signed_in": true], update: [String: Any] = [:],
                     security: [String: Any] = [:], check: [String: Any]? = nil) throws -> MachineStatus {
    var fields: [String: Any] = ["agent": "vps", "machine": "vps", "role": "worker", "update": update, "runtime": runtime,
                                 "security": security, "os": [:], "reported_at": reported]
    if let check { fields["check"] = check }
    return try JSONDecoder().decode(MachineStatus.self, from: JSONSerialization.data(withJSONObject: fields))
}

struct AgentAttentionTests {
    @Test func machineProblemsCountOnlyForAnOnlineAgentInAFreshState() throws {
        let unsigned = try machine(runtime: ["signed_in": false])
        #expect(AgentAttention.items(for: try agent(), serverTime: now, isFresh: false, machine: unsigned).isEmpty)
        #expect(AgentAttention.items(for: try agent(["last_seen": now - 600]), serverTime: now, isFresh: true, machine: unsigned).isEmpty)
        #expect(AgentAttention.items(for: try agent(), serverTime: now, isFresh: true, machine: nil).isEmpty)
        // An old reading of an online agent says only that it is old, not what it said.
        #expect(AgentAttention.items(for: try agent(), serverTime: now, isFresh: true, machine: try machine(reported: now - 900, runtime: ["signed_in": false])) == [.staleReading])
    }

    @Test func aCurrentReadingShowsEachConcreteProblemInOrderButNoVaultWarning() throws {
        let check: [String: Any] = ["id": 4, "state": "failed", "requested_at": now - 60, "completed_at": now - 50, "detail": "codex: not found"]
        let reading = try machine(runtime: ["signed_in": false], update: ["state": "failed", "detail": "git pull failed"],
                                  security: ["reboot_required": true, "vault": ["mode": "broker", "isolated": false]], check: check)
        #expect(AgentAttention.items(for: try agent(), serverTime: now, isFresh: true, machine: reading) == [.signIn, .updateFailed, .checkFailed, .restart])
        let healthy = try machine(security: ["vault": ["mode": "file", "isolated": false]])   // administrator access kept on purpose
        #expect(AgentAttention.items(for: try agent(), serverTime: now, isFresh: true, machine: healthy).isEmpty)
    }
}
