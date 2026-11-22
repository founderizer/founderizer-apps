import AppKit
import FleetCore
import Testing
@testable import Founderizer

/// **A press on the badge of his message about a task or a job opens the card over the chat** (design "Task details as
/// a card over the page", part 2; the owner's "Yes, build it" of 21 November 2026 to its drawing). The bugs that this
/// catches: a click on the badge opens nothing (its press view has no action, or another view over it takes the
/// click); VoiceOver's press (`AXPress`) on it does nothing, because its one element of `.accessibilityElement(children:
/// .ignore)` has no action of its own (the fault that the rows of a job's card had, 21 November 2026); and a badge of a
/// job opens one agent's part of the job, a task's level, or a card with a level under it. The test clicks the task's
/// badge where VoiceOver says that it stands, and presses the job's badge as AppKit does for an `AXPress`
/// (`accessibilityPerformPress` on SwiftUI's element, found by its identifier). SwiftUI makes its elements only in a
/// process that an assistive app reads, so the test sets `AXEnhancedUserInterface` on its own app, as such an app sets
/// it, and takes it away at its end.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AboutBadgePressTests {
    struct Seen: Sendable {
        let clicked: DetailPlace?
        let clickedUnder: DetailPlace?
        let answer: Bool
        let pressed: DetailPlace?
        let pressedUnder: DetailPlace?
    }

    /// The Fleet Manager's chat with two messages of his: one about task 2, and one about the job of tasks 1 and 2,
    /// which names it by task 2. Task 2 follows task 1, so the board names the job "task 1". **A chat draws the
    /// messages of the store's timeline**, which a read of the hub makes, and at a start the reading that the app kept
    /// (`FleetStore.init`): this reading stands as the kept one, in the test's own folder, and the store starts from it.
    @MainActor private static func store() throws -> FleetStore {
        let now = Date().timeIntervalSince1970
        func task(_ id: Int, _ title: String, _ more: [String: Any] = [:]) -> [String: Any] {
            ["id": id, "title": title, "details": "", "done_when": "Checked", "needs": "none", "goal": "", "owner": "manager",
             "requester": "owner", "state": "completed", "created": now - 900 + Double(id), "attempt": 1, "restarts": 0,
             "nudge_level": 0, "stop_sent": 0, "started": now - 890, "last_activity": now - 800, "accepted": 1]
                .merging(more) { _, new in new }
        }
        func message(_ number: Int, _ text: String, about: [String: Any]) -> [String: Any] {
            ["request_id": Self.message(number), "recipient": "manager", "kind": "message", "text": text,
             "event_id": number, "created": now - 300 + Double(number), "client": "example-mac", "read_at": now - 200,
             "about": about]
        }
        let state: [String: Any] = [
            "schema_version": 1, "db": "view-test-\(UUID().uuidString)", "time": Int(now),
            "agents": [["name": "manager", "role": "manager", "runtime": "claude", "can": [], "placed": true]],
            "tasks": [task(1, "Find the old build files", ["job_name": "Move the CI to Node 24"]),
                      task(2, "Check the builds", ["job": 1])],
            "messages": [message(1, "Good work on the builds.", about: ["task": 2, "title": "Check the builds"]),
                         message(2, "Thanks for the whole move.", about: ["job": 2, "title": "Move the CI to Node 24"])],
            "holds": [], "outcomes": [], "notes": [], "needs": [], "permissions": [], "reports": [],
            "ui_features": ["direct_chat", "message_about"]]
        let reading = try JSONSerialization.data(withJSONObject: state)
        // A first store makes the test's folder the app's (`ViewHost`), before anything is written to it.
        _ = ViewHost.store(try HubState.decode(reading))
        let folder = AppFolders.support.appendingPathComponent("Founderizer")
        guard folder.path.hasPrefix(FileManager.default.temporaryDirectory.path) else {
            throw ViewHost.Missing(description: "the app's folder is not the test's: \(folder.path)")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // the kept reading of the hub of the tests, http://127.0.0.1:9 (`FleetStore.keptFile`)
        try reading.write(to: folder.appendingPathComponent("state-127.0.0.1-9.json"))
        return ViewHost.store(try HubState.decode(reading))
    }

    private static func message(_ number: Int) -> String { "aaaaaaaa-0000-4000-8000-00000000000\(number)" }

    /// The element of this identifier in the window, or nil while the window does not show it.
    @MainActor private static func element(_ identifier: String, in window: NSWindow) -> NSObject? {
        var queue: [NSObject] = [window.contentView].compactMap { $0 }
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

    @Test func aPressOnTheBadgeOpensTheCardAtItsTaskAndAtItsWholeJob() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop { () -> Seen in
            let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            NSApp.accessibilitySetValue(true, forAttribute: enhanced)
            defer { NSApp.accessibilitySetValue(false, forAttribute: enhanced) }
            let store = try Self.store()
            store.destination = .agent("manager")
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            let task = "message-about-\(Self.message(1))", job = "message-about-\(Self.message(2))"
            ViewHost.turn(20) { Self.element(task, in: window) != nil && Self.element(job, in: window) != nil }
            // A click in the middle of the task's badge, where its element says that it stands.
            guard let badge = Self.element(task, in: window) else {
                throw ViewHost.Missing(description: "the chat has no element \(task)")
            }
            let frame = NSSelectorFromString("accessibilityFrame")
            typealias Frame = @convention(c) (AnyObject, Selector) -> NSRect
            let place = window.convertFromScreen(unsafeBitCast(badge.method(for: frame), to: Frame.self)(badge, frame))
            ViewHost.atOnce(ViewHost.click(NSPoint(x: place.midX, y: place.midY), in: window))
            ViewHost.turn(20) { store.detail?.shown == .task(2) }
            let clicked = (store.detail?.shown, store.detail?.under)
            store.closeDetail()
            ViewHost.turn(20) { window.childWindows?.contains(where: \.isVisible) != true }
            // VoiceOver's press on the job's badge.
            guard let jobBadge = Self.element(job, in: window) else {
                throw ViewHost.Missing(description: "the chat has no element \(job)")
            }
            let press = NSSelectorFromString("accessibilityPerformPress")
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            let answer = unsafeBitCast(jobBadge.method(for: press), to: Press.self)(jobBadge, press)
            ViewHost.turn(20) { store.detail?.shown == .job("task 1", board: nil) }
            return Seen(clicked: clicked.0, clickedUnder: clicked.1, answer: answer, pressed: store.detail?.shown,
                        pressedUnder: store.detail?.under)
        }
        #expect(seen.clicked == .task(2), "a click opens the task level of the message's task")
        #expect(seen.clickedUnder == nil, "fresh, with no job under it")
        #expect(seen.answer, "the badge takes VoiceOver's press")
        #expect(seen.pressed == .job("task 1", board: nil), "the level of the whole job, of no one agent's board")
        #expect(seen.pressedUnder == nil)
        #expect(screen.stayedHis)
    }
}
