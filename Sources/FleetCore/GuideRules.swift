import Foundation

// The onboarding guide: the rules that the app holds each tool call and each message to, as pure functions
// (`~/dev/founderizer-plans/onboarding-guide-spec.md`, sections 3.3, 3.4 and 3.5, lane K). The model has no tool that
// writes in a fleet. It proposes, and these rules decide what of a proposal the app shows. A refusal says in one
// sentence which rule the call broke, so that the model can ask the owner. A refused call shows nothing.

/// **The guide is off.** No page, card or word of it shows, no flow starts its session, and the first run is as it was.
/// To turn it on is the owner's own word for a release, with what he then sees first (the spec's section 9, step 8):
/// no lane changes this by itself. A lane that builds a part of the guide starts nothing while this is false.
public enum GuideSwitch {
    public static let isOn = false
}

/// The guide's own six tools, by their names. With the base's two they are the model's whole tool list.
public enum GuideTool: String, CaseIterable, Sendable {
    case proposeTeam = "propose_team"
    case askSecret = "ask_secret"
    case checkServers = "check_servers"
    case proposeServers = "propose_servers"
    case offerRepair = "offer_repair"
    case finish

    /// The two tools of the helper's base that the set `guide` also holds.
    public static let base = ["setup_state", "setup_show"]
    /// **The guide's list: the eight names that the model has, and no other** (`GuideCheck` holds each turn to it).
    public static let list = base + allCases.map(\.rawValue)
}

/// Why the app refused a tool call: one sentence for the model.
public struct GuideRefusal: Error, Equatable, Sendable {
    public let says: String
    public init(_ says: String) { self.says = says }
}

/// Why the box did not take a text of the owner's. The words for it are the view's.
public enum GuideBoxRefusal: Error, Equatable, Sendable {
    case empty
    /// The text holds what looks like a key. It is not sent and not kept, and nothing offers to send it anyway.
    case looksLikeAKey
}

/// What came of one thing that an agent uses, for `finish`.
public enum GuideUseResult: String, Codable, Sendable {
    case saved, declined, connected
    case passedOver = "passed_over"
    /// The app does not ask for it in the setup: the hand-over names it, and its agent asks for it later.
    case later
}

/// **The team of a `propose_team` call, as the app checked it.** A pressed card of it is what the app carries out, and
/// what each grant is held to.
public struct GuideTeam: Codable, Equatable, Sendable {
    public struct Use: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable, CaseIterable { case repo, key, login, gmail, drive }
        public var kind: Kind
        /// A repository as `owner/name`, a service's name, or a mailbox. The owner typed it.
        public var name: String
        public init(kind: Kind, name: String) { self.kind = kind; self.name = name }

        /// The same thing of the same agent, whatever the case of its letters.
        public func key(role: String) -> String { "\(role.lowercased())|\(kind.rawValue)|\(name.lowercased())" }
        func isSame(_ other: Use) -> Bool { kind == other.kind && name.lowercased() == other.name.lowercased() }
    }

    public struct Agent: Codable, Equatable, Sendable {
        /// The name that the agent gets in the hub. The app makes it, as Add agent suggests one.
        public var name: String
        public var role: String
        public var does: String
        public var uses: [Use]
        /// What goes to the owner first. It becomes the profile's section "Must ask first".
        public var asksFirst: String?
        /// Such an agent runs on a Mac.
        public var needsBrowser: Bool
    }

    public var agents: [Agent]
    /// The owner's first answer, when the guide gave it with the team.
    public var use: FleetUse?

    public func agent(role: String) -> Agent? { agents.first { $0.role.lowercased() == role.lowercased() } }

    /// **The team as the card "Your fleet" draws it** (`FleetCard`). `words` gives the name of a thing as the card
    /// shows it ("Stripe key"): those are the view's words.
    public func plan(manager: String, words: (Use) -> String = { $0.name }) -> FleetPlan {
        FleetPlan(manager: manager, agents: agents.map { agent in
            let shown = agent.uses.first.flatMap { use -> FleetPlan.Use? in
                let kind: FleetPlan.Use.Kind? = switch use.kind {
                case .repo: .repository
                case .key: .key
                case .login: .login
                case .gmail: .mailbox
                case .drive: nil
                }
                return kind.map { FleetPlan.Use(kind: $0, name: words(use)) }
            }
            return FleetPlan.Agent(name: agent.name, role: agent.role, does: agent.does, asksFirst: agent.asksFirst,
                                   uses: shown, needsBrowser: agent.needsBrowser)
        })
    }
}

/// A role that a server of the owner's can take on the card "Your servers".
public enum GuideServerRole: String, Codable, Sendable, CaseIterable { case hub, agents, apps, out }

public struct GuideServerChoice: Codable, Equatable, Sendable {
    public var name: String
    public var role: GuideServerRole
    public init(name: String, role: GuideServerRole) { self.name = name; self.role = role }
}

/// Why a server takes no install, as one of the check's fixed kinds. Never the server's own text.
public enum GuideServerStop: String, Codable, Sendable, CaseIterable {
    case unreached, system, machine
    case noSystemd = "no_systemd"
    case notRoot = "not_root"
    case memory, disk
    case noIPv4 = "no_ipv4"
    case noHTTPS = "no_https"
    case otherTailnet = "other_tailnet"
    /// The server is still starting or installs its updates: the same check later answers again.
    case busy
}

/// **One server of a check, as the model gets it and as the card "Your servers" draws its line**: typed values only.
/// The card's line is the system, the memory and the ports, in that order; its words are the view's.
public struct GuideServerFact: Codable, Equatable, Sendable {
    /// Letters, digits, "-" and ".", 63 at most.
    public var name: String
    public var address: String
    /// The app's own words for the system: its name from the app's table with the version ("Ubuntu 24.04"), or
    /// "Other system" for an id that the table does not have.
    public var system: String
    public var memoryGB: Int?
    /// The TCP ports that answer from outside, without SSH.
    public var ports: [Int]
    /// The roles that the fleet's rules allow on this server.
    public var roles: [GuideServerRole]
    /// The server takes none of this Mac's keys, or its `sudo` asks for a password. The check asks for none.
    public var needsPassword: Bool
    public var stop: GuideServerStop?

    public static let otherSystem = "Other system"

    var value: GuideValue {
        var fields: [String: GuideValue] = [
            "name": .text(name), "address": .text(address), "system": .text(system),
            "ports": .list(ports.map(GuideValue.number)), "roles": .list(roles.map { .text($0.rawValue) }),
            "needs_password": .flag(needsPassword),
        ]
        if let memoryGB { fields["memory_gb"] = .number(memoryGB) }
        if let stop { fields["stop"] = .text(stop.rawValue) }
        return .fields(fields)
    }
}

/// What a `check_servers` call asks the app to check.
public enum GuideServersAsk: Equatable, Sendable {
    case addresses([String])
    /// The servers of the owner's account at this provider, 20 at most.
    case provider(CloudProvider)
}

/// The step for one secret that a checked `ask_secret` call shows. The host, the address and the variable's name are
/// the app's own, from its table: the model gave the service's name only.
public struct GuideSecretStep: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case key, login }
    public var service: GuideServices.Service
    public var kind: Kind
    /// The agent that gets it, by its role on the card and by its name in the hub.
    public var holderRole: String
    public var holderName: String
    /// The guide's own words for what the owner does on the service's page, drawn as plain words.
    public var steps: [String]
}

/// What the app may give by itself for a thing of the pressed team card.
public enum GuideGrant: Equatable, Sendable {
    /// A key or a login goes to this agent at `use`: its vault uses it for the agent, and the agent never reads it.
    case use(agent: String)
    /// The card shows no level for this thing, so the app gives none by itself: the owner sets it on the app's page.
    case ownerSetsLevel
}

/// What the app knows at a call that is not in the kept state.
public struct GuideFacts: Equatable, Sendable {
    /// The part of the first run that has work that runs now, by its fixed name ("build", "install", "check"). nil
    /// when none runs.
    public var busy: String?
    /// The manager's name, as the owner typed it on "Name your manager".
    public var manager: String
    /// How many agents the servers that are paid for can take. nil until a paid press was made.
    public var room: Int?
    /// The providers whose token this Mac holds.
    public var tokens: Set<CloudProvider>
    public var hubExists: Bool
    /// The card "Your servers" can show: "Server for apps" is in the app, and the words of what changes on a server
    /// that runs apps have the owner's yes. Until then `propose_servers` is refused.
    public var serversCard: Bool

    public init(busy: String? = nil, manager: String = ManagerName.suggested, room: Int? = nil,
                tokens: Set<CloudProvider> = [], hubExists: Bool = false, serversCard: Bool = false) {
        self.busy = busy; self.manager = manager; self.room = room; self.tokens = tokens
        self.hubExists = hubExists; self.serversCard = serversCard
    }
}

public enum GuideRules {
    // MARK: - The owner's message

    /// The box's guard: a text that `KeyInText` matches, and a text that holds a run of 24 or more letters and digits
    /// with no other character (a token of digits and capitals, or of hex, has no shape that `KeyInText` knows). It
    /// does not catch a password or a short key.
    public static func guardRefuses(_ text: String) -> Bool {
        KeyInText.contains(text) || text.range(of: "[A-Za-z0-9]{24,}", options: .regularExpression) != nil
    }

    /// **The text of the owner's that the app keeps, or why the box does not take it.** The marks of an event go out of
    /// the text first, because without them the text can read as a key; then the guard. The kept text is the owner's
    /// own words, with no change: `plain` makes of it what goes to the program.
    public static func ownerMessage(_ typed: String) -> Result<String, GuideBoxRefusal> {
        let text = withoutMarks(typed).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        guard !guardRefuses(text) else { return .failure(.looksLikeAKey) }
        return .success(text)
    }

    /// The text with each mark of an event taken out, until none is left.
    static func withoutMarks(_ text: String) -> String {
        var text = text
        while let mark = text.range(of: "<\\s*/?\\s*app-event\\s*>", options: [.regularExpression, .caseInsensitive]) {
            text.removeSubrange(mark)
        }
        return text
    }

    /// The first characters that Claude Code can take for itself in a message. Run on 2.1.312 on 15 November 2026:
    /// the program answers "/context" itself, with no call of the model, and it reads a file that a message names after
    /// "@" and gives the model its content. "!" and "#" at the start went to the model as plain words: they are here
    /// for a later version.
    static let taken: Set<Character> = ["/", "@", "!", "#"]
    /// What stands before such a character: a space of no width. It is no white space for the program, so the text
    /// does not begin with the character and the "@" does not begin a word, and it changes no word for the model.
    static let lead = "\u{200B}"

    /// **The text as plain words for the program.** Each text that the app writes to the program passes this, the
    /// app's own events too (`GuideCommand.message`).
    ///
    /// - A first character "/", "!" or "#" gets the lead before it.
    /// - **Each "@" that can begin the name of a file gets the lead before it.** The program reads a word that begins
    ///   with "@", or an "@" after one of four marks of Chinese and Japanese text, as a file's name, anywhere in a
    ///   message (its own code, 2.1.312). Here that is each "@" with no letter and no digit before it, which is more
    ///   than the program's rule. The "@" of a mail address stays as it is.
    ///
    /// A text that passed it one time does not change again.
    public static func plain(_ text: String) -> String {
        var plain = ""
        var before: Character?
        for character in text {
            if character == "@", before.map({ !$0.isLetter && !$0.isNumber && String($0) != lead }) ?? true { plain += lead }
            plain.append(character)
            before = character
        }
        if let first = plain.first, taken.contains(first) { plain = lead + plain }
        return plain
    }

    /// A text of a tool call with the lead taken out: the model can give a name back with the lead that it read in it.
    static func withoutLead(_ text: String) -> String { text.replacingOccurrences(of: lead, with: "") }

    // MARK: - The name rule

    /// The whole words of a text, in small letters. A word ends at a space and at the marks that end a name: a comma,
    /// a semicolon, a bracket, a quotation mark, and a full stop, a question mark, an exclamation mark or a colon at
    /// the word's end.
    static func words(of text: String) -> [String] {
        let between = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;()[]{}<>\"'“”‘’«»¿¡"))
        return withoutLead(text).lowercased().unicodeScalars.split { between.contains($0) }.compactMap { part in
            var word = String(String.UnicodeScalarView(part))
            while let last = word.last, ".?!:".contains(last) { word.removeLast() }
            return word.isEmpty ? nil : word
        }
    }

    /// **The name rule: a name that the owner must have given is a whole word of a message that the owner typed in
    /// this conversation**, with no difference of case. A part of a word does not count: `203.0.113.5` is not in
    /// `203.0.113.50`. A name of several words holds when its words stand one after the other in one message. `typed`
    /// is `GuideState.typed`: a pressed row is not in it, because its words are the model's.
    public static func isNamed(_ name: String, by typed: [String]) -> Bool {
        let wanted = words(of: name)
        guard !wanted.isEmpty else { return false }
        return typed.contains { message in
            let has = words(of: message)
            guard has.count >= wanted.count else { return false }
            return (0...(has.count - wanted.count)).contains { Array(has[$0..<($0 + wanted.count)]) == wanted }
        }
    }

    // MARK: - The suggestions

    /// **The guide's words as the conversation draws them, and the rows under them.** The guide ends a message with a
    /// block between `<suggestions>` and `</suggestions>`, one suggestion on each line. The block goes out of the
    /// drawn words. Its lines are rows only when there are two to six of them, each of 60 characters at most and of
    /// plain words: no mark of the program's own at its start, and no "@", "<", ">" or "`" in it. Else nothing of the
    /// block is drawn.
    public static func suggestions(in text: String) -> (words: String, rows: [String]) {
        var words = text
        var block: String?
        while let open = words.range(of: "<suggestions>", options: .caseInsensitive) {
            if let close = words.range(of: "</suggestions>", options: .caseInsensitive, range: open.upperBound..<words.endIndex) {
                block = String(words[open.upperBound..<close.lowerBound])
                words.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                // A block with no end: what follows the mark is not the guide's words for the owner.
                block = nil
                words.removeSubrange(open.lowerBound..<words.endIndex)
            }
        }
        words = words.replacingOccurrences(of: "</suggestions>", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = (block ?? "").split(whereSeparator: \.isNewline).map { line -> String in
            var row = line.trimmingCharacters(in: .whitespaces)
            for bullet in ["- ", "* ", "• "] where row.hasPrefix(bullet) { row.removeFirst(bullet.count) }
            return row.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        let plainRows = lines.allSatisfy { row in
            row.count <= 60 && !taken.contains(row.first!) && !row.contains(where: { "@<>`".contains($0) }) && !guardRefuses(row)
        }
        return (words, (2...6).contains(lines.count) && plainRows ? lines : [])
    }

    // MARK: - propose_team

    /// How many things of an agent the card "Your fleet" shows, and which kinds it has a mark for. **The app gives
    /// nothing that no pressed card names, so a call cannot hold more than the card shows.**
    static let usesOnCard = 1
    static let kindsOnCard: Set<GuideTeam.Use.Kind> = [.repo, .key, .login, .gmail]

    /// **The check of a `propose_team` call.** On success the caller keeps the team as a card that shows
    /// (`GuideState.show(team:)`) and answers `{"shown": true, "card": "<id>"}`.
    public static func proposeTeam(_ arguments: Any?, state: GuideState, facts: GuideFacts) -> Result<GuideTeam, GuideRefusal> {
        refusing {
            try notBusy(facts)
            if state.fleet.contains(.restored) { throw GuideRefusal("The owner restored a copy of a fleet, and that fleet has its own team.") }
            if state.fleet.contains(.teamMade) { throw GuideRefusal("The app has made the agents, so the team cannot change in the setup.") }
            let call = try Fields(arguments, of: "propose_team", has: ["agents", "use"])
            let use = try call.word("use", of: FleetUse.self)
            let list = try call.list("agents", count: 1...6, each: "an agent")
            if let room = facts.room, list.count > room {
                throw GuideRefusal("The servers that are paid for can take \(room) \(room == 1 ? "agent" : "agents"), and this team has \(list.count).")
            }
            var taken = Set([ManagerName.agentName(facts.manager) ?? ManagerName.fallback])
            var agents: [GuideTeam.Agent] = []
            for item in list {
                let one = try Fields(item, of: "an agent", has: ["role", "does", "uses", "asks_first", "needs_browser"])
                let role = try one.text("role", max: 30)!
                if agents.contains(where: { $0.role.lowercased() == role.lowercased() }) {
                    throw GuideRefusal("The role \(role) is there two times. Each agent has its own role.")
                }
                let uses = try one.list("uses", count: 0...usesOnCard, each: "a thing that the agent uses", required: false).map { item in
                    try self.use(item, typed: state.typed)
                }
                let name = GuideNames.free(taken: taken)
                taken.insert(name)
                agents.append(GuideTeam.Agent(name: name, role: role, does: try one.text("does", max: 90)!, uses: uses,
                                              asksFirst: try one.text("asks_first", max: 60, required: false),
                                              needsBrowser: try one.flag("needs_browser") ?? false))
            }
            return GuideTeam(agents: agents, use: use)
        }
    }

    private static func use(_ item: Any, typed: [String]) throws -> GuideTeam.Use {
        if (item as? [String: Any])?["level"] != nil {
            throw GuideRefusal("The card shows no level for a repository, so leave `level` out. The owner sets the level when GitHub is connected.")
        }
        let one = try Fields(item, of: "a thing that the agent uses", has: ["kind", "name"])
        guard let kind = try one.word("kind", of: GuideTeam.Use.Kind.self) else {
            throw GuideRefusal("`kind` is missing: give repo, key, login or gmail.")
        }
        guard kindsOnCard.contains(kind) else {
            throw GuideRefusal("The card has no mark for a \(kind.rawValue) yet, so the setup cannot give one. The owner connects it later on the app's page.")
        }
        let name = try one.text("name", max: 200)!
        let shape = switch kind {
        case .repo: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,38}/[A-Za-z0-9_.-]{1,100}$"
        case .gmail, .drive: "^[^@\\s]{1,64}@[A-Za-z0-9.-]{1,190}\\.[A-Za-z]{2,24}$"
        case .key, .login: "^[A-Za-z0-9][A-Za-z0-9 .&_-]{0,39}$"
        }
        guard name.range(of: shape, options: .regularExpression) != nil else {
            throw GuideRefusal(kind == .repo ? "A repository is named as owner/name." : kind == .gmail
                               ? "A mailbox is named by its address." : "A service is named by its name, in 40 characters at most.")
        }
        guard isNamed(name, by: typed) else { throw GuideRefusal(notNamed(name)) }
        return GuideTeam.Use(kind: kind, name: name)
    }

    static func notNamed(_ name: String) -> String {
        "The owner did not type \(name) in this conversation. Ask the owner for it: a name that you chose or a suggestion that was pressed does not count."
    }

    // MARK: - ask_secret

    /// **The check of an `ask_secret` call.** On success the caller keeps the step as open (`GuideState.secretOpen`),
    /// shows it and answers `{"shown": true}`.
    public static func askSecret(_ arguments: Any?, state: GuideState, facts: GuideFacts) -> Result<GuideSecretStep, GuideRefusal> {
        refusing {
            try notBusy(facts)
            guard state.fleet.contains(.teamMade), state.fleet.contains(.vaultReady) else {
                throw GuideRefusal("The step for a secret comes after the team is made and the fleet's vault is ready. Wait for those two events.")
            }
            guard let team = state.pressedTeam else { throw GuideRefusal("No team card is pressed, so no agent can hold a secret yet.") }
            if state.secretOpen != nil { throw GuideRefusal("A step for a secret shows now. Wait for its event.") }
            let call = try Fields(arguments, of: "ask_secret", has: ["service", "kind", "holder", "steps"])
            let name = try call.text("service", max: 40)!
            guard let kind = try call.word("kind", of: GuideSecretStep.Kind.self) else { throw GuideRefusal("`kind` is missing: give key or login.") }
            let role = try call.text("holder", max: 30)!
            guard let agent = team.agent(role: role) else { throw GuideRefusal("The pressed team card has no agent with the role \(role).") }
            let wanted = GuideTeam.Use(kind: kind == .key ? .key : .login, name: name)
            guard agent.uses.contains(where: { $0.isSame(wanted) }) else {
                throw GuideRefusal("The pressed team card does not say that \(agent.role) uses a \(name) \(kind.rawValue). The app asks only for what that card names.")
            }
            guard let service = GuideServices.find(name), kind == .key else {
                throw GuideRefusal("The app does not ask for the \(name) \(kind.rawValue) in the setup. Tell the owner that \(agent.role) asks for it later, with its own request.")
            }
            let steps = try call.list("steps", count: 0...2, each: "a step", required: false).enumerated().map { index, item in
                guard let text = item as? String else { throw GuideRefusal("Each step is a text.") }
                let step = try plainText(text, "step \(index + 1)", max: 80)
                if step.contains("://") || step.lowercased().contains("www.") {
                    throw GuideRefusal("A step holds no link and no address. The app shows the service's own page itself.")
                }
                return step
            }
            return GuideSecretStep(service: service, kind: kind, holderRole: agent.role, holderName: agent.name, steps: steps)
        }
    }

    // MARK: - check_servers

    /// **The check of a `check_servers` call.** On success the caller starts the app's own read-only check and
    /// answers `{"started": true}`, with `"count"` for a list of addresses. The check changes nothing on a server, and
    /// it asks for no password.
    public static func checkServers(_ arguments: Any?, state: GuideState, facts: GuideFacts) -> Result<GuideServersAsk, GuideRefusal> {
        refusing {
            try notBusy(facts)
            let call = try Fields(arguments, of: "check_servers", has: ["addresses", "provider"])
            let provider = try call.text("provider", max: 40, required: false)
            let addresses = try call.list("addresses", count: 1...20, each: "an address", required: false)
            switch (provider, addresses.isEmpty) {
            case (nil, true): throw GuideRefusal("Give `addresses` or `provider`.")
            case (.some, false): throw GuideRefusal("Give `addresses` or `provider`, not both.")
            case (let name?, true):
                guard isNamed(name, by: state.typed) else { throw GuideRefusal(notNamed(name)) }
                guard let known = CloudProvider.allCases.first(where: { [$0.rawValue, $0.name.lowercased()].contains(name.lowercased()) }) else {
                    throw GuideRefusal("The app lists servers at Hetzner, DigitalOcean, Vultr and Akamai. For another provider, ask the owner for each server's address.")
                }
                guard facts.tokens.contains(known) else {
                    throw GuideRefusal("This Mac holds no token of \(known.name). Ask the owner for each server's address, or show the app's page for the token.")
                }
                return .provider(known)
            case (nil, false):
                var seen = Set<String>()
                return .addresses(try addresses.map { item in
                    guard let address = (item as? String).map({ withoutLead($0).trimmingCharacters(in: .whitespaces) }),
                          address.range(of: "^[A-Za-z0-9][A-Za-z0-9._:@-]{0,254}$", options: .regularExpression) != nil else {
                        throw GuideRefusal("Each address is one server's name or IP address.")
                    }
                    guard seen.insert(address.lowercased()).inserted else { throw GuideRefusal("The address \(address) is there two times.") }
                    guard isNamed(address, by: state.typed) else { throw GuideRefusal(notNamed(address)) }
                    return address
                })
            }
        }
    }

    // MARK: - propose_servers

    /// **The check of a `propose_servers` call.** On success the caller keeps the roles as a card that shows
    /// (`GuideState.show(servers:)`) and answers `{"shown": true, "card": "<id>"}`.
    public static func proposeServers(_ arguments: Any?, state: GuideState, facts: GuideFacts) -> Result<[GuideServerChoice], GuideRefusal> {
        refusing {
            guard facts.serversCard else {
                throw GuideRefusal("The card for the owner's own servers is not in the app yet. Show the app's own page for a server that the owner has.")
            }
            try notBusy(facts)
            guard !state.checked.isEmpty else { throw GuideRefusal("No servers are checked yet. Call check_servers first, and wait for its event.") }
            let call = try Fields(arguments, of: "propose_servers", has: ["servers"])
            let choices = try call.list("servers", count: 1...20, each: "a server").map { item in
                let one = try Fields(item, of: "a server", has: ["name", "role"])
                guard let role = try one.word("role", of: GuideServerRole.self) else { throw GuideRefusal("`role` is missing: give hub, agents, apps or out.") }
                return GuideServerChoice(name: try one.text("name", max: 63)!, role: role)
            }
            if let why = cannotSetUp(choices, checked: state.checked, hubExists: facts.hubExists) { throw why }
            return choices
        }
    }

    /// **Why a set of roles cannot be set up, or nil when it can.** The card's button shows only while this is nil,
    /// also after the owner changed a role in the card. The servers are exactly those of the last check, each role is
    /// one that the fleet's rules allow on its server, exactly one server is the hub unless a hub exists, and one
    /// server at least is not left out.
    public static func cannotSetUp(_ choices: [GuideServerChoice], checked: [GuideServerFact], hubExists: Bool) -> GuideRefusal? {
        guard Set(choices.map(\.name)) == Set(checked.map(\.name)), choices.count == checked.count else {
            return GuideRefusal("Give exactly the servers of the last check, each one time.")
        }
        for choice in choices {
            guard let server = checked.first(where: { $0.name == choice.name }), server.roles.contains(choice.role) else {
                return GuideRefusal("The server \(choice.name) cannot take the role \(choice.role.rawValue). Its roles are in the event of the check.")
            }
        }
        let hubs = choices.count { $0.role == .hub }
        if hubExists, hubs > 0 { return GuideRefusal("The fleet has its hub already, so no server takes the role hub.") }
        if !hubExists, hubs != 1 { return GuideRefusal("Exactly one server takes the role hub.") }
        if choices.allSatisfy({ $0.role == .out }) { return GuideRefusal("Each server is left out, so there is nothing to set up.") }
        return nil
    }

    // MARK: - offer_repair

    /// **The check of an `offer_repair` call**: a server of the pressed servers card whose last install stopped in a
    /// way that the app can repair. On success the caller keeps a repair's card (`GuideState.show(repair:)`).
    public static func offerRepair(_ arguments: Any?, state: GuideState, facts: GuideFacts) -> Result<String, GuideRefusal> {
        refusing {
            try notBusy(facts)
            let call = try Fields(arguments, of: "offer_repair", has: ["server"])
            let server = try call.text("server", max: 63)!
            guard state.pressed(.servers)?.servers?.contains(where: { $0.name == server && $0.role != .out }) == true else {
                throw GuideRefusal("The server \(server) is not a server of the pressed servers card.")
            }
            guard state.installStops[server]?.repairable == true else {
                throw GuideRefusal("The install on \(server) did not stop in a way that the app can repair.")
            }
            return server
        }
    }

    // MARK: - finish

    /// **Why `finish` is refused now, or nil when the app writes the hand-over and sends the brief.** It is the one
    /// tool call that starts a write, so each thing before it must have its result.
    public static func finish(state: GuideState, facts: GuideFacts) -> GuideRefusal? {
        if let busy = facts.busy { return GuideRefusal("The \(busy) runs. Call finish when it has ended.") }
        guard state.fleet.contains(.up) else { return GuideRefusal("The fleet is not up yet.") }
        if state.secretOpen != nil { return GuideRefusal("A step for a secret is open. Wait for its event.") }
        // After a restore the fleet has its own team: the app carries out no team card.
        let restored = state.fleet.contains(.restored)
        for card in state.cards where card.state == .pressed && !card.carriedOut && !(restored && card.kind == .team) {
            return GuideRefusal("The \(card.kind.rawValue) card is pressed, and the app has not carried it out yet. Wait for its events.")
        }
        if !restored, let card = state.pressed(.team), let team = card.team {
            for agent in team.agents {
                for use in agent.uses where card.settled[use.key(role: agent.role)] == nil && asksInSetup(use) {
                    return GuideRefusal("\(agent.role): the \(use.name) \(use.kind.rawValue) has no result yet. Ask for it, or show its page.")
                }
            }
        }
        return nil
    }

    /// Whether the setup asks for this thing at all. A key of a service that the app's table does not have, and each
    /// login, are for later: the hand-over names them.
    static func asksInSetup(_ use: GuideTeam.Use) -> Bool {
        switch use.kind {
        case .key: GuideServices.find(use.name) != nil
        case .login: false
        case .repo, .gmail, .drive: true
        }
    }

    // MARK: - The write rule

    /// **What the app may give by itself for the guide** (spec section 3.5, point 4): only a thing of the pressed
    /// team card, to the agent that the card names for it. A key or a login goes at `use`, never at `read`. A
    /// repository and a mailbox have no level on the card, so the app gives none by itself. A grant that the owner
    /// makes himself on one of the app's own pages is his own act, and this rule is not about it.
    public static func grant(of thing: GuideTeam.Use, to role: String, state: GuideState) -> Result<GuideGrant, GuideRefusal> {
        guard !state.fleet.contains(.restored), let team = state.pressedTeam, let agent = team.agent(role: role),
              agent.uses.contains(where: { $0.isSame(thing) }) else {
            return .failure(GuideRefusal("No pressed card names \(thing.name) for \(role)."))
        }
        switch thing.kind {
        case .key, .login: return .success(.use(agent: agent.name))
        case .repo, .gmail, .drive: return .success(.ownerSetsLevel)
        }
    }

    // MARK: - A server of a check

    /// **One server of the app's read-only check as typed facts**, or nil for a name or an address with other
    /// characters than a server's name has. `reading` is nil for a server that SSH did not read: `needsPassword` says
    /// whether it asked for a password that this Mac does not hold. No text of the server is in the result: the
    /// system's words are the app's own, from the table of the systems that the installers take.
    public static func server(name: String, address: String, reading: ServerCheck.Reading?, needsPassword: Bool = false,
                              sshPort: Int = 22, tailnet: String? = nil) -> GuideServerFact? {
        guard name.range(of: "^[A-Za-z0-9.-]{1,63}$", options: .regularExpression) != nil,
              address.range(of: "^[A-Za-z0-9][A-Za-z0-9._:@-]{0,254}$", options: .regularExpression) != nil else { return nil }
        guard let reading else {
            return GuideServerFact(name: name, address: address, system: GuideServerFact.otherSystem, memoryGB: nil, ports: [],
                                   roles: [.out], needsPassword: needsPassword, stop: needsPassword ? nil : .unreached)
        }
        let hub = stop(reading, job: .hub, tailnet: tailnet), join = stop(reading, job: .join, tailnet: tailnet)
        var roles: [GuideServerRole] = []
        if hub == nil || hub == .busy { roles.append(.hub) }
        if join == nil || join == .busy { roles.append(.agents) }
        // A server for apps takes the door's parts, which cover these systems, over a root login.
        if DoorHosts.covered.contains("\(reading.system):\(reading.version)"), reading.sudo != .none { roles.append(.apps) }
        roles.append(.out)
        let ports = Set(reading.listeners.filter { $0.proto == "tcp" && $0.port != sshPort && !["sshd", "ssh"].contains($0.process) }
            .map(\.port)).sorted()
        let cannot: GuideServerStop? = hub == .busy || join == .busy ? .busy : (hub != nil && join != nil ? join : nil)
        return GuideServerFact(name: name, address: address, system: system(reading),
                               memoryGB: reading.memoryMB.map { max(1, Int((Double($0) / 1024).rounded())) }, ports: ports,
                               roles: roles, needsPassword: reading.sudo == .password, stop: cannot)
    }

    /// The system in the app's own words: the name from the installers' table with a version of digits and full
    /// stops, or "Other system".
    static func system(_ reading: ServerCheck.Reading) -> String {
        guard let known = (InstallPlan.hubTakes + InstallPlan.joinTakes).first(where: { $0.id == reading.system }),
              reading.version.range(of: "^[0-9][0-9.]{0,7}$", options: .regularExpression) != nil else {
            return GuideServerFact.otherSystem
        }
        return "\(known.name) \(reading.version)"
    }

    /// **Why a server takes no install of a job, as a fixed kind.** It follows `ServerCheck.verdict` rule for rule
    /// (a test holds the two together): that one gives the owner's words, and this one gives the model a kind. A
    /// password that the server asks for is no stop.
    static func stop(_ reading: ServerCheck.Reading, job: InstallJob, tailnet: String? = nil) -> GuideServerStop? {
        guard InstallPlan.systems(job).contains(where: { $0.id == reading.system && $0.version == reading.version }) else { return .system }
        guard ServerCheck.architectures[reading.arch] != nil else { return .machine }
        guard reading.systemd else { return .noSystemd }
        if reading.sudo == .none { return .notRoot }
        let memory = job == .hub ? ServerCheck.hubMemory : ServerCheck.agentMemory
        if let have = reading.memoryMB, have < memory.megabytes { return .memory }
        if let free = reading.diskFreeMB, free < ServerCheck.freeDisk.megabytes { return .disk }
        guard reading.ipv4Route else { return .noIPv4 }
        let ai = ["claude.ai", "chatgpt.com"]
        if ServerCheck.hosts.contains(where: { !ai.contains($0) && reading.reach[$0] == .no }) { return .noHTTPS }
        if job == .join, ai.allSatisfy({ reading.reach[$0] == .no }) { return .noHTTPS }
        if let tailnet, case .running(let theirs?) = reading.tailscale, theirs.lowercased() != tailnet.lowercased() { return .otherTailnet }
        if reading.sudo != .password, reading.cloudInit == .running || reading.dpkgLock { return .busy }
        return nil
    }

    // MARK: - Inside

    private static func refusing<T>(_ body: () throws -> T) -> Result<T, GuideRefusal> {
        do { return .success(try body()) }
        catch let refusal as GuideRefusal { return .failure(refusal) }
        catch { return .failure(GuideRefusal("The call could not be read.")) }
    }

    /// A tool that shows a card or a page, or that starts a check, is refused while a part of the first run has work
    /// that runs. During a build the guide only asks its questions.
    private static func notBusy(_ facts: GuideFacts) throws {
        if let busy = facts.busy {
            throw GuideRefusal("The \(busy) runs, and no card, page or check starts until it has ended. Ask your questions, and call this again after its event.")
        }
    }

    /// A text of the model's that the app shows or keeps: one line of plain words, with no text that the guard
    /// matches.
    static func plainText(_ text: String, _ field: String, max: Int) throws -> String {
        let text = withoutLead(text).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { throw GuideRefusal("`\(field)` is empty.") }
        guard text.count <= max else { throw GuideRefusal("`\(field)` has \(text.count) characters, and it takes \(max) at most.") }
        guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }) else {
            throw GuideRefusal("`\(field)` is one line of plain words.")
        }
        guard !guardRefuses(text), withoutMarks(text) == text else { throw GuideRefusal("`\(field)` holds a text that the app does not show.") }
        return text
    }

    /// The fields of one object of a call. A field that the tool does not have is refused, so nothing passes that the
    /// app did not check.
    private struct Fields {
        let fields: [String: Any]
        let what: String

        init(_ value: Any?, of what: String, has: Set<String>) throws {
            guard let fields = (value ?? [String: Any]()) as? [String: Any] else { throw GuideRefusal("\(what) takes an object of fields.") }
            if let other = fields.keys.sorted().first(where: { !has.contains($0) }) {
                throw GuideRefusal("\(what) has no field `\(other)`. Its fields are \(has.sorted().joined(separator: ", ")).")
            }
            self.fields = fields
            self.what = what
        }

        func text(_ name: String, max: Int, required: Bool = true) throws -> String? {
            guard let value = fields[name], !(value is NSNull) else {
                if required { throw GuideRefusal("`\(name)` is missing.") }
                return nil
            }
            guard let text = value as? String else { throw GuideRefusal("`\(name)` is a text.") }
            return try GuideRules.plainText(text, name, max: max)
        }

        func flag(_ name: String) throws -> Bool? {
            guard let value = fields[name], !(value is NSNull) else { return nil }
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw GuideRefusal("`\(name)` is true or false.")
            }
            return number.boolValue
        }

        func word<Word: RawRepresentable & CaseIterable>(_ name: String, of: Word.Type) throws -> Word? where Word.RawValue == String {
            guard let value = fields[name], !(value is NSNull) else { return nil }
            guard let text = value as? String, let word = Word(rawValue: text) else {
                throw GuideRefusal("`\(name)` is one of \(Word.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            return word
        }

        func list(_ name: String, count: ClosedRange<Int>, each: String, required: Bool = true) throws -> [Any] {
            guard let value = fields[name], !(value is NSNull) else {
                if required { throw GuideRefusal("`\(name)` is missing.") }
                return []
            }
            guard let list = value as? [Any] else { throw GuideRefusal("`\(name)` is a list.") }
            guard count.contains(list.count) || (!required && list.isEmpty) else {
                throw GuideRefusal("`\(name)` takes \(count.lowerBound) to \(count.upperBound) items, and it has \(list.count).")
            }
            return list
        }
    }
}

/// **The name that an agent of a proposed team gets**: the first of Add agent's list of short names that the team does
/// not have yet. The list is `AddAgentView.names` of the app, word for word (a test holds the two together), so the
/// card shows the mark that the agent then gets.
public enum GuideNames {
    public static let names = ["juno", "iris", "otto", "remy", "sage", "luna", "milo", "ezra", "nora", "theo", "vera", "kai",
                               "lena", "orion", "ada", "felix", "hugo", "ines", "elio", "maya"]

    public static func free(taken: Set<String>) -> String { names.first { !taken.contains($0) } ?? "agent-\(taken.count + 1)" }
}
