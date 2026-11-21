import AppKit
import FleetCore
import Testing
@testable import Founderizer

/// **An assistive app's press on a task row of a job's card opens that task over the job** (the coordinator's check of
/// Founderizer 0.1.413 on the owner's Mac, 21 November 2026: VoiceOver's VO-Space, `AXPress`, on the row did nothing,
/// while a click opened it). The bug that this catches: the row is a button whose own element
/// `.accessibilityElement(children: .ignore)` replaces with one of its words, and that element has no action of its
/// own, so the press answers no and the card stays at the job level. The test presses the row as AppKit does for an
/// `AXPress`: `accessibilityPerformPress` on SwiftUI's element of the row, found by its identifier. SwiftUI makes its
/// elements only in a process that an assistive app reads, so the test sets `AXEnhancedUserInterface` on its own app,
/// as such an app sets it, and takes it away at its end.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct JobCardPressTests {
    /// A job of two tasks of an example agent: task 2 follows task 1, so the board names the job "task 1".
    @MainActor private static func store() throws -> FleetStore {
        let now = Date().timeIntervalSince1970
        func task(_ id: Int, _ title: String, _ more: [String: Any] = [:]) -> [String: Any] {
            ["id": id, "title": title, "details": "", "done_when": "Checked", "needs": "none", "goal": "", "owner": "manager",
             "requester": "owner", "state": "completed", "created": now - 900 + Double(id), "attempt": 1, "restarts": 0,
             "nudge_level": 0, "stop_sent": 0, "started": now - 890, "last_activity": now - 800, "accepted": 1]
                .merging(more) { _, new in new }
        }
        let state: [String: Any] = [
            "schema_version": 1, "db": "view-test-\(UUID().uuidString)", "time": Int(now),
            "agents": [["name": "manager", "role": "manager", "runtime": "claude", "can": [], "placed": true]],
            "tasks": [task(1, "Find the old build files"), task(2, "Move the CI of repo one", ["follows": 1])],
            "holds": [], "outcomes": [], "notes": [], "needs": [], "permissions": [], "messages": [], "reports": []]
        return ViewHost.store(try HubState.decode(JSONSerialization.data(withJSONObject: state)))
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

    @Test func anAssistivePressOnATaskRowOfAJobOpensThatTaskOverTheJob() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop { () -> (answer: Bool, shown: DetailPlace?, under: DetailPlace?) in
            let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            NSApp.accessibilitySetValue(true, forAttribute: enhanced)
            defer { NSApp.accessibilitySetValue(false, forAttribute: enhanced) }
            let store = try Self.store()
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            store.show(.job("task 1", board: nil))
            ViewHost.turn(20) { Self.element("work-task-2", in: window) != nil }
            guard let row = Self.element("work-task-2", in: window) else {
                throw ViewHost.Missing(description: "the job's card has no element work-task-2")
            }
            let press = NSSelectorFromString("accessibilityPerformPress")
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            let answer = unsafeBitCast(row.method(for: press), to: Press.self)(row, press)
            ViewHost.turn(20) { store.detail?.shown == .task(2) }
            return (answer, store.detail?.shown, store.detail?.under)
        }
        #expect(seen.answer, "the row takes the press")
        #expect(seen.shown == .task(2), "the task level of the row's task")
        #expect(seen.under == .job("task 1", board: nil), "over its job, which its back link names")
        #expect(screen.stayedHis)
    }
}
