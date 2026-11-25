import AppKit
import FleetCore
import Testing
@testable import Founderizer

/// **A key that he adds to a knowledge file's text box waits for his choice, as in the chat's box**
/// (`KnowledgePage.editor`, `KeyHoldBanner`). Until 22 November 2026 the box of Settings › Knowledge saved the owner's
/// words into the file with no question, while the chat's box, a request's answer, Needs clarification, the feedback
/// box and a task's guidance held words that look like a key. The bugs that these catch: a knowledge file's box with no
/// key hold, so a key that he types or pastes there is saved into a file that agents read (on its check mark, or when
/// the box loses the cursor); his whole edit lost when he leaves the page while a key holds it, or given back over a
/// newer text of the hub's, which its save would replace; "Keep it" that saves
/// nothing; and a guard that holds a file for a key-like string that it held already, so a file of his cannot be saved
/// without "Keep it". A file with no key is saved on the same paths, so a check that nothing was saved cannot pass for
/// another reason. The elements are read and pressed as an assistive app does (`JobCardPressTests`).
@Suite(.serialized, .timeLimit(.minutes(2)))
struct KnowledgeKeyHoldTests {
    /// A made-up key with the shape of a real one (`KeyInText` knows it by its prefix), in two parts so that no scan of
    /// the repository takes it for a key.
    private static let keyText = "sk_test_" + "EXAMPLEexample0123456789"
    private static let path = "knowledge/owner/launch-plan.md"

    /// A reading with one file of the owner's, of a hub that takes its edit and secrets.
    private static func reading() throws -> Data {
        let file: [String: Any] = ["path": path, "title": "Launch plan", "scope": "owner", "bytes": 120,
                                   "source": "launch-plan.md · added 2026-11-01", "commit": "0123abc"]
        let state: [String: Any] = [
            "schema_version": 1, "db": "view-test-\(UUID().uuidString)", "time": Int(Date().timeIntervalSince1970),
            "agents": [["name": "manager", "role": "manager", "runtime": "claude", "can": [], "placed": true]],
            "tasks": [], "holds": [], "outcomes": [], "notes": [], "needs": [], "permissions": [], "messages": [],
            "reports": [], "knowledge": [file],
            "ui_features": [KnowledgeClient.feature, KnowledgeClient.editFeature, SecretEntryView.feature, "secret_grants"]]
        return try JSONSerialization.data(withJSONObject: state)
    }

    /// The hub's answer to a read of the file: its title and Source lines, which the box does not show, then `words`.
    private static func file(_ words: String, database: String) throws -> Data {
        let file: [String: Any] = ["db": database, "path": path, "title": "Launch plan",
                                   "source": "launch-plan.md · added 2026-11-01",
                                   "text": "# Launch plan\n\nSource: launch-plan.md · added 2026-11-01\n\n" + words]
        return try JSONSerialization.data(withJSONObject: file)
    }

    /// The stand-in hub, the store that reads it and the app's window, with Settings › Knowledge open on the file whose
    /// words are `words`, and the box open on them. `body` reads what it needs; the hub and the window end after it.
    @MainActor private static func withBox<Seen>(_ words: String,
                                                 _ body: (LoopbackHub, FleetStore, NSWindow, NSTextView?) throws -> Seen) throws -> Seen {
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(false, forAttribute: enhanced) }
        let state = try reading()
        let hub = try LoopbackHub(state: state)
        defer { hub.stop() }
        _ = ViewHost.store(try HubState.decode(state))         // the test's own defaults and folder
        AppDefaults.store.set(hub.address, forKey: "hubAddress")
        let store = FleetStore()
        Task { await store.refresh() }
        ViewHost.turn(10) { store.canWrite }
        // the file's text, which the page reads when it opens the file
        hub.give(try file(words, database: store.state?.db ?? ""), at: "/ui/knowledge")
        let window = ViewHost.window(store)
        defer { ViewHost.close(window) }
        open(store)
        press("knowledge-edit", in: window)
        ViewHost.turn(20) { box(in: window) != nil }
        return try body(hub, store, window, box(in: window))
    }

    /// Settings › Knowledge, on the file.
    @MainActor private static func open(_ store: FleetStore) {
        store.knowledgeRead = path
        store.show(.settings(.knowledge))
    }

    /// The first element of the window that `matches`, as an assistive app walks it, or nil.
    @MainActor private static func find(in window: NSWindow, _ matches: (NSObject) -> Bool) -> NSObject? {
        var queue: [NSObject] = [window.contentView].compactMap { $0 }
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

    /// The element of this identifier in the window, or nil while the window does not show it.
    @MainActor private static func element(_ identifier: String, in window: NSWindow) -> NSObject? {
        find(in: window) { attribute("accessibilityIdentifier", of: $0) == identifier }
    }

    /// The window shows these words as one text of their own, exactly.
    @MainActor private static func shows(_ words: String, in window: NSWindow) -> Bool {
        find(in: window) { attribute("accessibilityLabel", of: $0) == words || attribute("accessibilityValue", of: $0) == words } != nil
    }

    /// The box's own text view, the one of the window that takes words, or nil while the box does not show.
    @MainActor private static func box(in window: NSWindow) -> NSTextView? {
        var queue: [NSView] = [window.contentView].compactMap { $0 }
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let text = view as? NSTextView, text.isEditable, !text.isFieldEditor { return text }
            queue += view.subviews
        }
        return nil
    }

    /// Words that come into the box as typed words do: in place of all its text, through the text view's own input.
    @MainActor private static func type(_ words: String, into box: NSTextView) {
        box.selectAll(nil)
        box.insertText(words, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    @MainActor private static func press(_ identifier: String, in window: NSWindow) {
        ViewHost.turn(10) { Self.element(identifier, in: window) != nil }
        if let button = Self.element(identifier, in: window) {
            _ = button.perform(NSSelectorFromString("accessibilityPerformPress"))
        }
    }

    /// The box has the cursor, and then the cursor leaves it, as a click elsewhere takes it. A window of a test gives the
    /// box no cursor of its own (the app is never in front), so the box takes it here first.
    @MainActor private static func cursorLeaves(_ box: NSTextView, in window: NSWindow) {
        window.makeFirstResponder(box)
        ViewHost.turn(0.5)
        window.makeFirstResponder(nil)
    }

    /// The hub answered a moment ago, so a save would go now.
    @MainActor private static func fresh(_ store: FleetStore) {
        Task { await store.refresh() }
        ViewHost.turn(10) { store.writesNow }
    }

    /// The saves of the file's text that reached the hub.
    private static func saves(_ hub: LoopbackHub) -> Int {
        hub.requests.filter { $0.method == "POST" && $0.path == "/ui/knowledge" }.count
    }

    struct Held: Sendable {
        var boxShown = false, askedOnWords = false, bannerShown = false, fileWords = false, endedWithoutKey = false
        var heldOnDone = false, boxStayed = false, heldOnBlur = false, savesWhileHeld = -1
        var leftWithoutBox = false, givenBack = false, askedAgain = false, savesAfterReturn = -1, savesAfterKeep = -1
    }

    @Test func aKeyThatHeAddsWaitsForHisChoiceAndIsNotSavedNorLost() async throws {
        let words = "The launch is on Monday. Use this key: " + Self.keyText
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 100) { () -> Held in
            try Self.withBox("The launch is on Monday.") { hub, store, window, box in
                var seen = Held()
                guard let box else { return seen }
                seen.boxShown = true
                // his words with a key come into the box: the question under it
                Self.type(words, into: box)
                seen.askedOnWords = ViewHost.turn(10) { store.heldKey?.hold == .text }
                seen.bannerShown = ViewHost.turn(10) { Self.element("key-hold", in: window) != nil }
                seen.fileWords = ViewHost.turn(10) { Self.shows("This file holds what looks like a key.", in: window) }
                // words with no key end it
                Self.type("The launch is on Tuesday.", into: box)
                seen.endedWithoutKey = ViewHost.turn(10) { store.heldKey == nil }
                // another box's question stands, so this box asks nothing while he types: its check mark holds the key
                let other = HeldKey(composer: "another box", hold: .text)
                store.heldKey = other
                Self.type(words, into: box)
                Self.fresh(store)
                Self.press("knowledge-done", in: window)
                seen.heldOnDone = ViewHost.turn(10) { store.heldKey != other && store.heldKey?.hold == .text }
                ViewHost.turn(1)
                seen.boxStayed = Self.box(in: window) != nil
                // and so does the cursor that leaves the box
                store.heldKey = other
                Self.fresh(store)
                Self.cursorLeaves(box, in: window)
                seen.heldOnBlur = ViewHost.turn(10) { store.heldKey != other && store.heldKey?.hold == .text }
                ViewHost.turn(2)
                seen.savesWhileHeld = Self.saves(hub)
                // he leaves the page and comes back: his words wait in the box, with the question
                store.show(.needs)
                seen.leftWithoutBox = ViewHost.turn(10) { Self.box(in: window) == nil }
                Self.open(store)
                seen.givenBack = ViewHost.turn(20) { Self.box(in: window)?.string == words }
                seen.askedAgain = ViewHost.turn(10) { Self.element("key-hold", in: window) != nil }
                ViewHost.turn(1)
                seen.savesAfterReturn = Self.saves(hub)
                // "Keep it": the words are saved, once
                Self.fresh(store)
                Self.press("key-hold-go-on", in: window)
                ViewHost.turn(10) { Self.saves(hub) > 0 }
                ViewHost.turn(1)
                seen.savesAfterKeep = Self.saves(hub)
                return seen
            }
        }
        #expect(seen.boxShown, "the pencil opens the file's text in the box")
        #expect(seen.askedOnWords, "words with a key get the box's question")
        #expect(seen.bannerShown, "the question shows with the box")
        #expect(seen.fileWords, "in the words of a file, which every agent that reads it has")
        #expect(seen.endedWithoutKey, "words with no key end the question")
        #expect(seen.heldOnDone, "the check mark holds a key also when the box asked nothing")
        #expect(seen.boxStayed, "the box stays open with his words")
        #expect(seen.heldOnBlur, "the cursor that leaves the box holds the key too")
        #expect(seen.savesWhileHeld == 0, "no text with the key reached the hub")
        #expect(seen.leftWithoutBox, "the page went away")
        #expect(seen.givenBack, "the file gives his words back in the box")
        #expect(seen.askedAgain, "with the question")
        #expect(seen.savesAfterReturn == 0, "and still saves nothing")
        #expect(seen.savesAfterKeep == 1, "Keep it saves the words, once")
        #expect(screen.stayedHis)
    }

    struct Changed: Sendable {
        var boxShown = false, left = false, readAgain = false, givenBack = true, newText = false, asked = true, saves = -1
    }

    /// **A held text that the hub's text has moved past is not given back**: the save sends the whole text, so his old
    /// text would put itself over an agent's edit, or another save, made meanwhile. The file opens with the hub's text.
    @Test func aHeldTextGoesWhenTheFilesTextChangedAtTheHub() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop { () -> Changed in
            try Self.withBox("The launch is on Monday.") { hub, store, window, box in
                var seen = Changed()
                guard let box else { return seen }
                seen.boxShown = true
                Self.type("The launch is on Monday. Use this key: " + Self.keyText, into: box)
                ViewHost.turn(1)
                store.show(.needs)
                seen.left = ViewHost.turn(10) { Self.box(in: window) == nil }
                // an agent changes the file meanwhile
                let newer = "The launch is on Friday."
                hub.give(try Self.file(newer, database: store.state?.db ?? ""), at: "/ui/knowledge")
                Self.open(store)
                seen.readAgain = ViewHost.turn(20) {
                    (store.reading("knowledge.file.fleet") as KnowledgeFile?)?.text.hasSuffix(newer) == true
                }
                ViewHost.turn(1)
                seen.givenBack = Self.box(in: window) != nil
                Self.press("knowledge-edit", in: window)
                seen.newText = ViewHost.turn(10) { Self.box(in: window)?.string == newer }
                ViewHost.turn(2)
                seen.asked = store.heldKey != nil || Self.element("key-hold", in: window) != nil
                seen.saves = Self.saves(hub)
                return seen
            }
        }
        #expect(seen.boxShown, "the pencil opens the file's text in the box")
        #expect(seen.left, "the page went away with his held text")
        #expect(seen.readAgain, "the file's new text is read when it opens again")
        #expect(!seen.givenBack, "his old text does not come back over it")
        #expect(seen.newText, "the box opens on the hub's new text")
        #expect(!seen.asked, "with no question")
        #expect(seen.saves == 0, "and nothing was saved")
        #expect(screen.stayedHis)
    }

    struct Saved: Sendable {
        var boxShown = false, savesOnBlur = -1, savesOnDone = -1, boxClosed = false, asked = true
    }

    /// The positive control: the same file and the same paths, with words that add no key, reach the hub.
    @Test func wordsWithNoKeyAreSavedWhenTheCursorLeavesAndOnTheCheckMark() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop { () -> Saved in
            try Self.withBox("The launch is on Monday.") { hub, store, window, box in
                var seen = Saved()
                guard let box else { return seen }
                seen.boxShown = true
                Self.type("The launch is on Tuesday.", into: box)
                Self.fresh(store)
                Self.cursorLeaves(box, in: window)
                ViewHost.turn(10) { Self.saves(hub) > 0 }
                seen.savesOnBlur = Self.saves(hub)
                Self.type("The launch is on Wednesday.", into: box)
                Self.fresh(store)
                Self.press("knowledge-done", in: window)
                ViewHost.turn(10) { Self.saves(hub) > 1 }
                seen.savesOnDone = Self.saves(hub)
                seen.boxClosed = ViewHost.turn(10) { Self.box(in: window) == nil }
                seen.asked = store.heldKey != nil
                return seen
            }
        }
        #expect(seen.boxShown, "the pencil opens the file's text in the box")
        #expect(seen.savesOnBlur == 1, "the cursor that leaves the box saves words with no key")
        #expect(seen.savesOnDone == 2, "and so does the check mark")
        #expect(seen.boxClosed, "which closes the box")
        #expect(!seen.asked, "with no question")
        #expect(screen.stayedHis)
    }

    struct Kept: Sendable {
        var boxShown = false, askedOnOpen = true, askedOnEdit = true, saves = -1, boxClosed = false
    }

    /// A file that holds a key-like string already opens, and takes an edit beside it, with no question.
    @Test func aFileThatHoldsAKeyAlreadyTakesAnotherEditWithNoQuestion() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop { () -> Kept in
            try Self.withBox("The launch is on Monday. Old key: " + Self.keyText) { hub, store, window, box in
                var seen = Kept()
                guard let box else { return seen }
                seen.boxShown = true
                ViewHost.turn(2)
                seen.askedOnOpen = store.heldKey != nil || Self.element("key-hold", in: window) != nil
                Self.type("The launch is on Tuesday. Old key: " + Self.keyText, into: box)
                ViewHost.turn(2)
                seen.askedOnEdit = store.heldKey != nil || Self.element("key-hold", in: window) != nil
                Self.fresh(store)
                Self.press("knowledge-done", in: window)
                ViewHost.turn(10) { Self.saves(hub) > 0 }
                seen.saves = Self.saves(hub)
                seen.boxClosed = ViewHost.turn(10) { Self.box(in: window) == nil }
                return seen
            }
        }
        #expect(seen.boxShown, "the pencil opens the file's text in the box")
        #expect(!seen.askedOnOpen, "the file's own key-like string asks nothing before an edit")
        #expect(!seen.askedOnEdit, "nor after an edit that adds no key")
        #expect(seen.saves == 1, "the check mark saves the edit")
        #expect(seen.boxClosed, "and closes the box")
        #expect(screen.stayedHis)
    }
}
