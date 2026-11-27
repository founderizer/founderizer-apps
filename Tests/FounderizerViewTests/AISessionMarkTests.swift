import AppKit
import FleetCore
import Testing
import Vision
@testable import Founderizer

/// **A message that an AI session sent for him does not look like his own** (owner feature `message_hands`; the owner's
/// "B, go ahead" of 24 November 2026 to the picture `ai-session-mark-2026-11-24/1b-outline-and-mark.png`): in his chat
/// it stands at the right in the bubble's outline, with the AI's mark in the bubble's lower left corner and "Sent by
/// your AI session" on hover; his line of a card's talk that an AI session sent has the mark too. The real chat of the
/// app, on a reading with no hub. Example names only.
@Suite(.serialized, .timeLimit(.minutes(2))) struct AISessionMarkTests {
    private static let aiWords = "Draft the launch notes", hisWords = "Check the invoices", talkWords = "Which account is it"

    struct Seen: Sendable {
        /// The marks with the words "Sent by your AI session": how many, and the hover words of each.
        var marks = 0, helps: [String] = []
        /// The light of each bubble's fill, left of its words, in its padding (0 black, 1 white).
        var aiFill: Double?, hisFill: Double?, canvas: Double?
        /// How far the mark nearest the AI session's words stands from them: its middle left of their first letter, and
        /// under the middle of their line, in points.
        var markLeft: Double?, markUnder: Double?
        /// Whether the chat showed the AI session's words and his own, and the card's talk.
        var wordsShown: [Bool] = [], talkShown = false
        /// What VoiceOver reads for the card's talk line that the AI session sent.
        var talkSpoken: [String] = []
    }

    /// The bugs that this catches: an AI session's message in his filled bubble (the fault that he saw), or with no
    /// mark, or a mark with no hover words; the mark on his own words (from a chat app here) or not on the bubble's lower
    /// left corner; and an AI session's line of a card's talk with no mark, or which VoiceOver reads as "You: …".
    @Test func anAISessionsMessageIsOutlinedWithItsMarkAndHisOwnIsFilledWithNone() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 90) { () -> Seen in
            let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            NSApp.accessibilitySetValue(true, forAttribute: enhanced)
            defer { NSApp.accessibilitySetValue(false, forAttribute: enhanced) }
            // the chat draws the store's own timeline, which a read of a hub fills: a stand-in hub gives the reading
            let state = try Self.reading()
            let hub = try LoopbackHub(state: state)
            defer { hub.stop() }
            _ = ViewHost.store(try HubState.decode(state))         // the test's own defaults and folder
            AppDefaults.store.set(hub.address, forKey: "hubAddress")
            let store = FleetStore()
            Task { await store.refresh() }
            ViewHost.turn(10) { store.state != nil }
            store.destination = .agent("manager")
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            var seen = Seen()
            let ai = try Self.place(of: Self.aiWords, in: window), his = try Self.place(of: Self.hisWords, in: window)
            seen.talkShown = try Self.place(of: Self.talkWords, in: window) != nil
            seen.wordsShown = [ai != nil, his != nil]
            guard let ai, let his else { return seen }
            seen.aiFill = Self.light(at: CGPoint(x: ai.minX - 8, y: ai.midY), in: window)
            seen.hisFill = Self.light(at: CGPoint(x: his.minX - 8, y: his.midY), in: window)
            // the chat's canvas, far left of the bubbles, between them
            seen.canvas = Self.light(at: CGPoint(x: FleetStyle.sidebarWidth + 40, y: (ai.midY + his.midY) / 2), in: window)
            let marks = Self.elements(in: window) { $0 == OwnerHand.sentByAISession }
            seen.talkSpoken = Self.elements(in: window) { $0?.contains(Self.talkWords) == true }
                .compactMap { Self.text($0, "accessibilityLabel") }
            seen.marks = marks.count
            seen.helps = marks.map { mark in
                Self.text(mark, "accessibilityHelp")
                    ?? (mark.responds(to: NSSelectorFromString("accessibilityAttributeValue:"))
                        ? mark.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: "AXHelp")?
                            .takeUnretainedValue() as? String : nil) ?? ""
            }
            // the mark of the chat's bubble: the one nearest the AI session's words, on the screen
            let words = Self.onScreen(ai, in: window)
            if let mark = marks.map({ Self.upright(Self.frame(of: $0), in: window) })
                .min(by: { abs($0.midY - words.midY) < abs($1.midY - words.midY) }) {
                seen.markLeft = words.minX - mark.midX
                seen.markUnder = words.midY - mark.midY
            }
            return seen
        }
        #expect(seen.wordsShown == [true, true] && seen.talkShown, "the chat shows the AI session's words, his own, the talk")
        let ai = try #require(seen.aiFill)
        let his = try #require(seen.hisFill), canvas = try #require(seen.canvas)
        #expect(abs(ai - canvas) < 0.02, "the AI session's bubble has no fill: \(ai), the canvas \(canvas)")
        #expect(his - canvas > 0.05, "his own bubble is filled: \(his), the canvas \(canvas)")
        #expect(seen.marks == 2, "one mark on the chat's bubble and one on the talk's line, none on his own words")
        #expect(seen.helps.allSatisfy { $0 == OwnerHand.sentByAISession }, "\(seen.helps)")
        // VoiceOver never says that he wrote the AI session's line: the mark's words, then the line
        #expect(seen.talkSpoken.contains("\(OwnerHand.sentByAISession): \(Self.talkWords) for?"), "\(seen.talkSpoken)")
        #expect(!seen.talkSpoken.contains { $0.hasPrefix("You:") }, "\(seen.talkSpoken)")
        // 16 points of padding, then the mark's middle 7 points left of the bubble's edge and 9 to the right of it
        let left = try #require(seen.markLeft), under = try #require(seen.markUnder)
        #expect((8...22).contains(left), "the mark's middle stands \(left) points left of the words")
        #expect((4...30).contains(under), "the mark's middle stands \(under) points under the words' line")
        #expect(screen.stayedHis)
    }

    /// The manager's chat: the AI session's message, then his own from a chat app, and an open item whose talk has his
    /// line that an AI session sent, on a hub that gives the hands.
    private static func reading() throws -> Data {
        let now = Date().timeIntervalSince1970
        func message(_ text: String, ago: Double, _ fields: [String: Any]) -> [String: Any] {
            ["request_id": UUID().uuidString.lowercased(), "recipient": "manager", "kind": "message", "text": text,
             "event_id": Int(ago), "created": now - ago, "client": "example-client"].merging(fields) { $1 }
        }
        let state: [String: Any] = [
            "schema_version": 1, "db": "view-test-\(UUID().uuidString)", "time": Int(now),
            "agents": [["name": "manager", "role": "manager", "runtime": "claude", "can": [], "placed": true]],
            "tasks": [], "holds": [], "outcomes": [], "notes": [], "permissions": [], "reports": [],
            // one line each, so the mark stands one bubble's padding under the words' line
            "messages": [message("\(aiWords) today.", ago: 900, ["hand": "tool", "runtime": "claude-code"]),
                         message("\(hisWords) today.", ago: 800,
                                 ["hand": "chat", "origin": ["app": "whatsapp"]])],
            "needs": [["id": 41, "title": "Pick the account for the example shop", "why": "", "todo": "",
                       "raised": now - 600, "by": "manager", "options": ["Shared", "Own"],
                       "talk": [["who": "owner", "text": "\(talkWords) for?", "ts": now - 500, "hand": "tool",
                                 "runtime": "codex"]]]],
            "ui_features": ["direct_chat", "need_options", NeedTalk.feature, NeedClarify.feature, OwnerHand.feature]]
        return try JSONSerialization.data(withJSONObject: state)
    }

    /// Where the chat's column shows these words, in the view's points with the view's own origin, read as a person
    /// reads them (Vision, English), within 20 s: right of the sidebar, which shows his newest words too.
    @MainActor private static func place(of words: String, in window: NSWindow) throws -> CGRect? {
        guard let view = window.contentView else { return nil }
        let end = Date().addingTimeInterval(20)
        repeat {
            if let picture = Self.picture(of: view), let image = picture.cgImage {
                let reading = VNRecognizeTextRequest()
                reading.recognitionLevel = .accurate
                reading.recognitionLanguages = ["en-US"]
                reading.usesLanguageCorrection = false
                try VNImageRequestHandler(cgImage: image).perform([reading])
                for line in reading.results ?? [] {
                    for text in line.topCandidates(3) {
                        guard let range = text.string.range(of: words),
                              let box = try? text.boundingBox(for: range)?.boundingBox else { continue }
                        let width = view.bounds.width, height = view.bounds.height
                        let found = CGRect(x: box.minX * width, y: view.isFlipped ? (1 - box.maxY) * height : box.minY * height,
                                           width: box.width * width, height: box.height * height)
                        if found.midX > FleetStyle.sidebarWidth + 20 { return found }
                    }
                }
            }
            ViewHost.turn(0.3)
        } while Date() < end
        return nil
    }

    @MainActor private static func picture(of view: NSView) -> NSBitmapImageRep? {
        view.layoutSubtreeIfNeeded()
        view.display()
        guard let picture = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: picture)
        return picture
    }

    /// The light of the window's picture at a point of the view (0 black, 1 white).
    @MainActor private static func light(at point: CGPoint, in window: NSWindow) -> Double? {
        guard let view = window.contentView, let picture = picture(of: view) else { return nil }
        let scale = CGFloat(picture.pixelsWide) / view.bounds.width
        let row = view.isFlipped ? point.y : view.bounds.height - point.y
        guard let color = picture.colorAt(x: Int(point.x * scale), y: Int(row * scale))?.usingColorSpace(.deviceRGB) else {
            return nil
        }
        return Double(color.redComponent + color.greenComponent + color.blueComponent) / 3
    }

    /// A rectangle of the view, on the screen, as the accessibility frames are.
    @MainActor private static func onScreen(_ rect: CGRect, in window: NSWindow) -> CGRect {
        guard let view = window.contentView else { return rect }
        return window.convertToScreen(view.convert(rect, to: nil))
    }

    @MainActor private static func text(_ object: NSObject, _ name: String) -> String? {
        guard object.responds(to: NSSelectorFromString(name)) else { return nil }
        return object.perform(NSSelectorFromString(name))?.takeUnretainedValue() as? String
    }

    /// Every element of the window's accessibility tree whose label passes `matches`. SwiftUI makes its elements once
    /// the app says that an assistive app reads it (`AXEnhancedUserInterface`). The elements of a text's links
    /// (SwiftUI's link rotor) are passed over: the label of one throws an exception out of SwiftUI.
    @MainActor private static func elements(in window: NSWindow, _ matches: (String?) -> Bool) -> [NSObject] {
        var queue: [NSObject] = window.contentView.map { [$0] } ?? [], found: [NSObject] = []
        while !queue.isEmpty {
            let object = queue.removeFirst()
            if NSStringFromClass(type(of: object)).contains("LinkRotor") { continue }
            if matches(text(object, "accessibilityLabel")) { found.append(object) }
            if object.responds(to: NSSelectorFromString("accessibilityChildren")),
               let kids = object.perform(NSSelectorFromString("accessibilityChildren"))?.takeUnretainedValue() as? [Any] {
                queue += kids.compactMap { $0 as? NSObject }
            }
        }
        return found
    }

    /// **An element's frame on the screen with its origin at the lower left**, as the window's, whichever origin the
    /// element gives: a frame outside the window is read from the top left of the first screen.
    @MainActor private static func upright(_ frame: NSRect, in window: NSWindow) -> NSRect {
        if window.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) { return frame }
        let height = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
    }

    /// Where an element says that it stands, on the screen.
    @MainActor private static func frame(of element: NSObject) -> NSRect {
        let frame = NSSelectorFromString("accessibilityFrame")
        typealias Frame = @convention(c) (AnyObject, Selector) -> NSRect
        return unsafeBitCast(element.method(for: frame), to: Frame.self)(element, frame)
    }
}
