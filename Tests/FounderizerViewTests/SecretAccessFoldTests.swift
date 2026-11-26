import AppKit
import FleetCore
import SwiftUI
import Testing
@testable import Founderizer

/// **A press on the lines of "Who can use it" opens the row of each agent, a second press closes them, and neither
/// changes who gets the key** (the owner, 23 November 2026: "instead of Manage, just show a caret at the end of the Reads
/// it row and expand the list, and then let it collapse again,so we can remove the Manage button", and "Yes, as drawn" to
/// its pictures), on a key request's card and on Add secret. The form is the app's own, in a window that no screen shows,
/// on a stand-in hub whose central vault has the key that this test's app pinned. Its elements are read and pressed as an
/// assistive app does (`JobCardPressTests`). A row is set in the form's own draft (`SecretFormDraft`), as its control sets
/// it: the control's list is a window on the owner's screen.
@Suite(.serialized, .timeLimit(.minutes(10))) struct SecretAccessFoldTests {
    private static let fold = "secret-access-fold", bothRead = ["ada": "read", "bea": "read"]
    private static let agents = [("manager", "manager"), ("ada", "worker"), ("bea", "lead"), ("cal", "worker")]
    private static let holders: Set<String> = ["ada", "bea", "cal"]
    /// The central vault's key and the fleet's id, made up for tests.
    private static let vaultKey = "age1wxf6a2an5vh325jh25qs9dpemgwrxp0lgsuxhkr9yqtpyzfq99assg55x8", fleet = "0123456789abcdef"

    /// The rows as Save reads them.
    private struct Rows: Equatable, Sendable {
        let access: [String: SecretGrant], touched: Set<String>, proposed: Set<String>
    }

    /// A form of the app and its stand-in hub.
    @MainActor private struct Form {
        let store: FleetStore, hub: LoopbackHub, kept: SecretValueKept, window: NSWindow

        /// Each element that VoiceOver reads in the window.
        var elements: [NSObject] {
            var queue = [window.contentView as NSObject?].compactMap { $0 }, found: [NSObject] = []
            while !queue.isEmpty {
                let object = queue.removeFirst()
                found.append(object)
                queue += (get(object, "accessibilityChildren") as? [Any] ?? []).compactMap { $0 as? NSObject }
            }
            return found
        }
        func element(_ identifier: String) -> NSObject? {
            elements.first { get($0, "accessibilityIdentifier") as? String == identifier }
        }
        func text(_ name: String) -> String { element(fold).flatMap { get($0, name) as? String } ?? "" }
        /// What each element of the window says: its label, its title and its value.
        var words: [[String]] {
            elements.map { object in
                ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap { get(object, $0) as? String }
            }
        }
        /// The agents whose rows are open.
        var rows: Set<String> {
            Set(elements.compactMap { get($0, "accessibilityIdentifier") as? String }.filter { $0.hasPrefix("secret-give-") }
                .map { String($0.dropFirst("secret-give-".count)) })
        }
        func opens() -> Bool { ViewHost.turn(15) { rows == holders } }
        func closes() -> Bool { ViewHost.turn(15) { rows.isEmpty } }

        /// VoiceOver's press, as AppKit makes it for an `AXPress`, and whether the element took it.
        @discardableResult func press(_ identifier: String) -> Bool {
            guard let object = element(identifier) else { return false }
            let press = NSSelectorFromString("accessibilityPerformPress")
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(object.method(for: press), to: Press.self)(object, press)
        }
        /// Where the lines stand, in the window's own points.
        var place: NSRect {
            guard let object = element(fold) else { return .zero }
            let frame = NSSelectorFromString("accessibilityFrame")
            typealias Frame = @convention(c) (AnyObject, Selector) -> NSRect
            return window.convertFromScreen(unsafeBitCast(object.method(for: frame), to: Frame.self)(object, frame))
        }
        /// A click in the middle of the lines, where they have no words: the whole row is the target.
        func click() { ViewHost.atOnce(ViewHost.click(NSPoint(x: place.midX, y: place.midY), in: window)) }

        /// His picks in the open rows: Cal uses it, and Bea gets no access any more.
        func setRows() {
            kept.draft?.access["cal"] = .use
            kept.draft?.access["bea"] = nil
            kept.draft?.touched.formUnion(["cal", "bea"])
            kept.draft?.proposed.remove("bea")
        }
        var shown: Rows? { kept.draft.map { Rows(access: $0.access, touched: $0.touched, proposed: $0.proposed) } }

        func posts(_ path: String) -> [[String: Any]] {
            hub.requests.filter { $0.method == "POST" && $0.path == path }.map { object($0.body) }
        }
        /// Save, and each grant that the hub then got, in its order. The request's answer comes after the grants.
        func save() -> [String] {
            let answered = store.lastSuccess
            Task { await store.refresh() }              // the app writes only within 12 seconds of the hub's answer
            ViewHost.turn(15) { store.lastSuccess != answered }
            // a Save that waits for the vault's key takes no press
            ViewHost.turn(20) { press("secret-save"); return !posts("/ui/secrets/add").isEmpty }
            ViewHost.turn(20) { !posts("/ui/needs/91/secret").isEmpty }
            return posts("/ui/secrets/grant").map { "\($0["agent"] ?? "") \($0["grant"] ?? "")" }
        }

        /// The caret at the end of each of these lines, from the top ("down", "up" or "none"), once it is as expected, or
        /// as it is after 10 seconds: read in the window's picture, where its tip is under its ends or over them.
        func carets(_ lines: Int, until expected: [String]) -> [String] {
            var seen: [String] = []
            ViewHost.turn(10) { seen = drawn(lines); return seen == expected }
            return seen
        }
        private func drawn(_ lines: Int) -> [String] {
            let card = place
            guard let view = window.contentView, card != .zero else { return [] }
            view.layoutSubtreeIfNeeded()
            view.display()
            guard let picture = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return [] }
            view.cacheDisplay(in: view.bounds, to: picture)
            let scale = CGFloat(picture.pixelsWide) / view.bounds.width
            return (0..<lines).map { line -> String in
                // the picture counts from its top; the caret ends at the row's inset, 16 points from the card's edge
                let middle = view.bounds.height - card.maxY + card.height * (CGFloat(line) + 0.5) / CGFloat(lines)
                let across = Int((card.maxX - 30) * scale)..<Int((card.maxX - 14) * scale)
                let down = Int((middle - 9) * scale)..<Int((middle + 9) * scale)
                // the middle of the lit pixels of each column that has some: the card is at 0.16, the muted caret at 0.60
                let heights = across.compactMap { x -> Double? in
                    let lit = down.filter { y -> Bool in
                        (picture.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 0) > 0.32
                    }
                    return lit.isEmpty ? nil : Double(lit.reduce(0, +)) / Double(lit.count)
                }
                guard heights.count >= 4, let first = heights.first, let last = heights.last else { return "none" }
                return heights[heights.count / 2] > (first + last) / 2 ? "down" : "up"
            }
        }
    }

    private static func get(_ object: NSObject, _ name: String) -> Any? {
        object.responds(to: NSSelectorFromString(name)) ? object.perform(NSSelectorFromString(name))?.takeUnretainedValue() : nil
    }
    private static func object(_ body: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
    }
    private static func json(_ object: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: object)) ?? Data() }

    /// What a test reads of the app, on its main loop, while the app says that an assistive app reads it.
    private static func read<Seen: Sendable>(_ body: @escaping @MainActor () throws -> Seen) async throws -> Seen {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 200) { () -> Seen in
            let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            NSApp.accessibilitySetValue(true, forAttribute: enhanced)
            defer { NSApp.accessibilitySetValue(false, forAttribute: enhanced) }
            return try body()
        }
        #expect(screen.stayedHis)
        return seen
    }

    /// The form of a key request that proposes these levels, or Add secret for none, with its key typed already.
    @MainActor private static func form<Seen>(_ give: [String: String]?, _ body: (Form) throws -> Seen) throws -> Seen {
        let db = "access-fold-\(UUID().uuidString)", now = Int(Date().timeIntervalSince1970)
        let secret: [String: Any] = ["kind": "api_key", "env": "EXAMPLE_READ_KEY", "site": "https://api.example.com", "give": give ?? [:]]
        let state: [String: Any] = [
            "schema_version": 1, "db": db, "time": now, "tasks": [], "holds": [], "outcomes": [], "notes": [], "permissions": [],
            "messages": [], "reports": [], "ui_features": [SecretEntryView.feature, "secret_grants", CentralVault.feature],
            "agents": agents.map { ["name": $0.0, "role": $0.1, "runtime": "claude", "can": [String](), "placed": true] as [String: Any] },
            "needs": [["id": 91, "title": "Enter the API key EXAMPLE_READ_KEY", "why": "", "todo": "", "raised": now - 300,
                       "by": "manager", "answered": NSNull(), "kind": "secret", "secret": secret] as [String: Any]]]
        let hub = try LoopbackHub(state: json(state))
        defer { hub.stop() }
        let vault = json(["db": db, "fleet": fleet, "machines": [String](), "central": ["ok": true, "recipient": vaultKey] as [String: Any]])
        let lines = agents.map { $0.1 == "manager" ? ["agent": $0.0, "role": $0.1] : ["agent": $0.0, "role": $0.1, "reports_to": "manager"] }
        let team = json(["db": db, "revision": String(repeating: "a", count: 40), "sha256": String(repeating: "b", count: 64),
                         "lines": lines, "open_tasks": [String: Int](), "logins": [String: String]()])
        hub.answer("GET", "/ui/vault") { _ in (200, vault) }
        hub.answer("GET", "/ui/team") { _ in (200, team) }
        hub.answer("GET", "/ui/secrets/salts") { request in
            let login = URLComponents(string: "?\(request.query)")?.queryItems?.first { $0.name == "login" }?.value ?? ""
            let salt = String(repeating: "0", count: 32)
            return (200, json(["login": login, "password": salt, "totp": salt]))
        }
        _ = ViewHost.store(try HubState.decode(json(state)))        // the test's own defaults and folder
        AppDefaults.store.set(hub.address, forKey: "hubAddress")
        let store = FleetStore(), client = store.installation
        CentralVaultPins.pin(vaultKey, hub: store.hub, fleet: fleet)
        // each receipt says what was asked, and whose
        for path in ["/ui/secrets/add", "/ui/vault/intake", "/ui/secrets/grant"] {
            hub.answer("POST", path) { request in
                let asked = object(request.body), count = (asked["fingerprints"] as? [Any])?.count ?? 0
                return (200, json(asked.merging(["ok": true, "client": client, "stored": count, "known": 0, "changed": true]) { $1 }))
            }
        }
        Task { await store.refresh() }
        guard ViewHost.turn(15, until: { store.writesNow && store.state?.needs.isEmpty == false }), let need = store.state?.needs.first else {
            throw ViewHost.Missing(description: "the stand-in hub's reading did not come")
        }
        var preset = give == nil ? SecretPreset() : SecretPreset(need: need)
        preset.key = "example-value-1"
        preset.env = "EXAMPLE_READ_KEY"
        let kept = SecretValueKept(), size = NSSize(width: 640, height: 860)
        let view = NSHostingView(rootView: SecretEntryView(store: store, preset: preset, compact: give != nil, kept: kept) { _ in }
            .padding(20).frame(width: size.width, height: size.height, alignment: .top).preferredColorScheme(.dark))
        view.sizingOptions = []
        let window = ViewHost.window(showing: view, size: size)
        defer { ViewHost.close(window) }
        let form = Form(store: store, hub: hub, kept: kept, window: window)
        // the vault's answer comes after the first draw, and a form with no vault has no lines
        guard ViewHost.turn(20, until: { hub.requests.contains { $0.path == "/ui/vault" } && form.element(fold) != nil }) else {
            throw ViewHost.Missing(description: "the form does not show who can use the key")
        }
        return try body(form)
    }

    /// The bugs: a press opens the rows and nothing closes them, only the words or the caret take the press, the lines
    /// move or go while the rows are open, or Manage stands on the card or on Add secret again.
    @Test func aPressOnTheLinesOpensEachAgentsRowAndASecondPressClosesThem() async throws {
        struct Seen: Sendable { let open: Bool, stays: Bool, closed: Bool, manage: Bool }
        let seen = try await Self.read { () -> [Seen] in
            try [Self.bothRead, nil].map { give -> Seen in
                try Self.form(give) { form -> Seen in
                    let before = form.place, closedWords = form.words
                    form.click()
                    let open = form.opens(), after = form.place, openWords = form.words
                    form.click()
                    return Seen(open: open, stays: abs(before.maxY - after.maxY) < 1 && abs(before.height - after.height) < 1,
                                closed: form.closes(), manage: (closedWords + openWords).contains { $0.contains("Manage") })
                }
            }
        }
        for (form, seen) in zip(["a key request's card", "Add secret"], seen) {
            #expect(seen.open, "\(form): a press in the row opens the row of each worker and lead")
            #expect(seen.stays, "\(form): the lines stay at the top, as they were")
            #expect(seen.closed, "\(form): a second press closes the rows")
            #expect(!seen.manage, "\(form): no Manage")
        }
    }

    /// The bug: a close gives the rows back to the request's proposal, or forgets which of them he set himself.
    @Test func closingTheRowsChangesNoGrantOfAnyRow() async throws {
        struct Seen: Sendable { let set: Rows?, closed: Rows?, line: String, named: String }
        let seen = try await Self.read { () -> Seen in
            try Self.form(Self.bothRead) { form -> Seen in
                form.press(Self.fold)
                guard form.opens() else { throw ViewHost.Missing(description: "the rows did not open") }
                form.setRows()
                let set = form.shown
                form.press(Self.fold)
                guard form.closes() else { throw ViewHost.Missing(description: "the rows did not close") }
                return Seen(set: set, closed: form.shown, line: form.text("accessibilityLabel"),
                            named: "Uses it: \("cal".agentLabel); Reads it: \("ada".agentLabel)")
            }
        }
        #expect(seen.set == Rows(access: ["ada": .read, "cal": .use], touched: ["bea", "cal"], proposed: ["ada"]))
        #expect(seen.closed == seen.set, "each row is as he set it")
        #expect(seen.line == seen.named, "and the closed lines say so")
    }

    /// The bug: Save with the rows closed gives what the request proposed, or with the rows open another list.
    @Test func saveGivesWhatTheRowsSayOpenOrClosed() async throws {
        let seen = try await Self.read { () -> [[String]] in
            try [true, false].map { closed -> [String] in
                try Self.form(Self.bothRead) { form -> [String] in
                    form.press(Self.fold)
                    guard form.opens() else { throw ViewHost.Missing(description: "the rows did not open") }
                    form.setRows()
                    if closed {
                        form.press(Self.fold)
                        guard form.closes() else { throw ViewHost.Missing(description: "the rows did not close") }
                    }
                    return form.save()
                }
            }
        }
        #expect(seen == [["ada read", "cal use"], ["ada read", "cal use"]], "closed, then open")
    }

    /// The bugs: the caret stands on the first of two lines or on each line, a new key's line has none, or it does not
    /// turn as the rows open.
    @Test func theCaretStandsAtTheEndOfTheLastLine() async throws {
        let seen = try await Self.read { () -> [[String]] in
            let states: [(give: [String: String]?, lines: Int)] = [(Self.bothRead, 1), (["ada": "use", "bea": "read"], 2), (nil, 1)]
            return try states.flatMap { state -> [[String]] in
                try Self.form(state.give) { form -> [[String]] in
                    let none = Array(repeating: "none", count: state.lines - 1)
                    let closed = form.carets(state.lines, until: none + ["down"])
                    form.press(Self.fold)
                    _ = form.opens()
                    return [closed, form.carets(state.lines, until: none + ["up"])]
                }
            }
        }
        #expect(Array(seen.prefix(2)) == [["down"], ["up"]], "one line")
        #expect(Array(seen.dropFirst(2).prefix(2)) == [["none", "down"], ["none", "up"]], "Uses it, then Reads it")
        #expect(Array(seen.suffix(2)) == [["down"], ["up"]], "Add secret: No agent")
    }

    /// The bugs: the one element of the lines says nothing of its state, or VoiceOver's press on it does nothing (the
    /// fault that the rows of a job's card had), or the lines are elements of their own beside it.
    @Test func voiceOverReadsOneButtonThatSaysWhetherTheRowsAreOpen() async throws {
        struct Seen: Sendable { let role: String, label: String, named: String, values: [String], took: Bool, parts: Int }
        let seen = try await Self.read { () -> [Seen] in
            try [Self.bothRead, nil].map { give -> Seen in
                try Self.form(give) { form -> Seen in
                    let start = give == nil ? "No agent" : "Reads it"
                    let parts = form.words.filter { $0.contains { $0.hasPrefix(start) } }.count
                    var values = [form.text("accessibilityValue")]
                    let took = form.press(Self.fold)
                    for state in ["Open", "Closed"] {
                        if state == "Closed" { form.press(Self.fold) }
                        ViewHost.turn(10) { form.text("accessibilityValue") == state }
                        values.append(form.text("accessibilityValue"))
                    }
                    return Seen(role: form.text("accessibilityRole"), label: form.text("accessibilityLabel"),
                                named: give == nil ? start : "\(start): \("ada".agentLabel), \("bea".agentLabel)",
                                values: values, took: took, parts: parts)
                }
            }
        }
        for seen in seen {
            #expect(seen.role == NSAccessibility.Role.button.rawValue && seen.parts == 1, "one button: \(seen)")
            #expect(seen.label == seen.named)
            #expect(seen.took, "it takes VoiceOver's press")
            #expect(seen.values == ["Closed", "Open", "Closed"])
        }
    }

    /// **Each agent's face keeps its own name under the pointer**, closed and open (the owner, 21 November 2026: the
    /// names on hover). On macOS an outer hover wins over an inner one, also an empty one, so hover words on the press
    /// that holds the faces would show "Show each agent with its access", or nothing, on each face. The bugs: `.help` on
    /// the press (`accessFold`), or the words on no part of the lines and no hint for VoiceOver. Read from the source, as
    /// `DarkLookTests` finds the app's windows: no view test can move a pointer over a face.
    @Test func eachFaceKeepsItsOwnNameUnderThePointer() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Founderizer/SecretEntryView.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        func body(from start: String, to end: String) throws -> String {
            let from = try #require(text.range(of: start), "\(start) is in the file")
            let to = try #require(text.range(of: end, range: from.upperBound..<text.endIndex), "\(end) follows it")
            return String(text[from.lowerBound..<to.lowerBound])
        }
        let press = try body(from: "private var accessFold: some View {", to: "private var foldHint: Text")
        #expect(!press.contains(".help("), "the press itself has no hover words")
        #expect(press.contains(".accessibilityHint(foldHint)"), "VoiceOver hears the words as the hint")
        let line = try body(from: "private func accessLine(", to: "private var noAgentLine: some View {")
        #expect(line.components(separatedBy: ".help(foldHint)").count - 1 == 2, "the level's mark and word, and the caret")
        let none = try body(from: "private var noAgentLine: some View {", to: "private func accessRow(")
        #expect(none.components(separatedBy: ".help(foldHint)").count - 1 == 2, "No agent, and its caret")
    }
}
