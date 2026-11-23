import Foundation
import Observation
import Synchronization

/// **An agent by its name** (the owner, 22 November 2026, of a customer's agent that the apps and its colleagues
/// called by its role, not by the name that the customer gave it; and his answers to the questions of that day: "Each
/// place of the Mac, iPhone and PC apps ...; the Agents page shows the name over the role", and "The name with the role
/// in grey"). It reverses his choice of 10 November 2026, the role first with no setting. Both apps name an agent by
/// its name with capitals ("Nova") wherever they name it, and its role, its team.json `title` ("Customer Support"),
/// stands beside the name where a place shows the agent as an entry of its own: "Nova · Customer Support" on one line,
/// or the role under the name on Agents. One exception: when one word of the role is the name, the role is the label
/// and stands alone ("Fleet Manager" for `manager`).
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

    /// The agent as both apps name it: its name with capitals ("web-dev" is "Web-Dev"), or its role when one word of
    /// the role is the name ("Fleet Manager" for `manager`, "Scout" for `scout`).
    public static func label(_ name: String, roles: [String: String]) -> String {
        if let role = roles[name], says(role, name) { return role }
        return name.capitalized
    }

    /// The role beside the label: after a middle dot in `AgentNameLine`, under the name on the Agents page. nil for an
    /// agent with no role, and for a role that is the label already ("Fleet Manager" beside "Fleet Manager").
    public static func role(_ name: String, roles: [String: String]) -> String? {
        guard let role = roles[name], !says(role, name) else { return nil }
        return role
    }

    /// True when one word of the role is the name: the role in small letters, cut at each character that is no letter
    /// and no digit.
    private static func says(_ role: String, _ name: String) -> Bool {
        role.lowercased().split { !$0.isLetter && !$0.isNumber }.contains(Substring(name.lowercased()))
    }

    /// **The line under an agent's name in Settings › Reporting lines** (the owner's answer of 22 November 2026: "the
    /// role under the name in Reporting lines"): the role beside its label, then " · " and "Lead" for a lead ("Customer
    /// Support · Lead"); "Lead" alone for a lead with no role beside its label; nil for any other agent with no role
    /// beside its label, which has its name's line only.
    public struct GraphLine: Equatable, Sendable {
        /// The role, which the view cuts at its end where the line is too long; nil where the position stands alone.
        public let role: String?
        /// "Lead" for a lead; nil for an agent that is no lead.
        public let position: String?
        /// " · Lead" after a role, or "Lead" alone, which the view keeps whole; nil for an agent that is no lead.
        public var end: String? { position.map { role == nil ? $0 : " · " + $0 } }
        /// The whole line, as it reads.
        public var words: String { (role ?? "") + (end ?? "") }
    }

    /// The line under the name of `name` in Reporting lines, where `lead` says that the agent is a lead (`GraphLine`).
    public static func graphLine(_ name: String, lead: Bool, roles: [String: String]) -> GraphLine? {
        let role = Self.role(name, roles: roles)
        guard role != nil || lead else { return nil }
        return GraphLine(role: role, position: lead ? String(l10n: "Lead") : nil)
    }

    /// True when `words` find this agent by its label, its name or its role, as a search field does.
    public static func matches(_ name: String, _ words: String, roles: [String: String]) -> Bool {
        label(name, roles: roles).localizedStandardContains(words) || name.localizedStandardContains(words)
            || roles[name]?.localizedStandardContains(words) == true
    }

    public func label(_ name: String) -> String { Self.label(name, roles: roles) }
    public func role(_ name: String) -> String? { Self.role(name, roles: roles) }
    public func graphLine(_ name: String, lead: Bool) -> GraphLine? { Self.graphLine(name, lead: lead, roles: roles) }
    public func matches(_ name: String, _ words: String) -> Bool { Self.matches(name, words, roles: roles) }
}

extension String {
    /// This agent's name as both apps show it: its name with capitals, or its role when the role holds the name
    /// (`AgentNames.label`).
    public var agentLabel: String { AgentNames.shared.label(self) }
}
