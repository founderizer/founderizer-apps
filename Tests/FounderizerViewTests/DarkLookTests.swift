import AppKit
import FleetCore
import SwiftUI
import Testing
@testable import Founderizer

/// **Every window of the app draws in its dark look, also on a Mac in Light mode** (the area App shell and look, 21
/// November 2026). The app is dark only (UI-PATTERNS.md, "Appearance"): its views draw their own grounds, #191919 and
/// #282828, and what follows the system (a dropdown's selected value, a switch, a field) takes its colour from the
/// window's look. AppKit gives a window the Mac's look unless it sets its own, and the main window's
/// `.preferredColorScheme(.dark)` sets that window's alone: on a customer's Mac in Light mode the words of the
/// dropdowns of a Drive account's card were black on the dark card, because the card's window (`fleetModal`) set none.
@Suite(.serialized, .timeLimit(.minutes(1))) struct DarkLookTests {
    struct Seen: Sendable {
        /// The look of the main window and of each window over it: "dark" or "light".
        let looks: [String]
        /// The lightest point of each dropdown's words, from 0 (black) to 1 (white); -1 where they were not read.
        let words: [String: Double]
    }

    /// The card of a Drive account, opened from its row, on a Mac in Light mode: its words read light, as on a Mac in
    /// Dark mode. The two dropdowns are the ones of the customer's report: an agent's level and "Who may give it".
    @Test func aCardOverTheWindowDrawsItsWordsLightOnAMacInLightMode() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop { () -> Seen in
            // the Mac's look as the app reads it: Light mode (the Mac's own setting does not change)
            NSApp.appearance = NSAppearance(named: .aqua)
            defer { NSApp.appearance = nil }
            let store = ViewHost.store(try Self.reading())
            store.keep(Self.resources(), as: AccessSettings.name(nil))
            store.destination = .app(.drive)
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            guard let row = try ViewHost.middle(of: "team@example.com", in: window) else {
                throw ViewHost.Missing(description: "the account's row on Settings › Apps › Google Drive")
            }
            ViewHost.atOnce(ViewHost.click(row, in: window))
            ViewHost.turn(10) { (window.childWindows ?? []).contains(where: \.isVisible) }
            guard let card = window.childWindows?.last else { throw ViewHost.Missing(description: "the account's card") }
            var words: [String: Double] = [:]
            for value in ["No access", "You and the fleet manager"] {
                words[value] = try ViewHost.middle(of: value, in: card, seconds: 8).map { Self.lightest(around: $0, in: card) } ?? -1
            }
            let looks = ([window] + (window.childWindows ?? [])).map {
                $0.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
            }
            return Seen(looks: looks, words: words)
        }
        #expect(seen.looks == ["dark", "dark"], "the main window and the card's window draw dark")
        for (value, light) in seen.words.sorted(by: { $0.key < $1.key }) {
            #expect(light > 0.6, "the dropdown's words \"\(value)\" read light on the dark card (\(light))")
        }
        #expect(screen.stayedHis)
    }

    /// **Each window that the app makes sets the dark look itself, and each scene of the app takes the dark scheme.**
    /// The windows are found in the app's source, as `OwnerShowRulesTests` finds the app's event watches: a window of
    /// the app shows only when a person does something (a card, a list, a hover, a request's own window), so no view
    /// test opens each one, and a new window takes the Mac's look by itself. A window that is added fails here until
    /// it sets the look and is on the list. The system's own windows (About, Check for Updates, an open or save panel,
    /// Quick Look) draw their own ground and words in the Mac's look, so their words read in both.
    @Test func everyWindowThatTheAppMakesTakesTheDarkLook() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Founderizer")
        let texts = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
        func matches(_ pattern: String, in text: String) throws -> [[String]] {
            try NSRegularExpression(pattern: pattern).matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
                (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
            }
        }
        // AppKit's two kinds of window, and the app's own
        var kinds: Set<String> = ["NSPanel", "NSWindow"]
        for (_, text) in texts { for match in try matches(#"class (\w+): (?:NSPanel|NSWindow)\b"#, in: text) { kinds.insert(match[1]) } }
        var found: [String] = []
        for (file, text) in texts {
            for match in try matches(#"(?:(?:let|var) (\w+)\s*=\s*)?\b(\w+)\((?:contentRect|contentViewController):"#, in: text)
                where kinds.contains(match[2]) {
                let dark = !match[1].isEmpty && text.contains("\(match[1]).appearance = NSAppearance(named: .darkAqua)")
                found.append("\(file): \(match[2])" + (dark ? "" : ", without the dark look"))
            }
        }
        #expect(found == [
            "AnsweredMarkView.swift: TagPanel",         // an answered mark's hover tag (`HoverTag`)
            "FleetMenu.swift: FleetMenuPanel",          // every list and right-click menu (`FleetMenu`)
            "FormRows.swift: ModalPanel",               // the card over the window (`fleetModal`)
            "NeedWindow.swift: NeedPanel",              // a request's own window (`NeedWindows`)
        ])
        // The windows that SwiftUI makes: each scene's root view takes the dark scheme, which sets its window's look.
        var scenes: [String] = []
        for (file, text) in texts {
            // a scene starts its line; a comment that names one does not
            let starts = try NSRegularExpression(pattern: #"(?m)^[ \t]*(?:Window|WindowGroup)\(""#)
                .matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
            for (index, start) in starts.enumerated() {
                let scene = text[start.lowerBound..<(index + 1 < starts.count ? starts[index + 1].lowerBound : text.endIndex)]
                let name = scene.drop { $0 == " " || $0 == "\t" }.prefix { $0 != "," && $0 != ")" }
                scenes.append("\(file): \(name)" + (scene.contains(".preferredColorScheme(.dark)") ? "" : ", without the dark scheme"))
            }
        }
        #expect(scenes == ["FounderizerApp.swift: Window(\"Founderizer\"", "FounderizerApp.swift: Window(\"Report a problem\""])
    }

    /// The lightest point of the words around `middle` (the window's points, from its lower left corner), in the card's
    /// picture: the middle of the words and 14 points to each side of it, which stays inside the words of a dropdown.
    @MainActor static func lightest(around middle: NSPoint, in card: NSWindow) -> Double {
        guard let view = card.contentView, let picture = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return -1 }
        view.cacheDisplay(in: view.bounds, to: picture)
        let scale = CGFloat(picture.pixelsWide) / view.bounds.width
        var lightest = 0.0
        for x in stride(from: middle.x - 14, through: middle.x + 14, by: 0.5) {
            for y in stride(from: middle.y - 4, through: middle.y + 4, by: 0.5) {
                guard let colour = picture.colorAt(x: Int(x * scale), y: Int((view.bounds.height - y) * scale))?
                    .usingColorSpace(.sRGB) else { continue }
                lightest = max(lightest, Double(0.2126 * colour.redComponent + 0.7152 * colour.greenComponent
                                                + 0.0722 * colour.blueComponent))
            }
        }
        return lightest
    }

    /// A fleet of a manager and two agents, on a hub that lists its resources and its Google accounts.
    static func reading() throws -> HubState {
        let agents: [[String: Any]] = [
            ["name": "manager", "role": "manager", "runtime": "claude", "can": [], "placed": true],
            ["name": "ada", "role": "worker", "runtime": "claude", "can": [], "placed": true],
            ["name": "bob", "role": "worker", "runtime": "claude", "can": [], "placed": true]]
        let state: [String: Any] = ["schema_version": 1, "db": "view-test-\(UUID().uuidString)",
                                    "time": Int(Date().timeIntervalSince1970),
                                    "agents": agents, "tasks": [], "holds": [], "outcomes": [], "notes": [],
                                    "needs": [], "permissions": [], "messages": [], "reports": [],
                                    "ui_features": [ResourceList.feature, Google.feature]]
        return try HubState.decode(JSONSerialization.data(withJSONObject: state))
    }

    /// One Drive account that Ada holds at Read, and that the manager may give at Read.
    static func resources() -> ResourceList {
        let levels = GoogleService.drive.levels.map(\.rawValue)
        let account = FleetResource(id: "drive:team@example.com", kind: "drive", what: "team@example.com",
                                    title: "team@example.com", needs: "files to read", levels: levels, uses: [],
                                    credential: "google", connected: true,
                                    grant: .init(max: "read", to: ResourceList.everyone),
                                    holders: [ResourceHolder(agent: "ada", level: "read")])
        return ResourceList(db: "view-test", revision: nil, sha256: "0", audience: "owner", limit: 50,
                            kinds: [ResourceKind(kind: "drive", title: "Google Drive", word: "Google Drive account",
                                                 levels: levels, needs: "files to read")],
                            resources: [account])
    }
}
