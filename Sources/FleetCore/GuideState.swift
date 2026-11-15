import Foundation

// The onboarding guide: what the app keeps of the conversation (`~/dev/founderizer-plans/onboarding-guide-spec.md`,
// section 3.6, lane K). The guide proposes, the owner presses, and the app writes: so the app's own record of a press
// is what a write starts from, never a word of the model. This file is that record, and the file on the disk that
// holds it through a quit. **Nothing in the app reads or writes it yet** (`GuideSwitch`).

/// **The guide's own folder on this Mac**, of the owner's user alone (mode 700): the kept state, the session's work
/// folder, the MCP configuration and the app's own copy of the provider's program. All of it goes at the guide's end.
public struct GuidePlaces: Equatable, Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    /// The folder in the app's own part of the user's Library.
    public static func inSupport(_ support: URL) -> GuidePlaces {
        GuidePlaces(root: support.appendingPathComponent("Founderizer/Guide", isDirectory: true))
    }

    /// The kept state: one file, mode 600.
    public var state: URL { root.appendingPathComponent("state.json") }
    /// The session's working folder: empty, and the same one at each resume.
    public var work: URL { root.appendingPathComponent("work", isDirectory: true) }
    /// The MCP configuration that the app writes for the program: mode 600, because it holds the session's label.
    public var configuration: URL { root.appendingPathComponent("mcp.json") }
    /// The app's own copy of the provider's program, when the owner has no tested version.
    public var program: URL { root.appendingPathComponent("program", isDirectory: true) }

    /// Makes the folder and the work folder, each for the owner's user alone.
    public func make() throws {
        for folder in [root, work] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        }
    }

    /// **Writes a file whole: a new file of mode 600, then a rename.** A write that is cut leaves the file before it
    /// as it was.
    public func write(_ data: Data, to file: URL) throws {
        let new = file.deletingLastPathComponent()
            .appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString.lowercased())")
        guard FileManager.default.createFile(atPath: new.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(new.path, file.path) == 0 else {
            try? FileManager.default.removeItem(at: new)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// The whole folder goes: the state, the work folder, the configuration and the app's own copy of the program.
    public func remove() { try? FileManager.default.removeItem(at: root) }
}

/// What the guide says of the account in its first message: a plan or a key, and the plan's name. No address and no
/// token.
public struct GuideAccount: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case plan, key }
    public var kind: Kind
    public var plan: String?
    public init(kind: Kind, plan: String? = nil) { self.kind = kind; self.plan = plan }

    /// The provider's word for a plan ("max", "pro") as a name: letters, digits, spaces, "-" and "_", 30 at most. nil
    /// for each other text, so no free text of the program is kept.
    public static func planName(_ word: String?) -> String? {
        guard let word, word.range(of: "^[A-Za-z0-9][A-Za-z0-9 _-]{0,29}$", options: .regularExpression) != nil else { return nil }
        return word
    }
}

/// A typed value of an event or of a tool's answer: what the model may get. It is made only from the app's own typed
/// facts.
public enum GuideValue: Codable, Equatable, Sendable {
    case text(String)
    case number(Int)
    case flag(Bool)
    case list([GuideValue])
    case fields([String: GuideValue])

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let flag = try? value.decode(Bool.self) { self = .flag(flag) }
        else if let number = try? value.decode(Int.self) { self = .number(number) }
        else if let text = try? value.decode(String.self) { self = .text(text) }
        else if let list = try? value.decode([GuideValue].self) { self = .list(list) }
        else { self = .fields(try value.decode([String: GuideValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .text(let text): try value.encode(text)
        case .number(let number): try value.encode(number)
        case .flag(let flag): try value.encode(flag)
        case .list(let list): try value.encode(list)
        case .fields(let fields): try value.encode(fields)
        }
    }

    /// The value as `JSONSerialization` takes it.
    var json: Any {
        switch self {
        case .text(let text): text
        case .number(let number): number
        case .flag(let flag): flag
        case .list(let list): list.map(\.json)
        case .fields(let fields): fields.mapValues(\.json)
        }
    }

    /// Each text in the value, for a search.
    var texts: [String] {
        switch self {
        case .text(let text): [text]
        case .number, .flag: []
        case .list(let list): list.flatMap(\.texts)
        case .fields(let fields): fields.keys.sorted().flatMap { fields[$0]!.texts }
        }
    }
}

/// **The kept state of the guide: one value, written whole at each change.**
///
/// It is made to hold no key: the box's guard runs before a message is kept. It can still hold a password that the
/// owner typed, and it holds the session's label. So the file is the owner's alone, it is in no copy of the fleet, and
/// it goes at the end. The build's own state is not here: the first run keeps that itself, and `build` only names it.
public struct GuideState: Codable, Equatable, Sendable {
    /// The file's form. A file of a newer form is not read: the first run then goes on without the guide.
    public static let form = 1

    public enum Provider: String, Codable, Sendable { case claudeCode = "claude_code" }

    public struct Session: Codable, Equatable, Sendable {
        /// The session's id: for Claude Code, the UUID that the app chose.
        public var id: String
        /// The channel's label of this session.
        public var label: String
        public init(id: String, label: String) { self.id = id; self.label = label }
    }

    /// One message that the owner sent, as it went.
    public struct OwnerWords: Codable, Equatable, Sendable {
        public var text: String
        public var at: Date
        /// The owner pressed a row that the guide suggested. It is his answer, but its words are the model's: it does
        /// not count for the name rule.
        public var pressedRow: Bool
        public init(text: String, at: Date, pressedRow: Bool) { self.text = text; self.at = at; self.pressedRow = pressedRow }
    }

    /// One thing that the conversation shows, in its order.
    public struct Entry: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case guide, owner, card }
        public var kind: Kind
        /// The guide's words, with the suggestions' block taken out.
        public var text: String?
        /// The rows that the guide suggested under these words.
        public var rows: [String]?
        /// The owner's message, by its place in `ownerWords`.
        public var owner: Int?
        /// The card, by its id.
        public var card: String?
    }

    /// One step that the app carried out for a pressed card. Its id is the request id of its call: it is kept before
    /// the call, so a step that ran is not run a second time, and one that was cut is asked again under the same id.
    public struct Step: Codable, Equatable, Sendable {
        public var id: String
        /// What the step is, by a fixed name of the lane that carries it out ("add_agent:iris").
        public var what: String
        /// nil while the step has no result yet.
        public var result: String?
        public var at: Date
    }

    public struct Card: Codable, Equatable, Sendable, Identifiable {
        public enum Kind: String, Codable, Sendable { case team, servers, repair }
        public enum State: String, Codable, Sendable { case shown, pressed, replaced, declined, leftOut = "left_out" }
        public var id: String
        public var kind: Kind
        /// The card's fields, as the app checked them: the one of its kind.
        public var team: GuideTeam?
        public var servers: [GuideServerChoice]?
        public var repair: String?
        public var state: State
        public var pressedAt: Date?
        public var steps: [Step] = []
        /// Each step of the pressed card ran.
        public var carriedOut = false
        /// For a team card: what came of each thing that an agent uses, by `GuideTeam.Use.key`.
        public var settled: [String: String] = [:]
    }

    public struct Page: Codable, Equatable, Sendable {
        public var name: String
        public var result: GuidePageResult?
        public var at: Date
    }

    public struct Limit: Codable, Equatable, Sendable {
        /// When the plan's limit ends, when the program said it.
        public var resetsAt: Date?
        public init(resetsAt: Date?) { self.resetsAt = resetsAt }
    }

    public var version = GuideState.form
    public var provider: Provider
    /// Which program runs, and from where: its file, its version, and whether it is the app's own copy.
    public var program: String
    public var programVersion: String
    public var programIsAppsOwn: Bool
    public var session: Session
    public var account: GuideAccount?
    public var ownerWords: [OwnerWords] = []
    public var thread: [Entry] = []
    public var cards: [Card] = []
    public var pages: [Page] = []
    /// Each event that the model has not got yet.
    public var waiting: [GuideAppEvent] = []
    public var limit: Limit?

    // What the rules read of the setup. Each is a typed fact that the app wrote.
    /// The owner's first answer, when the guide gave it with the team.
    public var use: FleetUse?
    /// The step of the slider of "Your fleet's servers" that the owner chose.
    public var step: ServersStep?
    /// The servers of the last check.
    public var checked: [GuideServerFact] = []
    /// What the fleet has reached.
    public var fleet: [GuideFleetFact] = []
    /// The last stop of an install, by its server.
    public var installStops: [String: GuideInstallStop] = [:]
    /// The step for one secret that shows now.
    public var secretOpen: GuideSecretStep?
    /// The name of the first run's kept build, and no more of it.
    public var build: String?
    /// The setup is done: the hand-over is written and the brief is sent.
    public var done = false
    private var cardCount = 0

    public init(provider: Provider = .claudeCode, program: String, programVersion: String, programIsAppsOwn: Bool,
                session: Session, account: GuideAccount?) {
        self.provider = provider; self.program = program; self.programVersion = programVersion
        self.programIsAppsOwn = programIsAppsOwn; self.session = session; self.account = account
    }

    // MARK: - The file

    /// The state as its file's bytes.
    public func file() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(self)
    }

    /// **A file's bytes as a state**, or nil when they are none: a file that was cut, a file of a newer form, or
    /// another file. The first run then goes on without the guide.
    public static func read(_ data: Data) -> GuideState? {
        struct Form: Decodable { let version: Int }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let form = try? decoder.decode(Form.self, from: data), (1...GuideState.form).contains(form.version) else { return nil }
        return try? decoder.decode(GuideState.self, from: data)
    }

    // MARK: - The conversation

    /// The typed messages of the owner: what the name rule reads. A pressed row is not one.
    public var typed: [String] { ownerWords.filter { !$0.pressedRow }.map(\.text) }

    /// **Keeps a message of the owner's, and gives the text that goes to the program.** The state keeps the owner's own
    /// words (`GuideRules.ownerMessage`), and the program gets them as plain words (`GuideRules.plain`). A text that
    /// the box's guard refuses is not kept and not sent.
    public mutating func owner(says text: String, pressedRow: Bool = false, at: Date = Date()) -> Result<String, GuideBoxRefusal> {
        GuideRules.ownerMessage(text).map { kept in
            ownerWords.append(OwnerWords(text: kept, at: at, pressedRow: pressedRow))
            thread.append(Entry(kind: .owner, owner: ownerWords.count - 1))
            return GuideRules.plain(kept)
        }
    }

    /// Keeps words of the guide as the conversation shows them: the suggestions' block goes out of the words, and its
    /// lines are the rows when they keep the block's rule.
    public mutating func guide(says text: String) {
        let shown = GuideRules.suggestions(in: text)
        guard !shown.words.isEmpty || !shown.rows.isEmpty else { return }
        thread.append(Entry(kind: .guide, text: shown.words, rows: shown.rows.isEmpty ? nil : shown.rows))
    }

    // MARK: - The cards

    public func card(_ id: String) -> Card? { cards.first { $0.id == id } }

    /// The newest card of a kind that is pressed.
    public func pressed(_ kind: Card.Kind) -> Card? { cards.last { $0.kind == kind && $0.state == .pressed } }

    /// The team card that the owner pressed: what each grant and each step for a secret is held to.
    public var pressedTeam: GuideTeam? { pressed(.team)?.team }

    private mutating func show(_ kind: Card.Kind, _ fill: (inout Card) -> Void) -> String {
        // A new call takes the button from the card before it: only the newest card of a kind can be pressed.
        for index in cards.indices where cards[index].kind == kind && cards[index].state == .shown {
            cards[index].state = .replaced
        }
        cardCount += 1
        var card = Card(id: "c\(cardCount)", kind: kind, state: .shown)
        fill(&card)
        cards.append(card)
        thread.append(Entry(kind: .card, card: card.id))
        return card.id
    }

    /// Keeps a checked team as a card that shows, and gives its id.
    public mutating func show(team: GuideTeam) -> String {
        if let use = team.use { self.use = use }
        return show(.team) { $0.team = team }
    }

    public mutating func show(servers: [GuideServerChoice]) -> String { show(.servers) { $0.servers = servers } }
    public mutating func show(repair server: String) -> String { show(.repair) { $0.repair = server } }

    /// **The owner pressed a card's button.** The press is kept here, and the store writes it to the file before the
    /// caller does any work on it. It gives the event that tells the model, which also waits in `waiting`. nil when
    /// the card cannot be pressed: it is not the newest one that shows.
    public mutating func press(_ id: String, servers roles: [GuideServerChoice]? = nil, at: Date = Date()) -> GuideAppEvent? {
        guard let index = cards.firstIndex(where: { $0.id == id }), cards[index].state == .shown else { return nil }
        cards[index].state = .pressed
        cards[index].pressedAt = at
        let event: GuideAppEvent
        switch cards[index].kind {
        case .team: event = .team(card: id)
        case .servers:
            // The owner can change each role in the card: the pressed card holds the roles as the owner left them.
            if let roles { cards[index].servers = roles }
            event = .servers(card: id, roles: cards[index].servers ?? [])
        case .repair: event = .repair(server: cards[index].repair ?? "", result: .repairing)
        }
        waiting.append(event)
        return event
    }

    /// The owner pressed **Leave out** on a repair's card.
    public mutating func leaveOut(_ id: String) -> GuideAppEvent? {
        guard let index = cards.firstIndex(where: { $0.id == id }), cards[index].kind == .repair,
              cards[index].state == .shown, let server = cards[index].repair else { return nil }
        cards[index].state = .leftOut
        installStops[server] = nil
        let event = GuideAppEvent.repair(server: server, result: .leftOut)
        waiting.append(event)
        return event
    }

    /// **The step of a pressed card that the app runs next, kept before its call.** A step of that name that the card
    /// has already comes back as it is: with a result, it ran and is not run again; with none, its call was cut, and
    /// the same request id goes again. nil for a card that is not pressed.
    public mutating func begin(step what: String, of id: String, at: Date = Date()) -> Step? {
        guard let index = cards.firstIndex(where: { $0.id == id }), cards[index].state == .pressed else { return nil }
        if let step = cards[index].steps.first(where: { $0.what == what }) { return step }
        let step = Step(id: UUID().uuidString.lowercased(), what: what, result: nil, at: at)
        cards[index].steps.append(step)
        return step
    }

    /// The result of a step that ran.
    public mutating func end(step id: String, result: String) {
        for card in cards.indices {
            if let step = cards[card].steps.firstIndex(where: { $0.id == id }) { cards[card].steps[step].result = result }
        }
    }

    /// Each step of a pressed card ran.
    public mutating func carriedOut(_ id: String) {
        if let index = cards.firstIndex(where: { $0.id == id && $0.state == .pressed }) { cards[index].carriedOut = true }
    }

    /// What came of one thing that an agent of the pressed team card uses: a key saved or declined, GitHub or Google
    /// connected or passed over, or a thing that the hand-over names for later.
    public mutating func settle(_ use: GuideTeam.Use, of role: String, as result: GuideUseResult) {
        guard let index = cards.lastIndex(where: { $0.kind == .team && $0.state == .pressed }) else { return }
        cards[index].settled[use.key(role: role)] = result.rawValue
    }

    // MARK: - The events

    /// **Keeps an event for the model, and what it says of the setup.** The model gets it as the app's next message.
    public mutating func note(_ event: GuideAppEvent, at: Date = Date()) {
        waiting.append(event)
        switch event.event {
        case .serversChecked: checked = event.servers ?? []
        case .fleet:
            if let fact = event.fleet, !fleet.contains(fact) { fleet.append(fact) }
        case .installStopped:
            if let server = event.server, let stop = event.installStop { installStops[server] = stop }
        case .repair:
            if let server = event.server, event.repair?.result == .repaired { installStops[server] = nil }
        case .secret: secretOpen = nil
        case .page:
            if let name = event.page { pages.append(Page(name: name, result: event.pageResult, at: at)) }
        case .start, .resumed, .team, .servers, .build: break
        }
    }

    /// The model got the first events of `waiting`.
    public mutating func taken(_ count: Int) { waiting.removeFirst(min(count, waiting.count)) }
}

/// **The kept state and its file.** Each change is in the file before the change's caller goes on: so a press is in the
/// file before its first step runs, and a quit between the two loses no press.
public final class GuideStore: @unchecked Sendable {
    public let places: GuidePlaces
    private let lock = NSLock()
    private var state: GuideState

    /// A new session's state, written at once.
    public init(_ state: GuideState, in places: GuidePlaces) throws {
        self.places = places
        self.state = state
        try places.make()
        try places.write(try state.file(), to: places.state)
    }

    private init(read state: GuideState, in places: GuidePlaces) {
        self.places = places
        self.state = state
    }

    /// **The state that a first run finds at its start**, or nil: no file, a file that was cut in the middle of a
    /// write, or a file of a newer form.
    public static func open(_ places: GuidePlaces) -> GuideStore? {
        guard let data = try? Data(contentsOf: places.state), let state = GuideState.read(data) else { return nil }
        return GuideStore(read: state, in: places)
    }

    public var now: GuideState { lock.withLock { state } }

    /// **One change, written whole to the file before this returns.** When the file cannot be written, the change is
    /// not made and the error goes to the caller: nothing is carried out on a press that the file does not hold.
    @discardableResult
    public func change<T>(_ body: (inout GuideState) throws -> T) throws -> T {
        try lock.withLock {
            var next = state
            let result = try body(&next)
            try places.write(try next.file(), to: places.state)
            state = next
            return result
        }
    }

    /// The guide's end: the file and the whole folder go.
    public func end() { places.remove() }
}

// MARK: - The events

/// How a page of `setup_show` ended. The stop words are the page's own fixed words: never a text that a server or a
/// hub gave.
public struct GuidePageResult: Codable, Equatable, Sendable {
    public enum Result: String, Codable, Sendable { case done, back, stopped }
    public var result: Result
    public var words: String?
    public init(_ result: Result, words: String? = nil) { self.result = result; self.words = result == .stopped ? words : nil }
}

/// What the fleet has reached, as the guide's rules read it.
public enum GuideFleetFact: String, Codable, Sendable, CaseIterable {
    case up
    /// The owner took **Restore copy**: the fleet has its own team, and no team card is carried out.
    case restored
    case teamMade = "team_made"
    case vaultReady = "vault_ready"
}

/// The kind of an install's stop. The app decides what is repairable, not the model: the first four kinds are.
public enum GuideInstallStop: String, Codable, Sendable, CaseIterable {
    case halfInstalledPackage = "half_installed_package"
    case heldLock = "held_lock"
    case portInUse = "port_in_use"
    case oldTailscale = "old_tailscale"
    case other

    public var repairable: Bool { self != .other }
}

/// What came of a repair. The app takes the end of a repair session only in this fixed form.
public struct GuideRepair: Codable, Equatable, Sendable {
    public enum Result: String, Codable, Sendable { case repairing, repaired, notRepaired = "not_repaired", leftOut = "left_out" }
    public enum Reason: String, Codable, Sendable, CaseIterable {
        case needsRestart = "needs_restart", needsUpgrade = "needs_upgrade", needsPackageRemoval = "needs_package_removal"
        case needsServiceStop = "needs_service_stop", gaveUp = "gave_up"
    }
    public var result: Result
    public var reason: Reason?

    public static let repairing = GuideRepair(result: .repairing, reason: nil)
    public static let repaired = GuideRepair(result: .repaired, reason: nil)
    public static let leftOut = GuideRepair(result: .leftOut, reason: nil)
    public static func notRepaired(_ reason: Reason) -> GuideRepair { GuideRepair(result: .notRepaired, reason: reason) }
}

/// **One event: what the app tells the model about a press, a page that ended, or a result of the app's own work**
/// (spec section 3.3). It reaches the model as one message that the app writes: one JSON object between the fixed
/// marks. It holds typed values only: no value of a field, and no free text of a server or of a hub.
///
/// **The press is the app's fact, never the model's belief.** The app writes in the fleet from its own record of a
/// press (`GuideState.cards`). An event only tells the model what happened, so a text that looks like an event
/// changes nothing.
public struct GuideAppEvent: Codable, Equatable, Sendable {
    public static let open = "<app-event>"
    public static let close = "</app-event>"

    public enum Kind: String, Codable, Sendable {
        case start, resumed, page, team
        case serversChecked = "servers_checked"
        case servers
        case installStopped = "install_stopped"
        case repair, secret, build, fleet
    }

    /// Where the setup stands at a session's first message.
    public enum Stand: String, Codable, Sendable { case new, building, up }
    public enum SecretResult: String, Codable, Sendable { case saved, declined, back }
    public enum BuildStep: String, Codable, Sendable, CaseIterable { case vps, network, install, checks }
    public enum BuildResult: String, Codable, Sendable { case running, done, stopped }

    public struct CardNote: Codable, Equatable, Sendable {
        public var card: String
        public var kind: GuideState.Card.Kind
    }

    public var event: Kind
    public var provider: GuideState.Provider?
    public var account: GuideAccount?
    public var manager: String?
    public var stand: Stand?
    public var pressed: [CardNote]?
    public var canBePressed: [CardNote]?
    public var pagesDone: [String]?
    public var ownerMessages: [GuideState.OwnerWords]?
    public var page: String?
    public var pageResult: GuidePageResult?
    public var step: ServersStep?
    public var card: String?
    public var servers: [GuideServerFact]?
    public var roles: [GuideServerChoice]?
    public var server: String?
    public var installStop: GuideInstallStop?
    public var repair: GuideRepair?
    public var secretResult: SecretResult?
    public var service: String?
    public var holder: String?
    public var buildStep: BuildStep?
    public var buildResult: BuildResult?
    public var fleet: GuideFleetFact?

    init(_ event: Kind) { self.event = event }

    /// The first message of a session. `manager` is the name that the owner gave on the page "Name your manager".
    public static func start(provider: GuideState.Provider, account: GuideAccount?, manager: String?, stand: Stand) -> GuideAppEvent {
        var event = GuideAppEvent(.start)
        event.provider = provider; event.account = account; event.stand = stand
        event.manager = manager.flatMap { ManagerName.agentName($0) == nil ? nil : ManagerName.shown($0) }
        return event
    }

    /// **The first message of a new session after a quit, when the program refused the resume**: the app's own account
    /// of where the setup stands, from the kept state. Each pressed card, each card that shows and can still be
    /// pressed, each page that is done, and the owner's own messages, each of which passes the box's guard again.
    public static func resumed(from state: GuideState) -> GuideAppEvent {
        var event = GuideAppEvent(.resumed)
        event.provider = state.provider; event.account = state.account
        event.pressed = state.cards.filter { $0.state == .pressed }.map { CardNote(card: $0.id, kind: $0.kind) }
        event.canBePressed = state.cards.filter { $0.state == .shown }.map { CardNote(card: $0.id, kind: $0.kind) }
        event.pagesDone = state.pages.filter { $0.result?.result == .done }.map(\.name)
        event.ownerMessages = state.ownerWords.filter { !GuideRules.guardRefuses($0.text) }
        return event
    }

    /// A page of `setup_show` ended. For the page "Your fleet's servers": the step that the owner chose.
    public static func page(_ name: String, _ result: GuidePageResult, step: ServersStep? = nil) -> GuideAppEvent {
        var event = GuideAppEvent(.page)
        event.page = name; event.pageResult = result; event.step = step
        return event
    }

    public static func team(card: String) -> GuideAppEvent {
        var event = GuideAppEvent(.team); event.card = card; return event
    }

    public static func serversChecked(_ servers: [GuideServerFact]) -> GuideAppEvent {
        var event = GuideAppEvent(.serversChecked); event.servers = servers; return event
    }

    public static func servers(card: String, roles: [GuideServerChoice]) -> GuideAppEvent {
        var event = GuideAppEvent(.servers); event.card = card; event.roles = roles; return event
    }

    public static func installStopped(server: String, kind: GuideInstallStop) -> GuideAppEvent {
        var event = GuideAppEvent(.installStopped); event.server = server; event.installStop = kind; return event
    }

    public static func repair(server: String, result: GuideRepair) -> GuideAppEvent {
        var event = GuideAppEvent(.repair); event.server = server; event.repair = result; return event
    }

    /// The step for one secret ended. Never the value.
    public static func secret(_ result: SecretResult, service: String, holder: String) -> GuideAppEvent {
        var event = GuideAppEvent(.secret)
        event.secretResult = result; event.service = service; event.holder = holder
        return event
    }

    public static func build(_ step: BuildStep, _ result: BuildResult) -> GuideAppEvent {
        var event = GuideAppEvent(.build); event.buildStep = step; event.buildResult = result; return event
    }

    public static func fleet(_ fact: GuideFleetFact) -> GuideAppEvent {
        var event = GuideAppEvent(.fleet); event.fleet = fact; return event
    }

    /// The event as the model gets it: the names of the spec's table, and only the parts that this kind holds.
    public var value: GuideValue {
        var fields: [String: GuideValue] = ["event": .text(event.rawValue)]
        func cards(_ notes: [CardNote]?) -> GuideValue {
            .list((notes ?? []).map { .fields(["card": .text($0.card), "kind": .text($0.kind.rawValue)]) })
        }
        if let provider { fields["provider"] = .text(provider.rawValue) }
        if event == .start || event == .resumed {
            fields["account"] = .text(account?.kind.rawValue ?? "none")
            if let plan = account?.plan { fields["plan"] = .text(plan) }
        }
        if let manager { fields["manager"] = .text(manager) }
        if let stand { fields["setup"] = .text(stand.rawValue) }
        if event == .resumed {
            fields["pressed"] = cards(pressed)
            fields["can_be_pressed"] = cards(canBePressed)
            fields["pages_done"] = .list((pagesDone ?? []).map(GuideValue.text))
            fields["owner_messages"] = .list((ownerMessages ?? []).map {
                .fields(["text": .text($0.text), "pressed_suggestion": .flag($0.pressedRow)])
            })
        }
        if let page { fields["page"] = .text(page) }
        if let pageResult {
            fields["result"] = .text(pageResult.result.rawValue)
            if let words = pageResult.words { fields["stop"] = .text(words) }
        }
        if let step { fields["step"] = .text(step.rawValue) }
        if let card { fields["card"] = .text(card) }
        if let servers { fields["servers"] = .list(servers.map(\.value)) }
        if let roles {
            fields["servers"] = .list(roles.map { .fields(["name": .text($0.name), "role": .text($0.role.rawValue)]) })
        }
        if let server { fields["server"] = .text(server) }
        if let installStop {
            fields["kind"] = .text(installStop.rawValue)
            fields["repairable"] = .flag(installStop.repairable)
        }
        if let repair {
            fields["result"] = .text(repair.result.rawValue)
            if let reason = repair.reason { fields["reason"] = .text(reason.rawValue) }
        }
        if let secretResult { fields["result"] = .text(secretResult.rawValue) }
        if let service { fields["service"] = .text(service) }
        if let holder { fields["holder"] = .text(holder) }
        if let buildStep { fields["step"] = .text(buildStep.rawValue) }
        if let buildResult { fields["result"] = .text(buildResult.rawValue) }
        if let fleet { fields["result"] = .text(fleet.rawValue) }
        return .fields(fields)
    }

    /// **The app's message for the model**: the event as one JSON object between the marks, as plain words for the
    /// program: an owner's message in it can hold an "@" before a file's name.
    public var message: String {
        let data = (try? JSONSerialization.data(withJSONObject: value.json, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return GuideRules.plain(Self.open + String(decoding: data, as: UTF8.self) + Self.close)
    }
}
