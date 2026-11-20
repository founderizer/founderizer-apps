import Foundation
import Testing
@testable import FleetCore

/// The hub's lines of a manager's grants are one card in its chat (the owner, 19 November 2026; `ChatGrantPlaces`).
struct ChatGrantsTests {
    private func mine(_ id: String, at created: Double) throws -> ChatPart {
        .entry(.message(try JSONDecoder().decode(OwnerMessage.self, from: JSONSerialization.data(withJSONObject: [
            "request_id": id, "kind": "message", "need_id": NSNull(), "text": "Synthetic", "event_id": 1,
            "created": created, "client": "test", "recipient": "manager",
        ]))))
    }

    /// A line of the manager's: a grant to `agent` when one is named, else its own words.
    private func line(_ id: Int, at created: Double, to agent: String? = nil, repo: String = "example/web",
                      kind: String = "repo", word: String = "GitHub repository") throws -> ChatPart {
        let parts: [String: Any]? = agent.map { ["agent": $0, "resource": "\(kind):\(repo)", "kind": kind, "word": word,
                                                 "title": repo, "level": "write", "words": "write"] }
        let grant: Any = parts ?? NSNull()
        return .entry(.report(try JSONDecoder().decode(ManagerReport.self, from: JSONSerialization.data(withJSONObject: [
            "id": id, "agent": "manager", "text": "Synthetic", "about": agent == nil ? "status" : "grant", "created": created,
            "in_reply_to": NSNull(), "grant": grant,
        ]))))
    }

    @Test("Grant lines that follow each other are one row at the place of the last one, also with a request's card between them, and other words end the run")
    func aRunIsOneRow() throws {
        let rows = [try mine("a", at: 10), try line(1, at: 20), try line(2, at: 30, to: "dev"), .request(7),
                    try line(3, at: 40, to: "dev", repo: "example/api"), try line(4, at: 50, to: "ops"),
                    try line(5, at: 60), try line(6, at: 70, to: "ops"), .ask("a"), try line(8, at: 80, to: "dev")]
        let places = ChatGrantPlaces(rows)
        // The card of request 7 stays where it stands, over the row of the run whose lines came around it.
        #expect(places.rows.map(\.id) == ["message-a", "report-1", "need-7", "grants-2", "report-5", "grants-6", "ask-a", "grants-8"])
        #expect(places.runs.mapValues { $0.map(\.id) } == [2: [2, 3, 4], 6: [6], 8: [8]])
        // The card has the time of its newest line for the marks of a day or an hour.
        #expect(ChatRequestPlaces.times(of: places.rows, raised: [7: 35], granted: places.times) == [10, 20, 35, 50, 60, 70, 70, 80])
        // The card names an agent once, over its rows, in the order in which each agent first got something.
        let card = ChatGrantPlaces.cardRows(places.runs[2] ?? [])
        #expect(card.map(\.id) == [2, 3, 4] && card.map(\.leads) == [true, false, true])
        let mixed = ChatGrantPlaces.cardRows([try line(1, at: 1, to: "dev"), try line(2, at: 2, to: "ops"), try line(3, at: 3, to: "dev")]
            .compactMap { if case .entry(.report(let report)) = $0 { report } else { nil } })
        #expect(mixed.map(\.id) == [1, 3, 2] && mixed.map(\.leads) == [true, false, true])
        // A repository stands by its name; a mail account and a Drive account of one address say which they are.
        let accounts = ChatGrantPlaces.cardRows([try line(1, at: 1, to: "dev"),
                                                 try line(2, at: 2, to: "dev", repo: "a@example.com", kind: "gmail", word: "Gmail"),
                                                 try line(3, at: 3, to: "dev", repo: "a@example.com", kind: "drive", word: "Google Drive"),
                                                 try line(4, at: 4, to: "dev", repo: "web-1", kind: "server", word: "server")]
            .compactMap { if case .entry(.report(let report)) = $0 { report } else { nil } })
        #expect(accounts.map(\.resource) == ["example/web", "Gmail a@example.com", "Google Drive a@example.com", "Server web-1"])
    }

    @Test("Grant lines more than an hour apart, or of two days, are two runs, as the chat's marks of time part its rows")
    func timePartsRuns() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = 86_400.0
        // Each line counts from the line before it: 10:00, 11:00 and 12:00 are one run, more than an hour from its
        // first line to its last; 12:00 and 13:00:01 are not.
        let hours = [try line(1, at: 10 * 3600, to: "dev"), try line(2, at: 11 * 3600, to: "dev"),
                     try line(3, at: 12 * 3600, to: "dev"), try line(4, at: 13 * 3600 + 1, to: "dev")]
        #expect(ChatGrantPlaces(hours, calendar: calendar).rows.map(\.id) == ["grants-1", "grants-4"])
        // 23:50 and 00:10 of the next day are ten minutes apart, and two days.
        let night = [try line(1, at: day - 600, to: "dev"), try line(2, at: day + 600, to: "dev")]
        #expect(ChatGrantPlaces(night, calendar: calendar).rows.map(\.id) == ["grants-1", "grants-2"])
    }
}
