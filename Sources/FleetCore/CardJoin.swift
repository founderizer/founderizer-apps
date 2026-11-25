import Foundation

/// **A name beside its own role is one badge, with the name** (the owner, 21 November 2026, of a card that drew an
/// agent's name and its role as two badges: "it should be the same, right? or show it only once!", and his "Yes, as
/// drawn"; 22 November 2026: an agent shows by its name, and "the names should show ... in needs you cards"): on a
/// request's card, "Nova (Customer Support Lead)" is one badge "Nova", and so are "Customer Support Lead (Nova)", "Nova,
/// Customer Support Lead" and the two with " - ", " – " or " — " between them. **The badge's words are the agent's
/// label** (`AgentNames.label`, as every place of the apps names it): its name, or its role where a word of the role is
/// the name ("Manager (Fleet Manager)" is one badge "Fleet Manager"). It is the card's alone: a chat's message keeps
/// every character that its writer wrote but a whole role (`ChatNames`), so `CardNames.pieces` stays as it is, and the
/// card joins its pieces after it (`CardBadgeText.text`, `CardValues.values`).
///
/// Two pieces join when both are badges of one agent, one is the agent's own name with a capital (as `CardNames` finds
/// it) and the other has other words (its role, or a start of it that the book holds), and the words between them are
/// exactly " (" with ")" right after the second, ", ", " - ", " – " or " — ". **This is one of two exceptions to the
/// rule of `CardNames.pieces` that every character stays:** the role, the words between them and the bracket's ")" go,
/// and the name's piece stays as the text wrote it, with its link (the role's piece where the label is the role). A
/// name and its role with other words between them, and the names of two agents, stay two badges. **The other
/// exception: a whole role alone is a badge with the agent's label and its role** (`RoleNames`; the owner, 23 November
/// 2026: "We should ALWAYS use the name", and "The name with the role in grey"), where the chat's stricter rules find
/// it: "I asked Marketing" draws the badge "Wren · Marketing", and "Marketing spend rose 10%" at a line's start keeps
/// "Marketing". Every other character stays, in its order.
public enum CardJoin {
    /// The words between a name and its role, but the bracket's (" (", which ")" after the second closes).
    static let between: Set<String> = [", ", " - ", " – ", " — "]

    /// `pieces` (`CardNames.pieces`) with each name and its role beside it as one piece, the label's, and each whole
    /// role alone as the label's and its role's (`RoleNames.named`). `roles`: each agent's role, by its name (`AgentNames.roles`), the
    /// hub's newest reading's by default. **`oneLine`: each line break of the words is a space** after the names are
    /// read, for words that a place draws on one line (a folded reason): a role at a line's start then keeps its words as
    /// on the open card, where it stands at a line's start (`RoleNames`).
    public static func join(_ pieces: [CardNames.Piece], roles: [String: String] = AgentNames.shared.roles,
                            oneLine: Bool = false) -> [CardNames.Piece] {
        // which role to name is read from the pieces as the text has them: a join takes words away
        let named = RoleNames.named(pieces, roles: roles)
        var joined: [CardNames.Piece] = [], index = 0
        while index < pieces.count {
            if let one = one(at: index, in: pieces, roles: roles) ?? written(at: index, in: pieces) {
                joined += one.pieces
                index += one.taken
            } else {
                joined.append(named[index])
                index += 1
            }
        }
        guard oneLine else { return joined }
        return joined.map { piece in
            var words = piece.words
            // from the end, so that each place before it stays where it was
            for index in words.characters.indices.filter({ words.characters[$0].isNewline }).reversed() {
                words.characters.replaceSubrange(index...index, with: " ")
            }
            return CardNames.Piece(words: words, badge: piece.badge)
        }
    }

    /// The name and the role that begin at `index` as the label's one piece, with the words after a bracket's ")",
    /// and how many pieces they take; nil where the pieces there are no name and its role.
    private static func one(at index: Int, in pieces: [CardNames.Piece], roles: [String: String])
        -> (pieces: [CardNames.Piece], taken: Int)? {
        guard index + 2 < pieces.count, pieces[index + 1].badge == nil,
              let kept = kept(pieces[index], pieces[index + 2], roles: roles) else { return nil }
        let gap = String(pieces[index + 1].words.characters)
        guard gap == " (" else { return between.contains(gap) ? ([kept], 3) : nil }
        guard index + 3 < pieces.count, pieces[index + 3].badge == nil,
              let close = pieces[index + 3].words.characters.first, close == ")" else { return nil }
        let words = pieces[index + 3].words
        let rest = AttributedString(words[words.characters.index(after: words.startIndex)...])
        return (rest.characters.isEmpty ? [kept] : [kept, CardNames.Piece(words: rest, badge: nil)], 4)
    }

    /// **In the owner's own words** (`RoleNames.Written`, his typed answer on a card) a name beside its
    /// own role keeps every character that he wrote, and only the name is a badge: the role's piece is plain words, with
    /// no link, as in his own chat bubble (`ChatNames`), so the agent shows once (his "show it only once!" of 21 November
    /// 2026). The three pieces and how many they take; nil where they are no name and its role in his words.
    private static func written(at index: Int, in pieces: [CardNames.Piece]) -> (pieces: [CardNames.Piece], taken: Int)? {
        guard index + 2 < pieces.count, pieces[index + 1].badge == nil, case .agent(let agent)? = pieces[index].badge,
              pieces[index + 2].badge == pieces[index].badge,
              RoleNames.isWritten(pieces[index].words), RoleNames.isWritten(pieces[index + 2].words) else { return nil }
        let gap = String(pieces[index + 1].words.characters)
        guard gap == " (" || between.contains(gap) else { return nil }
        let name = agent.capitalized, one = String(pieces[index].words.characters)
        let two = String(pieces[index + 2].words.characters)
        guard one != two, one == name || two == name else { return nil }
        var three = Array(pieces[index...(index + 2)])
        let role = one == name ? 2 : 0
        var words = three[role].words
        words.link = nil
        three[role] = CardNames.Piece(words: words, badge: nil)
        return (three, 3)
    }

    /// The piece that stays, where `first` and `second` are an agent's own name and its role, in either order: the
    /// name's, or the role's where the agent's label is not its name (a role that says the name, "Fleet Manager").
    /// **None in the owner's own words** (`RoleNames.Written`): they keep every word that he wrote (`written`).
    private static func kept(_ first: CardNames.Piece, _ second: CardNames.Piece, roles: [String: String])
        -> CardNames.Piece? {
        guard case .agent(let agent)? = first.badge, second.badge == first.badge,
              !RoleNames.isWritten(first.words), !RoleNames.isWritten(second.words) else { return nil }
        let name = agent.capitalized, one = String(first.words.characters), two = String(second.words.characters)
        guard one != two, one == name || two == name else { return nil }
        let byName = AgentNames.label(agent, roles: roles) == name
        return (one == name) == byName ? first : second
    }
}
