import Foundation

/// **What a key request's card in a chat draws for his save** (the owner, 20 November 2026, with a picture of such a card
/// after his save, its hub's words cut at the end of one line: "animaton when entering a secret on a chat should be MUCH
/// smoother and simple.. no text needed, just a nice animation of loading and then a nice and smooth check"). The
/// secure form says which one, and its card draws it (`SecretEntryView`, `NeedRequestCard`):
/// - `goes`: his save runs. The card is its title and a ring that turns at its end.
/// - `saved`: every step is done. The ring becomes a check that draws itself, and the folded card keeps that check.
/// - `failed`: a step failed after the key went into the list, or a step ended with words that he must read: a grant
///   whose agent cannot use the key yet, a request that had its answer already. The card stands whole, with the form's
///   rows, Try again where a step can run again, and Done, also once the request has its answer: the grants run
///   before the answer, and the answer goes without them.
///
/// nil: the form shows its fields, or a line of its own (a problem before anything was sent, the line about a key of the
/// same name), and the card is as it was.
public enum KeySaveLook: Equatable, Sendable {
    case goes, saved, failed

    /// The look of a form. `done`: nil while the key is not in the list, else whether every step after it is done (the
    /// vault has it, the agents have it, the request has its answer). `warned`: a done step left words that he must
    /// read, so the check would say more than is true ("Statuses must be true"). `busy`: a step runs now, a Try again
    /// too. `saving`: his save passed the checks that end with a line of their own and has not ended. Decline and his
    /// words make the form busy with no save, and show no ring. **Every step done is the check at once**, also while
    /// the save's last read of the hub runs: that read brings the answered request, and the check must stand before it.
    public static func of(done: Bool?, warned: Bool = false, busy: Bool, saving: Bool) -> KeySaveLook? {
        guard let done else { return saving ? .goes : nil }
        if done && !warned { return .saved }
        return busy || saving ? .goes : .failed
    }
}

/// **The card around a key save** (`NeedRequestCard`): what it draws for its form's look, and when the folded card takes
/// its place. The form's look comes in with `take`; the card calls `settle` once the check has drawn itself and gone
/// quiet, and `end` for Done after a failed step.
public struct KeySaveCard: Equatable, Sendable {
    /// The form's last look.
    public private(set) var look: KeySaveLook?
    /// The check of the save drew itself and went quiet: the folded card, which shows the same check, can take its place.
    public private(set) var settled = false

    public init() {}

    /// The form's look. **A form that went after its save (nil) leaves the check where it stands**: the form goes once
    /// the request has its answer, and its card folds only when the check has drawn itself. False: nothing changed.
    @discardableResult
    public mutating func take(_ new: KeySaveLook?) -> Bool {
        if new == nil && look == .saved { return false }
        guard new != look else { return false }
        look = new
        settled = false
        return true
    }

    /// The check has drawn itself and gone quiet.
    public mutating func settle() {
        if look == .saved { settled = true }
    }

    /// Done after a failed step or a warning, and every other end of the form (a decline, his words): the card is as it
    /// was, and it folds once the request has its answer.
    public mutating func end() {
        look = nil
        settled = false
    }

    /// The card is its title and the mark at its end, with no words: the save runs, or its check draws, or the check
    /// waits for the reading that brings the answer. A card that he opened stays open.
    public func collapsed(expanded: Bool) -> Bool { !expanded && (look == .goes || look == .saved) }

    /// The folded card waits: a save runs, a failed step stands with its Try again, or the check still draws.
    public var holds: Bool { look == .goes || look == .failed || (look == .saved && !settled) }

    /// The card folds: `answered` (the request has its answer, or his answer is on its way, and no run goes on), he did
    /// not open it, and no save holds it.
    public func folds(answered: Bool, expanded: Bool) -> Bool { answered && !expanded && !holds }

    /// The form stands in the card: while the request is open, and while the save holds the card, so that a save whose
    /// answer the reading brought first can still say how it ended. **Never on an answered request once its check
    /// settled**: a form drawn again would offer the Key field of a request that has its answer.
    public func showsForm(open: Bool) -> Bool { open || holds }
}

/// **The mark of the part "Value" of a key's card** (the owner, 21 November 2026, word for word: "Yes, ring and check"):
/// at the start of the row of Cancel and Replace, the ring while his Replace runs, then the check that draws itself,
/// with no words, as on a key card (`KeySaveMark`); then the part is at rest again, with its empty field and no mark. A
/// step that failed has no mark: the form's rows say it, with Try again.
public struct KeyValueMark: Equatable, Sendable {
    /// The ring (`goes`) or the check (`saved`), or nil at rest.
    public private(set) var look: KeySaveLook?
    /// **The check of this Replace came already** (Fable's review of 22 November 2026): a later word of the same
    /// Replace draws no second check. The end of the save's last read of the hub can come after the check went to
    /// rest, about 2 seconds after it drew itself, and it said "saved" again. Only the ring of the next Replace starts
    /// a new one.
    private var checked = false

    public init() {}

    /// The form's look (`KeySaveLook.of`). **A form that went back to rest after its save (nil) leaves the check where it
    /// stands**: the part empties its field and is at rest at once, and the check draws itself there. A failed step
    /// (`failed`) is no mark, and the check comes once for each Replace (`checked`). False: nothing changed.
    @discardableResult
    public mutating func take(_ new: KeySaveLook?) -> Bool {
        let next = new == .failed ? nil : new
        if next == nil && look == .saved { return false }
        if next == .saved && checked { return false }
        guard next != look else { return false }
        look = next
        if next == .goes { checked = false }
        if next == .saved { checked = true }
        return true
    }

    /// The check has drawn itself and stood for a moment, or he types a new value: the part is at rest, with no mark. A
    /// ring that turns stays: its save still runs.
    public mutating func rest() {
        if look == .saved { look = nil }
    }
}

extension OwnerNeed {
    /// **A saved key answered this request**: its folded card is its title and a check, with no words. The hub's words
    /// of the answer stay in the whole card, a click away. A key request that he declined, or answered with his own
    /// words (Needs clarification), keeps its words on the folded card.
    public var answeredWithKey: Bool {
        asksForSecret && !isOpen && secret?.saved != nil && secret?.clarified != true
    }
}

extension ChatList {
    /// **His answer with a saved key is the check of its card on the agent's row, with no words** (the owner, 20
    /// November 2026: "Yes, both" to the sidebar's line and Needs you without words after a saved key): true when the
    /// row's line would say his last message (`preview`), and that message is the answer of a request that a saved
    /// key answered. The hub writes that answer as his message, in long words that are the agent's.
    public static func savedKey(_ agent: String, last: ChatEntry?, tasks: [FleetTask], needs: [OwnerNeed]) -> Bool {
        guard case .message(let message)? = last, message.kind == "answer", let id = message.need_id,
              needs.first(where: { $0.id == id })?.answeredWithKey == true else { return false }
        // a task of the agent that moved after his answer is the line instead, and says what it does now (`preview`)
        return preview(agent, last: last, tasks: tasks) == preview(agent, last: last, tasks: [])
    }
}

extension ChatList {
    /// **The line of an agent's row, in the sidebar and in the search, in its one order**: a request that waits for him
    /// and is the newest thing in its chat (its title, in orange: `waitingRequest`), else his answer with a saved key
    /// (the card's check, with no words: `savedKey`), else the newest thing it did in words (`preview`). Both rows ask
    /// this one rule, so a saved key's check never stands in the place of a request that waits for him.
    public enum Line {
        case waiting(OwnerNeed), savedKey, words(String)

        /// The request that waits for him, where it is the line.
        public var request: OwnerNeed? { if case .waiting(let need) = self { need } else { nil } }
        /// The line is the check of a saved key's card.
        public var isSavedKey: Bool { if case .savedKey = self { true } else { false } }
        /// What the line says: the request's title, the check's word for VoiceOver, or its words.
        public var words: String {
            switch self {
            case .waiting(let need): need.title
            case .savedKey: String(l10n: "Saved")
            case .words(let words): words
            }
        }
    }

    /// The line of `agent`'s row (`Line`). `entries`: the newest entries of its chat, oldest first; `whole`: they are its
    /// whole chat. Nil before the first message, and the row then shows the name alone.
    /// `features`: the hub's, for the words of his last message (`preview`).
    public static func line(_ agent: String, entries: [ChatEntry], whole: Bool, needs: [OwnerNeed], tasks: [FleetTask],
                            features: [String]? = nil) -> Line? {
        if let request = waitingRequest(agent, entries: entries, whole: whole, needs: needs) { return .waiting(request) }
        if savedKey(agent, last: entries.last, tasks: tasks, needs: needs) { return .savedKey }
        return preview(agent, last: entries.last, tasks: tasks, features: features).map(Line.words)
    }
}
