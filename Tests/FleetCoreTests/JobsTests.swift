import Foundation
import Testing
@testable import FleetCore

// Explicit test data only: tasks with the links that make them one job, a case of a duty, and their results.
struct JobsTests {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// The hub's time: 13 October 2026, 15:00 UTC.
    private static let now = utc.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 15))!.timeIntervalSince1970

    private func task(_ id: Int, _ state: String, owner: String = "dev", title: String? = nil, last: Double? = nil,
                      _ more: [String: Any] = [:]) -> [String: Any] {
        let moved = last ?? Self.now - 600
        var row: [String: Any] = ["id": id, "title": title ?? "Task \(id)", "details": "", "done_when": "Checked", "needs": "none",
                                  "goal": "", "owner": owner, "requester": "manager", "state": state, "created": moved - 60,
                                  "attempt": 1, "restarts": 0, "nudge_level": 0, "stop_sent": 0]
        row["started"] = state == "submitted" ? nil : moved
        row["last_activity"] = state == "submitted" ? nil : moved
        for (key, value) in more { row[key] = value }
        return row
    }

    private func hub(_ tasks: [[String: Any]], duties: [[String: Any]] = [], messages: [[String: Any]] = []) throws -> HubState {
        let agents: [[String: Any]] = ["manager", "lead", "dev", "ops"].map {
            ["name": $0, "role": $0 == "manager" ? "manager" : $0 == "lead" ? "lead" : "worker", "runtime": "codex", "can": []]
        }
        return try HubState.decode(JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "db": "test-db", "time": Self.now, "agents": agents, "tasks": tasks, "holds": [],
            "outcomes": [], "notes": [], "needs": [], "permissions": [], "messages": messages, "reports": [],
            "responsibilities": duties]))
    }

    /// The bug that this catches: three tasks of one update that are three cards, a job under the title of a later
    /// task, and the wake-ups and reviews of a whole team as one card because the hub files them under one task.
    @Test func aTaskIsInTheJobThatItsLinksNameAndParentAloneJoinsNone() throws {
        let state = try hub([
            task(1, "completed", title: "Find what uses the old version", ["accepted": 1, "job_name": "Install the security update"]),
            task(2, "working", owner: "ops", title: "Update the servers", ["job": 1, "works": true]),
            task(3, "submitted", owner: "ops", title: "Check the servers", ["follows": 2]),
            // the lead's one task for its team's results, with a review and a wake-up that the hub filed under it
            task(4, "working", owner: "lead", title: "Your team's results", ["works": false]),
            task(5, "working", title: "Put your notes in order", ["parent": 4, "works": true]),
            task(6, "completed", owner: "ops", title: "Daily check", ["parent": 4, "accepted": 1]),
            // a lead's own subtask, for which the hub wrote the link
            task(7, "working", owner: "lead", title: "Move the images", ["works": false]),
            task(8, "working", title: "Copy the images", ["parent": 7, "job": 7, "works": true]),
            // a case of a duty, its task, and a subtask of that task of before the hub wrote the link
            task(9, "working", owner: "ops", title: "Incident: the check found a problem", ["duty_case": 30, "works": false]),
            task(10, "working", title: "Read the logs", ["parent": 9, "works": true]),
            // a later part of what he asked for: the hub gave it the ask of its job
            task(11, "completed", owner: "lead", title: "Plan it", ["ask": "m", "accepted": 1]),
            task(12, "working", title: "Do it", ["job": 11, "ask": "m", "works": true]),
            // the follow-up of a subtask of the case's task: it reaches the case as that subtask does
            task(13, "submitted", title: "Read the logs again", ["follows": 10]),
            // two tasks that name a task that this reading does not hold are one job all the same
            task(14, "working", title: "Clean the queue", ["job": 99, "works": true]),
            task(15, "submitted", owner: "ops", title: "Check the queue", ["job": 99]),
        ], duties: [["agent": "ops", "cases": [["id": 30, "responsibility": 3, "key": "alert/disk", "title": "The shop's disk is full",
                                                "state": "open"]]]],
           messages: [["request_id": "m", "recipient": "lead", "kind": "message", "text": "Please move it", "event_id": 1,
                       "created": Self.now - 3600, "client": "test", "asked": "Move the shop"]])
        let jobs = Dictionary(state.jobs.map { ($0.id, $0) }) { first, _ in first }
        #expect(Set(jobs.keys) == ["task 1", "task 4", "task 5", "task 6", "task 7", "case 30", "ask m", "task 99"])
        #expect(Set(jobs["task 99"]?.tasks.map(\.id) ?? []) == [14, 15] && jobs["task 99"]?.title == "Clean the queue")
        // what he asked for is one thing on the board and in his chat: the same tasks as its ask has
        #expect(Set(jobs["ask m"]?.tasks.map(\.id) ?? []) == Set(state.asks.first?.tasks.map(\.id) ?? []))
        let update = try #require(jobs["task 1"])
        // its name is the one that its first task gave it; its agent is the one that has it now
        #expect(update.title == "Install the security update" && update.agent == "ops")
        #expect(Set(update.tasks.map(\.id)) == [1, 2, 3] && update.lines.map(\.id) == [1, 2, 3])
        #expect(update.column == .inProgress && update.working?.id == 2 && update.lead?.id == 2)
        #expect(Set(jobs["task 7"]?.tasks.map(\.id) ?? []) == [7, 8])
        let incident = try #require(jobs["case 30"])
        // the case's holder waits for the subtask that another agent works now: the card names that agent
        #expect(incident.title == "The shop's disk is full" && incident.agent == "dev" && Set(incident.tasks.map(\.id)) == [9, 10, 13])
        let asked = try #require(jobs["ask m"])
        #expect(asked.title == "Move the shop" && asked.agent == "lead" && asked.asked && Set(asked.tasks.map(\.id)) == [11, 12])
        #expect(jobs["task 5"]?.title == "Put your notes in order" && jobs["task 4"]?.tasks.map(\.id) == [4])
    }

    /// The bug that this catches: a card that counts a canceled task, a card of one task with a counts line, a Done
    /// card that says the words that its agent wrote for another agent while plain words are there, and a job that is
    /// open with a result on its card.
    @Test func aJobCountsItsTasksAndSaysItsResultInPlainWords() throws {
        let state = try hub([
            task(1, "completed", last: Self.now - 900, ["accepted": 1, "plain": "The servers are listed."]),
            task(2, "working", ["job": 1, "works": true]),
            task(3, "submitted", ["job": 1]),
            task(4, "failed", last: Self.now - 500, ["job": 1]),
            task(5, "canceled", ["job": 1]),
            task(6, "working", ["works": true]),
            // he asked for it; its fix has the last word, and the fix's plain words are its result
            task(7, "completed", owner: "lead", last: Self.now - 800, ["ask": "m", "accepted": 0, "plain": "It is half done."]),
            task(8, "completed", owner: "lead", last: Self.now - 300,
                 ["ask": "m", "follows": 7, "accepted": 1, "plain": "  The shop runs on\n the new server. ", "what": "Moved 4,212 files to app-2."]),
            // no plain words: the first words of its own result
            task(9, "completed", last: Self.now - 200, ["accepted": 1, "what": "Rotated the logs on app-3."]),
        ], messages: [["request_id": "m", "recipient": "lead", "kind": "message", "text": "Please move it", "event_id": 1,
                       "created": Self.now - 3600, "client": "test", "asked": "Move the shop"]])
        let jobs = Dictionary(state.jobs.map { ($0.id, $0) }) { first, _ in first }
        let open = try #require(jobs["task 1"])
        #expect(open.counts == Job.Counts(working: 1, waiting: 1, done: 1, failed: 1))
        #expect(open.countWords?.plain == "1 working · 1 waiting · 1 done" && open.countWords?.failed == "1 failed")
        #expect(open.lines.map(\.id) == [1, 2, 3, 4])                   // none that somebody canceled
        #expect(open.result == nil && !open.showsResult)                 // it is open: no result yet
        #expect(jobs["task 6"]?.countWords == nil)                       // one task: its card says where it stands
        let asked = try #require(jobs["ask m"])
        #expect(asked.isOver && asked.failed == nil && asked.showsResult)
        #expect(asked.result == "The shop runs on the new server." && asked.countWords?.plain == "1 done")
        #expect(asked.countWords?.failed == nil && asked.replaced == [7])    // its fix took it over: in no group
        #expect(open.countWords?.plain.hasSuffix("1 done") == true)
        let routine = try #require(jobs["task 9"])
        #expect(routine.result == "Rotated the logs on app-3." && !routine.showsResult)    // routine work: behind "more"
    }

    /// The bug that this catches: a job behind "later" while a task of it waits on something that is no time, and a
    /// thing that he asked for hidden behind that row.
    @Test func aJobIsBehindLaterOnlyWhileNothingButATimeHoldsEachOpenTaskOfIt() throws {
        let later = Self.now + 3600
        let state = try hub([
            task(1, "completed", ["accepted": 1]),
            task(2, "working", ["job": 1, "parked_until": later, "works": false]),                    // only its time
            task(3, "working", ["parked_until": later, "works": false]),
            task(4, "submitted", ["job": 3]),                                                           // and one in the queue
            task(5, "working", owner: "lead", ["ask": "m", "parked_until": later, "works": false]),   // he asked for it
        ], messages: [["request_id": "m", "recipient": "lead", "kind": "message", "text": "Please move it", "event_id": 1,
                       "created": Self.now - 3600, "client": "test", "asked": "Move the shop"]])
        let waiting = WaitingTasks(items: state.board(period: .all, calendar: Self.utc)[.waiting] ?? [], calendar: Self.utc)
        #expect(waiting.later.flatMap(\.jobs).map(\.id) == ["task 1"] && waiting.laterCount == 1)
        #expect(Set(waiting.cards.map(\.id)) == ["task 3", "ask m"])
        #expect(waiting.later.first?.jobs.first?.until == later)
    }

    /// The bug that this catches: a card that jumps to the top of its lane each time a task of it moves (the board is
    /// read every three seconds, and the job whose task made the last call stood first), and a job whose time starts
    /// again with a later task of it.
    @Test func aCardKeepsItsPlaceInItsLaneByWhenItsJobBegan() throws {
        let state = try hub([
            task(1, "working", last: Self.now - 30, ["created": Self.now - 7200, "works": true]),     // began first, moved last
            task(2, "working", last: Self.now - 900, ["created": Self.now - 1200, "works": true]),
            task(3, "completed", last: Self.now - 3000, ["created": Self.now - 5400, "accepted": 1]),
            task(4, "working", last: Self.now - 10, ["job": 3, "created": Self.now - 60, "works": true]),   // a part made now
            task(5, "working", owner: "lead", last: Self.now - 20, ["ask": "m", "created": Self.now - 100, "works": true]),
        ], messages: [["request_id": "m", "recipient": "lead", "kind": "message", "text": "Please move it", "event_id": 1,
                       "created": Self.now - 3600, "client": "test", "asked": "Move the shop"]])
        let working = state.board(period: .all, calendar: Self.utc)[.inProgress] ?? []
        #expect(working.map(\.id) == ["task 2", "ask m", "task 3", "task 1"])     // the job that began last first
        #expect(working.map(\.began) == [Self.now - 1200, Self.now - 3600, Self.now - 5400, Self.now - 7200])
    }

    /// The owner, 19 November 2026, of a job card's time: "something like "for X hours" or "for Y minutes", in the
    /// sense of "working for x hours on this task"". The bugs that this catches: a card that says how old its job is
    /// ("2 h ago"); a time that a stall of its machine, or a task that joins the job later, sets back (a review of 20
    /// November 2026).
    @Test func aCardSaysHowLongItsJobHasStoodInItsColumn() throws {
        let later = Self.now + 3600
        let state = try hub([
            // in work since now-3 h, stalled since now-2 min: the hub's `since` moves, the card's time does not
            task(1, "working", ["created": Self.now - 4 * 3600, "started": Self.now - 3 * 3600,
                                "since": Self.now - 120, "works": true]),
            task(2, "working", ["job": 1, "created": Self.now - 600, "started": Self.now - 300, "works": true]),
            // waiting, parked since now-40 min, and a task that joined it a minute ago
            task(3, "working", ["created": Self.now - 7200, "started": Self.now - 7200, "since": Self.now - 2400,
                                "parked_until": later, "works": false]),
            task(4, "submitted", ["job": 3, "created": Self.now - 60]),
            // waiting for his sign-in since now-15 min
            task(5, "auth-required", ["created": Self.now - 7200, "since": Self.now - 900]),
        ])
        let board = state.board(period: .all, calendar: Self.utc)
        #expect(board[.inProgress]?.map(\.columnSince) == [Self.now - 3 * 3600])
        #expect(Set(board[.waiting]?.map(\.columnSince) ?? []) == [Self.now - 2400, Self.now - 900])
        // Kept while a card stays in its column, at every reading: a restart of its session (a new `started`) sets
        // nothing back; a change of column takes the later of its guess and the last reading that saw it before, so a
        // gap in the readings takes the hub's facts (the reviews of 20 November 2026)
        var times = ColumnTimes()
        let job = try #require(board[.inProgress]?.first)
        times.note([job], hub: "h", now: Self.now)
        #expect(times.since(job, hub: "h") == Self.now - 3 * 3600)
        let restarted = try hub([task(1, "working", ["created": Self.now - 4 * 3600, "started": Self.now - 10, "works": true]),
                                 task(2, "working", ["job": 1, "created": Self.now - 600, "started": Self.now - 300,
                                                     "works": true])])
        let again = try #require(restarted.board(period: .all, calendar: Self.utc)[.inProgress]?.first)
        times.note([again], hub: "h", now: Self.now + 5)
        #expect(times.since(again, hub: "h") == Self.now - 3 * 3600)
        #expect(times.since(again, hub: "another hub") == again.columnSince)       // a time is one hub's
        let waits = try hub([task(1, "working", ["created": Self.now - 4 * 3600, "started": Self.now - 3 * 3600,
                                                 "since": Self.now + 300, "parked_until": later, "works": false])])
        let parked = try #require(waits.board(period: .all, calendar: Self.utc)[.waiting]?.first)
        // a card drawn before its reading's note (the Mac makes the note away from the main thread) shows the time that
        // the note keeps: the later of the hub's guess and the last reading that saw it in its column before, here
        // the reading at now + 5 over a guess of now - 500
        let early = try hub([task(1, "working", ["created": Self.now - 4 * 3600, "started": Self.now - 3 * 3600,
                                                 "since": Self.now - 500, "parked_until": later, "works": false])])
        let parkedEarly = try #require(early.board(period: .all, calendar: Self.utc)[.waiting]?.first)
        #expect(parkedEarly.columnSince == Self.now - 500)
        #expect(times.since(parkedEarly, hub: "h") == Self.now + 5)
        times.note([parked], hub: "h", now: Self.now + 2 * 3600)                    // two hours with no reading
        #expect(times.since(parked, hub: "h") == Self.now + 300)
        // an agent's own board names its part of another agent's job apart: a reading notes that card by its own id
        // too, so a restart of its session sets nothing back on that agent's board
        let reading = { (started: Double) in
            try self.hub([task(1, "working", owner: "lead", last: Self.now - 10, ["created": Self.now - 7200,
                                                                                "started": Self.now - 60, "works": true]),
                          task(2, "working", last: Self.now - 300, ["job": 1, "created": Self.now - 3600,
                                                                     "started": started, "works": true])])
        }
        times = ColumnTimes()
        let first = try reading(Self.now - 3600)
        let owners = Set(first.tasks.filter { !$0.isTerminal }.map(\.owner))
        let cards = ([nil] + owners.map(Optional.some)).flatMap { owner in
            first.board(period: .all, agent: owner).values.flatMap { $0 }
        }
        let tracked = first.jobs(of: nil, includingPartsFor: owners)
        #expect(Set(tracked.map(\.id)) == Set(cards.map(\.id)))
        #expect(tracked.count == Set(cards.map(\.id)).count)
        for card in cards {
            let match = try #require(tracked.first { $0.id == card.id })
            #expect(match.column == card.column && match.columnSince == card.columnSince)
        }
        times.note(first)
        let before = try #require(first.board(period: .all, agent: "dev", calendar: Self.utc)[.inProgress]?.first)
        let second = try reading(Self.now - 5)
        times.note(second)
        let after = try #require(second.board(period: .all, agent: "dev", calendar: Self.utc)[.inProgress]?.first)
        #expect(after.id == before.id && after.id.hasSuffix(" of dev"))                 // a part of the lead's job,
        #expect(after.columnSince != before.columnSince)                                // its guess moved,
        #expect(times.since(after, hub: second.db) == before.columnSince)              // the kept time did not
    }

    /// The bug that this catches: red "failed" on a card whose failure later work took over, and "Rejected" on a job
    /// whose work was done, while a failure that nothing took over must stay red (on the owner's fleet, 19 November
    /// 2026, the release of a fix followed the fix and not the rejected hand-over, and the card in Done said
    /// "Rejected").
    @Test func aFailureIsRedOnlyWhileNoLaterWorkTookItOver() throws {
        let state = try hub([
            // a result that its requester did not accept, and the follow-up that takes it over
            task(1, "completed", last: Self.now - 3000, ["accepted": 0, "delivered": Self.now - 3000]),
            task(2, "input-required", ["follows": 1]),
            task(3, "working", ["job": 1, "works": true]),
            // a hand-over that its agent rejected and its requester agreed with, then the release, which follows the fix
            task(10, "completed", last: Self.now - 4000, ["accepted": 1, "delivered": Self.now - 4000]),
            task(11, "rejected", owner: "lead", last: Self.now - 3000, ["follows": 10, "accepted": 1, "delivered": Self.now - 3000]),
            task(12, "completed", last: Self.now - 2000, ["follows": 10, "accepted": 1, "created": Self.now - 2990]),
            // a failure that a further part of the job did not take over
            task(20, "failed", last: Self.now - 3000, ["accepted": 1]),
            task(21, "working", ["job": 20, "works": true]),
            // a rejection with work before it and none after it, and one after which only a canceled task came
            task(30, "completed", last: Self.now - 4000, ["accepted": 1]),
            task(31, "rejected", owner: "lead", last: Self.now - 3000, ["follows": 30, "accepted": 1]),
            task(40, "completed", last: Self.now - 4000, ["accepted": 1]),
            task(41, "rejected", owner: "lead", last: Self.now - 3000, ["follows": 40, "accepted": 1]),
            task(42, "canceled", ["follows": 40]),
            // a rejection whose own subtask, and a part made beside it, came before the rejection: neither redid it
            task(50, "rejected", owner: "lead", last: Self.now - 3000,
                 ["accepted": 1, "delivered": Self.now - 3000, "created": Self.now - 4000]),
            task(51, "completed", last: Self.now - 3500, ["parent": 50, "job": 50, "accepted": 1, "created": Self.now - 3600]),
            task(52, "completed", owner: "ops", last: Self.now - 1000, ["job": 50, "accepted": 1, "created": Self.now - 3590]),
        ])
        let jobs = Dictionary(state.jobs.map { ($0.id, $0) }) { first, _ in first }
        let followed = try #require(jobs["task 1"])
        #expect(followed.counts == Job.Counts(working: 1, waiting: 1, done: 0, failed: 0) && followed.countWords?.failed == nil)
        #expect(followed.countWords?.plain == "1 working · 1 waiting" && followed.replaced.contains(1))
        let released = try #require(jobs["task 10"])
        #expect(released.isOver && released.failed == nil && released.counts.failed == 0 && released.replaced.contains(11))
        #expect(jobs["task 20"]?.counts.failed == 1 && jobs["task 20"]?.countWords?.failed == "1 failed")
        #expect(jobs["task 30"]?.failed?.id == 31 && jobs["task 40"]?.failed?.id == 41)
        #expect(jobs["task 30"]?.replaced.contains(31) == false && jobs["task 40"]?.replaced.contains(41) == false)
        #expect(jobs["task 50"]?.failed?.id == 50 && jobs["task 50"]?.replaced.contains(50) == false)
        // On the board of the agent whose hand-over was rejected, its part of the job ended well too: the release is
        // another agent's work, which that part does not hold.
        let lead = state.board(period: .all, agent: "lead", calendar: Self.utc)[.done] ?? []
        let part = try #require(lead.first { $0.id == "task 10 of lead" })
        #expect(part.tasks.map(\.id) == [11] && part.failed == nil && part.replaced == [11])
    }

    /// The bug that this catches: a task's row that says since when its session last started, while it waited on a
    /// question for two days (on the owner's fleet a restart gave 15 open tasks one start time), and a row that reads
    /// no time from an older hub.
    @Test func aTasksRowSaysSinceWhenTheTaskIsInItsState() throws {
        let state = try hub([
            task(1, "input-required", last: Self.now - 60, ["since": Self.now - 172_800]),
            task(2, "working", last: Self.now - 60, ["started": Self.now - 900]),              // an older hub: its start
            task(3, "submitted", ["created": Self.now - 300]),
            task(4, "completed", last: Self.now - 600, ["delivered": Self.now - 500]),          // waits for its check
            task(5, "completed", last: Self.now - 600, ["delivered": Self.now - 500, "accepted": 1, "checked_at": Self.now - 100]),
        ])
        let byID = Dictionary(uniqueKeysWithValues: state.tasks.map { ($0.id, $0) })
        // the checked result wears its check's mark ("Accepted by Manager") since the check
        #expect([1, 2, 3, 4, 5].map { byID[$0]?.stateSince }
                    == [Self.now - 172_800, Self.now - 900, Self.now - 300, Self.now - 500, Self.now - 100])
    }

    /// The Tasks area's condition for the follow-ups (owner feature `ask_follow_ups`, 25 November 2026): **a follow-up
    /// and its first ask make one job card**, under the first message's name and agent, in both lanes that its tasks
    /// stand in. The bug that this catches: the follow-up's task, which names its own message, makes a second card with
    /// the title of that task, and the first card stays in Done while his newer question is worked on.
    @Test func aFollowUpAndItsFirstAskAreOneJobCard() throws {
        func message(_ id: String, _ created: Double, asked: String?, ask: String?) -> [String: Any] {
            ["request_id": id, "recipient": "lead", "kind": "message", "text": "Words of \(id)", "event_id": 1,
             "created": created, "client": "test", "asked": asked ?? NSNull(), "ask": ask ?? NSNull()]
        }
        let state = try hub([
            task(1, "completed", owner: "lead", title: "Find the orders", last: Self.now - 7200, ["ask": "m1", "accepted": 1]),
            task(2, "working", title: "Refund them", ["ask": "m2", "works": true]),
        ], messages: [message("m1", Self.now - 86_400, asked: "Refund the failed orders", ask: nil),
                      message("m2", Self.now - 600, asked: nil, ask: "m1")])
        let job = try #require(state.jobs.first)
        #expect(state.jobs.map(\.id) == ["ask m1"])
        #expect(job.title == "Refund the failed orders" && job.agent == "lead" && job.asked && job.column == .inProgress)
        #expect(Set(job.tasks.map(\.id)) == [1, 2] && job.began == Self.now - 86_400)
        #expect(state.board(period: .week).values.flatMap { $0 }.map(\.id) == ["ask m1"])
    }
}
