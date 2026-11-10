import Foundation
import Observation
import Synchronization

/// **An agent by its role** (the owner, 10 November 2026: "Maybe we could add a setting where the main agent label is
/// its function instead of its name ... otherwise I have like 10 agents and I have to learn the names"; his choice of
/// the mockup: the role first for every agent, with no setting). Both apps name an agent by its role, its team.json
/// `title` ("Customer Support"), wherever they name it, and its chat's panel and the Agents page put its own name
/// ("Nova") under the role. An agent with no role keeps its name.
///
/// The hub's reading carries each agent's role. The store that reads it hands the roles here (`read`), and every line
/// of either app that names an agent asks here (`String.agentLabel`), so one agent reads one way in every place. A view
/// that asks takes part in Observation: a role that he changes redraws every place that shows it.
public final class AgentNames: Observable, Sendable {
    /// The one book of both apps: the roles of the newest reading of the hub that the app shows.
    public static let shared = AgentNames()

    private let registrar = ObservationRegistrar()
    private let book = Mutex<[String: String]>([:])

    public init() {}

    /// Each agent's role, by its name: the agents that have one.
    public var roles: [String: String] {
        registrar.access(self, keyPath: \.roles)
        return book.withLock { $0 }
    }

    /// The roles of one reading of the hub, which replace the ones before: a role that he removed is gone at once.
    public func read(_ agents: [(name: String, title: String?)]) {
        let new = Self.roles(agents)
        guard book.withLock({ $0 }) != new else { return }
        registrar.withMutation(of: self, keyPath: \.roles) { book.withLock { $0 = new } }
    }

    /// The roles of a list of agents: one line each, with single spaces, and none for an empty title.
    public static func roles(_ agents: [(name: String, title: String?)]) -> [String: String] {
        var roles: [String: String] = [:]
        for agent in agents {
            let role = (agent.title ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !role.isEmpty { roles[agent.name] = role }
        }
        return roles
    }

    /// The agent as both apps name it: its role, else its name with capitals ("web-dev" is "Web-Dev").
    public static func label(_ name: String, roles: [String: String]) -> String {
        roles[name] ?? name.capitalized
    }

    /// The small line under the role on the agent's chat panel and on the Agents page: its name with capitals. nil for
    /// an agent with no role, whose name is its label already, and for a role that says the name already ("Fleet
    /// Manager" over "Manager").
    public static func under(_ name: String, roles: [String: String]) -> String? {
        guard let role = roles[name] else { return nil }
        let words = role.lowercased().split { !$0.isLetter && !$0.isNumber }
        return words.contains(Substring(name.lowercased())) ? nil : name.capitalized
    }

    /// True when `words` find this agent by its role or by its name, as a search field does.
    public static func matches(_ name: String, _ words: String, roles: [String: String]) -> Bool {
        label(name, roles: roles).localizedStandardContains(words) || name.localizedStandardContains(words)
    }

    public func label(_ name: String) -> String { Self.label(name, roles: roles) }
    public func under(_ name: String) -> String? { Self.under(name, roles: roles) }
    public func matches(_ name: String, _ words: String) -> Bool { Self.matches(name, words, roles: roles) }
}

extension String {
    /// This agent's name as both apps show it: its role, else the name with capitals (`AgentNames`).
    public var agentLabel: String { AgentNames.shared.label(self) }
}
