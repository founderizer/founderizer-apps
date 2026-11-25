import Foundation

/// **An agent that words name by its whole role shows by its name** (the owner, 23 November 2026: "We should ALWAYS use
/// the name. If we can additionally use the role, fine, but we need to address agents by their name!"; F23, piece N1,
/// his answer of that day: "The name with the role in grey"). In a card's words and in an agent's chat message, a badge
/// whose words are an agent's whole role draws the agent's label in their place (`AgentNames.label`), then a middle dot
/// and the role, which a drawer draws muted (`RolePart`): "Wren · Marketing" for the role "Marketing". A role that holds
/// the name stays as it is ("Fleet Manager"). The badge keeps its agent, its link and its marks, and "'s" after it stays
/// ("Wren · Marketing's plan"). Only the drawing changes: the hub keeps the words as their writer wrote them, and a copy
/// of the words and VoiceOver take what shows.
///
/// A run changes only where the chat's stricter rules find it (`ChatNames`), because a wrong badge must never also
/// change the words: an agent's whole role, and a role of one word only right after a word on its line ("I asked
/// Marketing"). **A run that can be no agent, or that speaks of the role itself, keeps its words** as written:
/// - a start of a role ("Customer Support" of "Customer Support Lead"), and a role of one word at a line's start or
///   after a mark ("Marketing spend rose 10%");
/// - a role that starts with a small letter, which is a word of the language ("I need support");
/// - a role of one word after an article or a determiner, which is a common noun there ("the Marketing budget", "our
///   sales", "el Marketing"); a role of several words after one is its agent ("the Customer Support Lead"), but not
///   after "a", "an", "un" or "una", which speak of another person of that role ("hire a Customer Support Lead");
/// - a role after the word "role" or "title" ("the role Customer Support Lead", "el rol Marketing");
/// - a role in a longer title, after a word with a capital and "of", "de" or "del" ("Head of Marketing", "VP of
///   Sales", "Head of Customer Success", "Jefe de Ventas"); "la campaña de Marketing" is no title, and names the agent;
/// - a role in quotation marks, or with an apostrophe alone after it ("'Customer Support Lead'", "Sales' report");
/// - **a role in one sentence with its agent's own name**: that is the role in addition to the name ("Nova is Customer
///   Support Lead", "Nova (Customer Support Lead, EU)"), and "Nova is Nova" says nothing.
/// A role that two agents hold names neither (`CardNames`), so no rule here picks one of two. **The owner's own words
/// stay as he wrote them** (`Written`), his tags too.
public enum RoleNames {
    /// **The part of a badge's words that is the role**, " · Marketing" of "Wren · Marketing", which a drawer draws
    /// muted, as the line of an agent's name does (`AgentNameLine` in the Mac app).
    public enum RolePart: AttributedStringKey {
        public typealias Value = Bool
        public static let name = "FleetCore.RoleNames.RolePart"
    }

    /// **Words that the owner wrote himself**, which keep a role as he wrote it: his bubble in a chat
    /// (`MessageText.asWritten`).
    public enum Written: AttributedStringKey {
        public typealias Value = Bool
        public static let name = "FleetCore.RoleNames.Written"
    }

    /// `text` as the owner's own words (`Written`).
    public static func written(_ text: AttributedString) -> AttributedString {
        var text = text, mark = AttributeContainer()
        mark[Written.self] = true
        text.mergeAttributes(mark)
        return text
    }

    /// `words` hold words that the owner wrote himself (`Written`).
    static func isWritten(_ words: AttributedString) -> Bool {
        words.runs[Written.self].contains { $0.0 == true }
    }

    /// **`pieces` of a card's or a chat's words, one for one, each whole role that the chat's rules find drawn as its
    /// agent's label and its role**: `CardNames.pieces`, or a chat's own pieces (`ChatNames.pieces`), whose "@Marketing"
    /// of an agent's reply is "@Wren · Marketing". `roles`: each agent's role, by its name (`AgentNames.roles`).
    public static func named(_ pieces: [CardNames.Piece], roles: [String: String]) -> [CardNames.Piece] {
        // most words name no agent by its role
        guard pieces.contains(where: { label(of: $0, roles: roles) != nil }) else { return pieces }
        var line = ""       // the words of the line before each piece
        return pieces.indices.map { index in
            let piece = pieces[index], words = String(piece.words.characters)
            defer { line = String((line + words).split(separator: "\n", omittingEmptySubsequences: false).last ?? "") }
            let next = index + 1 < pieces.count ? String(pieces[index + 1].words.characters) : ""
            guard let named = label(of: piece, roles: roles), namesTheAgent(words, after: line, before: next),
                  !itsNameIsInTheSentence(of: index, in: pieces) else { return piece }
            return named
        }
    }

    /// **`text` as a card draws its words, with no badge and no badge's link** (`CardJoin.join` of the pieces of
    /// `names`): each whole role that the chat's rules find is "Wren · Marketing", the role with its mark (`RolePart`),
    /// and a name with its role beside it is the name. For a drawer that draws a card's words plain; the shared vectors
    /// (`vectors/swift-words.json`) hold its words for the apps that draw them so.
    public static func words(_ text: AttributedString, names: CardNames,
                             roles: [String: String] = AgentNames.shared.roles) -> AttributedString {
        CardJoin.join(names.pieces(text), roles: roles).reduce(into: AttributedString()) { drawn, piece in
            var words = piece.words
            if piece.badge != nil { words.link = nil }
            drawn += words
        }
    }

    /// The piece with its agent's label and its role in place of its words, where its words are the agent's whole role,
    /// or "@" and the role: both take the marks of the role's first character, its link too, and the "@" stays. nil
    /// where the piece is no badge of an agent, where its words are no whole role of its agent or are the owner's own
    /// (`Written`), where the role starts with a small letter, and where the label is the role.
    private static func label(of piece: CardNames.Piece, roles: [String: String]) -> CardNames.Piece? {
        guard case .agent(let agent)? = piece.badge, let role = roles[agent], role.first?.isLowercase == false
        else { return nil }
        let label = AgentNames.label(agent, roles: roles), words = piece.words
        let start = words.characters.first == "@" ? words.characters.index(after: words.startIndex) : words.startIndex
        guard label != role, String(words[start...].characters) == role, !isWritten(words) else { return nil }
        let marks = words[start...].runs.first?.attributes ?? AttributeContainer()
        var part = AttributedString(" · \(role)", attributes: marks)
        part[RolePart.self] = true
        return CardNames.Piece(words: AttributedString(words[..<start]) + AttributedString(label, attributes: marks) + part,
                               badge: piece.badge)
    }

    /// The articles and the determiners of English and Spanish: before a role of one word, the word is a common noun.
    private static let articles: Set<String> = [
        "the", "a", "an", "our", "your", "their", "my", "his", "her", "its", "this", "that", "these", "those",
        "el", "la", "los", "las", "un", "una", "unos", "unas", "nuestro", "nuestra", "nuestros", "nuestras",
        "su", "sus", "tu", "tus", "mi", "mis", "este", "esta", "estos", "estas", "ese", "esa", "esos", "esas"]
    /// The articles that speak of another person of a role, before a role of any length ("hire a Customer Support Lead").
    private static let another: Set<String> = ["a", "an", "un", "una", "unos", "unas"]
    /// The words that speak of a role, before it.
    private static let roleWords: Set<String> = ["role", "title", "rol", "título"]
    /// A quotation mark that opens, right before a role, and one that closes, right after it, or an apostrophe alone.
    private static let opening: Set<Character> = ["'", "‘", "\"", "“", "«"]
    private static let closing: Set<Character> = ["'", "’", "\"", "”", "»"]

    /// **The run `words` of a role names its agent where it stands**, between `line` (the words of its line before it)
    /// and `next` (the words after it): the rules of the type's comment, but the one of the same sentence.
    private static func namesTheAgent(_ words: String, after line: String, before next: String) -> Bool {
        let several = words.contains(" ")
        // a role of one word only after a word or a chat's "@", as a chat counts it
        guard several || words.hasPrefix("@") || ChatNames.followsAWord(line) else { return false }
        if let mark = line.last, opening.contains(mark) { return false }
        if let mark = next.first, closing.contains(mark), next.dropFirst().first?.isLetter != true { return false }
        let before = lastWords(of: line)
        if let last = before.last?.lowercased(),
           roleWords.contains(last) || another.contains(last) || (!several && articles.contains(last)) {
            return false
        }
        // "Head of Marketing", "Head of Customer Success", "Jefe de Ventas"
        if before.count == 2, ["of", "de", "del"].contains(before[1].lowercased()),
           before[0].first?.isUppercase == true { return false }
        return true
    }

    /// The last two words of `line`, in their order, with only spaces between them and after them: the words right
    /// before a role. None where a mark stands there.
    private static func lastWords(of line: String) -> [String] {
        var words: [String] = [], rest = Substring(line)
        while words.count < 2 {
            let trimmed = rest.reversed().drop(while: { $0 == " " })
            let word = String(trimmed.prefix(while: \.isLetter).reversed())
            guard !word.isEmpty else { break }
            words.insert(word, at: 0)
            rest = rest.prefix(trimmed.count - word.count)
        }
        return words
    }

    /// The own name of the agent of the piece at `index` is a badge of the same sentence, before it or after it.
    private static func itsNameIsInTheSentence(of index: Int, in pieces: [CardNames.Piece]) -> Bool {
        guard case .agent(let agent)? = pieces[index].badge else { return false }
        let name = agent.capitalized
        return [Array(pieces[..<index].reversed()), Array(pieces[(index + 1)...])].contains { side in
            for piece in side {
                let words = String(piece.words.characters)
                if piece.badge == .agent(agent), words == name || words == "@" + name { return true }
                if piece.badge == nil, endsASentence(words) { return false }
            }
            return false
        }
    }

    /// A sentence or a line ends in `words`: a line break, or ".", "!", "?" or "…" before a space or at their end.
    private static func endsASentence(_ words: String) -> Bool {
        let characters = Array(words)
        return characters.indices.contains { index in
            characters[index].isNewline
                || ".!?…".contains(characters[index])
                && (index + 1 == characters.count || characters[index + 1].isWhitespace)
        }
    }
}
