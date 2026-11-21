import Foundation

/// **Needs clarification on every card** (owner feature `need_clarify`, owner API 1.272; the owner, 20 November 2026:
/// "I thought we discussed recently about hvaing a option to "Discuss" so instead of replying I could provide additional
/// context?", "Bring it back", "a button link, that then shows the extra text input", and "Keep Your answer too" to the
/// picture of the card): under his answer a quiet link opens one field, and his message there goes to the manager
/// while the item stays open (`OwnerCommand.needTalk`). The manager's replies and his messages stand in the card over
/// the answers (`OwnerNeed.talk`). His answer still closes the item.
public enum NeedClarify {
    /// `ui_features` of a hub that takes his message under a card (`POST /ui/needs/<id>/talk`).
    public static let feature = "need_clarify"

    /// **The card whose Needs clarification field takes a key that a chat would send to its box**, or nil for the box
    /// (the owner, 21 November 2026: "I clicked on discuss and typed, dont remember where"; on his busy Mac the keys
    /// came before the field took them, and his words left as a chat message): `open`, the card whose field he opened,
    /// while it is a card of this chat's agent and its item is still open. A card of another chat, an answered item and
    /// a card that left the reading leave the box as it was.
    public static func field(open: Int?, chat agent: String, needs: [OwnerNeed]) -> Int? {
        guard let open, let need = needs.first(where: { $0.id == open }), need.by == agent, need.isOpen else { return nil }
        return open
    }
}

extension OwnerNeed {
    /// The card takes his message under it now: an open item that the hub says takes one (`clarify`), on a hub that
    /// names the feature. A key request answers with its own Needs clarification, and a conversation's item is that
    /// person's question: the hub says false for both.
    public func clarifies(features: [String]?) -> Bool {
        isOpen && clarify == true && features?.contains(NeedClarify.feature) == true
    }

    /// **His talk under the card, as the card shows it**: on a hub that names the feature, the whole talk of the item,
    /// open or answered, and also where the card takes no more of it (a renamed manager's card): the talk is his record
    /// of the item (the area of Needs-you, 20 November 2026: "the talk stands in the card" holds after his answer too).
    /// An answered card shows it read only: no link and no field (`clarifies`).
    public func shownTalk(features: [String]?) -> [NeedMessage] {
        features?.contains(NeedClarify.feature) == true ? talk ?? [] : []
    }
}
