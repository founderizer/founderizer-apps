import AppKit
import FleetCore
import SwiftUI
import Testing
@testable import Founderizer

/// **A value's chip adds no character to a card's words** (the owner's "Yes, as drawn" of 21 November 2026 to a copy
/// icon on each value; the area Chat and files: "A selection copies the code's words only"): the room of its icon is a
/// kern, so the words that he selects, and that VoiceOver reads, are the words as the agent wrote them. A room made of
/// a no-break space went into every copy of a chat's words once (a review of 21 November 2026). VoiceOver copies each
/// value from the words, in their order, and a list item's mark has no such action; each value has its press.
@Suite(.serialized, .timeLimit(.minutes(10))) struct CardValueChipTests {
    private final class Window: NSWindow {
        override var canBecomeKey: Bool { true }
        override var isKeyWindow: Bool { isVisible }
    }

    @Test func aValuesChipAddsNoCharacterAndVoiceOverCopiesItFromTheWords() async throws {
        typealias Seen = (words: [String], actions: [[String]], presses: Int)
        let (seen, screen) = try await ViewHost.onMainLoop { () -> Seen in
            let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            NSApp.accessibilitySetValue(true, forAttribute: enhanced)
            defer { NSApp.accessibilitySetValue(false, forAttribute: enhanced) }
            let text = "1. Paste the key into `acme-door-key` and keep `eu-central`."
            let host = NSHostingView(rootView: MessageText(text: text, chat: true, card: true, values: true)
                .frame(width: 420))
            let window = Window(contentRect: NSRect(x: -40000, y: -40000, width: 420, height: 120),
                                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            window.contentView = host
            window.orderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            func get(_ object: NSObject, _ name: String) -> Any? {
                object.responds(to: NSSelectorFromString(name))
                    ? object.perform(NSSelectorFromString(name))?.takeUnretainedValue() : nil
            }
            var seen: Seen = ([], [], 0)
            ViewHost.turn(20) {
                var queue: [NSObject] = [host], words: [String] = [], actions: [[String]] = []
                while !queue.isEmpty {
                    let object = queue.removeFirst()
                    if get(object, "accessibilityRole") as? String == NSAccessibility.Role.staticText.rawValue {
                        words.append(get(object, "accessibilityValue") as? String ?? "")
                        let custom = get(object, "accessibilityCustomActions") as? [NSAccessibilityCustomAction]
                        actions.append((custom ?? []).map(\.name))
                    }
                    queue += (get(object, "accessibilityChildren") as? [Any] ?? []).compactMap { $0 as? NSObject }
                }
                func presses(_ view: NSView) -> Int {
                    (view is BadgePress.PressView ? 1 : 0) + view.subviews.map(presses).reduce(0, +)
                }
                seen = (words, actions, presses(host))
                // the words come before the presses and the actions: it waits for all three, 20 s at most
                return words.contains { $0.hasPrefix("Paste") } && seen.presses > 0 && actions.contains { !$0.isEmpty }
            }
            return seen
        }
        let words = try #require(seen.words.firstIndex { $0.hasPrefix("Paste") })
        #expect(seen.words[words] == "Paste the key into acme-door-key and keep eu-central.")
        #expect(seen.actions[words] == ["Copy acme-door-key", "Copy eu-central"])
        #expect(seen.words.indices.filter { $0 != words }.allSatisfy { seen.actions[$0].isEmpty }, "\(seen)")
        #expect(seen.presses == 2)
        #expect(screen.stayedHis)
    }
}
