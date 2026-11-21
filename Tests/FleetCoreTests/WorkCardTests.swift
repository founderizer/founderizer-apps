import Foundation
import Testing
@testable import FleetCore

// Explicit test data only: the tasks of a few agents, the cases of their duties, a request that waits for the owner,
// and one message of his.
struct WorkCardTests {
    /// The hub's time: 13 October 2026, 15:00 UTC.
    private static let now = 1_791_903_600.0
    private static let hour = 3600.0

    private func task(_ id: Int, _ state: String, owner: String = "dev", title: String? = nil, waitingOn: String? = nil,
                      parked: Double? = nil, works: Bool? = nil, doing: String? = nil, delivered: Double? = nil,
                      accepted: Int? = nil, checked: Double? = nil, ask: String? = nil, parent: Int? = nil,
                      follows: Int? = nil, dutyCase: Int? = nil) -> [String: Any] {
        let moved = delivered ?? Self.now - 600 + Double(id)       // a delivery is a task's last move
        var row: [String: Any] = ["id": id, "title": title ?? "Task \(id)", "details": "", "done_when": "Checked",
                                  "needs": "none", "goal": "", "owner": owner, "requester": "lead", "state": state,
                                  "created": moved - 60, "attempt": 1, "restarts": 0, "nudge_level": 0, "stop_sent": 0,
                                  "started": moved, "last_activity": moved]
        row["waiting_on"] = waitingOn; row["parked_until"] = parked; row["works"] = works; row["doing"] = doing
        row["delivered"] = delivered; row["accepted"] = accepted; row["checked_at"] = checked; row["ask"] = ask
        row["parent"] = parent; row["follows"] = follows; row["duty_case"] = dutyCase
        return row
    }

    private func closed(_ id: Int, _ title: String, ago: Double, outcome: String = "handled", note: String? = nil,
                        facts: [String: String]? = nil, openedIn: Int? = nil, repeated: Bool = false) -> [String: Any] {
        ["id": id, "responsibility": 1, "key": title, "title": title, "state": "closed", "opened": Self.now - ago - 600,
         "opened_in": openedIn ?? NSNull(), "closed": Self.now - ago, "closed_by": "dev", "outcome": outcome,
         "note": note ?? NSNull(), "facts": facts ?? NSNull(), "repeated": repeated]
    }

    private func need(_ id: Int, question: Int? = nil, answered: Double? = nil) -> [String: Any] {
        ["id": id, "title": "Need \(id)", "why": "", "todo": "", "raised": Self.now - 300, "by": "manager",
         "answered": answered ?? NSNull(), "question": question ?? NSNull(), "ask": NSNull()]
    }

    private func hub(_ tasks: [[String: Any]], needs: [[String: Any]] = [], messages: [[String: Any]] = [],
                     duties: Any? = nil) throws -> HubState {
        let agents: [[String: Any]] = ["manager", "lead", "dev"].map {
            ["name": $0, "role": $0 == "manager" ? "manager" : $0 == "lead" ? "lead" : "worker", "runtime": "codex", "can": []]
        }
        var state: [String: Any] = ["schema_version": 1, "db": "test-db", "time": Self.now, "agents": agents,
                                    "tasks": tasks, "holds": [], "outcomes": [], "notes": [], "needs": needs,
                                    "permissions": [], "messages": messages, "reports": []]
        state["responsibilities"] = duties
        return try HubState.decode(JSONSerialization.data(withJSONObject: state))
    }

    private func duty(agent: String = "dev", open: [[String: Any]] = [], recent: [[String: Any]]) -> [[String: Any]] {
        [["id": 1, "agent": agent, "title": "Answer each ticket", "cases": open, "joined": [], "recent": recent]]
    }

    private func card(_ state: HubState, agent: String = "dev") -> WorkCard {
        WorkCard(state, agent: agent, asks: state.asks)
    }

    @Test func aQuestionThatWentUpToHisRequestIsARowByTheRequestsTitle() throws {
        // Task 1 asked its lead (Q-7), and the manager took the question to him as request 5.
        let state = try hub([task(1, "input-required", waitingOn: "Q-7")], needs: [need(5, question: 7)])
        let work = card(state)
        #expect(work.waits == [WorkCard.Wait(id: 1, title: "Need 5", line: "Waits for you", request: 5)])
        // The dot says the same, and not "Waiting for Lead".
        #expect(state.ownerWaits(of: state.tasks)[1]?.statusWords == "Waits for you: Need 5")
    }

    @Test func aQuestionThatAnAgentAnswersIsNoRow() throws {
        // Q-8 is with the lead: no request of his carries it, and one that he answered carries nothing.
        let state = try hub([task(1, "input-required", waitingOn: "Q-8"), task(2, "input-required", waitingOn: "Q-9")],
                            needs: [need(6, question: 9, answered: Self.now - 60)])
        #expect(card(state).isEmpty)
        #expect(state.ownerWaits(of: state.tasks).isEmpty)
    }

    /// The owner, 17 November 2026: "'resolved ticket TCK-xxxxx' instead of the specific tasks performed to resolve
    /// it". A ticket is one row by its case, with what its agent recorded, and the card shows the three newest things.
    @Test func theNewestThingsThatEndedAreRowsByTheirCasesAndNotByTheirTasks() throws {
        let state = try hub([
            task(1, "completed", title: "CRM tickets waiting for dev: TCK-1", delivered: Self.now - 5 * Self.hour, accepted: 1, dutyCase: 11),
            task(2, "completed", title: "CRM tickets waiting for dev: TCK-2", delivered: Self.now - 2 * Self.hour, accepted: 1, dutyCase: 12),
            task(3, "completed", title: "Look again at TCK-2", delivered: Self.now - Self.hour, accepted: 1, dutyCase: 12),
            task(4, "completed", title: "Tidy the old reports", delivered: Self.now - 3 * Self.hour, accepted: 1),
            task(5, "completed", title: "CRM tickets waiting for dev: TCK-5", delivered: Self.now - 80 * Self.hour, accepted: 1, dutyCase: 15),
            task(6, "completed", title: "Write the weekly numbers", delivered: Self.now - 1800),       // no check yet
            task(9, "canceled", title: "Tidy the logs", delivered: Self.now - 900),
            task(7, "completed", title: "CRM tickets waiting for dev: TCK-2", delivered: Self.now - 4 * Self.hour, accepted: 1, dutyCase: 13),
            // Its case closed before the hub's 72 hours, and its check came now: no news of the case.
            task(8, "completed", title: "Report D-17", delivered: Self.now - 100 * Self.hour, accepted: 1, checked: Self.now - 1800, dutyCase: 16),
        ], duties: duty(recent: [
            closed(12, "TCK-2", ago: Self.hour, facts: ["resolution": "Reassigned to Ana", "symptom": "Wrong price"]),
            closed(14, "Weekly report", ago: 2 * Self.hour, note: "Sent to the owner."),   // no task: a duty's own close
            closed(13, "TCK-2", ago: 4 * Self.hour, facts: ["resolution": "Drafted"]),     // the same ticket before
            closed(11, "TCK-1", ago: 5 * Self.hour, facts: ["resolution": "Drafted"]),
        ]))
        let ended = card(state).ended
        // TCK-2 is one row for its two cases and three tasks; TCK-1 is fourth; TCK-5 ended more than 72 hours ago; the
        // weekly numbers wait for their check and the logs were canceled, so neither is a row.
        #expect(ended.map(\.title) == ["TCK-2", "Weekly report", "Tidy the old reports"])
        #expect(ended.map(\.words) == ["Reassigned to Ana", "Handled", "Done"])
        #expect(ended.map(\.endedAt) == [Self.now - Self.hour, Self.now - 2 * Self.hour, Self.now - 3 * Self.hour])
        #expect(ended.map(\.id) == [.dutyCase(12), .dutyCase(14), .task(4)])
        #expect(state.workItem(.dutyCase(12))?.tasks.map(\.id) == [2, 3, 7])
        #expect(state.workItem(.dutyCase(13))?.id == .dutyCase(12))      // a page of the older case shows the ticket now
        // "Done" only once its check accepted it, as the card Asked says it.
        #expect(state.workItem(.task(6))?.result?.words == "Awaiting check")
    }

    /// The work of a subtask or a follow-up is the work of the thing that its task belongs to: the lead's task of an
    /// incident gave the developer a subtask, and the incident is the developer's row too. Its page lists every
    /// task of it, each subtask under the task that gave it.
    @Test func aSubtaskAndAFollowUpBelongToTheCaseOfTheirTask() throws {
        let state = try hub([
            task(1, "completed", owner: "lead", title: "Have dev find the cause", delivered: Self.now - 3 * Self.hour, accepted: 1, dutyCase: 7),
            task(2, "completed", title: "Find the cause", delivered: Self.now - 3 * Self.hour, accepted: 1, parent: 1),
            task(3, "completed", title: "Put the report on config", delivered: Self.now - 3 * Self.hour, accepted: 1, parent: 1),
            task(4, "completed", owner: "lead", title: "Have dev fix it", delivered: Self.now - 2 * Self.hour, accepted: 1, follows: 1),
            task(5, "completed", title: "Fix it", delivered: Self.now - 2 * Self.hour, accepted: 1, parent: 4),
        ], duties: [["id": 1, "agent": "lead", "cases": [], "recent": [closed(7, "The queue does not empty", ago: Self.hour)]]])
        #expect(card(state).ended.map(\.title) == ["The queue does not empty"])
        #expect(card(state, agent: "lead").ended.map(\.id) == [.dutyCase(7)])
        let item = try #require(state.workItem(.dutyCase(7)))
        #expect(item.lines.map(\.task.id) == [1, 2, 3, 4, 5])
        #expect(item.lines.map(\.depth) == [0, 1, 1, 0, 1])
    }

    /// The hub files an agent's wake-ups and reviews under its lead's one task for the team. That task is the lead's;
    /// the agent's review is its own thing, and the lead's task lists it on its page.
    @Test func workUnderTheLeadsTaskForTheTeamIsTheAgentsOwn() throws {
        let state = try hub([
            task(20, "working", owner: "lead", title: "Your team's wake-up and case results", works: false),
            task(21, "completed", title: "Put your lessons in order", delivered: Self.now - 1800, accepted: 1, parent: 20),
        ])
        #expect(card(state).ended.map(\.title) == ["Put your lessons in order"])
        #expect(card(state, agent: "lead").isEmpty)
        #expect(state.workItem(.task(20))?.lines.map(\.depth) == [0, 1])
    }

    /// A case's result is what its checks said too: a task of it that its check refused is red, and a fix that
    /// follows it keeps the thing open until the fix ends. Its page lists the task that opened it, which opened two
    /// cases and so names neither in its own case.
    @Test func aCaseIsNotDoneWhileItsCheckRefusesItAndItsPageListsTheTaskThatOpenedIt() throws {
        let tasks = [
            task(30, "completed", title: "Advisory lines", delivered: Self.now - 3 * Self.hour, accepted: 1),
            task(31, "completed", title: "Patch the image library", delivered: Self.now - 2 * Self.hour, accepted: 0, dutyCase: 32),
        ]
        let duties = duty(recent: [closed(32, "The image library advisory", ago: 2 * Self.hour, openedIn: 30)])
        let refused = try hub(tasks, duties: duties)
        #expect(card(refused).ended.map(\.words) == ["Not accepted", "Done"])
        #expect(card(refused).ended.first?.end == .failed)
        #expect(refused.workItem(.dutyCase(32))?.lines.map(\.task.id) == [30, 31])
        let fixing = try hub(tasks + [task(33, "working", title: "Patch it again", works: false, follows: 31)], duties: duties)
        #expect(card(fixing).ended.map(\.id) == [.task(30)])
    }

    /// One key is one event: a check's condition that fires again opens a case that the hub marks as the event come
    /// back, and that incident is a row of its own.
    @Test func anEventThatCameBackIsAThingOfItsOwn() throws {
        let state = try hub([
            task(51, "completed", delivered: Self.now - 5 * Self.hour, accepted: 1, dutyCase: 50),
            task(53, "completed", delivered: Self.now - Self.hour, accepted: 1, dutyCase: 52),
        ], duties: duty(recent: [closed(52, "The queue stopped", ago: Self.hour, repeated: true),
                                 closed(50, "The queue stopped", ago: 5 * Self.hour)]))
        #expect(card(state).ended.map(\.id) == [.dutyCase(52), .dutyCase(50)])
    }

    @Test func theThingInWorkNowIsARowByItsNameWithWhatItDoes() throws {
        let state = try hub([
            task(1, "working", title: "Report D-29 from R-9/C-899", works: true, doing: "Reads the stock check", dutyCase: 8),
            task(2, "working", parked: Self.now + 3600, works: false, dutyCase: 9),
            task(3, "working", owner: "lead", works: true),
            // Its session closed its case and still delivers: one row, of work now.
            task(4, "working", title: "CRM tickets waiting for dev: TCK-9", works: true, doing: "Delivers its result", dutyCase: 10),
        ], duties: duty(open: [["id": 8, "title": "Amazon DE keeps a back order in stock", "state": "open"],
                               ["id": 9, "title": "A parked case", "state": "open"]],
                        recent: [closed(10, "TCK-9", ago: 60, facts: ["resolution": "Drafted"])]))
        let work = card(state)
        #expect(work.working.map(\.id) == [.dutyCase(10), .dutyCase(8)])
        #expect(work.working.last == WorkCard.Row(id: .dutyCase(8), title: "Amazon DE keeps a back order in stock",
                                                  words: "Reads the stock check", endedAt: nil, end: nil))
        #expect(work.ended.isEmpty)
        // A page opened for task 1 before it opened its case follows it to the case.
        #expect(state.workItem(.task(1))?.id == .dutyCase(8))
    }

    @Test func whatHeAskedThisAgentForIsAskedsAndNotWorks() throws {
        // He asked dev in its chat: "a" waits for his request 5 (a row of Asked), "c" ended. He asked the lead for "d",
        // and dev's task of it ended: that is dev's work.
        let messages: [[String: Any]] = [("a", "dev"), ("c", "dev"), ("d", "lead")].map { id, to in
            ["request_id": id, "recipient": to, "kind": "message", "text": "Words of \(id)", "event_id": 1,
             "created": Self.now - 3600, "client": "test", "asked": "Thing \(id)"]
        }
        let state = try hub([
            task(1, "input-required", waitingOn: "Q-7", ask: "a"), task(2, "input-required", waitingOn: "N-6"),
            task(4, "completed", delivered: Self.now - 60, accepted: 1, ask: "c"),
            task(5, "completed", delivered: Self.now - 60, accepted: 1, ask: "d"),
        ], needs: [need(5, question: 7), need(6)], messages: messages)
        let asked = AskedCard(state.asks, agent: "dev", after: Self.now - 3600)
        #expect(asked.rows.map(\.task) == [4, 1])
        let work = card(state)
        #expect(work.waits.map(\.id) == [2])
        #expect(work.ended.map(\.id) == [.task(5)])
    }

    @Test func anAgentWithNothingToSayHasNoCard() throws {
        let state = try hub([task(1, "completed", delivered: Self.now - 80 * Self.hour, accepted: 1),
                             task(2, "working", owner: "lead")])
        #expect(card(state).isEmpty)
    }

    /// One strict field once made every read of the state fail: duties of a shape that this app does not read lose
    /// their cases, and nothing else.
    @Test func dutiesOfAnotherShapeLoseOnlyTheirCases() throws {
        let state = try hub([task(1, "completed", delivered: Self.now - 60, accepted: 1, dutyCase: 3)],
                            duties: [["id": 1, "cases": "not a list"]])
        #expect(state.tasks.count == 1)
        #expect(state.responsibilities?.byID.isEmpty == true)
        #expect(card(state).ended.map(\.words) == ["Done"])
    }

    @Test func oneAgentsWaitsAreTheFleetsWaitsOfItsTasks() throws {
        let state = try hub([task(1, "input-required", waitingOn: "Q-7"), task(2, "input-required", owner: "lead", waitingOn: "N-6"),
                             task(3, "auth-required")], needs: [need(5, question: 7), need(6)])
        let mine = state.tasks.filter { $0.owner == "dev" }
        #expect(state.ownerWaits(of: mine) == state.ownerWaits.filter { key, _ in mine.contains { $0.id == key } })
        #expect(state.ownerWaits(of: mine)[3]?.statusWords == "Sign-in needed")
    }

    @Test func aTaskOfWhatHeAskedThatFollowsAThingIsAskedsAndTheThingKeepsItsOwnEnd() throws {
        // Feedback on a task (owner API 1.279): the task that answers it follows the task and has his ask. While it
        // works, and once it ended, it is a row of Asked only; the thing that it follows keeps its own end and result
        // in Work, and never takes the asked task's (the card's rule: no task is in both cards).
        let messages: [[String: Any]] = [["request_id": "a", "recipient": "dev", "kind": "message", "text": "Words of a",
                                          "event_id": 1, "created": Self.now - 600, "client": "test", "asked": "Thing a"]]
        for (next, delivered) in [("working", nil), ("completed", Self.now - 60)] as [(String, Double?)] {
            let state = try hub([
                task(1, "completed", title: "Fix the export", delivered: Self.now - 3 * Self.hour, accepted: 1),
                task(2, next, title: "Fix the export again", works: next == "working", doing: "Reads it",
                     delivered: delivered, accepted: delivered == nil ? nil : 1, ask: "a", follows: 1),
            ], messages: messages)
            let work = card(state)
            #expect(work.working.isEmpty, "\(next)")
            #expect(work.ended.map(\.id) == [.task(1)], "\(next)")
            #expect(work.ended.first?.endedAt == Self.now - 3 * Self.hour, "\(next)")
            #expect(AskedCard(state.asks, agent: "dev", after: Self.now - 3600).rows.map(\.task) == [2], "\(next)")
        }
    }
}
