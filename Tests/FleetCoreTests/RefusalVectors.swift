import Foundation
import Testing

/// **`app/vectors/refusal-codes.json`**, the hub's refusal words by code as `make_vectors.py` made them from
/// `refusal_words.py` (UI-API.md 1.181): each code with the English of its sentence, `{name}` where a name goes, and the
/// names that each sentence holds. The tests of the apps hold their own table to it (`RefusalWordsTests`) and the compared
/// phrases to it (`RefusalMeaningTests`).
enum RefusalVectors {
    static let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("vectors").appendingPathComponent("refusal-codes.json")

    struct Table {
        /// The hub's English of each code, with `{name}` for each name.
        let codes: [String: String]
        /// The names that the words of a code hold; a code with none has no entry.
        let holes: [String: [String]]
    }

    static func load() throws -> Table {
        let data = try Data(contentsOf: file)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let codes = try #require(json["codes"] as? [String: String])
        let holes = try #require(json["holes"] as? [String: [String]])
        return Table(codes: codes, holes: holes)
    }

    /// The English of a code with each hole filled by `fill` of its name: what the hub writes into `error`.
    static func english(_ code: String, in table: Table, fill: (String) -> String) -> String? {
        guard var text = table.codes[code] else { return nil }
        for name in table.holes[code] ?? [] { text = text.replacingOccurrences(of: "{\(name)}", with: fill(name)) }
        return text
    }
}
