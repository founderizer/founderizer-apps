import Foundation
import Testing
@testable import FleetCore

/// **The Spanish of the real catalog** (`app/Localization/Localizable.xcstrings`) as a table of words for a test's own task,
/// as `xcstringstool compile` writes the shipped language into an app (`Localized.bundle`, `LocalizedTests.table`). A test
/// that runs under it runs the real Spanish and not a copy of it, so an edit of a line fails the test that holds its words.
enum SpanishTable {
    static let catalog = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Localization").appendingPathComponent("Localizable.xcstrings")

    /// The Spanish text of each key of the catalog that has one text (the keys with plural forms have none here).
    static func words() throws -> [String: String] {
        let data = try Data(contentsOf: catalog)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(json["strings"] as? [String: [String: Any]])
        var out: [String: String] = [:]
        for (key, entry) in strings {
            let spanish = (entry["localizations"] as? [String: Any])?["es"] as? [String: Any]
            if let unit = spanish?["stringUnit"] as? [String: Any], let value = unit["value"] as? String { out[key] = value }
        }
        return out
    }

    /// Runs `body` with `words` as the table of the language of the device (the catalog's Spanish when none are given),
    /// for this task only, and removes the folder that it wrote.
    static func run<T>(_ words: [String: String]? = nil, _ body: () throws -> T) throws -> T {
        let table = try words ?? Self.words()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spanish-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("es.lproj")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let strings = table.map { "\"\(escaped($0.key))\" = \"\(escaped($0.value))\";" }.joined(separator: "\n")
        try strings.write(to: folder.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        let bundle = try #require(Bundle(url: folder))
        return try Localized.$bundle.withValue(bundle) { try body() }
    }

    /// A text as the old-style `.strings` file writes it.
    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
