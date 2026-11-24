import Foundation
import Synchronization

/// **The names in a chat's message are badges, as on a request's card** (the owner, 20 November 2026: "ok but use always
/// the agent badges and icons!!", and "Yes, as drawn" to the third mock-up of a chat), **by stricter rules than a
/// card's**: an agent's reply and the owner's own bubble are free words, where the card's rules found wrong names (a
/// review of 21 November 2026): a role of one word in "Marketing spend rose 10%", the unique start of a role in "SEO &
/// content updates", the server "m4" in "M4 Mac mini", and the Agents page and the Help page of another product. A
/// wrong badge is worse than none, so a chat counts only:
/// - an agent's name with a capital, as a card does (`CardNames`: no word with a capital beside it), and its whole role
///   ("Customer Support Lead"), never the start of a role; a role of one word only right after a word on its line
///   ("I asked Marketing", "goes to Sales"), never after a sentence's end, a quote, a bracket, a colon, a digit, a mark
///   or at a line's start ("Marketing spend rose 10%", "(1) Sales grew 5%"): on real messages of one fleet the role
///   "Marketing" named its agent often, and every wrong one of the reviews stood so;
/// - a server or a repository as it is written, in its own capitals ("app-1", "acme/web"), and never in inline code;
/// - a knowledge file by its path, as a card does;
/// - a secret of the fleet's by its name, as a card does (`CardNames`: word for word, in words only when it has a
///   character that is no letter and no space, and a name of letters only only as the whole of an inline code; the
///   owner, 21 November 2026: "task cards in both agents chat and needs you sohuld also have a badge for specific
///   Credentials", and "Yes, both");
/// - no page of the app.
/// A possessive keeps the name as the badge and "'s" as words after it ("Mia's duty"). **An agent's whole role right
/// beside its own name is no second badge** (the owner, 21 November 2026, of a card that drew an agent's name and its
/// role as two badges: "it should be the same, right? or show it only once!"): in "Nova (Customer Support Lead)",
/// "Nova, Customer Support Lead" or "Nova - Customer Support Lead", and with the two the other way round, the name is
/// the badge and the role stays words. The words stay as written, every one in its order.
public struct ChatNames: Equatable, Sendable {
    /// The card's book of the same names.
    private let book: CardNames
    /// What names an agent in a chat: its name with a capital and its whole role.
    private let agentWords: Set<String>
    /// The roles of one word that are no agent's name, which count only after a word (`followsAWord`).
    private let oneWord: Set<String>
    /// Each agent's name with a capital, by its name.
    private let named: [String: String]
    /// **The words of each text that this book read** (`words(_:)`): a chat draws its rows again at each reading of the
    /// hub, and it found every name of every block again at each (a review of 21 November 2026: 1,000 reads for 500
    /// blocks). A new book reads anew, unless it holds the same names (`FleetStore.chatNames`); one of many thousand
    /// texts starts again empty.
    let read = Read()

    final class Read: Sendable {
        let words = Mutex<[AttributedString: ChatWords]>([:])
    }

    /// Two books are equal when they are one, or when they hold the same names: what they read is no part of them.
    public static func == (lhs: ChatNames, rhs: ChatNames) -> Bool {
        lhs.read === rhs.read || (lhs.book == rhs.book && lhs.agentWords == rhs.agentWords && lhs.written == rhs.written
                                  && lhs.named == rhs.named && lhs.oneWord == rhs.oneWord)
    }
    /// The servers and the repositories as they are written: a repository's owner/name and its name alone.
    private let written: Set<String>

    /// The same names as the card's book (`CardNames.init`).
    public init(agents: [(name: String, role: String?)], repositories: [String] = [], servers: [String] = [],
                knowledge: [String] = [], secrets: [(name: String, key: Bool)] = []) {
        let agents = agents.map { agent in
            (name: agent.name, role: agent.role.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
                .flatMap { $0.isEmpty ? nil : $0 })
        }
        book = CardNames(agents: agents, repositories: repositories, servers: servers, knowledge: knowledge,
                         secrets: secrets)
        agentWords = Set(agents.map { $0.name.capitalized } + agents.compactMap(\.role))
        oneWord = Set(agents.compactMap(\.role).filter { !$0.contains(" ") })
            .subtracting(agents.map { $0.name.capitalized })
        named = Dictionary(agents.map { ($0.name, $0.name.capitalized) }, uniquingKeysWith: { first, _ in first })
        written = Set(servers + repositories + repositories.compactMap { $0.split(separator: "/").last.map(String.init) })
    }

    /// **`text` in pieces, each name that it shows by the chat's rules a piece of its own with its link**, which a chat
    /// draws as a badge with its icon. The pieces hold every character of `text` once, in its order; a name that the
    /// card's rules find and the chat's do not stays words, with no link.
    ///
    /// **@ tags** (owner feature `agent_tags`; his "Yes, as drawn": "in a sent message the tag is the chat's agent
    /// badge"): words that carry `AgentTags.Tagged` are a tag of his message, which is its agent's badge over the whole
    /// tag, "@" included, and wins over a name that the book finds inside it; a tag of an agent that the book does not
    /// know is plain words. **An agent's name or role right after an "@" that starts a tag** (an agent's reply, his own
    /// words with no tag) is found as after a space, counts as after a word, and its badge takes the "@" too; any other
    /// name after such an "@" stays words, as it was.
    ///
    /// **In his words whose tags the hub gave** (`AgentTags.Given`), only an entry is a tag: an "@" before a name
    /// outside them stays words, as an email does.
    public func pieces(_ text: AttributedString) -> [CardNames.Piece] {
        let given = text.runs[AgentTags.Given.self].contains { $0.0 == true }
        let read = given ? (text: text, after: Set<Int>()) : Self.reading(text)
        let names = book.pieces(read.text, codedRepositories: false)
        let found = read.after.isEmpty ? names : Self.restored(names, in: text, at: read.after)
        var pieces: [CardNames.Piece] = [], line = "", offset = 0     // the words of the line before each piece, its place
        for (index, piece) in found.enumerated() {
            var shown = piece
            let words = String(piece.words.characters)
            let afterAt = read.after.contains(offset)
            defer {
                line = String((line + words).split(separator: "\n", omittingEmptySubsequences: false).last ?? "")
                offset += piece.words.characters.count
            }
            if let target = piece.badge, !counts(target, words: words) || besideItsName(index, in: found)
                || (afterAt && !target.isAgent) || (oneWord.contains(words) && !afterAt && !Self.followsAWord(line)) {
                var words = piece.words
                words.link = nil        // the link that the card's book gave the name: no other link stands in a name
                shown = CardNames.Piece(words: words, badge: nil)
            }
            if afterAt, let target = shown.badge, let last = pieces.last, last.badge == nil, last.words.characters.last == "@" {
                // the "@" goes into the badge, with the name's link
                let at = last.words.characters.index(before: last.words.endIndex)
                var words = AttributedString(last.words[at...]) + shown.words
                words.link = target.url
                shown = CardNames.Piece(words: words, badge: target)
                let before = AttributedString(last.words[..<at])
                if before.characters.isEmpty { pieces.removeLast() } else {
                    pieces[pieces.count - 1] = CardNames.Piece(words: before, badge: nil)
                }
            }
            if shown.badge == nil, let last = pieces.last, last.badge == nil {
                pieces[pieces.count - 1] = CardNames.Piece(words: last.words + shown.words, badge: nil)
            } else {
                pieces.append(shown)
            }
        }
        let tags = text.runs[AgentTags.Tagged.self].compactMap { agent, range -> (range: Range<Int>, agent: String)? in
            guard let agent else { return nil }
            let start = text.characters.distance(from: text.startIndex, to: range.lowerBound)
            return (start..<start + text.characters.distance(from: range.lowerBound, to: range.upperBound), agent)
        }
        return tags.isEmpty ? pieces : tagged(pieces, tags: tags, in: text)
    }

    /// **The pieces with each tag of his message as its own**: its agent's badge where the book knows the agent, else
    /// plain words; a piece that a tag cuts keeps its words outside the tag, as plain words.
    private func tagged(_ pieces: [CardNames.Piece], tags: [(range: Range<Int>, agent: String)],
                        in text: AttributedString) -> [CardNames.Piece] {
        var out: [CardNames.Piece] = []
        func add(_ piece: CardNames.Piece) {
            if piece.badge == nil, let last = out.last, last.badge == nil {
                out[out.count - 1] = CardNames.Piece(words: last.words + piece.words, badge: nil)
            } else {
                out.append(piece)
            }
        }
        func words(_ range: Range<Int>) -> AttributedString {
            let start = text.characters.index(text.startIndex, offsetBy: range.lowerBound)
            return AttributedString(text[start..<text.characters.index(start, offsetBy: range.count)])
        }
        var at = 0
        for piece in pieces {
            let span = at..<(at + piece.words.characters.count)
            var cursor = span.lowerBound
            for tag in tags where tag.range.overlaps(span) {
                if cursor < tag.range.lowerBound {
                    let part = cursor..<tag.range.lowerBound
                    add(part == span ? piece : CardNames.Piece(words: { var w = words(part); w.link = nil; return w }(), badge: nil))
                }
                if span.contains(tag.range.lowerBound) {
                    var tagWords = words(tag.range)
                    if named[tag.agent] != nil {
                        let target = CardNames.Target.agent(tag.agent)
                        tagWords.link = target.url
                        add(CardNames.Piece(words: tagWords, badge: target))
                    } else {
                        add(CardNames.Piece(words: tagWords, badge: nil))
                    }
                }
                cursor = max(cursor, min(tag.range.upperBound, span.upperBound))
            }
            if cursor < span.upperBound {
                let part = cursor..<span.upperBound
                add(part == span ? piece : CardNames.Piece(words: { var w = words(part); w.link = nil; return w }(), badge: nil))
            }
            at = span.upperBound
        }
        return out
    }

    /// **The words as the book reads them, where an "@" starts a tag before a name**: that "@" as a space, so that the
    /// book finds the name after it (a name stands only between two word boundaries, and an "@" before a letter joins
    /// it to the word before, as in an email), and the places of the characters right after each such "@". The "@"
    /// starts a tag as in the hub's reading: at the start, after whitespace or after one of `( [ { " '`.
    private static func reading(_ text: AttributedString) -> (text: AttributedString, after: Set<Int>) {
        // most words have no "@": they cost one look at their scalars, and no copy
        guard text.unicodeScalars.contains("@") else { return (text, []) }
        let characters = Array(text.characters)
        var read = text, after = Set<Int>()
        for (offset, character) in characters.enumerated() where character == "@" && offset + 1 < characters.count {
            let before = offset == 0 ? nil : characters[offset - 1]
            guard before.map({ $0.isWhitespace || "([{\"'".contains($0) }) ?? true,
                  characters[offset + 1].isLetter || characters[offset + 1].isNumber else { continue }
            let at = read.characters.index(read.startIndex, offsetBy: offset)
            let next = read.characters.index(after: at)
            let kept = read[at..<next].runs.first?.attributes ?? AttributeContainer()
            read.replaceSubrange(at..<next, with: AttributedString(" ", attributes: kept))
            after.insert(offset + 1)
        }
        return (read, after)
    }

    /// The book's pieces of the words that it read (`reading`), with `text`'s own characters: words as `text` holds
    /// them, "@" again, and a name as the book found it. A name over the place of such an "@" is words (none can be:
    /// a name has no space at its start).
    private static func restored(_ pieces: [CardNames.Piece], in text: AttributedString, at after: Set<Int>)
        -> [CardNames.Piece] {
        var start = text.startIndex, offset = 0
        return pieces.map { piece in
            let count = piece.words.characters.count
            let end = text.characters.index(start, offsetBy: count)
            defer { start = end; offset += count }
            if piece.badge != nil, !(offset..<offset + count).contains(where: { after.contains($0 + 1) }) { return piece }
            return CardNames.Piece(words: AttributedString(text[start..<end]), badge: nil)
        }
    }

    /// The piece at `index` is an agent's role, with that agent's own name beside it, before it or after it, and only a
    /// bracket, a comma or a dash between them ("Nova (Customer Support Lead)", "Customer Support Lead, Nova").
    private func besideItsName(_ index: Int, in pieces: [CardNames.Piece]) -> Bool {
        guard case .agent(let agent)? = pieces[index].badge, let name = named[agent],
              String(pieces[index].words.characters) != name else { return false }
        return [index - 2, index + 2].contains { other in
            guard pieces.indices.contains(other), pieces[other].badge == .agent(agent),
                  String(pieces[other].words.characters) == name, pieces[(index + other) / 2].badge == nil
            else { return false }
            let between = String(pieces[(index + other) / 2].words.characters).trimmingCharacters(in: .whitespaces)
            return ["(", ",", "-", "–", "—"].contains(between)
        }
    }

    /// The nearest character before a word, past spaces, on its line (`line`, the words of the line before it) is a
    /// letter: "asked Marketing", "to Sales". The text's or a line's start, punctuation, a quote, a bracket, a colon, a
    /// digit, an emoji or an arrow before it is no word.
    private static func followsAWord(_ line: String) -> Bool {
        line.last(where: { !$0.isWhitespace })?.isLetter == true
    }

    /// The name that the card's book found counts in a chat.
    private func counts(_ target: CardNames.Target, words: String) -> Bool {
        switch target {
        case .agent: agentWords.contains(words)
        case .server, .repository: written.contains(words)
        // the card's book finds a secret only word for word, and a name of letters only only as the whole of an inline
        // code: free words name no product's secret
        case .knowledge, .secret: true
        case .page: false
        }
    }
}

private extension CardNames.Target {
    var isAgent: Bool {
        if case .agent = self { return true }
        return false
    }
}

/// **One block of a chat's message as the chat draws it** (`ChatNames.words`): its words exactly as the message holds
/// them, which a copy of them holds too, and where each name's badge stands in them. A name keeps the room of its icon
/// on the character before it (a kern, which a copy does not hold). **A name that begins the words keeps it in the
/// words' own leading space** (`leads`), as the owner's drawing shows a glyph on each name ("ok but use always the
/// agent badges and icons!!"): a no-break space there went into every copy ("\u{00A0}mini-2 restarts", a review of 21
/// November 2026). A name that a line break of the words begins has neither, and its badge no icon.
public struct ChatWords: Equatable, Sendable {
    public struct Badge: Hashable, Sendable {
        /// Which badge of the words, in their order.
        public let index: Int
        public let target: CardNames.Target
        /// Where its name stands: in the words' characters, and in their UTF-16 units, as a text's layout counts them.
        public let characters: Range<Int>
        public let utf16: Range<Int>
        /// The character before the name, on its line, keeps the room of its icon.
        public let room: Bool
        /// That character in the words' UTF-16 units, all of them: a layout gives its glyph at only one of them (an
        /// emoji of several parts, a flag; a review of 21 November 2026). Empty where it keeps no room.
        public let before: Range<Int>
        /// The name begins the words, left to right, and the words have one line: the room of its icon is the words'
        /// own leading space, no character, which a chat gives them only where they lay out on one line in the width
        /// without it (`ChatBadgeText.led`): a block that wraps keeps the column and the width of the blocks around
        /// it. A name in a line written right to left, or in words with a line break, has none.
        public let leads: Bool
        /// The character whose kern is the end of its badge, where a kern adds room on a glyph's right: the name's last
        /// character, or its first in a script written right to left, whose last is on its left; in a line written right
        /// to left (its first letter is of such a script, as a layout finds a paragraph's direction), the character
        /// after it (`endAfter`).
        public let end: Int
        /// The end's kern is on the character after the name, whose glyph the layout puts beside the name, on the side
        /// where the badge ends: on its left in a line written right to left, on its right in a phrase left to right
        /// inside one (a review of 21 November 2026: in "שאלתי את Nova" the icon stood on the next word, and a name in
        /// Hebrew lost its last letter to the end's kern).
        public let endAfter: Bool
    }

    /// The words as written, each name with its link (`CardNames.Target.url`).
    public let text: AttributedString
    public let badges: [Badge]

    init(_ pieces: [CardNames.Piece]) {
        var text = AttributedString(), characters = 0, utf16 = 0
        var found: [(target: CardNames.Target, characters: Range<Int>, utf16: Range<Int>, before: Range<Int>?, starts: Bool,
                     rightToLeft: Bool)] = []
        var line = ""       // the words' line so far, up to its first letter
        for piece in pieces {
            let words = String(piece.words.characters)
            if let target = piece.badge {
                let before = text.characters.last.flatMap { $0.isNewline ? nil : utf16 - String($0).utf16.count..<utf16 }
                found.append((target, characters..<characters + words.count, utf16..<utf16 + words.utf16.count, before,
                              text.characters.isEmpty, Self.rightToLeft(line + words)))
            }
            for character in words {
                if character.isNewline { line = "" } else if !line.unicodeScalars.contains(where: \.properties.isAlphabetic) {
                    line.append(character)
                }
            }
            text += piece.words
            characters += words.count
            utf16 += words.utf16.count
        }
        self.text = text
        let all = found.isEmpty ? [] : Array(text.characters), oneLine = !all.contains(where: \.isNewline)
        badges = found.enumerated().map { index, name in
            let after = name.characters.upperBound < all.count && !all[name.characters.upperBound].isNewline
            let endAfter = name.rightToLeft && after
            let script = Self.rightToLeft(String(all[name.characters]))
            return Badge(index: index, target: name.target, characters: name.characters, utf16: name.utf16,
                         room: name.before != nil, before: name.before ?? name.utf16.lowerBound..<name.utf16.lowerBound,
                         leads: name.starts && !name.rightToLeft && oneLine,
                         end: endAfter ? name.characters.upperBound : script ? name.characters.lowerBound
                            : name.characters.upperBound - 1,
                         endAfter: endAfter)
        }
    }

    /// The first letter of `words` is of a script written right to left (Hebrew, Arabic and their kin).
    static func rightToLeft(_ words: String) -> Bool {
        guard let letter = words.unicodeScalars.first(where: { $0.properties.isAlphabetic }) else { return false }
        return [0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF].contains { $0.contains(Int(letter.value)) }
    }
}

extension ChatNames {
    /// **This book, or `old` where it holds the same names**, with what `old` read (a review of 21 November 2026: a book
    /// made again read all 500 blocks of a chat again, 118 ms with 300 repositories, also where only what the names were
    /// made of had changed: a repository's or a server's order, a server's symbol, a file that no message names).
    public func keeping(_ old: ChatNames?) -> ChatNames {
        guard let old, old == self else { return self }
        return old
    }

    /// **`text` as a chat draws it** (`ChatWords`), read once by this book (`read`).
    public func words(_ text: AttributedString) -> ChatWords {
        if let kept = read.words.withLock({ $0[text] }) { return kept }
        let words = ChatWords(pieces(text))
        read.words.withLock { read in
            if read.count >= 8_192 { read.removeAll(keepingCapacity: true) }
            read[text] = words
        }
        return words
    }
}
