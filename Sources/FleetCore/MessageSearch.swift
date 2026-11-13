import Foundation

/// **Message matches in the search card** (the owner's yes of 12 November 2026 to one picture, "Yes, all four": under
/// the card's groups, a group "In messages", each row the agent's glyph, the matching line on one line with the typed
/// words in medium weight, and the day at the right in muted text). The hub finds them (`GET /ui/history?mode=messages`,
/// UI-API.md 1.128): every typed word must match, the last one also as the start of a word, one row for each record,
/// the newest first. A hub without the feature `history_messages` is not asked, and the card shows nothing new.
public enum MessageSearch {
    /// The owner feature of the search.
    public static let feature = "history_messages"
    /// The characters that he types before the card asks the hub, and the time with no key before it asks.
    public static let least = 3
    public static let wait: Duration = .milliseconds(200)
    /// The rows of one answer.
    public static let limit = 20
    /// The entries that a chat draws over a match that it opens at, so that it can show the match in its middle:
    /// twelve entries of one line fill more than half of the tallest window.
    public static let over = 12

    /// The words, without the room around them, when they are enough to ask the hub for: `least` characters or more.
    public static func asks(_ query: String) -> String? {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.count >= least ? words : nil
    }

    /// How many of a chat's newest entries the chat draws to show a match in its middle: the match at `index` of the
    /// chat's `count` entries, the oldest first, every entry after it, and `over` entries before it. With the match
    /// as the first entry that the chat drew, nothing stood over it to scroll into, and it showed at the top (a real
    /// window, 13 November 2026). A chat with fewer entries before the match draws them all.
    public static func drawn(count: Int, index: Int) -> Int {
        min(count, count - index + over)
    }

    /// The tokens of the typed words as the hub's index makes them: each run of letters and digits, in lower case and
    /// without accents.
    public static func tokens(_ text: String) -> [String] {
        text.split { !($0.isLetter || $0.isNumber) }.map { fold(String($0)) }.filter { !$0.isEmpty }
    }

    /// The parts of `line` that the typed words match, as the hub matched them: a word of the line that is one of the
    /// typed words, or that begins with the last of them.
    public static func highlights(in line: String, words: String) -> [Range<String.Index>] {
        let typed = tokens(words)
        guard let last = typed.last else { return [] }
        let whole = Set(typed.dropLast())
        var out: [Range<String.Index>] = [], start: String.Index?
        var index = line.startIndex
        func close(_ end: String.Index) {
            guard let from = start else { return }
            let word = fold(String(line[from..<end]))
            if whole.contains(word) || word == last { out.append(from..<end) }
            else if word.hasPrefix(last), let cut = prefixEnd(of: line, from: from, to: end, length: last.count) {
                out.append(from..<cut)
            }
            start = nil
        }
        while index < line.endIndex {
            let character = line[index]
            if character.isLetter || character.isNumber { if start == nil { start = index } } else { close(index) }
            index = line.index(after: index)
        }
        close(line.endIndex)
        return out
    }

    /// Where the first `length` folded characters of a word of the line end, so that only the typed part is marked.
    private static func prefixEnd(of line: String, from: String.Index, to end: String.Index, length: Int) -> String.Index? {
        var index = from, count = 0
        while index < end, count < length {
            count += fold(String(line[index])).count
            index = line.index(after: index)
        }
        return count == length ? index : nil
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil).lowercased()
    }
}

/// One record that matches, as `GET /ui/history?mode=messages` gives it.
public struct MessageMatch: Decodable, Identifiable, Equatable, Sendable {
    /// The history row's own number: a key for the list only.
    public let id: Int
    public let ref: String
    public let kind: String
    public let agent: String
    public let at: Double
    /// `T-<n>`, or nil.
    public let task: String?
    public let owner_chat: Bool
    /// The request id of the owner's message, for an `OM-<n>` record.
    public let message: String?
    public let snippet: String

    public init(id: Int, ref: String, kind: String, agent: String, at: Double, task: String? = nil, owner_chat: Bool = false,
                message: String? = nil, snippet: String) {
        self.id = id; self.ref = ref; self.kind = kind; self.agent = agent; self.at = at; self.task = task
        self.owner_chat = owner_chat; self.message = message; self.snippet = snippet
    }

    /// The task that the record is part of.
    public var taskNumber: Int? { Self.number(task, prefix: "T-") }

    /// Where the record stands in the agent's chat (`ChatEntry.id`, or a request's card `need-<n>`), for a record of
    /// his chat with it: his message, its reply, a request that it raised and his answer to it.
    public var chatEntry: String? {
        if ref.hasPrefix("OM-") { return message.map { "message-\($0)" } }
        if let report = Self.number(ref, prefix: "OR-") { return "report-\(report)" }
        if let need = Self.number(ref, prefix: "N-") { return "need-\(need)" }
        return nil
    }

    private static func number(_ text: String?, prefix: String) -> Int? {
        guard let text, text.hasPrefix(prefix), let number = Int(text.dropFirst(prefix.count)), number > 0 else { return nil }
        return number
    }
}

/// One answer of `GET /ui/history?mode=messages`.
public struct MessageMatches: Decodable, Sendable {
    public let db: String
    public let mode: String
    public let results: [MessageMatch]

    public func validate(database: String) throws {
        guard db == database, mode == "messages", results.count <= 100, Set(results.map(\.id)).count == results.count
        else { throw HubError.invalidResponse }
    }
}
