import Foundation
import Testing
@testable import FleetCore

/// **An answered card says what came of his answer** (owner feature `need_marks`, API 1.280; the owner, 21 November
/// 2026: "shouldn't we show somehow that they are being done? nothing moved on the left sidebar and the cards just
/// remained with a check", and his "Yes, as drawn" to the three looks): the check, the turning mark of work, or the
/// red mark of work that failed, only from a record that proves it.
struct NeedMarksTests {
    private static let now = 1_791_903_600.0

    private func task(_ id: Int, _ state: String, title: String = "Move the shop", parked: Double? = nil,
                      accepted: Int? = nil) -> [String: Any] {
        var row: [String: Any] = ["id": id, "title": title, "details": "", "done_when": "Checked", "needs": "none",
                                  "goal": "", "owner": "dev", "requester": "manager", "state": state,
                                  "created": Self.now - 600, "attempt": 1, "restarts": 0, "nudge_level": 0,
                                  "stop_sent": 0, "started": Self.now - 500, "last_activity": Self.now - 60]
        row["parked_until"] = parked; row["accepted"] = accepted
        return row
    }

    private func need(_ extra: [String: Any]) -> [String: Any] {
        ["id": 7, "title": "Add a developer", "why": "", "todo": "", "raised": Self.now - 300, "by": "manager",
         "answer": "Yes: add dev", "answered": Self.now - 200, "options": ["Yes: add dev", "No"]]
            .merging(extra) { _, new in new }
    }

    private func reading(_ need: [String: Any], tasks: [[String: Any]] = [],
                         features: [String] = [AnsweredMark.feature]) throws -> (OwnerNeed, HubState) {
        let agents: [[String: Any]] = ["manager", "dev"].map {
            ["name": $0, "role": $0 == "manager" ? "manager" : "worker", "runtime": "claude", "can": []]
        }
        let state = try HubState.decode(JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "db": "db", "time": Self.now, "agents": agents, "tasks": tasks, "holds": [],
            "outcomes": [], "notes": [], "needs": [need], "permissions": [], "messages": [], "reports": [],
            "ui_features": features] as [String: Any]))
        return (try #require(state.needs.first), state)
    }

    @Test func aTeamCardSaysWhereItsPlanStandsAndGiveIsGiven() throws {
        let (making, inMaking) = try reading(need(["team": true, "team_state": "making"]))
        #expect(making.answeredMark(in: inMaking) == .working(words: "The hub makes the change", agent: nil, title: nil))
        let reason = "The hub did not make this change: the fleet changed after your yes. Nothing changed, and the manager knows."
        let (failed, inFailed) = try reading(need(["team": true, "team_state": "not_made", "team_reason": reason]))
        #expect(failed.answeredMark(in: inFailed) == .failed(words: reason))
        let (made, inMade) = try reading(need(["team": true, "team_state": "made"]))
        #expect(made.answeredMark(in: inMade) == .done(words: "Changed"))
        let give: [String: Any] = ["agent": "dev", "level": "write", "repos": ["acme/web"]]
        let (given, inGiven) = try reading(need(["give": give, "chosen": 0, "answer": "Give Dev write"]))
        #expect(given.answeredMark(in: inGiven) == .done(words: "Given"))
        // No on the same card, and a plain decision: the agent that raised it has his answer
        let (refused, inRefused) = try reading(need(["give": give, "chosen": 1, "answer": "No"]))
        #expect(refused.answeredMark(in: inRefused) == .done(words: "\("manager".agentLabel) has your answer"))
        // a hub before the feature: the check, also for a value that it could not have sent
        let (older, inOlder) = try reading(need(["team": true, "team_state": "making"]), features: [])
        #expect(older.answeredMark(in: inOlder) == .done(words: "\("manager".agentLabel) has your answer"))
    }

    @Test func aCardWithATaskTurnsOnlyWhileItWorksAndIsRedOnlyWhenItFailed() throws {
        let answered = need(["task": 41])
        let (working, inWork) = try reading(answered, tasks: [task(41, "working")])
        #expect(working.answeredMark(in: inWork) == .working(words: "\("dev".agentLabel) · Move the shop",
                                                                   agent: "dev", title: "Move the shop"))
        // parked until a time: no work now, so the check with its state word, and no fourth look
        let (parked, inParked) = try reading(answered, tasks: [task(41, "working", parked: Self.now + 3600)])
        let rest = try #require(inParked.tasks.first).mark(in: inParked)
        #expect(parked.answeredMark(in: inParked) == .done(words: rest.words))
        let (failed, inFailed) = try reading(answered, tasks: [task(41, "failed")])
        let failedTask = try #require(inFailed.tasks.first)
        #expect(failed.answeredMark(in: inFailed)
                == .failed(words: failedTask.failedResult ?? failedTask.mark(in: inFailed).words))
        let (done, inDone) = try reading(answered, tasks: [task(41, "completed", accepted: 1)])
        #expect(done.answeredMark(in: inDone) == .done(words: "Done"))
        // a result that waits for its check is no "Done" yet: the check with its own state word
        let (unchecked, inUnchecked) = try reading(answered, tasks: [task(41, "completed")])
        let waits = try #require(inUnchecked.tasks.first).mark(in: inUnchecked)
        #expect(unchecked.answeredMark(in: inUnchecked) == .done(words: waits.words) && waits.words != "Done")
        // a task that the reading does not hold: the check
        let (gone, inGone) = try reading(answered, tasks: [task(42, "working")])
        #expect(gone.answeredMark(in: inGone) == .done(words: "\("manager".agentLabel) has your answer"))
    }

    /// A press that waited for the store is dropped when the card changed under it (`signsTheSame`): the marks' fields
    /// change after his answer and are no words of the card, so they never make a card another one.
    @Test func theMarksFieldsDoNotMakeACardAnotherOne() throws {
        let open: [String: Any] = ["answer": NSNull(), "answered": NSNull()]
        let (before, _) = try reading(need(open))
        let (after, _) = try reading(need(open.merging(["team_state": "making", "team_reason": "Why", "task": 41]) { _, new in new }))
        #expect(before.signsTheSame(as: after))
    }
}
