import Foundation
import Testing
@testable import FleetCore

// Explicit test data only: example agents, tasks of a narrowed pair, and the owner's messages about a task and a job.
struct FeedbackTests {
    /// The hub's time: 13 October 2026, 15:00 UTC.
    private static let now = 1_791_903_600.0

    private func task(_ id: Int, owner: String, requester: String, _ more: [String: Any] = [:]) -> [String: Any] {
        var row: [String: Any] = ["id": id, "title": "Task \(id)", "details": "", "done_when": "Checked", "needs": "none",
                                  "goal": "", "owner": owner, "requester": requester, "state": "completed",
                                  "created": Self.now - 600, "attempt": 1, "restarts": 0, "nudge_level": 0, "stop_sent": 0,
                                  "started": Self.now - 590, "last_activity": Self.now - 500, "accepted": 1]
        for (key, value) in more { row[key] = value }
        return row
    }

    private func hub(_ tasks: [[String: Any]], messages: [[String: Any]] = [], reports: [[String: Any]] = [],
                     needs: [[String: Any]] = [], duties: Any? = nil,
                     features: [String] = ["direct_chat", "message_about"]) throws -> HubState {
        // nova and the manager take messages in their chats; atlas does not (`direct_chat` false).
        let agents: [[String: Any]] = [
            ["name": "manager", "role": "manager", "runtime": "codex", "can": []],
            ["name": "nova", "role": "lead", "runtime": "codex", "can": [], "direct_chat": true],
            ["name": "atlas", "role": "worker", "runtime": "codex", "can": [], "direct_chat": false],
        ]
        var state: [String: Any] = [
            "schema_version": 1, "db": "test-db", "time": Self.now, "agents": agents, "tasks": tasks, "holds": [],
            "outcomes": [], "notes": [], "needs": needs, "permissions": [], "messages": messages, "reports": reports,
            "ui_features": features]
        state["responsibilities"] = duties
        return try HubState.decode(JSONSerialization.data(withJSONObject: state))
    }

    /// The bug that this catches: his feedback goes to a chat that the hub lets read no record of the task (409
    /// `about_unreadable`, his words lost behind a refusal), to the owner himself, or names a narrowed pair's task.
    @Test func theFeedbackOnATaskGoesToItsAgentElseToItsRequesterAndToNoneThatCannotReadIt() throws {
        let state = try hub([
            task(1, owner: "nova", requester: "manager"),
            task(2, owner: "atlas", requester: "nova"),         // its agent has no chat: its requester's does
            task(3, owner: "atlas", requester: "owner"),        // the owner is no agent: nobody
            task(4, owner: "nova", requester: "manager", ["scope_person": 7]),   // a narrowed pair's: nobody
            task(5, owner: "atlas", requester: "manager"),
        ])
        #expect(state.feedback(onTask: 1) == Feedback(recipient: "nova", about: .task(1)))
        #expect(state.feedback(onTask: 2) == Feedback(recipient: "nova", about: .task(2)))
        #expect(state.feedback(onTask: 3) == nil)
        #expect(state.feedback(onTask: 4) == nil)
        #expect(state.feedback(onTask: 5) == Feedback(recipient: "manager", about: .task(5)))
        #expect(state.feedback(onTask: 99) == nil)
        // A hub with no direct chat: only the Fleet Manager's chat takes messages.
        let older = try hub([task(1, owner: "nova", requester: "manager")], features: [])
        #expect(older.feedback(onTask: 1) == Feedback(recipient: "manager", about: .task(1)))
    }

    /// The bug that this catches: the job's message names a task that its agent neither does nor asked for, or a
    /// narrowed pair's, which the hub refuses; or a job whose agent has no chat gets a box.
    @Test func theFeedbackOnAJobNamesATaskOfItThatItsAgentDoesElseAskedFor() throws {
        let state = try hub([
            task(20, owner: "atlas", requester: "nova"),
            task(21, owner: "nova", requester: "manager", ["scope_person": 3]),
            task(22, owner: "nova", requester: "manager"),
            task(23, owner: "atlas", requester: "manager"),
        ])
        func level(_ agent: String, _ ids: [Int]) -> JobLevel {
            JobLevel(title: "A job", agent: agent, request: nil,
                     lines: ids.compactMap { id in state.tasks.first { $0.id == id } }.map { WorkItem.Line(task: $0, depth: 0) },
                     taskIDs: Set(ids), replaced: [], open: [], result: nil, recorded: nil, endedAt: nil)
        }
        #expect(state.feedback(onJob: level("nova", [20, 21, 22])) == Feedback(recipient: "nova", about: .job(22)))
        #expect(state.feedback(onJob: level("nova", [20, 23])) == Feedback(recipient: "nova", about: .job(20)))
        #expect(state.feedback(onJob: level("nova", [21, 23])) == nil)
        #expect(state.feedback(onJob: level("atlas", [20, 23])) == nil)
    }

    /// The bug that this catches: a wake-up that opened two cases of a duty is the work of neither (the hub names neither
    /// in its `duty_case`), but each case's card lists it as the task that opened it; his feedback on one ticket named
    /// that wake-up, so its badge named and opened the wake-up's job, and his message stood on the card of each case.
    /// The feedback names the case's own task, its badge opens that case, and a message that names the wake-up stands
    /// on neither case's card.
    @Test func feedbackOnACaseNamesItsOwnTaskAndNeverTheSessionThatOpenedIt() throws {
        func open(_ id: Int, _ title: String) -> [String: Any] {
            ["id": id, "responsibility": 1, "key": title, "title": title, "state": "open", "opened": Self.now - 300,
             "opened_in": 30]
        }
        func message(_ id: String, about: [String: Any]) -> [String: Any] {
            ["request_id": id, "recipient": "nova", "kind": "message", "text": "Words of \(id)", "event_id": 1,
             "created": Self.now - 30, "client": "test", "about": about]
        }
        let state = try hub([task(30, owner: "nova", requester: "manager", ["title": "Read the new tickets"]),
                             task(31, owner: "nova", requester: "manager", ["title": "Answer ticket A", "duty_case": 11,
                                                                           "state": "working", "works": true]),
                             task(32, owner: "nova", requester: "manager", ["title": "Answer ticket B", "duty_case": 12])],
                            messages: [message("a", about: ["job": 31, "title": "Ticket A"]),
                                       message("w", about: ["job": 30, "title": "Read the new tickets"])],
                            duties: [["id": 1, "agent": "nova", "title": "Answer each ticket",
                                      "cases": [open(11, "Ticket A"), open(12, "Ticket B")], "joined": [], "recent": []]])
        let a = try #require(state.levels(of: DetailCard(.work("nova", .dutyCase(11)))).shown)
        let b = try #require(state.levels(of: DetailCard(.work("nova", .dutyCase(12)))).shown)
        #expect(a.lines.map(\.task.id) == [30, 31], "the card lists the session that opened the case")
        #expect(state.feedback(onJob: a) == Feedback(recipient: "nova", about: .job(31)))
        #expect(state.feedback(onJob: b) == Feedback(recipient: "nova", about: .job(32)))
        #expect(state.messages(aboutJob: a).map(\.request_id) == ["a"])
        #expect(state.messages(aboutJob: b).isEmpty)
        // The badge names the case, and opens it as a job of the board, by its own id.
        let badge = state.badge(about: MessageAbout(place: .job(31), title: "Ticket A"), jobs: state.jobsByTask)
        #expect(badge?.title == "Ticket A" && badge?.standing?.opens == .job("case 11", board: nil))
    }

    /// The bug that this catches: one `about` of a shape that this app does not read made every read of the state
    /// fail (as one strict field once did); and a card shows feedback that names another task, or misses the agent's
    /// answers to it; or his feedback on a job leaves the job's card when the task that it names is canceled later.
    @Test func aMessageSaysWhatItIsAboutAndAShapeThatTheAppDoesNotReadIsNone() throws {
        func message(_ id: String, at: Double, about: Any?) -> [String: Any] {
            var row: [String: Any] = ["request_id": id, "recipient": "nova", "kind": "message", "text": "Words of \(id)",
                                      "event_id": 1, "created": Self.now - at, "client": "test"]
            row["about"] = about
            return row
        }
        let state = try hub([task(1, owner: "nova", requester: "manager"),
                             task(2, owner: "nova", requester: "manager", ["job": 1]),
                             task(3, owner: "nova", requester: "manager", ["job": 1, "state": "canceled"]),
                             task(4, owner: "nova", requester: "manager")],
                            messages: [message("b", at: 100, about: ["task": 1, "title": "Task 1"]),
                                       message("a", at: 200, about: ["task": 1, "title": NSNull()]),
                                       message("j", at: 50, about: ["job": 2, "title": "A job"]),
                                       message("c", at: 60, about: ["job": 3, "title": "A job"]),   // its task canceled since
                                       message("o", at: 70, about: ["job": 4, "title": "Task 4"]),  // another job's
                                       message("x", at: 40, about: ["task": "one"]),
                                       message("y", at: 30, about: "task 1"),
                                       message("z", at: 20, about: nil)],
                            reports: [["agent": "nova", "in_reply_to": "b", "id": 1, "text": "On it", "about": "",
                                       "created": Self.now - 90],
                                      ["agent": "nova", "turn": "b", "id": 2, "text": "Started", "about": "",
                                       "created": Self.now - 95],
                                      ["agent": "nova", "in_reply_to": "j", "id": 3, "text": "Other", "about": "",
                                       "created": Self.now - 40]])
        #expect(state.messages.count == 8)
        #expect(state.messages(aboutTask: 1).map(\.request_id) == ["a", "b"])
        #expect(state.messages.first { $0.request_id == "b" }?.about?.title == "Task 1")
        #expect(state.messages.filter { $0.about?.place == nil }.map(\.request_id).sorted() == ["x", "y", "z"])
        // The job's card lists tasks 1 and 2: the canceled task 3 is not in its list, and its feedback stays.
        let job = try #require(state.levels(of: DetailCard(.job("task 1", board: nil))).shown)
        #expect(job.lines.map(\.task.id) == [1, 2])
        #expect(state.messages(aboutJob: job).map(\.request_id) == ["c", "j"])
        let b = try #require(state.messages.first { $0.request_id == "b" })
        #expect(state.replies(to: b).map(\.id) == [2, 1])
    }

    /// The bug that this catches: the badge over his message in the agent's chat names a task by the title that the hub
    /// gave where the reading has the task, marks it otherwise than the board (no orange hand while it waits for him, no
    /// green of work while it works, red for good on a failure that a follow-up put right), names or marks a job
    /// otherwise than its card (also one that ended, and one whose open task neither works nor waits for him), loses the
    /// job of a task that somebody canceled after he wrote, opens one agent's part of a job or the level of one task for
    /// a job, or makes a task that the hub has no more a badge that presses; or his message on its way, which names its
    /// task with no title, gets a badge with no words.
    @Test func theBadgeOfHisMessageNamesAndMarksItsTaskOrJobAsTheBoardDoesAndOpensItsCard() throws {
        let state = try hub([
            task(1, owner: "nova", requester: "manager", ["title": "Find the old build files",
                                                          "job_name": "Move the CI to Node 24"]),
            task(2, owner: "atlas", requester: "nova", ["title": "Move the CI of repo one", "job": 1, "state": "working",
                                                        "works": true]),
            task(3, owner: "nova", requester: "manager", ["title": "Answer the customer", "state": "input-required",
                                                          "waiting_on": "N-9"]),
            task(4, owner: "nova", requester: "manager", ["title": "Write the release notes"]),
            task(5, owner: "nova", requester: "manager", ["title": "Send the invoice", "state": "failed"]),
            task(6, owner: "nova", requester: "manager", ["title": "Send the invoice again", "follows": 5]),
            task(7, owner: "nova", requester: "manager", ["title": "Book the room", "state": "failed"]),
            task(8, owner: "atlas", requester: "nova", ["title": "Move the CI of repo two", "job": 1, "state": "canceled"]),
            task(10, owner: "nova", requester: "manager", ["title": "Plan the launch", "state": "submitted"]),
        ], needs: [["id": 9, "title": "Which card gets the refund?", "why": "", "todo": "", "raised": Self.now - 60,
                    "by": "nova"]])
        let jobs = state.jobsByTask
        func badge(_ place: MessagePlace?, _ title: String?) -> AboutBadge? {
            state.badge(about: MessageAbout(place: place, title: title), jobs: jobs)
        }
        // A task: its title of now, the mark and the words of its row, and its own level.
        let done = try #require(state.tasks.first { $0.id == 4 })
        #expect(badge(.task(4), "An older title") == AboutBadge(title: "Write the release notes", standing: .init(
            mark: .task(symbol: "checkmark.circle.fill", tint: .checked, inWork: false), words: done.mark(in: state).words,
            opens: .task(4))))
        #expect(badge(.task(2), nil)?.standing?.mark == .task(symbol: "circle.dotted", tint: .work, inWork: true))
        #expect(badge(.task(3), nil)?.standing.map { [$0.mark == .waits, $0.words == String(l10n: "Waits for you")] }
                == [true, true])
        // A failure that a follow-up put right is muted, as on the board, and on its job's card; one that nothing put
        // right stays red.
        let taskMark: (String, FleetTask.MarkTint, Bool) -> StandingMark = { .task(symbol: $0, tint: $1, inWork: $2) }
        #expect(badge(.task(5), nil)?.standing?.mark == taskMark("exclamationmark.circle.fill", .quiet, false))
        #expect(badge(.task(7), nil)?.standing?.mark == taskMark("exclamationmark.circle.fill", .failed, false))
        #expect(state.levels(of: DetailCard(.job("task 5", board: nil))).shown?.replaced == [5])
        // A job, by any task of it, also by another agent's task: its name and the mark of its card's state row, and
        // the level of the whole job.
        let card = try #require(state.levels(of: DetailCard(.job("task 1", board: nil))).shown).standing(in: state)
        #expect(card.mark == .task(symbol: "circle.dotted", tint: .work, inWork: true))
        for id in [1, 2, 8] {     // 8: canceled after he wrote
            #expect(badge(.job(id), "A job") == AboutBadge(title: "Move the CI to Node 24", standing: .init(
                mark: card.mark, words: card.words, opens: .job("task 1", board: nil))), "job by task \(id)")
        }
        // A job that ended, and one whose open task neither works nor waits for him, which speaks for it in its own mark.
        #expect(badge(.job(4), nil)?.standing.map { [$0.mark == .ended(.done), $0.words == String(l10n: "Done")] }
                == [true, true])
        let queued = try #require(state.tasks.first { $0.id == 10 })
        #expect(badge(.job(10), nil)?.standing == .init(mark: taskMark("clock", .quiet, false),
                                                       words: queued.mark(in: state).words, opens: .job("task 10", board: nil)))
        // What the reading has no more: the hub's title alone, which does not press; with no title, no badge.
        #expect(badge(.task(99), "A task of last year") == AboutBadge(title: "A task of last year", standing: nil))
        #expect(badge(.job(99), "A job of last year") == AboutBadge(title: "A job of last year", standing: nil))
        #expect(badge(.task(99), nil) == nil)
        #expect(badge(nil, "A shape that the app does not read") == nil)
    }

    /// The bug that this catches: the card's message reaches the hub with no `about` (the agent never learns which
    /// task it is about), or an answer to a Needs-you item carries one, which the hub refuses; or a correction of his
    /// feedback goes with none (its words lose the badge, and the card never shows them), or with one that the hub
    /// refuses whole (409 `about_unreadable`), so the correction does not go.
    @Test func aMessageFromACardCarriesWhatItIsAboutAndKeepsItInTheOutbox() throws {
        let hub = try #require(URL(string: "http://127.0.0.1:9"))
        let feedback = PendingRequest(hub: hub, database: "test-db", client: "test", recipient: "nova",
                                      about: .job(22), text: "Thanks")
        let body = try #require(JSONSerialization.jsonObject(with: feedback.body()) as? [String: Any])
        #expect(body["about"] as? [String: Int] == ["job": 22])
        #expect(body["recipient"] as? String == "nova" && body["text"] as? String == "Thanks")
        let answer = PendingRequest(hub: hub, database: "test-db", client: "test", needID: 5, about: .task(1), text: "Yes")
        #expect(answer.about == nil)
        let kept = try JSONDecoder().decode(PendingRequest.self, from: JSONEncoder().encode(feedback))
        #expect(kept.about == .job(22) && kept.recipient == "nova")
        // A correction is about what its message is about, but never about a task that its chat cannot read.
        let correction = PendingRequest(hub: hub, database: "test-db", client: "test", recipient: "nova",
                                        replacesRequestID: "m1", about: .task(1), text: "Thanks, all of it")
        let sent = try #require(JSONSerialization.jsonObject(with: correction.body()) as? [String: Any])
        #expect(sent["about"] as? [String: Int] == ["task": 1] && sent["replaces_request_id"] as? String == "m1")
        func message(_ id: String, about: [String: Any]?) -> [String: Any] {
            var row: [String: Any] = ["request_id": id, "recipient": "nova", "kind": "message", "text": "Words",
                                      "event_id": 1, "created": Self.now - 30, "client": "test"]
            row["about"] = about
            return row
        }
        let state = try self.hub([task(1, owner: "nova", requester: "manager"),
                                  task(4, owner: "atlas", requester: "manager"),           // nova's chat cannot read it
                                  task(5, owner: "atlas", requester: "nova", ["scope_person": 3])],
                                 messages: [message("m1", about: ["task": 1]), message("m4", about: ["job": 4]),
                                            message("m5", about: ["task": 5]), message("m9", about: ["task": 99]),
                                            message("m0", about: nil)])
        let corrected = ["m1", "m4", "m5", "m9", "m0"].map { id in
            state.messages.first { $0.request_id == id }.flatMap { state.correctionAbout(of: $0) }
        }
        #expect(corrected == [.task(1), nil, nil, .task(99), nil])
    }
}
