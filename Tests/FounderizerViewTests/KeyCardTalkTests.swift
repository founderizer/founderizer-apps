import AppKit
import FleetCore
import Testing
@testable import Founderizer

/// **A key request's card shows his talk with the manager over its form** (owner feature `need_clarify`): a key
/// request that took another's place carries his question about it (the area Needs-you and the manager, 21 November
/// 2026), and a chat's card drew the talk only inside the answer box, which a key card does not have. Needs you draws it
/// over every request's answers already.
@Suite(.serialized, .timeLimit(.minutes(1))) struct KeyCardTalkTests {
    @Test func anOpenKeyCardInAChatShowsHisTalkOverItsForm() async throws {
        let (shown, screen) = try await ViewHost.onMainLoop { () -> Bool in
            let now = Int(Date().timeIntervalSince1970)
            let store = ViewHost.store(try ViewHost.reading(
                needs: [["id": 71, "title": "Enter the API key for the logs", "why": "", "todo": "",
                         "raised": now - 300, "by": "manager", "answered": NSNull(), "kind": "secret",
                         "secret": ["kind": "api_key", "env": "ACME_LOGS_KEY"],
                         "talk": [["who": "owner", "text": "Which account is this for?", "ts": now - 200],
                                  ["who": "manager", "text": "The shared one of the support team.", "ts": now - 100]]]],
                features: [NeedTalk.feature, NeedClarify.feature]))
            store.destination = .agent("manager")
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            return try ViewHost.middle(of: "Which account is this for", in: window) != nil
        }
        #expect(shown, "his question stands on the key card")
        #expect(screen.stayedHis)
    }

    /// **His bubble over a login's form ends where the form ends**, in a chat's card and on Needs you (the owner's "not
    /// aligned, please fix" of 22 November 2026, with a picture of each). The bug that this catches: the talk takes the
    /// card's whole width, and the column's on Needs you, while the form stops at its own width in a chat and is a
    /// step's field wide on Needs you, so his bubble stands past the form's right edge.
    @Test func hisBubbleOverALoginsFormEndsWhereTheFormEnds() async throws {
        typealias Edges = (bubble: CGFloat, form: CGFloat)
        let (seen, screen) = try await ViewHost.onMainLoop { () -> (chat: Edges?, step: Edges?) in
            let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            NSApp.accessibilitySetValue(true, forAttribute: enhanced)
            defer { NSApp.accessibilitySetValue(false, forAttribute: enhanced) }
            let database = "view-test-\(UUID().uuidString)"
            let state = try Self.loginReading(database)
            let hub = try LoopbackHub(state: state)
            defer { hub.stop() }
            // the central vault answers with the key that this Mac pinned, so the form shows its fields and keeps them
            hub.give(try JSONSerialization.data(withJSONObject: [
                "db": database, "fleet": Self.fleet, "machines": [], "held": [:],
                "central": ["ok": true, "recipient": Self.recipient, "fleet": Self.fleet, "pins": [:], "grants": [],
                            "pool": []],
            ]), at: "/ui/vault")
            _ = ViewHost.store(try HubState.decode(state))         // the test's own defaults and folder
            AppDefaults.store.set(hub.address, forKey: "hubAddress")
            let store = FleetStore()
            CentralVaultPins.pin(Self.recipient, hub: store.hub, fleet: Self.fleet)
            Task { await store.refresh() }
            ViewHost.turn(10) { store.canWrite }
            store.destination = .agent("manager")
            // wider than a chat's card with a form of its full width, as on his Mac
            let window = ViewHost.window(store, size: NSSize(width: 1500, height: 900))
            defer { ViewHost.close(window) }
            let bubble = "You: \(Self.question)"
            @MainActor func edges(_ form: String, box: Bool) -> Edges? {
                guard let talk = Self.element(in: window, { $0.label == bubble }),
                      let field = Self.element(in: window, { $0.identifier == form }) else { return nil }
                let place = Self.frame(of: field)
                guard let edge = box ? Self.boxEdge(of: place, in: window) : place.maxX else { return nil }
                return (Self.frame(of: talk).maxX, edge)
            }
            // The edges once two reads 0.2 s apart agree: a layout that still moves gives none.
            @MainActor func steady(_ form: String, box: Bool) -> Edges? {
                for _ in 0..<40 {
                    let first = edges(form, box: box)
                    ViewHost.turn(0.2)
                    if let first, let second = edges(form, box: box), first == second { return second }
                }
                return nil
            }
            // In a chat, the form's right edge is its Save's, at the end of its row.
            ViewHost.turn(20) { hub.requests.contains(where: { $0.path == "/ui/vault" }) }
            let chat = steady("secret-save", box: false)
            // On Needs you, the request at hand is its two fields alone, in the middle: the edge of a field's box.
            store.destination = .needs
            let step = steady("secret-password", box: true)
            return (chat, step)
        }
        let chat = try #require(seen.chat, "the chat's card shows his bubble and the form")
        let step = try #require(seen.step, "Needs you shows his bubble and the form's fields")
        #expect(abs(chat.bubble - chat.form) <= 1,
                "in a chat, his bubble ends at \(chat.bubble), the form at \(chat.form)")
        #expect(abs(step.bubble - step.form) <= 1,
                "on Needs you, his bubble ends at \(step.bubble), the fields' boxes at \(step.form)")
        #expect(screen.stayedHis)
    }

    private static let question = "We no longer use this account, it can be removed"
    private static let fleet = "0123456789abcdef"
    private static let recipient = "age1aahjzcwvvmrhch43mhx4w5pld4uwqvcv5wsyrf6k493ggmm3wqus7rxumd"

    /// A hub's reading with one open login request of the manager for a named site, with his question about it, of a
    /// hub that takes secrets into its central vault.
    @MainActor private static func loginReading(_ database: String) throws -> Data {
        let now = Date().timeIntervalSince1970
        let need: [String: Any] = [
            "id": 72, "title": "Enter a login for platform.example.com",
            "why": "The agent submits the app's new tools.",
            "todo": "", "raised": now - 300, "by": "manager", "answered": NSNull(), "kind": "secret",
            "secret": ["kind": "login", "site": "https://platform.example.com"],
            "talk": [["who": "owner", "text": question, "ts": now - 200]]]
        let state: [String: Any] = [
            "schema_version": 1, "db": database, "time": Int(now),
            "agents": [["name": "manager", "role": "manager", "runtime": "claude", "can": [], "placed": true]],
            "tasks": [], "holds": [], "outcomes": [], "notes": [], "needs": [need], "permissions": [], "messages": [],
            "reports": [],
            "ui_features": [SecretEntryView.feature, "secret_grants", CentralVault.feature, NeedTalk.feature,
                            NeedClarify.feature]]
        return try JSONSerialization.data(withJSONObject: state)
    }

    /// The first element of the window's accessibility tree whose label and identifier pass `matches`. SwiftUI makes
    /// its elements once the app says that an assistive app reads it (`AXEnhancedUserInterface`). The elements of a
    /// text's links (SwiftUI's link rotor) are passed over: the label of one throws an exception out of SwiftUI.
    @MainActor private static func element(in window: NSWindow,
                                           _ matches: ((label: String?, identifier: String?)) -> Bool) -> NSObject? {
        func text(_ object: NSObject, _ name: String) -> String? {
            guard object.responds(to: NSSelectorFromString(name)) else { return nil }
            return object.perform(NSSelectorFromString(name))?.takeUnretainedValue() as? String
        }
        var queue: [NSObject] = window.contentView.map { [$0] } ?? []
        while !queue.isEmpty {
            let object = queue.removeFirst()
            if NSStringFromClass(type(of: object)).contains("LinkRotor") { continue }
            if matches((text(object, "accessibilityLabel"), text(object, "accessibilityIdentifier"))) { return object }
            if object.responds(to: NSSelectorFromString("accessibilityChildren")),
               let kids = object.perform(NSSelectorFromString("accessibilityChildren"))?
                   .takeUnretainedValue() as? [Any] {
                queue += kids.compactMap { $0 as? NSObject }
            }
        }
        return nil
    }

    /// **The right edge of a field's box as he sees it**, on the screen: the field's accessibility frame is its box, or
    /// only its line of words, 16 points inside the box that pads it (`FleetFieldBox`); both were read. So this
    /// finds the box's edge line in the window's picture: on the field's middle line, from 24 points left of the
    /// frame's right end to 40 points right of it, the last column as light as the lightest. Nil where no column stands
    /// out: a page with no edge line has no box's edge.
    @MainActor private static func boxEdge(of field: NSRect, in window: NSWindow) -> CGFloat? {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        let local = view.convert(window.convertFromScreen(field), from: nil)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let row = Int((view.isFlipped ? local.midY : view.bounds.height - local.midY) * scale)
        let first = max(0, Int((local.maxX - 24) * scale)), end = min(rep.pixelsWide, Int((local.maxX + 40) * scale))
        guard first < end else { return nil }
        let columns = first..<end
        let light = columns.map { x -> CGFloat in
            guard let color = rep.colorAt(x: x, y: row)?.usingColorSpace(.deviceRGB) else { return 0 }
            return color.redComponent + color.greenComponent + color.blueComponent
        }
        guard let lightest = light.max(), let darkest = light.min(), lightest - darkest > 0.3,
              let last = light.lastIndex(where: { $0 >= lightest - 0.05 }) else { return nil }
        // the column after the edge line's last one, back on the screen
        let edge = CGFloat(columns.lowerBound + last + 1) / scale
        return window.convertToScreen(view.convert(NSRect(x: edge, y: local.midY, width: 0, height: 0), to: nil)).minX
    }

    /// Where an element says that it stands, on the screen.
    @MainActor private static func frame(of element: NSObject) -> NSRect {
        let frame = NSSelectorFromString("accessibilityFrame")
        typealias Frame = @convention(c) (AnyObject, Selector) -> NSRect
        return unsafeBitCast(element.method(for: frame), to: Frame.self)(element, frame)
    }
}
