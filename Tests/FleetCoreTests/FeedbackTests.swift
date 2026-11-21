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
                     features: [String] = ["direct_chat", "message_about"]) throws -> HubState {
        // nova and the manager take messages in their chats; atlas does not (`direct_chat` false).
        let agents: [[String: Any]] = [
            ["name": "manager", "role": "manager", "runtime": "codex", "can": []],
            ["name": "nova", "role": "lead", "runtime": "codex", "can": [], "direct_chat": true],
            ["name": "atlas", "role": "worker", "runtime": "codex", "can": [], "direct_chat": false],
        ]
        return try HubState.decode(JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "db": "test-db", "time": Self.now, "agents": agents, "tasks": tasks, "holds": [],
            "outcomes": [], "notes": [], "needs": [], "permissions": [], "messages": messages, "reports": reports,
            "ui_features": features]))
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
                     taskIDs: Set(ids), open: [], result: nil, recorded: nil, endedAt: nil)
        }
        #expect(state.feedback(onJob: level("nova", [20, 21, 22])) == Feedback(recipient: "nova", about: .job(22)))
        #expect(state.feedback(onJob: level("nova", [20, 23])) == Feedback(recipient: "nova", about: .job(20)))
        #expect(state.feedback(onJob: level("nova", [21, 23])) == nil)
        #expect(state.feedback(onJob: level("atlas", [20, 23])) == nil)
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

    /// The bug that this catches: the card's message reaches the hub with no `about` (the agent never learns which
    /// task it is about), or an answer to a Needs-you item carries one, which the hub refuses.
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
    }
}
