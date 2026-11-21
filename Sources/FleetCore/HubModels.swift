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
    /// The agents' internal knowledge files, which only a badge in a request's words opens, read-only, on a hub that
    /// gives the app one (`readsInternalKnowledge`; the owner's "Yes, read-only" of 20 November 2026). No list shows them.
    public private(set) var internalKnowledge: [KnowledgeEntry]?
    /// The hub gives the app an internal knowledge file (feature `knowledge_internal_read`).
    public var readsInternalKnowledge: Bool { ui_features?.contains("knowledge_internal_read") == true }
    public let secrets: [SecretReference]?
    public let agents: [FleetAgent]
    /// The tasks, and with them their notes, permissions, guidance, holds and outcomes: the hub's own rows of one
    /// read, or those rows with the blocks of older tasks that this Mac holds (`OlderTasks.join`), which only
    /// FleetCore sets.
    public internal(set) var tasks: [FleetTask]
    public internal(set) var notes: [ProgressNote]
    /// The Needs-you items, the messages and the reports: the hub's own rows of one read, or those rows with the blocks
    /// of older rows that this Mac holds (`OlderRows.join`, owner API 1.258), which only FleetCore sets.
    public internal(set) var needs: [OwnerNeed]
    public internal(set) var permissions: [FleetPermission]
    public internal(set) var messages: [OwnerMessage]
    public internal(set) var reports: [ManagerReport]
    public internal(set) var steers: [TaskSteer]?
    public internal(set) var holds: [TaskHold]?
    public internal(set) var outcomes: [TaskOutcome]?
    /// **Where the ended tasks are that this read leaves out** (owner API 1.254, `OlderTasksHead`), in a read that
    /// asked for the window of the tasks. nil: every task is in `tasks`: the hub is older, its marks are not in
    /// place, or this is a reading that `OlderTasks.join` made whole.
    public internal(set) var older_tasks: OlderTasksHead?
    /// **Where the items, reports and messages are that this read leaves out** (owner API 1.258, `OlderRowsHeads`), in a
    /// read that asked for that window. nil: every row is in the lists: the hub is older, its marks are not in place,
    /// or this is a reading that `OlderRows.join` made whole.
    public internal(set) var older_rows: OlderRowsHeads?
    /// Every task of the fleet, by this read: its own, and the ones that it leaves out.
    public var taskCount: Int { tasks.count + (older_tasks?.tasks ?? 0) }
    /// Every Needs-you item and every report of the fleet, by this read: its own, and the ones that it leaves out
    /// (owner API 1.258).
    public var needCount: Int { needs.count + (older_rows?.needs?.rows ?? 0) }
    public var reportCount: Int { reports.count + (older_rows?.reports?.rows ?? 0) }
    /// Owner feature `chat_apps`: Pause all, and the accounts that are not connected or not linked.
    public let chat_apps: ChatAppsSummary?
    /// The time of the newest repository grant that the door may not hold yet, or nil: the Mac's door round starts once
    /// for each new value (`DoorAccess.roundDue`). nil also from a hub before it; an optional var, so the phone's reading
    /// (`init(phoneTime:)`) has none by itself.
    public private(set) var door_grant_waits: Double?
    /// Owner feature `live_changes`: the hub's change count at the moment of this snapshot, `<boot>.<state>.<activity>`,
    /// read under the same lock as the snapshot. The app's watcher of `/ui/wait` starts from it.
    public let token: String?
    /// **The cases of the duties** (UI-API.md, newest finished work): the open ones and the ones that closed in the
    /// last 72 hours, by which the card Work names an agent's work (`WorkItem`). nil on a hub that sends no duties; a
    /// var, so the phone's reading (`init(phoneTime:)`) has none by itself.
    public private(set) var responsibilities: DutyCaseLists?

    /// The token as one the watcher can wait from, or nil.
    public var liveToken: LiveToken? { LiveToken(token) }
    /// The hub says when something changed (`GET /ui/wait`).
    public var offersLiveChanges: Bool { ui_features?.contains(LiveChanges.feature) == true }

    public static func decode(_ data: Data) throws -> HubState {
        guard data.count <= 16_000_000 else { throw HubError.invalidResponse }
        var state = try JSONDecoder().decode(Self.self, from: data)
        state.internalKnowledge = state.knowledge?.filter { !$0.isOwner }
        state.knowledge = state.knowledge?.filter(\.isOwner)
        guard state.schema_version == 1, !state.db.isEmpty,
              state.time.isFinite,
              state.goals?.allSatisfy(\.isValid) != false,
              state.steers?.allSatisfy(\.isValid) != false,
              state.older_tasks?.isValid != false,
              state.older_rows?.isValid != false,
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

    /// **The manager's name**: the agent with the role `manager`. A new hub's installer can give it a name of its
    /// owner's choice (`hub.sh --manager-name`), so no line finds the manager by the word `manager`; that word is the
    /// answer only for a reading with no manager in it.
    public var managerName: String { agents.first { $0.role == "manager" }?.name ?? "manager" }

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
        if editsInPlace(message) { return String(l10n: "\(name) has not read this yet: your words replace it.") }
        if wasAnswered(message) { return String(l10n: "\(name) already answered this: your words go under it as a correction.") }
        if message.read_at != nil { return String(l10n: "\(name) already read this: your words go under it as a correction.") }
        return String(l10n: "Your words go under it as a correction.")
    }

    public func receipt(for request: PendingRequest) -> OwnerMessage? {
        guard request.command == nil, db == request.database else { return nil }
        return messages.first {
            $0.request_id.caseInsensitiveCompare(request.requestID.uuidString) == .orderedSame
                && $0.kind == (request.needID == nil ? "message" : "answer")
                && $0.need_id == request.needID && $0.text == request.text && $0.client == request.client
                && (request.needID != nil || $0.chatRecipient == (request.recipient ?? "manager"))
                && $0.replaces_request_id == request.replacesRequestID
                // The same files: the reading lists them by number, the request in the order of its chips.
                && $0.attachmentIDs.sorted() == request.attachments.sorted()
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
    /// **Its account with a kind** (the AI providers build): the AI that the owner picked for it, by a key or on his own
    /// model server, and that server's address. nil for an agent on a plan, and from a hub before it. A field that will
    /// not read is none: it never hides the agent.
    public let model_account: AgentModelAccount?
    /// **Its account cannot work now** (owner API 1.186, item 7 of the AI providers' pictures): the key has no credit,
    /// or its model server does not answer. nil while it works, for an agent on a plan, and from a hub before it.
    public let account_problem: AccountProblem?
    public var id: String { name }
    /// The AI that the owner picked for an agent on a key or a model server, which the app names in the place of its
    /// program (his answer 12 of 14 November 2026); nil for an agent on a plan.
    public var modelProvider: ModelProvider? { model_account.flatMap { ModelProvider(rawValue: $0.provider) } }
    public var accountLimits: AccountLimits? { local_model == true ? nil : usage?.limits }
    /// The email of the provider account of the agent's own (primary) route, from a current reading of its configured
    /// provider. nil: unknown, a local model, or an old reading. The screen route has its own account:
    /// `usage?.screen?.limits?.currentEmail(at:)`.
    public func accountEmail(at time: Double) -> String? { accountLimits?.currentEmail(at: time) }

    private enum CodingKeys: String, CodingKey {
        case name, role, title, runtime, active, direct_chat, local_model, reports_to, can, last_seen, alive_ts, client_seen, alive, client, usage, limit,
             signed_in, chat_ready, placed, turn_ended_after, chat_undelivered, model_account, account_problem
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
        model_account = (try? data.decodeIfPresent(AgentModelAccount.self, forKey: .model_account)) ?? nil
        account_problem = (try? data.decodeIfPresent(AccountProblem.self, forKey: .account_problem)) ?? nil
        // Bad telemetry must not block chat or hide the rest of the fleet state.
        do {
            let reading = try data.decodeIfPresent(AgentUsage.self, forKey: .usage)
            guard reading?.isValid != false else { throw HubError.invalidResponse }
            usage = reading
            usageError = nil
        } catch {
            usage = nil
            usageError = String(l10n: "The usage reading is invalid. Waiting for a new reading.")
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
    /// **Since when an open task is in the state that its mark shows** (owner API 1.237), from the hub's own records: a
    /// hold, a usage limit of its agent, a stall or a lost session since it began, the start of what it waits on, its
    /// park, its creation while it is queued, else its return to work (`stateSince`). nil for a task that ended, and
    /// from an older hub.
    public let since: Double?
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
    /// **The owner's own message that this task comes from** (owner feature `asks`, hub 1.182), as that message's
    /// `request_id`, or nil: work that no message of his began (a wake-up, a duty's case, a review), or an older hub. A
    /// follow-up and a subtask have the ask of their task, so every task of one thing that he asked for carries one
    /// value (`HubState.asks`).
    public let ask: String?
    /// **The case of a duty that this task works**, by the case's id, or nil: work of no case, a subtask or a follow-up
    /// of a case's task (which belongs to that case all the same: `HubState.workKey`), or an older reading.
    public let duty_case: Int?
    /// **The task whose job this task joins** (owner feature `jobs`, hub 1.226), by that task's id, or nil: a task that
    /// begins a job, a task that only follows another, or an older hub. An agent names it for a further part of work
    /// that is there already, and the hub writes it for a later part of one step of a plan and for a lead's subtask
    /// (`HubState.jobs`).
    public let job: Int?
    /// On the task that begins a job: the name of the whole job, when its title names only the first step; else nil.
    public let job_name: String?
    /// **What came of the task, in plain words for the owner** (hub 1.226), on one line, or nil: the agent gave none,
    /// the task ended in another way, or an older hub. The hub writes it for a typed result of a session whose Shell
    /// box is off. The card of a job that ended shows it (`Job.result`), and so does the result on the task's page at
    /// rest (`FleetTask.resultAtRest`).
    public let plain: String?
    /// **A person's conversation drives this task's session** (owner feature `steer_files`, owner API 1.231): the
    /// conversation opened it, or a task that it is a part of, also the conversation window's own task. That person
    /// could get what a file of the owner's guidance says, so its guidance box takes no file (the owner's "Yes, build
    /// it" of 19 November 2026 to the pictures). nil from a hub without the feature.
    public let from_conversation: Bool?

    public var isTerminal: Bool { ["completed", "failed", "rejected", "canceled"].contains(state) }
    /// Who checks the result, by the name the app gives everywhere: an agent's capitalised ("Accepted by Manager"),
    /// and the owner as "you".
    public var checkStatus: String {
        let who = requester == "owner" ? "you" : requester.agentLabel
        if accepted == 1 { return requester == "owner" ? String(l10n: "Accepted by you") : String(l10n: "Accepted by \(who)") }
        if accepted == 0 { return requester == "owner" ? String(l10n: "Not accepted by you") : String(l10n: "Not accepted by \(who)") }
        return delivered == nil ? String(l10n: "No result yet") : requester == "owner" ? String(l10n: "Waiting for your check") : String(l10n: "Waiting for \(who)'s check")
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
        if outcomeUnknown { return ("questionmark.circle", String(l10n: "Outcome not known: check it"), true, false) }
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
    /// Whether the owner must check if an action of the task `task` took effect: its outcome is not known, and the
    /// task's agent does not check it first (`TaskOutcome.waitsOnOwner`).
    public func outcomeUnknown(_ task: Int) -> Bool {
        guard outcomes?.contains(where: { $0.task == task && $0.state == "unknown" }) == true else { return false }
        return ownerChecks(task, row: tasks.first { $0.id == task })
    }

    /// The same for the task `row` of this reading, with no search of the tasks.
    public func outcomeUnknown(of row: FleetTask) -> Bool { ownerChecks(row.id, row: row) }

    /// The outcomes that the owner checks (`TaskOutcome.waitsOnOwner`), of every task.
    public var ownerOutcomes: [TaskOutcome] {
        let unknown = (outcomes ?? []).filter { $0.state == "unknown" }
        guard !unknown.isEmpty else { return [] }
        let ids = Set(unknown.map(\.task))
        let rows = Dictionary(tasks.filter { ids.contains($0.id) }.map { ($0.id, $0) }) { first, _ in first }
        let theirs = Set(ids.filter { ownerChecks($0, row: rows[$0]) })     // once for each task
        return unknown.filter { theirs.contains($0.task) }
    }

    /// Whether an unknown outcome of the task `task` (its row `row`, nil when the reading has none) waits on the owner.
    private func ownerChecks(_ task: Int, row: FleetTask?) -> Bool {
        let shellOff = row.flatMap { row in agents.first { $0.name == row.owner } }
            .map { TaskOutcome.shellOff(role: $0.role, can: $0.can) } ?? false
        return (outcomes ?? []).contains {
            $0.task == task && $0.waitsOnOwner(holds: holds ?? [], taskEnded: row?.isTerminal, shellOff: shellOff)
        }
    }
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

    /// The word of a task in work, which the Tasks board leaves out of its card (`ActivityBoard`).
    public static let working = String(l10n: "Working")

    /// The state word: the owner's hold first, then, for a task that is not over, its agent's usage limit, a stall and a
    /// lost session; then a checked result, what the task waits on, and its own state.
    public static func state(_ state: String, accepted: Int?, requester: String, waitingOn: String? = nil,
                             stalled: Bool = false, reconnecting: Bool = false, hold: Hold? = nil,
                             limited: Bool = false) -> String {
        if let hold, hold.state != "released" {
            if hold.state == "requested" { return String(l10n: "Stopping…") }
            if hold.state == "not_confirmed" { return String(l10n: "Stop not confirmed") }
            return hold.kind == "pause" ? String(l10n: "Paused") : String(l10n: "Stopped")
        }
        let over = ["completed", "failed", "rejected", "canceled"].contains(state)
        if !over, limited { return String(l10n: "Usage limit") }
        if !over, stalled { return String(l10n: "Stalled") }
        if !over, reconnecting { return String(l10n: "Reconnecting") }
        if accepted == 1 && state == "completed" { return String(l10n: "Checked") }
        if accepted == 0 && state == "completed" { return String(l10n: "Not accepted") }
        if !over, let waitingOn, !waitingOn.isEmpty { return waiting(on: waitingOn, requester: requester) }
        switch state {
        case "working": return working
        case "submitted": return String(l10n: "Queued")
        case "input-required": return waitingFor(requester)
        case "auth-required": return String(l10n: "Sign-in needed")
        case "completed": return String(l10n: "Awaiting check")
        case "canceled": return String(l10n: "Canceled")
        default: return state.prefix(1).uppercased() + state.dropFirst()
        }
    }

    /// **Who a task waits for, in three words** (fix round 2): "Waiting for you" when its requester is the owner, else
    /// "Waiting for Manager". It said "Waiting for an answer", which named nobody in four words.
    public static func waitingFor(_ requester: String) -> String {
        requester == "owner" ? String(l10n: "Waiting for you") : String(l10n: "Waiting for \(requester.agentLabel)")
    }

    /// The one a task waits on when it is not its requester: a name ("Juno"). The hub's own reference to a question, a
    /// permission or a conversation ("Q-1", "P-3", "CM-7"), or to its screen, is its requester's to answer: nil.
    public static func waiter(of waitingOn: String) -> String? {
        isReference(waitingOn) ? nil : waitingOn.agentLabel
    }

    /// What a task waits on, in words: "Waiting on Juno", or its requester for one of the hub's references.
    static func waiting(on waitingOn: String, requester: String) -> String {
        waiter(of: waitingOn).map { String(l10n: "Waiting on \($0)") } ?? waitingFor(requester)
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

/// Owner feature `need_talk` (the owner, 9 November 2026: "Needs You items should be formatted MUCH better so they are
/// shorter and much easier to read"): a short card, Details and options that combine. Its Discuss left the apps on 13
/// November 2026 ("lets use the free-type text input as the general reply too, so we can remove the discuss option
/// completely"): Your answer is his one reply.
public enum NeedTalk {
    public static let feature = "need_talk"
    /// The hub's most for one message of the discussion, for a request that an older app saved (`OwnerCommand.needTalk`).
    public static let most = 2000
    /// The hub's most for a card's why: an item written before the rule may be longer, and keeps its fold.
    public static let why = 240
}

/// One message in the discussion of a Needs-you item, in the answer to a request that an older app saved
/// (`OwnerCommand.needTalk`): `who` is `owner` or the agent that replied.
public struct NeedMessage: Decodable, Equatable, Sendable {
    public let who: String
    public let text: String
    public let ts: Double
    public var fromOwner: Bool { who == "owner" }
}

/// What the first option of an item for access gives at his press (API 1.235): the agent, the level, and each
/// repository as owner/name.
public struct NeedGive: Decodable, Equatable, Sendable {
    public let agent: String
    public let level: String
    public let repos: [String]
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
    /// Owner feature `asks`: the `request_id` of his message whose work waits for his answer to this item, or nil.
    public let ask: String?
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
    /// API 1.160: the title of the task that asked for the run, on the door's card only, and nil on a card whose
    /// task the hub does not know. The apps show it after the title (`shownTitle`). No signature covers it and
    /// nothing decides by it, because an agent names its task itself; before the Mac signs, it holds these words
    /// to the rule of the card's other words (`DoorCall.checked`: no backtick).
    public let door_task: String?
    /// The item's title as the owner reads it. On the door's card it is `title`, which the Mac signs under, then
    /// the task that asked ("Run one root script on web-1? · Read the logs"): two cards on one server read as two
    /// things (the owner's "Yes, as shown" of 14 November 2026).
    public var shownTitle: String {
        guard let task = door_task, !task.isEmpty else { return title }
        return title + " · " + task
    }
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
    /// Owner feature `need_run` (API 1.197): the one command of a hand step that this Mac runs at his press of Run,
    /// and where it runs (`NeedRun.ownMac`, or a machine of the fleet); nil on every other item. Run stands only where
    /// `NeedRun.command(of:)` says.
    public let run_command: String?
    public let run_on: String?
    /// The lane "Give on a card" (owner feature `need_give`, API 1.235): the grant that the item's first option makes at
    /// his press, and nil on every other item. The hub writes that option's words ("Give <role> <level>"), so the card
    /// draws it as its one main action (`NeedAnswerBox`), and the press is the item's whole step.
    public let give: NeedGive?
    /// API 1.244: true on a team card of the manager (`change_team`, API 1.214), whose options are its yes options and
    /// then No; false on every other item, and nil from a hub before that version.
    public let team: Bool?
    /// Owner feature `need_recommended` (API 1.269): the answer that the agent that raised the item recommends, one of
    /// `options` word for word or, on an item with no options, a line of the agent's own words; nil on an item with
    /// none and from a hub before that version. The card marks its row with a badge (`recommendedRow`). Not in
    /// `signsTheSame`: a new field is nil before the hub's update and a value after it, and a press that waited across
    /// the update would be dropped with no word.
    public let recommended: String?
    /// Owner feature `need_clarify` (API 1.272): true when the card takes his message under it (Needs clarification:
    /// an open item of the manager's that is no conversation's question and no key request), as the hub decides it;
    /// nil from a hub before that version. The card draws its link only then (`clarifies`).
    public let clarify: Bool?
    /// His talk with the manager under the card, oldest first: his messages and its replies (`NeedMessage`); nil or
    /// empty for an item with none.
    public let talk: [NeedMessage]?
    /// **The options that only Founderizer on a Mac or a PC can press, by their index in `choices`** (the lane "Give on
    /// the iPhone": the owner's "Line to the Mac" of 19 November 2026 to the phone's picture, and his "Yes, add it" of
    /// the same day for the door's card). The hub refuses them from a phone: Give, the first option of an item that
    /// carries its grant, and each yes of a team card, every option but its last, because there the card shows what
    /// they change; and Full access, the second of the door card's three fixed answers ("Run it once", "Full access on
    /// <server>", "No"), because only the owner key on the Mac signs a server's mode. Empty on every other item.
    public var optionsOnlyOnAComputer: [Int] {
        switch onlyOnAComputer {
        case .give: return [0]
        case .teamYes: return Array(0..<(choices.count - 1))
        case .fullAccess: return [1]
        case nil: return []
        }
    }

    /// Which options of the item only a Mac or a PC presses (`optionsOnlyOnAComputer`), so that the phone's line names
    /// them by the first word of the hub's own answers.
    public enum OnlyOnAComputer: Sendable, Equatable {
        /// Give, which a Mac or a PC presses.
        case give
        /// The yes options of a team card, each starting with "Yes:", which a Mac or a PC presses.
        case teamYes
        /// Full access on the door card's server, which only the owner key on the Mac signs.
        case fullAccess
    }

    /// What only a Mac or a PC presses on this item, or nil for an item whose every option a phone presses.
    public var onlyOnAComputer: OnlyOnAComputer? {
        guard choices.count >= 2 else { return nil }
        if team == true { return .teamYes }
        if let host = door_host, !host.isEmpty { return .fullAccess }
        return give != nil ? .give : nil
    }

    /// One row of the options that the iPhone draws (`NeedOptions`).
    public enum PhoneRow: Hashable, Sendable {
        /// An option to press, by its index in `choices`, which its press sends: the hub reads a press by it.
        case option(Int)
        /// The one line to the Mac, in the place of options that only a Mac or a PC presses, by the index of the first
        /// of them, so that each row stays one of its own.
        case onTheComputer(Int)
    }

    /// The iPhone's rows of the item's options, in their order: each option that a phone presses, and one line in the
    /// place of each run of options that only a Mac or a PC presses (`optionsOnlyOnAComputer`).
    public var phoneRows: [PhoneRow] {
        let computer = Set(optionsOnlyOnAComputer)
        var rows: [PhoneRow] = []
        for index in choices.indices {
            if !computer.contains(index) {
                rows.append(.option(index))
            } else if !computer.contains(index - 1) {
                rows.append(.onTheComputer(index))
            }
        }
        return rows
    }
    /// Once he pressed Run: the command's exit status and the end of its output, which the hub masked; nil after an
    /// answer in words.
    public let run_status: Int?
    public let run_output: String?
    public var isOpen: Bool { answered == nil && answer == nil }
    /// The same card to sign, byte for byte: its words, its answers, its door call, server and script, and what its
    /// first option starts on this Mac (a GitHub App, the Add device picture). A press
    /// that waited for the store is dropped when the item changed under it (review of 12 November 2026: the Mac
    /// signed the script that a later read brought, not the one that he pressed on).
    public func signsTheSame(as other: OwnerNeed) -> Bool {
        func same(_ a: String?, _ b: String?) -> Bool { (a == nil) == (b == nil) && (a ?? "").utf8.elementsEqual((b ?? "").utf8) }
        return id == other.id && same(title, other.title) && same(why, other.why) && same(todo, other.todo)
            && same(details, other.details) && same(door_call, other.door_call) && same(door_host, other.door_host)
            && same(door_script, other.door_script) && same(door_task, other.door_task)
            && same(github_app, other.github_app) && same(run_command, other.run_command) && same(run_on, other.run_on)
            && add_device == other.add_device && give == other.give && (options ?? []).count == (other.options ?? []).count
            && zip(options ?? [], other.options ?? []).allSatisfy { same($0, $1) }
    }
    /// The options combine: he ticks any of them and sends them together (`NeedRequestCard`).
    public var combines: Bool { multi == true && choices.count >= 2 }

    /// An item that asks for a key or a login. It takes no answer in words: the hub refuses one, because a key typed
    /// into an answer is in the agent's conversation before anything can mask it. Its secure form answers it.
    public var asksForSecret: Bool { kind == "secret" }

    /// Owner feature `need_takeover` (API 1.217): an item whose agent asks for one step on its own screen that only a
    /// person can do. Its title is that step, and its card has Take over, which opens the agent's screen in Screen
    /// Sharing. He answers it in words or with a quick reply, as any item.
    public var asksForTakeover: Bool { kind == "takeover" }

    /// **The task of the item stands on the front of its card, under the reason** (the owner, 15 November 2026:
    /// "manager tasks need to be super specific ... the task itself need to be very clear"): the words that an agent
    /// wrote as what he does (`todo`), which stood behind Details. Not the hub's own sentence of a secret request or
    /// of a conversation's item, which says where the answer goes. **And not an item with a door call**, the door's
    /// card of a run among them: his yes there signs a call by its hash, and he runs nothing, so no command of the
    /// agent's own words stands on the front of that card with a copy icon, as if it were the call.
    /// **Nor an item that carries its grant** (`give`): Give is its step, and the hub's sentence about that press says
    /// nothing that the button does not.
    public var taskInFront: Bool { kind == nil && door_call == nil && give == nil }

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
    /// Owner feature `asks`: the name of what he asked for in this message, as his list shows it, or nil for a message
    /// that no task names. The first task of the message writes it, once.
    public let asked: String?
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
    /// CHAT-APPS.md 20: the files that the agent sent with these words. A hub from before that round sends none.
    public let attachments: [MessageAttachment]?
    /// **The owner's message whose turn this report took** (owner API 1.190), when it names none: the Fleet Manager's
    /// reply to a message written in the app, a worker's sentence before its task. It is no link (never `in_reply_to`),
    /// and only the row of what he asked for stands under it (`ChatAskPlaces`). A hub from before it sends none.
    public let turn: String?
    /// **The parts of a line that says a grant** (owner API 1.236): the Mac's chat shows a run of such lines as one
    /// card (`ChatGrantPlaces`). Nil for every other report, for a grant line whose agent was removed since (the hub
    /// has no record of that grant any more), and from a hub before it: such a line stays a line.
    public let grant: ReportGrant?
}

/// What one line of a grant says, in parts (`ManagerReport.grant`; owner API 1.236): the agent that got it, by the name
/// that it has now; the resource, by its id and in the owner's words; and the level, with the line's own words for it
/// ("write and deploy"). The hub gives them from its own record of the grant, so each one is there; the level and its
/// words are optional here only so that a hub that sent none would not stop the reading.
public struct ReportGrant: Decodable, Equatable, Sendable {
    public let agent: String
    public let resource: String
    public let kind: String?
    /// What kind of thing the resource is, in the line's own words ("Gmail", "MCP server"), or nil.
    public let word: String?
    public let title: String
    public let level: String?
    public let words: String?
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
            // The same files: the hub's replay of a request lists them by number, the request in its chips' order.
            && (attachments ?? []).sorted() == request.attachments.sorted()
    }
}

public struct SecretReference: Decodable, Identifiable, Sendable {
    public let id: Int
    public let label: String
}
