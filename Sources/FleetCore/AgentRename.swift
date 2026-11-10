import Foundation

/// A new name for an agent (hub feature `agent_rename`, UI-API.md 1.45). The hub moves everything the agent has to the
/// new name in one step, and the agent's server moves its checkout and its service there under the OS user it already
/// has, so nobody signs in again. The manager keeps its name.
public enum AgentRename {
    public static let feature = "agent_rename"

    /// Why `agent` cannot take this name, in the words of Add agent's name rule, or nil. The name it has is no
    /// problem: Rename simply does nothing then.
    public static func problem(_ name: String, agent: String, existing: [String]) -> String? {
        if name == agent { return nil }
        guard name.range(of: AgentPlacement.namePattern, options: .regularExpression) != nil, !["owner", "hub"].contains(name)
        else { return "Use a name of 2 to 31 characters: a-z, 0-9 and -, starting with a letter." }
        return existing.contains(name) ? "An agent with this name exists." : nil
    }

    /// The rename of this agent that its server works on now, or that stopped there: the newest job of the agent's
    /// server, when it is this agent's rename. nil for any other job, and for one that ended well.
    public static func job(of agent: String, in list: ServerList?) -> ServerJob? {
        guard let job = list?.server(of: agent)?.job, job.kind == "rename", job.agent == agent,
              job.isOpen || job.state == "failed" else { return nil }
        return job
    }
}

/// The answer of `POST /ui/team/agents/<agent>/rename`.
public struct AgentRenameReceipt: Decodable, Sendable {
    public let ok: Bool
    public let request_id: String
    /// The new name.
    public let agent: String
    /// The name the agent had.
    public let was: String
    public let server: String
    public let job: Int
    public let revision: String
    public let sha256: String
}

extension HubClient {
    /// `POST /ui/team/agents/<agent>/rename`: the agent's new name, against the team.json that the app read. The
    /// receipt names the server job that moves the agent there; a job that stopped goes again with `addServerAgent`
    /// for the new name, as a failed install does.
    public func renameAgent(hub: URL, database: String, client: String, requestID: UUID = UUID(), agent: String,
                            sha256: String, name: String) async throws -> AgentRenameReceipt {
        guard agent.range(of: AgentPlacement.namePattern, options: .regularExpression) != nil,
              name.range(of: AgentPlacement.namePattern, options: .regularExpression) != nil,
              sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw HubError.invalidResponse }
        let receipt = try JSONDecoder().decode(AgentRenameReceipt.self, from: await ownerCommand(
            "ui/team/agents/\(agent)/rename", hub: hub, database: database, client: client, requestID: requestID,
            fields: ["base_sha256": sha256, "name": name]))
        guard receipt.ok, receipt.request_id.lowercased() == requestID.uuidString.lowercased(), receipt.agent == name,
              receipt.was == agent, receipt.job > 0 else { throw HubError.invalidResponse }
        return receipt
    }
}
