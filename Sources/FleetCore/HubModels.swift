import Foundation

public struct HubState: Decodable, Sendable {
    public let schema_version: Int
    public let db: String
    public let time: Double
    public let manager_flag: String?
    public let manager_warning: ManagerWarning?
    public let goals: [FleetGoal]?
    public let ui_features: [String]?
    /// The owner's knowledge files only. Internal files stay internal: no page and no picker shows them.
    public private(set) var knowledge: [KnowledgeEntry]?
    public let secrets: [SecretReference]?
    public let agents: [FleetAgent]
    public let tasks: [FleetTask]
    public let notes: [ProgressNote]
    public let needs: [OwnerNeed]
    public let permissions: [FleetPermission]
    public let messages: [OwnerMessage]
    public let reports: [ManagerReport]
    public let steers: [TaskSteer]?
    public let holds: [TaskHold]?
    public let outcomes: [TaskOutcome]?
    /// Owner feature `chat_apps`: Pause all, and the accounts that are not connected or not linked.
    public let chat_apps: ChatAppsSummary?
    /// Owner feature `live_changes`: the hub's change count at the moment of this snapshot, `<boot>.<state>.<activity>`,
    /// read under the same lock as the snapshot. The app's watcher of `/ui/wait` starts from it.
    public let token: String?

    /// The token as one the watcher can wait from, or nil.
    public var liveToken: LiveToken? { LiveToken(token) }
    /// The hub says when something changed (`GET /ui/wait`).
    public var offersLiveChanges: Bool { ui_features?.contains(LiveChanges.feature) == true }

    public static func decode(_ data: Data) throws -> HubState {
        guard data.count <= 16_000_000 else { throw HubError.invalidResponse }
        var state = try JSONDecoder().decode(Self.self, from: data)
        state.knowledge = state.knowledge?.filter(\.isOwner)
        guard state.schema_version == 1, !state.db.isEmpty,
              state.time.isFinite,
              state.goals?.allSatisfy(\.isValid) != false,
              state.steers?.allSatisfy(\.isValid) != false,
              Set(state.steers?.map(\.id) ?? []).count == (state.steers?.count ?? 0),
              Set(state.goals?.map(\.id) ?? []).count == (state.goals?.count ?? 0),
              Set(state.agents.map(\.id)).count == state.agents.count,
              Set(state.tasks.map(\.id)).count == state.tasks.count,
              Set(state.needs.map(\.id)).count == state.needs.count,
              Set(state.notes.map(\.id)).count == state.notes.count,
              Set(state.permissions.map(\.id)).count == state.permissions.count,
              Set(state.messages.map(\.id)).count == state.messages.count,
              Set(state.reports.map(\.id)).count == state.reports.count
        else { throw HubError.invalidResponse }
        return state
    }

    public func hasSteeringReceipt(for request: PendingRequest) -> Bool {
        db == request.database && steers?.contains(where: { $0.matches(request) }) == true
    }

    public func supportsChat(with agent: String) -> Bool {
        (agent == "manager" || ui_features?.contains("direct_chat") == true) &&
            agents.first(where: { $0.name == agent })?.direct_chat != false &&
            agents.first(where: { $0.name == agent })?.active != false
    }

    /// Owner feature `edit_in_place`: whether an edit of this message would change it where it stands, instead of
    /// going under it as a correction. The hub asks the same question again inside the write it makes, so a read
    /// of the same moment wins and what comes back is a correction after all.
    public func editsInPlace(_ message: OwnerMessage) -> Bool {
        ui_features?.contains("edit_in_place") == true && message.kind == "message"
            && message.read_at == nil && !wasAnswered(message)
    }

    /// Whether an agent answered this message of the owner.
    public func wasAnswered(_ message: OwnerMessage) -> Bool {
        reports.contains { $0.in_reply_to == message.request_id }
    }

    /// What the edit button says it will do to this message, in plain terms: a message nothing has read changes
    /// where it stands, and one that was read or answered keeps its bubble and takes a correction under it.
    public func editHelp(_ message: OwnerMessage) -> String {
        let name = message.chatRecipient.agentLabel
        if editsInPlace(message) { return "\(name) has not read this yet: your words replace it." }
        if wasAnswered(message) { return "\(name) already answered this: your words go under it as a correction." }
        if message.read_at != nil { return "\(name) already read this: your words go under it as a correction." }
        return "Your words go under it as a correction."
    }

    public func receipt(for request: PendingRequest) -> OwnerMessage? {
        guard request.command == nil, db == request.database else { return nil }
        return messages.first {
            $0.request_id.caseInsensitiveCompare(request.requestID.uuidString) == .orderedSame
                && $0.kind == (request.needID == nil ? "message" : "answer")
                && $0.need_id == request.needID && $0.text == request.text && $0.client == request.client
                && (request.needID != nil || $0.chatRecipient == (request.recipient ?? "manager"))
                && $0.replaces_request_id == request.replacesRequestID && $0.attachmentIDs == request.attachments
        }
    }
}

public struct FleetAgent: Decodable, Identifiable, Sendable {
    public let name: String
    public let role: String
    /// **Its role in the team, in the owner's words** (team.json `title`, hub 3 November 2026): the line under its name
    /// on Agents and in its chat's panel. nil: none set, or a hub older than this field.
    public let title: String?
    public let runtime: String
    public let active: Bool?
    public let direct_chat: Bool?
    public let local_model: Bool?
    public let reports_to: String?
    public let can: [String]
    public let last_seen: Double?
    public let alive_ts: Double?
    public let client_seen: Double?
    public let alive: String?
    public let client: String?
    public let usage: AgentUsage?
    public let limit: RuntimeLimit?
    public let usageError: String?
    /// What its machine last reported about its own provider: nil when the reading is old, the agent runs a local
    /// model, or the hub is older than this field.
    public let signed_in: Bool?
    /// Whether its owner chat runs and its session has its tools (hub 1.48, `chat_warm`): false while its helper
    /// starts it, nil for the manager, an agent in setup, a helper that starts its chat only at the first message, or
    /// a hub older than this field.
    public let chat_ready: Bool?
    /// **It has a server of its own** (hub 1.82, `manager_server`): false only for the manager of a new fleet, until
    /// its setup gives it one. Absent, from an older hub, means that it has one.
    public let placed: Bool
    /// **When he sent the newest chat message that it had read at its last turn end** (hub 1.110): its turn that took
    /// a message sent up to then is over, so the chat stops saying that it works on that message
    /// (`ChatWaiting.turnIsOver`). nil for an agent whose turns the hub does not know (every agent but the manager),
    /// before the first such message, while a usage limit holds it (a turn that the limit cut ends too, and the chat
    /// then says "Usage limit" as before), and from an older hub.
    public let turn_ended_after: Double?
    /// **His newest chat message to it is late** (hub 1.144): no session read it in two minutes, or a session read
    /// it and wrote no reply for as long. Its server can answer all that time, so nothing else says that the agent
    /// does not: the chat then says "Not answering" under his message, as it does for a server that is silent
    /// (`chatWaiting`). false or nil: it is not late, or the hub is older than this field.
    public let chat_undelivered: Bool?
    public var id: String { name }
    public var accountLimits: AccountLimits? { local_model == true ? nil : usage?.limits }
    /// The email of the provider account of the agent's own (primary) route, from a current reading of its configured
    /// provider. nil: unknown, a local model, or an old reading. The screen route has its own account:
    /// `usage?.screen?.limits?.currentEmail(at:)`.
    public func accountEmail(at time: Double) -> String? { accountLimits?.currentEmail(at: time) }

    private enum CodingKeys: String, CodingKey {
        case name, role, title, runtime, active, direct_chat, local_model, reports_to, can, last_seen, alive_ts, client_seen, alive, client, usage, limit,
             signed_in, chat_ready, placed, turn_ended_after, chat_undelivered
    }

    public init(from decoder: Decoder) throws {
        let data = try decoder.container(keyedBy: CodingKeys.self)
        name = try data.decode(String.self, forKey: .name)
        role = try data.decode(String.self, forKey: .role)
        // A blank title is none.
        title = try data.decodeIfPresent(String.self, forKey: .title)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        runtime = try data.decode(String.self, forKey: .runtime)
        active = try data.decodeIfPresent(Bool.self, forKey: .active)
        direct_chat = try data.decodeIfPresent(Bool.self, forKey: .direct_chat)
        local_model = try data.decodeIfPresent(Bool.self, forKey: .local_model)
        reports_to = try data.decodeIfPresent(String.self, forKey: .reports_to)
        can = try data.decode([String].self, forKey: .can)
        last_seen = try data.decodeIfPresent(Double.self, forKey: .last_seen)
        alive_ts = try data.decodeIfPresent(Double.self, forKey: .alive_ts)
        client_seen = try data.decodeIfPresent(Double.self, forKey: .client_seen)
        alive = try data.decodeIfPresent(String.self, forKey: .alive)
        client = try data.decodeIfPresent(String.self, forKey: .client)
        limit = try data.decodeIfPresent(RuntimeLimit.self, forKey: .limit)
        signed_in = try data.decodeIfPresent(Bool.self, forKey: .signed_in)
        chat_ready = try data.decodeIfPresent(Bool.self, forKey: .chat_ready)
        placed = try data.decodeIfPresent(Bool.self, forKey: .placed) ?? true
        turn_ended_after = try data.decodeIfPresent(Double.self, forKey: .turn_ended_after)
        chat_undelivered = try data.decodeIfPresent(Bool.self, forKey: .chat_undelivered)
        // Bad telemetry must not block chat or hide the rest of the fleet state.
        do {
            let reading = try data.decodeIfPresent(AgentUsage.self, forKey: .usage)
            guard reading?.isValid != false else { throw HubError.invalidResponse }
            usage = reading
            usageError = nil
        } catch {
            usage = nil
            usageError = "The usage reading is invalid. Waiting for a new reading."
        }
    }

    public func helperIsRecent(serverTime: Double) -> Bool {
        guard let last_seen else { return false }
        return serverTime - last_seen >= -5 && serverTime - last_seen < 60
    }
}

public struct FleetTask: Decodable, Identifiable, Sendable {
    public let goal_id: Int?
    public let trigger_id: Int?
    public let trigger_run: Int?
    /// Owner API 1.10: the task's project, and why its requester chose this agent.
    public let project: String?
    public let why: String?
    public let parent: Int?
    public let id: Int
    public let title: String
    public let details: String
    public let done_when: String
    public let needs: String
    /// The goal in words, "" for none. **A null is none too**: the hub's own tasks for a duty's daily review carried
    /// `goal: null` on 27 October 2026, and the one strict field made every read of the state fail, so the owner saw
    /// "could not read your hub" while the hub answered.
    @TextOrNull public var goal: String
    public let owner: String
    public let requester: String
    public let state: String
    public let created: Double
    public let attempt: Int
    public let restarts: Int
    public let nudge_level: Int
    public let stop_sent: Int
    public let follows: Int?
    public let started: Double?
    public let last_activity: Double?
    public let delivered: Double?
    public let checked_at: Double?
    public let missing_since: Double?
    public let last_tool: String?
    public let outcome: String?
    public let what: String?
    public let where_: String?
    public let how: String?
    public let check_note: String?
    public let waiting_on: String?
    public let case_id: String?
    public let accepted: Int?
    public let live_path: String?
    /// The time until which its agent parked the task with a reminder, or nil: it does no work until then, so the
    /// board shows it in Waiting with "Until 10:00". nil on a hub that does not send it, where a parked task still
    /// shows as work.
    public let parked_until: Double?
    /// **Whether its session works on it now** (hub 1.147): true while a turn of its session runs or a call that it
    /// started in the background is open, false when its last turn ended and nothing of it runs. nil: the hub knows no
    /// turn of its attempt yet, or it is an older hub; the task's state then says it, as before. On the first fleet, on
    /// 13 November 2026, 19 tasks were in state working, 12 of them parked on a reminder, and one had work that ran:
    /// each of their agents moved in the sidebar (the owner: "the agent replied but the sidebar is still animating!").
    public let works: Bool?
    /// **What its running turn does now, in plain words** (hub 1.148), or nil: no turn of it runs, its turn has made no
    /// call yet that says something, or an older hub. The words are the agent's own line of a command ("Read live API
    /// health and public status") or the hub's fixed words for a tool ("Reading its messages"); no model writes them
    /// for the app (the owner, 13 November 2026, to their picture in his sidebar: "Yes, build it").
    public let doing: String?
    public let stalled_since: Double?
    public let stalled_reason: String?

    public var isTerminal: Bool { ["completed", "failed", "rejected", "canceled"].contains(state) }
    /// Who checks the result, by the name the app gives everywhere: an agent's capitalised ("Accepted by Manager"),
    /// and the owner as "you".
    public var checkStatus: String {
        let who = requester == "owner" ? "you" : requester.agentLabel
        if accepted == 1 { return "Accepted by \(who)" }
        if accepted == 0 { return "Not accepted by \(who)" }
        return delivered == nil ? "No result yet" : requester == "owner" ? "Waiting for your check" : "Waiting for \(who)'s check"
    }
}

extension FleetTask {
    /// **The task's one state word** (`TaskWords.state`), from the fleet's own state: the owner's hold on it, and whether
    /// its agent's usage limit holds it.
    public func stateWord(holds: [TaskHold], limited: Bool) -> String {
        let hold = holds.first { $0.task == id && $0.state != "released" }
        return TaskWords.state(state, accepted: accepted, requester: requester, waitingOn: waiting_on,
                               stalled: stalled_since != nil || nudge_level > 0, reconnecting: missing_since != nil,
                               hold: hold.map { TaskWords.Hold(kind: $0.kind, state: $0.state) }, limited: limited)
    }
}

extension FleetTask {
    /// **A task's mark: its symbol, its one state word, whether it needs attention and whether it is work now** — in the
    /// order of its state word (`TaskWords`; fix round 2, review B5), so the search card, the Tasks board, the Needs-you
    /// rows and the thread agree: the owner's hold first; for a task that is over, its result; then its agent's usage
    /// limit (the board's hourglass, never the green of work), a stall, a lost session, a question or a sign-in, what it
    /// waits on, and its own state. A limited task was drawn as green work in the search card while its thread said
    /// "Usage limit", and a result that was not accepted was a muted circle there and a red badge on the board.
    /// `inWork` is true only for a task in work now with nothing that holds it: **a task in state working that its
    /// agent parked until a time (`parked_until`), or whose session's last turn ended with nothing of it running
    /// (`works` false), is no work now** (13 November 2026). It keeps the mark and the word of its state, at rest and
    /// without the green of work, because motion and that green say that something happens now.
    ///
    /// **An outcome that is not known comes before all of it** (`outcomeUnknown`; fix round 3b, item 7): the orange "?"
    /// with "Outcome not known: check it", as the Tasks board and the lane of Needs you draw it, over the owner's hold and
    /// over a result. Those two drew it before they asked for the mark, so T-401 — paused, its outcome not known — was
    /// a grey pause in its agent's panel.
    public func mark(holds: [TaskHold], limited: Bool = false,
                     outcomeUnknown: Bool = false) -> (symbol: String, words: String, attention: Bool, inWork: Bool) {
        if outcomeUnknown { return ("questionmark.circle", "Outcome not known: check it", true, false) }
        let words = stateWord(holds: holds, limited: limited)
        if let hold = holds.first(where: { $0.task == id && $0.state != "released" }) {
            return hold.state == "not_confirmed" ? ("exclamationmark.circle", words, true, false) : ("pause.circle", words, false, false)
        }
        if isTerminal {
            // **A task that is over wears the board's result look** (fix round 3, item 21; `tint`): a checked result the
            // filled check, and a result that the board badges red (`failedResult`: Failed, Rejected, Canceled, Not
            // accepted) the filled exclamation, as the phone draws them; one that waits for its check muted. ⌘K drew a
            // muted outline check and an orange "!" beside the board's green check and red badge.
            if accepted == 1 && state == "completed" { return ("checkmark.circle.fill", words, false, false) }
            if failedResult != nil { return ("exclamationmark.circle.fill", words, state != "canceled", false) }
            return ("circle", words, false, false)
        }
        if limited { return ("hourglass", words, true, false) }
        if stalled_since != nil || nudge_level > 0 { return ("exclamationmark.circle", words, true, false) }
        if missing_since != nil { return ("arrow.triangle.2.circlepath", words, true, false) }
        switch state {
        case "input-required": return ("questionmark.circle", words, true, false)
        case "auth-required": return ("key", words, true, false)
        default: break
        }
        // A working or queued task that waits on something is the board's hourglass: "Waiting for Manager", "Waiting on Juno".
        if let waiting = waiting_on, !waiting.isEmpty { return ("hourglass", words, true, false) }
        switch state {
        case "working": return ("circle.dotted", words, false, parked_until == nil && works != false)
        case "submitted": return ("clock", words, false, false)
        default: return ("circle", words, false, false)
        }
    }

    /// Its mark from the fleet's state: an outcome that is not known, the owner's holds, and whether its agent's usage
    /// limit holds it.
    public func mark(in state: HubState?) -> (symbol: String, words: String, attention: Bool, inWork: Bool) {
        mark(holds: state?.holds ?? [], limited: state?.agents.first(where: { $0.name == owner })?.limit != nil,
             outcomeUnknown: state?.outcomeUnknown(id) == true)
    }

    /// **The colour of a task's mark**, in the mark's own order (fix round 3, item 21): the green of work while it is in
    /// work and nothing holds it; for a task that is over, the board's result look — green for a checked result, red
    /// for one that the board badges red — and nothing of the owner's hold over it; orange for a task that needs someone;
    /// muted for the rest. A state is never violet (D-8).
    public enum MarkTint: Sendable, Equatable { case work, attention, checked, failed, quiet }

    public func tint(holds: [TaskHold], limited: Bool = false, outcomeUnknown: Bool = false) -> MarkTint {
        if outcomeUnknown { return .attention }
        let mark = mark(holds: holds, limited: limited)
        if !holds.contains(where: { $0.task == id && $0.state != "released" }), isTerminal {
            return accepted == 1 && state == "completed" ? .checked : failedResult != nil ? .failed : .quiet
        }
        return mark.inWork ? .work : mark.attention ? .attention : .quiet
    }

    /// Its mark's colour from the fleet's state, as `mark(in:)`.
    public func tint(in state: HubState?) -> MarkTint {
        tint(holds: state?.holds ?? [], limited: state?.agents.first(where: { $0.name == owner })?.limit != nil,
             outcomeUnknown: state?.outcomeUnknown(id) == true)
    }
}

extension HubState {
    /// Whether the owner must check if an action of the task `task` took effect: its outcome is not known.
    public func outcomeUnknown(_ task: Int) -> Bool { outcomes?.contains { $0.task == task && $0.state == "unknown" } == true }
}

/// **One task's state in a few words, the same on every screen of both apps** (T-12; fix round 2 of 29 October 2026). A
/// finished task read "Delivered" in an agent's panel where its thread and Goals said "Checked", and the phone said
/// "Working" for a paused, a limited and a stalled task that the Mac called "Paused", "Usage limit" and "Stalled".
/// One function now gives the word, from the fields both apps read; a name is written as the apps write it,
/// capitalised, and the owner is "you".
public enum TaskWords {
    /// The owner's hold on a task: its kind (`pause` or `stop`) and its state.
    public struct Hold: Equatable, Sendable {
        public let kind: String
        public let state: String
        public init(kind: String, state: String) { self.kind = kind; self.state = state }
    }

    /// The state word: the owner's hold first, then, for a task that is not over, its agent's usage limit, a stall and a
    /// lost session; then a checked result, what the task waits on, and its own state.
    public static func state(_ state: String, accepted: Int?, requester: String, waitingOn: String? = nil,
                             stalled: Bool = false, reconnecting: Bool = false, hold: Hold? = nil,
                             limited: Bool = false) -> String {
        if let hold, hold.state != "released" {
            if hold.state == "requested" { return "Stopping…" }
            if hold.state == "not_confirmed" { return "Stop not confirmed" }
            return hold.kind == "pause" ? "Paused" : "Stopped"
        }
        let over = ["completed", "failed", "rejected", "canceled"].contains(state)
        if !over, limited { return "Usage limit" }
        if !over, stalled { return "Stalled" }
        if !over, reconnecting { return "Reconnecting" }
        if accepted == 1 && state == "completed" { return "Checked" }
        if accepted == 0 && state == "completed" { return "Not accepted" }
        if !over, let waitingOn, !waitingOn.isEmpty { return waiting(on: waitingOn, requester: requester) }
        switch state {
        case "working": return "Working"
        case "submitted": return "Queued"
        case "input-required": return waitingFor(requester)
        case "auth-required": return "Sign-in needed"
        case "completed": return "Awaiting check"
        case "canceled": return "Canceled"
        default: return state.prefix(1).uppercased() + state.dropFirst()
        }
    }

    /// **Who a task waits for, in three words** (fix round 2): "Waiting for you" when its requester is the owner, else
    /// "Waiting for Manager". It said "Waiting for an answer", which named nobody in four words.
    public static func waitingFor(_ requester: String) -> String {
        requester == "owner" ? "Waiting for you" : "Waiting for \(requester.agentLabel)"
    }

    /// The one a task waits on when it is not its requester: a name ("Juno"). The hub's own reference to a question, a
    /// permission or a conversation ("Q-1", "P-3", "CM-7"), or to its screen, is its requester's to answer: nil.
    public static func waiter(of waitingOn: String) -> String? {
        isReference(waitingOn) ? nil : waitingOn.agentLabel
    }

    /// What a task waits on, in words: "Waiting on Juno", or its requester for one of the hub's references.
    static func waiting(on waitingOn: String, requester: String) -> String {
        waiter(of: waitingOn).map { "Waiting on \($0)" } ?? waitingFor(requester)
    }

    /// The hub's own references are bookkeeping, never words for the owner (B-COPY-21).
    static func isReference(_ waitingOn: String) -> Bool {
        waitingOn == "its screen" || waitingOn.range(of: #"^[A-Z]+-\d+$"#, options: .regularExpression) != nil
    }
}

/// A text field that the hub may also send as null: an empty text then.
@propertyWrapper
public struct TextOrNull: Decodable, Sendable {
    public var wrappedValue: String
    public init(wrappedValue: String) { self.wrappedValue = wrappedValue }
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        wrappedValue = value.decodeNil() ? "" : try value.decode(String.self)
    }
}

public struct ProgressNote: Decodable, Identifiable, Sendable {
    public let id: Int
    public let task: Int
    public let agent: String
    public let ts: Double
    public let text: String
}

/// Owner feature `need_talk` (the owner, 9 November 2026: "a way to clarify some points and have a conversation with
/// the agent", apart from Your answer): the Discuss of a Needs-you item.
public enum NeedTalk {
    public static let feature = "need_talk"
    /// The hub's most for one message of the discussion.
    public static let most = 2000
    /// The hub's most for a card's why: an item written before the rule may be longer, and keeps its fold.
    public static let why = 240
}

/// One message in the discussion of a Needs-you item: `who` is `owner` or the agent that replied.
public struct NeedMessage: Decodable, Equatable, Sendable {
    public let who: String
    public let text: String
    public let ts: Double
    public var fromOwner: Bool { who == "owner" }
}

public struct OwnerNeed: Decodable, Identifiable, Sendable {
    public let id: Int
    public let title: String
    public let why: String
    public let todo: String
    public let raised: Double
    public let by: String
    public let answer: String?
    public let answered: Double?
    /// Owner feature `need_options` (API 1.18): the answers the agent offered with its question, in its own
    /// order. nil on a hub without the feature, and empty for a question that is not a choice. They are data and
    /// never markup: the app draws each as a plain label on a button.
    public let options: [String]?
    /// The index in `options` of the option the owner pressed; nil while the item is open, and nil for an answer
    /// the owner typed.
    public let chosen: Int?
    /// Owner feature `conversations` (API 1.17): `question` or `work` for an item that an agent raised inside a
    /// conversation with another person, and nil for every other item.
    public let kind: String?
    /// The conversation the item came from. The owner's answer goes back into that conversation and nowhere else.
    public let conversation: Int?
    /// The number of the agent's question that this item carries to the owner, or nil. A task that waits on that
    /// question ("Q-68" in its `waiting_on`) waits for his answer to this item (`HubState.ownerWaits`).
    public let question: Int?
    /// Owner feature `secret_requests`: what a `request_secret` item asks for (its `kind` is `secret`), and nil on
    /// every other item. It names a secret and never holds a value.
    public let secret: NeedSecret?
    /// Owner feature `door_calls` (API 1.79): the hash of the door call that the owner's yes lets through once, and
    /// nil on every other item. Its first option is the yes, which the Mac signs (`OwnerStatement.doorCall`).
    public let door_call: String?
    /// The fleet id that a phone's door-call statement names (API 1.81), on an item with a `door_call` only.
    public let door_fleet: String?
    /// Owner feature `door_modes` (API 1.121): the server of a run that the door refused, on the door's card only. Its
    /// second option, Full access on that server, is the server's mode, which the Mac signs (`OwnerStatement.doorMode`).
    public let door_host: String?
    /// API 1.125 (review point 5.6): the script of that run, byte for byte, on a door card that carries it, and nil on
    /// every other item. The card shows it under Script, and the Mac computes the call's hash from it before it signs
    /// Run it once (`DoorCall.checked`).
    public let door_script: String?
    /// Owner feature `door_setup` (API 1.94): the GitHub account that the item's first option makes a private App in,
    /// with GitHub's manifest flow (`GitHubManifestFlow`), and nil on every other item. The option's words are the
    /// answer, as for any other item.
    public let github_app: String?
    /// Owner feature `recovery_copy` (API 1.95): 1 on an item whose first option, pressed on this Mac, opens the Add
    /// device picture, which his phone scans; nil on every other item.
    public let add_device: Int?
    /// Owner feature `need_talk` (API 1.106): the long part of the item, which the card shows behind Details, or nil.
    public let details: String?
    /// True when the owner may tick several of the options and send them together; nil or false: he presses one.
    public let multi: Bool?
    /// The indexes of the options he ticked, once he answered an item whose options combine.
    public let chose: [Int]?
    /// His discussion of the item with the manager, oldest first: what he asked and what it replied, apart from his
    /// answer. nil on a hub without the feature.
    public let talk: [NeedMessage]?
    public var isOpen: Bool { answered == nil && answer == nil }
    /// The same card to sign, byte for byte: its words, its answers, its door call, server and script, and what its
    /// first option starts on this Mac (a GitHub App, the Add device picture). A press
    /// that waited for the store is dropped when the item changed under it (review of 12 November 2026: the Mac
    /// signed the script that a later read brought, not the one that he pressed on).
    public func signsTheSame(as other: OwnerNeed) -> Bool {
        func same(_ a: String?, _ b: String?) -> Bool { (a == nil) == (b == nil) && (a ?? "").utf8.elementsEqual((b ?? "").utf8) }
        return id == other.id && same(title, other.title) && same(why, other.why) && same(todo, other.todo)
            && same(details, other.details) && same(door_call, other.door_call) && same(door_host, other.door_host)
            && same(door_script, other.door_script) && same(github_app, other.github_app)
            && add_device == other.add_device && (options ?? []).count == (other.options ?? []).count
            && zip(options ?? [], other.options ?? []).allSatisfy { same($0, $1) }
    }
    /// The options combine: he ticks any of them and sends them together (`NeedRequestCard`).
    public var combines: Bool { multi == true && choices.count >= 2 }

    /// An item that asks for a key or a login. It takes no answer in words: the hub refuses one, because a key typed
    /// into an answer is in the agent's conversation before anything can mask it. Its secure form answers it.
    public var asksForSecret: Bool { kind == "secret" }

    /// An answer that goes into a conversation carries no file: the window a person talks to can open none, so the
    /// hub refuses one. Such a request therefore offers no file at all, rather than taking one and being refused. A
    /// secret request takes no answer of words or files.
    public var takesFiles: Bool { conversation == nil && !asksForSecret }

    /// The options this item offers, as they came. How many there may be and how long each one may be are the
    /// hub's to decide: it refuses a list or a label that is too long, and the app draws each on its own row, which
    /// wraps. So there is no second limit here and no truncation — a limit of the app's own would quietly drop an
    /// answer that the hub accepted. What the app still refuses is what is not one answer to press: fewer than two
    /// (one option is not a choice), a label that is empty, one with a control character in it, and two that say
    /// the same thing. An item that offers none leaves the app's own quick replies in their place.
    public var choices: [String] {
        let given = (options ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard given.count >= 2,
              given.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 } }),
              Set(given.map { $0.lowercased() }).count == given.count else { return [] }
        return given
    }
}

public struct FleetPermission: Decodable, Identifiable, Sendable {
    public let id: Int
    public let task: Int
    public let agent: String
    public let tool: String
    public let input: String
    public let key: String
    public let created: Double
    public let decision: String?
    public let reason: String?
    public let decided: Double?
    public let by: String?
}

public struct OwnerMessage: Decodable, Identifiable, Sendable, Equatable {
    public let request_id: String
    public let recipient: String?
    public let replaces_request_id: String?
    public var chatRecipient: String { recipient ?? "manager" }
    public let kind: String
    public let need_id: Int?
    public let text: String
    public let event_id: Int
    public let created: Double
    public let read_at: Double?
    /// Owner feature `edit_in_place`: when the owner last changed these words where they stand, or nil. The chat
    /// shows one bubble either way; what he first said is in the hub's own record.
    public let edited: Double?
    public let client: String
    /// Owner feature `chat_apps`: the chat app that the owner sent this message from; nil from this app.
    public let origin: MessageOrigin?
    /// Owner feature `attachments`: the files that went with this message, in the order the owner picked them.
    public let attachments: [MessageAttachment]?
    public var attachmentIDs: [Int] { (attachments ?? []).map(\.id) }
    public var id: String { request_id }
}

public struct ManagerReport: Decodable, Identifiable, Sendable, Equatable {
    public let agent: String?
    public let in_reply_to: String?
    public var chatAgent: String { agent ?? "manager" }
    public let id: Int
    public let text: String
    public let about: String
    public let created: Double
    /// Owner feature `chat_apps`: the newest outbound message of a reply to a chat-app message.
    public let delivery: ReportDelivery?
    /// Chat apps round 2: the agent wrote this to the owner first (`message_owner`); it answers no message.
    public let pushed: HubFlag?
    public var isPushed: Bool { pushed?.value == true }
}

public struct SendReceipt: Decodable, Sendable {
    public let recipient: String?
    public let replaces_request_id: String?
    /// Owner feature `attachments`: the files that this message carries. A hub without the feature names none, so a
    /// request with files is never taken as confirmed by it.
    public let attachments: [Int]?
    public let ok: Bool
    public let request_id: String
    public let event_id: Int
    public let created: Double
    public let read_at: Double?
    public let replayed: Bool
    public let client: String
    /// Owner feature `edit_in_place`: true when the hub changed the message itself instead of writing a correction
    /// under it. Then `event_id` and `created` are that message's, and `message_request_id` is its own id; for
    /// every other message they are this request's. A hub without the feature says neither.
    public let edited: Bool?
    public let message_request_id: String?

    public func matches(_ request: PendingRequest) -> Bool {
        ok && request_id.caseInsensitiveCompare(request.requestID.uuidString) == .orderedSame && client == request.client
            && (request.needID != nil || (recipient ?? "manager") == (request.recipient ?? "manager"))
            && replaces_request_id == request.replacesRequestID
            && (attachments ?? []) == request.attachments
    }
}

public struct SecretReference: Decodable, Identifiable, Sendable {
    public let id: Int
    public let label: String
}
