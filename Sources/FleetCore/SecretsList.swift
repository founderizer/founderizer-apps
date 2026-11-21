import Foundation

/// **The fleet's Secrets page** (the owner, 20 November 2026: "on the secrets page: * we need a great FILTER (by free
/// type text, by agent with multiple selection) * for each secret, show the icons of the agents that hold it, and their
/// names, like in a facebook group, all overlapping each other and the names later * bulk selection to: remove and give
/// access to one or several agents. Make sure the operation shows a loading etc", and "yes as drawn" to its picture):
/// who holds each secret and how a row says it, what the filter shows, what the bar acts on, the calls of a change of
/// several secrets in their one order, and the counts. The page draws; these decide.
public enum SecretsList {
    /// One secret of the list: its reference, its catalog entry, and the agents that hold it (`holders(of:)`).
    public struct Item: Equatable, Sendable {
        public let reference: String
        public let entry: TeamLogin
        public let holders: [String]

        public init(reference: String, entry: TeamLogin, holders: [String]) {
            self.reference = reference; self.entry = entry; self.holders = holders
        }
    }

    // MARK: holders

    /// The agents that hold one secret: a grant, or a profile that lists its reference (the older grant), in the hub's
    /// order of `agents`. `listed`: by reference, the agents whose profile lists it; nil when the profiles were not read.
    public static func holders(of reference: String, _ entry: TeamLogin, agents: [String], listed: [String: [String]]?) -> [String] {
        agents.filter { entry.grants?[$0] != nil || listed?[reference]?.contains($0) == true }
    }

    /// The most holders that a row draws as faces and names; past them, "+N".
    public static let named = 3

    /// The holders that a row draws, as faces and then by name: the first `named` in the hub's order, and how many more.
    public static func faces(_ holders: [String]) -> (shown: [String], more: Int) {
        (Array(holders.prefix(named)), max(0, holders.count - named))
    }

    /// A row's words for its holders, as the apps name an agent (its role, `label`): "No agent", "Support, Writer", or
    /// the first three and "+2".
    public static func holderWords(_ holders: [String], label: (String) -> String = { $0.agentLabel }) -> String {
        let (shown, more) = faces(holders)
        guard !shown.isEmpty else { return String(l10n: "No agent") }
        let names = shown.map(label).joined(separator: ", ")
        return more == 0 ? names : String(l10n: "\(names) +\(more)")
    }

    // MARK: filter

    /// A text as the filter compares it: case and accents folded, so "credito" finds "Crédito" and "stripe" finds
    /// "STRIPE_KEY".
    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Whether one secret shows for the filter's words: each of its words stands in the secret's name or in its note.
    /// No words: every secret.
    public static func matches(_ entry: TeamLogin, words: String) -> Bool {
        let wanted = folded(words).split(whereSeparator: \.isWhitespace)
        guard !wanted.isEmpty else { return true }
        let name = folded(entry.name), note = folded(entry.note ?? "")
        return wanted.allSatisfy { name.contains($0) || note.contains($0) }
    }

    /// The secrets that the filter shows, in the list's order: those that match its words (`matches`) and that at least
    /// one of the ticked agents holds; with no agent ticked, those of every agent and of none.
    public static func shown(_ items: [Item], words: String, agents: Set<String>) -> [Item] {
        items.filter { matches($0.entry, words: words) && (agents.isEmpty || $0.holders.contains(where: agents.contains)) }
    }

    /// Whether a filter is on: words, or a ticked agent.
    public static func filters(words: String, agents: Set<String>) -> Bool {
        !words.trimmingCharacters(in: .whitespaces).isEmpty || !agents.isEmpty
    }

    /// "4 of 161", while a filter is on: the secrets it shows, of all of them. nil while no filter is on.
    public static func count(shown: Int, of total: Int, filtering: Bool) -> String? {
        filtering ? String(l10n: "\(shown) of \(total)") : nil
    }

    /// The words of the agent menu: "All agents" at rest, else the count of the ticked agents.
    public static func agentsWords(_ ticked: Int) -> String {
        ticked == 0 ? String(l10n: "All agents") : ticked == 1 ? String(l10n: "\(1) agent") : String(l10n: "\(ticked) agents")
    }

    // MARK: the bar

    /// What a press of the bar does.
    public enum Change: Equatable, Sendable {
        /// Give access: each chosen agent may use each ticked secret (`use`).
        case give
        /// Take access: each chosen agent's grant of each ticked secret ends.
        case take
        /// Delete: each ticked secret that nobody holds leaves the list.
        case delete
    }

    /// One call of a change of several secrets: one agent's grant of one secret, or its end.
    public struct Pair: Equatable, Sendable {
        public let reference: String
        public let agent: String

        public init(reference: String, agent: String) { self.reference = reference; self.agent = agent }
    }

    /// **What the bar acts on: the ticked secrets that the filter shows (`shown`), in the list's order.** A tick that
    /// the filter hides does not count, so a change never reaches a secret that he cannot see.
    public static func selected(_ items: [Item], ticked: Set<String>, words: String, agents: Set<String>) -> [Item] {
        shown(items, words: words, agents: agents).filter { ticked.contains($0.reference) }
    }

    /// The agents that Take access offers: each agent with a grant of at least one of the secrets, in the hub's order.
    /// An agent that has a secret only from its profile is no such agent: its profile changes that.
    public static func takeable(_ secrets: [Item], agents: [String]) -> [String] {
        agents.filter { agent in secrets.contains { $0.entry.grants?[agent] != nil } }
    }

    /// **The calls of one change, one pair at a time, in one fixed order**: the secrets in the list's order, and for
    /// each the chosen agents in the hub's order (`agents`). Give goes only to an agent that does not hold the secret,
    /// so an agent that reads a key never comes down to using it, and a secret that a profile lists gets no grant
    /// beside it. Take goes only to an agent with a grant of the secret. Delete has no pairs (`removal`).
    public static func pairs(_ change: Change, secrets: [Item], chosen: Set<String>, agents: [String]) -> [Pair] {
        let order = agents.filter(chosen.contains)
        return secrets.flatMap { item in
            order.compactMap { agent -> Pair? in
                switch change {
                case .give: item.holders.contains(agent) ? nil : Pair(reference: item.reference, agent: agent)
                case .take: item.entry.grants?[agent] == nil ? nil : Pair(reference: item.reference, agent: agent)
                case .delete: nil
                }
            }
        }
    }

    /// What Delete does with the ticked secrets, in the list's order: it removes each one that no agent and no profile
    /// holds, as the removal in a secret's detail does, and keeps each one that is still held.
    public struct Removal: Equatable, Sendable {
        public let removes: [String]
        public let held: [String]
    }

    public static func removal(_ secrets: [Item]) -> Removal {
        Removal(removes: secrets.filter { $0.holders.isEmpty }.map(\.reference),
                held: secrets.filter { !$0.holders.isEmpty }.map(\.reference))
    }

    /// The bar's count: "1 selected", "4 selected".
    public static func selectedWords(_ count: Int) -> String {
        count == 1 ? String(l10n: "1 selected") : String(l10n: "\(count) selected")
    }

    /// The white button of Give access or Take access, by the ticked secrets and the ticked agents: "Give 4 secrets
    /// to 2 agents". The count of agents comes in only with a tick: with none, "Give 4 secrets", dimmed. One sentence
    /// for each count, so that each language says it in its own grammar.
    public static func buttonWords(_ change: Change, secrets: Int, agents: Int) -> String {
        if agents == 0 {
            switch (change, secrets == 1) {
            case (.take, true): return String(l10n: "Take 1 secret")
            case (.take, false): return String(l10n: "Take \(secrets) secrets")
            case (_, true): return String(l10n: "Give 1 secret")
            case (_, false): return String(l10n: "Give \(secrets) secrets")
            }
        }
        return switch (change, secrets == 1, agents == 1) {
        case (.take, true, true): String(l10n: "Take 1 secret from 1 agent")
        case (.take, true, false): String(l10n: "Take 1 secret from \(agents) agents")
        case (.take, false, true): String(l10n: "Take \(secrets) secrets from 1 agent")
        case (.take, false, false): String(l10n: "Take \(secrets) secrets from \(agents) agents")
        case (_, true, true): String(l10n: "Give 1 secret to 1 agent")
        case (_, true, false): String(l10n: "Give 1 secret to \(agents) agents")
        case (_, false, true): String(l10n: "Give \(secrets) secrets to 1 agent")
        case (_, false, false): String(l10n: "Give \(secrets) secrets to \(agents) agents")
        }
    }

    /// The bar's words while a change works: "Giving 4 of 6". `at` counts the calls that are done, so the call on its
    /// way is the next one.
    public static func progress(_ change: Change, done at: Int, of total: Int) -> String {
        let now = min(at + 1, total)
        switch change {
        case .give: return String(l10n: "Giving \(now) of \(total)")
        case .take: return String(l10n: "Taking \(now) of \(total)")
        case .delete: return String(l10n: "Deleting \(now) of \(total)")
        }
    }

    /// The bar's orange line after a Delete that kept the secrets that are still held.
    public static func heldWords(_ count: Int) -> String {
        count == 1 ? String(l10n: "1 secret stays, because an agent has it.")
            : String(l10n: "\(count) secrets stay, because agents have them.")
    }
}
