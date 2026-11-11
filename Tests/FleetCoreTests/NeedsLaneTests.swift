import Foundation
import Testing
@testable import FleetCore

// Explicit test data only: requests that wait, requests that ended, and tasks that wait for a request.
struct NeedsLaneTests {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// The hub's time: 11 November 2026, 09:00 UTC.
    private static let now = at(11, 9)

    private static func at(_ day: Int, _ hour: Int) -> Double {
        utc.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!.timeIntervalSince1970
    }

    private func row(_ id: Int, answered: Double? = nil, answer: String? = nil, question: Int? = nil) -> [String: Any] {
        ["id": id, "title": "Need \(id)", "why": "", "todo": "", "raised": Self.at(1, 8) + Double(id), "by": "manager",
         "answered": answered ?? NSNull(), "answer": answer ?? (answered == nil ? NSNull() : "Yes" as Any),
         "question": question ?? NSNull()]
    }

    private func need(_ id: Int, answered: Double? = nil, answer: String? = nil) throws -> OwnerNeed {
        try JSONDecoder().decode(OwnerNeed.self, from: JSONSerialization.data(withJSONObject: row(id, answered: answered, answer: answer)))
    }

    private func task(_ id: Int, _ state: String, owner: String, waitingOn: String? = nil) -> [String: Any] {
        var row: [String: Any] = ["id": id, "title": "Task \(id)", "details": "", "done_when": "Checked", "needs": "none",
                                  "goal": "", "owner": owner, "requester": "manager", "state": state, "created": Self.now - 60,
                                  "attempt": 1, "restarts": 0, "nudge_level": 0, "stop_sent": 0]
        row["waiting_on"] = waitingOn
        return row
    }

    private func hub(tasks: [[String: Any]], needs: [[String: Any]]) throws -> HubState {
        let agents: [[String: Any]] = ["manager", "leo", "mia"].map {
            ["name": $0, "role": $0 == "manager" ? "manager" : "worker", "runtime": "codex", "can": []]
        }
        return try HubState.decode(JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "db": "test-db", "time": Self.now, "agents": agents, "tasks": tasks, "holds": [],
            "outcomes": [], "notes": [], "needs": needs, "permissions": [], "messages": [], "reports": []]))
    }

    @Test("The lane holds the requests that wait, the newest first, and not one whose answer is on its way")
    func theOpenRequests() throws {
        let needs = [try need(2), try need(7), try need(5, answered: Self.at(10, 16)), try need(9), try need(4)]
        #expect(NeedsLane(needs, now: Self.now, calendar: Self.utc).open.map(\.id) == [9, 7, 4, 2])
        // He answered 7 a moment ago: the reading still has it open, and its card left the lane.
        let lane = NeedsLane(needs, sent: [7], now: Self.now, calendar: Self.utc)
        #expect(lane.open.map(\.id) == [9, 4, 2])
        #expect(lane.endedCount == 2)
    }

    @Test("A request that is held stays in the lane, on its way or answered, and is not counted as ended")
    func aHeldRequestStays() throws {
        let needs = [try need(2), try need(7), try need(5, answered: Self.at(10, 16)), try need(9)]
        // He answered 7 a moment ago and its answer settles: it keeps its place, though its answer is on its way.
        let going = NeedsLane(needs, sent: [7], held: [7], now: Self.now, calendar: Self.utc)
        #expect(going.open.map(\.id) == [9, 7, 2])
        #expect(going.endedCount == 1)
        // The reading has the answer of 5 before its moment ended: it stays too.
        let read = NeedsLane(needs, held: [5], now: Self.now, calendar: Self.utc)
        #expect(read.open.map(\.id) == [9, 7, 5, 2])
        #expect(read.ended.isEmpty)
        // The moment ended: each one leaves, as before.
        #expect(NeedsLane(needs, sent: [7], now: Self.now, calendar: Self.utc).open.map(\.id) == [9, 2])
    }

    @Test("The requests that ended stand by day, the newest first, and an answer on its way is of today")
    func theRequestsThatEnded() throws {
        let needs = [try need(1, answered: Self.at(9, 12)), try need(2, answered: Self.at(10, 16)),
                     try need(3, answered: Self.at(10, 10)), try need(4), try need(5),
                     try need(6, answered: Self.at(9, 23))]
        let lane = NeedsLane(needs, sent: [5], now: Self.now, calendar: Self.utc)
        #expect(lane.ended.map { $0.needs.map(\.id) } == [[5], [2, 3], [6, 1]])
        #expect(lane.ended.map(\.start) == [Self.at(11, 0), Self.at(10, 0), Self.at(9, 0)])
        #expect(lane.endedCount == 5)
        // A request that the hub closed with words and no time stands at the time it was raised.
        let closed = NeedsLane([try need(8, answer: "Withdrawn")], now: Self.now, calendar: Self.utc)
        #expect(closed.open.isEmpty)
        #expect(closed.ended.map(\.start) == [Self.at(1, 0)])
    }

    @Test("The request under the one that left comes to hand, else the one over it")
    func theNextRequest() {
        let order = [9, 7, 4, 2]
        #expect(NeedsLane.successor(of: 7, in: order, open: [9, 4, 2]) == 4)     // the one that takes its place
        #expect(NeedsLane.successor(of: 2, in: order, open: [9, 7, 4]) == 4)     // the last one left: the one over it
        #expect(NeedsLane.successor(of: 7, in: order, open: [9, 2]) == 2)        // the one under it left too
        #expect(NeedsLane.successor(of: 9, in: order, open: []) == nil)          // nothing waits any more
        #expect(NeedsLane.successor(of: 3, in: order, open: [9, 7, 4, 2]) == nil) // it was not in the lane
    }

    @Test("The request at hand is the one he chose while it waits, then the one that takes its place, else the first")
    func theRequestAtHand() {
        let order = [9, 7, 4, 2]
        #expect(NeedsLane.atHand(chosen: nil, order: order, open: order) == 9)          // none chosen: the first
        #expect(NeedsLane.atHand(chosen: 4, order: order, open: order) == 4)            // his choice waits
        #expect(NeedsLane.atHand(chosen: 7, order: order, open: [9, 4, 2]) == 4)        // it left: the one under it
        #expect(NeedsLane.atHand(chosen: 2, order: order, open: [9, 7, 4]) == 4)        // the last one left: the one over it
        #expect(NeedsLane.atHand(chosen: 5, order: order, open: order) == 9)            // the lane never held it: the first
        #expect(NeedsLane.atHand(chosen: 7, order: [], open: [9, 4]) == 9)              // the page's first pass, an old choice
        #expect(NeedsLane.atHand(chosen: 7, order: order, open: []) == nil)             // nothing waits
        #expect(NeedsLane.atHand(chosen: nil, order: [], open: []) == nil)
        // A new request came while the one at hand left: the lane as it stood decides, and the new one waits its turn.
        #expect(NeedsLane.atHand(chosen: 7, order: order, open: [11, 9, 4, 2]) == 4)
    }

    @Test("An answer on its way to a request that ended, and two answers of one moment, change nothing")
    func theEdgesOfTheLane() throws {
        let needs = [try need(1, answered: Self.at(10, 12)), try need(2, answered: Self.at(10, 12)), try need(3)]
        // 1 is named as on its way, and the reading has it answered already: it ended once, at its own time.
        let lane = NeedsLane(needs, sent: [1], now: Self.now, calendar: Self.utc)
        #expect(lane.open.map(\.id) == [3])
        #expect(lane.endedCount == 2)
        // Two requests that ended in the same second stand in one order at every reading: the newer request first.
        #expect(lane.ended.map { $0.needs.map(\.id) } == [[2, 1]])
        #expect(lane.ended.map(\.start) == [Self.at(10, 0)])
    }

    @Test("A request names the agents whose work waits for its answer, each agent once")
    func theAgentsThatWait() throws {
        let state = try hub(tasks: [
            task(1, "input-required", owner: "leo", waitingOn: "N-5"),
            task(2, "input-required", owner: "mia", waitingOn: "Q-68"),      // through the question that request 7 carries
            task(3, "input-required", owner: "leo", waitingOn: "N-5"),       // the same agent, a second task
            task(4, "input-required", owner: "mia", waitingOn: "N-5"),
            task(5, "completed", owner: "mia", waitingOn: "N-9"),            // it ended: nothing waits
            task(6, "input-required", owner: "leo", waitingOn: "N-6"),       // that request has its answer
            task(7, "working", owner: "leo"),
        ], needs: [row(5), row(6, answered: Self.at(10, 10)), row(7, question: 68), row(9)])
        #expect(state.needWaits == [5: ["leo", "mia"], 7: ["mia"]])
    }

    @Test("The words of the mark name the agents")
    func theWordsOfTheMark() {
        #expect(NeedsLane.waitWords([]) == "")
        #expect(NeedsLane.waitWords(["leo"]) == "\("leo".agentLabel) waits for this")
        #expect(NeedsLane.waitWords(["leo", "mia"]) == "\("leo".agentLabel) and \("mia".agentLabel) wait for this")
        #expect(NeedsLane.waitWords(["leo", "mia", "ivy"])
            == "\("leo".agentLabel), \("mia".agentLabel) and \("ivy".agentLabel) wait for this")
    }
}
