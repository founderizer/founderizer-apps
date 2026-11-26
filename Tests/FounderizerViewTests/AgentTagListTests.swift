import AppKit
import FleetCore
import Testing
import Vision
@testable import Founderizer

/// **The @ list of the chat's box, by its keys and the pointer, and the tags that go with his message** (the owner, 20
/// November 2026: "@<agent-name> or @<agent-role> allows tagging an agent", and "Yes, as drawn" to the list: one row for
/// each other agent, ↑ ↓ and Return or Tab, Esc, one Backspace removes it; his answer of 22 November 2026: a row
/// shows the name and the role, and a pick writes "@" and the name). The real composer, in the window of a test, on a stand-in hub that keeps what
/// the app sends. Example names only.
@Suite(.serialized, .timeLimit(.minutes(10))) struct AgentTagListTests {
    struct Seen: Sendable {
        var firstRow: String?, keptDraft: String?, opened = false, closedByEsc = false, afterEsc: String?, closedWhileTyping = false
        var reopened = false, picked: String?, sentWhilePicking = false, typedAfterPick: String?
        var afterBackspaces: String?, wholeLabel: String?, firstSpace: String?, rangeCloses = false
        var clicked: String?, keepsKeys: String?, composing: String?, sentWhileComposing = false
        var tabbed: String?, mentions: [String]?, noFeature = false, otherChat: [String]?
    }

    private static let now = Int(Date().timeIntervalSince1970)

    /// The manager's team: its chat's rows are "Atlas · Marketing", "Nova · DevOps Lead" and "Iris · DevOps", in this
    /// order.
    private static let team: [(name: String, title: String)] = [("manager", "Fleet Manager"), ("atlas", "Marketing"),
                                                                ("nova", "DevOps Lead"), ("iris", "DevOps")]

    private static func reading(features: [String], messages: [[String: Any]] = [],
                                team: [(name: String, title: String)] = team) throws -> Data {
        let agents: [[String: Any]] = team.map {
            ["name": $0.name, "role": $0.name == "manager" ? "manager" : "worker", "title": $0.title, "runtime": "claude",
             "can": [], "placed": true]
        }
        return try JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "db": "tags-\(UUID().uuidString)", "time": now, "agents": agents, "tasks": [], "holds": [],
            "outcomes": [], "notes": [], "needs": [], "permissions": [], "messages": messages, "reports": [],
            "ui_features": features] as [String: Any])
    }

    /// A store that reads `hub`, after its first answer: it can write, and its chat has the hub's messages.
    @MainActor private static func store(on hub: LoopbackHub, _ state: Data) throws -> FleetStore {
        _ = ViewHost.store(try HubState.decode(state))         // the test's own defaults and folder
        AppDefaults.store.set(hub.address, forKey: "hubAddress")
        let store = FleetStore()
        Task { await store.refresh() }
        ViewHost.turn(10) { store.canWrite }
        store.destination = .agent("manager")
        return store
    }

    /// One key, down and up, as the keyboard sends it: its code and its characters.
    @MainActor private static func key(_ code: UInt16, _ characters: String, function: Bool = false,
                                       in window: NSWindow) -> [NSEvent] {
        [NSEvent.EventType.keyDown, .keyUp].compactMap { type in
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: function ? [.function, .numericPad] : [],
                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                             context: nil, characters: characters, charactersIgnoringModifiers: characters,
                             isARepeat: false, keyCode: code)
        }
    }

    /// His words into the field that has the keys, as an input method gives them, whatever the Mac's keyboard layout.
    @MainActor private static func type(_ words: String, in window: NSWindow) {
        (window.firstResponder as? NSTextView)?.insertText(words, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// Where the chat's column shows these words, read as a person reads them, in the window's picture (Vision,
    /// English): right of the sidebar, whose rows name the agents and show his newest words too, and left of the
    /// panel. `plain`: only a line with no "@", which leaves out the box and his bubble. Vision reads a badge's glyph as
    /// a character of its own, so a line of words with a badge reads in parts ("Ask * @DevOps", "about it").
    @MainActor private static func place(of words: String, plain: Bool, in window: NSWindow) throws -> NSPoint? {
        guard let view = window.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        view.display()
        guard let picture = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: picture)
        guard let image = picture.cgImage else { return nil }
        let reading = VNRecognizeTextRequest()
        reading.recognitionLevel = .accurate
        reading.recognitionLanguages = ["en-US"]
        reading.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([reading])
        let column = (FleetStyle.sidebarWidth + 20)...(view.bounds.width - FleetStyle.panelWidth - 20)
        for line in reading.results ?? [] {
            for text in line.topCandidates(plain ? 1 : 3) where !(plain && text.string.contains("@")) {
                guard let range = text.string.range(of: words),
                      let box = try? text.boundingBox(for: range)?.boundingBox else { continue }
                let point = NSPoint(x: box.midX * view.bounds.width, y: box.midY * view.bounds.height)
                if column.contains(point.x) { return point }
            }
        }
        return nil
    }

    /// The list shows (or no longer shows) a row of these words, within 15 s (3 s for none).
    @MainActor private static func list(_ shows: Bool, _ words: String, in window: NSWindow) throws -> Bool {
        let end = Date().addingTimeInterval(shows ? 15 : 3)
        repeat {
            if try (place(of: words, plain: true, in: window) != nil) == shows { return true }
            ViewHost.turn(0.3)
        } while Date() < end
        return false
    }

    /// The bug that this catches: Return sends the half-written words while the list is open, or ↑ opens a correction;
    /// ↑ and ↓ do not stop at the ends; the list reopens as he types after Esc; Return picks the first row where his
    /// letters are another row's whole role; a pick writes the role and not the name; a pick leaves the caret before
    /// its space; a Backspace leaves "@Nova" behind, or on the first of two spaces takes a space and not the tag; a selection of words keeps the list open; a
    /// click picks nothing or takes the keyboard from the box; an input method's Return picks a row or sends; the
    /// message reaches the hub with no `mentions`, or with them on a hub without the feature, which refuses a field
    /// that it does not know; the box's selection, bound for the list, selects a kept draft as the box takes the keys.
    @Test func theListPicksByItsKeysAndThePointerAndTheMessageCarriesItsTags() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 170) { () -> Seen in
            var seen = Seen()
            let state = try Self.reading(features: ["direct_chat", AgentTags.feature])
            let hub = try LoopbackHub(state: state)
            defer { hub.stop() }
            let store = try Self.store(on: hub, state)
            store.setDraft("Hello", for: "manager")
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            @MainActor func words() -> String? { ViewHost.fieldWords(in: window) }
            @MainActor func press(_ events: [NSEvent], until done: (() -> Bool)? = nil) {
                ViewHost.atOnce(events)
                ViewHost.turn(done == nil ? 0.5 : 5, until: done ?? { false })
            }
            @MainActor func clear() {
                store.setDraft("", for: "manager")
                ViewHost.turn(2) { words() == "" }
            }
            let escape = Self.key(53, "\u{1B}", in: window), back = Self.key(51, "\u{7F}", in: window)
            let down = Self.key(125, "\u{F701}", function: true, in: window)
            let up = Self.key(126, "\u{F700}", function: true, in: window)
            let left = Self.key(123, "\u{F702}", function: true, in: window)
            let enter = Self.key(36, "\r", in: window), tab = Self.key(48, "\t", in: window)
            // a key typed while no field has the keys goes to the box, after its kept draft (`ComposerCaret`)
            ViewHost.turn(2)
            ViewHost.atOnce(Self.key(7, "x", in: window))
            ViewHost.turn(5) { store.composerText(for: "manager") == "Hellox" }
            seen.keptDraft = store.composerText(for: "manager")
            clear()
            // "@" opens the list; Esc closes it and leaves the "@"; a letter typed then keeps it closed
            Self.type("@", in: window)
            seen.opened = try Self.list(true, "DevOps", in: window)
            press(escape)
            seen.closedByEsc = try Self.list(false, "DevOps", in: window)
            seen.afterEsc = words()
            Self.type("m", in: window)
            seen.closedWhileTyping = try Self.list(false, "Marketing", in: window)
            // a new "@" opens it again; ↑ at the first row and ↓ past the last stop there; Return picks, sends nothing
            press(back); press(back) { words() == "" }
            Self.type("@", in: window)
            seen.reopened = try Self.list(true, "DevOps", in: window)
            // ↑ at the first row stays there, and Return picks it; one Backspace at the space takes it again
            press(up)
            press(enter) { words()?.hasSuffix(" ") == true }
            seen.firstRow = words()
            press(back) { words() == "" }
            Self.type("@", in: window)
            _ = try Self.list(true, "DevOps", in: window)
            // ↓ four times on three rows stops at the last (a list that wraps ends on the first); one ↑ then lights the
            // middle row
            for _ in 0..<4 { press(down) }
            press(up)
            press(enter) { words()?.hasSuffix(" ") == true }
            seen.picked = words()
            seen.sentWhilePicking = hub.requests.contains { $0.method == "POST" }
            // the caret stands after the pick's space; two Backspaces take "hi", the third the space and the whole tag
            Self.type("hi", in: window)
            ViewHost.turn(2) { words() == "@Nova hi" }
            seen.typedAfterPick = words()
            for _ in 0..<3 { press(back) }
            ViewHost.turn(2) { words() == "" }
            seen.afterBackspaces = words()
            // letters that are a row's whole role light that row, not the first that they start
            Self.type("@devops", in: window)
            _ = try Self.list(true, "DevOps Lead", in: window)
            press(enter) { words()?.hasSuffix(" ") == true }
            seen.wholeLabel = words()
            clear()
            // two spaces after a tag: a Backspace on the first takes the tag, by the caret's place
            Self.type("@ma", in: window)
            _ = try Self.list(true, "Marketing", in: window)
            press(tab) { words() == "@Atlas " }
            Self.type(" ", in: window)
            press(left)
            press(back) { words() != "@Atlas " }
            seen.firstSpace = words()
            clear()
            // a selection of words closes the list, also one that begins after the "@"
            Self.type("@m", in: window)
            _ = try Self.list(true, "Marketing", in: window)
            (window.firstResponder as? NSTextView)?.setSelectedRange(NSRange(location: 1, length: 1))
            seen.rangeCloses = try Self.list(false, "Marketing", in: window)
            (window.firstResponder as? NSTextView)?.setSelectedRange(NSRange(location: 2, length: 0))
            press(back) { words() == "@" }
            // a click on a row picks it, and the box keeps the keys
            _ = try Self.list(true, "Marketing", in: window)
            if let row = try Self.place(of: "Marketing", plain: true, in: window) {
                press(ViewHost.click(row, in: window)) { words() == "@Atlas " }
                seen.clicked = words()
                Self.type("x", in: window)
                ViewHost.turn(2) { words() == "@Atlas x" }
                seen.keepsKeys = words()
            }
            clear()
            // an input method's text in the making: its Return is the method's, and no row is picked, nothing sent;
            // the store can write, so a Return that went to the send would send
            Task { await store.refresh() }
            ViewHost.turn(10) { store.canWrite }
            Self.type("@", in: window)
            _ = try Self.list(true, "Marketing", in: window)
            let field = window.firstResponder as? NSTextView
            field?.setMarkedText("ma", selectedRange: NSRange(location: 2, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
            ViewHost.turn(0.5)
            press(enter)
            seen.composing = words()
            seen.sentWhileComposing = hub.requests.contains { $0.method == "POST" }
            field?.unmarkText()
            clear()
            if window.firstResponder as? NSTextView == nil, let box = try ViewHost.middle(of: "Message", in: window) {
                ViewHost.atOnce(ViewHost.click(box, in: window))
                ViewHost.turn(2) { words() != nil }
            }
            // the letters filter, and Tab picks; Return with the list closed sends, with the tag
            Self.type("@ma", in: window)
            _ = try Self.list(true, "Marketing", in: window)
            press(tab) { words() == "@Atlas " }
            seen.tabbed = words()
            Self.type("now", in: window)
            ViewHost.turn(2) { words() == "@Atlas now" }
            // the app writes only within a moment of the hub's answer, and this test is long
            Task { await store.refresh() }
            ViewHost.turn(10) { store.canWrite }
            press(enter) { hub.requests.contains { $0.method == "POST" } }
            if let post = hub.requests.first(where: { $0.method == "POST" && $0.path == "/ui/messages" }),
               let body = try JSONSerialization.jsonObject(with: Data(post.body.utf8)) as? [String: Any],
               let tags = body["mentions"] as? [[String: Any]] {
                seen.mentions = tags.map { "\($0["agent"] ?? "") \($0["start"] ?? "") \($0["length"] ?? "")" }
            }
            // another chat's table: its own agent is no row, the manager is one
            seen.otherChat = store.agentTags(except: "atlas")?.rows.map(\.agent)
            // a hub without the feature: no list and no field
            let older = ViewHost.store(try ViewHost.reading(needs: [], features: ["direct_chat"]))
            seen.noFeature = older.agentTags(except: "manager") == nil
            return seen
        }
        #expect(seen.keptDraft == "Hellox", "a kept draft's caret is at its end: \(String(describing: seen.keptDraft))")
        #expect(seen.opened, "\"@\" opens the list with a row for each other agent")
        #expect(seen.closedByEsc && seen.afterEsc == "@", "Esc closes the list and does nothing else")
        #expect(seen.closedWhileTyping, "the list that Esc closed stays closed while he types")
        #expect(seen.reopened, "a new \"@\" opens it again")
        #expect(seen.firstRow == "@Atlas ", "↑ at the first row stays there: \(String(describing: seen.firstRow))")
        #expect(seen.picked == "@Nova " && !seen.sentWhilePicking,
                "↑ and ↓ stop at the ends, and Return picks and sends nothing: \(String(describing: seen.picked))")
        #expect(seen.typedAfterPick == "@Nova hi", "the caret stands after the pick's space")
        #expect(seen.afterBackspaces == "", "one Backspace at the space after the tag takes the whole tag")
        #expect(seen.wholeLabel == "@Iris ", "his letters light the row of their role, and the pick writes its name: \(String(describing: seen.wholeLabel))")
        #expect(seen.firstSpace == " ", "a Backspace on the first of two spaces takes the tag: \(String(describing: seen.firstSpace))")
        #expect(seen.rangeCloses, "a selection of words closes the list")
        #expect(seen.clicked == "@Atlas " && seen.keepsKeys == "@Atlas x",
                "a click picks the row, and the box keeps the keys: \(String(describing: seen.clicked)) \(String(describing: seen.keepsKeys))")
        #expect(seen.composing?.contains("Atlas") == false && !seen.sentWhileComposing,
                "an input method's Return picks no row and sends nothing: \(String(describing: seen.composing))")
        #expect(seen.tabbed == "@Atlas ", "the letters filter the rows by the role, and Tab picks")
        #expect(seen.mentions == ["atlas 0 6"], "the message carries its tag: \(String(describing: seen.mentions))")
        #expect(seen.otherChat == ["manager", "nova", "iris"], "each chat has its own table: \(String(describing: seen.otherChat))")
        #expect(seen.noFeature, "a hub without agent_tags gets no list and no field")
        #expect(screen.stayedHis)
    }

    /// **More than six rows scroll, and the lighter row stays in view.** The bug that this catches: ↓ lights a row that
    /// the list does not show, so Return picks an agent that he cannot see.
    @Test func moreThanSixRowsScrollToKeepTheLighterRowInView() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 90) { () -> (first: Bool, last: Bool, scrolled: Bool) in
            let team = [("manager", "Fleet Manager")] + ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf",
                                                         "Hotel"].map { ($0.lowercased(), $0) }
            let state = try Self.reading(features: ["direct_chat", AgentTags.feature], team: team)
            let hub = try LoopbackHub(state: state)
            defer { hub.stop() }
            let store = try Self.store(on: hub, state)
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            guard let box = try ViewHost.middle(of: "Message", in: window) else {
                throw ViewHost.Missing(description: "the chat's box is not drawn")
            }
            ViewHost.atOnce(ViewHost.click(box, in: window))
            ViewHost.turn(2) { ViewHost.fieldWords(in: window) != nil }
            Self.type("@", in: window)
            let first = try Self.list(true, "Alpha", in: window)
            let last = try Self.list(false, "Hotel", in: window)
            for _ in 0..<7 {
                ViewHost.atOnce(Self.key(125, "\u{F701}", function: true, in: window))
                ViewHost.turn(0.3)
            }
            return (first, last, try Self.list(true, "Hotel", in: window))
        }
        #expect(seen.first && seen.last, "six rows show, the first ones")
        #expect(seen.scrolled, "↓ to the eighth row scrolls it into view")
        #expect(screen.stayedHis)
    }

    /// **His sent message draws its tag from the hub's `mentions`, with the "@" in its words** (`MessageText` marks each
    /// tag's "@" before the Markdown and gives it back in the block's words), **and only an entry is a tag**: his "@"
    /// name that the list does not hold stays words. The bug that this catches: the mark stays in the bubble where his
    /// "@" stood, a message with tags makes the chat fail to draw, or a name after his "@" that the hub did not take as
    /// a tag (the chat's own agent, an 11th, a message from before the tags) looks like one.
    @Test func hisSentMessageDrawsItsTagWithItsAt() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop { () -> (tag: Bool, words: Bool) in
            let message: [String: Any] = [
                "request_id": "m-1", "recipient": "manager", "kind": "message", "text": "**Ask** @DevOps about it",
                "event_id": 1, "created": Self.now - 60, "client": "test",
                "mentions": [["agent": "iris", "start": 8, "length": 7]]]
            let untagged: [String: Any] = [
                "request_id": "m-2", "recipient": "manager", "kind": "message", "text": "Then @Marketing again",
                "event_id": 2, "created": Self.now - 30, "client": "test", "mentions": [] as [Any]]
            let state = try Self.reading(features: ["direct_chat", AgentTags.feature], messages: [message, untagged])
            let hub = try LoopbackHub(state: state)
            defer { hub.stop() }
            let store = try Self.store(on: hub, state)
            ViewHost.turn(10) { store.chatTimeline.count(for: "manager") > 0 }
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            let end = Date().addingTimeInterval(15)
            var tag = false, words = false
            repeat {
                tag = try tag || Self.place(of: "@DevOps", plain: false, in: window) != nil
                words = try words || Self.place(of: "Then @Marketing again", plain: false, in: window) != nil
                if tag && words { break }
                ViewHost.turn(0.3)
            } while Date() < end
            return (tag, words)
        }
        #expect(seen.tag, "the bubble reads \"@DevOps\", after the badge's glyph")
        #expect(seen.words, "his \"@Marketing\" that the list does not hold reads as one line of words, with no glyph")
        #expect(screen.stayedHis)
    }
}
