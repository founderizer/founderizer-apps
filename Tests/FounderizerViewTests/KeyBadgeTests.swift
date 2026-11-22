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

    /// **The key's name in the title of a request for its new value is its badge** (his "Yes, both" to the drawing
    /// "New value for DOOR_BACKBLAZE_ACME_KEY"), and **no other card's title has one** (the area Needs-you and the
    /// manager). A press on the badge in a Replace card's title opens the key's card, and the title's own press (it
    /// opens the card's long part) does not take it; in another key request's title the name is words, and a press on
    /// the title opens the long part and no key's card.
    @Test func onlyAReplaceCardsTitleHasTheKeysBadge() async throws {
        struct Seen: Sendable { let badges: [Int]; let keyCard: [Bool]; let longPart: [Bool] }
        let (seen, screen) = try await ViewHost.onMainLoop { () -> Seen in
            var badges: [Int] = [], keyCard: [Bool] = [], longPart: [Bool] = []
            // where the Replace card's badge stood: on the other card the same point is its title's words
            var badgePoint: NSPoint?
            for replaces in [true, false] {
                let now = Int(Date().timeIntervalSince1970)
                var secret: [String: Any] = ["kind": "api_key", "env": "EXAMPLE_API_KEY"]
                if replaces { secret["replaces"] = "bws://11111111-2222-4333-8444-555555555551" }
                let store = ViewHost.store(try ViewHost.reading(
                    needs: [["id": replaces ? 82 : 83, "title": "New value for EXAMPLE_API_KEY", "raised": now - 300,
                             "by": "manager", "why": "The old one expired.", "todo": "", "answered": NSNull(),
                             "details": "Make the new key at Backblaze, under Keys.", "kind": "secret", "secret": secret]],
                    features: [SecretEntryView.feature, "secret_grants"]))
                store.destination = .agent("manager")
                try Self.keepTheKey(in: store)
                let window = ViewHost.window(store)
                defer { ViewHost.close(window) }
                guard try ViewHost.middle(of: "New value for", in: window) != nil else {
                    throw ViewHost.Missing(description: "the card's title is not drawn")
                }
                // the badge's own press (`BadgePress`), where the title draws it: the text reader's box of a name in a
                // line with a badge's mark stood far from the badge
                let presses = Self.presses(in: window.contentView!)
                badges.append(presses.count)
                if let press = presses.first {
                    let frame = press.convert(press.bounds, to: nil)
                    badgePoint = NSPoint(x: frame.midX, y: frame.midY)
                }
                guard let point = badgePoint else { throw ViewHost.Missing(description: "the Replace card had no badge") }
                ViewHost.atOnce(ViewHost.click(point, in: window))
                ViewHost.turn(replaces ? 10 : 2) { store.secretCard != nil }
                keyCard.append(store.secretCard != nil)
                store.secretCard = nil
                longPart.append(try ViewHost.middle(of: "under Keys", in: window, seconds: replaces ? 2 : 10) != nil)
            }
            return Seen(badges: badges, keyCard: keyCard, longPart: longPart)
        }
        #expect(seen.badges == [1, 0], "one badge, in the Replace card's title; none in another key request's title")
        #expect(seen.keyCard == [true, false], "the badge opens the key's card; the other title opens none")
        #expect(seen.longPart == [false, true], "the badge's press is not the title's; the other title's press is")
        #expect(screen.stayedHis)
    }

    /// The badges' presses in a view, deepest first.
    @MainActor private static func presses(in view: NSView) -> [NSView] {
        view.subviews.flatMap { presses(in: $0) + ($0 is BadgePress.PressView ? [$0] : []) }
    }
}
