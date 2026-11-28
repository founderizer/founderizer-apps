import AppKit
import CryptoKit
import FleetCore
import Testing
@testable import Founderizer

/// **A key that he adds to a knowledge file's text box waits for his choice, as in the chat's box**
/// (`KnowledgePage.editor`, `KeyHoldBanner`), **and Add file sends no file that holds one** (`KnowledgeImport.file`).
/// Until 22 November 2026 the box of Settings › Knowledge saved the owner's words into the file with no question,
/// while the chat's box, a request's answer, Needs clarification, the feedback box and a task's guidance held words
/// that look like a key. The bugs that these catch: a knowledge file's box with no
/// key hold, so a key that he types or pastes there is saved into a file that agents read (on its check mark, or when
/// the box loses the cursor); his whole edit lost when he leaves the page while a key holds it, or given back over a
/// newer text of the hub's, which its save would replace; "Keep it" that saves
/// nothing; and a guard that holds a file for a key-like string that it held already, so a file of his cannot be saved
/// without "Keep it". A file with no key is saved on the same paths, so a check that nothing was saved cannot pass for
/// another reason. The elements are read and pressed as an assistive app does (`JobCardPressTests`). Since 24 November
/// 2026 also: a "Keep it" that lets a second key through; a held text lost when an earlier save landed after he left;
/// Cmd+V, and a cut that takes more than the key; a write that names to a checking hub more parts than he kept, or
/// says `key_kept` to a hub that does not check; and a file with a key that Add file sends.
@Suite(.serialized, .timeLimit(.minutes(10)))
struct KnowledgeKeyHoldTests {
    /// A made-up key with the shape of a real one (`KeyInText` knows it by its prefix), in two parts so that no scan of
    /// the repository takes it for a key.
    private static let keyText = "sk_test_" + "EXAMPLEexample0123456789"
    /// A second made-up key, of another shape.
    private static let secondKey = "rk_test_" + "EXAMPLEsecond0123456789"
    /// A look-alike with no shape of its own: a run of letters and digits that reads as random (an id, a hash).
    private static let lookAlike = "Xk7Qp2Lm9Rt4Vb8Nc3Wz6Hd1Jf5Gs0Ya"
    private static let path = "knowledge/owner/launch-plan.md"

    /// A reading with one file of the owner's, of a hub that takes its edit and secrets, with these other features
    /// (`knowledge_key`, the hub that checks a file for a key), of a new generation or of `db`.
    private static func reading(_ features: [String] = [], db: String? = nil) throws -> Data {
        let file: [String: Any] = ["path": path, "title": "Launch plan", "scope": "owner", "bytes": 120,
                                   "source": "launch-plan.md · added 2026-11-01", "commit": "0123abc"]
        let state: [String: Any] = [
            "schema_version": 1, "db": db ?? "view-test-\(UUID().uuidString)",
            "time": Int(Date().timeIntervalSince1970),
            "agents": [["name": "manager", "role": "manager", "runtime": "claude", "can": [], "placed": true]],
            "tasks": [], "holds": [], "outcomes": [], "notes": [], "needs": [], "permissions": [], "messages": [],
            "reports": [], "knowledge": [file],
            "ui_features": [KnowledgeClient.feature, KnowledgeClient.editFeature, SecretEntryView.feature, "secret_grants"]
                + features]
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
    @MainActor private static func withBox<Seen>(_ words: String, keyCheck: Bool = false,
                                                 _ body: (LoopbackHub, FleetStore, NSWindow, NSTextView?) throws -> Seen) throws -> Seen {
        try withPage(words, features: keyCheck ? [KnowledgeClient.keyFeature] : []) { hub, store, window in
            open(store)
            press("knowledge-edit", in: window)
            ViewHost.turn(20) { box(in: window) != nil }
            return try body(hub, store, window, box(in: window))
        }
    }

    /// The stand-in hub with these features, the store that reads it and the app's window, on no page yet; the file's
    /// text is `words`.
    @MainActor private static func withPage<Seen>(_ words: String, features: [String],
                                                  _ body: (LoopbackHub, FleetStore, NSWindow) throws -> Seen) throws -> Seen {
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(false, forAttribute: enhanced) }
        let state = try reading(features)
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
        return try body(hub, store, window)
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

    /// The bodies of those saves, in their order.
    private static func posts(_ hub: LoopbackHub) -> [[String: Any]] {
        hub.requests.filter { $0.method == "POST" && $0.path == "/ui/knowledge" }.map {
            (try? JSONSerialization.jsonObject(with: Data($0.body.utf8))) as? [String: Any] ?? [:]
        }
    }

    /// The SHA-256 of a part, as `key_kept` names it: lower-case hex of its UTF-8 bytes.
    private static func sha(_ part: String) -> String {
        SHA256.hash(data: Data(part.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The hub's receipt of an edit of the file: its request's own id, for this Mac.
    private static func receipt(_ request: LoopbackHub.Request, client: String) -> (status: Int, body: Data) {
        let sent = (try? JSONSerialization.jsonObject(with: Data(request.body.utf8))) as? [String: Any] ?? [:]
        let answer: [String: Any] = ["ok": true, "request_id": sent["request_id"] as? String ?? "", "client": client,
                                     "path": path, "commit": "0123abd"]
        return (200, (try? JSONSerialization.data(withJSONObject: answer)) ?? Data())
    }

    /// **A hub with the feature `knowledge_key`, for the box's saves**: it takes a text, and refuses with 409 `knowledge_key` a text
    /// that adds a key-like part (`KeyInText.all` of the saved form, as a set, as the hub reads it) that the file's
    /// text did not hold and whose SHA-256 its
    /// `key_kept` does not name. `refusing` refuses every text with a key-like part, as a hub whose rule read another
    /// part than the Mac's.
    final class KeyCheckingHub: @unchecked Sendable {
        private let lock = NSLock()
        private var text: String
        private let client: String, refusing: Bool, pause: Double

        /// `pause`: the seconds that each answer waits, as a slow hub's.
        init(text: String, client: String, refusing: Bool = false, pause: Double = 0) {
            self.text = text; self.client = client; self.refusing = refusing; self.pause = pause
        }

        /// The file's text that this hub has now.
        var current: String { lock.withLock { text } }

        func answer(_ request: LoopbackHub.Request) -> (status: Int, body: Data) {
            if pause > 0 { Thread.sleep(forTimeInterval: pause) }
            let sent = (try? JSONSerialization.jsonObject(with: Data(request.body.utf8))) as? [String: Any] ?? [:]
            let new = sent["text"] as? String ?? "", kept = Set(sent["key_kept"] as? [String] ?? [])
            let refused = lock.withLock {
                let held = Set(KeyInText.all(in: KeyInText.savedForm(text)).map(String.init))
                let parts = KeyInText.all(in: KeyInText.savedForm(new)).map(String.init)
                let added = parts.filter { !held.contains($0) }
                let refuse = refusing
                    ? !parts.isEmpty : added.contains { !kept.contains(KnowledgeKeyHoldTests.sha($0)) }
                if !refuse { text = new }
                return refuse
            }
            guard refused else { return KnowledgeKeyHoldTests.receipt(request, client: client) }
            let words: [String: Any] = ["error": "This holds what looks like a key.", "code": "knowledge_key"]
            return (409, (try? JSONSerialization.data(withJSONObject: words)) ?? Data())
        }
    }

    struct Held: Sendable {
        var boxShown = false, askedOnWords = false, bannerShown = false, fileWords = false, endedWithoutKey = false
        var heldOnDone = false, boxStayed = false, heldOnBlur = false, savesWhileHeld = -1
        var leftWithoutBox = false, givenBack = false, askedAgain = false, savesAfterReturn = -1, savesAfterKeep = -1
        var savesOnRetry = -1, askedOnRetry = true, namedNoPart = false, askedForSecond = false, savesAfterSecond = -1
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
                // this hub takes no edit, and lists no key check: Try again sends the kept words with no second
                // question, and neither save names a kept part (a hub before the check refuses the field). The page
                // that came back has a box of its own.
                guard let again = Self.box(in: window) else { return seen }
                Self.fresh(store)
                Self.cursorLeaves(again, in: window)
                ViewHost.turn(10) { Self.saves(hub) > 1 }
                ViewHost.turn(1)
                seen.savesOnRetry = Self.saves(hub)
                seen.askedOnRetry = store.heldKey != nil
                seen.namedNoPart = Self.posts(hub).allSatisfy { $0["key_kept"] == nil }
                // a second key that comes whole, as a menu paste or a drop brings it: "Keep it" was not for it
                Self.type(words + " And another: " + Self.secondKey, into: again)
                seen.askedForSecond = ViewHost.turn(10) { store.heldKey?.hold == .text }
                Self.fresh(store)
                Self.cursorLeaves(again, in: window)
                ViewHost.turn(2)
                seen.savesAfterSecond = Self.saves(hub)
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
        #expect(seen.savesOnRetry == 2, "a save of the kept words after the hub failed goes again")
        #expect(!seen.askedOnRetry, "with no second question")
        #expect(seen.namedNoPart, "a hub that lists no key check gets no key_kept")
        #expect(seen.askedForSecond, "a second key asks again: Keep it kept only the parts that he saw")
        #expect(seen.savesAfterSecond == 2, "and its words wait")
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

    struct Landed: Sendable {
        var boxShown = false, sent = false, left = false, landed = false, givenBack = false, askedAgain = false
        var saves = -1
    }

    /// **His held text comes back after the save that was on its way when he left** (the coordinator's S1, 24 November
    /// 2026): the cursor left the box and its save went, he added a key and left the page, and the save landed after.
    /// His held text began from the text that the save replaced, so the file dropped his whole edit on its return, as a
    /// text that the hub had changed. The hub here holds the save until he has left.
    @Test func aHeldTextComesBackAfterTheSaveThatWasOnItsWayWhenHeLeft() async throws {
        let first = "The launch is on Tuesday.", words = "The launch is on Tuesday. Use this key: " + Self.keyText
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 100) { () -> Landed in
            try Self.withBox("The launch is on Monday.") { hub, store, window, box in
                var seen = Landed()
                guard let box else { return seen }
                seen.boxShown = true
                let release = DispatchSemaphore(value: 0), client = store.installation
                let landed = try Self.file(first, database: store.state?.db ?? "")
                hub.answer("POST", "/ui/knowledge") { [weak hub] request in
                    _ = release.wait(timeout: .now() + 30)
                    hub?.give(landed, at: "/ui/knowledge")
                    return Self.receipt(request, client: client)
                }
                Self.type(first, into: box)
                Self.fresh(store)
                Self.cursorLeaves(box, in: window)
                seen.sent = ViewHost.turn(10) { Self.saves(hub) == 1 }
                // he adds a key and leaves the page while that save is on its way
                Self.type(words, into: box)
                ViewHost.turn(1)
                store.show(.needs)
                seen.left = ViewHost.turn(10) { Self.box(in: window) == nil }
                ViewHost.turn(1)
                release.signal()
                seen.landed = ViewHost.turn(10) {
                    (store.reading("knowledge.file.fleet") as KnowledgeFile?)?.text.hasSuffix(first) == true
                }
                Self.open(store)
                seen.givenBack = ViewHost.turn(20) { Self.box(in: window)?.string == words }
                seen.askedAgain = ViewHost.turn(10) { Self.element("key-hold", in: window) != nil }
                seen.saves = Self.saves(hub)
                return seen
            }
        }
        #expect(seen.boxShown, "the pencil opens the file's text in the box")
        #expect(seen.sent, "the cursor that left the box sent his first words")
        #expect(seen.left, "the page went away with his words and the key")
        #expect(seen.landed, "the first save landed after he left")
        #expect(seen.givenBack, "his words with the key come back on the text that his own save made")
        #expect(seen.askedAgain, "with the question")
        #expect(seen.saves == 1, "and only the first words went")
        #expect(screen.stayedHis)
    }

    struct Named: Sendable {
        var boxShown = false, asked = false, kept: [[String]?] = [], problem = true
    }

    /// **A gate that the box's reads wait at** (`KnowledgePage.readPause`), on their own thread, until the test opens it.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false

        func open() { lock.withLock { isOpen = true } }

        func wait() {
            let end = Date().addingTimeInterval(20)
            while !lock.withLock({ isOpen }), Date() < end { Thread.sleep(forTimeInterval: 0.01) }
        }
    }

    /// **His held text comes back also when the earlier save lands while the words of his leave are read** (round 2 of
    /// 24 November 2026): the leave held his words on the text that the box had when he left, the save that was on its
    /// way landed before that hold, and the file dropped his whole edit on his return as a text that the hub had
    /// changed. The reads of his words wait at a gate here, so the save lands between his leave and its read.
    @Test func aHeldTextComesBackWhenTheEarlierSaveLandsDuringTheLeavesRead() async throws {
        let first = "The launch is on Tuesday.", words = "The launch is on Tuesday. Use this key: " + Self.keyText
        let gate = Gate()
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 100) { () -> Landed in
            defer { gate.open(); KnowledgePage.readPause = nil }
            return try Self.withBox("The launch is on Monday.") { hub, store, window, box in
                var seen = Landed()
                guard let box else { return seen }
                seen.boxShown = true
                let release = DispatchSemaphore(value: 0), client = store.installation
                let landed = try Self.file(first, database: store.state?.db ?? "")
                hub.answer("POST", "/ui/knowledge") { [weak hub] request in
                    _ = release.wait(timeout: .now() + 30)
                    hub?.give(landed, at: "/ui/knowledge")
                    return Self.receipt(request, client: client)
                }
                Self.type(first, into: box)
                Self.fresh(store)
                Self.cursorLeaves(box, in: window)
                seen.sent = ViewHost.turn(10) { Self.saves(hub) == 1 }
                // from here each read of his words waits at the gate: he adds a key and leaves before any read ends
                KnowledgePage.readPause = { gate.wait() }
                Self.type(words, into: box)
                store.show(.needs)
                seen.left = ViewHost.turn(10) { Self.box(in: window) == nil }
                // the first save lands while the read of his leave waits; then the read goes on
                release.signal()
                seen.landed = ViewHost.turn(10) {
                    (store.reading("knowledge.file.fleet") as KnowledgeFile?)?.text.hasSuffix(first) == true
                }
                gate.open()
                ViewHost.turn(1)
                KnowledgePage.readPause = nil
                Self.open(store)
                seen.givenBack = ViewHost.turn(20) { Self.box(in: window)?.string == words }
                seen.askedAgain = ViewHost.turn(10) { Self.element("key-hold", in: window) != nil }
                seen.saves = Self.saves(hub)
                return seen
            }
        }
        #expect(seen.boxShown, "the pencil opens the file's text in the box")
        #expect(seen.sent, "the cursor that left the box sent his first words")
        #expect(seen.left, "the page went away with his words and the key")
        #expect(seen.landed, "the first save landed while his leave's words were read")
        #expect(seen.givenBack, "his words with the key come back on the text that his own save made")
        #expect(seen.askedAgain, "with the question")
        #expect(seen.saves == 1, "and only the first words went")
        #expect(screen.stayedHis)
    }

    struct Removed: Sendable {
        var boxShown = false, asked = false, problem = true, kept: [[String]?] = []
    }

    /// **A save that the hub refuses reads the file again, and asks about what is new against it** (round 2 of 24
    /// November 2026): another hand (a second Mac, the manager's team plan) took a look-alike out of the file at the hub,
    /// which his box still holds. The box compared with the text that it had read, so it asked nothing, the hub
    /// refused each save for the look-alike, and his words were lost when he left. Now the strip asks about it, and
    /// "Keep it" names it to the hub, which takes the save.
    @Test func aRefusedSaveReadsTheFileAgainAndAsksAboutWhatIsNewInIt() async throws {
        let old = "The plan. Its id: " + Self.lookAlike
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 100) { () -> Removed in
            try Self.withBox(old, keyCheck: true) { hub, store, window, box in
                var seen = Removed()
                guard let box else { return seen }
                seen.boxShown = true
                // another hand takes the id out of the file at the hub
                let check = KeyCheckingHub(text: "The plan.", client: store.installation)
                hub.answer("POST", "/ui/knowledge") { check.answer($0) }
                hub.give(try Self.file("The plan.", database: store.state?.db ?? ""), at: "/ui/knowledge")
                Self.type("The plan for Monday. Its id: " + Self.lookAlike, into: box)
                Self.fresh(store)
                Self.cursorLeaves(box, in: window)
                ViewHost.turn(10) { Self.saves(hub) > 0 }
                seen.asked = ViewHost.turn(10) { store.heldKey?.hold == .text }
                seen.problem = Self.element("knowledge-problem", in: window) != nil
                // he keeps it: the save names it, and the hub takes it
                Self.fresh(store)
                Self.press("key-hold-go-on", in: window)
                ViewHost.turn(10) { Self.saves(hub) > 1 }
                ViewHost.turn(1)
                seen.kept = Self.posts(hub).map { $0["key_kept"] as? [String] }
                return seen
            }
        }
        #expect(seen.boxShown, "the pencil opens the file's text in the box")
        #expect(seen.asked, "the refused save reads the file again: the look-alike is new against it, and asks")
        #expect(!seen.problem, "the strip says it, the line under the box says it no second time")
        #expect(seen.kept == [[], [Self.sha(Self.lookAlike)]], "the kept save names the look-alike, and the hub takes it")
        #expect(screen.stayedHis)
    }

    struct Closed: Sendable {
        var boxShown = false, pasteHeld = false, pastedAtCursor = false, askedAfterPaste = true, closed = false
        var back = false, askedAgain = false, boxText = ""
    }

    /// **"Paste it anyway" pastes what the guard checked, at the box's own cursor, and a kept save that the hub refuses
    /// after the check mark closed the box comes back** (round 2 of 24 November 2026). It pasted the clipboard of the
    /// moment of his press, into whichever field had the cursor after a read; and a refusal of a save whose box had
    /// closed lost his words. The clipboard changes here between Cmd+V and his press, and the hub refuses the kept
    /// save a moment after the box closed: his words come back in the box, with the question.
    @Test func aPasteGoesWhereHeChoseAndARefusedSaveOfAClosedBoxComesBack() async throws {
        // a key copied with the space before it: one that joined "launch" ("launchsk_test_…") is no key at all, and
        // no hub refuses it
        let start = "The launch is on Monday.", copied = " " + Self.keyText
        let pasted = "The launch " + Self.keyText + " is on Monday."
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 100) { () -> Closed in
            let board = NSPasteboard.withUniqueName()
            KeyCut.board = board
            defer { KeyCut.board = .general; board.releaseGlobally() }
            return try Self.withBox(start, keyCheck: true) { hub, store, window, box in
                var seen = Closed()
                guard let box else { return seen }
                seen.boxShown = true
                let check = KeyCheckingHub(text: start, client: store.installation, refusing: true, pause: 0.5)
                hub.answer("POST", "/ui/knowledge") { check.answer($0) }
                board.clearContents()
                board.setString(copied, forType: .string)
                window.makeFirstResponder(box)
                ViewHost.turn(1)
                box.setSelectedRange(NSRange(location: 10, length: 0))      // after "The launch"
                Self.commandV(in: window)
                seen.pasteHeld = ViewHost.turn(10) { store.heldKey?.hold == .paste }
                // the clipboard changes before his press
                board.clearContents()
                board.setString(Self.secondKey, forType: .string)
                Self.press("key-hold-go-on", in: window)
                seen.pastedAtCursor = ViewHost.turn(10) { box.string == pasted }
                seen.boxText = box.string
                ViewHost.turn(1)
                seen.askedAfterPaste = store.heldKey != nil
                // the check mark closes the box at once; the hub refuses the kept save a moment later
                Self.fresh(store)
                Self.press("knowledge-done", in: window)
                seen.closed = ViewHost.turn(10) { Self.box(in: window) == nil }
                seen.back = ViewHost.turn(20) { Self.box(in: window)?.string == pasted }
                seen.askedAgain = ViewHost.turn(10) { store.heldKey?.hold == .text }
                return seen
            }
        }
        #expect(seen.boxShown, "the pencil opens the file's text in the box")
        #expect(seen.pasteHeld, "Cmd+V of a key asks first")
        #expect(seen.pastedAtCursor, "Paste it anyway puts the key that the guard checked at the box's cursor: \(seen.boxText)")
        #expect(!seen.askedAfterPaste, "and asks no second time")
        #expect(seen.closed, "the check mark closed the box")
        #expect(seen.back, "the hub's refusal of the kept save gives his words back in the box")
        #expect(seen.askedAgain, "with the question")
        #expect(screen.stayedHis)
    }

    struct OtherField: Sendable {
        var boxShown = false, pasteHeld = false, boxSame = false, fieldSame = false, keySent = true, boxText = ""
    }

    /// **"Paste it anyway" puts nothing anywhere when the text view that had the cursor at Cmd+V is not the box's** (a
    /// reader's finding of 26 November 2026): a field took the cursor just before Cmd+V, while the box's guard still
    /// watched, and the paste wrote that field's text, with the key, over the box's words, which the next save would
    /// write over his file. Now neither the box nor the field changes, and no save carries the key.
    @Test func aPasteWhoseCursorWasInAnotherFieldChangesNothing() async throws {
        let start = "The launch is on Monday.", note = "A note."
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 100) { () -> OtherField in
            let board = NSPasteboard.withUniqueName()
            KeyCut.board = board
            defer { KeyCut.board = .general; board.releaseGlobally() }
            return try Self.withBox(start, keyCheck: true) { hub, store, window, box in
                var seen = OtherField()
                guard let box else { return seen }
                seen.boxShown = true
                let check = KeyCheckingHub(text: start, client: store.installation)
                hub.answer("POST", "/ui/knowledge") { check.answer($0) }
                board.clearContents()
                board.setString(" " + Self.keyText, forType: .string)
                window.makeFirstResponder(box)
                ViewHost.turn(1)
                // another field takes the cursor, and Cmd+V comes before the page turns (a busy Mac); the test reads
                // the box by its own view from here on, as `box(in:)` would find the field first
                let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 40))
                field.string = note
                window.contentView?.addSubview(field)
                defer { field.removeFromSuperview() }
                window.makeFirstResponder(field)
                Self.commandV(in: window)
                seen.pasteHeld = ViewHost.turn(10) { store.heldKey?.hold == .paste }
                Self.press("key-hold-go-on", in: window)
                ViewHost.turn(2)
                seen.boxText = box.string
                seen.boxSame = box.string == start
                seen.fieldSame = field.string == note
                seen.keySent = Self.posts(hub).contains { ($0["text"] as? String)?.contains(Self.keyText) == true }
                return seen
            }
        }
        #expect(seen.boxShown, "the pencil opens the file's text in the box")
        #expect(seen.pasteHeld, "Cmd+V of a key asks first, as the box's guard still watched")
        #expect(seen.boxSame, "the box keeps his words: \(seen.boxText)")
        #expect(seen.fieldSame, "and the other field gets nothing")
        #expect(!seen.keySent, "and no save carries the key")
        #expect(screen.stayedHis)
    }

    struct Covered: Sendable {
        var asked = false, askedAgain = false, savesAfterFirst = -1, kept: [[String]?] = []
    }

    /// **"Keep it" keeps only what the strip asked about** (round 2 of 24 November 2026): it kept every part that the
    /// words held at his press, so a second key that came in whole while the strip stood (a menu paste, a drop) went
    /// with the first, unseen; and a save that read the words while the strip stood made the strip's parts the new
    /// ones (round 3). Now that key asks again, in the same strip, and the save that goes names both.
    @Test func keepItKeepsOnlyWhatTheStripAskedAbout() async throws {
        let start = "The launch is on Monday."
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 100) { () -> Covered in
            try Self.withBox(start, keyCheck: true) { hub, store, window, box in
                var seen = Covered()
                guard let box else { return seen }
                let check = KeyCheckingHub(text: start, client: store.installation)
                hub.answer("POST", "/ui/knowledge") { check.answer($0) }
                Self.type("The launch is on Monday. Use this key: " + Self.keyText, into: box)
                seen.asked = ViewHost.turn(10) { store.heldKey?.hold == .text }
                // a second key comes in whole while the strip stands, and a save reads it (the cursor leaves the box)
                Self.type("The launch is on Monday. Use this key: \(Self.keyText) And: \(Self.secondKey)", into: box)
                ViewHost.turn(1)
                Self.fresh(store)
                Self.cursorLeaves(box, in: window)
                ViewHost.turn(1)
                Self.fresh(store)
                Self.press("key-hold-go-on", in: window)
                seen.askedAgain = ViewHost.turn(10) { store.heldKey?.hold == .text }
                ViewHost.turn(1)
                seen.savesAfterFirst = Self.saves(hub)
                // he keeps that one too
                Self.fresh(store)
                Self.press("key-hold-go-on", in: window)
                ViewHost.turn(10) { Self.saves(hub) > 0 }
                ViewHost.turn(1)
                seen.kept = Self.posts(hub).map { $0["key_kept"] as? [String] }
                return seen
            }
        }
        #expect(seen.asked, "the first key asks")
        #expect(seen.askedAgain, "the key that came in while the strip stood asks again")
        #expect(seen.savesAfterFirst == 0, "and nothing went meanwhile")
        #expect(seen.kept == [[Self.sha(Self.keyText), Self.sha(Self.secondKey)].sorted()], "the save names both")
        #expect(screen.stayedHis)
    }

    struct Waited: Sendable {
        var boxShown = false, closed = false, openedEarly = true, landed = false, opened = false
    }

    /// **The pencil waits for a save of its file that is on its way** (round 3 of 25 November 2026). The check mark
    /// closed the box at once, and the pencil (a second click) opened it again on the text from before the save; when
    /// the save landed, the box took his new text as the hub's while it showed the old one, and the next save put the
    /// old text over his edit; a refusal of that save found the old text in the box and held his words nowhere.
    @Test func thePencilWaitsForASaveOfItsFileOnItsWay() async throws {
        let first = "The launch is on Tuesday."
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 100) { () -> Waited in
            try Self.withBox("The launch is on Monday.") { hub, store, window, box in
                var seen = Waited()
                guard let box else { return seen }
                seen.boxShown = true
                let release = DispatchSemaphore(value: 0), client = store.installation
                let landed = try Self.file(first, database: store.state?.db ?? "")
                hub.answer("POST", "/ui/knowledge") { [weak hub] request in
                    _ = release.wait(timeout: .now() + 30)
                    hub?.give(landed, at: "/ui/knowledge")
                    return Self.receipt(request, client: client)
                }
                Self.type(first, into: box)
                ViewHost.turn(1)
                Self.fresh(store)
                Self.press("knowledge-done", in: window)
                seen.closed = ViewHost.turn(10) { Self.box(in: window) == nil && Self.saves(hub) == 1 }
                // the pencil, while the save is on its way: the box stays closed
                Self.press("knowledge-edit", in: window)
                seen.openedEarly = ViewHost.turn(1) { Self.box(in: window) != nil }
                release.signal()
                seen.landed = ViewHost.turn(10) {
                    (store.reading("knowledge.file.fleet") as KnowledgeFile?)?.text.hasSuffix(first) == true
                }
                // the pencil again, once the save has ended
                for _ in 0..<20 where Self.box(in: window) == nil {
                    Self.fresh(store)
                    Self.press("knowledge-edit", in: window)
                    ViewHost.turn(0.5) { Self.box(in: window) != nil }
                }
                seen.opened = Self.box(in: window)?.string == first
                return seen
            }
        }
        #expect(seen.boxShown, "the pencil opens the file's text in the box")
        #expect(seen.closed, "the check mark closed the box, and its save went")
        #expect(!seen.openedEarly, "the pencil does not open the box while the save is on its way")
        #expect(seen.landed, "the save landed")
        #expect(seen.opened, "then the pencil opens the box on the saved text")
        #expect(screen.stayedHis)
    }

    /// A read that fails, or not: a switch that the test throws, and the hub's thread reads.
    final class Failing: @unchecked Sendable {
        private let lock = NSLock()
        private var on = true
        var isOn: Bool { lock.withLock { on } }
        func off() { lock.withLock { on = false } }
    }

    struct Unread: Sendable {
        var boxShown = false, pasted = false, closed = false, left = false, refused = false, back = false, asked = false
    }

    /// **A refused save whose file cannot be read again comes back on the file's text** (round 3 of 25 November
    /// 2026): his words waited on the text from before the save, and the file, which another hand had changed at the
    /// hub, dropped them on his return as words on an older text. Here he keeps a pasted key, closes the box and
    /// leaves; the hub refuses the save, and its file cannot be read for a moment.
    @Test func aRefusedSaveWhoseFileCannotBeReadComesBackOnTheFilesText() async throws {
        let start = "The launch is on Monday.", other = "The launch is on Friday."
        // a key copied with the space before it (one that joined "launch" is no key)
        let copied = " " + Self.keyText, pasted = "The launch " + Self.keyText + " is on Monday."
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 100) { () -> Unread in
            let board = NSPasteboard.withUniqueName()
            KeyCut.board = board
            defer { KeyCut.board = .general; board.releaseGlobally() }
            return try Self.withBox(start, keyCheck: true) { hub, store, window, box in
                var seen = Unread()
                guard let box else { return seen }
                seen.boxShown = true
                // another hand changed the file at the hub; for a moment, a read of it fails
                let check = KeyCheckingHub(text: other, client: store.installation, refusing: true, pause: 0.5)
                hub.answer("POST", "/ui/knowledge") { check.answer($0) }
                let failing = Failing(), changed = try Self.file(other, database: store.state?.db ?? "")
                hub.answer("GET", "/ui/knowledge") { _ in
                    failing.isOn ? (503, Data(#"{"error":"busy"}"#.utf8)) : (200, changed)
                }
                board.clearContents()
                board.setString(copied, forType: .string)
                window.makeFirstResponder(box)
                ViewHost.turn(1)
                box.setSelectedRange(NSRange(location: 10, length: 0))
                Self.commandV(in: window)
                ViewHost.turn(10) { store.heldKey?.hold == .paste }
                Self.press("key-hold-go-on", in: window)
                seen.pasted = ViewHost.turn(10) { box.string == pasted }
                ViewHost.turn(1)
                Self.fresh(store)
                Self.press("knowledge-done", in: window)
                seen.closed = ViewHost.turn(10) { Self.box(in: window) == nil }
                let reads = { hub.requests.filter { $0.method == "GET" && $0.path == "/ui/knowledge" }.count }
                let before = reads()
                store.show(.needs)
                seen.left = ViewHost.turn(10) { Self.saves(hub) == 1 }
                // the refusal comes after the hub's pause, and the file is read again, which fails
                seen.refused = ViewHost.turn(10) { reads() > before }
                ViewHost.turn(1)
                failing.off()
                Self.open(store)
                seen.back = ViewHost.turn(20) { Self.box(in: window)?.string == pasted }
                seen.asked = ViewHost.turn(10) { store.heldKey?.hold == .text }
                return seen
            }
        }
        #expect(seen.boxShown, "the pencil opens the file's text in the box")
        #expect(seen.pasted, "his paste of the key")
        #expect(seen.closed, "the check mark closed the box")
        #expect(seen.left, "and its save went as he left")
        #expect(seen.refused, "the hub refused it, and the file was read again")
        #expect(seen.back, "his words come back on the file's text of his return")
        #expect(seen.asked, "with the question")
        #expect(screen.stayedHis)
    }

    struct Newer: Sendable {
        var boxShown = false, asked = false, sent = false, askedForSecond = false, left = false, refused = false
        var back = false, askedAgain = false
    }

    /// **A refused save never replaces his newer held words** (round 3 of 25 November 2026, reader 1): a kept save was
    /// on its way, he added a second key and left, so his newer words waited in memory; then the hub refused the kept
    /// save, and its older words took their place. He came back to the older words, and his second edit was gone.
    /// And when another hand had changed the file at the hub, the newer words stayed on the text from before, and the
    /// file dropped them on his return (round 4).
    @Test func aRefusedSaveKeepsTheNewerWordsThatWaitForTheFile() async throws {
        let start = "The launch is on Monday.", older = "The launch is on Monday. Use this key: " + Self.keyText
        let newer = older + " And: " + Self.secondKey, other = "The launch is on Friday."
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 100) { () -> Newer in
            try Self.withBox(start, keyCheck: true) { hub, store, window, box in
                var seen = Newer()
                guard let box else { return seen }
                seen.boxShown = true
                // another hand changed the file at the hub meanwhile
                let check = KeyCheckingHub(text: other, client: store.installation, refusing: true, pause: 3)
                hub.answer("POST", "/ui/knowledge") { check.answer($0) }
                hub.give(try Self.file(other, database: store.state?.db ?? ""), at: "/ui/knowledge")
                Self.type(older, into: box)
                seen.asked = ViewHost.turn(10) { store.heldKey?.hold == .text }
                Self.fresh(store)
                Self.press("key-hold-go-on", in: window)
                seen.sent = ViewHost.turn(10) { Self.saves(hub) == 1 }
                // while the kept save is on its way, he adds a second key, and leaves
                Self.type(newer, into: box)
                seen.askedForSecond = ViewHost.turn(10) { store.heldKey?.hold == .text }
                store.show(.needs)
                seen.left = ViewHost.turn(10) { Self.box(in: window) == nil }
                let reads = { hub.requests.filter { $0.method == "GET" && $0.path == "/ui/knowledge" }.count }
                let before = reads()
                // the hub refuses the kept save, and the file is read again
                seen.refused = ViewHost.turn(10) { reads() > before }
                ViewHost.turn(1)
                Self.open(store)
                seen.back = ViewHost.turn(20) { Self.box(in: window)?.string == newer }
                seen.askedAgain = ViewHost.turn(10) { store.heldKey?.hold == .text }
                return seen
            }
        }
        #expect(seen.boxShown, "the pencil opens the file's text in the box")
        #expect(seen.asked, "the first key asks, and he keeps it")
        #expect(seen.sent, "the kept save goes")
        #expect(seen.askedForSecond, "a second key asks while it is on its way")
        #expect(seen.left, "he leaves with it")
        #expect(seen.refused, "the hub refuses the kept save")
        #expect(seen.back, "his newer words come back on the file's new text, not the refused older ones")
        #expect(seen.askedAgain, "with the question")
        #expect(screen.stayedHis)
    }

    struct Typed: Sendable {
        var boxShown = false, asked = false, sent = false, typedOn = false, refused = false, askedAgain = false
        var problem = true, saved = false, left = false, heldNothing = false
    }

    /// **A refused save checks the words that the box holds now, and holds nothing** (round 4 of 25 November 2026): a
    /// kept save went, and he typed on. The hub refused it, and the refused older words were held in memory, while the
    /// box's newer words were not checked against the file's text read again, and the refusal's line stayed under them.
    /// When that read failed, the older words later came back over his newer saved text.
    @Test func aRefusedSaveChecksTheBoxsNewerWordsAndHoldsNothing() async throws {
        let start = "The launch is on Monday.", older = "The launch is on Monday. Use this key: " + Self.keyText
        let typed = older + " More words.", plain = "The launch is on Monday. More words."
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 100) { () -> Typed in
            try Self.withBox(start, keyCheck: true) { hub, store, window, box in
                var seen = Typed()
                guard let box else { return seen }
                seen.boxShown = true
                let check = KeyCheckingHub(text: start, client: store.installation, refusing: true, pause: 2)
                hub.answer("POST", "/ui/knowledge") { check.answer($0) }
                // a read of the file fails for a moment; then it gives the hub's text
                let failing = Failing(), db = store.state?.db ?? ""
                hub.answer("GET", "/ui/knowledge") { _ in
                    let text = (try? Self.file(check.current, database: db)) ?? Data()
                    return failing.isOn ? (503, Data(#"{"error":"busy"}"#.utf8)) : (200, text)
                }
                Self.type(older, into: box)
                seen.asked = ViewHost.turn(10) { store.heldKey?.hold == .text }
                Self.fresh(store)
                Self.press("key-hold-go-on", in: window)
                seen.sent = ViewHost.turn(10) { Self.saves(hub) == 1 }
                // he types on while the kept save is on its way
                Self.type(typed, into: box)
                ViewHost.turn(0.5)
                seen.typedOn = box.string == typed
                let reads = { hub.requests.filter { $0.method == "GET" && $0.path == "/ui/knowledge" }.count }
                let before = reads()
                seen.refused = ViewHost.turn(10) { reads() > before }
                seen.askedAgain = ViewHost.turn(10) { store.heldKey?.hold == .text }
                ViewHost.turn(1)
                seen.problem = Self.element("knowledge-problem", in: window) != nil
                failing.off()
                // he takes the key out, and that text is saved
                Self.type(plain, into: box)
                ViewHost.turn(1)
                Self.fresh(store)
                Self.cursorLeaves(box, in: window)
                seen.saved = ViewHost.turn(10) { check.current == plain }
                ViewHost.turn(1)
                store.show(.needs)
                seen.left = ViewHost.turn(10) { Self.box(in: window) == nil }
                Self.open(store)
                ViewHost.turn(10) {
                    (store.reading("knowledge.file.fleet") as KnowledgeFile?)?.text.hasSuffix(plain) == true
                }
                seen.heldNothing = !ViewHost.turn(3) { Self.box(in: window) != nil }
                return seen
            }
        }
        #expect(seen.boxShown, "the pencil opens the file's text in the box")
        #expect(seen.asked, "the key asks, and he keeps it")
        #expect(seen.sent, "the kept save goes")
        #expect(seen.typedOn, "he types on while it is on its way")
        #expect(seen.refused, "the hub refuses it, and the read of the file fails")
        #expect(seen.askedAgain, "the box's words ask again")
        #expect(!seen.problem, "with no refusal's line under them")
        #expect(seen.saved, "his text with no key is saved")
        #expect(seen.left, "he leaves")
        #expect(seen.heldNothing, "and no older refused words come back over it")
        #expect(screen.stayedHis)
    }

    struct Gained: Sendable {
        var boxShown = false, gained = false, kept: [String]?
    }

    /// **A hub that takes the key check while the box is open gets `key_kept`** (round 4 of 25 November 2026): the box
    /// kept the key check of the moment that it opened, so a hub that turned it on meanwhile read the new app as an
    /// older one and checked nothing.
    @Test func aHubThatTakesTheKeyCheckWhileTheBoxIsOpenGetsKeyKept() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 100) { () -> Gained in
            try Self.withBox("The launch is on Monday.") { hub, store, window, box in
                var seen = Gained()
                guard let box else { return seen }
                seen.boxShown = true
                let client = store.installation
                hub.answer("POST", "/ui/knowledge") { Self.receipt($0, client: client) }
                // the hub, in the same generation, takes the key check
                hub.give(try Self.reading([KnowledgeClient.keyFeature], db: store.state?.db))
                Self.fresh(store)
                seen.gained = ViewHost.turn(10) { store.state?.checksKnowledgeKeys == true }
                Self.type("The launch is on Tuesday.", into: box)
                ViewHost.turn(1)
                Self.fresh(store)
                Self.cursorLeaves(box, in: window)
                ViewHost.turn(10) { Self.saves(hub) > 0 }
                seen.kept = Self.posts(hub).first?["key_kept"] as? [String]
                return seen
            }
        }
        #expect(seen.boxShown, "the pencil opens the file's text in the box")
        #expect(seen.gained, "the hub took the key check while the box was open")
        #expect(seen.kept == [], "and the box's save says key_kept to it")
        #expect(screen.stayedHis)
    }

    struct Later: Sendable {
        var boxShown = false, asked = false, refused = false, closed = false, landed = false, stayedClosed = false
    }

    /// **A refused save gives nothing back while a later save of the file carries his newer words** (round 5 of 25
    /// November 2026): while the file was read again after a refusal, he took the key out and closed the box; the
    /// refusal then found no box, held the older words with the key and gave them back at once, so the box showed them
    /// while his newer save landed under them, and "Keep it" would have put them over it.
    @Test func aRefusedSaveGivesNothingBackWhileALaterSaveCarriesHisNewerWords() async throws {
        let start = "The launch is on Monday.", older = "The launch is on Monday. Use this key: " + Self.keyText
        let plain = "The launch is on Tuesday."
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 100) { () -> Later in
            try Self.withBox(start, keyCheck: true) { hub, store, window, box in
                var seen = Later()
                guard let box else { return seen }
                seen.boxShown = true
                let check = KeyCheckingHub(text: start, client: store.installation, refusing: true)
                hub.answer("POST", "/ui/knowledge") { check.answer($0) }
                // the next read of the file, the one after the refusal, takes 2 seconds
                let slow = Failing(), db = store.state?.db ?? ""
                hub.answer("GET", "/ui/knowledge") { _ in
                    if slow.isOn { slow.off(); Thread.sleep(forTimeInterval: 2) }
                    return (200, (try? Self.file(check.current, database: db)) ?? Data())
                }
                Self.type(older, into: box)
                seen.asked = ViewHost.turn(10) { store.heldKey?.hold == .text }
                Self.fresh(store)
                Self.press("key-hold-go-on", in: window)
                seen.refused = ViewHost.turn(10) { Self.saves(hub) == 1 }
                // during that read, he takes the key out and closes the box
                Self.type(plain, into: box)
                ViewHost.turn(0.5)
                Self.fresh(store)
                Self.press("knowledge-done", in: window)
                seen.closed = ViewHost.turn(10) { Self.box(in: window) == nil }
                seen.landed = ViewHost.turn(15) { check.current == plain }
                ViewHost.turn(1)
                seen.stayedClosed = !ViewHost.turn(3) { Self.box(in: window) != nil }
                return seen
            }
        }
        #expect(seen.boxShown, "the pencil opens the file's text in the box")
        #expect(seen.asked, "the key asks, and he keeps it")
        #expect(seen.refused, "the kept save goes, and the hub refuses it")
        #expect(seen.closed, "he closes the box with newer words while the file is read again")
        #expect(seen.landed, "his newer save lands")
        #expect(seen.stayedClosed, "and the refused older words do not come back over it")
        #expect(screen.stayedHis)
    }

    struct Read: Sendable {
        var boxShown = false, asked = false, left = false, openedEarly = true, back = false, askedAgain = false
    }

    /// **The pencil waits for the read that gives back his held words** (round 6 of 25 November 2026): the page shows
    /// the text that it read last at once, so the pencil opened the box on it before the file's read ended; the held
    /// words stayed in memory, and his next save dropped them. Here the read waits until the test lets it go.
    @Test func thePencilWaitsForTheReadThatGivesBackHisHeldWords() async throws {
        let start = "The launch is on Monday.", words = "The launch is on Monday. Use this key: " + Self.keyText
        let gate = Gate()
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 100) { () -> Read in
            defer { gate.open() }
            return try Self.withBox(start) { hub, store, window, box in
                var seen = Read()
                guard let box else { return seen }
                seen.boxShown = true
                Self.type(words, into: box)
                seen.asked = ViewHost.turn(10) { store.heldKey?.hold == .text }
                store.show(.needs)
                seen.left = ViewHost.turn(10) { Self.box(in: window) == nil }
                // the file's next read waits at the gate; each request has its own thread, so that read holds no other
                // (`holdRestores`: this test sends no restore)
                hub.holdRestores()
                let text = try Self.file(start, database: store.state?.db ?? "")
                hub.answer("GET", "/ui/knowledge") { _ in
                    gate.wait()
                    return (200, text)
                }
                Self.open(store)
                Self.fresh(store)
                Self.press("knowledge-edit", in: window)
                seen.openedEarly = ViewHost.turn(1) { Self.box(in: window) != nil }
                gate.open()
                seen.back = ViewHost.turn(10) { Self.box(in: window)?.string == words }
                seen.askedAgain = ViewHost.turn(10) { store.heldKey?.hold == .text }
                return seen
            }
        }
        #expect(seen.boxShown, "the pencil opens the file's text in the box")
        #expect(seen.asked, "the key asks")
        #expect(seen.left, "he leaves, and his words wait")
        #expect(!seen.openedEarly, "the pencil does not open the box on the text that the page read last")
        #expect(seen.back, "his words come back once the file's read ends")
        #expect(seen.askedAgain, "with the question")
        #expect(screen.stayedHis)
    }

    struct Again: Sendable {
        var boxShown = false, left = false, reread = false, back = false, askedAgain = false
    }

    /// **His held words come back when he opens the file again before their read ends** (round 7 of 25 November
    /// 2026): he left a file whose words a key held, and opened it again at once; the reader's read of the file ended
    /// before the read of his words, so it found nothing to give back, and the words waited unseen. Here the read of
    /// his words waits at a gate until the reader's read has ended. Back to the list keeps the page.
    @Test func heldWordsComeBackWhenHeOpensTheFileAgainBeforeTheirReadEnds() async throws {
        let start = "The launch is on Monday.", words = "The launch is on Monday. Use this key: " + Self.keyText
        let gate = Gate()
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 100) { () -> Again in
            defer { gate.open(); KnowledgePage.readPause = nil }
            return try Self.withBox(start) { hub, store, window, box in
                var seen = Again()
                guard let box else { return seen }
                seen.boxShown = true
                // from here each read of his words waits at the gate
                KnowledgePage.readPause = { gate.wait() }
                Self.type(words, into: box)
                let backLink = Self.find(in: window) {
                    Self.attribute("accessibilityLabel", of: $0) == "Back to Knowledge"
                }
                _ = backLink?.perform(NSSelectorFromString("accessibilityPerformPress"))
                seen.left = ViewHost.turn(10) { Self.box(in: window) == nil }
                // the file again at once: the reader's own read of the file ends first
                let reads = { hub.requests.filter { $0.method == "GET" && $0.path == "/ui/knowledge" }.count }
                let before = reads()
                Self.press("knowledge-" + Self.path, in: window)
                seen.reread = ViewHost.turn(10) { reads() > before }
                ViewHost.turn(1)
                gate.open()
                seen.back = ViewHost.turn(10) { Self.box(in: window)?.string == words }
                KnowledgePage.readPause = nil
                seen.askedAgain = ViewHost.turn(10) { store.heldKey?.hold == .text }
                return seen
            }
        }
        #expect(seen.boxShown, "the pencil opens the file's text in the box")
        #expect(seen.left, "Back to the list: his words with the key are held")
        #expect(seen.reread, "the file opens again, and its reader's read ends first")
        #expect(seen.back, "his words come back once their read ends")
        #expect(seen.askedAgain, "with the question")
        #expect(screen.stayedHis)
    }

    /// A made-up private key whose lines end in "\r\n", in two parts so that no scan of the repository takes it for a
    /// key.
    private static let returnKey = "-----BEGIN OPENSSH " + "PRIVATE KEY-----\r\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmU=\r\n"
        + "-----END OPENSSH " + "PRIVATE KEY-----"

    struct SavedForm: Sendable {
        var boxShown = false, twoCharacterEnds = false, asked = false, kept: [String]?, problem = true
    }

    /// **A kept key is named to the hub as the hub saves it** (round 8 of 25 November 2026): the hub reads a file in
    /// its saved form (`KeyInText.savedForm`: "\r\n" is "\n"), and the box read and named his raw words, so the kept
    /// part of a private key with such line ends was not the hub's, and the hub refused the kept save again and again.
    @Test func aKeptKeyWithTwoCharacterLineEndsIsNamedAsTheHubSavesIt() async throws {
        let start = "The launch is on Monday.", words = "The launch is on Monday.\r\nThe key:\r\n" + Self.returnKey
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 100) { () -> SavedForm in
            try Self.withBox(start, keyCheck: true) { hub, store, window, box in
                var seen = SavedForm()
                guard let box else { return seen }
                seen.boxShown = true
                let check = KeyCheckingHub(text: start, client: store.installation)
                hub.answer("POST", "/ui/knowledge") { check.answer($0) }
                Self.type(words, into: box)
                seen.twoCharacterEnds = box.string.contains("\r\n")
                seen.asked = ViewHost.turn(10) { store.heldKey?.hold == .text }
                Self.fresh(store)
                Self.press("key-hold-go-on", in: window)
                ViewHost.turn(10) { Self.saves(hub) > 0 }
                ViewHost.turn(1)
                seen.kept = Self.posts(hub).first?["key_kept"] as? [String]
                seen.problem = Self.element("knowledge-problem", in: window) != nil
                return seen
            }
        }
        #expect(seen.boxShown, "the pencil opens the file's text in the box")
        #expect(seen.twoCharacterEnds, "his words hold line ends of two characters")
        #expect(seen.asked, "the key asks, and he keeps it")
        #expect(seen.kept == [Self.sha(KeyInText.savedForm(Self.returnKey))],
                "the kept save names the key as the hub saves it")
        #expect(!seen.problem, "and the hub takes it")
        #expect(screen.stayedHis)
    }

    struct Apart: Sendable {
        var boxShown = false, control = false, asked = false, saves = -1
    }

    /// **A key that only the saved file sets apart asks before the save** (round 8 of 25 November 2026): U+001F before
    /// a run inside a web address joins the two in his words, where the run reads as the address's path, but the hub
    /// saves U+001F as a space and reads a key there. The box asked nothing, and the hub refused the save with no
    /// question.
    @Test func aKeyThatOnlyTheSavedFileSetsApartAsksBeforeTheSave() async throws {
        let start = "The launch is on Monday."
        let words = "The launch is on Monday. See https://example.com/files/\u{001F}" + Self.lookAlike
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 100) { () -> Apart in
            try Self.withBox(start) { hub, store, window, box in
                var seen = Apart()
                guard let box else { return seen }
                seen.boxShown = true
                Self.type(words, into: box)
                seen.control = box.string.contains("\u{001F}")
                seen.asked = ViewHost.turn(10) { store.heldKey?.hold == .text }
                Self.fresh(store)
                Self.cursorLeaves(box, in: window)
                ViewHost.turn(2)
                seen.saves = Self.saves(hub)
                return seen
            }
        }
        #expect(seen.boxShown, "the pencil opens the file's text in the box")
        #expect(seen.control, "his words hold U+001F")
        #expect(seen.asked, "the key that the saved file sets apart asks")
        #expect(seen.saves == 0, "and nothing goes before his choice")
        #expect(screen.stayedHis)
    }

    struct Ends: Sendable {
        var boxShown = false, twoCharacterEnds = false, saved = false, asked = false, left = false, back = false
        var askedAgain = false
    }

    /// **Held words come back after a save whose words had line ends of two characters** (round 9 of 25 November
    /// 2026): the hub keeps a file in its saved form ("\r\n" is "\n"), while the text that this Mac's save left was
    /// his own words; so at his return the two texts differed, and the file dropped his held words.
    @Test func heldWordsComeBackAfterASaveOfTwoCharacterLineEnds() async throws {
        let start = "The launch is on Monday.", first = "The launch is on Monday.\r\nThe team checks the orders."
        let words = first + " Use this key: " + Self.keyText
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 100) { () -> Ends in
            try Self.withBox(start) { hub, store, window, box in
                var seen = Ends()
                guard let box else { return seen }
                seen.boxShown = true
                // a hub that keeps the file in its saved form
                let check = KeyCheckingHub(text: start, client: store.installation), db = store.state?.db ?? ""
                hub.answer("POST", "/ui/knowledge") { check.answer($0) }
                hub.answer("GET", "/ui/knowledge") { _ in
                    (200, (try? Self.file(KeyInText.savedForm(check.current), database: db)) ?? Data())
                }
                Self.type(first, into: box)
                seen.twoCharacterEnds = box.string.contains("\r\n")
                ViewHost.turn(0.5)
                Self.fresh(store)
                Self.cursorLeaves(box, in: window)
                seen.saved = ViewHost.turn(10) {
                    (store.reading("knowledge.file.fleet") as KnowledgeFile?)?.text
                        .hasSuffix(KeyInText.savedForm(first)) == true
                }
                Self.type(words, into: box)
                seen.asked = ViewHost.turn(10) { store.heldKey?.hold == .text }
                store.show(.needs)
                seen.left = ViewHost.turn(10) { Self.box(in: window) == nil }
                Self.open(store)
                seen.back = ViewHost.turn(20) { Self.box(in: window)?.string == words }
                seen.askedAgain = ViewHost.turn(10) { store.heldKey?.hold == .text }
                return seen
            }
        }
        #expect(seen.boxShown, "the pencil opens the file's text in the box")
        #expect(seen.twoCharacterEnds, "his words hold line ends of two characters")
        #expect(seen.saved, "they are saved, and the hub keeps them in its saved form")
        #expect(seen.asked, "he adds a key, which asks")
        #expect(seen.left, "he leaves, and his words wait")
        #expect(seen.back, "they come back on the hub's saved text")
        #expect(seen.askedAgain, "with the question")
        #expect(screen.stayedHis)
    }

    struct Stripped: Sendable {
        var boxShown = false, control = false, saved = false, asked = false, left = false, back = false
        var askedAgain = false
    }

    /// **Held words come back after a save whose words ended in a control character** (round 10 of 25 November
    /// 2026): the hub strips the saved form, so U+0001 at the end of a saved text became a space and went, while the
    /// text that this Mac's save left kept it; at his return the two texts differed, and the file dropped his held
    /// words.
    @Test func heldWordsComeBackAfterASaveThatEndedInAControlCharacter() async throws {
        let start = "The launch is on Monday.", first = "The launch is on Monday. The team checks the orders.\u{0001}"
        let words = first + " Use this key: " + Self.keyText
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 100) { () -> Stripped in
            try Self.withBox(start) { hub, store, window, box in
                var seen = Stripped()
                guard let box else { return seen }
                seen.boxShown = true
                // a hub that keeps the file in its saved form, stripped
                let check = KeyCheckingHub(text: start, client: store.installation), db = store.state?.db ?? ""
                hub.answer("POST", "/ui/knowledge") { check.answer($0) }
                hub.answer("GET", "/ui/knowledge") { _ in
                    let kept = KeyInText.savedForm(check.current).trimmingCharacters(in: .whitespacesAndNewlines)
                    return (200, (try? Self.file(kept, database: db)) ?? Data())
                }
                Self.type(first, into: box)
                seen.control = box.string.unicodeScalars.contains("\u{0001}")
                ViewHost.turn(0.5)
                Self.fresh(store)
                Self.cursorLeaves(box, in: window)
                seen.saved = ViewHost.turn(10) {
                    let read = store.reading("knowledge.file.fleet") as KnowledgeFile?
                    return read?.text.hasSuffix("The team checks the orders.") == true
                }
                Self.type(words, into: box)
                seen.asked = ViewHost.turn(10) { store.heldKey?.hold == .text }
                store.show(.needs)
                seen.left = ViewHost.turn(10) { Self.box(in: window) == nil }
                Self.open(store)
                seen.back = ViewHost.turn(20) { Self.box(in: window)?.string == words }
                seen.askedAgain = ViewHost.turn(10) { store.heldKey?.hold == .text }
                return seen
            }
        }
        #expect(seen.boxShown, "the pencil opens the file's text in the box")
        #expect(seen.control, "his words end in U+0001")
        #expect(seen.saved, "they are saved, and the hub keeps them stripped")
        #expect(seen.asked, "he adds a key, which asks")
        #expect(seen.left, "he leaves, and his words wait")
        #expect(seen.back, "they come back on the hub's stripped text")
        #expect(seen.askedAgain, "with the question")
        #expect(screen.stayedHis)
    }

    struct Accent: Sendable {
        var boxShown = false, joined = false, asked = false, cut = false, formKey = false, text = ""
    }

    /// **"Save it as a secret" cuts the key's scalars, also when its last letter and a combining accent after it are
    /// one character** (the coordinator's S7, 25 November 2026): a cut by characters takes the accent with the key, out
    /// of his words and into the secret. The cut must leave the accent and the rest of his words in the box, and the
    /// secure form must get the key as the box held it.
    @Test func saveItAsASecretCutsTheKeysScalarsBeforeACombiningAccent() async throws {
        let start = "The launch is on Monday."
        let words = "The launch is on Monday. Use this key: " + Self.keyText + "\u{0301} and more words."
        let rest = "The launch is on Monday. Use this key: \u{0301} and more words."
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 100) { () -> Accent in
            try Self.withBox(start) { _, store, window, box in
                var seen = Accent()
                guard let box else { return seen }
                seen.boxShown = true
                Self.type(words, into: box)
                // the key's last letter and the accent are one character in his words
                seen.joined = box.string.unicodeScalars.elementsEqual(words.unicodeScalars)
                seen.asked = ViewHost.turn(10) { store.heldKey?.hold == .text }
                Self.press("key-hold-save", in: window)
                seen.cut = ViewHost.turn(10) { box.string.unicodeScalars.elementsEqual(rest.unicodeScalars) }
                seen.text = box.string
                let key = store.secretForm?.key
                seen.formKey = key.map { $0.unicodeScalars.elementsEqual(Self.keyText.unicodeScalars) } == true
                store.secretForm = nil
                ViewHost.turn(1)
                return seen
            }
        }
        #expect(seen.boxShown, "the pencil opens the file's text in the box")
        #expect(seen.joined, "his words hold the accent right after the key")
        #expect(seen.asked, "the key asks")
        #expect(seen.cut, "the cut takes the key's scalars, and the accent and his other words stay: \(seen.text)")
        #expect(seen.formKey, "the secure form gets the key as the box held it, with no accent")
        #expect(screen.stayedHis)
    }

    struct Forms: Sendable {
        var boxShown = false, decomposed = false, asked = false, composed = false, text = ""
    }

    /// **"Save it as a secret" cuts nothing wrong from words that changed their form** (round 9 of 25 November 2026):
    /// the same characters in other scalars ("e" and a combining accent, then "é") are the same words to Swift, so the
    /// box kept the parts of their first read, and the cut counted their places in the other scalars: it took one
    /// character too early or too late.
    @Test func saveItAsASecretCutsNothingWrongFromWordsThatChangedTheirForm() async throws {
        let decomposed = "Our cafe\u{0301} uses this key: \(Self.keyText) today."
        let composed = "Our caf\u{00E9} uses this key: \(Self.keyText) today."
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 100) { () -> Forms in
            try Self.withBox("The launch is on Monday.") { _, store, window, box in
                var seen = Forms()
                guard let box else { return seen }
                seen.boxShown = true
                Self.type(decomposed, into: box)
                seen.decomposed = box.string.unicodeScalars.contains("\u{0301}")
                seen.asked = ViewHost.turn(10) { store.heldKey?.hold == .text }
                ViewHost.turn(0.5)
                // the same characters, in other scalars
                Self.type(composed, into: box)
                seen.composed = !box.string.unicodeScalars.contains("\u{0301}")
                ViewHost.turn(0.5)
                Self.press("key-hold-save", in: window)
                ViewHost.turn(2)
                seen.text = Self.box(in: window)?.string ?? ""
                store.secretForm = nil
                ViewHost.turn(1)
                return seen
            }
        }
        #expect(seen.boxShown, "the pencil opens the file's text in the box")
        #expect(seen.decomposed, "his words hold a combining accent")
        #expect(seen.asked, "the key asks")
        #expect(seen.composed, "then the same words in composed characters")
        #expect(seen.text == composed || seen.text == composed.replacingOccurrences(of: Self.keyText, with: ""),
                "the cut takes the key alone, or nothing: \(seen.text)")
        #expect(screen.stayedHis)
    }

    struct Whole: Sendable {
        var boxShown = false, twoCharacterEnds = false, asked = false, cut = false, formKey = false
    }

    /// **"Save it as a secret" takes the key as the box held it** (round 9 of 25 November 2026): the secure form got
    /// the key in the hub's saved form, so a private key with "\r\n" line ends lost its "\r".
    @Test func saveItAsASecretTakesTheKeyAsTheBoxHeldIt() async throws {
        let start = "The launch is on Monday."
        let words = "The launch is on Monday.\r\nThe key:\r\n" + Self.returnKey + "\r\nThe end."
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 100) { () -> Whole in
            try Self.withBox(start) { _, store, window, box in
                var seen = Whole()
                guard let box else { return seen }
                seen.boxShown = true
                Self.type(words, into: box)
                seen.twoCharacterEnds = box.string.contains("\r\n")
                seen.asked = ViewHost.turn(10) { store.heldKey?.hold == .text }
                Self.press("key-hold-save", in: window)
                seen.cut = ViewHost.turn(10) { box.string == "The launch is on Monday.\r\nThe key:\r\n\r\nThe end." }
                seen.formKey = store.secretForm?.key == Self.returnKey
                store.secretForm = nil
                ViewHost.turn(1)
                return seen
            }
        }
        #expect(seen.boxShown, "the pencil opens the file's text in the box")
        #expect(seen.twoCharacterEnds, "his words hold line ends of two characters")
        #expect(seen.asked, "the key asks")
        #expect(seen.cut, "Save it as a secret takes the key out of his words, and the rest stays")
        #expect(seen.formKey, "the secure form gets the key as the box held it, its line ends included")
        #expect(screen.stayedHis)
    }

    struct Moved: Sendable {
        var boxShown = false, moved = false, body: [String: String] = [:], kept: [String]?
    }

    /// **A save to the hub and the generation that the box opened on says `key_kept` to it, also after the app moved
    /// on** (round 3 of 25 November 2026): the save of the box went to its own generation, but with no `key_kept`
    /// when that was not the one that the app read then, so that hub read the new app as an older one and checked
    /// nothing.
    @Test func aSaveToTheBoxsOwnGenerationSaysWhatHeKept() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 100) { () -> Moved in
            try Self.withBox("The launch is on Monday.", keyCheck: true) { hub, store, window, box in
                var seen = Moved()
                guard let box else { return seen }
                seen.boxShown = true
                let old = store.state?.db ?? "", client = store.installation
                hub.answer("POST", "/ui/knowledge") { Self.receipt($0, client: client) }
                Self.type("The launch is on Tuesday.", into: box)
                ViewHost.turn(1)
                // the hub moves to a new generation while the box shows his words: the page goes back to its list
                hub.give(try Self.reading([KnowledgeClient.keyFeature]))
                Self.fresh(store)
                seen.moved = ViewHost.turn(10) { store.state?.db != old && Self.saves(hub) > 0 }
                let sent = Self.posts(hub).first ?? [:]
                seen.body = ["db": sent["db"] as? String ?? "", "text": sent["text"] as? String ?? ""]
                seen.kept = sent["key_kept"] as? [String]
                seen.body["old"] = old
                return seen
            }
        }
        #expect(seen.boxShown, "the pencil opens the file's text in the box")
        #expect(seen.moved, "the generation moved, and his words went")
        #expect(seen.body["db"] == seen.body["old"], "to the generation that the box opened on")
        #expect(seen.body["text"] == "The launch is on Tuesday.", "with his words")
        #expect(seen.kept == [], "and they say key_kept to it, which checks them")
        #expect(screen.stayedHis)
    }

    /// Cmd+V in the window, as the keyboard gives it.
    @MainActor private static func commandV(in window: NSWindow) {
        if let paste = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                        context: nil, characters: "v", charactersIgnoringModifiers: "v",
                                        isARepeat: false, keyCode: 9) {
            NSApp.sendEvent(paste)
        }
    }

    /// **The kept save names to the hub exactly the parts that he kept** (`key_kept`, on a hub that
    /// lists `knowledge_key`): the SHA-256 of the key that his words add and that he saw when he pressed "Keep it", not
    /// a key that the file held already; a save with no "Keep it" says `[]`, which the hub needs to check it at all. A
    /// hub that checks the file takes the kept words and refuses any other part.
    @Test func theKeptSaveNamesOnlyThePartsThatHeKept() async throws {
        let old = "The launch is on Monday. Old key: " + Self.keyText
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 100) { () -> Named in
            try Self.withBox(old, keyCheck: true) { hub, store, window, box in
                var seen = Named()
                guard let box else { return seen }
                seen.boxShown = true
                let check = KeyCheckingHub(text: old, client: store.installation)
                hub.answer("POST", "/ui/knowledge") { check.answer($0) }
                // an edit beside the file's own key
                Self.type("The launch is on Tuesday. Old key: " + Self.keyText, into: box)
                Self.fresh(store)
                Self.cursorLeaves(box, in: window)
                ViewHost.turn(10) { Self.saves(hub) > 0 }
                // a new key, and "Keep it"
                Self.type("The launch is on Tuesday. Old key: \(Self.keyText) New key: \(Self.secondKey)", into: box)
                seen.asked = ViewHost.turn(10) { store.heldKey?.hold == .text }
                Self.fresh(store)
                Self.press("key-hold-go-on", in: window)
                ViewHost.turn(10) { Self.saves(hub) > 1 }
                // a later edit of the kept words
                Self.type("The launch is on Wednesday. Old key: \(Self.keyText) New key: \(Self.secondKey)", into: box)
                Self.fresh(store)
                Self.cursorLeaves(box, in: window)
                ViewHost.turn(10) { Self.saves(hub) > 2 }
                ViewHost.turn(1)
                seen.kept = Self.posts(hub).map { $0["key_kept"] as? [String] }
                seen.problem = Self.element("knowledge-problem", in: window) != nil
                return seen
            }
        }
        #expect(seen.boxShown, "the pencil opens the file's text in the box")
        #expect(seen.asked, "the new key asks")
        // an edit beside the file's own key names no part, and says so; the kept save names the new key alone, not
        // the file's own; a later save, after the hub took the key, names none
        #expect(seen.kept == [[], [Self.sha(Self.secondKey)], []], "the three saves name what he kept, and only that")
        #expect(!seen.problem, "the hub took each save")
        #expect(screen.stayedHis)
    }

    struct Refused: Sendable {
        var boxShown = false, asked = false, askedAgain = false, problem: String?, saves = -1
    }

    /// **A kept save that the hub refuses all the same asks again**, in the same strip (the coordinator, 24 November
    /// 2026): the hub read another part than the Mac did, so his "Keep it" did not cover it. The words wait under the
    /// question, and the cursor that leaves the box sends them no more.
    @Test func aKeptSaveThatTheHubRefusesAsksAgain() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 100) { () -> Refused in
            try Self.withBox("The launch is on Monday.", keyCheck: true) { hub, store, window, box in
                var seen = Refused()
                guard let box else { return seen }
                seen.boxShown = true
                let check = KeyCheckingHub(text: "The launch is on Monday.", client: store.installation, refusing: true)
                hub.answer("POST", "/ui/knowledge") { check.answer($0) }
                Self.type("The launch is on Monday. Use this key: " + Self.keyText, into: box)
                seen.asked = ViewHost.turn(10) { store.heldKey?.hold == .text }
                Self.fresh(store)
                Self.press("key-hold-go-on", in: window)
                ViewHost.turn(10) { Self.saves(hub) > 0 }
                seen.askedAgain = ViewHost.turn(10) { store.heldKey?.hold == .text }
                Self.fresh(store)
                Self.cursorLeaves(box, in: window)
                ViewHost.turn(2)
                seen.saves = Self.saves(hub)
                return seen
            }
        }
        #expect(seen.boxShown, "the pencil opens the file's text in the box")
        #expect(seen.asked, "the key asks")
        #expect(seen.askedAgain, "the hub's refusal of the kept save asks again")
        #expect(seen.saves == 1, "and the words wait")
        #expect(screen.stayedHis)
    }

    struct Pasted: Sendable {
        var boxShown = false, pasteHeld = false, notPasted = false, asked = false, cut = false, formKey = false
        var keySent = true
    }

    /// **Cmd+V of a key into the box is held, and "Save it as a secret" takes only the key out of his words.** A box
    /// with no guard of the paste puts the clipboard's key into the file; a cut that is the chat's (`KeyCut.split`)
    /// takes his spaces and joins his lines' spaces too. The clipboard is the test's own (`KeyCut.board`), never the
    /// Mac's.
    @Test func aPastedKeyIsHeldAndSaveItAsASecretTakesOutOnlyTheKey() async throws {
        let start = "  An indented line.\n\nThe launch is on Monday."
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 100) { () -> Pasted in
            let board = NSPasteboard.withUniqueName()
            KeyCut.board = board
            defer { KeyCut.board = .general; board.releaseGlobally() }
            return try Self.withBox(start) { hub, store, window, box in
                var seen = Pasted()
                guard let box else { return seen }
                seen.boxShown = true
                board.clearContents()
                board.setString(Self.keyText, forType: .string)
                window.makeFirstResponder(box)
                ViewHost.turn(1)
                let before = box.string
                Self.commandV(in: window)
                seen.pasteHeld = ViewHost.turn(10) { store.heldKey?.hold == .paste }
                seen.notPasted = box.string == before
                store.heldKey = nil
                // his words with a key, and two spaces on each side of it
                Self.type("  An indented line.\n\nUse this key:  \(Self.keyText)  and the rest.", into: box)
                seen.asked = ViewHost.turn(10) { store.heldKey?.hold == .text }
                Self.press("key-hold-save", in: window)
                seen.cut = ViewHost.turn(10) { box.string == "  An indented line.\n\nUse this key:    and the rest." }
                seen.formKey = store.secretForm?.key == Self.keyText
                store.secretForm = nil
                ViewHost.turn(1)
                seen.keySent = Self.posts(hub).contains { ($0["text"] as? String)?.contains(Self.keyText) == true }
                return seen
            }
        }
        #expect(seen.boxShown, "the pencil opens the file's text in the box")
        #expect(seen.pasteHeld, "Cmd+V of a key asks first")
        #expect(seen.notPasted, "and pastes nothing")
        #expect(seen.asked, "his words with a key ask")
        #expect(seen.cut, "Save it as a secret takes out the key alone, and his spaces and lines stay")
        #expect(seen.formKey, "the key goes into the secure form")
        #expect(!seen.keySent, "the key never reached the hub")
        #expect(screen.stayedHis)
    }

    struct Writes: Sendable {
        var kept: [[String]?] = []
    }

    /// **Every write of a knowledge file says `key_kept` where the hub checks a file for a key, and no write says it
    /// where the hub does not** (feature `knowledge_key`): Add file, Add URL, a kept chat file and a change in place. The hub
    /// checks an app's write only when it says the field, and an older hub refuses the field: a write path that leaves
    /// it out lets a key through, and one that always says it fails on an older hub.
    @Test func everyKnowledgeWriteSaysWhatHeKeptOnlyWhereTheHubChecks() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 100) { () -> Writes in
            let hub = try LoopbackHub(state: Self.reading())
            defer { hub.stop() }
            let client = KnowledgeClient(), address = URL(string: hub.address)!, me = "founderizer-swift/1/test"
            let writes = Imports()
            Task {
                for check in [true, false] {
                    _ = try? await client.add(hub: address, database: "d", client: me, title: "Launch plan",
                                              text: "The launch is on Monday.", source: "launch-plan.md", keyCheck: check)
                    _ = try? await client.addPage(hub: address, database: "d", client: me, url: "https://example.com/page",
                                                  keyCheck: check)
                    _ = try? await client.add(attachment: 7, hub: address, database: "d", client: me, keyCheck: check)
                    _ = try? await client.edit(hub: address, database: "d", client: me, path: Self.path,
                                               text: "Use this key: " + Self.keyText, keyCheck: check, kept: [Self.keyText])
                }
                writes.done = true
            }
            ViewHost.turn(30) { writes.done }
            return Writes(kept: Self.posts(hub).map { $0["key_kept"] as? [String] })
        }
        // to a hub that checks: Add file, Add URL and a kept chat file say that he kept nothing, and a change in place
        // names what he kept; to a hub that does not check, no write says it
        #expect(seen.kept == [[], [], [], [Self.sha(Self.keyText)], nil, nil, nil, nil], "each write's key_kept")
        #expect(screen.stayedHis)
    }

    struct Callers: Sendable {
        var status = false, file: [String]?, page: [String]?, kept: [String]?
    }

    /// **Each caller of a knowledge write says `key_kept` to a hub that checks a file for a key** (round 2 of 24 November
    /// 2026): Add file (and a drop, whose files go the same way, `add(_:)`), Add URL and "Keep as knowledge" of a chat
    /// file, each through the page or the store as he uses them. A caller that says `keyCheck: false` makes the hub
    /// read the new app as an older one, which it checks for nothing. Add file's line names the file that it did not
    /// send, in the strip's words, beside the one that it added.
    @Test func everyCallerOfAKnowledgeWriteSaysWhatHeKept() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-callers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let plain = folder.appendingPathComponent("launch-plan.txt"), keyed = folder.appendingPathComponent("notes.txt")
        try "The launch is on Monday.".write(to: plain, atomically: true, encoding: .utf8)
        try ("Use this key: " + Self.keyText).write(to: keyed, atomically: true, encoding: .utf8)
        let features = [KnowledgeClient.keyFeature, "attachment_knowledge"]
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 100) { () -> Callers in
            let panel = KnowledgeImport.choose
            KnowledgeImport.choose = { [plain, keyed] }
            defer { KnowledgeImport.choose = panel }
            return try Self.withPage("The launch is on Monday.", features: features) { hub, store, window in
                var seen = Callers()
                let client = store.installation
                hub.answer("POST", "/ui/knowledge") { Self.receipt($0, client: client) }
                func body(_ field: String) -> [String: Any]? { Self.posts(hub).first { $0[field] != nil } }
                store.show(.settings(.knowledge))
                // Add file
                Self.fresh(store)
                Self.press("knowledge-add-file", in: window)
                seen.status = ViewHost.turn(20) {
                    Self.shows("Added launch-plan.txt. notes.txt: " + String(l10n: "This file holds what looks like a key."), in: window)
                }
                seen.file = body("title")?["key_kept"] as? [String]
                // Add URL: the address in its field, and Return
                Self.fresh(store)
                Self.press("knowledge-add-url", in: window)
                ViewHost.turn(10) { Self.field(in: window) != nil }
                if let field = Self.field(in: window) {
                    window.makeFirstResponder(field)
                    ViewHost.turn(0.5)
                    if let editor = field.currentEditor() as? NSTextView {
                        editor.insertText("https://example.com/page", replacementRange: NSRange(location: NSNotFound, length: 0))
                        ViewHost.turn(0.5)
                        editor.insertNewline(nil)
                    }
                }
                ViewHost.turn(10) { body("url") != nil }
                seen.page = body("url")?["key_kept"] as? [String]
                // Keep as knowledge of a chat file
                let file = MessageAttachment(id: 7, name: "notes.md", mime: "text/markdown", size: 12,
                                             sha256: String(repeating: "a", count: 64), created: 1)
                Self.fresh(store)
                Task { await store.keepAsKnowledge(file) }
                ViewHost.turn(10) { body("attachment") != nil }
                seen.kept = body("attachment")?["key_kept"] as? [String]
                return seen
            }
        }
        #expect(seen.status, "Add file's line names the file with a key, in the strip's words, beside the one it added")
        #expect(seen.file == [], "Add file says that he kept nothing")
        #expect(seen.page == [], "and so does Add URL")
        #expect(seen.kept == [], "and Keep as knowledge of a chat file")
        #expect(screen.stayedHis)
    }

    /// The one field of the page that takes typed words, a text field: Add URL's address.
    @MainActor private static func field(in window: NSWindow) -> NSTextField? {
        var views: [NSView] = [window.contentView].compactMap { $0 }
        while !views.isEmpty {
            let view = views.removeFirst()
            if let field = view as? NSTextField, field.isEditable { return field }
            views += view.subviews
        }
        return nil
    }

    /// **Each place of the app's code that names the knowledge route is KnowledgeClient's read or its one write**
    /// (`change`, which says `key_kept` on every write to a hub that checks a file for a key). A write that builds its own
    /// request (a new "keep as knowledge", a drop of its own) would leave the field out, and the hub would then read it
    /// as an older app's and check nothing. Nor does any write say `keyCheck: false` but the delete, which the hub never
    /// checks, and no line builds the route from its parts (`"ui"` and `"knowledge"`). Comments do not count. It cannot
    /// see a route that a constant of another line or file spells, or one that comes as data (the owner tools' table).
    @Test func everyCallOfTheKnowledgeRouteGoesThroughTheClientsOneWrite() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        var found: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path } ?? []
        for file in files {
            var function = ""
            for line in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n") {
                let code = line.trimmingCharacters(in: .whitespaces)
                if let name = code.firstMatch(of: #/\bfunc (\w+)/#)?.1 { function = String(name) }
                guard !code.hasPrefix("//") else { continue }
                if code.contains("ui/knowledge") { found.append("\(file.lastPathComponent): \(function)") }
                if code.contains("keyCheck: false"), function != "delete" {
                    found.append("\(file.lastPathComponent): \(function): keyCheck: false")
                }
                if code.contains("\"knowledge\""),
                   code.contains("appendingPathComponent") || code.contains("\"ui") || code.contains("/ui") {
                    found.append("\(file.lastPathComponent): \(function): the route from its parts")
                }
            }
        }
        #expect(found == ["Knowledge.swift: file", "Knowledge.swift: change"], "the knowledge route outside the client")
    }

    @MainActor final class Imports {
        var said: [String: String] = [:]
        var done = false
    }

    struct Imported: Sendable {
        var said: [String: String] = [:]
    }

    /// **Add file and a drop send nothing for a file that holds what looks like a key** (the coordinator's M1, 24
    /// November 2026): its text, or its name, which is its title and its source. Until then they sent a file's whole
    /// text, which every agent that gets the file reads, with no look. The file's line says why in the strip's own
    /// words, and a file with no key, or with a picture's data in it, goes on.
    @Test func aFileThatHoldsAKeyIsNotAddedAndTheOthersAre() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var bytes: UInt64 = 20_261_124
        let picture = Data((0..<6_000).map { _ -> UInt8 in
            bytes = bytes &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: bytes >> 33)
        }).base64EncodedString()
        let files = ["launch-plan.txt": "The launch is on Monday.",
                     "notes.txt": "The launch is on Monday. Use this key: " + Self.keyText,
                     Self.keyText + ".txt": "The launch is on Monday.",
                     "logo-notes.txt": "Our logo:\n\n![logo](data:image/png;base64,\(picture))\n",
                     "address-notes.txt": "See https://example.com/files/\u{001F}" + Self.lookAlike]
        for (name, text) in files { try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let names = files.keys.sorted()
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 100) { () -> Imported in
            let imports = Imports()
            Task {
                for name in names {
                    do { imports.said[name] = try await KnowledgeImport.file(of: folder.appendingPathComponent(name)).text }
                    catch { imports.said[name] = error.localizedDescription }
                }
                imports.done = true
            }
            ViewHost.turn(60) { imports.done }
            return Imported(said: imports.said)
        }
        let refused = String(l10n: "This file holds what looks like a key.")
        #expect(seen.said["launch-plan.txt"] == "The launch is on Monday.", "a file with no key goes")
        #expect(seen.said["notes.txt"] == refused, "a key in a file's text sends nothing, in the strip's words")
        #expect(seen.said[Self.keyText + ".txt"] == refused, "nor a key in its name")
        #expect(seen.said["logo-notes.txt"]?.hasPrefix("Our logo:") == true, "a picture's data is no key")
        #expect(seen.said["address-notes.txt"] == refused, "nor a key that only the saved file sets apart (round 8)")
        #expect(screen.stayedHis)
    }
}
