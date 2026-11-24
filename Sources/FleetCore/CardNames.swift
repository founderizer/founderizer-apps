import Foundation

/// **The names in a request's words are links** (the lane "Give on a card"; the owner, 19 November 2026, of a request
/// that named an agent and a repository in plain words: "auto-detect and format an agent, so it becomes a link too",
/// then his picks of the mockup: repositories, servers and app pages too). An agent opens its page, a repository its
/// page on GitHub, a server its page, and a page of the app that a step names ("Settings › Apps", "the Apps page")
/// that page. The book holds what the app already knows: the agents of the hub's reading with their roles, and the
/// repositories and servers of the readings that the app kept. A word that it does not know stays plain words. A card
/// whose request has a Give has a book of its own: the same names, and the short names of the Give's repositories
/// (`given`).
///
/// A link that opens the wrong thing is worse than none, so a name counts only where it cannot be part of something
/// else (`Rule`):
/// - an agent: its role, word for word, when one agent holds it ("Customer Support Lead"); the first two words or
///   more of a role that no other role starts with, when no word with a capital follows ("Customer Support", but not
///   "Head of" in "Head of Sales"); its name with a capital, or a role of one word, when no word with a capital stands
///   beside it ("Nova", but not "Studio" in "Visual Studio" or "Manager" in "Password Manager");
/// - a repository: owner/name, in any case, on a card also as the whole of an inline code (the owner, 23 November
///   2026, of a code that is "owner/name of a repository of your fleet": "The repository's badge"); its name alone when
///   it has a hyphen or an underscore, starts with no point, and no other repository of the book has that name
///   ("shop-api"); and on the card whose own Give names the repository, its name alone in any form, also of letters
///   only ("web"; the owner, that day: "Yes: a name that the card's Give names is a badge"), but for one that starts
///   with a point or that a secret or a page of the book also is, in any case ("Stripe", "Resources"): in small
///   letters, as the hub gives the Give, or in other capitals with no word with a capital beside it ("Web", but not
///   "Studio" in "Visual Studio" for acme/studio). A name that two repositories of that Give have names neither. No
///   name alone counts in inline code;
/// - a server: its name, in any case, when it has a digit or a hyphen ("app-1");
/// - a knowledge file of the owner's: its path, word for word ("knowledge/owner/brand.md"), also as the whole of an
///   inline code, which is how agents write a path;
/// - a secret of the fleet's (an API key or a login): its name, word for word, when it has a character that is no
///   letter and no space ("DOOR_BACKBLAZE_ACME_KEY", "acme-login"), also as the whole of an inline code; a name of
///   words of letters only ("Stripe", "Google Drive") only as the whole of an inline code, because it is a product's
///   words too (the owner, 21 November 2026:
///   "task cards in both agents chat and needs you sohuld also have a badge for specific Credentials", and "Yes, both");
/// - a page of the app: its words as the app writes them (`pages`), with their capitals, only in a sentence that names
///   Founderizer before them, because other products have pages of the same names; and a path that starts with
///   Settings neither after a word with a capital ("System Settings > General") nor before another step of a path
///   ("Settings > Apps > Founderizer" on an iPhone).
/// The longest name wins where two begin at one place, and a name stands only between two word boundaries.
public struct CardNames: Equatable, Sendable {
    /// What a name opens.
    public enum Target: Hashable, Sendable {
        case agent(String)
        case repository(String)
        case server(String)
        /// A page of the app by its key (`pages`): `settings/<section>`, `app/<group>`, `activity`, `agents`.
        case page(String)
        /// A knowledge file by its path (`knowledge/owner/<name>.md`), which the Knowledge page opens (the owner, 20
        /// November 2026: "referencing knowledge files would be very nice too", and "Yes, as drawn").
        case knowledge(String)
        /// A secret by its name, which opens its card over the page (`FleetStore.showSecret(named:)`); `key`: an API
        /// key, with the key's mark, else a login.
        case secret(String, key: Bool)

        static let scheme = "founderizer-card"

        /// A name that can stand as the whole of an inline code, which its badge draws with no code look.
        var fromCode: Bool {
            switch self {
            case .knowledge, .secret, .repository: true
            default: false
            }
        }

        /// The link of the name: the GitHub page of a repository, and one of the app's own for the rest, which the
        /// card opens itself (`init(url:)`).
        public var url: URL? {
            switch self {
            case .repository(let repo): URL(string: "https://github.com/\(repo)")
            case .agent(let name): Self.own("agent", name)
            case .server(let name): Self.own("server", name)
            case .page(let page): Self.own("page", page)
            case .knowledge(let path): Self.own("knowledge", path)
            case .secret(let name, let key): Self.own(key ? "key" : "login", name)
            }
        }

        private static func own(_ kind: String, _ value: String) -> URL? {
            guard let path = value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
            return URL(string: "\(scheme)://\(kind)/\(path)")
        }

        /// The target of one of the app's own links, or nil for any other link.
        public init?(url: URL) {
            guard url.scheme == Self.scheme, let kind = url.host,
                  let value = String(url.path.dropFirst()).removingPercentEncoding, !value.isEmpty else { return nil }
            switch kind {
            case "agent": self = .agent(value)
            case "server": self = .server(value)
            case "page": self = .page(value)
            case "knowledge": self = .knowledge(value)
            case "key": self = .secret(value, key: true)
            case "login": self = .secret(value, key: false)
            default: return nil
            }
        }
    }

    /// One name in a text: where it stands, and what it opens.
    public struct Found: Equatable, Sendable {
        public let range: Range<String.Index>
        public let target: Target
    }

    /// How a name must stand in a text to count.
    enum Rule: Equatable, Sendable {
        /// Anywhere between two word boundaries: a role of more than one word, a repository, a server.
        case exact
        /// With no word with a capital beside it: an agent's own name, a role of one word, and the name alone of a
        /// repository of the card's own Give in other capitals than the Give's.
        case alone
        /// With no word with a capital after it: the start of a role.
        case start
        /// In a sentence that names Founderizer before it: a page of the app.
        case inFounderizer
    }

    /// The sections of Settings and the groups of its Apps, by the words that the app gives them in English, which
    /// is how the agents write them, and the key of each.
    static let sections: [(words: String, key: String)] = [
        ("General", "general"), ("Servers", "servers"), ("Backup", "backup"), ("System status", "status"),
        ("Secrets", "secrets"), ("Knowledge", "knowledge"), ("Apps", "apps"), ("People", "people"),
        ("Reporting lines", "team"), ("Help", "help")]
    static let groups: [(words: String, key: String)] = [
        ("GitHub", "github"), ("Google Drive", "drive"), ("Gmail", "gmail"), ("MCP servers", "mcp")]

    /// The words of each page of the app that a step names, and its key: a section of Settings as "Settings ›
    /// Apps", "Settings > Apps", "Settings, Apps" or "Apps page", an app's own page under it, two pages of the sidebar
    /// (Needs you is none: a card stands on it), and the names that agents give the page of who may use what, which is
    /// Settings › Apps ("Resources", "Access page": the app has no page of either name).
    public static let pages: [(words: String, page: String)] = {
        var pages: [(String, String)] = [("Tasks page", "activity"), ("Agents page", "agents"),
                                         ("Resources", "settings/apps"), ("Access page", "settings/apps")]
        for (words, key) in sections {
            for join in [" › ", " > ", ", "] { pages.append(("Settings\(join)\(words)", "settings/\(key)")) }
            pages.append(("\(words) page", "settings/\(key)"))
        }
        for (words, key) in groups {
            for join in [" › ", " > ", ", "] {
                pages.append(("Settings\(join)Apps\(join)\(words)", "app/\(key)"))
                pages.append(("Apps\(join)\(words)", "app/\(key)"))
            }
        }
        return pages
    }()

    private struct Name: Equatable, Sendable {
        let words: String
        let length: Int
        let anyCase: Bool
        let target: Target
        let rule: Rule
    }
    /// The names by their first letter in small letters, then by their length, the longest first, then by their words
    /// in small letters, each list in the book's order: a text of a few hundred characters is read against a book of
    /// hundreds of repositories, which all begin with their owner's name, so a place in the text looks up the few lengths
    /// of its first letter and does not read every name of it (a review of 21 November 2026: 300 repositories made a
    /// chat of 200 messages open in 1,070 ms, 290 ms with no book).
    private let names: [Character: [Bucket]]
    private struct Bucket: Equatable, Sendable {
        let length: Int
        let byWords: [String: [Name]]
    }

    /// agents: each agent's name and role (nil for none); repositories: owner/name; servers: their names; knowledge:
    /// the paths of the owner's knowledge files; secrets: each secret's name that one secret has, and whether it is an
    /// API key (`FleetStore.cardSecrets`); given: the repositories, owner/name, of the card's own Give, for the book of
    /// that one card. **A short name of the Give stands with the repositories in the book's order**: an agent of the
    /// same words stays the agent, and it comes before a server of the same words, as a short name with a hyphen does.
    /// A secret's or a page's words are no short name of the Give, in any case: the Give would hide them.
    public init(agents: [(name: String, role: String?)], repositories: [String] = [], servers: [String] = [],
                knowledge: [String] = [], secrets: [(name: String, key: Bool)] = [], given: [String] = []) {
        var names: [Name] = []
        func add(_ words: String, anyCase: Bool, _ target: Target, _ rule: Rule) {
            if !words.isEmpty {
                names.append(Name(words: words, length: words.count, anyCase: anyCase, target: target, rule: rule))
            }
        }
        let roles = agents.compactMap { agent in agent.role.map { (agent.name, Self.words($0)) } }
            .filter { !$0.1.isEmpty }
        let held = Dictionary(roles.map { ($0.1, 1) }, uniquingKeysWith: +)
        for (name, role) in roles where held[role] == 1 {       // a role that two agents hold names neither
            add(role.joined(separator: " "), anyCase: false, .agent(name), role.count > 1 ? .exact : .alone)
            guard role.count > 2 else { continue }
            for count in 2..<role.count {
                let start = Array(role.prefix(count))
                if held[start] == nil, !roles.contains(where: { $0.0 != name && Array($0.1.prefix(count)) == start }) {
                    add(start.joined(separator: " "), anyCase: false, .agent(name), .start)
                }
            }
        }
        for agent in agents where agent.name.contains(where: \.isLetter) {
            add(agent.name.capitalized, anyCase: false, .agent(agent.name), .alone)
        }
        let own = Set(given.map { $0.lowercased() })
        let repos = Set(repositories.map { $0.lowercased() }).union(own)
            .filter { $0.split(separator: "/").count == 2 }
        let short = Dictionary(grouping: repos, by: { String($0.split(separator: "/")[1]) })
        // a review of 23 November 2026: a Give of x/stripe made the key `Stripe` a copy chip, and a Give of
        // x/resources made "Resources" open GitHub, not the page, and took the card's Open <page>
        let taken = Set(secrets.map { $0.name.lowercased() } + Self.pages.map { $0.words.lowercased() })
        for repo in repos.sorted() {
            add(repo, anyCase: true, .repository(repo), .exact)
            let alone = String(repo.split(separator: "/")[1])
            if alone.hasPrefix(".") { continue }            // ".github" is a folder of every repository
            let named = short[alone] ?? []
            let mine = named.filter(own.contains) == [repo] && !taken.contains(alone)
            if alone.contains(where: { $0 == "-" || $0 == "_" }) {
                if mine || named == [repo] { add(alone, anyCase: true, .repository(repo), .exact) }
            } else if mine {
                add(alone, anyCase: false, .repository(repo), .exact)
                add(alone, anyCase: true, .repository(repo), .alone)
            }
        }
        for server in Set(servers) where server.contains(where: { $0.isNumber || $0 == "-" }) {
            add(server, anyCase: true, .server(server), .exact)
        }
        for (words, page) in Self.pages { add(words, anyCase: false, .page(page), .inFounderizer) }
        for path in Set(knowledge) where path.hasPrefix("knowledge/") { add(path, anyCase: false, .knowledge(path), .exact) }
        for secret in secrets where !secret.name.trimmingCharacters(in: .whitespaces).isEmpty {
            add(secret.name, anyCase: false, .secret(secret.name, key: secret.key), .exact)
        }
        // the longest first, so that "Customer Support Lead" wins over "Customer Support" where both begin
        self.names = Dictionary(grouping: names, by: { Self.first($0.words) }).mapValues { names in
            Dictionary(grouping: names, by: \.length).sorted { $0.key > $1.key }
                .map { Bucket(length: $0.key, byWords: Dictionary(grouping: $0.value, by: { $0.words.lowercased() })) }
        }
    }

    private static func first(_ text: some StringProtocol) -> Character {
        String(text.first ?? " ").lowercased().first ?? " "
    }

    private static func words(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }

    /// A character that continues a name, so that no name ends or begins next to it: a letter, a digit, a hyphen or an
    /// underscore; a slash, a point or an at sign only between two such characters ("acme/web", "app-1.example").
    private static func joins(_ text: String, at index: String.Index) -> Bool {
        let c = text[index]
        if c.isLetter || c.isNumber || c == "-" || c == "_" { return true }
        guard "/.@".contains(c) else { return false }
        let next = text.index(after: index)
        return next < text.endIndex && (text[next].isLetter || text[next].isNumber)
    }

    /// Whether a name that matched at `range` stands as its rule asks (`Rule`).
    private static func stands(_ rule: Rule, in text: String, _ range: Range<String.Index>) -> Bool {
        switch rule {
        case .exact: true
        case .alone: !capitalAfter(text, range.upperBound) && !capitalBefore(text, range.lowerBound)
        case .start: !capitalAfter(text, range.upperBound)
        case .inFounderizer:
            sentence(of: text, before: range.lowerBound).contains("Founderizer")
                && !(text[range].hasPrefix("Settings")
                     && (capitalBefore(text, range.lowerBound) || pathAfter(text, range.upperBound)))
        }
    }

    /// Another step of a path follows `end`: " > " or " › " and a word with a capital. The app's own paths are whole
    /// names of the book ("Settings › Apps › GitHub"), so a path that goes on is another product's ("Settings > Apps >
    /// Founderizer" on an iPhone).
    private static func pathAfter(_ text: String, _ end: String.Index) -> Bool {
        let rest = text[end...]
        for join in [" › ", " > "] where rest.hasPrefix(join) {
            let next = rest.index(rest.startIndex, offsetBy: join.count)
            return next < rest.endIndex && rest[next].isUppercase
        }
        return false
    }

    /// The word after `end`, one space on, starts with a capital.
    private static func capitalAfter(_ text: String, _ end: String.Index) -> Bool {
        guard end < text.endIndex, text[end] == " " else { return false }
        let next = text.index(after: end)
        return next < text.endIndex && text[next].isUppercase
    }

    /// The word before `start`, one space back, starts with a capital: also at a sentence's start ("Android Studio").
    private static func capitalBefore(_ text: String, _ start: String.Index) -> Bool {
        guard start > text.startIndex else { return false }
        let space = text.index(before: start)
        guard text[space] == " " else { return false }
        var word = space
        while word > text.startIndex, text[text.index(before: word)].isLetter || text[text.index(before: word)].isNumber {
            word = text.index(before: word)
        }
        return word < space && text[word].isUppercase
    }

    /// The words of `text` from the start of the sentence of `index` to it: after the last end of a sentence or line.
    private static func sentence(of text: String, before index: String.Index) -> Substring {
        var start = index
        while start > text.startIndex, !".!?\n".contains(text[text.index(before: start)]) {
            start = text.index(before: start)
        }
        return text[start..<index]
    }

    /// Every name of the book in `text`, in their order: the longest at each place, and none inside another word.
    ///
    /// **A known hole** (Fable's read of 22 November 2026): where two names of the book are the same words at a place,
    /// the first of them in the book wins (`init`: agents, repositories, servers, pages, knowledge files, and secrets
    /// last), and the other gets no badge there. So a key's name that a repository's short name or a server's name also
    /// is, in any case of letters, shows in a card's words as that repository's or server's badge, and its press opens
    /// that one. The title of a Replace card is free of it: its book holds the one key and nothing else
    /// (`NeedRequestCard.titleNames`).
    ///
    /// **A known hole of a Give's short names** (the validation of F9, 24 November 2026): on the card whose Give names a
    /// repository, its short name is a badge also where the words mean something else: with acme/api, "the api key"
    /// shows a badge; with acme/acme.com, "acme.com" opens the repository on GitHub, not the site. It fits his words
    /// ("a name that the card's Give names is a badge"), and his card of that answer had no such case.
    public func find(in text: String) -> [Found] {
        var found: [Found] = [], index = text.startIndex
        while index < text.endIndex {
            if index > text.startIndex, Self.joins(text, at: text.index(before: index)) {
                index = text.index(after: index)
                continue
            }
            var hit: Found?
            lengths: for bucket in names[Self.first(text[index...])] ?? [] {
                guard let end = text.index(index, offsetBy: bucket.length, limitedBy: text.endIndex) else { continue }
                let piece = text[index..<end]
                for name in bucket.byWords[piece.lowercased()] ?? [] {
                    let same = name.anyCase ? piece.compare(name.words, options: .caseInsensitive) == .orderedSame
                                            : piece == name.words
                    if same, end == text.endIndex || !Self.joins(text, at: end), Self.stands(name.rule, in: text, index..<end) {
                        hit = Found(range: index..<end, target: name.target)
                        break lengths
                    }
                }
            }
            if let hit {
                found.append(hit)
                index = hit.range.upperBound
            } else {
                index = text.index(after: index)
            }
        }
        return found
    }

    /// The names of `text` that its words show, each with its range in `text`'s characters: none in the words of a link
    /// of its own, and none in inline code but a knowledge file's path, a secret's name or, with `codedRepositories`, a
    /// repository's owner/name that is the whole of one (`wholeCode`); a secret's name of letters only shows only there
    /// (`distinct`).
    private func shown(in text: AttributedString, codedRepositories: Bool = true)
        -> [(Found, Range<AttributedString.Index>)] {
        let plain = String(text.characters)
        return find(in: plain).compactMap { found in
            let lower = plain.distance(from: plain.startIndex, to: found.range.lowerBound)
            let count = plain.distance(from: found.range.lowerBound, to: found.range.upperBound)
            let start = text.characters.index(text.startIndex, offsetBy: lower)
            let range = start..<text.characters.index(start, offsetBy: count)
            if text[range].runs.contains(where: { $0.link != nil }) { return nil }
            guard text[range].runs.contains(where: { Self.isCode($0.inlinePresentationIntent) }) else {
                if case .secret(let name, _) = found.target, !Self.distinct(name) { return nil }
                return (found, range)
            }
            switch found.target {
            case .knowledge, .secret: return Self.wholeCode(text, range) ? (found, range) : nil
            // its owner/name only: a name alone in code is a value to copy ("The repository's badge")
            case .repository(let repo) where codedRepositories && plain[found.range].lowercased() == repo:
                return Self.wholeCode(text, range) ? (found, range) : nil
            default: return nil
            }
        }
    }

    private static func isCode(_ intent: InlinePresentationIntent?) -> Bool { intent?.contains(.code) == true }

    /// A secret's name that cannot be plain words: it has a character that is no letter and no space (an underscore, a
    /// digit, a hyphen, a point). "Google Drive" is a product's words (review).
    private static func distinct(_ name: String) -> Bool { name.contains { !$0.isLetter && !$0.isWhitespace } }

    /// The characters of `range` are one inline code and nothing more: code on each of them, and none just before or
    /// just after them ("`knowledge/owner/brand.md`", but not "`cat knowledge/owner/brand.md`").
    private static func wholeCode(_ text: AttributedString, _ range: Range<AttributedString.Index>) -> Bool {
        guard text[range].runs.allSatisfy({ isCode($0.inlinePresentationIntent) }) else { return false }
        if range.lowerBound > text.startIndex {
            let before = text.characters.index(before: range.lowerBound)
            if text[before..<range.lowerBound].runs.contains(where: { isCode($0.inlinePresentationIntent) }) { return false }
        }
        if range.upperBound < text.endIndex {
            let after = text.characters.index(after: range.upperBound)
            if text[range.upperBound..<after].runs.contains(where: { isCode($0.inlinePresentationIntent) }) { return false }
        }
        return true
    }

    /// One piece of a request's words as a card draws them (`pieces(_:)`): words, or one name that it draws as a badge.
    public struct Piece: Equatable, Sendable {
        public let words: AttributedString
        /// What the name of the piece opens, with its link (`Target.url`) on its words; nil for the words around the
        /// names, a link of their own among them.
        public let badge: Target?
    }

    /// **`text` in pieces, each name that it shows a piece of its own with its link**, which a card draws as a badge
    /// with its icon (the owner, 20 November 2026: "for servers, show a server/vps or mac icon before its name, and
    /// enclose it in like a badge entirely", "Same for agents", and "Badge them too" of repositories and the app's
    /// pages). The pieces hold every character of `text` once, in its order; a name in the words of a link of its own
    /// or in inline code stays words, but for those that can be the whole of one (`shown`). `codedRepositories`: a
    /// repository's owner/name is one of them, which is a card's rule and no chat's (`ChatNames`).
    public func pieces(_ text: AttributedString, codedRepositories: Bool = true) -> [Piece] {
        var pieces: [Piece] = [], start = text.startIndex
        for (found, range) in shown(in: text, codedRepositories: codedRepositories) {
            if start < range.lowerBound {
                pieces.append(Piece(words: AttributedString(text[start..<range.lowerBound]), badge: nil))
            }
            var words = AttributedString(text[range])
            if found.target.fromCode {                // a path or a name from inline code: the badge's look, not code's
                let coded = words.runs.filter { Self.isCode($0.inlinePresentationIntent) }
                    .map { ($0.range, $0.inlinePresentationIntent?.subtracting(.code)) }
                for (part, rest) in coded { words[part].inlinePresentationIntent = rest?.isEmpty == true ? nil : rest }
            }
            if let url = found.target.url { words.link = url }
            pieces.append(Piece(words: words, badge: found.target))
            start = range.upperBound
        }
        if start < text.endIndex { pieces.append(Piece(words: AttributedString(text[start...]), badge: nil)) }
        return pieces
    }

    /// The pages of the app that the words of Markdown `text` show, each once, in their order: a step on one page gets
    /// "Open <page>". A page in a code block, in inline code or in a link's own words does not count.
    public func pages(inMarkdown text: String) -> [String] {
        var seen: [String] = []
        for block in MessageBlock.parse(text) where block.kind != .code && block.kind != .rule && block.kind != .table {
            for (found, _) in shown(in: MessageBlock.inline(block.text)) {
                if case .page(let page) = found.target, !seen.contains(page) { seen.append(page) }
            }
        }
        return seen
    }
}
