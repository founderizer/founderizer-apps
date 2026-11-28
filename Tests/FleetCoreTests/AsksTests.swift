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
                      checked: Double? = nil, delivered: Double? = nil, plain: String? = nil) -> [String: Any] {
        let moved = last ?? Self.now - 600
        var row: [String: Any] = ["id": id, "title": title ?? "Task \(id)", "details": "", "done_when": "Checked", "needs": "none",
                                  "goal": "", "owner": owner, "requester": "manager", "state": state, "created": moved - 60,
                                  "attempt": 1, "restarts": 0, "nudge_level": 0, "stop_sent": 0]
        row["started"] = state == "submitted" ? nil : moved
        row["last_activity"] = state == "submitted" ? nil : moved
        row["waiting_on"] = waitingOn; row["accepted"] = accepted; row["parked_until"] = parked
        row["follows"] = follows; row["works"] = works; row["doing"] = doing; row["ask"] = ask
        row["parent"] = parent; row["checked_at"] = checked; row["delivered"] = delivered; row["plain"] = plain
        return row
    }

    /// `ask`: the first message of the earlier ask that this one goes on with (owner feature `ask_follow_ups`).
    private func message(_ id: String, asked: String?, to recipient: String = "lead", created: Double? = nil,
                         ask: String? = nil) -> [String: Any] {
        ["request_id": id, "recipient": recipient, "kind": "message", "text": "Words of \(id)", "event_id": 1,
         "created": created ?? Self.now - 3600, "client": "test", "asked": asked ?? NSNull(), "ask": ask ?? NSNull()]
    }

    private func need(_ id: Int, ask: String? = nil, question: Int? = nil, answered: Double? = nil) -> [String: Any] {
        ["id": id, "title": "Need \(id)", "why": "", "todo": "", "raised": Self.now - 300, "by": "manager",
         "answered": answered ?? NSNull(), "question": question ?? NSNull(), "ask": ask ?? NSNull()]
    }

    /// `asks`: his list "Asked by me" (`owner_asks`), and `features` the hub's, which name `ask_follow_ups` for it.
    private func hub(_ tasks: [[String: Any]], messages: [[String: Any]] = [], needs: [[String: Any]] = [],
                     outcomes: [[String: Any]] = [], asks: [Any]? = nil, features: [String] = []) throws -> HubState {
        let agents: [[String: Any]] = ["manager", "lead", "dev", "ops"].map {
            ["name": $0, "role": $0 == "manager" ? "manager" : $0 == "lead" ? "lead" : "worker", "runtime": "codex", "can": []]
        }
        var state: [String: Any] = [
            "schema_version": 1, "db": "test-db", "time": Self.now, "agents": agents, "tasks": tasks, "holds": [],
            "outcomes": outcomes, "notes": [], "needs": needs, "permissions": [], "messages": messages, "reports": [],
            "ui_features": features]
        state["owner_asks"] = asks
        return try HubState.decode(JSONSerialization.data(withJSONObject: state))
    }

    private func ids(_ board: [ActivityColumn: [Job]], _ column: ActivityColumn) -> [String] { board[column, default: []].map(\.id) }

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
        // A card stands by when its job began, the newest first: the ask began with his message an hour ago, under the
        // task of a few minutes ago, also when a task of it moved last (the owner, 19 November 2026: "do not reorder the
        // tasks in the same column, keep them in their position").
        #expect(ids(board, .inProgress) == ["task 3", "ask a"])
        // What waits for him first, whatever the period; then the rest.
        #expect(ids(board, .waiting) == ["ask b", "task 5"])
        #expect(ids(board, .done) == ["task 7", "ask c"])           // the ask that ended nine days ago is outside the period
        // An ask that is open shows whatever the period, also when it waits for nobody, and so does a task that its agent
        // parked (the review of 18 November 2026): it moves no more until its time, and must not leave "later" before.
        let parked = try hub([task(1, "working", ask: "p", last: Self.now - 86_400 * 9, parked: Self.now + 3600, works: false),
                              task(2, "working", last: Self.now - 86_400 * 9, parked: Self.now + 3600, works: false),
                              task(3, "working", last: Self.now - 86_400 * 9, works: false)],                   // not parked
                             messages: [message("p", asked: "Parked for long")])
        #expect(Set(ids(parked.board(period: .today, calendar: Self.utc), .waiting)) == ["ask p", "task 2"])
        #expect(ids(parked.board(period: .today, calendar: Self.utc), .inProgress).isEmpty)
        #expect(parked.asks.first?.lead?.id == 1)
        #expect(ids(state.board(period: .all, calendar: Self.utc), .done) == ["task 7", "ask c", "ask old"])
        // No task of an ask is a card of its own.
        let cards = board.values.flatMap { $0 }.compactMap { job -> Int? in if case .task(let id) = job.key { id } else { nil } }
        #expect(Set(cards) == [3, 5, 7])
        // The board of one agent (View all of the card Asked): what he asked that agent is one card, whoever does its
        // tasks; the agent's other tasks are cards of their own, and its work on what he asked another agent is a card
        // under that thing's name, with this agent's tasks of it alone. An agent that owns no task of its own, as the
        // Fleet Manager, shows what he asked it. As on every board, what waits for him shows whatever the period and
        // stands first in Waiting, and so does an open thing that he asked for.
        let one = try hub([task(1, "working", ask: "mine", owner: "lead", last: Self.now - 300, works: true),
                           task(2, "working", ask: "mine", owner: "dev", last: Self.now - 200, works: true, parent: 1),
                           task(3, "input-required", ask: "theirs", owner: "lead", last: Self.now - 86_400 * 9, waitingOn: "N-7"),
                           task(4, "working", owner: "lead", last: Self.now - 400, works: true),
                           task(5, "submitted", owner: "lead", last: Self.now - 50)],
                          messages: [message("mine", asked: "Mine"), message("theirs", asked: "Theirs", to: "ops")], needs: [need(7)])
        let lead = one.board(period: .today, agent: "lead", calendar: Self.utc)
        #expect(ids(lead, .inProgress) == ["task 4", "ask mine"] && ids(lead, .waiting) == ["ask theirs of lead", "task 5"])
        #expect(lead[.inProgress]?.last?.tasks.map(\.id) == [2, 1] && lead[.waiting]?.first?.tasks.map(\.id) == [3])
        let dev = one.board(period: .today, agent: "dev", calendar: Self.utc)
        #expect(ids(dev, .inProgress) == ["ask mine of dev"] && dev[.inProgress]?.first?.tasks.map(\.id) == [2])
        #expect(dev[.inProgress]?.first?.title == "Mine" && dev[.inProgress]?.first?.agent == "dev")
        // Its part of what he asked another agent for is that agent's work, not a thing that he asked it for: it shows
        // by its period and ends behind "more", and the whole of it is on the card of the agent that he asked.
        #expect(dev[.inProgress]?.first?.asked == false && lead[.inProgress]?.last?.asked == true)
        #expect(one.board(period: .today, agent: "ops", calendar: Self.utc).mapValues { $0.map(\.id) } == [.waiting: ["ask theirs"]])
    }

    @Test func endedHasOneRowForAnAskAndTheRowsOfTasksAsBefore() throws {
        let state = try hub([
            task(1, "completed", ask: "fine", last: Self.at(13, 10), accepted: 1, title: "First part"),
            task(2, "completed", ask: "fine", last: Self.at(13, 12), accepted: 1, title: "Second part"),
            task(3, "failed", ask: "bad", last: Self.at(13, 11), title: "The step that failed"),
            task(4, "completed", last: Self.at(13, 13), accepted: 1, title: "A daily check"),
            task(5, "failed", last: Self.at(13, 14), title: "A check that failed"),      // routine work, the last to end
            task(6, "completed", ask: "day", last: Self.at(12, 9), title: "Its first part"),          // waits for its check
            task(7, "completed", ask: "day", last: Self.at(12, 10), title: "Its second part", delivered: Self.at(12, 10)),
            task(8, "canceled", ask: "gone", last: Self.at(13, 8)),
        ], messages: [message("fine", asked: "Move the images"), message("bad", asked: "Write the invoice", to: "ops"),
                      message("day", asked: "Yesterday's thing"), message("gone", asked: "Dropped")])
        let ended = EndedTasks(items: state.board(period: .all, calendar: Self.utc)[.done] ?? [], calendar: Self.utc)
        // The ask whose task did not succeed, under its own name and the agent that he asked, with that task.
        #expect(ended.failedRows.map(\.title) == ["A check that failed", "Write the invoice"])
        #expect(ended.failedRows.map(\.owner) == ["dev", "ops"] && ended.failedRows.map(\.task.id) == [5, 3])
        #expect(ended.failed.map(\.id) == [5, 3])
        // The cards of Done: what he asked for first, with its checked result or the word of a result that did not
        // succeed, the one that ended last first; then the other work that did not succeed, also when it ended later
        // (his answer of 18 November 2026: the results of what he asked for and what failed).
        #expect(ended.cards.map(\.id) == ["ask fine", "ask bad", "task 5"])
        // Every other one behind "more": a daily check, and a thing that somebody canceled. An ask is one row and counts
        // as one, on the day that its last task ended.
        #expect(ended.rest == 2 && ended.days.count == 1)
        let today = ended.days[0].groups
        #expect(today.map(\.title) == ["A daily check", "Dropped"])
        #expect(today[0].owner == "dev" && today[1].owner == "lead" && today[1].tasks.map(\.id) == [8])
        // What he asked for is not done until its result is checked: it waits on the board, where he sees it, and its
        // card opens the result that waits. In his chat it is as before (`Ask`).
        let waiting = state.board(period: .all, calendar: Self.utc)[.waiting] ?? []
        #expect(waiting.map(\.id) == ["ask day"] && waiting.first?.unchecked?.id == 7 && waiting.first?.lead?.id == 7)
        #expect(waiting.first?.tasks.map(\.id) == [7, 6] && waiting.first?.onlyLater == false)
        #expect(waiting.first?.checkWords == "Waiting for Manager's check")            // its card says who checks it
        #expect(state.board(period: .today, calendar: Self.utc)[.waiting]?.map(\.id) == ["ask day"])       // whatever the period
        #expect(state.asks.first { $0.id == "day" }?.column == .done)
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

    @Test func theCardAskedShowsItsNewsThenWhatOnlyWaitsInTheBoardsWords() throws {
        let state = try hub([
            task(1, "input-required", ask: "his", owner: "dev", waitingOn: "N-7"),
            task(2, "working", ask: "works", owner: "dev", works: true, doing: "Runs the tests"),
            task(3, "working", ask: "parked", parked: Self.now + 3600, works: false),
            task(12, "submitted", ask: "parked", last: Self.now - 5),          // a later task of it, queued: its lead
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
        let card = AskedCard(state.asks, agent: "lead", after: Self.now - 250, state: state)
        // The order is the order in which he asked, the newest first.
        #expect(card.rows.map(\.id) == ["his", "works", "done", "failed"])
        #expect(card.rows.map(\.mark) == [.waitsForOwner, .working, .done, .failed])
        // Parked, and queued: each a row of its own, muted, in the board's words (until its time, "Queued"), that opens
        // the task whose wait it says, and not the ask's newest task. The one whose check is not made and the one that
        // somebody canceled say nothing.
        #expect(card.waits.map(\.id) == ["parked", "queued"] && card.waiting == 2 && card.waitsInRows && !card.isEmpty)
        #expect(card.waits.map(\.mark) == [.quiet(symbol: "circle.dotted", word: TaskWords.working),
                                            .quiet(symbol: "clock", word: "Queued")])
        #expect(card.waits.map(\.until) == [Self.now + 3600, nil] && card.waits.map(\.task) == [3, 4])
        #expect(card.waits.allSatisfy { !$0.moves } && card.waits.last?.line == "Queued")
        // Its words read the fleet's reading: a task that waits for its subtask's agent says so, as on the board.
        let sub = try hub([task(20, "working", ask: "sub", owner: "lead", works: false),
                           task(21, "working", owner: "ops", works: true, parent: 20)],
                          messages: [message("sub", asked: "Waits for a subtask")])
        #expect(AskedCard(sub.asks, agent: "lead", after: 0, state: sub).waits.map(\.line) == [HubState.subtaskWords(["ops"])])
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
        // Three that only wait are rows of their own (his "if it's only 3 elements you could have shown them there
        // directly!"); a fourth folds them into one row with their number (his "Yes, fold them").
        let four = try hub((1...4).map { task($0, "submitted", ask: "q\($0)") },
                           messages: (1...4).map { message("q\($0)", asked: "Q \($0)") })
        #expect(AskedCard(four.asks.filter { $0.id != "q4" }, agent: "lead", after: 0).waitsInRows)
        #expect(!AskedCard(four.asks, agent: "lead", after: 0).waitsInRows)
        // A Mac that has drawn no card for this fleet yet shows nothing that ended.
        #expect(AskedCard(state.asks, agent: "lead", after: .infinity).rows.map(\.id) == ["his", "works"])
        // An ask whose result is not checked yet is over on the board, and no failure.
        let unchecked = try #require(state.asks.first { $0.id == "unchecked" })
        #expect(unchecked.isOver && unchecked.unchecked && unchecked.failed == nil)
    }
}

// Owner feature `ask_follow_ups` (UI-API.md 1.360): his follow-ups, and his list "Asked by me".
extension AsksTests {
    /// One row of his list "Asked by me" as the hub gives it (`owner_asks`).
    private func ownerAsk(_ id: String, name: String, to agent: String = "lead", created: Double, follows: [String] = [],
                          answer: (words: String, at: Double)? = nil, open: Bool = false) -> [String: Any] {
        var row: [String: Any] = ["id": id, "event_id": 1, "agent": agent, "name": name, "created": created,
                                  "messages": [id] + follows, "open": open,
                                  "moved": max(created, answer?.at ?? created)]
        row["answer"] = answer.map { ["text": $0.words, "at": $0.at, "agent": agent] as [String: Any] } ?? NSNull()
        return row
    }

    /// The bug that this catches: a follow-up that names the follow-up before it (an older join) is an ask of its own; a
    /// follow-up whose first message this reading does not hold, and that his list does not name, names a message that
    /// is not there (it is no ask: the hub's own rule), but one that his list names is on that ask, on the board too;
    /// a loop, which the hub cannot write, never ends; and a chain longer than the hub's four steps goes on where the
    /// hub stops.
    @Test func aFollowUpFindsTheFirstMessageOfItsAskAndADanglingAskOrALoopIsNoAsk() throws {
        let state = try hub([], messages: [
            message("m1", asked: "Refund the orders"), message("m2", asked: nil, ask: "m1"),
            message("m3", asked: nil, ask: "m2"),
            message("m4", asked: nil, ask: "gone"),
            message("x", asked: nil, ask: "y"), message("y", asked: nil, ask: "x"),
            message("c1", asked: nil, ask: "c2"), message("c2", asked: nil, ask: "c3"), message("c3", asked: nil, ask: "c4"),
            message("c4", asked: nil, ask: "c5"), message("c5", asked: nil, ask: "c6"), message("c6", asked: "Far"),
        ])
        let firsts = state.askFirsts
        #expect(firsts["m2"] == "m1" && firsts["m3"] == "m1")
        #expect(firsts["m1"] == nil && firsts["m4"] == nil)
        #expect(firsts["x"] == "y" && firsts["y"] == "x")
        #expect(firsts["c1"] == "c5")
        // his list names a follow-up's first message, also one older than the reading's messages (the Mac validator,
        // 26 November 2026: the board made a second card of it, and his list one row)
        let listed = try hub([task(1, "completed", ask: "gone", accepted: 1), task(2, "working", ask: "m4", works: true)],
                             messages: [message("m4", asked: nil, ask: "gone")],
                             asks: [ownerAsk("gone", name: "Numbers for each agent", created: Self.now - 5 * 86_400,
                                             follows: ["m4"])])
        #expect(listed.askFirsts["m4"] == "gone" && listed.jobs.map(\.id) == ["ask gone"])
        // with only the follow-up's task in the reading (sent to a second agent), the card still has the ask's name and
        // agent from his list, not that task's
        let late = try hub([task(2, "working", ask: "m4", owner: "ops", title: "Count the agents' numbers", works: true)],
                           messages: [message("m4", asked: nil, to: "ops", ask: "gone")],
                           asks: [ownerAsk("gone", name: "Numbers for each agent", created: Self.now - 5 * 86_400,
                                           follows: ["m4"])])
        #expect(late.jobs.first.map { [$0.title, $0.agent] } == ["Numbers for each agent", "lead"])
        #expect(late.asks.first.map { [$0.title, $0.agent] + $0.alsoIn } == ["Numbers for each agent", "lead", "ops"])
        // the map is kept on the reading, and worked out again when its messages change (a join of older rows)
        var later = try hub([], messages: [message("f2", asked: nil, ask: "f1")])
        #expect(later.askFirsts["f2"] == nil)
        later.messages += try hub([], messages: [message("f1", asked: "Refund the old orders")]).messages
        #expect(later.askFirsts["f2"] == "f1")
    }

    /// The bug that this catches (his words of 25 November 2026: "Sometimes I will be asking about related tasks
    /// repeatedly, so the system should catch that"): a follow-up's work is a thing of its own in his chat's card and
    /// on the board, under no name, and the request that its work raised waits on nothing that he asked.
    @Test func aFollowUpsTasksAndItsRequestAreOnTheAskThatItGoesOnWith() throws {
        let messages = [message("m1", asked: "Refund the failed orders", created: Self.now - 86_400),
                        message("m2", asked: nil, created: Self.now - 3600, ask: "m1"), message("other", asked: "Other")]
        let state = try hub([
            task(1, "completed", ask: "m1", last: Self.now - 7200, accepted: 1),
            task(2, "input-required", ask: "m2", owner: "ops", last: Self.now - 300, waitingOn: "N-7"),
            task(3, "working", ask: "other", works: true),
        ], messages: messages, needs: [need(7)])
        let ask = try #require(state.asks.first { $0.id == "m1" })
        #expect(state.asks.map(\.id).sorted() == ["m1", "other"])
        #expect(ask.title == "Refund the failed orders" && ask.agent == "lead" && ask.followUps == ["m2"])
        #expect(ask.tasks.map(\.id) == [2, 1] && ask.wait == .request(id: 7, title: "Need 7") && ask.waitTask?.id == 2)
        // an open request that names the follow-up, with no task that waits on it, waits on the first ask
        let named = try hub([task(4, "working", ask: "m2", works: true)], messages: messages, needs: [need(8, ask: "m2")])
        #expect(named.asks.map(\.id) == ["m1"] && named.asks.first?.wait == .request(id: 8, title: "Need 8"))
    }

    /// The reading of the pictures of round 2 (`r1-mac-asked-by-me.png`): each ask of his list once, whatever the number
    /// of his messages in it, with its state mark by the board's rules, what waits for him in orange, its newest answer
    /// and the agent that has it now. The bugs that this catches: a follow-up's task or request left out of its row; a
    /// question with no task shown as work; an answer older than a task's plain result shown as the newest; Open not
    /// keeping its rows' places (what needs him first, then when he asked); Done holding what ended weeks ago.
    @Test func theListHasEachAskOnceWithItsMarkWhatWaitsForHimItsNewestAnswerAndWhoHasIt() throws {
        let day = 86_400.0
        let state = try hub([
            task(1, "completed", ask: "refunds", last: Self.now - day, accepted: 1, title: "Find the orders"),
            task(2, "input-required", ask: "refunds-2", owner: "ops", last: Self.now - 600, waitingOn: "N-7"),
            task(3, "working", ask: "kpis", last: Self.now - 300, works: true),
            task(4, "working", ask: "google", owner: "ops", last: Self.now - 7200, parked: Self.now + day, works: false),
            task(5, "completed", ask: "move", last: Self.now - 2 * day, accepted: 1, delivered: Self.now - 2 * day + 60,
                 plain: "The shop moved to the new server."),
            task(6, "failed", ask: "xbot", last: Self.now - 3 * day),
            task(7, "canceled", ask: "dropped", last: Self.now - day),
            task(8, "completed", ask: "old", last: Self.now - 9 * day, accepted: 1),
            task(9, "completed", ask: "check", last: Self.now - 600),                 // its result waits for its check
            task(10, "working", ask: "late-2", works: true),                          // a follow-up that the list names not yet
        ], messages: [message("refunds-2", asked: nil, created: Self.now - 3600, ask: "refunds"),
                      message("late-2", asked: nil, created: Self.now - 120, ask: "late")],
           needs: [need(7)],
           asks: [
            ownerAsk("refunds", name: "Refund the failed orders", created: Self.now - 2 * day, follows: ["refunds-2"],
                     answer: ("3 orders had the error.", Self.now - 900), open: true),
            ownerAsk("kpis", name: "Numbers for each agent", created: Self.now - day, open: true),
            ownerAsk("google", name: "The site's search result", created: Self.now - 3 * day, open: true),
            ownerAsk("waits", name: "A question", created: Self.now - 600),
            ownerAsk("move", name: "Move the shop", created: Self.now - 4 * day, answer: ("Looking at it.", Self.now - 3 * day)),
            ownerAsk("question", name: "Who checks the backups", created: Self.now - day, answer: ("Shop Developer does.", Self.now - day + 60)),
            ownerAsk("xbot", name: "The bot does not answer", created: Self.now - 4 * day),
            ownerAsk("dropped", name: "Dropped", created: Self.now - 2 * day),
            ownerAsk("old", name: "Old", created: Self.now - 10 * day),
            ownerAsk("check", name: "Waits for its check", created: Self.now - 5 * day, open: false),
            ownerAsk("late", name: "Late", created: Self.now - 4 * day),
           ], features: [AskedByMe.feature])
        let list = try #require(state.askedByMe)
        let rows = Dictionary(uniqueKeysWithValues: list.rows.map { ($0.id, $0) })
        // Open: what needs him first, then when he asked, the newest first; Done: seven days, the newest end first.
        #expect(list.open.map(\.id) == ["refunds", "waits", "kpis", "google", "late", "check"])
        #expect(list.done.map(\.id) == ["question", "dropped", "move", "xbot"])
        #expect(list.earlier.map(\.id) == ["old"])
        let refunds = try #require(rows["refunds"])
        #expect(refunds.mark == .needsYou && refunds.request == 7 && refunds.waitWords == "Needs you: Need 7")
        #expect(refunds.tasks.map(\.id) == [2, 1] && refunds.holder == "ops" && refunds.answer == "3 orders had the error.")
        #expect(rows["kpis"]?.mark == .working && rows["kpis"]?.moves == true && rows["kpis"]?.holder == "dev")
        #expect(rows["google"]?.mark == .waiting && rows["google"]?.until == Self.now + day && rows["google"]?.holder == "ops")
        #expect(rows["waits"]?.mark == .waiting && rows["waits"]?.answer == nil && rows["waits"]?.holder == "lead")
        // the plain result came after the hub's answer, so it is the newest answer
        #expect(rows["move"]?.mark == .done && rows["move"]?.answer == "The shop moved to the new server.")
        #expect(rows["move"]?.answered == Self.now - 2 * day + 60 && rows["move"]?.ended == Self.now - 2 * day + 60)
        // a question with no task is done once it has its answer
        #expect(rows["question"]?.mark == .done && rows["question"]?.answer == "Shop Developer does." && rows["question"]?.holder == "lead")
        #expect(rows["xbot"]?.mark == .failed && rows["xbot"]?.failedWord == "Failed" && rows["dropped"]?.mark == .canceled)
        // what he asked for is not done until its result is checked, as on the board
        #expect(rows["check"]?.mark == .waiting && rows["check"]?.ended == nil)
        // a follow-up's task is on its first ask's row before the hub's list names the follow-up
        #expect(rows["late"]?.mark == .working && rows["late"]?.tasks.map(\.id) == [10])
        // an open row's time is its newest move: here its task that waits for him, after the answer
        #expect(rows["refunds"]?.time == Self.now - 600 && rows["move"]?.time == Self.now - 2 * day + 60)
    }

    /// The rule of the hub's `answer` (UI-API.md 1.363). The bugs that this catches: a result that its check refused (a
    /// "Fixed" taken back), or one that nobody checked yet, or a part's result under another task of the ask, stands as
    /// his row's newest answer.
    @Test func aRowsAnswerIsANewerResultThatItsRequesterAcceptedAndNoPartsResult() throws {
        let state = try hub([
            task(1, "completed", ask: "fees", last: Self.now - 7200, accepted: 1, delivered: Self.now - 7200,
                 plain: "The fee stop is live."),
            task(2, "completed", ask: "fees", last: Self.now - 3600, accepted: 0, delivered: Self.now - 3600,
                 plain: "Fixed: no fee is charged."),
            task(3, "completed", ask: "fees", last: Self.now - 1800, delivered: Self.now - 1800, plain: "All refunds are out."),
            task(4, "completed", ask: "fees", last: Self.now - 900, accepted: 1, parent: 1, delivered: Self.now - 900,
                 plain: "Half of it."),
        ], asks: [ownerAsk("fees", name: "Stop the fees", created: Self.now - 9000, answer: ("Mia stops them.", Self.now - 8000))],
           features: [AskedByMe.feature])
        let row = try #require(state.askedByMe?.rows.first { $0.id == "fees" })
        #expect(row.answer == "The fee stop is live." && row.answered == Self.now - 7200)
        // later work that follows that task puts its result right: the hub's words are the answer until it says its own
        let followed = try hub([
            task(1, "completed", ask: "fees", last: Self.now - 7200, accepted: 1, delivered: Self.now - 7200,
                 plain: "The fee stop is live."),
            task(5, "working", ask: "fees", last: Self.now - 300, follows: 1, works: true),
        ], asks: [ownerAsk("fees", name: "Stop the fees", created: Self.now - 9000, answer: ("Mia stops them.", Self.now - 8000))],
           features: [AskedByMe.feature])
        #expect(followed.askedByMe?.rows.first?.answer == "Mia stops them.")
    }

    /// The bug that this catches: he asks again about work that ended ("Are they refunded yet?"), and the row stays in
    /// Done with the old answer, so his question is lost until an agent starts a task.
    @Test func aFollowUpQuestionOnWorkThatEndedKeepsItOpenUntilItsAnswer() throws {
        let tasks = [task(1, "completed", ask: "orders", last: Self.now - 7200, accepted: 1)]
        let messages = [message("orders", asked: "Failed orders", created: Self.now - 9000),
                        message("orders-2", asked: nil, created: Self.now - 600, ask: "orders")]
        func row(answeredAt: Double) throws -> AskedRow {
            let state = try hub(tasks, messages: messages, asks: [
                ownerAsk("orders", name: "Failed orders", created: Self.now - 9000, follows: ["orders-2"],
                         answer: ("They are refunded.", answeredAt))], features: [AskedByMe.feature])
            return try #require(state.askedByMe?.rows.first)
        }
        #expect(try row(answeredAt: Self.now - 7000).mark == .waiting)
        let answered = try row(answeredAt: Self.now - 60)
        #expect(answered.mark == .done && answered.answer == "They are refunded." && answered.ended == Self.now - 60)
    }

    /// The bug that this catches: a row of another shape (or a hub's later field that this app does not read) takes the
    /// whole reading of the fleet down; a row of one ask twice stands twice; and a hub before the feature, or one that
    /// sends no list, shows the switch with nothing under it.
    @Test func aRowThatTheAppCannotReadIsNoRowAndAHubWithoutTheListHasNone() throws {
        let state = try hub([], asks: [ownerAsk("good", name: "Good", created: Self.now - 60), ["id": "bad", "agent": "lead"],
                                       "not a row", ownerAsk("good", name: "Again", created: Self.now - 30)],
                            features: [AskedByMe.feature])
        #expect(state.owner_asks?.map(\.name) == ["Good"])
        #expect(state.askedByMe?.open.map(\.id) == ["good"])
        #expect(try hub([], asks: [ownerAsk("good", name: "Good", created: Self.now)]).askedByMe == nil)
        #expect(try hub([], features: [AskedByMe.feature]).askedByMe == nil)
    }

    /// The bug that this catches: a name stays semibold after he opened its card; it does not turn semibold again for a
    /// later answer; a Mac that reads a fleet for the first time shows its whole past as new; or the kept value grows
    /// with every ask he ever made.
    @Test func aNameIsSemiboldOnlyForAnAnswerThatCameAfterHeOpenedItsCard() throws {
        let state = try hub([], asks: [
            ownerAsk("new", name: "New", created: Self.now - 3600, answer: ("Done now.", Self.now - 60)),
            ownerAsk("past", name: "Past", created: Self.now - 9000, answer: ("Done then.", Self.now - 7200)),
        ], features: [AskedByMe.feature])
        let rows = Dictionary(uniqueKeysWithValues: try #require(state.askedByMe).rows.map { ($0.id, $0) })
        let new = try #require(rows["new"]), past = try #require(rows["past"])
        var seen = AskSeen(words: "")
        #expect(!seen.unread(new, db: "test-db"))                   // before this Mac drew the list, nothing is new
        seen.begin(db: "test-db", at: Self.now - 3600)
        seen.begin(db: "test-db", at: Self.now)                     // a second drawing keeps the first time
        #expect(seen.since(db: "test-db") == Self.now - 3600)
        #expect(seen.unread(new, db: "test-db") && !seen.unread(past, db: "test-db"))
        #expect(!seen.unread(new, db: "another-db"))
        seen.note("new", answered: Self.now - 60, db: "test-db", keep: ["new", "past"])
        #expect(!seen.unread(new, db: "test-db"))
        #expect(AskSeen(words: seen.words) == seen && AskSeen(words: "not JSON") == AskSeen(words: ""))
        // a later answer is news again
        let later = try hub([], asks: [ownerAsk("new", name: "New", created: Self.now - 3600, answer: ("And more.", Self.now - 10))],
                            features: [AskedByMe.feature])
        #expect(seen.unread(try #require(later.askedByMe?.rows.first), db: "test-db"))
        // only the asks that the list still has stay kept
        seen.note("past", answered: Self.now - 7200, db: "test-db", keep: ["past"])
        #expect(seen.unread(new, db: "test-db"))
    }

    /// The bug that this catches: the message from an ask's card reaches the hub with no `ask` (it may join another
    /// thing, or none), an answer to a Needs-you item carries one (the hub refuses it, 400), a saved request loses it
    /// at a restart of the app, or his message on its way stands on no card.
    @Test func aMessageFromAnAsksCardCarriesTheAskAndAnAnswerOrACorrectionCarriesNone() throws {
        let hub = try #require(URL(string: "http://127.0.0.1:9"))
        let message = PendingRequest(hub: hub, database: "test-db", client: "test", recipient: "nova", ask: "m1",
                                     text: "Are they refunded yet?")
        let body = try #require(JSONSerialization.jsonObject(with: message.body()) as? [String: Any])
        #expect(body["ask"] as? String == "m1" && body["recipient"] as? String == "nova")
        #expect(try JSONDecoder().decode(PendingRequest.self, from: JSONEncoder().encode(message)).ask == "m1")
        #expect(OwnerMessage(onItsWay: message).ask == "m1")
        let plain = PendingRequest(hub: hub, database: "test-db", client: "test", recipient: "nova", text: "Hello")
        #expect(try #require(JSONSerialization.jsonObject(with: plain.body()) as? [String: Any])["ask"] == nil)
        #expect(PendingRequest(hub: hub, database: "test-db", client: "test", needID: 5, ask: "m1", text: "Yes").ask == nil)
        #expect(PendingRequest(hub: hub, database: "test-db", client: "test", recipient: "nova", replacesRequestID: "m2",
                               ask: "m1", text: "Are all of them refunded?").ask == nil)
    }
}
