import Foundation

/// **What the chat says while the owner waits for an answer**, and whether anything is genuinely moving.
///
/// The owner, 20 October 2026: "we need some kind of Thinking animation, like in chatgpt or like in our [other]
/// project". His own project is the reference, and it already carries his own correction to the obvious design —
/// 14 October 2026, in `conversation-state.ts`: *"why does it say Thinking and sometimes Starting??"*. The rule he
/// settled on there is the rule here:
///
///   - **While the agent is working, the chat says one thing.** The queue, the pickup, the retry and the agent's
///     own waits are all the agent working, and narrating them as stages is the noise he objected to.
///   - **A wait gets its own words only when it is not the agent's work** — when something outside it is in the
///     way and he may have to act.
///
/// That second half matters more here than it does in his other project, because this wait is not a model
/// answering now: the message goes to the hub and is answered when that agent's session next runs, which can be
/// minutes. Three dots pulsing for four minutes is a lie, and worse, it cannot be told apart from a hang. So a
/// wait that is blocked says what is blocking it **and stops moving**: motion means something is happening.
public struct ChatWaiting: Equatable, Sendable {
    /// The one line, in the owner's own terms: one word for the agent's work, two for a wait that is not its work.
    public let says: String
    /// Something is genuinely happening, so the line may move. A blocked wait never moves.
    public let moving: Bool
    /// The rest of a blocked wait — whose wait it is, until when, and that the message is kept — for the line's hover
    /// text and its accessibility label. A wait is a few words at a glance (his own project's waits are two or
    /// three), and a time to read is there for the owner who asks for it.
    public let detail: String?

    public init(says: String, moving: Bool, detail: String? = nil) {
        self.says = says; self.moving = moving; self.detail = detail
    }

    /// The one word for every part of this that is the agent's own work.
    public static let working = String(l10n: "Thinking")
    /// The two words of a usage limit, as the board and a thread's head say them.
    public static let limited = String(l10n: "Usage limit")

    /// The mark of a blocked wait: the one its state has on every screen (fix round 3, one mark per state), so a
    /// usage limit has the board's hourglass, and the other waits the clock.
    public var symbol: String { says == Self.limited ? "hourglass" : "clock" }

    /// What the hub knows about the owner's newest message to this agent.
    public enum Pending: Sendable, Equatable {
        /// Nothing of his is outstanding.
        case none
        /// His message is outstanding and nothing has come back since.
        case waiting
        /// **The agent has said something since, and nothing links it to his message.** The hub gives a request
        /// id only to a worker's or a lead's chat, so the fleet manager's every reply lands here — which is why
        /// a line that counted this as work never cleared for the manager, and said "Thinking" under an answer
        /// he had already read (20 October 2026, his own screen). It is not evidence that the agent is working,
        /// so the chat claims nothing and says nothing.
        case spokenSince
        /// **The agent read his message and ended that turn with no reply** (hub 1.110, `turnIsOver`). Nothing of
        /// that turn can still answer it, so the agent does not work on it now, and the chat says nothing. A session
        /// on his Mac sent the manager three messages that asked for no answer, and "Thinking" turned under them for
        /// more than an hour after turns of 20 seconds (10 November 2026, his own screen).
        case turnOver

        /// **The wait when the hub says that his newest message is late** (hub 1.144, `chat_undelivered`). A word of
        /// the agent that names no message ends the wait by itself (`spokenSince`), and so does a first sentence
        /// before a task that the agent then did not open. The hub knows that no reply names his message two minutes
        /// after the agent read it, so for a message that it calls late such a word ends nothing: the chat says "Not
        /// answering" under it. Every other state stays as it is.
        public func late(_ late: Bool?) -> Pending { late == true && self == .spokenSince ? .waiting : self }
    }

    /// The feature name of a hub whose `turn_ended_after` and `waits_since` count the manager's answers to its
    /// Needs-you items (hub 1.283, `chat_waits_answers`).
    public static let answersFeature = "chat_waits_answers"

    /// **Whether the chat of an agent with this role waits on his answer to one of its Needs-you items too** (hub
    /// 1.283): only the manager's, and only on a hub that names `answersFeature`. The manager reads such an answer in
    /// its own chat session and works on it there, in a turn whose end the hub knows (`turnIsOver`). The owner, 21
    /// November 2026, after he answered three of its cards in its chat: "shouldn't we show somehow that they are being
    /// done? nothing moved on the left sidebar and the cards just remained with a check". A worker's or a lead's
    /// answer goes to the task that asked, where no turn of its chat follows it, so a wait on it would never end. An
    /// older hub's turn end never counts an answer, so there the wait would stand until the manager's next word.
    /// `hubSays`: the hub names `answersFeature`. Each app's own chat rule asks this one question.
    public static func waitsOnAnswers(role: String, hubSays: Bool) -> Bool { hubSays && role == "manager" }

    /// **The message of his whose reply holds the row of his ask while that message is worked on**
    /// (`ChatAskPlaces.rows`, `waitsOn`): his newest chat message (`kind` "message"), never his answer to a request. In
    /// the manager's chat the line waits on such an answer too (`waitsOnAnswers`), but the answer's card stands in no
    /// turn: a row that it held stood under his message and then moved under the reply a reading later (review of 21
    /// November 2026). `moving`: the line moves by the rule that leaves his answers out (`answers: false` of
    /// `FleetAgent.chatWaiting`), so a message whose turn is over holds no row while the line moves for an answer.
    /// nil: nothing holds a row.
    public static func asksWaitOn(_ entries: [ChatEntry], moving: Bool) -> String? {
        guard moving else { return nil }
        for entry in entries.reversed() {
            if case .message(let message) = entry, message.kind == "message" { return message.request_id }
        }
        return nil
    }

    /// **Whether the turn that took his message is over** (hub 1.110, `agents[].turn_ended_after`): the hub says when
    /// he sent the newest message that the agent had read at its last turn end, so a message sent at or before that
    /// time was read in a turn that has ended. nil, from an agent whose turns the hub does not know (one with no owner
    /// chat, or whose helper does not report its turns yet, helper feature `chat_turns`; on a hub before UI-API 1.309,
    /// every agent but the manager) or from an older hub, says nothing, and the wait stays as it was.
    public static func turnIsOver(sent: Double, turnEndedAfter: Double?) -> Bool {
        guard let turnEndedAfter else { return false }
        return sent <= turnEndedAfter
    }

    /// What the chat shows under the last message, or nil when nothing is waited for.
    ///
    ///   - `pending`: what the hub knows about his newest message (`FleetAgent.pendingChat`).
    ///   - `sending`: this Mac has a request on its way to the hub, which is its own short wait.
    ///   - `limit`: the agent's runtime is at a usage limit, so nothing of its will run until it resets.
    ///   - `offline`: the hub has not heard from that agent's helper.
    ///   - `until`: how a time of this fleet reads to the owner, so this stays free of the app's formatting.
    public static func of(agent: String, pending: Pending, sending: Bool, limit: RuntimeLimit?, offline: Bool,
                          until: (Double) -> String) -> ChatWaiting? {
        guard pending == .waiting || sending else { return nil }
        let who = agent.agentLabel
        // Not the agent's work: it cannot run at all until its allowance resets. This is the case he must never
        // be left guessing about, because nothing will happen for a known length of time.
        if let limit {
            return ChatWaiting(says: limited, moving: false,
                               detail: limit.reset_known ? String(l10n: "\(who) is at its usage limit until \(until(limit.until)).")
                               : String(l10n: "\(who) is at its usage limit."))
        }
        // Not the agent's work either: the hub is not hearing from its server, so the message sits where it is.
        if offline {
            return ChatWaiting(says: String(l10n: "Not answering"), moving: false,
                               detail: String(l10n: "\(who) is not answering. Your message is kept and reaches it when it is back."))
        }
        return ChatWaiting(says: working, moving: true)
    }
}

extension FleetAgent {
    /// What the hub shows about the owner's newest chat message to this agent; nil with no message, or with a reply
    /// that names this message. Only a reply linked to this exact message proves an answer: a reply to an older
    /// message never does, and a later report without a link leaves it unknown. A message that the agent wrote first
    /// (`pushed`) is no reply. **A message that the agent read in a turn that has ended is not worked on** (hub 1.110,
    /// `turn_ended_after`): the manager did what three messages of 10 November 2026 asked in turns of 20 seconds and,
    /// as they told it, wrote no reply, and "Thinking" turned under them for more than an hour. The hub knows the
    /// turns of each agent's owner chat whose helper reports them (UI-API 1.309, helper feature `chat_turns`; before
    /// it, of the manager's session only); for an agent whose turns it does not know, this is a fact about the message,
    /// not a claim that the agent works. **For the manager, his answer to one of its Needs-you items is such a message
    /// too**, on a hub that counts it (`chatWaits(on:in:)`, hub 1.283).
    /// `answers`: false leaves his answers out for every agent (`ChatWaiting.asksWaitOn`).
    public func pendingChat(in state: HubState, answers: Bool = true) -> PendingChat? {
        let waited = state.messages.filter {
            $0.chatRecipient == name && (answers ? chatWaits(on: $0, in: state) : $0.kind == "message")
        }
        guard let message = waited.max(by: { $0.created < $1.created }) else { return nil }
        let reports = state.reports.filter { $0.chatAgent == name && !$0.isPushed }
        if reports.contains(where: { $0.in_reply_to == message.request_id }) { return nil }
        if reports.contains(where: { $0.in_reply_to == nil && $0.created >= message.created }) { return PendingChat(state: .unlinked, sent: message.created) }
        if ChatWaiting.turnIsOver(sent: message.created, turnEndedAfter: turn_ended_after) { return PendingChat(state: .turnOver, sent: message.created) }
        return PendingChat(state: message.read_at == nil ? .unread : .read, sent: message.created)
    }

    /// **Whether this agent's chat line can wait on this message of his**: a chat message, and for the manager his
    /// answer to one of its Needs-you items too, on a hub that counts such answers (`ChatWaiting.waitsOnAnswers`). The
    /// rows of his asks wait on his chat messages only (`ChatWaiting.asksWaitOn`).
    public func chatWaits(on message: OwnerMessage, in state: HubState) -> Bool {
        message.kind == "message" || (message.kind == "answer" && ChatWaiting.waitsOnAnswers(
            role: role, hubSays: state.ui_features?.contains(ChatWaiting.answersFeature) == true))
    }

    /// **What this agent's chat waits for** (`ChatWaiting.of`), from the hub's state alone, so the chat's line and
    /// every other sign of the same wait read one rule: the agent's row of the sidebar moves while this says
    /// "Thinking" (`thinks`). `sending`: this device has the owner's message to this agent on its way. `fresh`: the
    /// state is a current reading; an old one cannot say that the agent's server is quiet. `answers`: false leaves his
    /// answers to requests out, as the rows of his asks wait (`ChatWaiting.asksWaitOn`).
    public func chatWaiting(in state: HubState, sending: Bool, fresh: Bool, until: (Double) -> String,
                            answers: Bool = true) -> ChatWaiting? {
        ChatWaiting.of(agent: name,
                       pending: (pendingChat(in: state, answers: answers)?.waits ?? .none).late(chat_undelivered),
                       sending: sending, limit: limit,
                       // also when its server answers and his message does not arrive (hub 1.144, `chat_undelivered`)
                       offline: fresh && (!helperIsRecent(serverTime: state.time) || chat_undelivered == true),
                       until: until)
    }

    /// **Whether the agent works on the owner's newest chat message now**: its chat's line says "Thinking" and moves.
    /// A wait that is not the agent's work (a usage limit, a server that does not answer) is not thinking.
    public func thinks(in state: HubState, sending: Bool, fresh: Bool) -> Bool {
        chatWaiting(in: state, sending: sending, fresh: fresh, until: { _ in "" })?.moving == true
    }
}

/// **The owner's newest chat message to an agent while no reply names it**, which is how the chat itself knows
/// to wait (`ChatWaiting`). It is not a row anywhere: whether a message is read, and what came back, is the chat
/// in front of him, and on a page beside it it was bookkeeping he could do nothing with (21 October 2026).
public struct PendingChat: Equatable, Sendable {
    public enum State: Sendable { case unread, read, unlinked, turnOver }
    public let state: State
    public let sent: Double

    /// What the chat's waiting line makes of it (`ChatWaiting.of`): only a message that the agent has not read, or
    /// reads in a turn that still runs, is waited for.
    public var waits: ChatWaiting.Pending {
        switch state {
        case .unlinked: .spokenSince
        case .turnOver: .turnOver
        case .unread, .read: .waiting
        }
    }
}
