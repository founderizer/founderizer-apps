import AppKit
import FleetCore
import Testing
@testable import Founderizer

/// **The request at hand on Needs you has Copy prompt and Open in its own window, as its card in a chat has** (the
/// owner's "Yes, ship it" of 22 November 2026 to the picture of the page): at the right end of the line of who asks,
/// while the request is open. He follows the steps of a request in another app from either place, so a change of
/// the step's top that drops them takes his way to the card's own window from this page. A request with no steps
/// for him outside the app has the window's icon and no Copy prompt (`NeedPrompt.offers`).
@Suite(.serialized, .timeLimit(.minutes(10))) struct NeedStepToolsTests {
    @Test func theRequestAtHandHasCopyPromptAndItsWindowsIcon() async throws {
        struct Seen: Sendable {
            let withSteps: Set<String>
            let noSteps: Set<String>
        }
        let (seen, screen) = try await ViewHost.onMainLoop { () -> Seen in
            let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            NSApp.accessibilitySetValue(true, forAttribute: enhanced)
            defer { NSApp.accessibilitySetValue(false, forAttribute: enhanced) }
            let now = Int(Date().timeIntervalSince1970)
            func need(_ id: Int, todo: String) -> [String: Any] {
                ["id": id, "title": "Turn on the shop's error logs", "why": "Orders fail.", "todo": todo,
                 "raised": now - 120, "by": "manager", "answered": NSNull()]
            }
            let store = ViewHost.store(try ViewHost.reading(
                needs: [need(9, todo: "1. Open the shop's settings.\n2. Under Logs, press **Enable**."),
                        need(10, todo: "Say which shop it is.")], features: []))
            store.destination = .needs
            store.selectedNeed = 9
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            func get(_ object: NSObject, _ name: String) -> Any? {
                object.responds(to: NSSelectorFromString(name))
                    ? object.perform(NSSelectorFromString(name))?.takeUnretainedValue() : nil
            }
            // the request's tools that the page draws now, by their identifiers
            func tools(of id: Int) -> Set<String> {
                guard let root = window.contentView else { return [] }
                var queue: [NSObject] = [root], found: Set<String> = []
                while !queue.isEmpty {
                    let object = queue.removeFirst()
                    if let name = get(object, "accessibilityIdentifier") as? String,
                       ["need-prompt-\(id)", "need-window-\(id)"].contains(name) { found.insert(name) }
                    queue += (get(object, "accessibilityChildren") as? [Any] ?? []).compactMap { $0 as? NSObject }
                }
                return found
            }
            var withSteps: Set<String> = []
            ViewHost.turn(20) { withSteps = tools(of: 9); return withSteps.count == 2 }
            store.selectedNeed = 10
            var noSteps: Set<String> = []
            ViewHost.turn(20) { noSteps = tools(of: 10); return !noSteps.isEmpty }
            return Seen(withSteps: withSteps, noSteps: noSteps)
        }
        #expect(seen.withSteps == ["need-prompt-9", "need-window-9"])
        #expect(seen.noSteps == ["need-window-10"])
        #expect(screen.stayedHis)
    }
}
