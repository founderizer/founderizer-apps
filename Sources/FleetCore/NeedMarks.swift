import Foundation

/// **The mark of an answered card, in the place of its check** (owner feature `need_marks`, owner API 1.280; the
/// owner, 21 November 2026, of three cards that he answered in the manager's chat: "shouldn't we show somehow that they
/// are being done? nothing moved on the left sidebar and the cards just remained with a check", and his "Yes, as
/// drawn" to its looks): the check while nothing runs that the hub knows, the turning green mark of work while a
/// record proves that work runs, and the red mark of work that ended with no success. Exactly these three looks: a
/// task that waits is look 1, "nothing runs that the hub knows", with its state word (the area Needs-you and the
/// manager, 21 November 2026: a muted resting symbol would be a fourth look with no yes). It moves only on such a
/// record, and it ends when that record ends. Its words are behind the mark only: on hover, and for VoiceOver.
public enum AnsweredMark: Sendable, Equatable {
    /// Done, or nothing runs that the hub knows: the check, as before. For a task that waits, its state word.
    case done(words: String)
    /// Work runs now: the turning green mark (at rest, green, with Reduce Motion). For the task that his answer lets go
    /// on, its agent and its title too, which `words` joins ("<Role> · <title>"); nil for a team card's plan.
    case working(words: String, agent: String?, title: String?)
    /// The work ended with no success: the red mark.
    case failed(words: String)

    /// `ui_features` of a hub that gives an item's `team_state`, `team_reason` and `task`.
    public static let feature = "need_marks"

    /// What the pointer and VoiceOver read for the mark.
    public var words: String {
        switch self {
        case .done(let words), .working(let words, _, _), .failed(let words): words
        }
    }
}

extension OwnerNeed {
    /// **The mark of this card once he answered it with an option** (`AnsweredMark`), from the reading that holds it:
    /// - a team card says where its plan stands: the hub makes it ("The hub makes the change"), made ("Changed"), or
    ///   not made (the hub's own sentences);
    /// - Give that he pressed is made with his answer ("Given");
    /// - the task that his answer lets go on (a question's, a door card's or a take-over's): work now by its own mark
    ///   turns (`FleetTask.mark`), a result that the Tasks board badges red is the red mark, a checked result is the
    ///   check ("Done"), and a task that waits, or whose result waits for its check, is the check with its state word;
    /// - else, and on a hub before the feature, and for a task that the reading does not hold: the check, and the
    ///   agent that raised it has his answer.
    /// A card that he answered in words keeps no mark, and the key card and the Run card keep their own: the card
    /// decides those, as it did for the check.
    public func answeredMark(in state: HubState?) -> AnsweredMark {
        let received = AnsweredMark.done(words: String(l10n: "\(by.agentLabel) has your answer"))
        guard let state, state.ui_features?.contains(AnsweredMark.feature) == true else { return received }
        switch team_state {
        case "making": return .working(words: String(l10n: "The hub makes the change"), agent: nil, title: nil)
        case "not_made": return .failed(words: team_reason ?? "")
        case "made": return .done(words: String(l10n: "Changed"))
        default: break
        }
        if give != nil, chosen == 0 { return .done(words: String(l10n: "Given")) }
        guard let task, let found = state.tasks.first(where: { $0.id == task }) else { return received }
        let mark = found.mark(in: state)
        switch found.tint(in: state) {
        case .failed: return .failed(words: found.failedResult ?? mark.words)
        case .checked: return .done(words: String(l10n: "Done"))
        default: break
        }
        if mark.inWork {
            return .working(words: "\(found.owner.agentLabel) · \(found.title)", agent: found.owner, title: found.title)
        }
        return .done(words: mark.words)
    }
}
