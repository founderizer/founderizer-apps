import AppKit
import FleetCore
import Testing
@testable import Founderizer

/// **A correction of his feedback is about what the feedback is about, and is his chat's own request** (design "Task
/// details as a card over the page", 2.2: a correction carries its own `about`). The bugs that this catches: the
/// correction goes with no `about`, so the corrected words lose the badge in the chat and never stand on the card; and
/// the card's feedback box takes the correction as its own request (`FleetStore.stageKey(of:)`), so its files and its
/// draft are the box's. The store reads a stand-in hub (`LoopbackHub`), because a correction goes only within a moment
/// of the hub's answer; the hub refuses the send, and the request stays in the outbox, where the test reads it.
@Suite(.serialized, .timeLimit(.minutes(2))) struct FeedbackCorrectionTests {
    struct Seen: Sendable {
        let about: MessagePlace?
        let replaces: String?
        let sent: [String: Int]?
        let key: String
        let chat: String
        let draft: String?
    }

    @Test func aCorrectionOfHisFeedbackCarriesItsAboutAndLeavesTheCardsBox() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 90) { () -> Seen in
            let now = Int(Date().timeIntervalSince1970)
            let first = "aaaaaaaa-0000-4000-8000-000000000001"
            let task: [String: Any] = [
                "id": 1, "title": "Write the release notes", "details": "", "done_when": "Checked", "needs": "none",
                "goal": "", "owner": "manager", "requester": "owner", "state": "completed", "created": now - 900,
                "attempt": 1, "restarts": 0, "nudge_level": 0, "stop_sent": 0, "started": now - 890,
                "last_activity": now - 800, "accepted": 1]
            // his feedback on task 1, sent from this Mac (its client is the store's installation below)
            let message: [String: Any] = [
                "request_id": first, "recipient": "manager", "kind": "message", "text": "Good work on the notes.",
                "event_id": 1, "created": now - 60, "client": "founderizer-swift/1/example-installation",
                "about": ["task": 1, "title": "Write the release notes"]]
            let reading = try JSONSerialization.data(withJSONObject: [
                "schema_version": 1, "db": "correction-\(UUID().uuidString)", "time": now,
                "agents": [["name": "manager", "role": "manager", "runtime": "claude", "can": [], "placed": true]],
                "tasks": [task], "messages": [message], "holds": [], "outcomes": [], "notes": [], "needs": [],
                "permissions": [], "reports": [], "ui_features": ["message_about", "corrections"]] as [String: Any])
            let hub = try LoopbackHub(state: reading)
            defer { hub.stop() }
            _ = ViewHost.store(try HubState.decode(reading))         // the test's own defaults and folder
            // the outbox that the request is saved in goes with the test, as `ViewHost.close` takes it
            defer { try? FileManager.default.removeItem(at: AppFolders.support.appendingPathComponent("Founderizer")) }
            AppDefaults.store.set(hub.address, forKey: "hubAddress")
            AppDefaults.store.set("example-installation", forKey: "installationID")
            let store = FleetStore()
            Task { await store.refresh() }
            guard ViewHost.turn(10, until: { store.canWrite && store.state?.messages.isEmpty == false }),
                  let feedback = store.state?.messages.first else {
                throw ViewHost.Missing(description: "the stand-in hub's reading did not reach the store")
            }
            let box = FleetStore.stageKey(about: .task(1), database: store.state?.db ?? "")
            store.feedbackDrafts[box] = "My next words about the notes"
            store.beginEdit(feedback)
            store.editText = "Good work on the notes and on the list."
            Task { await store.sendEdit() }
            ViewHost.turn(10) { store.pending != nil && hub.requests.contains { $0.path == "/ui/messages" } }
            let body = hub.requests.first { $0.method == "POST" && $0.path == "/ui/messages" }?.body ?? ""
            let fields = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
            let pending = store.pending
            return Seen(about: pending?.about, replaces: pending?.replacesRequestID, sent: fields?["about"] as? [String: Int],
                        key: pending.map { FleetStore.stageKey(of: $0) } ?? "", chat: FleetStore.stageKey(agent: "manager"),
                        draft: store.feedbackDrafts[box])
        }
        #expect(seen.about == .task(1), "the correction is about task 1, as his first words")
        #expect(seen.replaces == "aaaaaaaa-0000-4000-8000-000000000001")
        #expect(seen.sent == ["task": 1], "and the hub gets it so")
        #expect(seen.key == seen.chat, "its files are the chat's, not the card box's")
        #expect(seen.draft == "My next words about the notes", "the card's box keeps its words")
        #expect(screen.stayedHis)
    }
}
