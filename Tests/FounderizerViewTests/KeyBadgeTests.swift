import AppKit
import FleetCore
import Testing
@testable import Founderizer

/// **A key that a request's words or an agent's message name is a badge, and a press on it opens the key's own card
/// over the chat** (the owner, 21 November 2026: "task cards in both agents chat and needs you sohuld also have a badge
/// for specific Credentials, like we have for agents! ideally a modal of that key should open so it can be edited right
/// there after clicking it", and "Yes, both"). The bugs that these catch: the name stays words, or its press opens
/// nothing or Settings › Secrets.
@Suite(.serialized, .timeLimit(.minutes(2))) struct KeyBadgeTests {
    /// The fleet's secrets as Settings › Secrets read them last: one API key, EXAMPLE_API_KEY.
    @MainActor private static func keepTheKey(in store: FleetStore) throws {
        let team: [String: Any] = [
            "db": store.state?.db ?? "", "revision": String(repeating: "a", count: 40),
            "sha256": String(repeating: "b", count: 64), "lines": [], "open_tasks": [:],
            "logins": ["bws://11111111-2222-4333-8444-555555555551": ["title": "EXAMPLE_API_KEY", "kind": "api_key",
                                                                      "env": "EXAMPLE_API_KEY", "protected": true,
                                                                      "grants": [:]]]]
        let snapshot = try JSONDecoder().decode(TeamSnapshot.self, from: JSONSerialization.data(withJSONObject: team))
        store.keep(LoginReading(team: snapshot, profiles: nil), as: "secrets.logins.fleet")
    }

    /// **The pointer comes onto `point` of the window**, as AppKit tells the window's own tracking areas: the window
    /// server sends no move to a window that no screen shows, so the test gives each area of the window's root view
    /// that follows the pointer its entry and its move. A chat's message under the pointer takes its badges' presses
    /// (`ChatSelection`). The owner's own pointer does not move.
    @MainActor private static func pointerComes(to point: NSPoint, in window: NSWindow) {
        guard let root = window.contentView else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for area in root.trackingAreas where area.options.contains(.mouseMoved) {
            guard let owner = area.owner as? NSResponder else { continue }
            // the event's tracking number is its area, which `NSEvent.trackingArea` gives back
            if let enter = NSEvent.enterExitEvent(with: .mouseEntered, location: point, modifierFlags: [], timestamp: now,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                  trackingNumber: Int(bitPattern: Unmanaged.passUnretained(area).toOpaque()),
                                                  userData: nil) {
                owner.mouseEntered(with: enter)
            }
            if let move = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: now,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 0, pressure: 0) {
                owner.mouseMoved(with: move)
            }
        }
    }

    @Test func aPressOnAKeysBadgeOpensTheKeysCardOverTheChat() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop { () -> (card: Bool, chat: Bool) in
            let now = Int(Date().timeIntervalSince1970)
            let store = ViewHost.store(try ViewHost.reading(
                needs: [["id": 81, "title": "Make a new key for the logs", "raised": now - 300, "by": "manager",
                         "why": "The old one expired. Put the new value in EXAMPLE_API_KEY.", "todo": "",
                         "answered": NSNull()]],
                features: [SecretEntryView.feature, "secret_grants"]))
            store.destination = .agent("manager")
            try Self.keepTheKey(in: store)
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            guard let badge = try ViewHost.middle(of: "EXAMPLE_API_KEY", in: window) else {
                throw ViewHost.Missing(description: "the card does not show the key's name")
            }
            ViewHost.atOnce(ViewHost.click(badge, in: window))
            ViewHost.turn(10) { store.secretCard != nil }
            let card = store.secretCard != nil
            if card { store.secretCard = nil }
            return (card, store.destination == .agent("manager"))
        }
        #expect(seen.card, "the key's own card opens")
        #expect(seen.chat, "over the chat, where he was")
        #expect(screen.stayedHis)
    }

    /// **In an agent's message as on its card**: the chat's book holds the same secrets (`FleetStore.chatNames`), and
    /// the press of the badge in the message under the pointer (`chatBadgeLayer`) opens the same card. The chat draws
    /// its messages from the hub's reading, so a stand-in hub gives the agent's message (`LoopbackHub`). The bug that
    /// this catches: the chat's book is made with no secrets, so the key's name in the message stays words.
    @Test func aPressOnAKeysBadgeInAnAgentsMessageOpensTheKeysCardOverTheChat() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 90) { () -> (press: Bool, card: Bool, chat: Bool) in
            let now = Int(Date().timeIntervalSince1970)
            let agents: [[String: Any]] = [["name": "manager", "role": "manager", "runtime": "claude", "can": [],
                                            "placed": true]]
            let reading = try JSONSerialization.data(withJSONObject: [
                "schema_version": 1, "db": "key-chat-\(UUID().uuidString)", "time": now, "agents": agents, "tasks": [],
                "holds": [], "outcomes": [], "notes": [], "needs": [], "permissions": [], "messages": [],
                "reports": [["agent": "manager", "id": 7, "about": "", "created": now - 60,
                             "text": "The old one expired. I put the new value in EXAMPLE_API_KEY."]],
                "ui_features": [SecretEntryView.feature, "secret_grants"]] as [String: Any])
            let hub = try LoopbackHub(state: reading)
            defer { hub.stop() }
            _ = ViewHost.store(try HubState.decode(reading))         // the test's own defaults and folder
            AppDefaults.store.set(hub.address, forKey: "hubAddress")
            let store = FleetStore()
            Task { await store.refresh() }
            guard ViewHost.turn(10, until: { store.chatTimeline.count(for: "manager") > 0 }) else {
                throw ViewHost.Missing(description: "the stand-in hub's reading did not reach the chat")
            }
            try Self.keepTheKey(in: store)
            store.destination = .agent("manager")
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            guard let badge = try ViewHost.middle(of: "EXAMPLE_API_KEY", in: window) else {
                throw ViewHost.Missing(description: "the agent's message does not show the key's name")
            }
            Self.pointerComes(to: badge, in: window)
            let press = ViewHost.turn(10) {
                window.contentView?.superview?.hitTest(badge).map { String(reflecting: type(of: $0)) }?
                    .contains("ChatBadgePress") == true
            }
            ViewHost.atOnce(ViewHost.click(badge, in: window))
            ViewHost.turn(10) { store.secretCard != nil }
            let card = store.secretCard != nil
            if card { store.secretCard = nil }
            return (press, card, store.destination == .agent("manager"))
        }
        #expect(seen.press, "the badge's press stands over the key's name in the message under the pointer")
        #expect(seen.card, "the key's own card opens")
        #expect(seen.chat, "over the chat, where he was")
        #expect(screen.stayedHis)
    }
}
