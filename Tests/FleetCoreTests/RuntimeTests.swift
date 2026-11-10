import Foundation
import Testing
@testable import FleetCore

private func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T {
    try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
}

@Test func reportedRuntimesStayWithTheirAttemptAndExcludeChildSessions() throws {
    func event(_ id: Int, _ fields: [String: Any]) throws -> RuntimeEvent {
        try decode(RuntimeEvent.self, ["id": id, "attempt": 1, "session": "root", "seq": id,
            "type": "session"].merging(fields) { _, new in new })
    }
    var timeline = ActivityTimeline()
    timeline.append([
        try event(1, ["runtime": "claude"]),
        try event(2, ["runtime": "codex", "parent": "child"]),
        try event(3, ["runtime": "codex", "attempt": 2]),
        try event(4, ["runtime": "codex", "attempt": 2]),
        try event(5, ["attempt": 3])
    ])
    #expect(timeline.runtimes[1] == ["claude"])
    #expect(timeline.runtimes[2] == ["codex"])
    #expect(timeline.runtimes[3] == nil)
    #expect(timeline.rows.isEmpty)
}

@Test func activityCombinesOnlyTheSameAttemptSessionAndTool() throws {
    func event(_ id: Int, _ type: String, _ attempt: Int, _ status: String) throws -> RuntimeEvent {
        try decode(RuntimeEvent.self, ["id": id, "attempt": attempt, "session": "s", "seq": id,
            "type": type, "tool_call_id": "tool", "title": "Read file", "status": status, "output": "Output \(id)"])
    }
    var timeline = ActivityTimeline()
    timeline.append([try event(1, "tool_call", 1, "in_progress"), try event(2, "tool_call_update", 1, "completed"),
                     try event(3, "tool_call", 2, "in_progress"), try event(4, "tool_call_update", 2, "failed")])
    #expect(timeline.rows.count == 2)
    #expect(timeline.rows.map(\.id) == [1, 3])
    #expect(timeline.rows.map(\.status) == ["completed", "failed"])
    #expect(timeline.rows.map(\.output) == ["Output 2", "Output 4"])
}

/// A hold row as the hub sends it, for a Stop that the task's requester asked for: `by` is not the owner.
private func requesterStop(_ state: String, _ fields: [String: Any] = [:]) -> [String: Any] {
    ["id": 4, "task": 7, "kind": "stop", "by": "manager", "note": "", "state": state, "created": 100, "attempt": 1,
     "confirmed": NSNull(), "detail": NSNull(), "released": NSNull(), "released_by": NSNull(),
     "resume_mode": NSNull()].merging(fields) { _, new in new }
}

@Test func aNewAttemptKeepsTheCutCallOfTheStoppedAttemptAndItsUnknownOutcome() throws {
    func event(_ id: Int, _ attempt: Int, _ fields: [String: Any] = [:]) throws -> RuntimeEvent {
        try decode(RuntimeEvent.self, ["id": id, "attempt": attempt, "session": "s", "seq": id, "type": "tool_call", "kind": "other",
            "tool_call_id": "send", "title": "Click Send", "status": "in_progress"].merging(fields) { _, new in new })
    }
    var timeline = ActivityTimeline()
    // Attempt 1: one call ended, and the stop came during the next one. That call has no finish in the record.
    timeline.append([try event(1, 1, ["tool_call_id": "open", "title": "Open page"]),
                     try event(2, 1, ["type": "tool_call_update", "tool_call_id": "open", "status": "completed", "output": "Page open"]),
                     try event(3, 1)])
    // While attempt 1 can run, the call can run. A confirmed stop of attempt 1 ended it, with no result.
    #expect(timeline.rows.map { $0.endedWithoutResult(current: 1) } == [false, false])
    #expect(timeline.rows.map { $0.endedWithoutResult(current: 1, stopped: 1) } == [false, true])
    // Attempt 2 of the same task makes the same call with the same IDs, and ends it.
    timeline.append([try event(4, 2), try event(5, 2, ["type": "tool_call_update", "status": "completed", "output": "Sent"])])
    #expect(timeline.rows.map(\.id) == [1, 3, 4])
    #expect(timeline.rows.map(\.event.attempt) == [1, 1, 2])
    #expect(timeline.rows.map(\.status) == ["completed", "in_progress", "completed"])   // the cut call never becomes done
    #expect(timeline.rows.map { $0.endedWithoutResult(current: 2) } == [false, true, false])   // and it does not run
    #expect(timeline.rows.map(\.output) == ["Page open", nil, "Sent"])
    // The hub's rows after the requester's stop was released with a check: the task is in attempt 2, and the outcome of
    // the cut call stays unknown, with attempt 1, until a check settles it.
    let outcome: [String: Any] = ["id": 9, "task": 7, "attempt": 1, "hold": 4, "tool_call_id": "send", "title": "Click Send",
        "kind": "other", "state": "unknown", "created": 130, "resolved": NSNull(), "by": NSNull(), "note": NSNull()]
    let settled = outcome.merging(["id": 10, "tool_call_id": "save", "state": "not_done", "resolved": 150, "by": "worker",
                                   "note": "The page shows the draft."]) { _, new in new }
    func hub(_ hold: [String: Any]) throws -> HubState {
        try HubState.decode(JSONSerialization.data(withJSONObject: ["schema_version": 1, "db": "db", "time": 200,
            "agents": [], "notes": [], "needs": [], "permissions": [], "messages": [], "reports": [],
            "tasks": [["id": 7, "title": "Chrome task", "details": "Send the form", "done_when": "Sent", "needs": "browser",
                       "goal": "Local", "owner": "worker", "requester": "manager", "state": "working", "created": 90, "attempt": 2,
                       "restarts": 1, "nudge_level": 0, "stop_sent": 0]],
            "holds": [hold], "outcomes": [outcome, settled]]))
    }
    let state = try hub(requesterStop("released", ["confirmed": 120, "detail": "1 process ended", "released": 140,
                                                   "released_by": "manager", "resume_mode": "check"]))
    #expect(state.tasks[0].attempt == 2 && state.tasks[0].restarts == 1)
    #expect(state.holds?.map(\.state) == ["released"] && state.holds?.first?.attempt == 1)
    #expect(state.outcomes?.filter { $0.task == 7 && $0.state == "unknown" }.map(\.attempt) == [1])
    // Only a hold that the helper confirmed, and that holds the task now, says that its attempt ended.
    for (held, ended) in [("requested", nil), ("not_confirmed", nil), ("stopped", 1), ("released", nil)] as [(String, Int?)] {
        #expect(try hub(requesterStop(held)).stoppedAttempt(of: 7) == ended)
    }
    #expect(try hub(requesterStop("stopped")).stoppedAttempt(of: 8) == nil)
}

@Test func runtimePagesRejectWrongTaskAndBrokenCursor() throws {
    let page = try decode(RuntimePage.self, ["db": "db", "task": 7, "events": [], "next": 5, "more": false])
    try page.validate(database: "db", task: 7, after: 5)
    #expect(throws: (any Error).self) { try page.validate(database: "other", task: 7, after: 5) }
    #expect(throws: (any Error).self) { try page.validate(database: "db", task: 8, after: 5) }
    #expect(throws: (any Error).self) { try page.validate(database: "db", task: 7, after: 4) }
    let loop = try decode(RuntimePage.self, ["db": "db", "task": 7, "events": [], "next": 5, "more": true])
    #expect(throws: (any Error).self) { try loop.validate(database: "db", task: 7, after: 5) }
}

@Test func controlsKeepIdentityAcrossRelaunchAndCannotUseAnotherReceipt() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let outbox = Outbox(file: folder.appendingPathComponent("pending.json"))
    let pending = PendingRequest(hub: URL(string: "http://127.0.0.1")!, database: "db", client: "test",
                                 command: .control(task: 7, action: .pause), text: "")
    try outbox.save(pending)
    let recovered = try #require(try outbox.load())
    #expect(recovered == pending)
    #expect(recovered.route == "ui/tasks/7/control")
    #expect(try recovered.body() == pending.body())
    let body = try #require(JSONSerialization.jsonObject(with: recovered.body()) as? [String: String])
    #expect(body["action"] == "pause")
    #expect(body["text"] == nil)
    func receipt(_ task: Int, _ client: String) throws -> ControlReceipt {
        try decode(ControlReceipt.self, ["ok": true, "request_id": pending.requestID.uuidString.lowercased(), "client": client,
            "replayed": false, "hold": ["id": 1, "task": task, "kind": "pause", "state": "requested", "attempt": 1]])
    }
    let accepted = try receipt(7, "test")
    #expect(accepted.matches(pending))
    #expect(accepted.hold?.state == "requested") // A receipt is not a confirmed stop.
    #expect(try !receipt(8, "test").matches(pending))
    #expect(try !receipt(7, "another-client").matches(pending))
    let other = PendingRequest(hub: pending.hub, database: "db", client: "test", command: .control(task: 7, action: .stop), text: "")
    #expect(throws: (any Error).self) { try outbox.save(other) }
}

@Test func controlsOnATaskThatItsRequesterStoppedConfirmOnlyTheStateOfThatHold() throws {
    func reply(_ action: ControlAction, _ hold: [String: Any], _ fields: [String: Any] = [:]) throws -> (receipt: ControlReceipt, accepted: Bool) {
        let request = PendingRequest(hub: URL(string: "http://127.0.0.1")!, database: "db", client: "app",
                                     command: .control(task: 7, action: action), text: "")
        let receipt = try decode(ControlReceipt.self, ["ok": true, "request_id": request.requestID.uuidString.lowercased(),
            "client": "app", "replayed": false, "hold": hold].merging(fields) { _, new in new })
        return (receipt, receipt.matches(request))
    }
    // The owner's Stop or Pause takes the stop of a restart over: the hub answers with that Stop hold in the owner's
    // name, as a change, and the app takes the answer for both actions. A hold that is only requested stays requested:
    // the answer is not a confirmed stop. A stop that was not confirmed gives the same answer: requested again.
    for state in ["requested", "stopped"] {
        for action in [ControlAction.stop, .pause] {
            let answer = try reply(action, requesterStop(state, ["by": "owner"]), ["changed": true])
            #expect(answer.accepted)
            #expect(answer.receipt.hold?.state == state)
        }
    }
    // The same Stop again changes nothing, and the app takes that answer too.
    #expect(try reply(.stop, requesterStop("stopped", ["by": "owner"]), ["changed": false]).accepted)
    // A released hold is no answer to a Stop. Only a released hold is the answer to a resume.
    let released = requesterStop("released", ["confirmed": 120, "released": 140, "released_by": "owner", "resume_mode": "check"])
    #expect(try !reply(.stop, released, ["changed": false]).accepted)
    for action in [ControlAction.resume, .resume_check] {
        #expect(try !reply(action, requesterStop("stopped", ["confirmed": 120])).accepted)
        #expect(try reply(action, released, ["resumed_with": "new session"]).accepted)
    }
    // The owner's Stop shows on a hold only while it is a Stop in an agent's name: after the take-over it is the owner's.
    func hold(_ row: [String: Any]) throws -> TaskHold { try decode(TaskHold.self, row) }
    for state in ["requested", "stopped", "not_confirmed"] { #expect(try hold(requesterStop(state)).isAgentStop) }
    for other in [requesterStop("stopped", ["by": "owner"]), requesterStop("stopped", ["by": "hub"]), released,
                  requesterStop("stopped").filter { $0.key != "by" }, requesterStop("stopped", ["kind": "pause"])] {
        #expect(try !hold(other).isAgentStop)
    }
}

@Test func childToolsAndFileReportsStayWithTheirAttemptSessionAndParent() throws {
    func event(_ id: Int, _ fields: [String: Any]) throws -> RuntimeEvent {
        try decode(RuntimeEvent.self, ["id": id, "attempt": 1, "session": "root", "seq": id, "type": "tool_call", "tool_call_id": "edit"].merging(fields) { _, new in new })
    }
    var timeline = ActivityTimeline()
    timeline.append([
        try event(1, ["tool_call_id": "child", "subagent": ["name": "Check files"]]),
        try event(2, ["parent": "child", "status": "in_progress"]),
        try event(3, ["parent": "other", "status": "in_progress"]),
        try event(4, ["parent": "child", "session": "another", "status": "in_progress"]),
        try event(5, ["parent": "child", "attempt": 2, "status": "in_progress"]),
        try event(6, ["type": "tool_call_update", "parent": "child", "status": "completed", "changes": [["path": "app.swift", "action": "modify", "added": 4, "removed": 2]]]),
        try event(7, ["type": "tool_call_update", "parent": "child", "status": "completed", "changes": [["path": "app.swift", "action": "modify", "added": 4, "removed": 2]]]),
        try event(8, ["type": "tool_call_update", "parent": "other", "status": "failed", "changes": [["path": "failed.swift", "action": "add", "added": 10]]])
    ])
    #expect(timeline.rows.count == 5)
    let parent = try #require(timeline.rows[0].event.toolKey)
    #expect(timeline.children(of: parent).map(\.id) == [2])
    #expect(timeline.rows.map(\.status) == [nil, "completed", "failed", "in_progress", "in_progress"])
    #expect(timeline.changedFiles.map(\.path) == ["app.swift"])
    #expect(timeline.changedFiles.first?.added == 4)
    #expect(timeline.changedFiles.first?.removed == 2)
}

@Test func fileReportsUseCompletionTimeWhenChildActivityArrivesLate() throws {
    func event(_ id: Int, _ fields: [String: Any]) throws -> RuntimeEvent {
        try decode(RuntimeEvent.self, ["id": id, "attempt": 1, "session": "root", "seq": id,
            "type": "tool_call", "status": "in_progress", "tool_call_id": "first",
            "ts": 100].merging(fields) { _, new in new })
    }
    func change(_ added: Int) -> [[String: Any]] {
        [["path": "checkout.swift", "action": "modify", "added": added, "removed": 1]]
    }
    var timeline = ActivityTimeline()
    timeline.append([
        try event(1, ["changes": change(8)]),
        try event(2, ["tool_call_id": "second", "ts": 110, "changes": change(3)]),
        try event(3, ["type": "tool_call_update", "tool_call_id": "second", "ts": 120, "status": "completed"]),
        try event(4, ["type": "tool_call_update", "ts": 130, "status": "completed"])
    ])
    #expect(timeline.changedFiles.first?.added == 8)
    // The child finished earlier, but its transcript is delivered after the parent.
    timeline.append([
        try event(5, ["parent": "child", "tool_call_id": "child/edit", "ts": 90, "changes": change(2)]),
        try event(6, ["type": "tool_call_update", "parent": "child", "tool_call_id": "child/edit", "ts": 115, "status": "completed"])
    ])
    #expect(timeline.changedFiles.first?.added == 8)
    // A later completed edit still replaces that report.
    timeline.append([try event(7, ["tool_call_id": "last", "ts": 140, "status": "completed", "changes": change(5)])])
    #expect(timeline.changedFiles.first?.added == 5)
}

@Test func steeringRequiresTheSameAttemptAndContentAcrossRecovery() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let outbox = Outbox(file: folder.appendingPathComponent("pending.json"))
    let request = PendingRequest(hub: URL(string: "http://127.0.0.1")!, database: "db", client: "app", command: .steer(task: 8, attempt: 2), text: "  Check\r\nthe result  ")
    try outbox.save(request)
    let loaded = try #require(try outbox.load())
    #expect(loaded == request)
    let body = try #require(JSONSerialization.jsonObject(with: loaded.body()) as? [String: Any])
    #expect(body["text"] as? String == "Check\nthe result")
    #expect(body["expected_attempt"] as? Int == 2)
    #expect(body["note"] == nil)
    func steer(_ fields: [String: Any] = [:]) throws -> TaskSteer {
        try decode(TaskSteer.self, ["id": 9, "task": 8, "attempt": 2, "text": "Check\nthe result", "created": 100, "request_id": request.requestID.uuidString.lowercased(), "client": "app"].merging(fields) { _, new in new })
    }
    #expect(try steer().matches(loaded))
    #expect(try steer().deliveryLabel(currentAttempt: 2) == "Received")
    #expect(try steer().deliveryLabel(currentAttempt: 3) == "Not delivered · task restarted")
    #expect(try steer(["read_at": 101]).deliveryLabel(currentAttempt: 3) == "Read")
    func state(_ db: String) throws -> HubState {
        try HubState.decode(JSONSerialization.data(withJSONObject: ["schema_version": 1, "db": db, "time": 110,
            "agents": [], "tasks": [], "notes": [], "needs": [], "permissions": [], "messages": [], "reports": [],
            "steers": [["id": 9, "task": 8, "attempt": 2, "text": "Check\nthe result", "created": 100,
                        "request_id": request.requestID.uuidString.lowercased(), "client": "app"]]]))
    }
    #expect(try state("db").hasSteeringReceipt(for: loaded))
    #expect(try !state("other-db").hasSteeringReceipt(for: loaded))
    #expect(try !steer(["attempt": 3]).matches(loaded))
    #expect(try !steer(["task": 9]).matches(loaded))
    #expect(try !steer(["client": "another"]).matches(loaded))
    #expect(try !steer(["text": "Something else"]).matches(loaded))
    #expect(try !steer(["request_id": UUID().uuidString]).matches(loaded))
    let invalid = PendingRequest(hub: request.hub, database: "db", client: "app", command: .steer(task: 8, attempt: 2), text: String(repeating: "x", count: 4001))
    #expect(throws: (any Error).self) { try invalid.body() }
}

@Test func rejectedSteeringTextIsRemovedFromTheDurableCommand() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let outbox = Outbox(file: folder.appendingPathComponent("pending.json"))
    let request = PendingRequest(hub: URL(string: "http://127.0.0.1")!, database: "db", client: "app", command: .steer(task: 8, attempt: 2), text: "fake-rejected-value")
    let suite = "fleet-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try outbox.save(request)
    _ = try outbox.rejectSecret(matching: request.requestID, drafts: defaults)
    let saved = try #require(try outbox.load())
    #expect(saved.text.isEmpty)
    #expect(saved.command == .steer(task: 8, attempt: 2))
    #expect(!String(decoding: try Data(contentsOf: outbox.file), as: UTF8.self).contains("fake-rejected-value"))
}

/// **A waiting write is named by its item's title, not the hub's number** (fix round 3c, COPY): "Pause G-3" and "Set
/// outcome O-5" stood in the window's request line. A reading without the item says "the task" or "the goal".
@Test func aWaitingWriteIsNamedByItsItemsTitle() throws {
    let outcome: [String: Any] = ["id": 9, "task": 7, "attempt": 1, "hold": 4, "tool_call_id": "send", "title": "Click Send",
        "kind": "other", "state": "unknown", "created": 130, "resolved": NSNull(), "by": NSNull(), "note": NSNull()]
    let state = try HubState.decode(JSONSerialization.data(withJSONObject: ["schema_version": 1, "db": "db", "time": 200,
        "agents": [], "notes": [], "needs": [], "permissions": [], "messages": [], "reports": [],
        "tasks": [["id": 7, "title": "Chrome task", "details": "Send the form", "done_when": "Sent", "needs": "browser",
                   "goal": "Local", "owner": "worker", "requester": "manager", "state": "working", "created": 90, "attempt": 2,
                   "restarts": 1, "nudge_level": 0, "stop_sent": 0]],
        "outcomes": [outcome]]))
    #expect(OwnerCommand.control(task: 7, action: .pause).label(in: state) == "Pause “Chrome task”")
    #expect(OwnerCommand.steer(task: 7, attempt: 2).label(in: state) == "Guide “Chrome task”")
    #expect(OwnerCommand.outcome(id: 9, finding: .done).label(in: state) == "Set the outcome of “Chrome task”")
    // Not in the reading: plain words, and no hub number (3 November 2026).
    #expect(OwnerCommand.control(task: 8, action: .stop).label(in: state) == "Stop the task")
    #expect(OwnerCommand.goalState(id: 3, revision: 1, action: .pause).label(in: state) == "Pause the goal")
    #expect(OwnerCommand.ownerDeviceCode(device: "iphone").label == "New code for iphone")
}

/// **A waiting schedule write is named by the schedule's own title** (the polish of 30 October 2026): the request line said
/// "Run schedule 3", with the hub's number. A schedule that the schedules' reading does not hold is "Run schedule".
@Test func aWaitingScheduleWriteIsNamedByItsTitle() throws {
    let schedule = try JSONDecoder().decode(FleetTrigger.self, from: JSONSerialization.data(withJSONObject: [
        "id": 3, "agent": "vps", "state": "active", "revision": 2,
        "schedule": try payloadFields(TriggerSchedule(kind: "weekly", days: ["mon"], timezone: "Europe/Madrid")),
        "task": try payloadFields(TriggerTask(title: "Weekly prices", details: "Compare the prices", done_when: "Sent")),
        "created": 1000, "updated": 1000, "request_id": UUID().uuidString.lowercased()]))
    #expect(OwnerCommand.triggerState(id: 3, revision: 2, action: .run_now).label(in: nil, schedules: [schedule]) == "Run “Weekly prices”")
    #expect(OwnerCommand.triggerState(id: 3, revision: 2, action: .pause).label(in: nil, schedules: [schedule]) == "Pause “Weekly prices”")
    #expect(OwnerCommand.triggerState(id: 3, revision: 2, action: .check_now).label(in: nil, schedules: [schedule]) == "Check “Weekly prices”")
    // Not in the reading, or no reading: no number.
    #expect(OwnerCommand.triggerState(id: 4, revision: 1, action: .run_now).label(in: nil, schedules: [schedule]) == "Run schedule")
    #expect(OwnerCommand.triggerState(id: 3, revision: 2, action: .run_now).label(in: nil) == "Run schedule")
    #expect(OwnerCommand.triggerState(id: 3, revision: 2, action: .resume).label == "Resume schedule")
}

/// **A waiting write of another hub, or of this hub before it was installed again, keeps its plain name** (the review of
/// 30 October 2026): its numbers are another reading's, and this reading gives them to other items.
@Test func aWaitingWriteOfAnotherHubKeepsItsPlainName() throws {
    let schedule = try JSONDecoder().decode(FleetTrigger.self, from: JSONSerialization.data(withJSONObject: [
        "id": 3, "agent": "vps", "state": "active", "revision": 2,
        "schedule": try payloadFields(TriggerSchedule(kind: "weekly", days: ["mon"], timezone: "Europe/Madrid")),
        "task": try payloadFields(TriggerTask(title: "Weekly prices", details: "Compare the prices", done_when: "Sent")),
        "created": 1000, "updated": 1000, "request_id": UUID().uuidString.lowercased()]))
    let state = try HubState.decode(JSONSerialization.data(withJSONObject: ["schema_version": 1, "db": "gen-2", "time": 200,
        "agents": [], "notes": [], "needs": [], "permissions": [], "messages": [], "reports": [],
        "tasks": [["id": 7, "title": "Chrome task", "details": "Send the form", "done_when": "Sent", "needs": "browser",
                   "goal": "Local", "owner": "worker", "requester": "manager", "state": "working", "created": 90, "attempt": 2,
                   "restarts": 1, "nudge_level": 0, "stop_sent": 0]]]))
    let hub = URL(string: "http://127.0.0.1:8765/")!, other = URL(string: "http://127.0.0.1:9876/")!
    func request(_ command: OwnerCommand, hub: URL, database: String) -> PendingRequest {
        PendingRequest(hub: hub, database: database, client: "c", command: command, text: "")
    }
    let run = OwnerCommand.triggerState(id: 3, revision: 2, action: .run_now), pause = OwnerCommand.control(task: 7, action: .pause)
    // This hub and this generation: the items' own titles.
    #expect(request(run, hub: hub, database: "gen-2").name(hub: hub, state: state, schedules: [schedule]) == "Run “Weekly prices”")
    #expect(request(pause, hub: hub, database: "gen-2").name(hub: hub, state: state, schedules: [schedule]) == "Pause “Chrome task”")
    // This hub before it was installed again, and another hub: the plain names.
    #expect(request(run, hub: hub, database: "gen-1").name(hub: hub, state: state, schedules: [schedule]) == "Run schedule")
    #expect(request(pause, hub: hub, database: "gen-1").name(hub: hub, state: state, schedules: [schedule]) == "Pause the task")
    #expect(request(run, hub: other, database: "gen-2").name(hub: hub, state: state, schedules: [schedule]) == "Run schedule")
    // No reading yet: the plain name; a message: its own words.
    #expect(request(run, hub: hub, database: "gen-2").name(hub: hub, state: nil, schedules: [schedule]) == "Run schedule")
    #expect(PendingRequest(hub: hub, database: "gen-2", client: "c", recipient: "atlas", text: "Hello")
        .name(hub: hub, state: state, schedules: []) == "Hello")
}
