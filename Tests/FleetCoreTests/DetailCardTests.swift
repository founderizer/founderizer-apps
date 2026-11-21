import Foundation
import Testing
@testable import FleetCore

// Explicit test data only: the tasks of two agents, a case of a duty, and a request of the owner's that a task waits on.
struct DetailCardTests {
    /// The hub's time: 13 October 2026, 15:00 UTC.
    private static let now = 1_791_903_600.0

    private func task(_ id: Int, _ state: String, owner: String = "dev", _ more: [String: Any] = [:]) -> [String: Any] {
        let moved = Self.now - 600 + Double(id)
        var row: [String: Any] = ["id": id, "title": "Task \(id)", "details": "", "done_when": "Checked", "needs": "none",
                                  "goal": "", "owner": owner, "requester": "lead", "state": state, "created": moved - 60,
                                  "attempt": 1, "restarts": 0, "nudge_level": 0, "stop_sent": 0, "started": moved,
                                  "last_activity": moved]
        for (key, value) in more { row[key] = value }
        return row
    }

    private func hub(_ tasks: [[String: Any]], needs: [[String: Any]] = [], duties: [[String: Any]] = [],
                     db: String = "test-db") throws -> HubState {
        let agents: [[String: Any]] = ["manager", "lead", "dev"].map {
            ["name": $0, "role": $0 == "manager" ? "manager" : $0 == "lead" ? "lead" : "worker", "runtime": "codex", "can": []]
        }
        return try HubState.decode(JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "db": db, "time": Self.now, "agents": agents, "tasks": tasks, "holds": [],
            "outcomes": [], "notes": [], "needs": needs, "permissions": [], "messages": [], "reports": [],
            "responsibilities": duties]))
    }

    private func job(_ id: String, in state: HubState) throws -> Job { try #require(state.job(id, board: nil)) }

    /// The bug that this catches: a job of one task, or a thing of one task with no case, opens a list of one row in
    /// place of that task; and a job that waits on his open request opens its one task, where the request's own card
    /// should stand first.
    @Test func aJobOfOneTaskOpensThatTaskAndAJobOfSeveralACaseOrARequestOpensTheJob() throws {
        let state = try hub([
            task(1, "completed", ["accepted": 1]),                                    // alone
            task(2, "completed", ["accepted": 1]), task(3, "working", ["follows": 2, "works": true]),   // one job of two
            task(4, "completed", ["accepted": 1]), task(5, "canceled", ["follows": 4]),  // one line: the other was canceled
            task(6, "input-required", ["waiting_on": "Q-7"]),                         // waits on his request 9
            task(7, "completed", ["accepted": 1, "duty_case": 30]),                   // a case of one task
        ], needs: [["id": 9, "title": "Which account?", "why": "", "todo": "", "raised": Self.now - 300, "by": "manager",
                    "answered": NSNull(), "question": 7, "ask": NSNull()]],
           duties: [["agent": "dev", "cases": [], "recent": [["id": 30, "responsibility": 1, "key": "TCK-1", "title": "TCK-1",
                                                              "state": "closed", "closed": Self.now - 60, "closed_by": "dev",
                                                              "outcome": "handled"]]]])
        #expect(try job("task 1", in: state).detail(board: nil) == .task(1))
        #expect(try job("task 2", in: state).detail(board: nil) == .job("task 2", board: nil))
        #expect(try job("task 4", in: state).detail(board: nil) == .task(4))
        #expect(try job("task 6", in: state).detail(board: nil) == .job("task 6", board: nil))
        // The card of one agent's board is opened by its id on that board.
        #expect(state.job("task 2", board: "dev")?.detail(board: "dev") == .job("task 2", board: "dev"))
        // A row of the card Work: a thing of one task opens it, one of several tasks or with a case is the job level.
        #expect(state.detail(of: .task(1), agent: "dev") == .task(1))
        #expect(state.detail(of: .task(2), agent: "dev") == .work("dev", .task(2)))
        #expect(state.detail(of: .dutyCase(30), agent: "dev") == .work("dev", .dutyCase(30)))
        // The job level of the job that waits draws its request first.
        #expect(state.levels(of: DetailCard(.job("task 6", board: nil))).shown?.request == 9)
        #expect(state.levels(of: DetailCard(.job("task 2", board: nil))).shown?.request == nil)
    }

    /// The bug that this catches: the back link of a task names the wrong job, or none, after a row of its facts opened
    /// another task, or names the job that shows for a task that an opener outside the card opened (the search card,
    /// `setup_show`); and Esc closes a task that came from a job, where it should show that job again.
    @Test func aTaskOpenedFromAJobKeepsThatJobUnderItAndEscShowsTheJobAgain() {
        let job = DetailPlace.job("case 30", board: nil)
        let fromJob = DetailCard.showing(.task(7), over: DetailCard(job), inCard: true)
        #expect(fromJob.under == job && fromJob.shown == .task(7))
        // A row of the facts (Follow-up to, Parent task, a subtask): the task takes the place of the one that shows.
        let followUp = DetailCard.showing(.task(8), over: fromJob, inCard: true)
        #expect(followUp.under == job && followUp.shown == .task(8))
        #expect(followUp.back == DetailCard(job))
        #expect(followUp.back?.back == nil)
        // A task opened outside a card, and a task that a row of its facts opens, have no job under them.
        let alone = DetailCard.showing(.task(8), over: DetailCard.showing(.task(7), over: nil, inCard: false), inCard: true)
        #expect(alone.under == nil && alone.shown == .task(8) && alone.back == nil)
        // An opener outside the card, while a job's card shows, opens the task fresh: it is no row of that job.
        #expect(DetailCard.showing(.task(9), over: DetailCard(job), inCard: false) == DetailCard(.task(9)))
        #expect(DetailCard.showing(.task(9), over: fromJob, inCard: false) == DetailCard(.task(9)))
        // A job takes the whole card.
        #expect(DetailCard.showing(.work("dev", .task(2)), over: followUp, inCard: true) == DetailCard(.work("dev", .task(2))))
    }

    /// The bug that this catches: a card whose task or job the hub lists no more, or that a reading of another hub
    /// generation or none at all left, stands empty over the window until Esc ends it.
    @Test func aCardWhoseTaskTheHubListsNoMoreCloses() throws {
        let before = try hub([task(1, "completed", ["accepted": 1]), task(2, "working", ["follows": 1, "works": true])])
        let card = DetailCard.showing(.task(2), over: DetailCard(.job("task 1", board: nil)), inCard: true)
        #expect(card.kept(in: before, before: before)?.card == card)
        #expect(card.kept(in: before, before: before)?.levels.under?.title == "Task 1")
        // The task went.
        let gone = try hub([task(1, "completed", ["accepted": 1])])
        #expect(card.kept(in: gone, before: before) == nil)
        // Another generation of the hub numbers its tasks again, and a moment with no reading shows nothing.
        #expect(card.kept(in: try hub([task(1, "completed"), task(2, "working", ["follows": 1])], db: "other-db"),
                          before: before) == nil)
        #expect(card.kept(in: nil, before: before) == nil)
        // The job under it went (its task opened a case, so the board has the case's card): the task stays, alone.
        let moved = try hub([task(1, "completed", ["accepted": 1, "duty_case": 31]), task(2, "working", ["follows": 1, "works": true])],
                            duties: [["agent": "dev", "cases": [["id": 31, "responsibility": 1, "key": "TCK-2", "title": "TCK-2",
                                                                 "state": "open"]], "recent": []]])
        #expect(card.kept(in: moved, before: before)?.card == DetailCard(.task(2)))
        // A thing of the panel follows its task to the case that the task opened, as its row does.
        let thing = DetailCard(.work("dev", .task(1)))
        #expect(thing.kept(in: moved, before: before)?.card == thing)
        #expect(thing.kept(in: moved, before: before)?.levels.shown?.title == "TCK-2")
    }
}
