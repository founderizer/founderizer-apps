import Foundation

/// **What one row answers, when the answer is yes or no.**
///
/// The owner, 20 October 2026: "not even sentences, just a check or a cross, and on hover probably show the
/// detail? This applies to all menus, it needs to be simpler! fleet setup should be super simple! you can keep
/// data internally etc."
///
/// So a row that states a fact answers with a mark, and the sentence it used to print lives behind that mark. The
/// app keeps every detail it has — this is about what reaches the surface, and about nothing else.
///
/// **A mark is for a binary fact; a sentence is for a decision.** The test is whether the answer is yes or no.
/// "The firewall is off" is a mark. "This grant will let vps deploy to production" is not, and stays a sentence
/// with its buttons.
///
/// Each state has its own shape as well as its own colour, because colour is never the only cue.
public enum MarkState: String, Equatable, Sendable, CaseIterable {
    /// It is as it should be.
    case good
    /// It is not, and the row carries the one thing to do about it.
    case bad
    /// It works, and something about it is worth knowing.
    case warn
    /// Nothing here can say, which is never drawn as a pass.
    case unknown
    /// It is being found out now.
    case working

    public var symbol: String {
        switch self {
        case .good: return "checkmark.circle.fill"
        case .bad: return "xmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
        case .working: return "clock.arrow.circlepath"
        }
    }

    /// The word behind the mark: the accessibility label, and the first line of the detail a reader opens. A
    /// caller with a better word of its own passes it instead.
    public var words: String {
        switch self {
        case .good: return "Fine"
        case .bad: return "Not fine"
        case .warn: return "Worth knowing"
        case .unknown: return "Not known"
        case .working: return "Finding out"
        }
    }

    /// It is one to act on, so the mark is drawn in orange and the row carries what to do.
    public var attention: Bool { self == .bad || self == .warn }

    /// One `verify` answer as a mark: `ok`, `warn` or `fail`, and anything else is not read as a pass.
    public static func of(_ check: VerifyCheck) -> MarkState {
        check.passed ? .good : check.warned ? .warn : check.failed ? .bad : .unknown
    }
}
