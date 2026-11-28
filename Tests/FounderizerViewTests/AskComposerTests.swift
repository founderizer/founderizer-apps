import AppKit
import FleetCore
import Testing
@testable import Founderizer

/// **An ask's card is read from this fleet's hub, and its field writes his message with a draft of its own** (owner
/// feature `ask_follow_ups`; the Mac validator, 26 November 2026). The bugs that this catches: the card's read leaves
/// out `?db=`, so the hub refuses every card with a 409; the receipt of a message from the card empties the agent's
/// chat draft and not the card's (`FleetStore.stageKey(of:)`, `finish`), so the card keeps his words, the chat loses
/// his other words, and a second Send makes a second message. The store reads a stand-in hub (`LoopbackHub`).
@Suite(.serialized, .timeLimit(.minutes(2))) struct AskComposerTests {
    private static let now = Int(Date().timeIntervalSince1970)
    /// The request id of the ask's first message.
    private static let first = "aaaaaaaa-0000-4000-8000-0000000000a1"

    private static func reading(db: String) throws -> Data {
        let agents: [[String: Any]] = [
            ["name": "manager", "role": "manager", "title": "Fleet Manager", "runtime": "claude", "can": [], "placed": true]]
        let message: [String: Any] = [
            "request_id": first, "recipient": "manager", "kind": "message", "text": "Refund the failed orders.",
            "event_id": 1, "created": Double(now - 600), "client": "founderizer-swift/1/example-installation",
            "asked": "Refund the failed orders"]
        let ask: [String: Any] = [
            "id": first, "event_id": 1, "agent": "manager", "name": "Refund the failed orders", "created": Double(now - 600),
            "messages": [first], "answer": NSNull(), "open": true, "moved": Double(now - 600)]
        return try JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "db": db, "time": now, "agents": agents, "tasks": [], "holds": [], "outcomes": [],
            "notes": [], "needs": [], "permissions": [], "messages": [message], "reports": [], "owner_asks": [ask],
            "ui_features": ["direct_chat", "ask_follow_ups"]] as [String: Any])
    }

    struct Seen: Sendable {
        let query: String?
        let sent: [String: String]
        let cardDraft: String?
        let chatDraft: String
        let sends: Int
    }

    @Test func theCardIsReadWithItsFleetAndItsFieldEmptiesOnlyItsOwnDraft() async throws {
        let (seen, _) = try await ViewHost.onMainLoop(limit: 90) { () -> Seen in
            let db = "asks-\(UUID().uuidString)"
            let state = try Self.reading(db: db)
            let hub = try LoopbackHub(state: state)
            defer { hub.stop() }
            let card = try JSONSerialization.data(withJSONObject: [
                "db": db, "id": Self.first, "agent": "manager", "name": "Refund the failed orders", "messages": [],
                "reports": [], "tasks": []] as [String: Any])
            hub.give(card, at: "/ui/mobile/asks/\(Self.first)")
            _ = ViewHost.store(try HubState.decode(state))         // the test's own defaults and folder
            defer { try? FileManager.default.removeItem(at: AppFolders.support.appendingPathComponent("Founderizer")) }
            AppDefaults.store.set(hub.address, forKey: "hubAddress")
            AppDefaults.store.set("example-installation", forKey: "installationID")
            let store = FleetStore()
            Task { await store.refresh() }
            guard ViewHost.turn(10, until: { store.canWrite }) else {
                throw ViewHost.Missing(description: "the stand-in hub's reading did not reach the store")
            }
            // the card's read, as the card's page makes it
            let address = try #require(URL(string: hub.address))
            Task { _ = try? await HubClient().askCard(hub: address, database: db, id: Self.first) }
            ViewHost.turn(10) { hub.requests.contains { $0.path == "/ui/mobile/asks/\(Self.first)" } }
            let read = hub.requests.first { $0.method == "GET" && $0.path == "/ui/mobile/asks/\(Self.first)" }
            // a message from the card's field, with other words of his in the agent's chat
            let client = store.installation
            hub.answer("POST", "/ui/messages") { request in
                let sent = (try? JSONSerialization.jsonObject(with: Data(request.body.utf8)) as? [String: Any]) ?? [:]
                let receipt: [String: Any] = [
                    "ok": true, "request_id": sent["request_id"] ?? "", "event_id": 2, "created": Double(Self.now),
                    "read_at": NSNull(), "replayed": false, "client": client, "recipient": "manager",
                    "replaces_request_id": NSNull(), "attachments": [], "ask": Self.first]
                return (200, (try? JSONSerialization.data(withJSONObject: receipt)) ?? Data())
            }
            let key = FleetStore.stageKey(ask: Self.first)
            store.setDraft("My other words for the chat", for: "manager")
            store.askDrafts[key] = "How many were hit?"
            Task { await store.sendAsk(Self.first, to: "manager") }
            ViewHost.turn(10) { hub.requests.contains { $0.method == "POST" && $0.path == "/ui/messages" } }
            ViewHost.turn(10) { !store.sending && store.pending == nil }
            Task { await store.sendAsk(Self.first, to: "manager") }   // Send again: the field is empty now
            ViewHost.turn(2) { hub.requests.filter { $0.method == "POST" && $0.path == "/ui/messages" }.count > 1 }
            let posts = hub.requests.filter { $0.method == "POST" && $0.path == "/ui/messages" }
            let body = posts.first.flatMap { try? JSONSerialization.jsonObject(with: Data($0.body.utf8)) as? [String: Any] }
            return Seen(query: read?.query,
                        sent: ["text": body?["text"] as? String ?? "", "ask": body?["ask"] as? String ?? ""],
                        cardDraft: store.askDrafts[key], chatDraft: store.draft(for: "manager"), sends: posts.count)
        }
        #expect(seen.query?.contains("db=asks-") == true)
        #expect(seen.sent == ["text": "How many were hit?", "ask": Self.first])
        #expect(seen.cardDraft == nil && seen.chatDraft == "My other words for the chat")
        #expect(seen.sends == 1)
    }
}
