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

    // MARK: who can use it, closed

    /// **One line of "Who can use it"** (the owner, 21 November 2026, of a key request's card with a row for each agent:
    /// "do not show all agents, show the agent icons ... for every group of agents with the same access level", and "No,
    /// no access does not need to show at all"): a level and its agents. A press on the lines opens and closes the row of
    /// each agent under them (his "Yes, as drawn" of 23 November 2026).
    public struct AccessLine: Equatable, Sendable {
        public let level: SecretGrant
        public let agents: [String]
    }

    /// The lines of "Who can use it": Uses it, then Reads it, each only with an agent, in the order of `holders`. An
    /// agent with no access has no line: its row, once the rows are open, shows it. A login is never read, so each of its
    /// grants is Uses it, as its row says. A grant of no holder (the door's) has no line. **A name that `holders` has two
    /// times is one face** (Fable's review of 22 November 2026): a list with no second copy of a key stopped the app on
    /// it.
    public static func accessLines(_ access: [String: SecretGrant], holders: [String], login: Bool) -> [AccessLine] {
        var seen = Set<String>()
        let agents = holders.filter { seen.insert($0).inserted }
        return [SecretGrant.use, .read].compactMap { level in
            let named = agents.filter { agent in access[agent].map { login ? .use : $0 } == level }
            return named.isEmpty ? nil : AccessLine(level: level, agents: named)
        }
    }

    /// The most faces that a line of "Who can use it" draws; past them, "+N". Eight faces of 16 points that overlap by
    /// 6, with the level's mark and word and the caret, fit the 340 points of a card's own window, the narrowest that it
    /// can be.
    public static let lineFaces = 8

    /// The faces that a line draws, in its order, and the agents that its "+N" stands for, whose names it has under the
    /// pointer.
    public static func lineFaces(_ agents: [String]) -> (shown: [String], rest: [String]) {
        (Array(agents.prefix(lineFaces)), Array(agents.dropFirst(lineFaces)))
    }

    // MARK: a card's badge

    /// **The secret that a card's badge of this name opens** (the owner, 21 November 2026, of a request that named a
    /// key of the vault: "a badge for specific Credentials, like we have for agents! ideally a modal of that key should
    /// open"): the reference of the one secret of the list that has this name (`TeamLogin.name`: an API key by its
    /// variable name, a login by its title). None for a name that the list does not have, and none for a name that two
    /// secrets have (two keys from before the list refused a second one, two logins of one title): the badge cannot know
    /// which one he means, and the card of the other one would take his new value.
    public static func reference(named name: String, in catalog: [String: TeamLogin]) -> String? {
        let found = catalog.filter { $0.value.name == name }
        return found.count == 1 ? found.first?.key : nil
    }

    /// The names that a card's badges take, with the kind of each (true: an API key, which has the key's mark; else a
    /// login), in the list's order: each name that exactly one secret has (`reference(named:in:)`).
    public static func badges(_ catalog: [String: TeamLogin]) -> [(name: String, key: Bool)] {
        let counts = catalog.values.reduce(into: [String: Int]()) { $0[$1.name, default: 0] += 1 }
        return catalog.values.filter { counts[$0.name] == 1 }
            .sorted { ($0.name.lowercased(), $0.name) < ($1.name.lowercased(), $1.name) }
            .map { ($0.name, $0.isAPIKey) }
    }

    // MARK: a secret's card

    /// What the card of one secret shows (`card(_:in:fresh:)`).
    public enum Card: Equatable, Sendable {
        /// The secret of the list: its name, its kind and the rest of its card.
        case entry(TeamLogin)
        /// The list that the card has does not have it, and no reading of this visit of the card says yet that it
        /// went: the card shows no name and no kind until a reading comes.
        case waiting
        /// A list that this visit of the card read does not have it: the card closes.
        case gone

        /// The secret's entry, only in `entry`.
        public var entry: TeamLogin? {
            if case .entry(let entry) = self { return entry }
            return nil
        }
    }

    /// **The card of a secret that left the list closes, and no card names a secret by its reference** (a Fable read of
    /// 22 November 2026): a key can leave the fleet somewhere else (at another device, with an agent's removal) while
    /// the list that this Mac keeps still has it, so its badge stays, and its press opens its card. The card then
    /// showed the raw `bws://` reference as its name and "Login" as its kind. `catalog`: the list that the card has
    /// now, nil before its first reading and when the hub's list could not be read; `fresh`: this Mac kept that list
    /// after the page or the card opened, not before.
    /// Only a list of this visit closes the card: an older list can lack a key that the fleet has now.
    public static func card(_ reference: String, in catalog: [String: TeamLogin]?, fresh: Bool) -> Card {
        if let entry = catalog?[reference] { return .entry(entry) }
        return catalog != nil && fresh ? .gone : .waiting
    }
}
