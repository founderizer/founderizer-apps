import Foundation
import Testing
@testable import FleetCore

// Explicit test data only. The app has no fixture loader or demo data path.
private func stateData(messages: [[String: Any]] = [], db: String = "test-db", version: Int = 1) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "schema_version": version, "db": db, "time": 1000.0, "manager_flag": NSNull(),
        "agents": [["name": "worker", "role": "worker", "runtime": "test-runtime", "can": ["browser"],
                    "last_seen": 950.0, "alive": "test-session", "alive_ts": 990.0]],
        "tasks": [["id": 1, "title": "Test result", "details": "Test input", "done_when": "Checked",
                   "needs": "none", "goal": "Test goal", "owner": "worker", "requester": "manager",
                   "state": "completed", "created": 900.0, "attempt": 1, "restarts": 0,
                   "nudge_level": 0, "stop_sent": 0, "delivered": 999.0, "accepted": 0,
                   "where_": "/test/output.txt", "check_note": "Result refused in test"]],
        "notes": [], "needs": [], "permissions": [], "messages": messages,
        "reports": [["id": 1, "text": "Actual report field", "about": "T-1", "created": 999.0]]
    ])
}

private func request() throws -> PendingRequest {
    PendingRequest(hub: try HubClient.address("http://127.0.0.1:8765"), database: "test-db",
                   client: "founderizer-swift/1/test-installation", text: "One test goal")
}

private func receiptRow(_ request: PendingRequest) -> [String: Any] {
    ["request_id": request.requestID.uuidString.lowercased(), "kind": "message", "text": request.text,
     "event_id": 5, "created": 995.0, "client": request.client]
}

/// 27 October 2026: the hub's task for a duty's daily review had `goal: null`, and the whole state did not decode.
@Test func aTaskWithANullGoalStillReads() throws {
    var object = try JSONSerialization.jsonObject(with: stateData()) as! [String: Any]
    var task = (object["tasks"] as! [[String: Any]])[0]
    task["goal"] = NSNull()
    object["tasks"] = [task]
    let state = try HubState.decode(JSONSerialization.data(withJSONObject: object))
    #expect(state.tasks[0].goal == "")
    #expect(try HubState.decode(stateData()).tasks[0].goal == "Test goal")
}

@Test func resultIsNotAcceptedJustBecauseItIsCompleted() throws {
    let state = try HubState.decode(stateData())
    #expect(state.tasks[0].state == "completed")
    #expect(state.tasks[0].checkStatus == "Not accepted by Manager")
    #expect(state.tasks[0].where_ == "/test/output.txt")
    #expect(state.reports[0].text == "Actual report field")
    #expect(state.agents[0].helperIsRecent(serverTime: 1000))
    #expect(!state.agents[0].helperIsRecent(serverTime: 1100))
}

@Test func unknownSchemaAndDuplicateRowsAreRejected() throws {
    #expect(throws: (any Error).self) { try HubState.decode(stateData(version: 2)) }
    let row = receiptRow(try request())
    #expect(throws: (any Error).self) { try HubState.decode(stateData(messages: [row, row])) }
}

@Test func reconciliationRequiresSameGenerationPayloadAndClient() throws {
    let pending = try request()
    let row = receiptRow(pending)
    #expect(try HubState.decode(stateData(messages: [row])).receipt(for: pending)?.event_id == 5)
    #expect(try HubState.decode(stateData(messages: [row], db: "other-db")).receipt(for: pending) == nil)
    var altered = row
    altered["text"] = "Different goal"
    #expect(try HubState.decode(stateData(messages: [altered])).receipt(for: pending) == nil)
    altered = row
    altered["client"] = "other-installation"
    #expect(try HubState.decode(stateData(messages: [altered])).receipt(for: pending) == nil)
}

@Test func pendingIdentityAndBodySurviveRelaunch() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("pending.json")
    let pending = try request()
    try Outbox(file: file).save(pending)
    let reloaded = try #require(try Outbox(file: file).load())
    #expect(reloaded == pending)
    #expect(try reloaded.body() == pending.body())
    #expect(throws: (any Error).self) { try Outbox(file: file).save(request()) }
    #expect(throws: (any Error).self) { try Outbox(file: file).clear(matching: UUID()) }
    #expect(try Outbox(file: file).load() == pending)
    try Outbox(file: file).clear(matching: pending.requestID)
    #expect(try Outbox(file: file).load() == nil)
}

@Test func refusalIsSavedWithoutChangingDispatchIdentity() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let outbox = Outbox(file: directory.appendingPathComponent("pending.json"))
    var pending = try request()
    try outbox.save(pending)
    let originalBody = try pending.body()
    pending.refusal = "Already answered"
    try outbox.save(pending)
    let reloaded = try #require(try outbox.load())
    #expect(reloaded.refusal == "Already answered")
    #expect(try reloaded.body() == originalBody)
    #expect(reloaded.requestID == pending.requestID)
}

@Test func unreadablePendingRecordDoesNotBecomeAnEmptyOutbox() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("pending.json")
    try Data("broken data".utf8).write(to: file)
    #expect(throws: (any Error).self) { try Outbox(file: file).load() }
    #expect(throws: (any Error).self) { try Outbox(file: file).save(request()) }
}

@Test func refusalAndUnknownOutcomeAreDistinct() {
    #expect(HubError.refusal(403, "not the owner's machine").definitiveRefusal)
    #expect(!HubError.refusal(500, "server error").definitiveRefusal)
    #expect(!HubError.invalidResponse.definitiveRefusal)
}

@Test func addressAndOwnerAnswerUseOnlyDocumentedRoute() throws {
    #expect(throws: (any Error).self) { try HubClient.address("http://user:password@localhost") }
    #expect(throws: (any Error).self) { try HubClient.address("http://localhost/events/manager") }
    #expect(throws: (any Error).self) { try HubClient.address("file:///tmp/state") }
    let pending = PendingRequest(hub: try HubClient.address("http://127.0.0.1:8765"), database: "db",
                                 client: "test", needID: 13, text: "An answer")
    #expect(pending.route == "ui/needs/13")
    let body = try #require(try JSONSerialization.jsonObject(with: pending.body()) as? [String: String])
    #expect(body["answer"] == "An answer")
    #expect(body["text"] == nil)
    #expect(body["request_id"] == pending.requestID.uuidString.lowercased())
}

@Test func secretRefusalRemovesCanaryFromAllSavedDraftsAndPendingText() throws {
    let id = UUID().uuidString
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(id)
    let defaults = try #require(UserDefaults(suiteName: "fleet-test-\(id)"))
    defer {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: "fleet-test-\(id)")
    }
    let canary = "SYNTHETIC-REJECTED-CANARY-\(id)"
    let pending = PendingRequest(hub: try HubClient.address("http://127.0.0.1:8765"), database: "test-db",
                                 client: "test", text: "A message with \(canary)")
    let outbox = Outbox(file: directory.appendingPathComponent("pending.json"))
    try outbox.save(pending)
    defaults.set(pending.text, forKey: "managerDraft")
    defaults.set(["13": "An answer with \(canary)"], forKey: "answerDrafts")
    defaults.set(["vps": canary, "studio": canary], forKey: "agentDrafts")
    let redacted = try outbox.rejectSecret(matching: pending.requestID, drafts: defaults)
    #expect(redacted.text.isEmpty)
    #expect(redacted.requestID == pending.requestID)
    #expect(redacted.refusal != nil)
    #expect(defaults.string(forKey: "managerDraft") == nil)
    #expect(defaults.dictionary(forKey: "answerDrafts") == nil)
    #expect(defaults.dictionary(forKey: "agentDrafts") == nil)
    let saved = try String(contentsOf: outbox.file, encoding: .utf8)
    #expect(!saved.contains(canary))
    #expect(try outbox.load()?.text == "")
}

@Test func directChatReceiptBindsRecipientAndCorrection() throws {
    let original = UUID().uuidString.lowercased()
    let pending = PendingRequest(hub: try HubClient.address("http://127.0.0.1:8765"), database: "test-db",
                                 client: "test", recipient: "vps", replacesRequestID: original, text: "Correction")
    let body = try #require(try JSONSerialization.jsonObject(with: pending.body()) as? [String: String])
    #expect(body["recipient"] == "vps")
    #expect(body["replaces_request_id"] == original)
    var row = receiptRow(pending)
    row["recipient"] = "vps"
    row["replaces_request_id"] = original
    #expect(try HubState.decode(stateData(messages: [row])).receipt(for: pending) != nil)
    row["recipient"] = "studio"
    #expect(try HubState.decode(stateData(messages: [row])).receipt(for: pending) == nil)
    row["recipient"] = "vps"
    row.removeValue(forKey: "replaces_request_id")
    #expect(try HubState.decode(stateData(messages: [row])).receipt(for: pending) == nil)
    row["ok"] = true
    row["replayed"] = false
    row["replaces_request_id"] = original
    let receipt = try JSONDecoder().decode(SendReceipt.self, from: JSONSerialization.data(withJSONObject: row))
    #expect(receipt.matches(pending))
    row["recipient"] = "manager"
    let wrong = try JSONDecoder().decode(SendReceipt.self, from: JSONSerialization.data(withJSONObject: row))
    #expect(!wrong.matches(pending))
}

/// One chat of one message to `vps`, as `/ui/state` gives it: read or not, answered or not, on a hub with or
/// without `edit_in_place`.
private func chatState(read: Double?, edited: Double? = nil, answered: Bool = false,
                       features: [String] = ["direct_chat", "corrections", "edit_in_place"]) throws -> HubState {
    let id = "11111111-2222-3333-4444-555555555555"
    var message: [String: Any] = ["request_id": id, "kind": "message", "text": "Write a test label.",
                                  "event_id": 7, "created": 995.0, "client": "test", "recipient": "vps"]
    if let read { message["read_at"] = read }
    if let edited { message["edited"] = edited }
    var state = try #require(try JSONSerialization.jsonObject(with: stateData(messages: [message])) as? [String: Any])
    state["ui_features"] = features
    if answered {
        state["reports"] = [["id": 2, "text": "Done.", "about": "", "created": 999.0,
                             "agent": "vps", "in_reply_to": id]]
    }
    return try HubState.decode(try JSONSerialization.data(withJSONObject: state))
}

@Test func theEditChangesAnUnreadMessageAndCorrectsOneThatWasSeen() throws {
    let fresh = try chatState(read: nil, edited: 996.0)
    #expect(fresh.editsInPlace(fresh.messages[0]))
    #expect(fresh.editHelp(fresh.messages[0]) == "Vps has not read this yet: your words replace it.")
    #expect(fresh.messages[0].edited == 996.0)
    let seen = try chatState(read: 998.0)
    #expect(!seen.editsInPlace(seen.messages[0]))
    #expect(seen.editHelp(seen.messages[0]).contains("already read this"))
    #expect(seen.messages[0].edited == nil)
    let answered = try chatState(read: 998.0, answered: true)
    #expect(answered.wasAnswered(answered.messages[0]) && !answered.editsInPlace(answered.messages[0]))
    #expect(answered.editHelp(answered.messages[0]).contains("already answered this"))
    // A hub without the feature writes a correction for every edit, so the words never promise more than it does.
    let older = try chatState(read: nil, features: ["direct_chat", "corrections"])
    #expect(!older.editsInPlace(older.messages[0]))
    #expect(older.editHelp(older.messages[0]) == "Your words go under it as a correction.")
}

@Test func theReceiptOfAnEditSaysWhichMessageCarriesTheWords() throws {
    let original = UUID().uuidString.lowercased()
    let pending = PendingRequest(hub: try HubClient.address("http://127.0.0.1:8765"), database: "test-db",
                                 client: "test", recipient: "vps", replacesRequestID: original, text: "Other words.")
    var row = receiptRow(pending)
    row["ok"] = true
    row["replayed"] = false
    row["recipient"] = "vps"
    row["replaces_request_id"] = original
    row["edited"] = true
    row["message_request_id"] = original
    let receipt = try JSONDecoder().decode(SendReceipt.self, from: JSONSerialization.data(withJSONObject: row))
    #expect(receipt.matches(pending))           // this request's own id still binds the replay
    #expect(receipt.edited == true && receipt.message_request_id == original)
    row["edited"] = false
    row["message_request_id"] = pending.requestID.uuidString.lowercased()
    let correction = try JSONDecoder().decode(SendReceipt.self, from: JSONSerialization.data(withJSONObject: row))
    #expect(correction.matches(pending) && correction.edited == false)
    row.removeValue(forKey: "edited")
    row.removeValue(forKey: "message_request_id")
    let older = try JSONDecoder().decode(SendReceipt.self, from: JSONSerialization.data(withJSONObject: row))
    #expect(older.matches(pending) && older.edited == nil && older.message_request_id == nil)
}

@Test func directChatIdentitySurvivesRelaunchAndLegacyRecordsStillLoad() throws {
    let pending = PendingRequest(hub: try HubClient.address("http://127.0.0.1:8765"), database: "test-db",
                                 client: "test", recipient: "studio", replacesRequestID: UUID().uuidString.lowercased(), text: "Updated text")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let outbox = Outbox(file: directory.appendingPathComponent("pending.json"))
    try outbox.save(pending)
    #expect(try outbox.load() == pending)
    var altered = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(pending)) as? [String: Any])
    altered["recipient"] = "vps"
    let different = try JSONDecoder().decode(PendingRequest.self, from: JSONSerialization.data(withJSONObject: altered))
    #expect(throws: (any Error).self) { try outbox.save(different) }
    let legacy = try request()
    let decoded = try JSONDecoder().decode(PendingRequest.self, from: JSONEncoder().encode(legacy))
    #expect(decoded.recipient == nil && decoded.replacesRequestID == nil)
    let state = try HubState.decode(stateData(messages: [receiptRow(legacy)]))
    #expect(state.messages[0].chatRecipient == "manager")
    #expect(state.reports[0].chatAgent == "manager")
    #expect(state.ui_features == nil)
    var wrongRow = receiptRow(legacy)
    wrongRow["recipient"] = "studio"
    #expect(try HubState.decode(stateData(messages: [wrongRow])).receipt(for: legacy) == nil)
    wrongRow["ok"] = true
    wrongRow["replayed"] = true
    let wrongReceipt = try JSONDecoder().decode(SendReceipt.self, from: JSONSerialization.data(withJSONObject: wrongRow))
    #expect(!wrongReceipt.matches(legacy))
}
