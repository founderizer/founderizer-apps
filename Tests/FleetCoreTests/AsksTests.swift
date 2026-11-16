import Foundation
import Testing
@testable import FleetCore

// Explicit test data only: messages of the owner's, the tasks that name them, and requests that wait for him.
struct AsksTests {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// The hub's time: 13 October 2026, 15:00 UTC.
    private static let now = at(13, 15)

    private static func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Double {
        utc.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!.timeIntervalSince1970
    }

    private func task(_ id: Int, _ state: String, ask: String? = nil, owner: String = "dev", last: Double? = nil,
                      waitingOn: String? = nil, accepted: Int? = nil, title: String? = nil, parked: Double? = nil,
                      follows: Int? = nil, works: Bool? = nil, doing: String? = nil, parent: Int? = nil,
                      checked: Double? = nil) -> [String: Any] {
        let moved = last ?? Self.now - 600
        var row: [String: Any] = ["id": id, "title": title ?? "Task \(id)", "details": "", "done_when": "Checked", "needs": "none",
                                  "goal": "", "owner": owner, "requester": "manager", "state": state, "created": moved - 60,
                                  "attempt": 1, "restarts": 0, "nudge_level": 0, "stop_sent": 0]
        row["started"] = state == "submitted" ? nil : moved
        row["last_activity"] = state == "submitted" ? nil : moved
        row["waiting_on"] = waitingOn; row["accepted"] = accepted; row["parked_until"] = parked
        row["follows"] = follows; row["works"] = works; row["doing"] = doing; row["ask"] = ask
        row["parent"] = parent; row["checked_at"] = checked
        return row
    }

    private func message(_ id: String, asked: String?, to recipient: String = "lead", created: Double? = nil) -> [String: Any] {
        ["request_id": id, "recipient": recipient, "kind": "message", "text": "Words of \(id)", "event_id": 1,
         "created": created ?? Self.now - 3600, "client": "test", "asked": asked ?? NSNull()]
    }

    private func need(_ id: Int, ask: String? = nil, question: Int? = nil, answered: Double? = nil) -> [String: Any] {
        ["id": id, "title": "Need \(id)", "why": "", "todo": "", "raised": Self.now - 300, "by": "manager",
         "answered": answered ?? NSNull(), "question": question ?? NSNull(), "ask": ask ?? NSNull()]
    }

    private func hub(_ tasks: [[String: Any]], messages: [[String: Any]] = [], needs: [[String: Any]] = [],
                     outcomes: [[String: Any]] = []) throws -> HubState {
        let agents: [[String: Any]] = ["manager", "lead", "dev", "ops"].map {
            ["name": $0, "role": $0 == "manager" ? "manager" : $0 == "lead" ? "lead" : "worker", "runtime": "codex", "can": []]
        }
        return try HubState.decode(JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "db": "test-db", "time": Self.now, "agents": agents, "tasks": tasks, "holds": [],
            "outcomes": outcomes, "notes": [], "needs": needs, "permissions": [], "messages": messages, "reports": []]))
    }

    private func ids(_ board: [ActivityColumn: [BoardItem]], _ column: ActivityColumn) -> [String] { board[column, default: []].map(\.id) }

    @Test func theTasksOfOneMessageAreOneAskUnderItsNameAndItsAgent() throws {
        let state = try hub([
            task(1, "completed", ask: "a", owner: "lead", last: Self.now - 900, accepted: 1),
            task(2, "working", ask: "a", last: Self.now - 300, follows: 1, works: true, doing: "Runs the tests"),
            task(3, "working", ask: "b", owner: "ops", works: true),
            task(4, "working"),                                     // work that no message of his began
        ], messages: [message("a", asked: "Move the images", created: Self.now - 7200), message("b", asked: "Check the disk", to: "ops"),
                      message("c", asked: nil)])
        let asks = state.asks
        #expect(asks.map(\.id) == ["b", "a"])                       // the newest ask first
        let ask = try #require(asks.last)
        #expect(ask.title == "Move the images" && ask.agent == "lead" && ask.created == Self.now - 7200)
        #expect(ask.tasks.map(\.id) == [2, 1] && ask.open.map(\.id) == [2])      // the task that moved last first
        #expect(ask.column == .inProgress && ask.working?.id == 2 && ask.wait == nil && ask.failed == nil && !ask.isOver)
        #expect(ask.activityTime == Self.now - 300)
        #expect(try hub([task(4, "working")]).asks.isEmpty)
    }

    @Test func anAskWhoseMessageThisReadingDoesNotHoldKeepsItsOldestTasksWords() throws {
        let ask = try #require(try hub([
            task(8, "working", ask: "gone", owner: "ops", title: "The second step"),
            task(5, "completed", ask: "gone", owner: "dev", accepted: 1, title: "The first step"),
        ]).asks.first)
        #expect(ask.title == "The first step" && ask.agent == "dev" && ask.tasks.count == 2)
    }

    @Test func anAskStandsWhereItsTasksStand() throws {
        let state = try hub([
            task(1, "working", ask: "works", works: true),
            task(2, "completed", ask: "works", accepted: 1),
            // parked until a time, and one that waits for its turn: it only waits, until the earlier time
            task(3, "working", ask: "parked", parked: Self.now + 7200, works: false),
            task(4, "working", ask: "parked", parked: Self.now + 3600, works: false),
            // one task works, and another waits for his answer: what waits for him comes first
            task(5, "working", ask: "his", works: true),
            task(6, "input-required", ask: "his", waitingOn: "N-7"),
            // a request that names the ask, with no task that waits on it
            task(7, "working", ask: "card", works: true),
            task(8, "completed", ask: "over", accepted: 1),
            task(9, "canceled", ask: "over"),
        ], messages: ["works", "parked", "his", "card", "over"].map { message($0, asked: "Ask \($0)") },
           needs: [need(7), need(8, ask: "card"), need(9, ask: "works", answered: Self.now - 60)])
        let asks = Dictionary(uniqueKeysWithValues: state.asks.map { ($0.id, $0) })
        #expect(asks["works"]?.column == .inProgress && asks["works"]?.wait == nil)       // an answered request waits for nobody
        #expect(asks["parked"]?.column == .waiting && asks["parked"]?.until == Self.now + 3600 && asks["parked"]?.working == nil)
        #expect(asks["his"]?.column == .waiting && asks["his"]?.wait == .request(id: 7, title: "Need 7"))
        #expect(asks["card"]?.column == .waiting && asks["card"]?.wait == .request(id: 8, title: "Need 8"))
        #expect(asks["over"]?.column == .done && asks["over"]?.isOver == true && asks["over"]?.open.isEmpty == true)
        #expect(asks["over"]?.failed == nil)                        // somebody chose to cancel: no failure
    }

    @Test func aResultThatALaterTaskPutRightIsNoFailureOfTheAsk() throws {
        let state = try hub([
            task(1, "failed", ask: "fixed", last: Self.now - 900),
            task(2, "completed", ask: "fixed", last: Self.now - 300, accepted: 1, follows: 1),
            task(3, "completed", ask: "broken", last: Self.now - 900, accepted: 1),
            task(4, "completed", ask: "broken", last: Self.now - 300, accepted: 0, follows: 3),
            task(5, "failed", ask: "open", last: Self.now - 900),
            task(6, "working", ask: "open", follows: 5, works: true),
        ], messages: ["fixed", "broken", "open"].map { message($0, asked: "Ask \($0)") })
        let asks = Dictionary(uniqueKeysWithValues: state.asks.map { ($0.id, $0) })
        #expect(asks["fixed"]?.column == .done && asks["fixed"]?.failed == nil)
        #expect(asks["broken"]?.column == .done && asks["broken"]?.failed?.id == 4)
        #expect(asks["open"]?.column == .inProgress && asks["open"]?.failed == nil)    // an open ask has no result yet
    }

    @Test func theBoardHasOneCardForEachAskAndOneForEveryOtherTask() throws {
        let state = try hub([
            task(1, "working", ask: "a", last: Self.now - 500, works: true),
            task(2, "completed", ask: "a", last: Self.now - 100, accepted: 1),
            task(3, "working", last: Self.now - 200),
            task(4, "input-required", ask: "b", last: Self.now - 86_400 * 9, waitingOn: "N-7"),      // nine days ago, and it waits for him
            task(5, "submitted"),
            task(6, "completed", ask: "c", last: Self.now - 400, accepted: 1),
            task(7, "completed", last: Self.now - 300, accepted: 1),
            task(8, "completed", ask: "old", last: Self.now - 86_400 * 9, accepted: 1),
        ], messages: ["a", "b", "c", "old"].map { message($0, asked: "Ask \($0)") }, needs: [need(7)])
        let board = state.board(period: .week, calendar: Self.utc)
        // An ask moved when its newest task moved: its card stands before the task that moved earlier.
        #expect(ids(board, .inProgress) == ["ask a", "task 3"])
        // What waits for him first, whatever the period; then the rest.
        #expect(ids(board, .waiting) == ["ask b", "task 5"])
        #expect(ids(board, .done) == ["task 7", "ask c"])           // the ask that ended nine days ago is outside the period
        // An ask that is open shows whatever the period, also when it waits for nobody.
        let parked = try hub([task(1, "working", ask: "p", last: Self.now - 86_400 * 9, parked: Self.now + 3600, works: false),
                              task(2, "working", last: Self.now - 86_400 * 9, parked: Self.now + 3600, works: false)],
                             messages: [message("p", asked: "Parked for long")])
        #expect(ids(parked.board(period: .today, calendar: Self.utc), .waiting) == ["ask p"])
        #expect(parked.asks.first?.lead?.id == 1)
        #expect(ids(state.board(period: .all, calendar: Self.utc), .done) == ["task 7", "ask c", "ask old"])
        // No task of an ask is a card of its own.
        let cards = board.values.flatMap { $0 }.compactMap { item -> Int? in if case .task(let task) = item { task.id } else { nil } }
        #expect(Set(cards) == [3, 5, 7])
    }

    @Test func endedHasOneRowForAnAskAndTheRowsOfTasksAsBefore() throws {
        let state = try hub([
            task(1, "completed", ask: "fine", last: Self.at(13, 10), accepted: 1, title: "First part"),
            task(2, "completed", ask: "fine", last: Self.at(13, 12), accepted: 1, title: "Second part"),
            task(3, "failed", ask: "bad", last: Self.at(13, 11), title: "The step that failed"),
            task(4, "completed", last: Self.at(13, 13), accepted: 1, title: "A daily check"),
            task(5, "failed", last: Self.at(13, 9), title: "A check that failed"),
            task(6, "completed", ask: "day", last: Self.at(12, 9), accepted: 1),
        ], messages: [message("fine", asked: "Move the images"), message("bad", asked: "Write the invoice", to: "ops"),
                      message("day", asked: "Yesterday's thing")])
        let ended = EndedTasks(items: state.board(period: .all, calendar: Self.utc)[.done] ?? [], calendar: Self.utc)
        // The ask whose task did not succeed, under its own name and the agent that he asked, with that task.
        #expect(ended.failedRows.map(\.title) == ["Write the invoice", "A check that failed"])
        #expect(ended.failedRows.map(\.owner) == ["ops", "dev"] && ended.failedRows.map(\.task.id) == [3, 5])
        #expect(ended.failed.map(\.id) == [3, 5])
        // Every other one behind "more": an ask is one row and counts as one, on the day that its last task ended.
        #expect(ended.rest == 3 && ended.days.count == 2)
        let today = ended.days[0].groups
        #expect(today.map(\.title) == ["A daily check", "Move the images"])
        #expect(today[1].tasks.map(\.id) == [2, 1] && today[1].owner == "lead" && today[0].owner == "dev")
        #expect(ended.days[1].groups.map(\.title) == ["Yesterday's thing"])
        // With no ask, the column is what it was.
        let plain = EndedTasks(state.tasks.filter { $0.ask == nil }, calendar: Self.utc)
        #expect(plain.failed.map(\.id) == [5] && plain.rest == 1 && plain.failedRows.map(\.title) == ["A check that failed"])
    }

    @Test func aCanceledFollowUpPutsNothingRightAndAnAcceptedTaskCoversItsSubtasks() throws {
        let state = try hub([
            // the fix of a failed task was canceled: the failure still has the last word
            task(1, "failed", ask: "still", last: Self.now - 900),
            task(2, "canceled", ask: "still", last: Self.now - 300, follows: 1),
            // every chain of it ended with a task that somebody canceled
            task(3, "canceled", ask: "dropped"),
            // a subtask failed, and the task over it was delivered and accepted
            task(4, "completed", ask: "covered", owner: "lead", last: Self.now - 200, accepted: 1),
            task(5, "failed", ask: "covered", last: Self.now - 400, parent: 4),
            task(6, "completed", ask: "covered", last: Self.now - 350, parent: 4),      // and one result with no check
        ], messages: ["still", "dropped", "covered"].map { message($0, asked: "Ask \($0)") })
        let asks = Dictionary(uniqueKeysWithValues: state.asks.map { ($0.id, $0) })
        #expect(asks["still"]?.failed?.id == 1 && asks["still"]?.canceled == false)
        #expect(asks["dropped"]?.canceled == true && asks["dropped"]?.failed == nil && asks["dropped"]?.isOver == true)
        #expect(asks["covered"]?.failed == nil && asks["covered"]?.unchecked == false && asks["covered"]?.canceled == false)
        let card = AskedCard(state.asks, agent: "lead", after: 0)
        #expect(Dictionary(uniqueKeysWithValues: card.rows.map { ($0.id, $0.mark) }) == ["still": .failed, "covered": .done])
        #expect(card.rows.first { $0.id == "still" }?.task == 1 && card.waiting == 0)
    }

    @Test func theLastWordOfAnAskIsATaskThatIsNoSubtaskAndThatNothingPutRight() throws {
        let state = try hub([
            // the lead's task was canceled, and a subtask of it had ended well: somebody chose to end the whole
            task(1, "canceled", ask: "ended", owner: "lead"),
            task(2, "completed", ask: "ended", accepted: 1, parent: 1),
            // a result that was not accepted, with a failed subtask, and a later task that followed it and was accepted
            task(3, "completed", ask: "right", owner: "lead", last: Self.now - 900, accepted: 0),
            task(4, "failed", ask: "right", last: Self.now - 950, parent: 3),
            task(5, "completed", ask: "right", owner: "lead", last: Self.now - 100, accepted: 1, follows: 3),
            // two tasks followed one failure: one was canceled, the other put it right
            task(6, "failed", ask: "two", last: Self.now - 900),
            task(7, "canceled", ask: "two", last: Self.now - 500, follows: 6),
            task(8, "completed", ask: "two", last: Self.now - 100, accepted: 1, follows: 6),
            // a later task put right a failed subtask: the task over that subtask has no last word any more
            task(9, "failed", ask: "under", owner: "lead", last: Self.now - 900),
            task(10, "failed", ask: "under", last: Self.now - 950, parent: 9),
            task(11, "completed", ask: "under", last: Self.now - 100, accepted: 1, follows: 10),
            // a subtask failed, and the result of the task over it waits for its check: nothing is said yet
            task(12, "completed", ask: "soon", owner: "lead", last: Self.now - 100),
            task(13, "failed", ask: "soon", last: Self.now - 200, parent: 12),
            // the first fix of a failure was canceled, and a second fix followed that canceled one
            task(14, "failed", ask: "chain", last: Self.now - 900),
            task(15, "canceled", ask: "chain", last: Self.now - 500, follows: 14),
            task(16, "completed", ask: "chain", last: Self.now - 100, accepted: 1, follows: 15),
        ], messages: ["ended", "right", "two", "under", "soon", "chain"].map { message($0, asked: "Ask \($0)") })
        let asks = Dictionary(uniqueKeysWithValues: state.asks.map { ($0.id, $0) })
        #expect(asks["ended"]?.canceled == true && asks["ended"]?.failed == nil)
        for id in ["right", "two", "under", "chain"] {
            #expect(asks[id]?.failed == nil && asks[id]?.canceled == false && asks[id]?.unchecked == false, "\(id)")
        }
        #expect(asks["soon"]?.failed == nil && asks["soon"]?.unchecked == true)
        let card = AskedCard(state.asks, agent: "lead", after: 0)
        #expect(Dictionary(uniqueKeysWithValues: card.rows.map { ($0.id, $0.mark) })
                == ["right": .done, "two": .done, "under": .done, "chain": .done])
    }

    @Test func aStalledTaskIsInProgressWithAMarkThatStandsStill() throws {
        var stalled = task(1, "working", ask: "a", works: true)
        stalled["stalled_since"] = Self.now - 300
        let row = try #require(AskedCard(try hub([stalled], messages: [message("a", asked: "The thing")]).asks, agent: "lead", after: 0).rows.first)
        #expect(row.mark == .working && !row.moves)
    }

    @Test func anAskThatWaitsForHimOpensTheTaskThatWaits() throws {
        // A task of it ended with an outcome that nobody knows, and a later task of it works.
        let state = try hub([task(1, "completed", ask: "a", last: Self.now - 900),
                             task(2, "working", ask: "a", last: Self.now - 100, works: true)],
                            messages: [message("a", asked: "The thing")],
                            outcomes: [["id": 1, "task": 1, "attempt": 1, "title": "Sent the mail", "kind": "send", "state": "unknown"]])
        let ask = try #require(state.asks.first)
        #expect(ask.wait == .outcome && ask.waitTask?.id == 1 && ask.lead?.id == 1 && ask.column == .waiting)
        let row = try #require(AskedCard(state.asks, agent: "lead", after: 0).rows.first)
        #expect(row.mark == .waitsForOwner && row.task == 1 && row.request == nil)
    }

    @Test func theCardAskedShowsARowOnlyWhileItHasNews() throws {
        let state = try hub([
            task(1, "input-required", ask: "his", owner: "dev", waitingOn: "N-7"),
            task(2, "working", ask: "works", owner: "dev", works: true, doing: "Runs the tests"),
            task(3, "working", ask: "parked", parked: Self.now + 3600, works: false),
            task(4, "submitted", ask: "queued"),
            task(5, "completed", ask: "done", last: Self.now - 100, accepted: 1),
            task(6, "failed", ask: "failed", last: Self.now - 200),
            task(7, "completed", ask: "seen", last: Self.now - 300, accepted: 1),
            task(8, "completed", ask: "before", last: Self.now - 5000, accepted: 1),
            task(9, "working", ask: "other", owner: "ops", works: true),
            task(10, "completed", ask: "unchecked", last: Self.now - 50),         // delivered, and its check is not made yet
            task(11, "canceled", ask: "dropped", last: Self.now - 40),
        ], messages: [message("his", asked: "The answer", created: Self.now - 10), message("works", asked: "The work", created: Self.now - 20),
                      message("parked", asked: "Parked", created: Self.now - 30), message("queued", asked: "Queued", created: Self.now - 40),
                      message("done", asked: "The done one", created: Self.now - 50), message("failed", asked: "The failed one", created: Self.now - 60),
                      message("seen", asked: "Seen", created: Self.now - 70), message("before", asked: "Before", created: Self.now - 80),
                      message("unchecked", asked: "Unchecked", created: Self.now - 90), message("dropped", asked: "Dropped", created: Self.now - 95),
                      message("other", asked: "Another agent's", to: "ops")],
           needs: [need(7)])
        // He has seen what ended up to 250 seconds ago.
        let card = AskedCard(state.asks, agent: "lead", after: Self.now - 250)
        // The order is the order in which he asked, the newest first.
        #expect(card.rows.map(\.id) == ["his", "works", "done", "failed"])
        #expect(card.rows.map(\.mark) == [.waitsForOwner, .working, .done, .failed])
        // Parked, and queued. The one whose check is not made and the one that somebody canceled say nothing.
        #expect(card.waiting == 2 && !card.isEmpty)
        #expect(card.rows[0].request == 7 && card.rows[0].words == "Need 7" && card.rows[0].task == 1)
        #expect(card.rows[1].worker == "dev" && card.rows[1].doing == "Runs the tests" && card.rows[1].task == 2)
        #expect(card.rows[1].line.hasSuffix(" · Runs the tests") && card.rows[1].moves)
        #expect(card.rows[3].failedWord != nil && card.rows[3].task == 6 && card.rows[3].line == card.rows[3].failedWord)
        // In the chat of the agent that works on it, the line does not say that agent again; and a task between two
        // turns is still in work, with a mark that stands still.
        let own = try hub([task(1, "working", ask: "a", owner: "dev", works: true, doing: "Runs the tests"),
                           task(2, "working", ask: "b", owner: "dev", works: false)],
                          messages: [message("a", asked: "The work", to: "dev", created: Self.now - 10),
                                     message("b", asked: "Between turns", to: "dev", created: Self.now - 20)])
        let mine = AskedCard(own.asks, agent: "dev", after: 0)
        #expect(mine.rows.map(\.line) == ["Runs the tests", ""] && mine.rows.map(\.moves) == [true, false])
        #expect(mine.rows.map(\.worker) == [nil, nil] && mine.waiting == 0)
        // What ended and showed is what he has seen once he leaves the chat: up to the newest end of the card.
        #expect(card.endedAt == Self.now - 100)
        let later = AskedCard(state.asks, agent: "lead", after: Self.now - 100)
        #expect(later.rows.map(\.id) == ["his", "works"] && later.waiting == 2 && later.endedAt == nil)
        // A later task of an ask that he saw done ends: its last word is newer, and it shows again.
        let again = try hub([task(7, "completed", ask: "seen", last: Self.now - 300, accepted: 1),
                             task(12, "completed", ask: "seen", last: Self.now - 20, accepted: 1, follows: 7)],
                            messages: [message("seen", asked: "Seen")])
        #expect(AskedCard(again.asks, agent: "lead", after: Self.now - 100).rows.map(\.end) == [Self.now - 20])
        // A result that was delivered before he looked and that its requester checked after it: the check is its last
        // word, so it shows then.
        let checked = try hub([task(10, "completed", ask: "unchecked", last: Self.now - 500, accepted: 1, checked: Self.now - 30)],
                              messages: [message("unchecked", asked: "Unchecked")])
        #expect(AskedCard(checked.asks, agent: "lead", after: Self.now - 100).rows.map(\.mark) == [.done])
        // Another agent's chat has that agent's asks only, and an agent with none has no card.
        #expect(AskedCard(state.asks, agent: "ops", after: 0).rows.map(\.id) == ["other"])
        #expect(AskedCard(state.asks, agent: "manager", after: 0).isEmpty)
        // A Mac that has drawn no card for this fleet yet shows nothing that ended.
        #expect(AskedCard(state.asks, agent: "lead", after: .infinity).rows.map(\.id) == ["his", "works"])
        // An ask whose result is not checked yet is over on the board, and no failure.
        let unchecked = try #require(state.asks.first { $0.id == "unchecked" })
        #expect(unchecked.isOver && unchecked.unchecked && unchecked.failed == nil)
    }
}
