import Foundation
import Testing
@testable import FleetCore

/// **`String(l10n:)`** (`Localized.swift`, `app/Localization/README.md`): with no table the English stays as it was,
/// character for character, and with a language's table the words come in that language, for this test's task only.
struct LocalizedTests {
    /// A table of one language in a folder of its own, as `xcstringstool compile` writes it into an app.
    static func table(_ words: [String: String], plural: (key: String, one: String, other: String)? = nil) throws -> Bundle {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("l10n-\(UUID().uuidString)/es.lproj")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let strings = words.map { "\"\($0.key)\" = \"\($0.value)\";" }.joined(separator: "\n")
        try strings.write(to: folder.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        if let plural {
            let dict: [String: Any] = [plural.key: [
                "NSStringLocalizedFormatKey": "%#@n@",
                "n": ["NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": "lld",
                      "one": plural.one, "other": plural.other]]]
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            try data.write(to: folder.appendingPathComponent("Localizable.stringsdict"))
        }
        return try #require(Bundle(url: folder))
    }

    @Test func withNoTableTheEnglishStaysAsItWas() {
        let app = "WhatsApp", count = 1234, big: Int64 = 5_000_000_000
        #expect(String(l10n: "Sent to \(app)") == "Sent to \(app)")
        // The current locale would write 1.234 on a Mac with the region Spain: the digits stay plain.
        #expect(String(l10n: "\(count) tasks") == "1234 tasks")
        #expect(String(l10n: "\(big) bytes") == "5000000000 bytes")
        #expect(String(l10n: "Sent to \("50% off")") == "Sent to 50% off")
    }

    @Test func aTableGivesItsWordsToThisTaskOnly() throws {
        let spanish = try Self.table(["Sent to %@": "Enviado a %@", "Just now": "Ahora mismo"],
                                     plural: (key: "%lld tasks", one: "%lld tarea", other: "%lld tareas"))
        Localized.$bundle.withValue(spanish) {
            #expect(String(l10n: "Sent to \("WhatsApp")") == "Enviado a WhatsApp")
            #expect(String(l10n: "Just now") == "Ahora mismo")
            #expect(String(l10n: "\(1) tasks") == "1 tarea")
            #expect(String(l10n: "\(1234) tasks") == "1234 tareas")
            #expect(String(l10n: "Not in the table") == "Not in the table")
        }
        #expect(String(l10n: "Just now") == "Just now")
    }
}
