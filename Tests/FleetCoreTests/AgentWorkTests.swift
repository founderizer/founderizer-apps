import Foundation
import Testing
@testable import FleetCore

// Explicit test data only: the counts of the Agents page (`HubState.work`) and an agent's part of its account's week
// (`AccountShares`).
struct AgentWorkTests {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// The hub's time: 19 November 2026, 15:00 UTC.
    private static let now = at(19, 15)

    private static func at(_ day: Int, _ hour: Int) -> Double {
        utc.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!.timeIntervalSince1970
    }

    private func task(_ id: Int, _ state: String, owner: String = "dev", delivered: Double? = nil, accepted: Int? = nil,
                      waitingOn: String? = nil, follows: Int? = nil) -> [String: Any] {
        var row: [String: Any] = ["id": id, "title": "Task \(id)", "details": "", "done_when": "Checked", "needs": "none",
                                  "goal": "", "owner": owner, "requester": "manager", "state": state,
                                  "created": Self.now - 30 * 86_400, "attempt": 1, "restarts": 0, "nudge_level": 0, "stop_sent": 0]
        row["started"] = Self.now - 30 * 86_400; row["last_activity"] = Self.now - 60
        row["delivered"] = delivered; row["accepted"] = accepted; row["waiting_on"] = waitingOn; row["follows"] = follows
        return row
    }

    private func hub(_ tasks: [[String: Any]], needs: [[String: Any]] = []) throws -> HubState {
        let agents: [[String: Any]] = ["manager", "dev", "ops"].map { ["name": $0, "role": $0 == "manager" ? "manager" : "worker", "runtime": "claude", "can": []] }
        return try HubState.decode(JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "db": "test-db", "time": Self.now, "agents": agents, "tasks": tasks, "holds": [],
            "outcomes": [], "notes": [], "needs": needs, "permissions": [], "messages": [], "reports": []]))
    }

    /// **Now counts by the Tasks board's rules for a task, and its orange part adds up to Needs you** (the owner's
    /// "show the number of tasks each one is currently working on"): a queued task and a task that waits for another
    /// agent's answer are no work; a request goes to the row of the agent whose task waits on it, else to the agent that
    /// raised it, or to the fleet manager's when that agent left the team; a sign-in is no request; the strip's count is
    /// the sidebar's Needs you count, and the rows add up to it.
    @Test func nowCountsWorkAndSharesOutWhatNeedsTheOwner() throws {
        func need(_ id: Int, by: String = "manager") -> [String: Any] {
            ["id": id, "title": "Need \(id)", "why": "", "todo": "", "raised": Self.now - 300, "by": by,
             "answered": NSNull(), "question": NSNull()]
        }
        let work = try hub([
            task(1, "working"),
            task(2, "working", owner: "ops"),
            task(3, "submitted"),
            task(4, "input-required", waitingOn: "Q-3"),
            task(5, "working", owner: "ops", waitingOn: "N-7"),
            task(6, "auth-required"),
        ], needs: [need(7), need(8), need(9, by: "gone")]).work(calendar: Self.utc)
        #expect(work.agents["dev"]?.inWork == 1)
        #expect(work.agents["dev"]?.needsYou == 0)
        #expect(work.agents["ops"]?.inWork == 1)
        #expect(work.agents["ops"]?.needsYou == 1)
        #expect(work.agents["manager"]?.needsYou == 2)
        #expect(work.inWork == 2)
        #expect(work.needsYou == 3)
        #expect(work.agents.values.reduce(0) { $0 + $1.needsYou } == work.needsYou)
    }

    /// **A done task counts on the day of its result**, on this Mac's calendar days, today last: a result that its
    /// requester refused or that failed is no done task but a failed one, and the work of an agent that left the team
    /// stays in the fleet's chart. The last 7 days stand beside the 7 before them. A refused result that a later task
    /// takes on (`follows`) is a review round, neither done nor failed; a failed task with a follow-up still fails.
    @Test func eachDayCountsTheResultsOfThatDay() throws {
        let work = try hub([
            task(1, "completed", delivered: Self.at(19, 9)),
            task(2, "completed", delivered: Self.at(19, 1), accepted: 1),
            task(3, "completed", delivered: Self.at(18, 23)),
            task(4, "completed", delivered: Self.at(12, 12)),
            task(5, "completed", delivered: Self.at(13, 0)),
            task(6, "completed", delivered: Self.at(5, 12)),
            task(7, "completed", delivered: Self.at(19, 8), accepted: 0),
            task(8, "failed", delivered: Self.at(17, 8)),
            task(9, "rejected", delivered: Self.at(10, 8)),
            task(10, "completed", owner: "gone", delivered: Self.at(19, 10)),
            task(11, "completed", delivered: Self.at(18, 8), accepted: 0),      // a refused round...
            task(12, "working", follows: 11),                                   // ...that the next one takes on
            task(13, "working", follows: 8),                                    // a failed task still fails
            task(14, "canceled", follows: 7),                                   // a canceled follow-up takes nothing on
        ]).work(calendar: Self.utc)
        let dev = try #require(work.agents["dev"])
        #expect(dev.done.count == FleetWork.days)
        #expect(dev.done[13] == 2)
        #expect(dev.done[12] == 1)
        #expect(dev.done[7] == 1)
        #expect(dev.done[6] == 1)
        #expect(dev.doneInDays == 5)
        #expect(work.others[13] == 1)
        #expect(work.dayTotals[13] == 3)
        #expect(work.doneWeek == 5)
        #expect(work.doneWeekBefore == 1)
        #expect(work.failedWeek == 2)
        #expect(work.failedPercent == 29)
        #expect(work.dayMost == 2)
        #expect(Self.utc.component(.day, from: Date(timeIntervalSince1970: work.dayStarts[0])) == 6)
    }

    /// **A day is a day of this Mac's calendar**, also the day that the clocks go back: in Madrid 25 October 2026 has 25
    /// hours, and a result at 23:30 that evening is a result of the 25th, not of the 26th.
    @Test func aDayOfTwentyFiveHoursKeepsItsLateResults() throws {
        var madrid = Calendar(identifier: .gregorian)
        madrid.timeZone = TimeZone(identifier: "Europe/Madrid")!
        let at = { (day: Int, hour: Int) in
            madrid.date(from: DateComponents(year: 2026, month: day < 20 ? 11 : 10, day: day, hour: hour, minute: 30))!.timeIntervalSince1970
        }
        let state = try HubState.decode(JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "db": "test-db", "time": at(2, 15), "agents": [["name": "dev", "role": "worker", "runtime": "claude", "can": []]],
            "tasks": [task(1, "completed", delivered: at(25, 23)), task(2, "completed", delivered: at(26, 0))],
            "holds": [], "outcomes": [], "notes": [], "needs": [], "permissions": [], "messages": [], "reports": []]))
        let work = state.work(calendar: madrid)
        #expect(madrid.component(.day, from: Date(timeIntervalSince1970: work.dayStarts[0])) == 20)
        #expect(work.agents["dev"]?.done[5] == 1)
        #expect(work.agents["dev"]?.done[6] == 1)
    }

    /// **An agent's own key request turns its dot orange** (the owner's "Yes" of 19 November 2026): an open item with
    /// its `secret` part that the agent raised and that no open task waits on. A card of the manager's without one is
    /// no key request, an answered one is over, and one that a task waits on is that task's agent's already.
    @Test func anAgentsOwnKeyRequestIsOneThatNoTaskWaitsOn() throws {
        func need(_ id: Int, by: String, secret: Bool = true, answered: Bool = false, question: Int? = nil) -> [String: Any] {
            var row: [String: Any] = ["id": id, "title": "Need \(id)", "why": "", "todo": "", "raised": Self.now - 300, "by": by,
                                      "answered": answered ? Self.now - 60 : NSNull(), "question": question ?? NSNull()]
            if secret { row["secret"] = ["kind": "api_key"] }
            return row
        }
        let state = try hub([task(1, "working", owner: "ops", waitingOn: "N-2"), task(2, "input-required", waitingOn: "Q-40")],
                            needs: [need(1, by: "manager", secret: false), need(2, by: "ops"), need(3, by: "dev", answered: true),
                                    need(4, by: "dev", question: 40), need(5, by: "dev"), need(6, by: "ops")])
        #expect(state.ownKeyRequest(of: "manager") == nil)
        #expect(state.ownKeyRequest(of: "dev")?.id == 5)
        #expect(state.ownKeyRequest(of: "ops")?.id == 6)
    }

    /// **An agent's own part of its account's week** shows only where the hub gave it for that window, the account's
    /// main one, and where other agents share the account: alone, its part is the whole bar.
    @Test func anAgentsPartIsOfTheMainWindowOfASharedAccount() throws {
        let shares = try JSONDecoder().decode(AccountShares.self, from: Data("""
        {"db": "test-db", "accounts": [
          {"account": "a:1", "agents": ["dev", "ops"], "shares": {"dev": 12.5, "ops": 28.5},
           "windows": [{"label": "5 hours", "main": false}, {"label": "7 days", "main": true}]},
          {"account": "a:2", "agents": ["solo"], "shares": {"solo": 16},
           "windows": [{"label": "7 days", "main": true}]}]}
        """.utf8))
        #expect(shares.share(of: "dev", account: "a:1", window: "7 days") == 12.5)
        #expect(shares.share(of: "dev", account: "a:1", window: "5 hours") == nil)
        #expect(shares.share(of: "solo", account: "a:2", window: "7 days") == nil)
        #expect(shares.share(of: "dev", account: nil, window: "7 days") == nil)
        #expect(shares.share(of: "other", account: "a:1", window: "7 days") == nil)
    }
}
