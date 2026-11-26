import Foundation
import Testing
@testable import FleetCore
@testable import Founderizer

/// **The board keeps the times of the newest reading** (`JobColumns`; the column note runs away from the main thread
/// since the owner's "scrolling Fleet Manager chat is SO slow", 25 November 2026): two readings that come close
/// together give the times that the two notes in their order give. A second note made from the times before the first
/// would set a card's time in its new column back to the hub's guess; the first note drawn last would keep the job in
/// its old column.
@Suite(.serialized, .timeLimit(.minutes(1))) struct JobColumnsOrderTests {
    static let now = Double(Int(Date().timeIntervalSince1970))

    /// Task 1 of the reading at `time`: in work, or parked since `since` (the hub's guess of its column's start).
    static func reading(db: String, time: Double, parkedSince since: Double?) throws -> HubState {
        let agents: [[String: Any]] = ["manager", "dev"].map {
            ["name": $0, "role": $0 == "manager" ? "manager" : "worker", "runtime": "codex", "can": []]
        }
        var task: [String: Any] = ["id": 1, "title": "Move the shop", "details": "", "done_when": "Checked",
                                   "needs": "none", "goal": "", "owner": "dev", "requester": "manager",
                                   "state": "working", "created": now - 4 * 3600, "attempt": 1, "restarts": 0,
                                   "nudge_level": 0, "stop_sent": 0, "started": now - 3 * 3600,
                                   "last_activity": now - 60, "works": true]
        if let since {
            task["since"] = since
            task["parked_until"] = now + 3600
            task["works"] = false
        }
        return try HubState.decode(JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "db": db, "time": time, "agents": agents, "tasks": [task], "holds": [],
            "outcomes": [], "notes": [], "needs": [], "permissions": [], "messages": [], "reports": []] as [String: Any]))
    }

    struct Seen: Sendable {
        let drawn: Double, inOrder: Double, guess: Double
        let sameAsInOrder: Bool
    }

    @Test func twoReadingsCloseTogetherKeepTheNewerReadingsTimes() async throws {
        let (seen, _) = try await ViewHost.onMainLoop { () -> Seen? in
            let db = "columns-\(UUID().uuidString)"
            // the first reading sees the job in work; the next, 100 s later, sees it parked since a time before the
            // first reading: the board's time is the first reading's, not the hub's guess
            let first = try Self.reading(db: db, time: Self.now, parkedSince: nil)
            let next = try Self.reading(db: db, time: Self.now + 100, parkedSince: Self.now - 500)
            var inOrder = ColumnTimes()
            inOrder.note(first)
            inOrder.note(next)
            JobColumns.shared.note(first)
            JobColumns.shared.note(next)
            ViewHost.turn(10, until: { !JobColumns.shared.notesOnTheirWay })
            let job = next.jobs(of: nil).first { $0.column == .waiting }
            guard let job else { return nil }
            return Seen(drawn: JobColumns.shared.since(job, hub: db), inOrder: inOrder.since(job, hub: db),
                        guess: job.columnSince, sameAsInOrder: JobColumns.shared.times.sameTimes(as: inOrder))
        }
        let drawn = try #require(seen)
        #expect(drawn.drawn == Self.now)                    // kept from the first reading
        #expect(drawn.drawn == drawn.inOrder)               // the two notes in their order
        #expect(drawn.guess == Self.now - 500)              // what a second note without the first would draw
        #expect(drawn.sameAsInOrder)                        // the newest note is the one drawn
    }
}
