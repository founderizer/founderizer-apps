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
@Suite(.serialized, .timeLimit(.minutes(10)))
struct GuidanceKeyHoldTests {
    /// A made-up key with the shape of a real one (`KeyInText` knows it by its prefix), in two parts so that no scan of
    /// the repository takes it for a key.
    private static let keyText = "sk_test_" + "EXAMPLEexample0123456789"

    /// A reading with one task of the manager in work, of a hub that takes guidance and secrets.
    private static func reading() throws -> Data {
        let now = Date().timeIntervalSince1970
        let task: [String: Any] = [
            "id": 41, "title": "Move the CI of repo one", "details": "", "done_when": "Checked", "needs": "none",
            "goal": "", "owner": "studio", "requester": "lead", "state": "working", "created": now - 900,
            "attempt": 1, "restarts": 0, "nudge_level": 0, "stop_sent": 0, "started": now - 890,
            "last_activity": now - 60]
        let state: [String: Any] = [
            "schema_version": 1, "db": "view-test-\(UUID().uuidString)", "time": Int(now),
            "agents": [["name": "manager", "role": "manager", "runtime": "claude", "can": [], "placed": true],
                       ["name": "lead", "role": "lead", "runtime": "claude", "can": [], "placed": true],
                       ["name": "studio", "role": "worker", "runtime": "claude", "can": [], "placed": true]],
            "tasks": [task], "holds": [], "outcomes": [], "notes": [], "needs": [], "permissions": [], "messages": [],
            "reports": [], "ui_features": ["task_steering", SecretEntryView.feature, "secret_grants"]]
        return try JSONSerialization.data(withJSONObject: state)
    }

    /// A reading with one stopped task of the manager whose send is not known, of a hub with task controls and secrets
    /// and no guidance, so that the card shows only the check of the result.
    private static func outcomeReading() throws -> Data {
        let now = Date().timeIntervalSince1970
        let task: [String: Any] = [
            "id": 41, "title": "Send the weekly note", "details": "", "done_when": "Checked", "needs": "none",
            "goal": "", "owner": "manager", "requester": "owner", "state": "working", "created": now - 900,
            "attempt": 1, "restarts": 0, "nudge_level": 0, "stop_sent": 0, "started": now - 890,
            "last_activity": now - 60]
        let state: [String: Any] = [
            "schema_version": 1, "db": "view-test-\(UUID().uuidString)", "time": Int(now),
            "agents": [["name": "manager", "role": "manager", "runtime": "claude", "can": [], "placed": true]],
            // stopped, as a task whose send nobody knows is: the owner checks it (`TaskOutcome.waitsOnOwner`)
            "tasks": [task], "holds": [["id": 1, "task": 41, "kind": "stop", "state": "stopped", "attempt": 1]],
            "notes": [], "needs": [], "permissions": [], "messages": [], "reports": [],
            "outcomes": [["id": 1, "task": 41, "attempt": 1, "title": "Send the note", "kind": "send", "state": "unknown"]],
            "ui_features": ["task_controls", SecretEntryView.feature, "secret_grants"]]
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

    /// The first element of the card over the window that `matches`, as an assistive app walks it, or nil.
    @MainActor private static func find(in window: NSWindow, _ matches: (NSObject) -> Bool) -> NSObject? {
        var queue: [NSObject] = window.childWindows?.filter(\.isVisible).compactMap(\.contentView) ?? []
        while !queue.isEmpty {
            let object = queue.removeFirst()
            if matches(object) { return object }
            let children = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: children), let kids = object.perform(children)?.takeUnretainedValue() as? [Any] {
                queue += kids.compactMap { $0 as? NSObject }
            }
        }
        return nil
    }

    /// An element's text attribute (`accessibilityIdentifier`, `accessibilityLabel`, `accessibilityValue`), or nil.
    @MainActor private static func attribute(_ name: String, of object: NSObject) -> String? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    /// The element of this identifier in the card over the window, or nil while the card does not show it.
    @MainActor private static func element(_ identifier: String, in window: NSWindow) -> NSObject? {
        find(in: window) { attribute("accessibilityIdentifier", of: $0) == identifier }
    }

    /// The card shows these words as one text of their own, exactly.
    @MainActor private static func shows(_ words: String, in window: NSWindow) -> Bool {
        find(in: window) { attribute("accessibilityLabel", of: $0) == words || attribute("accessibilityValue", of: $0) == words } != nil
    }

    struct Seen: Sendable {
        var boxShown = false, askedOnWords = false, bannerShown = false, messageWords = false, endedWithoutKey = false
        var heldOnSend = false, sent = true, namesBoth = false
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
            seen.messageWords = ViewHost.turn(10) { Self.shows("This message holds what looks like a key.", in: window) }
            // the agent that gave the task gets a copy of each guidance, so the question names it too (the owner's
            // "Name both" of 22 November 2026): "In a guidance, Studio and Lead and their transcripts would have it."
            if let card = window.childWindows?.first(where: \.isVisible) {
                seen.namesBoth = (try? ViewHost.middle(of: "Studio and Lead and their transcripts", in: card, seconds: 10)) != nil
            }
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
        #expect(seen.messageWords, "in the words of a message, as in the chat")
        #expect(seen.namesBoth, "and it names the task's agent and the agent that gets the guidance's copy")
        #expect(seen.endedWithoutKey, "words with no key end the question")
        #expect(seen.heldOnSend, "Send holds a key also when the box asked nothing")
        #expect(!seen.sent, "and no guidance with the key reached the hub")
        #expect(screen.stayedHis)
    }

    /// The note of a result's check ("How you checked") reaches the task's agent when the task runs again (the hub's
    /// outcome lines), so a key in it waits for his choice too.
    @Test func aKeyInTheNoteOfAResultsCheckWaitsForHisChoice() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop { () -> (opened: Bool, focused: Bool, asked: Bool, banner: Bool) in
            let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            NSApp.accessibilitySetValue(true, forAttribute: enhanced)
            defer { NSApp.accessibilitySetValue(false, forAttribute: enhanced) }
            let state = try Self.outcomeReading()
            let hub = try LoopbackHub(state: state)
            defer { hub.stop() }
            let store = try Self.store(on: hub, state)
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            store.show(.task(41))
            ViewHost.turn(20) { Self.element("outcome-1", in: window) != nil }
            if let row = Self.element("outcome-1", in: window) {
                _ = row.perform(NSSelectorFromString("accessibilityPerformPress"))
            }
            let opened = ViewHost.turn(10) { Self.element("outcome-note", in: window) != nil }
            // his typing: the field takes the keyboard, and its editor takes the words, as the system gives it typed text
            let card = window.childWindows?.first(where: \.isVisible)
            // (by key-value coding, which hands the setter its BOOL; a selector's perform would hand it an object)
            Self.element("outcome-note", in: window)?.setValue(true, forKey: "accessibilityFocused")
            let focused = ViewHost.turn(5) { card?.firstResponder is NSTextView }
            (card?.firstResponder as? NSTextView)?.insertText("I read it with " + Self.keyText,
                                                              replacementRange: NSRange(location: NSNotFound, length: 0))
            let asked = ViewHost.turn(10) { store.heldKey?.hold == .text && store.heldKey?.composer.hasPrefix("outcome:") == true }
            let banner = ViewHost.turn(10) { Self.element("key-hold", in: window) != nil }
            return (opened, focused, asked, banner)
        }
        #expect(seen.opened, "the check of the result opens")
        #expect(seen.focused, "its note takes the keyboard")
        #expect(seen.asked, "a key in its note gets the question")
        #expect(seen.banner, "the question shows over the note")
        #expect(screen.stayedHis)
    }
}
