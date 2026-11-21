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
                      accepted: Int? = nil, nudged: Int = 0, waitingOn: String? = nil) -> [String: Any] {
        var row: [String: Any] = ["id": id, "title": title, "details": "", "done_when": "Checked", "needs": "none",
                                  "goal": "", "owner": "dev", "requester": "manager", "state": state,
                                  "created": Self.now - 600, "attempt": 1, "restarts": 0, "nudge_level": 0,
                                  "stop_sent": 0, "started": Self.now - 500, "last_activity": Self.now - 60]
        row["parked_until"] = parked; row["accepted"] = accepted; row["nudge_level"] = nudged; row["waiting_on"] = waitingOn
        return row
    }

    private func need(_ extra: [String: Any]) -> [String: Any] {
        ["id": 7, "title": "Add a developer", "why": "", "todo": "", "raised": Self.now - 300, "by": "manager",
         "answer": "Yes: add dev", "answered": Self.now - 200, "options": ["Yes: add dev", "No"]]
            .merging(extra) { _, new in new }
    }

    private func reading(_ need: [String: Any], tasks: [[String: Any]] = [], holds: [[String: Any]] = [],
                         outcomes: [[String: Any]] = [],
                         features: [String] = [AnsweredMark.feature]) throws -> (OwnerNeed, HubState) {
        let agents: [[String: Any]] = ["manager", "dev"].map {
            ["name": $0, "role": $0 == "manager" ? "manager" : "worker", "runtime": "claude", "can": []]
        }
        let state = try HubState.decode(JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "db": "db", "time": Self.now, "agents": agents, "tasks": tasks, "holds": holds,
            "outcomes": outcomes, "notes": [], "needs": [need], "permissions": [], "messages": [], "reports": [],
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

    /// His "Orange mark" (21 November 2026: "The same orange mark as the task's own row"): where the task's row is
    /// orange the card is orange, with the row's symbol and words, and a task whose row is muted (his own pause) is the
    /// check with its state word. The row and the card never disagree.
    @Test func whereTheTasksRowIsOrangeTheCardIsOrange() throws {
        let answered = need(["task": 41])
        func mark(_ state: HubState) throws -> (symbol: String, words: String) {
            let row = try #require(state.tasks.first).mark(in: state)
            return (row.symbol, row.words)
        }
        let (stalled, inStall) = try reading(answered, tasks: [task(41, "working", nudged: 1)])
        let stall = try mark(inStall)
        #expect(stalled.answeredMark(in: inStall) == .attention(symbol: stall.symbol, words: stall.words))
        let unconfirmed: [String: Any] = ["id": 1, "task": 41, "kind": "pause", "state": "not_confirmed", "attempt": 1]
        let (held, inHold) = try reading(answered, tasks: [task(41, "working")], holds: [unconfirmed])
        let hold = try mark(inHold)
        #expect(held.answeredMark(in: inHold) == .attention(symbol: hold.symbol, words: hold.words))
        // an outcome that is not known, which a worker with no shell cannot check: his to check
        let unknown: [String: Any] = ["id": 1, "task": 41, "attempt": 1, "title": "Charge the card", "kind": "payment",
                                      "state": "unknown"]
        let (checks, inCheck) = try reading(answered, tasks: [task(41, "working")], outcomes: [unknown])
        let check = try mark(inCheck)
        #expect(check.symbol == "questionmark.circle"
                && checks.answeredMark(in: inCheck) == .attention(symbol: check.symbol, words: check.words))
        // a wait on another agent is orange on its row, so on the card too
        let (waits, inWait) = try reading(answered, tasks: [task(41, "working", waitingOn: "manager")])
        let wait = try mark(inWait)
        #expect(waits.answeredMark(in: inWait) == .attention(symbol: wait.symbol, words: wait.words))
        // his own pause is muted on its row: the check
        let paused: [String: Any] = ["id": 1, "task": 41, "kind": "pause", "state": "paused", "attempt": 1]
        let (rests, inPause) = try reading(answered, tasks: [task(41, "working")], holds: [paused])
        #expect(rests.answeredMark(in: inPause) == .done(words: try mark(inPause).words))
        // a sign-in that the task waits for: orange, as its row
        let (signs, inSign) = try reading(answered, tasks: [task(41, "auth-required")])
        let sign = try mark(inSign)
        #expect(signs.answeredMark(in: inSign) == .attention(symbol: sign.symbol, words: sign.words))
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
