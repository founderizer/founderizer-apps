import Foundation
import Testing
@testable import FleetCore

/// **The vectors of the words that FleetCore makes** (`app/vectors/swift-words.json`): an agent's label and the role
/// beside it (`AgentNames`), the blocks of a message (`MessageBlock.parse`) and its plain line (`MessageBlock.plain`,
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
        // A name inside a word of its role is no word of it: "Dev" with "DevOps" beside it.
        ("dev", "DevOps"),
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

    /// One block's inline marks as `MessageBlock.inline` reads them (the Mac's MessageText draws its runs).
    static let inlines: [String] = [
        "**bold** and *italic* and `code`", "a [link](https://example.com/docs) b", "<https://example.com/a>",
        "write to <mailto:help@example.com>", "[script](javascript:alert(1)) stays words", "~~gone~~ and kept",
        "__bold__ and _italic_", "**[a bold link](https://example.com)**", "\\*not italic\\*", "![the alt words](https://example.com/a.png)",
        "snake_case_word stays", "fish & chips &amp; peas", "`**not bold**` here", "**unclosed bold", "plain words only",
        "Use `npm test` and see [the docs](https://example.com/docs) or **bold _mixed_** text.",
        // A bare address, as Apple's reader links it with the autolinks of GitHub's Markdown (the hub tells a manager
        // that a page in a task is its full address). Only ASCII and no quotation mark: the reader's URL then keeps
        // the words as they are written.
        "Open https://example.com/settings and press **Save**.", "See https://example.com/settings.",
        "Open (https://example.com/a_(b)) now", "Go to www.example.com today", "Mail ops@example.com now",
        "Open http://localhost:8080/x", "ftp://example.com/x", "https://example.com/a?b=1&c=2, then",
        "Run `curl https://example.com` then open https://example.com/done!", "**https://example.com**",
        "x https://example.com/a_b_c_ y", "Write to mailto:ops@example.com.", "xhttps://example.com and WWW.example.com",
        "HTTPS://Example.com/A", "a https://example.com/a(b(c)d)e) b", "https://ex_ample.com/x and https://a.b_c.d.com/x",
        "a.b@example.com. and user@localhost and 1@2.3", "Use https://example.com/x&amp; then", "https://example.com/a&amp;b",
        "Visit https://example.com/a*b* now", "https://example.com/**x**", "*https://example.com* and _www.example.com_",
        "~~https://example.com~~", "_ops@example.com_", "a:b@example.com and xmailto:ops@x.com", "www. example",
        "(www.example.com/a(b))", "www.example.com<b>", "www.ex_ample.com and www.a_b.example.com",
        "ops@example.-com and ops@@example.com and -ops@example.com", "https://example.com/&quot;",
        "the address:https://example.com and foo_https://example.com",
        "https:// and https:/example.com and http://*example.com and https://-example.com",
        "[https://example.com](https://example.com/other)", "news.www@example.com and wow@example.com",
        "ops@example.com/x", "**see https://example.com/a**", "https://example.com/a.b?c. d",
    ]

    /// Times of the hub (seconds) and the clock now: today, yesterday, this week, older, and ahead of the clock.
    static let now = 1_794_582_720.0        // 13 November 2026, 15:12 UTC
    static let times: [Double] = [now - 480, now - 15 * 3600, now - 16 * 3600, now - 86_400 - 3600, now - 3 * 86_400,
                                  now - 6 * 86_400, now - 7 * 86_400, now - 40 * 86_400, now - 400 * 86_400, now + 30]
    static let ages: [Double] = [0, 59, 60, 61, 3599, 3600, 7200, 86_399, 86_400, 2 * 86_400, 6 * 86_400 + 86_399,
                                 7 * 86_400, 40 * 86_400, 400 * 86_400, -30]

    struct Name: Codable { let name: String; let title: String?; let label: String; let role: String?; let capitalized: String }
    struct Block: Codable { let kind: String; let text: String; let marker: String; let level: Int; let cells: [[String]] }
    struct Text: Codable { let text: String; let blocks: [Block]; let plain: String; let preview: String? }
    struct Time: Codable { let time: Double; let now: Double; let locale: String; let words: String }
    struct Age: Codable { let time: Double; let now: Double; let locale: String; let words: String }
    struct Match: Codable { let words: String; let names: [String] }
    struct Run: Codable, Equatable { let text: String; let bold: Bool; let italic: Bool; let struck: Bool; let code: Bool; let link: String? }
    struct Inline: Codable { let text: String; let runs: [Run] }
    struct Check: Codable { let requester: String; let accepted: Int?; let delivered: Double?; let words: String }
    struct Wait: Codable { let requester: String; let waiting_on: String?; let words: String }
    /// The Tasks board's Ended lane (`HubState.activity`, `EndedTasks`): a task of the input, and the lane of one period.
    struct EndedInput: Codable {
        let id: Int; let title: String; let owner: String; let state: String; let accepted: Int?; let created: Double
        let started: Double?; let last_activity: Double?; let trigger_id: Int?
    }
    struct EndedGroup: Codable { let title: String; let ids: [Int] }
    struct EndedDay: Codable { let start: Double; let groups: [EndedGroup] }
    struct EndedLane: Codable { let period: String; let count: Int; let failed: [Int]; let rest: Int; let days: [EndedDay] }
    struct Ended: Codable { let now: Double; let tasks: [EndedInput]; let lanes: [EndedLane] }
    struct Document: Codable {
        let about: String; let made_by: String; let time_zone: String
        let names: [Name]; let texts: [Text]; let times: [Time]; let ages: [Age]; let matches: [Match]; let inline: [Inline]
        let checks: [Check]; let waits: [Wait]; let ended: Ended
    }

    /// The Ended lane's tasks: ended today, yesterday, 5, 20 and 60 days ago, in each end state, accepted or not, the
    /// runs of two schedules, one agent's tasks of one title, a task that never started, and an open task.
    static let endedTasks: [EndedInput] = {
        let h = 3600.0, d = 86_400.0
        func task(_ id: Int, _ title: String, _ owner: String, _ state: String, ago: Double, accepted: Int? = nil,
                  schedule: Int? = nil, started: Bool = true) -> EndedInput {
            EndedInput(id: id, title: title, owner: owner, state: state, accepted: accepted, created: now - ago - 600,
                       started: started ? now - ago - 300 : nil, last_activity: started ? now - ago : nil, trigger_id: schedule)
        }
        return [
            task(1, "Answer the support tickets", "wren", "completed", ago: 1 * h, accepted: 1),
            task(2, "Answer the support tickets", "wren", "completed", ago: 2 * h),
            task(3, "Deploy the site", "pax", "failed", ago: 3 * h),
            task(4, "Fix the build", "theo", "completed", ago: 4 * h, accepted: 0),
            task(5, "An idea that was dropped", "wren", "canceled", ago: 5 * h),
            task(6, "CRM tickets waiting for iris: TCK-1", "wren", "completed", ago: 6 * h, schedule: 9),
            task(7, "CRM tickets waiting for iris: TCK-2", "wren", "completed", ago: 7 * h, accepted: 1, schedule: 9),
            task(8, "CRM tickets waiting for iris: TCK-3", "wren", "completed", ago: 8 * h, schedule: 9),
            task(9, "Daily report", "manager", "completed", ago: 9 * h, schedule: 10),
            task(10, "Answer the support tickets", "wren", "completed", ago: 20 * h),
            task(11, "Plan the first quarter", "manager", "rejected", ago: 22 * h),
            task(12, "CRM tickets waiting for iris: TCK-4", "wren", "completed", ago: 23 * h, schedule: 9),
            task(13, "Daily report", "manager", "completed", ago: 5 * d, schedule: 10),
            task(14, "Daily report", "manager", "completed", ago: 5 * d + h, schedule: 10),
            task(15, "Write the release notes", "theo", "completed", ago: 5 * d + 2 * h, accepted: 1),
            task(16, "Write the release notes", "pax", "completed", ago: 5 * d + 3 * h),
            task(17, "Check the backups", "pax", "completed", ago: 5 * d + 4 * h, started: false),
            task(18, "Renew the shop's certificate", "pax", "completed", ago: 20 * d, accepted: 1),
            task(19, "Renew the shop's certificate", "pax", "failed", ago: 20 * d + h),
            task(20, "Monthly invoices", "manager", "completed", ago: 20 * d + 2 * h, schedule: 11),
            task(21, "Monthly invoices", "manager", "completed", ago: 60 * d, schedule: 11),
            task(22, "Move the mail server", "pax", "canceled", ago: 60 * d + h),
            task(23, "Set up the fleet", "manager", "completed", ago: 61 * d, accepted: 0),
            task(24, "Answer today's support tickets", "wren", "working", ago: 0.5 * h),
        ]
    }()

    static func ended(calendar: Calendar) throws -> Ended {
        let tasks: [[String: Any]] = endedTasks.map { t in
            ["id": t.id, "title": t.title, "details": "", "done_when": "Checked", "needs": "none", "goal": "", "owner": t.owner,
             "requester": "manager", "state": t.state, "created": t.created, "attempt": 1, "restarts": 0, "nudge_level": 0,
             "stop_sent": 0, "started": t.started as Any? ?? NSNull(), "last_activity": t.last_activity as Any? ?? NSNull(),
             "accepted": t.accepted as Any? ?? NSNull(), "trigger_id": t.trigger_id as Any? ?? NSNull()]
        }
        let agents: [[String: Any]] = ["manager", "wren", "theo", "pax"].map {
            ["name": $0, "role": $0 == "manager" ? "manager" : "worker", "runtime": "codex", "can": []]
        }
        let state = try HubState.decode(JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "db": "vectors", "time": now, "agents": agents, "tasks": tasks, "holds": [], "outcomes": [],
            "notes": [], "needs": [], "permissions": [], "messages": [], "reports": []]))
        let lanes = ActivityPeriod.allCases.map { period in
            let done = state.activity(agent: nil, period: period, calendar: calendar)[.done] ?? []
            let lane = EndedTasks(done, calendar: calendar)
            return EndedLane(period: period.rawValue, count: done.count, failed: lane.failed.map(\.id), rest: lane.rest,
                             days: lane.days.map { day in
                                 EndedDay(start: day.start, groups: day.groups.map { EndedGroup(title: $0.title, ids: $0.tasks.map(\.id)) })
                             })
        }
        return Ended(now: now, tasks: endedTasks, lanes: lanes)
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
                 role: AgentNames.role(name, roles: roles), capitalized: name.capitalized)
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
        let inline = inlines.map { text in
            let attributed = MessageBlock.inline(text)
            var runs: [Run] = []
            for run in attributed.runs {
                let intent = run.inlinePresentationIntent ?? []
                let one = Run(text: String(attributed[run.range].characters), bold: intent.contains(.stronglyEmphasized),
                              italic: intent.contains(.emphasized), struck: intent.contains(.strikethrough),
                              code: intent.contains(.code), link: run.link?.absoluteString)
                // Runs that differ only by an attribute that no app draws (an image's address) are one run.
                if let last = runs.last, last.bold == one.bold, last.italic == one.italic, last.struck == one.struck,
                   last.code == one.code, last.link == one.link {
                    runs[runs.count - 1] = Run(text: last.text + one.text, bold: one.bold, italic: one.italic,
                                               struck: one.struck, code: one.code, link: one.link)
                } else { runs.append(one) }
            }
            return Inline(text: text, runs: runs)
        }
        // A result's check (FleetTask.checkStatus) and what a task waits for (TaskWords.waitingFor, TaskWords.waiting):
        // one whole sentence each, with the agent's name in its slot.
        var checks: [Check] = []
        for requester in ["owner", "manager", "web-dev"] {
            for (accepted, delivered) in [(nil, nil), (nil, 10.0), (1, 10.0), (0, 10.0)] as [(Int?, Double?)] {
                let json: [String: Any] = [
                    "id": 1, "title": "A task", "details": "", "done_when": "", "needs": "", "goal": "", "owner": "theo",
                    "requester": requester, "state": "completed", "created": 1, "attempt": 1, "restarts": 0,
                    "nudge_level": 0, "stop_sent": 0, "accepted": accepted as Any? ?? NSNull(),
                    "delivered": delivered as Any? ?? NSNull(),
                ]
                let task = try JSONDecoder().decode(FleetTask.self, from: JSONSerialization.data(withJSONObject: json))
                checks.append(Check(requester: requester, accepted: accepted, delivered: delivered, words: task.checkStatus))
            }
        }
        var waits = ["owner", "manager", "web-dev"].map { Wait(requester: $0, waiting_on: nil, words: TaskWords.waitingFor($0)) }
        for (on, requester) in [("juno", "manager"), ("Q-1", "owner"), ("N-2", "web-dev"), ("its screen", "manager")] {
            waits.append(Wait(requester: requester, waiting_on: on, words: TaskWords.waiting(on: on, requester: requester)))
        }
        let document = Document(
            about: "Words that FleetCore makes: AgentNames.label and role with the roles of team.json, String.capitalized, "
                + "MessageBlock.parse and plain, ChatList.plain (the line under an agent's row), ChatList.time and "
                + "activityAge in UTC with two locales, AgentNames.matches (Search) for each typed text, and the runs of "
                + "MessageBlock.inline for each inline text, FleetTask.checkStatus, TaskWords.waitingFor and waiting, and "
                + "the Tasks board's Ended lane of each period (HubState.activity, EndedTasks) in UTC.",
            made_by: "app/Tests/FleetCoreTests/WordsVectorsTests.swift", time_zone: "UTC", names: names, texts: texts,
            times: times, ages: ages, matches: matches, inline: inline,
            checks: checks, waits: waits, ended: try ended(calendar: calendar))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document) + Data("\n".utf8)
    }

    /// A bundle with no table of the apps' words (`app/Localization/`): each lookup gives its English key.
    static let noTable: Bundle = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("words-vectors-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return Bundle(url: folder)!
    }()

    @Test("The words' vectors are what FleetCore gives now")
    func theWordsVectorsAreTheCommittedFile() throws {
        // **English on a Mac of any language** (the Windows coordinator, 13 November 2026): the C# twin's words are
        // English, so no table of the apps' words may reach the words that the vectors hold.
        let made = try Localized.$bundle.withValue(Self.noTable) { try Self.document() }
        if let out = ProcessInfo.processInfo.environment["FOUNDERIZER_VECTORS_OUT"] {
            try made.write(to: URL(fileURLWithPath: out).appendingPathComponent(Self.file))
            return
        }
        let committed = try Data(contentsOf: Self.folder.appendingPathComponent(Self.file))
        #expect(committed == made, "app/vectors/\(Self.file) is not what FleetCore gives: run app/vectors/make_vectors.py")
    }
}
