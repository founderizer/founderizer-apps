import Foundation

/// One machine of `GET /ui/team` (owner API 1.12, `agent_auth`), as the app reads it: the OS user that its agents run
/// as, which its own helper reports. The hub's entry says more (its agents, SSH access, the runtimes that its helpers
/// know and `add_agent`): the app read that for Add agent on an existing machine, which went with executor 2.0.0.
public struct TeamMachine: Decodable, Equatable, Sendable {
    public let worker_user: String?
}

/// The names of an agent and of a machine that the app sends to the hub and to the bundled installer.
public enum AgentPlacement {
    static let namePattern = "^[a-z][a-z0-9-]{1,30}$"
    static let machinePattern = "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"
}
