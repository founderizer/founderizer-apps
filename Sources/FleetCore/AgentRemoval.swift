import Foundation

/// **Delete an agent** (hub feature `agent_remove`; the owner's yes of 7 November 2026 to the mockup: "Delete…" at the
/// end of the agent's menu, then a confirmation that names its server and the agents that stay there). The hub takes
/// the agent out of the fleet, and its server removes what was the agent's own — its service, its files and, on Linux,
/// its account — and nothing of the other agents that share that server. The manager is never deleted.
public enum AgentRemoval {
    public static let feature = "agent_remove"

    /// Whether the agent's menu has Delete…: on a hub that takes it, for an agent it lists, never for the manager.
    public static func offered(role: String?, features: [String]?) -> Bool {
        features?.contains(feature) == true && role != nil && role != "manager"
    }

    /// The confirmation's question.
    public static func question(_ agent: String) -> String { String(l10n: "Delete \(People.agentWord(agent))?") }

    /// The confirmation's one line: what goes on its server, and which agents there stay. nil for an agent that no
    /// server lists, which has nothing there to go.
    public static func line(_ agent: String, in list: ServerList?) -> String? {
        guard let server = list?.server(of: agent) else { return nil }
        let first = String(l10n: "Its account and files on \(server.name) go too.")
        let others = server.agents.filter { $0 != agent }
        guard !others.isEmpty else { return first }
        return others.count == 1 ? String(l10n: "\(first) \(People.agentWords(others)) stays.")
            : String(l10n: "\(first) \(People.agentWords(others)) stay.")
    }
}

/// The answer of `POST /ui/team/agents/<agent>/remove`. `server` and `job` are nil for an agent that had no server.
public struct AgentRemovalReceipt: Decodable, Sendable {
    public let ok: Bool
    public let request_id: String
    public let agent: String
    public let server: String?
    public let job: Int?
    public let revision: String
    public let sha256: String
}

extension HubClient {
    /// `POST /ui/team/agents/<agent>/remove`: the agent leaves the fleet, against the team.json that the app read. The
    /// receipt names the job of its server that removes what was its own there. The same command for an agent whose
    /// removal stopped there gives that job again.
    public func removeAgent(hub: URL, database: String, client: String, requestID: UUID = UUID(), agent: String,
                            sha256: String) async throws -> AgentRemovalReceipt {
        guard agent.range(of: AgentPlacement.namePattern, options: .regularExpression) != nil,
              sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw HubError.invalidResponse }
        let receipt = try JSONDecoder().decode(AgentRemovalReceipt.self, from: await ownerCommand(
            "ui/team/agents/\(agent)/remove", hub: hub, database: database, client: client, requestID: requestID,
            fields: ["base_sha256": sha256]))
        guard receipt.ok, receipt.request_id.lowercased() == requestID.uuidString.lowercased(), receipt.agent == agent,
              (receipt.job ?? 1) > 0 else { throw HubError.invalidResponse }
        return receipt
    }
}
