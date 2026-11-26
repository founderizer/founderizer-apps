import FleetCore
import Foundation
import Testing
@testable import Founderizer

/// **A request's answered mark and its task are worked out once for each reading** (`FleetStore.answered(_:)`; the owner,
/// 25 November 2026: "scrolling Fleet Manager chat is SO slow"): a card reads them at each of its draws, and the next
/// reading of the hub must give its own mark at once, never the mark of the reading before it.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AnsweredOncePerReadingTests {
    static let now = Int(Date().timeIntervalSince1970)

    /// Request 7, which he answered, and task 41, which his answer let go on, in the state `taskState`.
    static func reading(db: String, taskState: String) throws -> HubState {
        let agents: [[String: Any]] = [
            ["name": "manager", "role": "manager", "runtime": "claude", "can": [], "placed": true],
            ["name": "devops", "role": "worker", "runtime": "claude", "can": [], "placed": true]]
        let task: [String: Any] = ["id": 41, "title": "Move the shop", "details": "", "done_when": "Checked",
                                   "needs": "none", "goal": "", "owner": "devops", "requester": "manager",
                                   "state": taskState, "created": now - 2000, "attempt": 1, "restarts": 0,
                                   "nudge_level": 0, "stop_sent": 0, "started": now - 1900, "last_activity": now - 30]
        let need: [String: Any] = ["id": 7, "title": "Move the shop?", "why": "", "todo": "", "raised": now - 300,
                                   "by": "manager", "options": ["Yes", "No"], "answered": now - 200, "answer": "Yes",
                                   "chosen": 0, "task": 41]
        return try HubState.decode(JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "db": db, "time": now, "agents": agents, "tasks": [task], "holds": [], "outcomes": [],
            "notes": [], "needs": [need], "permissions": [], "messages": [], "reports": [],
            "ui_features": [AnsweredMark.feature]] as [String: Any]))
    }

    struct Seen: Sendable, Equatable {
        let firstIsTheReadingsMark: Bool
        let firstTaskWorks: Bool
        let sameReadingSameMark: Bool
        let nextIsItsReadingsMark: Bool
        let nextMarkChanged: Bool
        let nextTaskEnded: Bool
    }

    @Test func eachReadingGivesItsOwnMarkAndTask() async throws {
        let (seen, _) = try await ViewHost.onMainLoop { () -> Seen in
            let db = "answered-\(UUID().uuidString)"
            let working = try Self.reading(db: db, taskState: "working")
            let store = ViewHost.store(working)
            guard let need = store.state?.needs.first else { throw CocoaError(.fileReadCorruptFile) }
            let first = store.answered(need), again = store.answered(need)
            // the hub's next reading: the task that his answer let go on has ended
            let ended = try Self.reading(db: db, taskState: "completed")
            store.state = ended
            guard let endedNeed = store.state?.needs.first else { throw CocoaError(.fileReadCorruptFile) }
            let next = store.answered(endedNeed)
            return Seen(firstIsTheReadingsMark: first.mark == need.answeredMark(in: working),
                        firstTaskWorks: first.task?.state == "working", sameReadingSameMark: again.mark == first.mark,
                        nextIsItsReadingsMark: next.mark == endedNeed.answeredMark(in: ended),
                        nextMarkChanged: next.mark != first.mark, nextTaskEnded: next.task?.state == "completed")
        }
        #expect(seen == Seen(firstIsTheReadingsMark: true, firstTaskWorks: true, sameReadingSameMark: true,
                             nextIsItsReadingsMark: true, nextMarkChanged: true, nextTaskEnded: true))
    }
}
