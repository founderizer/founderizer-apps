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

    /// The owner, 17 November 2026, with the pointer on the first of two replies: "I should see the time and the copy
    /// button at the bottom of the second paragraph!"
    @Test("Each reply of a run hovers its run, and the run keeps its id when a reply comes under its last")
    func eachReplyNamesItsRun() throws {
        let rows = [try mine("a", at: 10), try reply(1, at: 20), try reply(2, at: 30), .request(7), try reply(3, at: 40),
                    try reply(4, at: 40 + 7200)]
        let marks = rows.indices.map { $0 == 5 }
        #expect(ChatPart.replyRuns(in: rows, stamped: marks) == [nil, "report-1", "report-1", nil, "report-3", "report-4"])
        let more = rows + [try reply(5, at: 40 + 7300)]
        #expect(ChatPart.replyRuns(in: more, stamped: marks + [false]).last == "report-4")
    }

    @Test("A pointer that goes from one reply to the next shows the footer of the run it is on, whichever it tells first")
    func thePointerMovesInsideARun() {
        var hover = ChatRunHover()
        hover.hover("report-1", run: "report-1", inside: true)
        hover.hover("report-2", run: "report-1", inside: true)
        hover.hover("report-1", run: "report-1", inside: false)
        #expect(hover.run == "report-1")
        hover.hover("report-4", run: "report-4", inside: true)
        hover.hover("report-2", run: "report-1", inside: false)
        #expect(hover.run == "report-4")
        hover.hover("report-4", run: "report-4", inside: false)
        #expect(hover.run == nil)
    }

    @Test("A row out of range is no reply")
    func outOfRange() throws {
        #expect(!ChatPart.endsReplies(at: 3, in: [try reply(1, at: 10)], stamped: []))
    }
}
