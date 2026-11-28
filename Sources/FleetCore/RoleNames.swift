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

    /// **Words that keep a role and a name as they were written**: the owner's own words, his bubble in a chat
    /// (`MessageText.asWritten`), and a quote in a chat's message, which holds somebody's exact words.
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

    /// **In an agent's words in a chat, a badge of an agent's name draws its role beside it** (`ChatNames.pieces`; the
    /// owner, 25 November 2026, of a chat's message whose badge was "Iris" alone: "I think we agreed that we should show
    /// both agent name and role? like in a nice card badge?"): "Iris" is "Iris · SEO & AI Search", with the role marked
    /// (`RolePart`), which a drawer draws muted, as a badge of a whole role draws it (`named`), and "'s" stays after the
    /// badge ("Leo · Web Lead's team", as "Wren · Marketing's plan"). `pieces`: the pieces of one block of a chat's
    /// message, after `named`. **The name, the middle dot and the role's first word are joined by no-break spaces**, in
    /// a badge of a whole role too (`joined`): a line breaks in the role or after the badge, and never leaves a name at a
    /// line's end and its role alone on the next (a review of 26 November 2026).
    ///
    /// **An agent's role shows once in a message** (the owner, 21 November 2026: "show it only once!"; reviews of 26
    /// November 2026): `before` are the agents whose role an earlier block of the message shows, and the result's
    /// `shown` are those and the agents whose role this block shows, for the next block. A badge of an agent's whole role
    /// after its role showed is the agent's name alone ("I asked Marketing and then told Marketing": "Kai · Marketing",
    /// then "Kai"). **A badge of a name keeps its words**:
    /// - in the owner's own words and in a quote of a message (`Written`): they keep what their writer wrote;
    /// - **inside quotation marks**, a pair of them in the block (`quotations`), which hold somebody's exact words ("The
    ///   customer wrote: "then Leo promised a refund"" keeps "Leo"), as a role in quotation marks keeps its words
    ///   (`namesTheAgent`); a mark with no partner (the inch mark of 27") is no quotation;
    /// - for an agent with no role beside its label (`AgentNames.role`): no role, or a role that says the name ("Fleet
    ///   Manager" of the manager);
    /// - **where the name can be a person of the fleet's** (`people`, the words of each name of the people that the
    ///   owner added, of their handles and of his own, as `folded` gives them): all the agent's words, in their order,
    ///   in one person's words ("Mia" in "Mia Example"; "Web-Dev" not in "Dev Example"). "Mia asked for a refund" can
    ///   speak of a customer Mia, and "Mia · Web Developer" would say a false thing; a wrong badge must never also change
    ///   the words (a review of 26 November 2026);
    /// - **where the message shows the agent's role elsewhere**: in an earlier block, or anywhere in this one, before
    ///   or after the name: its role written beside one of its names, behind a bracket, a comma, a dash, a colon or a
    ///   middle dot, either way round ("Nova (Customer Support Lead)", "Marketing: Wren wrote it"), a badge of its role's
    ///   words ("Nova is Customer Support Lead") or a badge of its whole role ("Kai wrote it. Then I asked Marketing":
    ///   "Kai · Marketing" there, so "Kai" stays alone);
    /// - where an earlier name of the agent has its role: only the first one has it.
    ///
    /// A badge of a whole role inside quotation marks keeps the words as written ("Marketing"), and one after the block
    /// wrote the role beside a name of the agent is the name alone ("Kai (Marketing) wrote it. Then I asked Marketing").
    /// `folds`: each agent's name as `folded` gives it, made once by the book; one that it lacks is folded here.
    public static func withRoles(_ pieces: [CardNames.Piece], roles: [String: String], people: [[String]] = [],
                                 folds: [String: [String]] = [:], before: Set<String> = [])
        -> (pieces: [CardNames.Piece], shown: Set<String>) {
        // most words name no agent that has a role
        guard pieces.contains(where: { piece in
            guard case .agent(let agent)? = piece.badge else { return false }
            return AgentNames.role(agent, roles: roles) != nil
        }) else { return (pieces, before) }
        // the agents whose role the block writes as written: a badge of its role's words, or its role written beside one
        // of its names; with the badges of a whole role and the earlier blocks', the agents whose role the message shows
        var written: Set<String> = [], shown = before
        for index in pieces.indices {
            guard case .agent(let agent)? = pieces[index].badge else { continue }
            let words = String(pieces[index].words.characters), name = agent.capitalized
            if pieces[index].words.runs[RolePart.self].contains(where: { $0.0 == true }) {
                shown.insert(agent)
            } else if words != name, words != "@" + name {
                written.insert(agent)
            } else if let role = AgentNames.role(agent, roles: roles),
                      beside(role, before: index > 0 ? String(pieces[index - 1].words.characters) : "",
                             after: index + 1 < pieces.count ? String(pieces[index + 1].words.characters) : "") {
                written.insert(agent)
            }
        }
        shown.formUnion(written)
        var given = before          // the agents whose role a badge of the message showed so far
        func roled(_ piece: CardNames.Piece, quoted: Bool) -> CardNames.Piece {
            guard case .agent(let agent)? = piece.badge else { return piece }
            // a badge of a whole role: as written inside quotation marks; its role joined to its name, once, where the
            // block does not write it; else the name alone
            if piece.words.runs[RolePart.self].contains(where: { $0.0 == true }) {
                if quoted { return CardNames.Piece(words: asWritten(piece.words), badge: piece.badge) }
                guard !written.contains(agent), given.insert(agent).inserted else {
                    return CardNames.Piece(words: nameAlone(piece.words), badge: piece.badge)
                }
                return CardNames.Piece(words: joined(piece.words), badge: piece.badge)
            }
            guard let role = AgentNames.role(agent, roles: roles), !isWritten(piece.words), !quoted,
                  !shown.contains(agent), !given.contains(agent) else { return piece }
            let words = String(piece.words.characters), name = agent.capitalized
            // a person of the fleet's can have the name
            guard words == name || words == "@" + name,
                  people.isEmpty || !people.contains(where: { holds($0, folds[agent] ?? folded(agent)) })
            else { return piece }
            given.insert(agent)
            var part = AttributedString(" · \(role)", attributes: piece.words.runs.last?.attributes ?? AttributeContainer())
            part[RolePart.self] = true
            return CardNames.Piece(words: joined(piece.words + part), badge: piece.badge)
        }
        // the quotations of the block, each a pair of marks; a piece inside one is somebody's exact words
        let quotes = quotations(pieces.flatMap { Array($0.words.characters) })
        var out: [CardNames.Piece] = [], offset = 0
        for piece in pieces {
            out.append(roled(piece, quoted: quotes.contains { $0.contains(offset) }))
            offset += piece.words.characters.count
        }
        return (out, shown.union(given))
    }

    /// `words` hold `name`'s words, all of them, in their order and one after the other.
    static func holds(_ words: [String], _ name: [String]) -> Bool {
        guard !name.isEmpty, name.count <= words.count else { return false }
        return (0...(words.count - name.count)).contains { Array(words[$0..<($0 + name.count)]) == name }
    }

    /// **The quotations of `characters`**, each from its opening mark to its closing one, in characters: a double mark
    /// opens where none is open and closes the one that is (" “ ” « »: English “…”, French «…», German „…“ and »…«,
    /// Swedish ”…”), and „ only opens. A mark with no partner is no quotation: the inch mark of 27", a lone » in
    /// "Settings » People" (a review of 27 November 2026). An apostrophe is no mark: it is also "'s".
    private static func quotations(_ characters: [Character]) -> [Range<Int>] {
        var found: [Range<Int>] = [], open: Int?
        for (index, character) in characters.enumerated() {
            switch character {
            case "\"", "\u{201C}", "\u{201D}", "\u{00AB}", "\u{00BB}":
                if let start = open { found.append(start..<index + 1); open = nil } else { open = index }
            case "\u{201E}":
                if open == nil { open = index }
            default: break
            }
        }
        return found
    }

    /// The words of a badge of a whole role as written: "@" where they began with it, and the role, with no name and no
    /// role's mark.
    private static func asWritten(_ words: AttributedString) -> AttributedString {
        guard let range = words.runs[RolePart.self].first(where: { $0.0 == true })?.1 else { return words }
        var role = AttributedString(words[range])
        role[RolePart.self] = nil
        // the part is " · role", its spaces joined or not
        role.characters.removeFirst(min(3, role.characters.count))
        guard words.characters.first == "@" else { return role }
        return AttributedString(words[words.startIndex..<words.characters.index(after: words.startIndex)]) + role
    }

    /// The words of a badge of a whole role with no role: its name, the agent's label.
    private static func nameAlone(_ words: AttributedString) -> AttributedString {
        var words = words
        for (mark, range) in words.runs[RolePart.self].reversed() where mark == true { words.removeSubrange(range) }
        return words
    }

    /// **The words of a name as `withRoles` matches a person's**: in small letters and in Latin letters with no accents
    /// (ø, ł, æ and ß too: "Bjørn" is "bjorn", "Weiß" is "weiss"), at each character that is no letter and no digit, so
    /// "Zoë Example" holds the agent `zoe` ("Zoe").
    public static func folded(_ name: String) -> [String] {
        let latin = name.applyingTransform(StringTransform("Latin-ASCII"), reverse: false) ?? name
        return latin.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// `words` of a badge with its role (`RolePart`, " · Marketing") with the spaces before and after the middle dot
    /// as no-break spaces, so that the name, the dot and the role's first word stay on one line.
    static func joined(_ words: AttributedString) -> AttributedString {
        guard let range = words.runs[RolePart.self].first(where: { $0.0 == true })?.1 else { return words }
        var words = words
        let start = words.characters.distance(from: words.startIndex, to: range.lowerBound)
        let characters = Array(words.characters)
        guard start + 2 < characters.count, characters[start] == " ", characters[start + 1] == "·",
              characters[start + 2] == " " else { return words }
        for offset in [start, start + 2] {
            let at = words.characters.index(words.startIndex, offsetBy: offset)
            words.characters.replaceSubrange(at...at, with: "\u{00A0}")
        }
        return words
    }

    /// `role` stands right beside a name: at the start of the words after it (`after`) or at the end of the words
    /// before it (`before`), with only a bracket, a comma, a dash, a colon or a middle dot and spaces between, in any
    /// capitals. A role of one word there is words, and no badge (`ChatNames`), so only the words say it.
    private static func beside(_ role: String, before: String, after: String) -> Bool {
        let marks: Set<Character> = ["(", ",", "-", "–", "—", ":", "·"]
        func behindAMark(_ words: [Character], _ role: [Character]) -> Bool {
            var rest = words.drop(while: \.isWhitespace)
            guard let mark = rest.first, marks.contains(mark) else { return false }
            rest = rest.dropFirst().drop(while: \.isWhitespace)
            guard rest.count >= role.count,
                  String(rest.prefix(role.count)).caseInsensitiveCompare(String(role)) == .orderedSame else { return false }
            // the whole role: no letter or digit goes on after it
            return rest.dropFirst(role.count).first.map { !$0.isLetter && !$0.isNumber } ?? true
        }
        return behindAMark(Array(after), Array(role)) || behindAMark(Array(before.reversed()), Array(role.reversed()))
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
