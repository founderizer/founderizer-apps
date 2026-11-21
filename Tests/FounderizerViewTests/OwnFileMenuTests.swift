import AppKit
import FleetCore
import SwiftUI
import Testing
@testable import Founderizer

/// **His own file has a "…" with the choices of the row that stood under it, and an agent's file has none** (the
/// owner, 21 November 2026, of that row: "dont show these 2 there, add like a three dots icon that you click and see
/// the 2 options you mentioned - since there is no download icon"). The bugs that these catch: the menu without Keep
/// as knowledge for a text file, the menu on an agent's file or a guidance's, and a choice that does another thing than
/// the row's press did. The menu's choices are VoiceOver's actions of the file (`OwnFileMenu.choices`), so the tests
/// read them there; the "…" itself is counted by the view that places its menu (`FleetMenuAnchor`). The menu itself is
/// not opened: its window would stand on the owner's screen.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct OwnFileMenuTests {
    private final class Window: NSWindow {
        override var canBecomeKey: Bool { true }
        override var isKeyWindow: Bool { isVisible }
    }

    private static let hash = String(repeating: "a", count: 64), now = Date().timeIntervalSince1970

    private static func file(_ id: Int, _ name: String, _ mime: String, kept: MessageAttachment.Kept? = nil)
        -> MessageAttachment {
        MessageAttachment(id: id, name: name, mime: mime, size: 2_048, sha256: hash, created: now - 60, kept: kept)
    }

    /// His four files: a text file, a PDF, a kept text file and a text file kept as knowledge.
    private static let his = [file(1, "plan.md", "text/markdown"), file(2, "deck.pdf", "application/pdf"),
                              file(3, "notes.txt", "text/plain", kept: .init(at: now - 30)),
                              file(4, "tolerances.md", "text/markdown",
                                   kept: .init(at: now - 30, knowledge: "knowledge/owner/tolerances.md"))]
    private static let agents = file(5, "report.txt", "text/plain"), guidance = file(6, "brief.txt", "text/plain")

    /// The three kinds of files, in a window that no screen shows.
    @MainActor private static func host(_ store: FleetStore) -> (Window, NSView) {
        let host = NSHostingView(rootView: VStack(spacing: 12) {
            MessageFilesView(store: store, files: his)
            MessageFilesView(store: store, files: [agents], alignment: .leading, keeps: false)
            MessageFilesView(store: store, files: [guidance], plain: true)
        }.preferredColorScheme(.dark).frame(width: 480))
        let window = Window(contentRect: NSRect(x: -40000, y: -40000, width: 480, height: 700),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = host
        window.orderFront(nil)
        return (window, host)
    }

    private static func get(_ object: NSObject, _ name: String) -> Any? {
        object.responds(to: NSSelectorFromString(name)) ? object.perform(NSSelectorFromString(name))?.takeUnretainedValue() : nil
    }

    /// VoiceOver's actions of each file's element, by the file's number.
    @MainActor private static func actions(in host: NSView) -> [Int: [NSAccessibilityCustomAction]] {
        var queue: [NSObject] = [host], found: [Int: [NSAccessibilityCustomAction]] = [:]
        while !queue.isEmpty {
            let object = queue.removeFirst()
            if let name = get(object, "accessibilityIdentifier") as? String, name.hasPrefix("file-"),
               let id = Int(name.dropFirst(5)) {
                found[id] = get(object, "accessibilityCustomActions") as? [NSAccessibilityCustomAction] ?? []
            }
            queue += (get(object, "accessibilityChildren") as? [Any] ?? []).compactMap { $0 as? NSObject }
        }
        return found
    }

    /// The "…"s that the view draws: each one has the view that places its menu (and SwiftUI's host of that view,
    /// which is not counted).
    @MainActor private static func menus(in view: NSView) -> Int {
        (String(reflecting: type(of: view)).hasPrefix("Founderizer.FleetMenuAnchor.") ? 1 : 0)
            + view.subviews.map(menus).reduce(0, +)
    }

    private static func press(_ action: NSAccessibilityCustomAction) {
        if let handler = action.handler { _ = handler() } else if let target = action.target as? NSObject,
                                                                   let selector = action.selector {
            _ = target.perform(selector, with: action)
        }
    }

    @Test func hisFilesHaveTheRowsChoicesInTheirMenuAndAnAgentsFileHasNone() async throws {
        // VoiceOver's actions by their names: AppKit gives them in an order of its own
        typealias Seen = (actions: [Int: Set<String>], menus: Int)
        let (seen, screen) = try await ViewHost.onMainLoop { () -> Seen in
            let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            NSApp.accessibilitySetValue(true, forAttribute: enhanced)
            defer { NSApp.accessibilitySetValue(false, forAttribute: enhanced) }
            let store = ViewHost.store(try ViewHost.reading(needs: [], features: ["attachment_knowledge"]))
            let (window, host) = Self.host(store)
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            var seen: Seen = ([:], 0)
            ViewHost.turn(20) {
                seen = (Self.actions(in: host).mapValues { Set($0.map(\.name)) }, Self.menus(in: host))
                return seen.actions.count == 6 && seen.actions[1]?.isEmpty == false && seen.menus > 0
            }
            return seen
        }
        let keep = String(l10n: "Keep"), stop = String(l10n: "Stop keeping"), words = String(l10n: "Keep as knowledge")
        #expect(seen.actions[1] == [keep, words], "a text file that is not kept: both of the row's presses")
        #expect(seen.actions[2] == [keep], "a PDF is kept only as the file itself")
        #expect(seen.actions[3] == [stop] && seen.actions[4] == [stop], "a kept file: the way back, and nothing else")
        #expect(seen.actions[5] == [String(l10n: "Save to Downloads")], "an agent's file keeps its save, and no keep")
        #expect(seen.actions[6] == [], "a guidance's file has neither")
        #expect(seen.menus == 4, "one \"…\" on each of his files, none on an agent's or a guidance's: \(seen)")
        #expect(screen.stayedHis)
    }

    @Test func eachChoiceSendsWhatTheRowsPressSent() async throws {
        let (posts, screen) = try await ViewHost.onMainLoop { () -> [String] in
            let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            NSApp.accessibilitySetValue(true, forAttribute: enhanced)
            defer { NSApp.accessibilitySetValue(false, forAttribute: enhanced) }
            let state: [String: Any] = [
                "schema_version": 1, "db": "own-file-\(UUID().uuidString)", "time": Int(Self.now),
                "agents": [["name": "manager", "role": "manager", "runtime": "claude", "can": [], "placed": true]],
                "tasks": [], "holds": [], "outcomes": [], "notes": [], "needs": [], "permissions": [], "messages": [],
                "reports": [], "ui_features": ["attachment_knowledge"]]
            let reading = try JSONSerialization.data(withJSONObject: state)
            let hub = try LoopbackHub(state: reading)
            defer { hub.stop() }
            _ = ViewHost.store(try HubState.decode(reading))       // the test's own defaults and folder
            AppDefaults.store.set(hub.address, forKey: "hubAddress")
            let store = FleetStore()
            Task { await store.refresh() }
            ViewHost.turn(10) { store.canWrite }
            let (window, host) = Self.host(store)
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            var found: [Int: [NSAccessibilityCustomAction]] = [:]
            ViewHost.turn(20) {
                found = Self.actions(in: host)
                return found[1]?.isEmpty == false && found[2]?.isEmpty == false && found[3]?.isEmpty == false
            }
            for (id, name) in [(1, String(l10n: "Keep as knowledge")), (2, String(l10n: "Keep")),
                               (3, String(l10n: "Stop keeping"))] {
                guard let action = found[id]?.first(where: { $0.name == name }) else {
                    throw ViewHost.Missing(description: "file \(id) has no action \(name)")
                }
                Self.press(action)
            }
            let sent = { hub.requests.filter { $0.method == "POST" } }
            ViewHost.turn(15) { sent().count >= 3 }
            return sent().map { "\($0.path) \($0.body)" }.sorted()
        }
        try #require(posts.count == 3, "\(posts)")
        #expect(posts[0].hasPrefix("/ui/attachments/2/keep ") && posts[0].contains(#""keep":true"#), "Keep: \(posts[0])")
        #expect(posts[1].hasPrefix("/ui/attachments/3/keep ") && posts[1].contains(#""keep":false"#),
                "Stop keeping: \(posts[1])")
        #expect(posts[2].hasPrefix("/ui/knowledge ") && posts[2].contains(#""attachment":1"#), "Keep as knowledge: \(posts[2])")
        #expect(screen.stayedHis)
    }
}
