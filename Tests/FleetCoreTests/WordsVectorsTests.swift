import Foundation
import Testing
@testable import FleetCore

/// **The vectors of the words that FleetCore makes** (`app/vectors/swift-words.json`): an agent's label and the line
/// under it (`AgentNames`), the blocks of a message (`MessageBlock.parse`) and its plain line (`MessageBlock.plain`,
/// `ChatList.plain`), the time at the end of an agent's row (`ChatList.time`) and the age of a request
/// (`activityAge`). The Windows app's library (`windows/Founderizer.Core`) makes the same words: its tests hold them
/// equal to this file, and each case where they differ is named there.
///
/// With `FOUNDERIZER_VECTORS_OUT` set, the test writes the file into that folder (`app/vectors/make_vectors.py` does,
/// and its `--check` compares); without it, the test holds the committed file equal to what FleetCore gives now.
struct WordsVectorsTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("vectors")
    static let file = "swift-words.json"

    /// Names of every form that team.json takes, with a role or none.
    static let agents: [(String, String?)] = [
        ("manager", "Fleet Manager"), ("wren", "Customer Support"), ("theo", "Developer"), ("pax", "DevOps"),
        ("orla", "Marketing"), ("nova", nil), ("dev-lead", nil), ("web_dev", nil), ("worker-1", nil), ("a1b2", nil),
        ("qa", "  Quality   assurance "), ("ops", ""), ("scout", "Scout"), ("iris", "Iris's helper"),
        ("sales-bot", "Sales bot"), ("x", nil), ("bistro", "Café helper"),
    ]

    /// What the owner types into Search (the Mac's SearchPalette): each against each agent, by `AgentNames.matches`.
    static let searches: [String] = ["support", "Support", "SUP", "wren", "WREN", "dev", "ops", "lead", "web_", "1",
                                     "cafe", "CAFÉ", "helper ", "", " ", "Fleet Manager", "fleet  manager"]

    static let texts: [String] = [
        "Here is the draft:\n\n# Simpler prices for November\n\nFrom **1 November**, three plans: *Starter*, *Team* and "
            + "*Scale*.\n\n> We moved our whole support team in an afternoon.\n\n- one\n2. two\n\n| Day | Signups |\n"
            + "|---|---|\n| Mon | 12 |\n\n```\n$ curl -sI https://example.com | head -1\n```",
        "Steps:\n- Pull the branch\n  - run the tests\n    - all of them\n  continued line\n- Push\n\n1) first\n2) second",
        "- item\n  ```\n  code in a list\n  ```\n- next",
        "Plain words\non two lines\n\nand a second paragraph",
        "***\n---\n#Not a heading\n## A heading\n####### seven",
        "Use `npm test` and see [the docs](https://example.com/docs) or **bold _mixed_** text.",
        "| a \\| b | c |\n|:--|--:|\n| 1 | 2 |",
        "    indented code-like line\n\tand a tab",
        "> quote one\n> quote two\nafter",
        "```swift\nlet a = 1\n```\n\n```\nunclosed fence",
        "You asked for *three* things: ~~one~~, __two__ and three.",
        "",
        "   ",
        "A line with **unclosed bold",
        "1. first\n   more of first\n10. tenth",
        "Café naïve: \"quotes\" and 'single' & <tags>",
    ]

    /// Times of the hub (seconds) and the clock now: today, yesterday, this week, older, and ahead of the clock.
    static let now = 1_794_582_720.0        // 13 November 2026, 15:12 UTC
    static let times: [Double] = [now - 480, now - 15 * 3600, now - 16 * 3600, now - 86_400 - 3600, now - 3 * 86_400,
                                  now - 6 * 86_400, now - 7 * 86_400, now - 40 * 86_400, now - 400 * 86_400, now + 30]
    static let ages: [Double] = [0, 59, 60, 61, 3599, 3600, 7200, 86_399, 86_400, 2 * 86_400, 6 * 86_400 + 86_399,
                                 7 * 86_400, 40 * 86_400, 400 * 86_400, -30]

    struct Name: Codable { let name: String; let title: String?; let label: String; let under: String?; let capitalized: String }
    struct Block: Codable { let kind: String; let text: String; let marker: String; let level: Int; let cells: [[String]] }
    struct Text: Codable { let text: String; let blocks: [Block]; let plain: String; let preview: String? }
    struct Time: Codable { let time: Double; let now: Double; let locale: String; let words: String }
    struct Age: Codable { let time: Double; let now: Double; let locale: String; let words: String }
    struct Match: Codable { let words: String; let names: [String] }
    struct Document: Codable {
        let about: String; let made_by: String; let time_zone: String
        let names: [Name]; let texts: [Text]; let times: [Time]; let ages: [Age]; let matches: [Match]
    }

    static func kind(_ kind: MessageBlock.Kind) -> String {
        switch kind {
        case .paragraph: "paragraph"
        case .heading: "heading"
        case .code: "code"
        case .item: "item"
        case .quote: "quote"
        case .rule: "rule"
        case .table: "table"
        }
    }

    static func document() throws -> Data {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let roles = AgentNames.roles(agents.map { (name: $0.0, title: $0.1) })
        let names = agents.map { name, title in
            Name(name: name, title: title, label: AgentNames.label(name, roles: roles),
                 under: AgentNames.under(name, roles: roles), capitalized: name.capitalized)
        }
        let texts = texts.map { text in
            Text(text: text,
                 blocks: MessageBlock.parse(text).map {
                     Block(kind: kind($0.kind), text: $0.text, marker: $0.marker, level: $0.level, cells: $0.cells)
                 },
                 plain: MessageBlock.plain(text), preview: ChatList.plain(text))
        }
        var times: [Time] = [], ages: [Age] = []
        for locale in ["en_GB", "en_US"] {
            for time in Self.times {
                times.append(Time(time: time, now: now, locale: locale,
                                  words: ChatList.time(time, now: now, calendar: calendar, locale: Locale(identifier: locale))))
            }
            for age in Self.ages {
                ages.append(Age(time: now - age, now: now, locale: locale,
                                words: activityAge(now - age, now: now, calendar: calendar, locale: Locale(identifier: locale))))
            }
        }
        let matches = searches.map { words in
            Match(words: words, names: agents.map(\.0).filter { AgentNames.matches($0, words, roles: roles) })
        }
        let document = Document(
            about: "Words that FleetCore makes: AgentNames.label and under with the roles of team.json, String.capitalized, "
                + "MessageBlock.parse and plain, ChatList.plain (the line under an agent's row), ChatList.time and "
                + "activityAge in UTC with two locales, and AgentNames.matches (Search) for each typed text.",
            made_by: "app/Tests/FleetCoreTests/WordsVectorsTests.swift", time_zone: "UTC", names: names, texts: texts,
            times: times, ages: ages, matches: matches)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document) + Data("\n".utf8)
    }

    @Test("The words' vectors are what FleetCore gives now")
    func theWordsVectorsAreTheCommittedFile() throws {
        let made = try Self.document()
        if let out = ProcessInfo.processInfo.environment["FOUNDERIZER_VECTORS_OUT"] {
            try made.write(to: URL(fileURLWithPath: out).appendingPathComponent(Self.file))
            return
        }
        let committed = try Data(contentsOf: Self.folder.appendingPathComponent(Self.file))
        #expect(committed == made, "app/vectors/\(Self.file) is not what FleetCore gives: run app/vectors/make_vectors.py")
    }
}
