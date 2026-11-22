import Foundation

/// **@ tags in a chat with an agent** (the owner, 20 November 2026: "@<agent-name> or @<agent-role> allows tagging an
/// agent"; to "What must a tag do?": "Name a helper"; "Yes, as drawn" to the list in the chat box; "Build tags now";
/// `~/dev/founderizer-plans/agent-tags-build-design-2026-11-21.md` 4.1). A tag is a range of his message that names one
/// other agent of the team: "@" and that agent's label. It moves nothing and copies nothing: the hub gives the chat's
/// agent one line with the route of each tagged agent (owner API 1.288, `mentions` of `POST /ui/messages`).
///
/// This type holds the rules of both apps' chat boxes, with no view: the rows of the list and their filter, the open
/// "@" before the caret, the words of a pick, the Backspace that takes a whole tag, and the tags of the words that he
/// sends. **Every caret, start and length is counted in Unicode scalars**, as the hub counts the characters of a
/// Python string (`String.unicodeScalars`): a count in characters or in UTF-16 units puts the hub's range on other
/// words after an emoji or an accent.
public struct AgentTags: Equatable, Sendable {
    /// One row of the list: an agent, and its label, which the row shows and a pick writes after "@".
    public struct Row: Equatable, Sendable, Identifiable {
        public let agent: String
        public let label: String
        public var id: String { agent }
    }

    /// One tag of his message as the hub takes it: the agent's name in team.json, and the range from the "@" to the
    /// last character of the label, in Unicode scalars.
    public struct Mention: Codable, Equatable, Hashable, Sendable {
        public let agent: String
        public let start: Int
        public let length: Int

        public init(agent: String, start: Int, length: Int) {
            self.agent = agent
            self.start = start
            self.length = length
        }
    }

    /// The box's words after an edit of this type, and the place of the caret in them, in Unicode scalars.
    public struct Edit: Equatable, Sendable {
        public let text: String
        public let caret: Int
    }

    /// The hub's feature name: the apps open the list and send `mentions` only when the hub has it.
    public static let feature = "agent_tags"
    /// The hub's limits of `mentions` (`MENTIONS_MAX`, `MENTION_LENGTH`): a longer list or a tag of more than 80
    /// scalars is a wrong shape, which the hub refuses with 400, and his message would not go.
    public static let most = 10
    public static let longest = 80
    /// How far back from the caret the list looks for its "@" (design 4.3).
    static let reach = 40
    /// The characters before an "@" where a tag starts, besides whitespace, and after its words where it ends, as the
    /// hub has them (`TAG_BEFORE`, `TAG_AFTER`).
    static let before: Set<Unicode.Scalar> = ["(", "[", "{", "\"", "'"]
    static let after: Set<Unicode.Scalar> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "\"", "'"]

    /// The rows of the list: every agent of the team but the chat's own, in the team's order.
    public let rows: [Row]
    /// The chat's own agent, which no tag names.
    private let except: String
    /// Each agent's role on single spaces, "" for none, by its name.
    private let roles: [String: String]
    /// Each agent's label, by its name.
    private let labels: [String: String]
    /// The roles of the team, for the tags of his words (rule 1 of the hub's reading).
    private let reading: [Role]
    /// The names of the team, the longest first, for rule 2.
    private let names: [[Unicode.Scalar]]

    /// One role of the team: its words, and the agents that hold it, without regard to case and spaces.
    private struct Role: Equatable, Sendable {
        let words: [[Unicode.Scalar]]
        let holders: [String]
        /// The role is also an agent's name: the name decides, as each label names one agent (`init`).
        let isAName: Bool
    }

    /// `agents`: the team, each agent's name and role (its `title`, nil for none), in its own order (the sidebar's);
    /// `except`: the chat's own agent, which is no row and no tag.
    ///
    /// **The label of each agent is the hub's** (`tag_label`, design 1.1): its role on single spaces, when no other
    /// agent has that role or that role as its name, without regard to case; else its name as the apps show it
    /// (`capitalized`, which is the hub's `shown_name`). So each label names one agent, as `CardNames` does: a role
    /// that two agents hold names neither.
    public init(agents: [(name: String, role: String?)], except: String) {
        var roles: [String: String] = [:], labels: [String: String] = [:]
        for agent in agents where roles[agent.name] == nil { roles[agent.name] = Self.spaced(agent.role ?? "") }
        // each agent's role and name as two of them compare, once
        let folded = agents.map { (name: $0.name, role: Self.fold($0.role ?? ""), said: Self.fold($0.name)) }
        let named = Set(folded.map(\.said))
        for agent in folded where labels[agent.name] == nil {
            let role = roles[agent.name] ?? ""
            let unique = !role.isEmpty && !folded.contains {
                $0.name != agent.name && ($0.role == agent.role || $0.said == agent.role)
            }
            labels[agent.name] = unique ? role : agent.name.capitalized
        }
        var grouped: [(said: String, role: String, holders: [String])] = []
        for agent in folded {
            guard let role = roles[agent.name], !role.isEmpty else { continue }
            let said = agent.role
            if let at = grouped.firstIndex(where: { $0.said == said }) {
                if !grouped[at].holders.contains(agent.name) { grouped[at].holders.append(agent.name) }
            } else {
                grouped.append((said, role, [agent.name]))
            }
        }
        self.roles = roles
        self.labels = labels
        self.except = except
        reading = grouped.map { group in
            Role(words: group.role.split(separator: " ").map { Array($0.unicodeScalars) }, holders: group.holders,
                 isAName: named.contains(group.said))
        }
        names = Set(agents.map(\.name)).sorted { $0.unicodeScalars.count != $1.unicodeScalars.count
            ? $0.unicodeScalars.count > $1.unicodeScalars.count : $0 < $1 }.map { Array($0.unicodeScalars) }
        var seen = Set<String>()
        rows = agents.filter { $0.name != except && seen.insert($0.name).inserted }
            .map { Row(agent: $0.name, label: labels[$0.name] ?? $0.name.capitalized) }
    }

    /// The label of an agent of the team: what its row shows and what a pick writes after "@".
    public func label(of agent: String) -> String? { labels[agent] }

    /// **The open "@" before the caret, and the letters between it and the caret** (design 4.3), or nil: the nearest
    /// "@" on the caret's line, at most 40 scalars back, that stands at the start of the words or after whitespace,
    /// where he approved the list. An "@" inside a word (an email) opens nothing.
    public func query(in text: String, caret: Int) -> (at: Int, letters: String)? {
        let scalars = Array(text.unicodeScalars)
        guard caret > 0, caret <= scalars.count else { return nil }
        var at = caret - 1
        while at >= max(0, caret - 1 - Self.reach) {
            let scalar = scalars[at]
            if Character(scalar).isNewline { return nil }
            if scalar == "@", at == 0 || scalars[at - 1].properties.isWhitespace {
                return (at, Self.string(scalars[(at + 1)..<caret]))
            }
            at -= 1
        }
        return nil
    }

    /// **The rows of the list for these letters, in the team's order** (design 4.3): every row for no letters; else
    /// each row whose role, from the start of one of its words, goes on as the letters do ("su" and "customer su" both
    /// find "Customer Support"), or whose name starts with them, without regard to case and accents. The order is the
    /// team's and not the best match first, so the rows do not jump while he types. Empty closes the list: it has no
    /// words for no match.
    public func rows(for letters: String) -> [Row] {
        guard !letters.isEmpty else { return rows }
        let wanted = Self.loose(letters)
        return rows.filter { row in
            Self.loose(row.agent).hasPrefix(wanted)
                || Self.wordStarts(of: roles[row.agent] ?? "").contains { Self.loose($0).hasPrefix(wanted) }
        }
    }

    /// **The words after a pick** (design 4.4): "@" and the letters before the caret become "@<label> ", and the caret
    /// stands after the space; a space that stood at the caret is that space. The words after the caret stay.
    public func pick(_ row: Row, in text: String, at: Int, caret: Int) -> Edit {
        let scalars = Array(text.unicodeScalars)
        let start = min(max(at, 0), scalars.count), end = min(max(caret, start), scalars.count)
        var rest = scalars[end...]
        if rest.first == " " { rest = rest.dropFirst() }
        let written = Array(scalars[..<start]) + Array("@\(row.label) ".unicodeScalars)
        return Edit(text: Self.string(written + rest), caret: written.count)
    }

    /// **One Backspace takes the whole tag** (his "Yes, as drawn": "one Backspace removes it"; design 4.4): when `new`
    /// is `old` without exactly one character, and that character was the last of a tag of `old` or the one space
    /// right after a tag, the words without that whole tag and its space, with the caret where its "@" stood. Nil for
    /// any other edit: an edit inside a tag makes it plain words, and a delete anywhere else stays a delete.
    ///
    /// `caret`: the box's caret after the delete, where the deleted character stood. **It says which character went
    /// where two of the same stand side by side**: after a tag with two spaces, a Backspace on the first one takes the
    /// tag, and one on the second takes a space; the words alone cannot tell the two apart. Without a caret that fits
    /// the edit, the first place where the words differ.
    public func afterDelete(old: String, new: String, caret: Int? = nil) -> Edit? {
        let was = Array(old.unicodeScalars), now = Array(new.unicodeScalars)
        guard now.count < was.count else { return nil }
        let gone = was.count - now.count
        func fits(_ at: Int) -> Bool {
            at >= 0 && at <= now.count && was[..<at].elementsEqual(now[..<at]) && was[(at + gone)...].elementsEqual(now[at...])
        }
        var at = 0
        if let caret, fits(caret) { at = caret } else {
            while at < now.count, was[at] == now[at] { at += 1 }
            guard fits(at) else { return nil }
        }
        guard Self.string(was[at..<(at + gone)]).count == 1 else { return nil }
        for tag in mentions(in: old) {
            let end = tag.start + tag.length
            let last = at > tag.start && at + gone == end
            let space = at == end && gone == 1 && was[at] == " "
            guard last || space else { continue }
            let cut = end < was.count && was[end] == " " ? end + 1 : end
            return Edit(text: Self.string(was[..<tag.start] + was[cut...]), caret: tag.start)
        }
        return nil
    }

    /// **The lighter row when the rows change**: the row whose label his letters already are, without regard to case
    /// and spaces ("@Customer Support" lights Customer Support, not Customer Support Lead above it, so Return picks what
    /// he wrote), else the first.
    public func start(for letters: String, in rows: [Row]) -> Int {
        let said = Self.fold(letters)
        return rows.firstIndex { Self.fold($0.label) == said } ?? 0
    }

    /// **The tags of the words that he sends** (design 4.5; rules 1 and 2 of the hub's reading, `tag_at`): at each "@"
    /// that starts a tag (the start of the words, whitespace or one of `( [ { " '` before it), outside code (between two
    /// backticks of one line, or in a fenced block), the longest role of the team, any case, each of its spaces one run
    /// of spaces or tabs; else the longest name, any case; then a tag end (the end, whitespace or one of
    /// `. , ; : ! ? ) ] } " '`, but no "." before a letter or a digit). So what he sees as a tag in the box is a whole
    /// label: "@Marketin" is plain words. The chat's own agent is no tag, and its role names nobody, also where another
    /// agent holds it too; a role that two agents hold names neither. **Where a role is also an agent's name, the name
    /// decides**, as that agent's label says, so a pick always reads back as the agent he picked. The hub reads a chat
    /// app's words by the same two rules. At most 10 tags, and none longer than 80 scalars, which the hub would refuse.
    public func mentions(in text: String) -> [Mention] {
        let scalars = Array(text.unicodeScalars)
        guard scalars.contains("@") else { return [] }
        let code = Self.code(scalars)
        var found: [Mention] = [], from = 0
        while found.count < Self.most, let at = scalars[from...].firstIndex(of: "@") {
            guard !code[at], Self.starts(scalars, at), let tag = tag(scalars, at) else {
                from = at + 1
                continue
            }
            if tag.length <= Self.longest { found.append(tag) }
            from = tag.start + tag.length
        }
        return found
    }

    /// The tag whose "@" stands at `at`, or nil.
    private func tag(_ scalars: [Unicode.Scalar], _ at: Int) -> Mention? {
        var longest: (end: Int, role: Role)?
        for role in reading {
            if let end = Self.match(role.words, in: scalars, from: at + 1), Self.ends(scalars, end),
               end > (longest?.end ?? at) {
                longest = (end, role)
            }
        }
        if let longest, !longest.role.isAName {
            guard longest.role.holders.count == 1, let agent = longest.role.holders.first, agent != except else { return nil }
            return Mention(agent: agent, start: at, length: longest.end - at)
        }
        for name in names {
            guard let end = Self.match([name], in: scalars, from: at + 1), Self.ends(scalars, end) else { continue }
            let agent = Self.string(name[...])
            return agent == except ? nil : Mention(agent: agent, start: at, length: end - at)
        }
        return nil
    }

    /// Where `words` end when they stand at `start`, any case, with one run of spaces or tabs between two of them.
    private static func match(_ words: [[Unicode.Scalar]], in scalars: [Unicode.Scalar], from start: Int) -> Int? {
        var at = start
        for (index, word) in words.enumerated() {
            if index > 0 {
                var gap = at
                while gap < scalars.count, scalars[gap] == " " || scalars[gap] == "\t" { gap += 1 }
                guard gap > at else { return nil }
                at = gap
            }
            guard at + word.count <= scalars.count,
                  word.indices.allSatisfy({ same(scalars[at + $0], word[$0]) }) else { return nil }
            at += word.count
        }
        return at
    }

    private static func same(_ a: Unicode.Scalar, _ b: Unicode.Scalar) -> Bool {
        a == b || a.properties.lowercaseMapping == b.properties.lowercaseMapping
    }

    /// The "@" at `at` can start a tag (the hub's `tag_start`).
    static func starts(_ scalars: [Unicode.Scalar], _ at: Int) -> Bool {
        scalars[at] == "@" && (at == 0 || scalars[at - 1].properties.isWhitespace || before.contains(scalars[at - 1]))
    }

    /// A tag can end before `at` (the hub's `tag_end`).
    private static func ends(_ scalars: [Unicode.Scalar], _ at: Int) -> Bool {
        guard at < scalars.count else { return true }
        let scalar = scalars[at]
        if scalar.properties.isWhitespace { return true }
        guard after.contains(scalar) else { return false }
        guard scalar == ".", at + 1 < scalars.count else { return true }
        let next = scalars[at + 1].properties
        return !(next.isAlphabetic || next.numericType != nil)
    }

    /// For each scalar, true where it is code, which holds no tag (the hub's `tag_code`): a fenced block, from a line
    /// that starts with three backticks to the next such line or the end, and what stands between two backticks of one
    /// line.
    private static func code(_ scalars: [Unicode.Scalar]) -> [Bool] {
        var code = [Bool](repeating: false, count: scalars.count), fenced = false, start = 0
        while start <= scalars.count {
            var end = start
            while end < scalars.count, scalars[end] != "\n" { end += 1 }
            let fence = end - start >= 3 && scalars[start..<(start + 3)].allSatisfy { $0 == "`" }
            if fence || fenced {
                for at in start..<end { code[at] = true }
                fenced = fenced != fence
            } else {
                let ticks = (start..<end).filter { scalars[$0] == "`" }
                for pair in stride(from: 0, to: ticks.count - 1, by: 2) {
                    for at in ticks[pair]...ticks[pair + 1] { code[at] = true }
                }
            }
            start = end + 1
        }
        return code
    }

    /// The words on single spaces.
    private static func spaced(_ words: String) -> String {
        words.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A name or a role as two of them compare: one space between words, and no case (the hub's `agent_words`, whose
    /// `casefold` this folding gives: "Straße" and "STRASSE" are one).
    private static func fold(_ words: String) -> String {
        spaced(words).folding(options: .caseInsensitive, locale: nil)
    }

    /// The letters of the filter and what they are compared with: no case and no accents.
    private static func loose(_ words: some StringProtocol) -> String {
        String(words).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The role from the start of each of its words: "SEO & AI Search", "AI Search", "Search".
    private static func wordStarts(of role: String) -> [Substring] {
        var starts: [Substring] = [], before: Character?
        for index in role.indices {
            let character = role[index]
            let word = character.isLetter || character.isNumber
            if word, !(before.map { $0.isLetter || $0.isNumber } ?? false) { starts.append(role[index...]) }
            before = character
        }
        return starts
    }

    static func string(_ scalars: some Sequence<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }
}

// MARK: - The tags in his sent message

extension AgentTags {
    /// **His words whose tags the hub gave** (`MessageText.mentions` not nil): only an entry is a tag there, so an "@"
    /// before a name outside the entries stays words: the name of the chat's own agent, an 11th tag, his messages from
    /// before the tags (`ChatNames.pieces`).
    public enum Given: AttributedStringKey {
        public typealias Value = Bool
        public static let name = "FleetCore.AgentTags.Given"
    }

    /// **The words of a tag in a block of his message**, with its agent's name (`ChatNames`, which draws them as that
    /// agent's badge): the whole range, "@" included.
    public enum Tagged: AttributedStringKey {
        public typealias Value = String
        public static let name = "FleetCore.AgentTags.Tagged"
    }

    /// **His message with a mark in place of each tag's "@"**, for the reading of its Markdown (`MessageBlock`), which
    /// gives the words of each block without their marks and their places in his text: the mark of a tag goes with its
    /// words into its block, and the block's words get the tag (`unmarked`), so the hub's range in his text, which is in
    /// Unicode scalars, falls on its words exactly. A mark is one private-use scalar, as "@" is one, so the text keeps
    /// its length and its blocks. Nil where no entry holds: none at all, a range past the end or over an earlier one, no
    /// "@" at its start or no tag start before it, and a text that holds such a mark already.
    public struct Marked: Equatable, Sendable {
        public let text: String
        /// Each mark's agent and the scalars of its words after the "@", in the order of the marks.
        let tags: [(agent: String, label: [Unicode.Scalar])]
        /// What the reading of the text depends on: the marked text and the agents, which a rename changes.
        public var key: String {
            "tags\u{0}" + tags.map { "\($0.agent)\u{2}\($0.label.count)" }.joined(separator: "\u{1}") + "\u{0}" + text
        }

        public static func == (lhs: Marked, rhs: Marked) -> Bool { lhs.key == rhs.key }
    }

    /// The first of the marks; a tag's mark is this plus its place among the tags.
    static let firstMark: UInt32 = 0xE000

    public static func marked(_ text: String, mentions: [Mention]) -> Marked? {
        guard !mentions.isEmpty else { return nil }
        var scalars = Array(text.unicodeScalars)
        guard !scalars.contains(where: { (firstMark..<firstMark + UInt32(most)).contains($0.value) }) else { return nil }
        var tags: [(agent: String, label: [Unicode.Scalar])] = [], last = 0
        for mention in mentions.sorted(by: { $0.start < $1.start }) where tags.count < most {
            let start = mention.start, end = mention.start + mention.length
            guard start >= last, mention.length >= 2, end <= scalars.count, starts(scalars, start),
                  let mark = Unicode.Scalar(firstMark + UInt32(tags.count)) else { continue }
            tags.append((mention.agent, Array(scalars[(start + 1)..<end])))
            scalars[start] = mark
            last = end
        }
        return tags.isEmpty ? nil : Marked(text: string(scalars), tags: tags)
    }

    /// **A block's words with each mark back to "@"**, and each tag's words with its agent (`Tagged`): only where the
    /// words after the mark are the tag's own, as his text holds them, and no link or code of his stands on them, which
    /// keep their words as a name does in a chat.
    public static func unmarked(_ words: AttributedString, by marked: Marked) -> AttributedString {
        let marks = words.unicodeScalars.enumerated().compactMap { offset, scalar -> (offset: Int, tag: Int)? in
            let tag = Int(scalar.value) - Int(firstMark)
            return marked.tags.indices.contains(tag) ? (offset, tag) : nil
        }
        guard !marks.isEmpty else { return words }
        var words = words
        for (offset, tag) in marks {
            let at = words.unicodeScalars.index(words.startIndex, offsetBy: offset)
            let next = words.unicodeScalars.index(after: at)
            let kept = words[at..<next].runs.first?.attributes ?? AttributeContainer()
            words.replaceSubrange(at..<next, with: AttributedString("@", attributes: kept))
            let label = marked.tags[tag].label
            let start = words.unicodeScalars.index(words.startIndex, offsetBy: offset)
            guard let end = words.unicodeScalars.index(start, offsetBy: label.count + 1, limitedBy: words.endIndex),
                  words.unicodeScalars[words.unicodeScalars.index(after: start)..<end].elementsEqual(label),
                  !words[start..<end].runs.contains(where: { $0.link != nil || $0.inlinePresentationIntent?.contains(.code) == true })
            else { continue }
            var tagged = AttributeContainer()
            tagged[Tagged.self] = marked.tags[tag].agent
            words[start..<end].mergeAttributes(tagged)
        }
        return words
    }

    /// Literal words (a code block, a cell of a table) with each mark back to "@", and no tag.
    public static func unmarked(_ words: String, by marked: Marked) -> String {
        string(words.unicodeScalars.map { scalar in
            marked.tags.indices.contains(Int(scalar.value) - Int(firstMark)) ? "@" : scalar
        })
    }
}
