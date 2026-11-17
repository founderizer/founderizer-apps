import Foundation
import Testing
@testable import FleetCore

// Explicit test data only: one agent's tasks, a request that waits for the owner, and one message of his.
struct WorkCardTests {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// The hub's time: 13 October 2026, 15:00 UTC.
    private static let now = utc.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 15))!.timeIntervalSince1970

    private func task(_ id: Int, _ state: String, owner: String = "dev", waitingOn: String? = nil, parked: Double? = nil,
                      works: Bool? = nil, doing: String? = nil, delivered: Double? = nil, accepted: Int? = nil,
                      checked: Double? = nil, ask: String? = nil) -> [String: Any] {
        let moved = Self.now - 600 + Double(id)
        var row: [String: Any] = ["id": id, "title": "Task \(id)", "details": "", "done_when": "Checked", "needs": "none",
                                  "goal": "", "owner": owner, "requester": "lead", "state": state, "created": moved - 60,
                                  "attempt": 1, "restarts": 0, "nudge_level": 0, "stop_sent": 0, "started": moved,
                                  "last_activity": moved]
        row["waiting_on"] = waitingOn; row["parked_until"] = parked; row["works"] = works; row["doing"] = doing
        row["delivered"] = delivered; row["accepted"] = accepted; row["checked_at"] = checked; row["ask"] = ask
        return row
    }

    private func need(_ id: Int, question: Int? = nil, answered: Double? = nil) -> [String: Any] {
        ["id": id, "title": "Need \(id)", "why": "", "todo": "", "raised": Self.now - 300, "by": "manager",
         "answered": answered ?? NSNull(), "question": question ?? NSNull(), "ask": NSNull()]
    }

    private func hub(_ tasks: [[String: Any]], needs: [[String: Any]] = [], messages: [[String: Any]] = []) throws -> HubState {
        let agents: [[String: Any]] = ["manager", "lead", "dev"].map {
            ["name": $0, "role": $0 == "manager" ? "manager" : $0 == "lead" ? "lead" : "worker", "runtime": "codex", "can": []]
        }
        return try HubState.decode(JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "db": "test-db", "time": Self.now, "agents": agents, "tasks": tasks, "holds": [],
            "outcomes": [], "notes": [], "needs": needs, "permissions": [], "messages": messages, "reports": []]))
    }

    private func card(_ state: HubState, agent: String = "dev") -> WorkCard {
        WorkCard(state, agent: agent, asks: state.asks, calendar: Self.utc)
    }

    @Test func aQuestionThatWentUpToHisRequestIsARowByTheRequestsTitle() throws {
        // Task 1 asked its lead (Q-7), and the manager took the question to him as request 5.
        let state = try hub([task(1, "input-required", waitingOn: "Q-7")], needs: [need(5, question: 7)])
        let work = card(state)
        #expect(work.waits == [WorkCard.Wait(id: 1, title: "Need 5", line: "Waits for you", request: 5)])
        #expect(work.waiting.isEmpty)
        // The dot says the same, and not "Waiting for Lead".
        #expect(state.ownerWaits(of: state.tasks)[1]?.statusWords == "Waits for you: Need 5")
    }

    @Test func aQuestionThatAnAgentAnswersOnlyWaits() throws {
        // Q-8 is with the lead: no request of his carries it, and one that he answered carries nothing.
        let state = try hub([task(1, "input-required", waitingOn: "Q-8"), task(2, "input-required", waitingOn: "Q-9")],
                            needs: [need(6, question: 9, answered: Self.now - 60)])
        let work = card(state)
        #expect(work.waits.isEmpty)
        #expect(work.waiting.map(\.id) == [2, 1])
        #expect(state.ownerWaits(of: state.tasks).isEmpty)
    }

    @Test func eachTaskInWorkNowIsARowAndParkedWorkWaits() throws {
        let state = try hub([
            task(1, "working", works: true, doing: "Runs the tests"),
            task(2, "working", parked: Self.now + 3600, works: false),
            task(3, "working", works: false),
            task(4, "submitted"),
            task(5, "working", owner: "lead", works: true),
            task(6, "working", works: true),
        ])
        let work = card(state)
        #expect(work.working.map(\.id) == [6, 1])
        #expect(work.working.last?.doing == "Runs the tests")
        #expect(work.waiting.map(\.id) == [4, 3, 2])
    }

    @Test func doneTodayCountsTheResultsThatTheirCheckAccepted() throws {
        let today = Self.now - 3600, yesterday = Self.now - 20 * 3600
        let state = try hub([
            task(1, "completed", delivered: today, accepted: 1),
            task(2, "completed", delivered: today),
            task(8, "completed", accepted: 1, checked: today),
            task(9, "completed", accepted: 1),
            task(3, "completed", delivered: today, accepted: 0),
            task(4, "completed", delivered: yesterday, accepted: 1),
            task(5, "failed", delivered: today),
            task(6, "canceled", delivered: today),
            task(7, "completed", owner: "lead", delivered: today, accepted: 1),
        ])
        let work = card(state)
        // 8 has no delivery time and its check today; 9 has neither, so no day.
        #expect(work.done.map(\.id) == [8, 1])
        #expect(work.waits.isEmpty && work.working.isEmpty && work.waiting.isEmpty)
    }

    @Test func whatHeAskedThisAgentForIsAskedsAndNotWorks() throws {
        // He asked dev in its chat: "a" waits for his request 5 (a row of Asked), "b" only waits ("1 waiting" of Asked),
        // "c" ended today. He asked the lead for "d", and dev works on it: that is dev's work.
        let messages: [[String: Any]] = [("a", "dev"), ("b", "dev"), ("c", "dev"), ("d", "lead")].map { id, to in
            ["request_id": id, "recipient": to, "kind": "message", "text": "Words of \(id)", "event_id": 1,
             "created": Self.now - 3600, "client": "test", "asked": "Thing \(id)"]
        }
        let state = try hub([
            task(1, "input-required", waitingOn: "Q-7", ask: "a"), task(2, "input-required", waitingOn: "N-6"),
            task(3, "working", parked: Self.now + 600, works: false, ask: "b"),
            task(4, "completed", delivered: Self.now - 60, accepted: 1, ask: "c"),
            task(5, "working", parked: Self.now + 600, works: false, ask: "d"),
        ], needs: [need(5, question: 7), need(6)], messages: messages)
        let asked = AskedCard(state.asks, agent: "dev", after: Self.now - 3600)
        #expect(asked.rows.map(\.task) == [4, 1])
        #expect(asked.waiting == 1)
        let work = card(state)
        #expect(work.waits.map(\.id) == [2])
        #expect(work.waiting.map(\.id) == [5])
        #expect(work.done.isEmpty)
    }

    @Test func anAgentWithNothingToSayHasNoCard() throws {
        let state = try hub([task(1, "completed", delivered: Self.now - 20 * 3600, accepted: 1), task(2, "working", owner: "lead")])
        #expect(card(state).isEmpty)
    }

    @Test func oneAgentsWaitsAreTheFleetsWaitsOfItsTasks() throws {
        let state = try hub([task(1, "input-required", waitingOn: "Q-7"), task(2, "input-required", owner: "lead", waitingOn: "N-6"),
                             task(3, "auth-required")], needs: [need(5, question: 7), need(6)])
        let mine = state.tasks.filter { $0.owner == "dev" }
        #expect(state.ownerWaits(of: mine) == state.ownerWaits.filter { key, _ in mine.contains { $0.id == key } })
        #expect(state.ownerWaits(of: mine)[3]?.statusWords == "Sign-in needed")
    }
}
