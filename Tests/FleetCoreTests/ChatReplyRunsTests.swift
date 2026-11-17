import Foundation
import Testing
@testable import FleetCore

/// Copy and the age of a reply show only under the last reply of a run (the owner, 16 November 2026). Explicit test
/// data only.
struct ChatReplyRunsTests {
    private func reply(_ id: Int, at created: Double) throws -> ChatPart {
        .entry(.report(try JSONDecoder().decode(ManagerReport.self, from: JSONSerialization.data(withJSONObject: [
            "id": id, "agent": "manager", "text": "Synthetic", "about": "", "created": created, "in_reply_to": NSNull(),
        ]))))
    }

    private func mine(_ id: String, at created: Double) throws -> ChatPart {
        .entry(.message(try JSONDecoder().decode(OwnerMessage.self, from: JSONSerialization.data(withJSONObject: [
            "request_id": id, "kind": "message", "need_id": NSNull(), "text": "Synthetic", "event_id": 1,
            "created": created, "client": "test", "recipient": "manager",
        ]))))
    }

    private func ends(_ rows: [ChatPart], stamped: Set<Int> = []) -> [Bool] {
        let marks = rows.indices.map { stamped.contains($0) }
        return rows.indices.map { ChatPart.endsReplies(at: $0, in: rows, stamped: marks) }
    }

    @Test("Of two replies in a row, only the second has Copy and its age")
    func twoRepliesInARow() throws {
        let rows = [try mine("a", at: 10), try reply(1, at: 20), try reply(2, at: 30)]
        #expect(ends(rows) == [false, false, true])
    }

    @Test("His message, a request's card and the row of an ask each end a run")
    func otherRowsEndARun() throws {
        let rows = [try reply(1, at: 10), try mine("a", at: 20), try reply(2, at: 30), .request(7),
                    try reply(3, at: 40), .ask("T-1"), try reply(4, at: 50)]
        #expect(ends(rows) == [true, false, true, false, true, false, true])
    }

    @Test("A mark of the day or the hour between two replies ends the first one's run")
    func aStampEndsARun() throws {
        let rows = [try reply(1, at: 10), try reply(2, at: 10 + 7200), try reply(3, at: 10 + 7300)]
        #expect(ends(rows, stamped: [0, 1]) == [true, false, true])
    }

    @Test("A row out of range is no reply")
    func outOfRange() throws {
        #expect(!ChatPart.endsReplies(at: 3, in: [try reply(1, at: 10)], stamped: []))
    }
}
