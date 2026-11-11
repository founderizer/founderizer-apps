import Foundation

// Other people and their conversations (UI-API.md 1.17, owner features `people` and `conversations`): the people the
// owner lets talk to an agent, the hub's roles, and the record of every conversation with what the agent did in it.
//
// The rules below belong to the hub and no screen can turn them off: only the owner writes a person, a person reaches
// the agents on their own list and no other one, and a person is never the owner. The app shows them and refuses
// early what the hub would refuse, so the owner reads one sentence and not a stack trace.

public enum People {
    /// `ui_features` of a hub that has the people table and its roles.
    public static let feature = "people"
    /// `ui_features` of a hub that serves the conversation routes.
    public static let conversationsFeature = "conversations"

    public static let nameMax = 60
    public static let noteMax = 2000
    public static let agentsMax = 16
    public static let handlesMax = 8
    public static let peopleMax = 200
    public static let dailyMax = 1000
    // The roles are the hub's (`GET /ui/people` `roles`): their names, their order and their words. Plan P1 makes them
    // data the owner writes, so the app knows no role of its own and refuses none the hub gives.

    /// A role as a page writes it: "Customer". A role the owner named himself shows as he wrote it.
    public static func roleWord(_ role: String) -> String {
        role.isEmpty ? "" : role.prefix(1).uppercased() + role.dropFirst()
    }

    /// The ending that WhatsApp puts on the ID of a phone number.
    public static let whatsappSuffix = "@s.whatsapp.net"

    /// The ID WhatsApp sends for a phone number, made here so the owner never types one: the digits, without the
    /// `+` or the `00` in front, and the app's own ending. Nil when those digits are no phone number (E.164 has 6
    /// to 15 of them).
    public static func whatsappID(from typed: String) -> String? {
        var digits = typed.filter(\.isWholeNumber)
        if digits.hasPrefix("00") { digits = String(digits.dropFirst(2)) }
        guard (6...15).contains(digits.count) else { return nil }
        return digits + whatsappSuffix
    }

    /// An agent's name as the pages write it.
    public static func agentWord(_ agent: String) -> String { agent.agentLabel }

    /// The agents of a list, for one line, each by its name: "Studio", "Studio and Mini", "Vps, Mini and Nova".
    public static func agentWords(_ agents: [String]) -> String {
        switch agents.count {
        case 0: "No agent"
        case 1: agentWord(agents[0])
        // Every one by name (D-2, fix round 2): "3 agents" did not say which.
        default: agents.dropLast().map(agentWord).joined(separator: ", ") + " and " + agentWord(agents[agents.count - 1])
        }
    }

    /// Why an agent cannot hold a conversation, in a line, before the owner puts it on a person's list. The hub
    /// decides this (`agents[].says` of `GET /ui/people`) and its own line always wins; this one is for an agent
    /// that is not on the list yet, where the hub says nothing.
    public static func cannotChat(role: String, runtime: String, active: Bool?) -> String? {
        if role == "manager" { return "The fleet's manager never talks with other people." }
        if active == false { return "This agent is still in setup." }
        if runtime != "claude" {
            // The provider's own name, "Codex" (fix round 3, item 37: it said "codex").
            return "A session of \(providerName(runtime)) cannot be locked down to a conversation yet, so other people never reach it."
        }
        return nil
    }

    /// A refusal in the hub's own words, or a write without an answer that can still have arrived.
    public static func reason(_ error: Error) -> String {
        if case HubError.refusal(_, let text) = error { return "The hub said: \(text.hasSuffix(".") ? text : text + ".")" }
        if error is URLError { return "No answer from the hub. It can still have done it: look again before you try again." }
        return error.localizedDescription
    }

    /// What the owner typed, as the hub takes it: one line, without the spaces at its ends.
    public static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - the roles and the people of `GET /ui/people`

extension PeopleSnapshot {
    /// One role as the hub gives it: what the agent is told about such a person, which tools their window has, and
    /// how many messages a day they may send. The app never writes these words itself.
    public struct Role: Decodable, Equatable, Sendable, Identifiable {
        public let role: String
        public let means: String
        /// The messages a day of such a person when the owner sets none; nil for a role with no limit (plan P1:
        /// only outsiders have one).
        public let daily: Int?
        /// The tools of their conversation, where the hub names them.
        public let tools: [String]
        public var id: String { role }
        public var word: String { People.roleWord(role) }

        public init(role: String, means: String, daily: Int?, tools: [String]) {
            self.role = role; self.means = means; self.daily = daily; self.tools = tools
        }

        private enum CodingKeys: String, CodingKey { case role, means, daily, tools, name, prompt }

        /// The name and the words are the role; a number or a list of another shape reads as absent, so a newer
        /// hub's role never takes the People page with it. With contacts.v2 on (plan P1) the hub lists them as
        /// `GET /ui/roles` does: `name`, and the owner's `prompt` as what the agent is told.
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            role = try values.decodeIfPresent(String.self, forKey: .role) ?? values.decode(String.self, forKey: .name)
            means = try values.decodeIfPresent(String.self, forKey: .means) ?? values.decode(String.self, forKey: .prompt)
            daily = (try? values.decodeIfPresent(Int.self, forKey: .daily)) ?? nil
            tools = (try? values.decodeIfPresent([String].self, forKey: .tools)) ?? []
        }
    }

    /// One agent of a person's list: whether it can hold a conversation now, and the hub's line when it cannot. The
    /// owner may keep such an agent on the list; the person still never reaches it.
    public struct PersonAgent: Decodable, Equatable, Sendable, Identifiable {
        public let agent: String
        public let can_chat: Bool
        public let says: String?
        /// **What this person may use of the agent** (feature `person_scope`): nil where the hub sends no `scope` (no
        /// list can hold there, or an older hub), `.all` for its null, and the list otherwise. A `scope` of a shape
        /// that this app cannot read is nil too: the read never fails, and the app never writes over a list that it
        /// cannot read.
        public let scope: PersonScope?
        public var id: String { agent }

        public init(agent: String, can_chat: Bool, says: String?, scope: PersonScope? = nil) {
            self.agent = agent; self.can_chat = can_chat; self.says = says; self.scope = scope
        }

        private enum CodingKeys: String, CodingKey { case agent, can_chat, says, scope }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            agent = try values.decode(String.self, forKey: .agent)
            can_chat = try values.decode(Bool.self, forKey: .can_chat)
            says = try values.decodeIfPresent(String.self, forKey: .says)
            scope = PersonScope.read(values, .scope)
        }
    }

    /// One handle of a person on a chat app: the ID that the app sends, and what the owner wrote down about it.
    public struct PersonHandle: Decodable, Equatable, Sendable, Identifiable {
        public let app: String
        public let handle: String
        public let alias: String?
        public let name: String?
        public let added: Double?
        public var id: String { "\(app)/\(handle)" }

        /// The handle as a row shows it: the name the owner wrote, else the ID itself, shortened as a WhatsApp ID is.
        public var shown: String {
            let said = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !said.isEmpty { return String(said.prefix(80)) }
            return String((handle.split(separator: "@").first.map(String.init) ?? handle).prefix(60))
        }
    }

    /// One conversation of a person, as the People route lists it. The messages are on the conversation's own route.
    public struct PersonConversation: Decodable, Equatable, Sendable, Identifiable {
        public let id: Int
        public let agent: String
        public let state: String
        public let last: Double?
    }

    /// One person the owner added: who they are, what the agent is told about them, which agents they reach, their
    /// handles, and the conversations they have had.
    public struct Person: Decodable, Equatable, Sendable, Identifiable {
        public let id: Int
        public let name: String
        public let role: String
        public let role_means: String?
        public let note: String?
        /// The number that counts: the owner's own, else the role's.
        public let daily: Int?
        /// The owner's own number, or nil while the role's own number counts.
        public let daily_set: Int?
        /// The time the owner blocked them, or nil.
        public let blocked: Double?
        public let added: Double?
        /// The messages this person sent since midnight, over all their conversations.
        public let today: Int?
        public let agents: [PersonAgent]
        public let handles: [PersonHandle]
        public let conversations: [PersonConversation]

        public var isBlocked: Bool { blocked != nil }
        public var roleWord: String { People.roleWord(role) }
        public var agentNames: [String] { agents.map(\.agent) }
        /// The agents of their list that can hold a conversation now.
        public var reachable: [PersonAgent] { agents.filter(\.can_chat) }
        /// The agents of their list that cannot, with the hub's line for each.
        public var unreachable: [PersonAgent] { agents.filter { !$0.can_chat } }
        public var limit: Int { daily ?? 0 }
        public var sentToday: Int { today ?? 0 }
        /// The messages a day that count, where a number does: the hub's, else the owner's own, which the hub counts only
        /// for an agent that this person has a list with (the person access plan, section 8). nil: no limit.
        public var dailyLimit: Int? { daily ?? (agents.contains { $0.scope.map { !$0.isAll } ?? false } ? daily_set : nil) }
        /// What a person's page says of today: "3 today of 30", or "3 today" with no number to count against, never
        /// "of 0" for a limit that is not there.
        public var todayWords: String { dailyLimit.map { "\(sentToday) today of \($0)" } ?? "\(sentToday) today" }

        /// The one line under a person's name: what stops them first, else what they have. Orange where the owner
        /// can act. Never more than a handful of words.
        public func state(now: Double) -> (words: String, attention: Bool) {
            if isBlocked { return ("Blocked", true) }
            if agents.isEmpty { return ("No agent yet", true) }
            if handles.isEmpty { return ("No handle yet", true) }
            if reachable.isEmpty {
                let first = unreachable.first?.agent ?? ""
                return ("\(People.agentWord(first)) cannot chat now", true)
            }
            if sentToday >= limit, limit > 0 { return ("Reached today's limit", true) }
            if conversations.isEmpty { return ("No message yet", false) }
            let last = conversations.compactMap(\.last).max()
            return (last.map { "Last message \(activityAge($0, now: now).lowercased())" }
                    ?? "\(conversations.count) conversations", false)
        }

        /// **The same fact as one mark.** The owner, 20 October 2026: "not even sentences, just a check or a cross,
        /// and on hover probably show the detail?" The row answers one question — can this person talk to your
        /// agents? — and `state` is the sentence behind it.
        ///
        /// Blocked and the daily limit warn instead of crossing: he blocked them himself, and a limit he set is
        /// not a fault. What is unfinished or broken — no agent, no handle, an agent that cannot chat — is a cross.
        public func mark(now: Double) -> MarkState {
            if isBlocked { return .warn }
            if agents.isEmpty || handles.isEmpty || reachable.isEmpty { return .bad }
            if sentToday >= limit, limit > 0 { return .warn }
            return .good
        }

        /// The apps this person writes from, in the hub's order.
        public var apps: [String] {
            var seen: [String] = []
            for handle in handles where !seen.contains(handle.app) { seen.append(handle.app) }
            return seen
        }
    }
}

extension PeopleSnapshot {
    /// The roles the hub serves, in its order; empty on a hub that has no 1.17 people.
    public var roleList: [Role] { roles ?? [] }
    /// Every person the owner added, in the hub's order.
    public var peopleList: [Person] { people ?? [] }
    /// The hub answers the people of 1.17: without it the People page says so instead of showing an empty list.
    public var hasPeople: Bool { people != nil && roles != nil }
    public func role(_ name: String) -> Role? { roleList.first { $0.role == name } }
    public func person(_ id: Int) -> Person? { peopleList.first { $0.id == id } }
    /// The person who holds a handle, so a sender nobody answered can be recognised.
    public func person(app: String, handle: String) -> Person? {
        peopleList.first { $0.handles.contains { $0.app == app && ($0.handle == handle || $0.alias == handle) } }
    }

    /// Everyone who wrote to an account of this fleet and got no answer, newest first, over all accounts. The hub
    /// keeps the last twenty of each account; a sender the owner has already added is left out, because their
    /// messages arrive now.
    public var strangers: [Stranger] {
        (ignored ?? []).flatMap { account in
            account.messages.map { Stranger(account: account.account, message: $0) }
        }
        .filter { person(app: $0.app, handle: $0.message.sender ?? "") == nil }
        .sorted { $0.message.ts > $1.message.ts }
    }

    /// How many were dropped today, over every account.
    public var ignoredToday: Int { (ignored ?? []).reduce(0) { $0 + $1.today } }

    /// One message that nobody answered, with the account it was written to.
    public struct Stranger: Equatable, Sendable, Identifiable {
        public let account: String
        public let message: Ignored.Message
        public var id: String { "\(account)/\(message.id)" }
        /// The chat app of the account, which is its first part (`whatsapp-studio`).
        public var app: String { String(account.split(separator: "-").first ?? "") }
        /// The agent of the account, which is its second part, or nil for an account of the whole fleet.
        public var agent: String? {
            let parts = account.split(separator: "-", maxSplits: 1).map(String.init)
            return parts.count == 2 && parts[1] != "main" ? parts[1] : nil
        }
    }
}

// MARK: - what one person may use of an agent (the person access plan, owner feature `person_scope`)

/// **One person's access with one agent of their list** (`GET /ui/people` `agents[].scope`; the owner's yes of 11
/// November 2026): All, which is whatever the agent holds now and later, or only a list of the agent's own
/// repositories and secrets, each at a level. The hub sends `scope` only where a list can hold, and wherever the person
/// has one, so that the owner can always set All again.
public enum PersonScope: Equatable, Sendable {
    case all
    case only([Entry])

    /// `ui_features` of a hub that reads and writes a person's list.
    public static let feature = "person_scope"
    /// The kinds that a list can name.
    public static let kinds = ["repo", "secret"]

    /// One resource of a list, as the hub gives it back.
    public struct Entry: Decodable, Equatable, Sendable, Identifiable {
        /// `repo:<owner/name>` or `secret:bws://<uuid>`.
        public let resource: String
        /// The resource in words: a repository as `owner/name`, a secret by its name.
        public let title: String
        /// `read` or `write` for a repository, `use` or `read` for a secret.
        public let level: String
        /// The agent holds it now. One that it does not hold stays in the list at the hub, and works again when the
        /// agent gets it back; the app does not draw it, and its next write leaves it out, as the hub would refuse it.
        public let held: Bool
        public var id: String { resource }
        /// `repo` or `secret`.
        public var kind: String { PersonScope.kind(of: resource) }
        /// The repository or the reference after the kind.
        public var what: String { String(resource.drop { $0 != ":" }.dropFirst()) }
        /// The entry in the fewest words: a repository without its owner, a secret by its name.
        public var shortName: String { kind == "repo" ? Integrations.name(what) : title }

        public init(resource: String, title: String, level: String, held: Bool) {
            self.resource = resource; self.title = title; self.level = level; self.held = held
        }

        private enum CodingKeys: String, CodingKey { case resource, title, level, held }

        /// The resource and its level are the entry: without them it is no entry, and a list that holds one is a list
        /// that this app does not read. Its words and `held` read leniently.
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            resource = try values.decode(String.self, forKey: .resource)
            level = try values.decode(String.self, forKey: .level)
            guard let colon = resource.firstIndex(of: ":"), colon > resource.startIndex,
                  resource.index(after: colon) < resource.endIndex, !level.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .resource, in: values,
                                                       debugDescription: "A resource of a list is <kind>:<what>.")
            }
            let words = ((try? values.decodeIfPresent(String.self, forKey: .title)) ?? nil)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            title = words.flatMap { $0.isEmpty ? nil : $0 } ?? String(resource[resource.index(after: colon)...])
            held = ((try? values.decodeIfPresent(Bool.self, forKey: .held)) ?? nil) ?? true
        }
    }

    /// `scope` of one agent of a person's list: nil where the hub sends none, All for its null, and the list
    /// otherwise. A value of another shape is nil too, so the read never fails.
    static func read<Key: CodingKey>(_ values: KeyedDecodingContainer<Key>, _ key: Key) -> PersonScope? {
        guard values.contains(key) else { return nil }
        if (try? values.decodeNil(forKey: key)) == true { return .all }
        return (try? values.decode([Entry].self, forKey: key)).map(PersonScope.only)
    }

    public var isAll: Bool { self == .all }
    /// The entries of the list, as the hub gave them; none for All.
    public var entries: [Entry] { if case .only(let entries) = self { entries } else { [] } }
    /// The list as a page edits it, {resource: level}: the entries that the agent holds now. Empty for All.
    public var list: [String: String] {
        Dictionary(entries.filter(\.held).map { ($0.resource, $0.level) }) { first, _ in first }
    }

    /// The longest two names that the list in a few words writes out both of.
    static let shortMost = 24
    /// The longest name that it writes out whole: a capsule's words never wrap, so a longer one ends in "…".
    static let nameMost = 28

    /// **The list in a few words**, for the select on the person's row of the agent: "abc-crm" for a list of
    /// `exampleowner/abc-crm`, a secret by its name, two short names both, and else the first one and how many more.
    /// Only what the agent holds now. nil for All, and for a list with nothing that the agent holds.
    public var short: String? {
        let names = entries.filter(\.held).map { entry in
            entry.shortName.count > Self.nameMost ? String(entry.shortName.prefix(Self.nameMost - 1)) + "…" : entry.shortName
        }
        guard let first = names.first else { return nil }
        if names.count == 1 { return first }
        if names.count == 2, first.count + names[1].count <= Self.shortMost { return "\(first), \(names[1])" }
        return "\(first) and \(names.count - 1) more"
    }

    /// `repo` or `secret` of a resource id, or what stands before its colon.
    public static func kind(of resource: String) -> String { String(resource.prefix { $0 != ":" }) }

    /// The levels of a kind that a list can give, from the lowest. Deploy is none of them: no list reaches it.
    static func order(_ kind: String) -> [String] {
        switch kind {
        case "repo": ["read", "write"]
        case "secret": ["use", "read"]
        default: []
        }
    }

    /// **The levels that a list can give one resource of an agent that holds it at `agentHas`**: the kind's levels up
    /// to the agent's own, so an agent at Read offers Read only, and Write is a repository's most, whatever the agent
    /// holds above it. Empty for a level that this app does not know.
    public static func levels(_ kind: String, agentHas: String) -> [String] {
        let order = order(kind)
        let top = kind == "repo" && agentHas == "deploy" ? "write" : agentHas
        guard let at = order.firstIndex(of: top) else { return [] }
        return Array(order[...at])
    }

    /// One entry's level as the hub takes it: the lower of the list's and the agent's, or nil when neither fits.
    public static func level(_ wanted: String, kind: String, agentHas: String) -> String? {
        let offered = levels(kind, agentHas: agentHas)
        if let level = offered.first(where: { $0 == (wanted == "deploy" ? "write" : wanted) }) { return level }
        return order(kind).contains(wanted) || wanted == "deploy" ? offered.last : nil
    }

    /// **What a change of the list sends**: each repository and secret that the agent holds now (`holdings`, by
    /// resource, at the agent's own level), at the lower of its level and the agent's, since the hub refuses a level
    /// above the agent's and deploy; one that the agent does not hold is left out, as the hub would refuse it. An entry
    /// of a kind that this app does not draw goes as the hub gave it.
    public static func written(_ list: [String: String], holdings: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (resource, wanted) in list {
            let kind = kind(of: resource)
            guard kinds.contains(kind) else { out[resource] = wanted; continue }
            if let has = holdings[resource], let level = level(wanted, kind: kind, agentHas: has) { out[resource] = level }
        }
        return out
    }

    /// The body of one change of one person's access with one agent (`POST /ui/people`): `scopes` with that agent
    /// alone, so no other agent of the person's list changes; nil is All.
    static func fields(person: Int, agent: String, list: [String: String]?) -> [String: Any] {
        ["id": person, "scopes": [agent: list.map { $0 as Any } ?? NSNull()]]
    }
}

extension ResourceList {
    /// **What a person's list can name of what `agent` holds** (the person access plan): each of its repositories and
    /// secrets by resource (`repo:<owner/name>`, `secret:bws://<uuid>`), at the agent's own level, as its Can use
    /// shows them.
    public func scopeHoldings(of agent: String) -> [String: String] {
        var out: [String: String] = [:]
        for resource in resources where PersonScope.kinds.contains(resource.kind) {
            if let level = resource.holders.first(where: { $0.agent == agent })?.level { out[resource.id] = level }
        }
        return out
    }
}

// MARK: - what the owner writes

/// A new person, or a change to one. The app refuses here what the hub refuses, so the owner sees one sentence before
/// the request leaves.
public struct PersonInput: Equatable, Sendable {
    public var name = ""
    public var role = "customer"
    public var agents: [String] = []
    public var note = ""
    /// The owner's own number of messages a day, or nil while the role's own number counts.
    public var daily: Int?
    /// Where they write from. The same person writes from WhatsApp and from Discord, and it is one person: the hub
    /// takes every handle of a new person in the one command, and a person who is already there gets one more on
    /// their own route.
    public var handles: [HandleInput] = []

    public init() {}

    /// The person as they are now, for the change form.
    public init(_ person: PeopleSnapshot.Person) {
        name = person.name
        role = person.role
        agents = person.agentNames
        note = person.note ?? ""
        daily = person.daily_set
    }

    /// One place a person writes from. The owner writes what he knows — a phone number on WhatsApp, the user ID on
    /// Discord — and this makes the ID the chat app sends. An ID that the hub already holds is kept exactly
    /// (`exact`), so removing one never rewrites it.
    public struct HandleInput: Equatable, Sendable, Identifiable {
        public var app = "whatsapp"
        /// What the owner wrote.
        public var typed = ""
        public var name = ""
        /// The ID as the hub already has it, which wins over anything made from `typed`.
        private var raw: String?
        public let id = UUID()

        public init(app: String = "whatsapp", handle: String = "", name: String = "") {
            self.app = app; self.typed = handle; self.name = name
        }

        /// A handle the hub already holds, by its exact ID.
        public static func exact(app: String, handle: String) -> HandleInput {
            var one = HandleInput(app: app, handle: handle)
            one.raw = handle
            return one
        }

        public static func == (a: HandleInput, b: HandleInput) -> Bool {
            a.app == b.app && a.typed == b.typed && a.name == b.name && a.raw == b.raw
        }

        /// The ID that the chat app sends. A WhatsApp phone number becomes its WhatsApp ID here, so the owner never
        /// types one; anything the owner pasted whole (it carries an `@`) is taken as it is, because a hidden
        /// WhatsApp ID is no phone number.
        public var handle: String {
            if let raw { return raw }
            let said = People.oneLine(typed)
            if said.contains("@") { return said }
            if app == "whatsapp" { return People.whatsappID(from: said) ?? said }
            return said
        }

        /// What this handle would be refused for, in the owner's words, or nil.
        public var problem: String? {
            if !People.apps.contains(app) { return "Choose WhatsApp or Discord." }
            let said = People.oneLine(typed)
            if said.isEmpty {
                return app == "whatsapp" ? "Write their phone number, with the country code."
                                         : "Write their Discord user ID."
            }
            if said.count > 200 { return "That is too long: at most 200 characters." }
            if said.contains("@") || raw != nil { return nil }     // an ID that the chat app itself gave
            if app == "whatsapp" {
                if said.contains(where: { !$0.isWholeNumber && !" +-().".contains($0) }) {
                    return "A phone number is digits and the country code, with no letters."
                }
                if People.whatsappID(from: said) == nil {
                    return "A phone number has 6 to 15 digits, with the country code."
                }
                return nil
            }
            if said.contains(where: { !$0.isWholeNumber }) || !(5...25).contains(said.count) {
                return "A Discord user ID is the number Discord copies, 5 to 25 digits."
            }
            return nil
        }

        /// What this handle shows once it is made: the ID the hub will hold.
        public var made: String? { problem == nil ? handle : nil }

        var fields: [String: Any] {
            var body: [String: Any] = ["app": app, "handle": handle]
            let said = People.oneLine(name)
            if !said.isEmpty { body["name"] = said }
            return body
        }
    }

    /// What the hub would refuse, in the owner's words, or nil. `existing` is how many people the fleet has, for the
    /// limit that the hub keeps.
    public func problem(existing: Int = 0, adding: Bool = true) -> String? {
        let said = People.oneLine(name)
        if said.isEmpty { return "Write the name you know them by." }
        if said.count > People.nameMax { return "A name is at most \(People.nameMax) characters." }
        // Any role the hub gave: the hub keeps the list, and a person keeps the role they have.
        if People.oneLine(role).isEmpty { return "Choose a role." }
        if agents.count > People.agentsMax { return "A person reaches at most \(People.agentsMax) agents." }
        if note.count > People.noteMax { return "The note is at most \(People.noteMax.formatted()) characters." }
        if let daily, !(0...People.dailyMax).contains(daily) { return "Messages a day is 0 to \(People.dailyMax.formatted())." }
        if adding {
            if handles.count > People.handlesMax { return "A person has at most \(People.handlesMax) handles." }
            if let said = handles.compactMap(\.problem).first { return said }
            let made = handles.map { "\($0.app)/\($0.handle)" }
            if Set(made).count != made.count { return "The same handle is in the list two times." }
        }
        if adding, existing >= People.peopleMax { return "This fleet already has \(People.peopleMax) people." }
        return nil
    }

    /// The body of `POST /ui/people` for a new person.
    var addFields: [String: Any] {
        var body: [String: Any] = ["name": People.oneLine(name), "role": role, "agents": agents.sorted()]
        let said = note.trimmingCharacters(in: .whitespacesAndNewlines)
        body["note"] = said.isEmpty ? NSNull() : said
        body["daily"] = daily.map { $0 as Any } ?? NSNull()
        let ready = handles.filter { $0.problem == nil }
        if !ready.isEmpty { body["handles"] = ready.map(\.fields) }
        return body
    }

    /// The body of a change: only the fields that differ from the person as the hub has them. An empty change sends
    /// nothing, because the hub would write a record of it.
    func changeFields(from person: PeopleSnapshot.Person) -> [String: Any] {
        var body: [String: Any] = [:]
        let said = People.oneLine(name)
        if said != person.name { body["name"] = said }
        if role != person.role { body["role"] = role }
        if agents.sorted() != person.agentNames.sorted() { body["agents"] = agents.sorted() }
        let wrote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if wrote != (person.note ?? "") { body["note"] = wrote.isEmpty ? NSNull() : wrote }
        if daily != person.daily_set { body["daily"] = daily.map { $0 as Any } ?? NSNull() }
        return body
    }
}

extension People {
    /// The chat apps a handle can be on.
    public static let apps = ["whatsapp", "discord"]

    /// What the owner is asked for on each chat app, because the app makes the ID itself.
    public static func handleAsk(_ app: String) -> String {
        app == "whatsapp" ? "Their phone number" : "Their Discord user ID"
    }

    public static func handlePlaceholder(_ app: String) -> String {
        app == "whatsapp" ? "+34 600 111 222" : "100200300"
    }

    public static func handleHint(_ app: String) -> String {
        app == "whatsapp" ? "With the country code. Founderizer makes the WhatsApp ID itself."
                          : "Discord, Settings, Advanced, Developer Mode: right-click them and Copy User ID."
    }
}

// MARK: - the roles (plan P1, owner feature `contact_roles`)

/// `GET /ui/roles`: every role of the fleet, as the owner wrote it. A role is a name, a prompt in the owner's words (what
/// the agent is told about such a person) and one switch: whether their conversations run with the agent's own tools,
/// or closed. Only the owner writes them; the admin MCP and this app are his two ways to.
public struct RoleList: Decodable, Sendable {
    /// The hub lists it only while contacts.v2 is on: before the switch the people hold the four old roles, and the
    /// owner sees no Roles card beside them (the coordinator of AUTONOMY.md, 27 October 2026).
    public static let feature = "contact_roles"
    public static let promptMax = 4000

    public struct Role: Decodable, Equatable, Sendable, Identifiable {
        public let name: String
        public let prompt: String
        public let tools: Bool
        /// The messages a day of a closed role, or nil for no limit.
        public let daily: Int?
        /// How many people hold it.
        public let people: Int?
        public var id: String { name }
        public var word: String { People.roleWord(name) }
    }

    public let db: String
    public let roles: [Role]

    public func validate(database: String) throws {
        guard db == database, Set(roles.map(\.name)).count == roles.count,
              roles.allSatisfy({ !$0.name.isEmpty && $0.prompt.count <= Self.promptMax })
        else { throw HubError.invalidResponse }
    }

    public func role(_ name: String) -> Role? { roles.first { $0.name == name } }

    /// The name the hub keeps for what the owner typed — lower case, a hyphen for a space, without the spaces at its
    /// ends — or nil when that is no name of a role: 2 to 31 letters, digits and hyphens, the first a letter. The
    /// owner types "Key account" and the hub keeps `key-account`, as he never types a WhatsApp ID either.
    public static func name(from typed: String) -> String? {
        let made = typed.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: "-")
        return made.range(of: "^[a-z][a-z0-9-]{1,30}$", options: .regularExpression) != nil ? made : nil
    }

    /// Why what the owner typed is no name of a role, in his words.
    public static let nameRule = "A role's name is 2 to 31 letters, digits or hyphens, and starts with a letter."
}

/// The answer to a write of a role: the role as the hub now has it, and the fields that changed.
public struct RoleReceipt: Decodable, Sendable {
    public let ok: Bool
    public let request_id: String
    public let client: String
    public let replayed: Bool?
    public let role: RoleList.Role?
    public let changed: [String]?

    func validate(requestID: String, client: String, name: String) throws {
        guard ok, request_id.lowercased() == requestID, self.client == client, role.map({ $0.name == name }) != false
        else { throw HubError.invalidResponse }
    }
}

// MARK: - the conversations

/// `GET /ui/conversations`: every conversation between an agent and a person, newest first.
public struct ConversationList: Decodable, Sendable {
    public let db: String
    public let conversations: [Conversation]

    public func validate(database: String) throws {
        guard db == database else { throw HubError.invalidResponse }
    }
}

/// The head of one conversation: who is in it, where it runs, and what is in it now.
public struct Conversation: Decodable, Equatable, Sendable, Identifiable {
    public struct Party: Decodable, Equatable, Sendable {
        public let id: Int
        public let name: String
        public let role: String
        public var roleWord: String { People.roleWord(role) }
    }

    /// The newest message of the conversation, for the list's one line.
    public struct Newest: Decodable, Equatable, Sendable {
        public let who: String
        public let text: String
        public let created: Double?
    }

    public let id: Int
    public let agent: String
    public let person: Party?
    public let account: String?
    /// `open` or `paused`. An unknown state from a newer hub shows as its own text.
    public let state: String
    public let created: Double?
    public let last: Double?
    public let messages: Int?
    /// The person's messages that the agent has not read.
    public let waiting: Int?
    /// The questions and work requests of this conversation that wait for the owner.
    public let open_needs: Int?
    public let newest: Newest?

    public var isPaused: Bool { state == "paused" }
    public var waitingCount: Int { waiting ?? 0 }
    public var openNeeds: Int { open_needs ?? 0 }
    /// The chat app of the account, which is its first part (`whatsapp-studio`).
    public var app: String? {
        guard let account, let first = account.split(separator: "-").first else { return nil }
        return People.apps.contains(String(first)) ? String(first) : nil
    }

    /// The one line a row shows: who said the last thing, and what it was.
    public var line: String? {
        guard let newest else { return nil }
        let text = People.oneLine(newest.text)
        guard !text.isEmpty else { return nil }
        switch newest.who {
        case "person": return "\(person?.name ?? "They"): \(text)"
        case "agent": return "\(People.agentWord(agent)): \(text)"
        case "owner": return "You: \(text)"
        default: return text
        }
    }

    /// What needs the owner, in a few words: his own answer first, then a message nobody read, then a pause.
    public func state(now: Double) -> (words: String, attention: Bool)? {
        if openNeeds > 0 { return (openNeeds == 1 ? "Waits for you" : "\(openNeeds) wait for you", true) }
        if isPaused { return ("Paused", true) }
        if waitingCount > 0 { return ("\(waitingCount) not read yet", false) }
        if state != "open" { return (state, false) }
        return nil
    }
}

extension Conversation {
    /// **The same fact as one mark.** `state` is the sentence behind it, and nil there — an ordinary open
    /// conversation with nothing to say about it — is what a tick is for.
    ///
    /// Only what waits for *him* is a cross. A conversation he paused, and messages an agent has not read yet,
    /// are worth knowing and are not failures.
    public func mark(now: Double) -> MarkState {
        if openNeeds > 0 { return .bad }
        if isPaused || waitingCount > 0 { return .warn }
        return .good
    }
}

/// `GET /ui/conversations/<id>`: the same head, and the whole record oldest first.
public struct ConversationRecord: Decodable, Sendable {
    public let db: String
    public let head: Conversation
    public let items: [ConversationItem]

    private enum CodingKeys: String, CodingKey { case db, items }

    public init(from decoder: Decoder) throws {
        head = try Conversation(from: decoder)
        let data = try decoder.container(keyedBy: CodingKeys.self)
        db = try data.decode(String.self, forKey: .db)
        items = try data.decodeIfPresent([ConversationItem].self, forKey: .items) ?? []
    }

    public func validate(database: String, conversation: Int) throws {
        guard db == database, head.id == conversation else { throw HubError.invalidResponse }
    }

    /// The number of the last item, for the next page (`after`).
    public var lastNumber: Int { items.compactMap(\.number).max() ?? 0 }
}

/// One line of the record: what the person wrote, what the agent answered, what the agent did about it, or what the
/// owner answered.
public struct ConversationItem: Decodable, Equatable, Sendable, Identifiable {
    /// What the agent did, with the Needs-you item behind it.
    public struct Need: Decodable, Equatable, Sendable {
        public let id: Int
        /// `question` or `work`.
        public let kind: String?
        public let title: String?
        public let answer: String?
        public let answered: Double?
        public var isOpen: Bool { answer == nil && answered == nil }
    }

    /// The newest send of a reply, as the chat app reported it.
    public struct Delivery: Decodable, Equatable, Sendable {
        public let outbound: Int?
        /// `queued`, `sending`, `sent`, `delivered`, `read`, `failed`, `unknown` or `expired`.
        public let state: String
        public let at: Double?
        public let error: String?

        public var isProblem: Bool { state == "failed" || state == "unknown" || state == "expired" }
        /// Only the owner decides to send again what failed or what is not confirmed.
        public var canSendAgain: Bool { isProblem && (outbound ?? 0) > 0 }

        /// The delivery in words, for the hover text and for assistive apps.
        public func words(app: String?, time: (Double) -> String) -> String {
            let name = app.map { ChatApps.title($0) } ?? "the chat app"
            let when = at.map { " \(time($0))" } ?? ""
            switch state {
            case "queued": return "Waiting to send to \(name)"
            case "sending": return "Sending to \(name)…"
            case "sent": return "Sent to \(name)" + when
            case "delivered": return "Sent to \(name) · Delivered" + when
            case "read": return "Sent to \(name) · Read" + when
            case "failed":
                let reason = (error ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return reason.isEmpty ? "Not sent to \(name)." : "Not sent: \(reason)\(reason.hasSuffix(".") ? "" : ".")"
            case "unknown": return "Delivery to \(name) not confirmed"
            case "expired": return "Too old to send to \(name)"
            default: return "\(name) delivery: \(state)"
            }
        }
    }

    /// `CM-7`, as the hub writes it.
    public let id: String
    /// `person`, `agent`, `owner` or `action`.
    public let who: String
    public let text: String
    public let created: Double?
    public let read_at: Double?
    public let in_reply_to: String?
    public let need: Need?
    public let delivery: Delivery?

    /// The number in `CM-7`, for the next page.
    public var number: Int? { Int(id.dropFirst(id.hasPrefix("CM-") ? 3 : 0)) }
    public var isAction: Bool { who == "action" }

    /// Who said it, in the owner's words. An unknown kind from a newer hub shows as its own text.
    public func said(person: String?, agent: String) -> String {
        switch who {
        case "person": return person ?? "They"
        case "agent": return People.agentWord(agent)
        case "owner": return "You"
        case "action": return People.agentWord(agent)
        default: return who
        }
    }

    /// What an action is waiting for, in a few words, or nil when it is not an action.
    public var actionState: (words: String, attention: Bool)? {
        guard isAction, let need else { return nil }
        if need.isOpen { return ("Waits for you", true) }
        return ("You answered", false)
    }
}

// MARK: - the hub

/// The people and conversation routes of the owner address (UI-API.md 1.17). Each write is one command with a new
/// request ID and the current `db`; a write without an answer can have arrived, so the page reads again before the
/// owner tries once more.
public final class PeopleClient: Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration, delegate: PeopleNoRedirect(), delegateQueue: nil)
    }

    public func people(hub: URL, database: String) async throws -> PeopleSnapshot {
        let snapshot = try JSONDecoder().decode(PeopleSnapshot.self, from: await get("ui/people", hub: hub, database: database))
        try snapshot.validate(database: database)
        return snapshot
    }

    /// Every role of the fleet (plan P1), in the hub's order.
    public func roles(hub: URL, database: String) async throws -> RoleList {
        let list = try JSONDecoder().decode(RoleList.self, from: await get("ui/roles", hub: hub, database: database))
        try list.validate(database: database)
        return list
    }

    /// Changes one role: its prompt, its switch, or its name (`rename`, which the hub does with the people who hold
    /// the role in the same write). The hub keeps every field this does not name.
    public func role(hub: URL, database: String, client: String, name: String, prompt: String? = nil,
                     tools: Bool? = nil, rename: String? = nil) async throws -> RoleReceipt {
        var fields: [String: Any] = ["name": name]
        if let prompt { fields["prompt"] = prompt }
        if let tools { fields["tools"] = tools }
        if let rename { fields["rename"] = rename }
        let requestID = UUID().uuidString.lowercased()
        let receipt = try JSONDecoder().decode(RoleReceipt.self,
                                               from: await post("ui/roles", fields: fields, requestID: requestID,
                                                                hub: hub, database: database, client: client))
        try receipt.validate(requestID: requestID, client: client, name: rename ?? name)
        return receipt
    }

    /// Every conversation, newest first; `agent` and `person` narrow it.
    public func conversations(hub: URL, database: String, agent: String? = nil, person: Int? = nil) async throws -> ConversationList {
        var query: [URLQueryItem] = []
        if let agent, !agent.isEmpty { query.append(.init(name: "agent", value: agent)) }
        if let person { query.append(.init(name: "person", value: String(person))) }
        let list = try JSONDecoder().decode(ConversationList.self,
                                            from: await get("ui/conversations", hub: hub, database: database, query: query))
        try list.validate(database: database)
        return list
    }

    /// One conversation, oldest first, at most 200 items after `after`.
    public func conversation(hub: URL, database: String, id: Int, after: Int = 0) async throws -> ConversationRecord {
        guard id > 0, after >= 0 else { throw HubError.invalidResponse }
        let query = after > 0 ? [URLQueryItem(name: "after", value: String(after))] : []
        let record = try JSONDecoder().decode(ConversationRecord.self,
                                              from: await get("ui/conversations/\(id)", hub: hub, database: database, query: query))
        try record.validate(database: database, conversation: id)
        return record
    }

    /// Adds a person. The answer carries them as the hub now has them.
    public func add(hub: URL, database: String, client: String, person: PersonInput) async throws -> PersonReceipt {
        try await write("ui/people", fields: person.addFields, hub: hub, database: database, client: client)
    }

    /// Changes a person: only the fields that differ. Nothing to change writes nothing.
    public func change(hub: URL, database: String, client: String, person: PeopleSnapshot.Person,
                       to input: PersonInput) async throws -> PersonReceipt? {
        let fields = input.changeFields(from: person)
        guard !fields.isEmpty else { return nil }
        return try await write("ui/people", fields: fields.merging(["id": person.id]) { _, new in new },
                               hub: hub, database: database, client: client)
    }

    /// **Sets what one person may use of one agent of their list** (feature `person_scope`): All with nil, else only
    /// the list, {resource: level}. Only that agent's access changes.
    public func scope(hub: URL, database: String, client: String, person: Int, agent: String,
                      list: [String: String]?) async throws -> PersonReceipt {
        try await write("ui/people", fields: PersonScope.fields(person: person, agent: agent, list: list), hub: hub,
                        database: database, client: client)
    }

    /// Blocks a person, or lets them write again.
    public func block(hub: URL, database: String, client: String, person: Int, blocked: Bool) async throws -> PersonReceipt {
        try await write("ui/people", fields: ["id": person, "blocked": blocked], hub: hub, database: database, client: client)
    }

    /// Removes a person with everything of theirs. There is no undo.
    public func remove(hub: URL, database: String, client: String, person: Int) async throws -> PersonReceipt {
        try await write("ui/people", fields: ["id": person, "delete": true], hub: hub, database: database, client: client)
    }

    /// Gives a person one more handle, or takes one away.
    public func handle(hub: URL, database: String, client: String, person: Int,
                       handle: PersonInput.HandleInput, delete: Bool = false) async throws -> PersonReceipt {
        var fields = handle.fields
        if delete { fields["delete"] = true; fields["name"] = nil }
        return try await write("ui/people/\(person)/handles", fields: fields, hub: hub, database: database, client: client)
    }

    /// Pauses a conversation, or lets it run again. A paused conversation keeps every message that arrives.
    public func conversation(hub: URL, database: String, client: String, id: Int, pause: Bool) async throws -> ConversationReceipt {
        guard id > 0 else { throw HubError.invalidResponse }
        let requestID = UUID().uuidString.lowercased()
        let receipt = try JSONDecoder().decode(
            ConversationReceipt.self,
            from: await post("ui/conversations/\(id)", fields: ["action": pause ? "pause" : "resume"],
                             requestID: requestID, hub: hub, database: database, client: client))
        try receipt.validate(requestID: requestID, client: client)
        return receipt
    }

    private func write(_ route: String, fields: [String: Any], hub: URL, database: String,
                       client: String) async throws -> PersonReceipt {
        let requestID = UUID().uuidString.lowercased()
        let receipt = try JSONDecoder().decode(PersonReceipt.self,
                                               from: await post(route, fields: fields, requestID: requestID,
                                                                hub: hub, database: database, client: client))
        try receipt.validate(requestID: requestID, client: client)
        return receipt
    }

    private func post(_ route: String, fields: [String: Any], requestID: String, hub: URL, database: String,
                      client: String) async throws -> Data {
        var request = URLRequest(url: hub.appendingPathComponent(route))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client, forHTTPHeaderField: "X-Fleet-Client")
        request.httpBody = try IntegrationsClient.body(fields, requestID: requestID, database: database)
        return try await perform(request)
    }

    private func get(_ route: String, hub: URL, database: String, query: [URLQueryItem] = []) async throws -> Data {
        var parts = URLComponents(url: hub.appendingPathComponent(route), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "db", value: database)] + query
        guard let url = parts.url else { throw HubError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        // A read of the hub that is on its way already, through any client with the same time limits, is the answer to
        // the same read now (`HubReads`, fix round 2); a write never is.
        guard let key = HubReads.key(request, in: session.configuration) else { return try await fetch(request) }
        return try await HubReads.shared.share(key) { [self] in HubReads.Answer(data: try await fetch(request), response: nil) }.data
    }

    private func fetch(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        HubWrites.note(request)
        guard let response = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        guard response.statusCode == 200 else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "Unexpected HTTP response."
            throw HubError.refusal(response.statusCode, String(message.prefix(500)))
        }
        guard data.count <= 4_194_304 else { throw HubError.invalidResponse }
        return data
    }

    private struct ErrorBody: Decodable { let error: String }
}

/// The answer to a write about a person: the person as the hub now has them, what changed, or what a removal took.
public struct PersonReceipt: Decodable, Sendable {
    public let ok: Bool
    public let request_id: String
    public let client: String
    public let replayed: Bool?
    public let person: Removed?
    public let changed: [String]?
    public let deleted: Bool?
    /// How many conversations a removal took with it.
    public let conversations: Int?
    /// The person as the hub now has them; nil for a removal, which keeps only their number and name.
    public let full: PeopleSnapshot.Person?

    private enum CodingKeys: String, CodingKey {
        case ok, request_id, client, replayed, person, changed, deleted, conversations
    }

    /// What a removal gives back: the number and the name, and nothing else.
    public struct Removed: Decodable, Sendable {
        public let id: Int
        public let name: String?
    }

    public init(from decoder: Decoder) throws {
        let data = try decoder.container(keyedBy: CodingKeys.self)
        ok = try data.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        request_id = try data.decode(String.self, forKey: .request_id)
        client = try data.decode(String.self, forKey: .client)
        replayed = try data.decodeIfPresent(Bool.self, forKey: .replayed)
        person = try data.decodeIfPresent(Removed.self, forKey: .person)
        changed = try data.decodeIfPresent([String].self, forKey: .changed)
        deleted = try data.decodeIfPresent(Bool.self, forKey: .deleted)
        conversations = try data.decodeIfPresent(Int.self, forKey: .conversations)
        full = try? data.decodeIfPresent(PeopleSnapshot.Person.self, forKey: .person)
    }

    func validate(requestID: String, client: String) throws {
        guard ok, request_id.lowercased() == requestID, self.client == client else { throw HubError.invalidResponse }
    }
}

/// The answer to a pause or a resume: the conversation as the hub now has it.
public struct ConversationReceipt: Decodable, Sendable {
    public let ok: Bool
    public let request_id: String
    public let client: String
    public let replayed: Bool?
    public let conversation: Conversation?

    func validate(requestID: String, client: String) throws {
        guard ok, request_id.lowercased() == requestID, self.client == client else { throw HubError.invalidResponse }
    }
}

private final class PeopleNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
