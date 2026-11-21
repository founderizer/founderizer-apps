import Foundation

/// **A name beside its own role is one badge, with the role** (the owner, 21 November 2026, of a card that drew an
/// agent's name and its role as two badges: "it should be the same, right? or show it only once!", and his "Yes, as
/// drawn"): on a request's card, "Nova (Customer Support Lead)" is one badge "Customer Support Lead", and so are
/// "Customer Support Lead (Nova)", "Nova, Customer Support Lead" and the two with " - ", " – " or " — " between them.
/// It is the card's alone: a chat's message keeps every character that its writer wrote (`ChatNames`), so
/// `CardNames.pieces` stays as it is, and the card joins its pieces after it (`CardBadgeText.text`,
/// `CardValues.values`).
///
/// Two pieces join when both are badges of one agent, one is the agent's own name with a capital (as `CardNames` finds
/// it) and the other has other words (its role, or a start of it that the book holds), and the words between them are
/// exactly " (" with ")" right after the second, ", ", " - ", " – " or " — ". **This is the one exception to the rule
/// of `CardNames.pieces` that every character stays:** the name, the words between them and the bracket's ")" go, and
/// the role's piece stays as the text wrote it, with its link. Every other character stays, in its order. A name and
/// its role with other words between them, and the names of two agents, stay two badges.
public enum CardJoin {
    /// The words between a name and its role, but the bracket's (" (", which ")" after the second closes).
    static let between: Set<String> = [", ", " - ", " – ", " — "]

    /// `pieces` (`CardNames.pieces`) with each name and its role beside it as one piece: the role's.
    public static func join(_ pieces: [CardNames.Piece]) -> [CardNames.Piece] {
        var joined: [CardNames.Piece] = [], index = 0
        while index < pieces.count {
            if let one = one(at: index, in: pieces) {
                joined += one.pieces
                index += one.taken
            } else {
                joined.append(pieces[index])
                index += 1
            }
        }
        return joined
    }

    /// The name and the role that begin at `index` as the role's one piece, with the words after a bracket's ")", and
    /// how many pieces they take; nil where the pieces there are no name and its role.
    private static func one(at index: Int, in pieces: [CardNames.Piece]) -> (pieces: [CardNames.Piece], taken: Int)? {
        guard index + 2 < pieces.count, pieces[index + 1].badge == nil,
              let role = role(pieces[index], pieces[index + 2]) else { return nil }
        let gap = String(pieces[index + 1].words.characters)
        guard gap == " (" else { return between.contains(gap) ? ([role], 3) : nil }
        guard index + 3 < pieces.count, pieces[index + 3].badge == nil,
              let close = pieces[index + 3].words.characters.first, close == ")" else { return nil }
        let words = pieces[index + 3].words
        let rest = AttributedString(words[words.characters.index(after: words.startIndex)...])
        return (rest.characters.isEmpty ? [role] : [role, CardNames.Piece(words: rest, badge: nil)], 4)
    }

    /// The piece of the role, where `first` and `second` are an agent's own name and its role, in either order.
    private static func role(_ first: CardNames.Piece, _ second: CardNames.Piece) -> CardNames.Piece? {
        guard case .agent(let agent)? = first.badge, second.badge == first.badge else { return nil }
        let name = agent.capitalized, one = String(first.words.characters), two = String(second.words.characters)
        guard one != two else { return nil }
        return one == name ? second : two == name ? first : nil
    }
}
