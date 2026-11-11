import Foundation
import Testing
@testable import FleetCore

// Explicit test data only: tasks in each state of the hub, with holds and a usage limit.
struct ActivityTests {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// The hub's time: 13 October 2026, 15:00 UTC.
    private static let now = at(13, 15)

    private static func at(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 10) -> Double {
        utc.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!.timeIntervalSince1970
    }

    private func task(_ id: Int, _ state: String, owner: String = "vps", created: Double = ActivityTests.now - 60, started: Double? = nil,
                      last: Double? = nil, waitingOn: String? = nil, accepted: Int? = nil, title: String? = nil,
                      schedule: Int? = nil, parked: Double? = nil) -> [String: Any] {
        var row: [String: Any] = ["id": id, "title": title ?? "Task \(id)", "details": "", "done_when": "Checked", "needs": "none",
                                  "goal": "", "owner": owner, "requester": "manager", "state": state, "created": created,
                                  "attempt": 1, "restarts": 0, "nudge_level": 0, "stop_sent": 0]
        row["started"] = started; row["last_activity"] = last; row["waiting_on"] = waitingOn; row["accepted"] = accepted
        row["trigger_id"] = schedule; row["parked_until"] = parked
        return row
    }

    private func need(_ id: Int, question: Int? = nil, answered: Double? = nil) -> [String: Any] {
        ["id": id, "title": "Need \(id)", "why": "", "todo": "", "raised": Self.now - 300, "by": "manager",
         "answered": answered ?? NSNull(), "question": question ?? NSNull()]
    }

    private func hub(_ tasks: [[String: Any]], holds: [[String: Any]] = [], limited: [String] = [], outcomes: [[String: Any]] = [],
                     needs: [[String: Any]] = []) throws -> HubState {
        let agents: [[String: Any]] = ["manager", "vps", "studio"].map { name in
            var agent: [String: Any] = ["name": name, "role": name == "manager" ? "manager" : "worker", "runtime": "codex", "can": []]
            if limited.contains(name) {
                agent["limit"] = ["since": Self.now - 60, "until": Self.now + 3600, "reset_known": true, "task": NSNull()]
            }
            return agent
        }
        return try HubState.decode(JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "db": "test-db", "time": Self.now, "agents": agents, "tasks": tasks, "holds": holds,
            "outcomes": outcomes, "notes": [], "needs": needs, "permissions": [], "messages": [], "reports": []]))
    }

    private func ids(_ board: [ActivityColumn: [FleetTask]], _ column: ActivityColumn) -> [Int] { board[column, default: []].map(\.id) }

    /// What an update of one agent's helper would end: that agent's work in flight, and nothing else. The
    /// confirmation on a server's page names it, because this Mac cannot wait for a helper to be idle.
    @Test func theWorkInFlightOfOneAgentIsWhatAnUpdateEnds() throws {
        let start = Self.now - 600
        let state = try hub([
            task(1, "working", owner: "manager", started: start, last: start),
            task(2, "working", owner: "vps", started: start, last: start),
            task(3, "submitted", owner: "manager"),
            task(4, "input-required", owner: "manager", started: start, last: start, waitingOn: "Q-1"),
            task(5, "completed", owner: "manager", started: start, last: start),
        ])
        #expect(state.working("manager").map(\.id) == [1])       // a task that waits is not work in flight
        #expect(state.working("vps").map(\.id) == [2])
        #expect(state.working("studio").isEmpty)
    }

    @Test func eachHubStateHasItsColumn() throws {
        let start = Self.now - 600
        let board = try hub([
            task(1, "submitted"), task(2, "working", started: start, last: start),
            task(3, "input-required", started: start, last: start, waitingOn: "Q-1"), task(4, "auth-required", started: start, last: start),
            task(5, "completed", started: start, last: start), task(6, "failed", started: start, last: start),
            task(7, "rejected", started: start, last: start), task(8, "canceled"),
        ]).activity(agent: nil, period: .all, calendar: Self.utc)
        #expect(ids(board, .inProgress) == [2])
        #expect(Set(ids(board, .waiting)) == [1, 3, 4])          // a queued task waits for its agent
        #expect(Set(ids(board, .done)) == [5, 6, 7, 8])
    }

    @Test func anOpenTaskThatWaitsOnSomethingOrIsHeldWaits() throws {
        let start = Self.now - 600
        let holds: [[String: Any]] = [
            ["id": 1, "task": 2, "kind": "pause", "state": "stopped", "attempt": 1],
            ["id": 2, "task": 3, "kind": "stop", "state": "released", "attempt": 1],
            ["id": 3, "task": 6, "kind": "stop", "state": "not_confirmed", "attempt": 1],
            ["id": 4, "task": 7, "kind": "stop", "state": "stopped", "attempt": 1]]
        let board = try hub([
            task(1, "working", started: start, last: start, waitingOn: "its screen"),
            task(2, "working", started: start, last: start),                   // paused by the owner
            task(3, "working", started: start, last: start),                   // its hold was released
            task(4, "submitted", owner: "studio"),                              // its agent has a usage limit
            task(5, "working", owner: "studio", started: start, last: start),
            task(6, "submitted"),                                               // a stop that was not confirmed
            task(7, "canceled", started: start, last: start),                  // a hold does not reopen an ended task
            task(8, "a-new-state"),                                             // not known to this app
        ], holds: holds, limited: ["studio"]).activity(agent: nil, period: .all, calendar: Self.utc)
        #expect(Set(ids(board, .waiting)) == [1, 2, 4, 5, 6, 8])
        #expect(ids(board, .inProgress) == [3])
        #expect(ids(board, .done) == [7])
        #expect(ids(board, .waiting).first == 6)                 // only the owner can check a stop that was not confirmed: first
    }

    @Test func anOutcomeThatTheOwnerMustRecordNeedsThemAlsoAfterTheTaskEndedAndBeforeThePeriod() throws {
        let start = Self.now - 600
        let outcomes: [[String: Any]] = [
            ["id": 1, "task": 1, "attempt": 1, "title": "Send the note", "kind": "send", "state": "unknown"],
            ["id": 2, "task": 2, "attempt": 1, "title": "Post", "kind": "post", "state": "done"],
            ["id": 3, "task": 3, "attempt": 1, "title": "Pay", "kind": "pay", "state": "unknown"]]
        let board = try hub([
            task(1, "canceled", started: start, last: start),                       // stopped, with an unknown send
            task(2, "canceled", started: start, last: start),                       // its outcome is recorded
            task(3, "working", created: Self.at(1, 9), started: Self.at(1, 9), last: Self.at(1, 10)),   // older than today
        ], outcomes: outcomes).activity(agent: nil, period: .today, calendar: Self.utc)
        #expect(Set(ids(board, .waiting)) == [1, 3])              // also the one that ended, and the one before the period
        #expect(ids(board, .done) == [2])
    }

    @Test func aTaskThatItsAgentParkedWaitsUntilThatTime() throws {
        let start = Self.now - 600
        let board = try hub([
            task(1, "working", started: start, last: start, parked: Self.now + 1800),      // a reminder in half an hour
            task(2, "working", started: start, last: start),
        ]).activity(agent: nil, period: .all, calendar: Self.utc)
        #expect(ids(board, .waiting) == [1])
        #expect(ids(board, .inProgress) == [2])
    }

    @Test func aTaskThatWaitsForTheOwnerSaysWhatForAndStandsFirstInWaiting() throws {
        let start = Self.now - 600
        let outcomes: [[String: Any]] = [["id": 1, "task": 8, "attempt": 1, "title": "Send", "kind": "send", "state": "unknown"]]
        let holds: [[String: Any]] = [["id": 1, "task": 9, "kind": "stop", "state": "not_confirmed", "attempt": 1]]
        let state = try hub([
            task(1, "input-required", started: start, last: start - 50, waitingOn: "N-53"),     // the request itself
            task(2, "input-required", started: start, last: start - 40, waitingOn: "Q-68"),     // the question the request carries
            task(3, "input-required", started: start, last: start - 30, waitingOn: "Q-71"),     // its request is answered
            task(4, "input-required", started: start, last: start - 20, waitingOn: "Q-5"),      // an agent answers this one
            task(5, "auth-required", started: start, last: start - 10),
            task(6, "working", started: start, last: start, waitingOn: "juno"),
            task(7, "completed", started: start, last: start, waitingOn: "N-53"),              // over: it waits for nothing
            task(8, "canceled", started: start, last: start - 60),
            task(9, "submitted", created: start - 70),
            task(10, "input-required", started: start, last: start, waitingOn: "N-5x"),         // no reference of the hub
        ], holds: holds, outcomes: outcomes, needs: [need(53), need(63, question: 68), need(70, question: 71, answered: Self.now - 10)])
        let waits = state.ownerWaits
        #expect(waits[1] == .request(id: 53, title: "Need 53"))
        #expect(waits[2] == .request(id: 63, title: "Need 63"))
        #expect(waits[5] == .signIn)
        #expect(waits[8] == .outcome)
        #expect(waits[9] == .stop)
        #expect(Set(waits.keys) == [1, 2, 5, 8, 9])
        #expect(OwnerWait.request(id: 53, title: "Need 53").words == "Need 53")
        #expect(OwnerWait.outcome.words == "Outcome not known: check it")
        // What waits for him stands first in Waiting, newest first; then the others, newest first.
        let board = state.activity(agent: nil, period: .all, calendar: Self.utc)
        #expect(ids(board, .waiting) == [5, 2, 1, 8, 9, 10, 6, 4, 3])
        #expect(ids(board, .done) == [7])
    }

    @Test func aTaskThatWaitsForTheOwnerShowsWhateverThePeriod() throws {
        let old = Self.at(1, 9)          // twelve days before the hub's time
        let board = try hub([
            task(1, "input-required", created: old, started: old, last: old, waitingOn: "N-53"),     // waits for his answer
            task(2, "auth-required", created: old, started: old, last: old),                         // waits for his sign-in
            task(3, "input-required", created: old, started: old, last: old, waitingOn: "Q-5"),      // waits for an agent
            task(4, "working", created: old, started: old, last: old),
        ], needs: [need(53)]).activity(agent: nil, period: .today, calendar: Self.utc)
        #expect(Set(ids(board, .waiting)) == [1, 2])
        #expect(ids(board, .inProgress).isEmpty)
    }

    @Test func endedShowsWhatDidNotSucceedAndFoldsTheRestByDay() throws {
        let day = Self.at(13, 0), before = Self.at(12, 0)
        let ended = EndedTasks(try hub([
            task(1, "completed", started: day, last: day + 9 * 3600, accepted: 1, title: "CRM tickets waiting for iris: TCK-1", schedule: 23),
            task(2, "failed", started: day, last: day + 8 * 3600, accepted: 1, title: "CRM tickets waiting for iris: TCK-2", schedule: 23),
            task(3, "completed", started: day, last: day + 7 * 3600, accepted: 1, title: "CRM tickets waiting for iris: TCK-3", schedule: 23),
            task(4, "completed", started: day, last: day + 6 * 3600, accepted: 1, title: "Put your notes in order"),
            task(5, "completed", owner: "studio", started: day, last: day + 5 * 3600, accepted: 1, title: "Put your notes in order"),
            task(6, "completed", started: day, last: day + 4 * 3600, accepted: 1, title: "Put your notes in order"),
            task(7, "canceled", started: day, last: day + 3 * 3600, title: "Ship the fix"),
            task(8, "completed", started: day, last: day + 2 * 3600, accepted: 0, title: "Write the note"),
            task(9, "rejected", started: before, last: before + 3600, title: "Move the repositories"),
            task(10, "completed", started: before, last: before + 1800, title: "CRM tickets waiting for iris: TCK-9", schedule: 23),
        ]).activity(agent: nil, period: .all, calendar: Self.utc)[.done] ?? [], calendar: Self.utc)
        #expect(ended.failed.map(\.id) == [2, 8, 9])            // failed, not accepted, rejected: newest first
        #expect(ended.rest == 7)
        #expect(ended.days.map(\.start) == [day, before])
        // Today: the two other runs of the schedule are one row, and so are one agent's two tasks of one title.
        #expect(ended.days[0].groups.map { $0.tasks.map(\.id) } == [[1, 3], [4, 6], [5], [7]])
        #expect(ended.days[0].groups.map(\.title) == ["CRM tickets waiting for iris", "Put your notes in order",
                                                       "Put your notes in order", "Ship the fix"])
        #expect(ended.days[0].groups.map(\.owner) == ["vps", "vps", "studio", "vps"])
        #expect(ended.days[0].groups.map(\.id) == [3, 6, 5, 7])       // a row's oldest task: a new run does not close it
        #expect(ended.days[1].groups.map { $0.tasks.map(\.id) } == [[10]])
        #expect(ended.days[1].groups[0].title == "CRM tickets waiting for iris: TCK-9")      // one task keeps its title
        #expect(EndedTasks([]).failed.isEmpty && EndedTasks([]).days.isEmpty && EndedTasks([]).rest == 0)
    }

    @Test func aRowOfRunsIsNamedByWhatTheirTitlesBeginWith() throws {
        let runs = try hub([task(1, "completed", title: "Vulnerabilities: handle new advisory lines"),
                            task(2, "completed", title: "Vulnerabilities: handle the old ones"),
                            task(3, "completed", title: "Incident: ABC service check"),
                            task(4, "completed", title: "Incident found")]).tasks
        #expect(EndedTasks.title(of: [runs[0], runs[1]]) == "Vulnerabilities: handle")
        #expect(EndedTasks.title(of: [runs[2], runs[3]]) == "Incident: ABC service check")     // one shared word: the newest title
        #expect(EndedTasks.title(of: [runs[0], runs[0]]) == "Vulnerabilities: handle new advisory lines")
    }

    @Test func theNeedsYouCountIsTheOpenRequestsAndTheTasksOnlyTheOwnerCanMove() throws {
        let start = Self.now - 600
        let outcomes: [[String: Any]] = [
            ["id": 1, "task": 1, "attempt": 1, "title": "Send the note", "kind": "send", "state": "unknown"],
            ["id": 2, "task": 2, "attempt": 1, "title": "Post", "kind": "post", "state": "done"]]
        let holds: [[String: Any]] = [["id": 1, "task": 3, "kind": "stop", "state": "not_confirmed", "attempt": 1]]
        let needs: [[String: Any]] = [
            ["id": 1, "title": "Need 1", "why": "", "todo": "", "raised": Self.now - 300, "by": "manager", "answered": NSNull()],
            ["id": 2, "title": "Need 2", "why": "", "todo": "", "raised": Self.now - 60, "by": "manager", "answered": Self.now - 10]]
        let state = try hub([
            task(1, "canceled", started: start, last: start),                   // stopped, with an unknown send
            task(2, "canceled", started: start, last: start),                   // its outcome is recorded
            task(3, "submitted"),                                               // a stop that was not confirmed
            task(4, "working", started: start, last: start),                    // ordinary work
        ], holds: holds, outcomes: outcomes, needs: needs)
        // One open request, and the two tasks that only he can move; the answered request and the rest do not count.
        #expect(state.needsYouCount == 3)
        #expect(state.ownerTasks.map(\.id) == [3, 1])
    }

    @Test func nothingNeedsTheOwnerWhenNoRequestIsOpenAndEveryOutcomeIsKnown() throws {
        #expect(try hub([task(1, "working", started: Self.now - 60, last: Self.now - 30)]).needsYouCount == 0)
    }

    @Test func eachColumnShowsTheNewestActivityFirst() throws {
        let board = try hub([
            task(1, "completed", started: Self.now - 900, last: Self.now - 300),
            task(2, "failed", started: Self.now - 900, last: Self.now - 100),
            task(3, "canceled", created: Self.now - 300),                        // not started: the created time
            task(4, "rejected", started: Self.now - 900, last: Self.now - 200),
        ]).activity(agent: nil, period: .all, calendar: Self.utc)
        #expect(ids(board, .done) == [2, 4, 3, 1])
    }

    @Test func thePeriodUsesTheLastActivityOrTheCreatedTimeOfATaskThatHasNotStarted() throws {
        let board = try hub([
            task(1, "working", created: Self.at(1, 9), started: Self.at(1, 9), last: Self.at(13, 0, 30)),
            task(2, "working", created: Self.at(12, 8), started: Self.at(12, 9), last: Self.at(12, 23, 30)),
            task(3, "submitted", created: Self.at(7, 0, 10), last: Self.at(13, 10)),                 // the created time counts
            task(4, "completed", created: Self.at(1, 9), started: Self.at(1, 9), last: Self.at(6, 23, 59)),
            task(5, "failed", created: Self.at(1, 9, month: 9), started: Self.at(1, 9, month: 9), last: Self.at(14, 0, month: 9)),
            task(6, "canceled", created: Self.at(13, 23, month: 9)),
        ])
        func shown(_ period: ActivityPeriod) -> Set<Int> {
            Set(board.activity(agent: nil, period: period, calendar: Self.utc).values.joined().map(\.id))
        }
        #expect(shown(.today) == [1])
        #expect(shown(.week) == [1, 2, 3])               // from 7 October, 00:00
        #expect(shown(.month) == [1, 2, 3, 4, 5])        // from 14 September, 00:00
        #expect(shown(.all) == [1, 2, 3, 4, 5, 6])
    }

    @Test func theAgentFilterShowsThatAgentsTasksAndKeepsEveryChoice() throws {
        let board = try hub([task(1, "working", started: Self.now - 60, last: Self.now - 60),
                             task(2, "submitted", owner: "studio"), task(3, "completed", owner: "retired")])
        #expect(board.activity(agent: "studio", period: .all, calendar: Self.utc).values.joined().map(\.id) == [2])
        #expect(board.activity(agent: "nobody", period: .all, calendar: Self.utc).isEmpty)
        #expect(board.activity(agent: nil, period: .all, calendar: Self.utc).values.joined().count == 3)
        #expect(board.activityAgents(saved: "") == ["manager", "vps", "studio", "retired"])
        #expect(board.activityAgents(saved: "vps") == ["manager", "vps", "studio", "retired"])
        #expect(board.activityAgents(saved: "gone") == ["manager", "vps", "studio", "retired", "gone"])
    }

    @Test func onlyASuccessfulResultHasNoRedBadge() throws {
        let tasks = try hub([task(1, "completed", accepted: 1), task(2, "completed"), task(3, "completed", accepted: 0),
                             task(4, "failed"), task(5, "rejected"), task(6, "canceled"), task(7, "working")]).tasks
        #expect(tasks.map(\.failedResult) == [nil, nil, "Not accepted", "Failed", "Rejected", "Canceled", nil])
    }

    @Test func theAgeIsShortAndRelative() {
        let now = Self.now, britain = Locale(identifier: "en_GB")
        #expect(activityAge(now - 30, now: now) == "Just now")
        #expect(activityAge(now + 120, now: now) == "Just now")              // a hub clock that is behind the task's
        #expect(activityAge(now - 5 * 60 - 59, now: now) == "5 min ago")
        #expect(activityAge(now - 3 * 3600, now: now) == "3 h ago")
        #expect(activityAge(now - 86_400, now: now) == "1 day ago")
        #expect(activityAge(now - 6 * 86_400, now: now) == "6 days ago")
        #expect(activityAge(now - 10 * 86_400, now: now, calendar: Self.utc, locale: britain) == "3 Oct")
        #expect(activityAge(now - 300 * 86_400, now: now, calendar: Self.utc, locale: britain) == "17 Dec 2025")
    }
}
