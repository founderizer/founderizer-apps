import AppKit
import FleetCore
import Testing
@testable import Founderizer

/// **A key in a task's guidance waits for his choice, as in the chat's box** (`TaskSteering`, `KeyHoldBanner`). Until 22
/// November 2026 the guidance box sent the owner's words to the task's agent with no question, while the chat's box, a
/// request's answer, Needs clarification and the feedback box held words that look like a key (a reader of the Windows
/// app's key hold found it). The bug that this catches: a box of the owner's words to an agent with no key hold, so a
/// key that he types, pastes or sends there goes to the agent's session and its records. The test draws a working task's
/// card with its guidance box and reads, in the card, the question for a key that comes into the box's words, and that
/// its Send holds such words also while another box's question stands, when the box itself asked nothing. The elements
/// are read and pressed as an assistive app does (`JobCardPressTests`).
@Suite(.serialized, .timeLimit(.minutes(1)))
struct GuidanceKeyHoldTests {
    /// A made-up key with the shape of a real one (`KeyInText` knows it by its prefix), in two parts so that no scan of
    /// the repository takes it for a key.
    private static let keyText = "sk_test_" + "EXAMPLEexample0123456789"

    /// A reading with one task of the manager in work, of a hub that takes guidance and secrets.
    private static func reading() throws -> Data {
        let now = Date().timeIntervalSince1970
        let task: [String: Any] = [
            "id": 41, "title": "Move the CI of repo one", "details": "", "done_when": "Checked", "needs": "none",
            "goal": "", "owner": "manager", "requester": "owner", "state": "working", "created": now - 900,
            "attempt": 1, "restarts": 0, "nudge_level": 0, "stop_sent": 0, "started": now - 890,
            "last_activity": now - 60]
        let state: [String: Any] = [
            "schema_version": 1, "db": "view-test-\(UUID().uuidString)", "time": Int(now),
            "agents": [["name": "manager", "role": "manager", "runtime": "claude", "can": [], "placed": true]],
            "tasks": [task], "holds": [], "outcomes": [], "notes": [], "needs": [], "permissions": [], "messages": [],
            "reports": [], "ui_features": ["task_steering", SecretEntryView.feature, "secret_grants"]]
        return try JSONSerialization.data(withJSONObject: state)
    }

    /// A store of the app that reads `hub`, after the hub's first answer: it can write, so Send shows and would send.
    @MainActor private static func store(on hub: LoopbackHub, _ state: Data) throws -> FleetStore {
        _ = ViewHost.store(try HubState.decode(state))         // the test's own defaults and folder
        AppDefaults.store.set(hub.address, forKey: "hubAddress")
        let store = FleetStore()
        Task { await store.refresh() }
        ViewHost.turn(10) { store.canWrite }
        return store
    }

    /// The element of this identifier in the card over the window, or nil while the card does not show it.
    @MainActor private static func element(_ identifier: String, in window: NSWindow) -> NSObject? {
        var queue: [NSObject] = window.childWindows?.filter(\.isVisible).compactMap(\.contentView) ?? []
        while !queue.isEmpty {
            let object = queue.removeFirst()
            let named = NSSelectorFromString("accessibilityIdentifier")
            if object.responds(to: named), object.perform(named)?.takeUnretainedValue() as? String == identifier {
                return object
            }
            let children = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: children), let kids = object.perform(children)?.takeUnretainedValue() as? [Any] {
                queue += kids.compactMap { $0 as? NSObject }
            }
        }
        return nil
    }

    struct Seen: Sendable {
        var boxShown = false, askedOnWords = false, bannerShown = false, endedWithoutKey = false
        var heldOnSend = false, sent = true
    }

    @Test func aKeyInATasksGuidanceWaitsForHisChoice() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop { () -> Seen in
            let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            NSApp.accessibilitySetValue(true, forAttribute: enhanced)
            defer { NSApp.accessibilitySetValue(false, forAttribute: enhanced) }
            let state = try Self.reading()
            let hub = try LoopbackHub(state: state)
            defer { hub.stop() }
            let store = try Self.store(on: hub, state)
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            let box = FleetStore.stageKey(task: 41, database: store.state?.db ?? "")
            let mine = HeldKey(composer: box, hold: .text)
            var seen = Seen()
            store.show(.task(41))
            // the box is drawn, and reads its draft from here on
            seen.boxShown = ViewHost.turn(20) { Self.element("task-guidance", in: window) != nil }
            // his words with a key come into the box: the question over it
            store.guidanceDrafts[box] = "Use this key: " + Self.keyText
            seen.askedOnWords = ViewHost.turn(10) { store.heldKey == mine }
            seen.bannerShown = ViewHost.turn(10) { Self.element("key-hold", in: window) != nil }
            // words with no key end it
            store.guidanceDrafts[box] = "Use the test account."
            seen.endedWithoutKey = ViewHost.turn(10) { store.heldKey == nil }
            // another box's question stands, so this box asks nothing while he types: its Send holds the key
            store.heldKey = HeldKey(composer: "another box", hold: .text)
            store.guidanceDrafts[box] = "Use this key: " + Self.keyText
            ViewHost.turn(10) { Self.element("task-guidance-send", in: window) != nil }
            if let send = Self.element("task-guidance-send", in: window) {
                _ = send.perform(NSSelectorFromString("accessibilityPerformPress"))
            }
            seen.heldOnSend = ViewHost.turn(10) { store.heldKey == mine }
            ViewHost.turn(2)
            seen.sent = hub.requests.contains { $0.method == "POST" && $0.path == "/ui/tasks/41/steer" }
            return seen
        }
        #expect(seen.boxShown, "the working task's card shows its guidance box")
        #expect(seen.askedOnWords, "words with a key get the box's question")
        #expect(seen.bannerShown, "the question shows over the box")
        #expect(seen.endedWithoutKey, "words with no key end the question")
        #expect(seen.heldOnSend, "Send holds a key also when the box asked nothing")
        #expect(!seen.sent, "and no guidance with the key reached the hub")
        #expect(screen.stayedHis)
    }
}
