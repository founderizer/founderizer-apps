import Foundation

/// **A message that an AI session sent for him does not look like his own** (owner feature `message_hands`; the owner's
/// "B, go ahead" of 24 November 2026 to the picture `ai-session-mark-2026-11-24/1b-outline-and-mark.png`, after "why
/// does it look like I sent that message? I didn't"): the hub gives each of his messages the hand that sent it
/// (`hand`, owner API 1.289) and, for an AI session, its program (`runtime`), on `messages[]`, on the message rows of
/// `GET /ui/older`, on the items of a phone's chat, on his lines of a card's talk and on his guidance of a task
/// (`steers[]`), and the phone's list of chats leaves out "You: " before such words. The filled bubble stays his own
/// words; words that another hand sent stand in the bubble's outline, still at the right, and an AI session's have its
/// mark in the bubble's lower left corner, where a chat app's mark goes. One rule for every place of both apps.
public enum OwnerHand {
    /// `ui_features` of a hub that gives `hand` and `runtime`. Without it every bubble is drawn as before.
    public static let feature = "message_hands"

    /// The AI whose mark stands on the bubble, by the name of its logo in `ProviderLogo` (FleetMark).
    public enum Runtime: String, CaseIterable, Equatable, Sendable {
        case claude, codex, grok, opencode

        /// The hub's name of the program (the labels of its runtime table: `claude-code`, `codex`, `grok`, `opencode`);
        /// nil for a program that has no mark here.
        public init?(hub: String?) {
            switch hub {
            case "claude-code": self = .claude
            case "codex": self = .codex
            case "grok": self = .grok
            case "opencode": self = .opencode
            default: return nil
            }
        }
    }

    /// How one bubble of his is drawn.
    public struct Look: Equatable, Sendable {
        /// The bubble in its outline, with no fill: words that he did not write with his own hand.
        public let outlined: Bool
        /// The mark of the AI session that sent them, or nil.
        public let mark: Runtime?

        public init(outlined: Bool, mark: Runtime?) { self.outlined = outlined; self.mark = mark }

        /// His own words: the filled bubble with no mark.
        public static let his = Look(outlined: false, mark: nil)

        /// **What VoiceOver reads for a line of his talk with these words**: "You: " only before his own words; an AI
        /// session's with the mark's words before them; another hand's words alone. It never tells him that he wrote
        /// what he did not.
        public func spoken(_ text: String) -> String {
            guard outlined else { return String(l10n: "You: \(text)") }
            return mark == nil ? text : "\(OwnerHand.sentByAISession): \(text)"
        }
    }

    /// The words of an AI session's mark: its hover text on the Mac, and what VoiceOver reads on both apps.
    public static var sentByAISession: String { String(l10n: "Sent by your AI session") }

    /// The hands of his own words: this Mac's app, a device of his (the iPhone), and a chat app of his. A row from before
    /// owner API 1.289 has no hand (nil), and it keeps the look that it always had.
    private static let his: Set<String> = ["app", "device", "chat"]

    /// **The look of one bubble of his**: the filled bubble for his own hands and for a row with no hand; the outline
    /// for every other hand (`tool`, an AI session through the owner tools; `connected`, a connected app; `other`); and
    /// the AI's mark only for `tool` with a program that has a mark. A hand that this app does not know is not proved
    /// his, so it is outlined too: the filled bubble is always his own words. On a hub without the feature, as before.
    public static func look(features: [String]?, hand: String?, runtime: String?) -> Look {
        guard features?.contains(feature) == true, let hand, !his.contains(hand) else { return .his }
        return Look(outlined: true, mark: hand == "tool" ? Runtime(hub: runtime) : nil)
    }
}

extension OwnerMessage {
    /// The look of this message's bubble (`OwnerHand.look`).
    public func look(features: [String]?) -> OwnerHand.Look {
        OwnerHand.look(features: features, hand: hand, runtime: runtime)
    }
}

extension TaskSteer {
    /// The look of this guidance's bubble in a task's thread (`OwnerHand.look`).
    public func look(features: [String]?) -> OwnerHand.Look {
        OwnerHand.look(features: features, hand: hand, runtime: runtime)
    }
}

extension NeedMessage {
    /// The look of this line of a card's talk: his line by its hand (`OwnerHand.look`); an agent's reply is no bubble.
    public func look(features: [String]?) -> OwnerHand.Look {
        fromOwner ? OwnerHand.look(features: features, hand: hand, runtime: runtime) : .his
    }
}
