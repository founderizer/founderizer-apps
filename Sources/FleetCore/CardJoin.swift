import Foundation

/// **A name beside its own role is one badge, with the name** (the owner, 21 November 2026, of a card that drew an
/// agent's name and its role as two badges: "it should be the same, right? or show it only once!", and his "Yes, as
/// drawn"; 22 November 2026: an agent shows by its name, and "the names should show ... in needs you cards"): on a
/// request's card, "Nova (Customer Support Lead)" is one badge "Nova", and so are "Customer Support Lead (Nova)", "Nova,
/// Customer Support Lead" and the two with " - ", " – " or " — " between them. **The badge's words are the agent's
/// label** (`AgentNames.label`, as every place of the apps names it): its name, or its role where a word of the role is
/// the name ("Manager (Fleet Manager)" is one badge "Fleet Manager"). It is the card's alone: a chat's message keeps
/// every character that its writer wrote (`ChatNames`), so `CardNames.pieces` stays as it is, and the card joins its
/// pieces after it (`CardBadgeText.text`, `CardValues.values`).
///
/// Two pieces join when both are badges of one agent, one is the agent's own name with a capital (as `CardNames` finds
/// it) and the other has other words (its role, or a start of it that the book holds), and the words between them are
/// exactly " (" with ")" right after the second, ", ", " - ", " – " or " — ". **This is the one exception to the rule
/// of `CardNames.pieces` that every character stays:** the role, the words between them and the bracket's ")" go, and
/// the name's piece stays as the text wrote it, with its link (the role's piece where the label is the role). Every
/// other character stays, in its order. A name and its role with other words between them, and the names of two
/// agents, stay two badges. A role alone stays a badge with the role: the card draws no words that the agent did not
/// write.
public enum CardJoin {
    /// The words between a name and its role, but the bracket's (" (", which ")" after the second closes).
    static let between: Set<String> = [", ", " - ", " – ", " — "]

    /// `pieces` (`CardNames.pieces`) with each name and its role beside it as one piece: the label's. `roles`: each
    /// agent's role, by its name (`AgentNames.roles`), the hub's newest reading's by default.
    public static func join(_ pieces: [CardNames.Piece], roles: [String: String] = AgentNames.shared.roles)
        -> [CardNames.Piece] {
        var joined: [CardNames.Piece] = [], index = 0
        while index < pieces.count {
            if let one = one(at: index, in: pieces, roles: roles) {
                joined += one.pieces
                index += one.taken
            } else {
                joined.append(pieces[index])
                index += 1
            }
        }
        return joined
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

    /// The piece that stays, where `first` and `second` are an agent's own name and its role, in either order: the
    /// name's, or the role's where the agent's label is not its name (a role that says the name, "Fleet Manager").
    private static func kept(_ first: CardNames.Piece, _ second: CardNames.Piece, roles: [String: String])
        -> CardNames.Piece? {
        guard case .agent(let agent)? = first.badge, second.badge == first.badge else { return nil }
        let name = agent.capitalized, one = String(first.words.characters), two = String(second.words.characters)
        guard one != two, one == name || two == name else { return nil }
        let byName = AgentNames.label(agent, roles: roles) == name
        return (one == name) == byName ? first : second
    }
}
