import AppKit
import FleetCore
import SwiftUI
import Testing
import Vision
@testable import Founderizer

/// **The Where row of Settings › Backup holds its sizes and its two buttons at the app's least width** (F14 piece 5;
/// the area App shell and look's route for the picture that the row owed, 22 November 2026). The row's detail is the
/// folder and what its copies weigh ("iCloud Drive › Founderizer · last copy 1.2 GB, 7 copies 8.4 GB"), the longest
/// words the row has; the page is drawn whole in a window of 960 points, the least that the app's window takes
/// (`FounderizerApp`), in English and in the catalog's Spanish. Its words must all show, and both buttons must stand
/// inside the row. The bugs that it catches: a detail cut to one line, and a button pushed out of its row.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct BackupWhereRowTests {
    struct Seen: Sendable {
        let language: String
        /// The sizes part of the row's words, as the app writes it in that language.
        let sizes: String
        let read: String
        let buttons: Int
        let buttonsInRow: Bool
        let rowInWindow: Bool
    }

    private static func need<T>(_ value: T?, _ what: String) throws -> T {
        guard let value else { throw ViewHost.Missing(description: what) }
        return value
    }

    /// The Spanish of the app's catalog as a table for this task, as `SpanishTable` of FleetCoreTests makes it.
    private static func spanish(in root: URL) throws -> Bundle {
        let catalog = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Localization/Localizable.xcstrings")
        let json = try need(JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [String: Any], "the catalog")
        let strings = try need(json["strings"] as? [String: [String: Any]], "the catalog's words")
        var lines: [String] = []
        for (key, entry) in strings {
            let unit = ((entry["localizations"] as? [String: Any])?["es"] as? [String: Any])?["stringUnit"] as? [String: Any]
            guard let value = unit?["value"] as? String else { continue }
            func escaped(_ text: String) -> String {
                text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                    .replacingOccurrences(of: "\n", with: "\\n")
            }
            lines.append("\"\(escaped(key))\" = \"\(escaped(value))\";")
        }
        let folder = root.appendingPathComponent("table/es.lproj")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: folder.appendingPathComponent("Localizable.strings"), atomically: true,
                                                encoding: .utf8)
        return try need(Bundle(url: folder), "the Spanish table")
    }

    /// Every line of words that the picture shows, read as a person reads them, joined with one space.
    @MainActor private static func words(in view: NSView, languages: [String]) throws -> (String, NSBitmapImageRep?) {
        view.layoutSubtreeIfNeeded()
        view.display()
        guard let picture = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return ("", nil) }
        view.cacheDisplay(in: view.bounds, to: picture)
        guard let image = picture.cgImage else { return ("", picture) }
        let reading = VNRecognizeTextRequest()
        reading.recognitionLevel = .accurate
        reading.recognitionLanguages = languages
        reading.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([reading])
        let text = (reading.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        return (text, picture)
    }

    /// The accessibility frames, on the screen, of the elements with these identifiers.
    @MainActor private static func frames(in host: NSView, _ names: Set<String>) -> [String: [NSRect]] {
        var queue: [NSObject] = [host], found: [String: [NSRect]] = [:]
        while !queue.isEmpty {
            let object = queue.removeFirst()
            if let element = object as? NSAccessibilityElementProtocol & NSObject,
               object.responds(to: NSSelectorFromString("accessibilityIdentifier")),
               let name = object.perform(NSSelectorFromString("accessibilityIdentifier"))?.takeUnretainedValue() as? String,
               names.contains(name) {
                found[name, default: []].append(element.accessibilityFrame())
            }
            let children = object.responds(to: NSSelectorFromString("accessibilityChildren"))
                ? object.perform(NSSelectorFromString("accessibilityChildren"))?.takeUnretainedValue() as? [Any] : nil
            queue += (children ?? []).compactMap { $0 as? NSObject }
        }
        return found
    }

    @MainActor private static func look(_ language: String, folder: URL) throws -> Seen {
        let state = try ViewHost.reading(needs: [], features: ["health", "restore"])
        _ = ViewHost.store(state)                                   // the test's own defaults, emptied
        let gib: Int64 = 1 << 30
        let kept = CopyFolder.Kept(newest: gib + gib / 5, count: FleetCopyKeeper.keeps, total: 8 * gib + 2 * gib / 5)
        AppDefaults.store.set(try folder.bookmarkData(), forKey: "copyFolder")
        CopyKept.keep(sizes: kept, hub: "http://127.0.0.1:9", in: AppDefaults.store)      // the address of ViewHost.store
        let store = FleetStore()
        store.state = state
        store.destination = .settings(.backup)
        let window = ViewHost.window(store, size: NSSize(width: 960, height: 760))
        defer { ViewHost.close(window) }
        let host = try need(window.contentView, "the window's view")
        ViewHost.turn(1)
        let words = try need(CopyFolder.whereWords(folder: folder.lastPathComponent, kept: kept), "the row's words")
        let sizes = String(words.split(separator: "·", maxSplits: 1).last ?? "").trimmingCharacters(in: .whitespaces)
        var found: [String: [NSRect]] = [:]
        ViewHost.turn(10) {
            found = Self.frames(in: host, ["copy-where", "copy-icloud", "copy-folder"])
            return found["copy-where"]?.isEmpty == false && found["copy-folder"]?.isEmpty == false
        }
        let (read, picture) = try Self.words(in: host, languages: language == "es" ? ["es-ES", "en-US"] : ["en-US"])
        if let pictures = ProcessInfo.processInfo.environment["FOUNDERIZER_PICTURES"],
           let png = picture?.representation(using: .png, properties: [:]) {
            try FileManager.default.createDirectory(atPath: pictures, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: pictures).appendingPathComponent("where-row-\(language).png"))
        }
        let row = found["copy-where"]?.first ?? .zero
        let buttons = (found["copy-icloud"] ?? []) + (found["copy-folder"] ?? [])
        return Seen(language: language, sizes: sizes, read: read, buttons: buttons.count,
                    buttonsInRow: !buttons.isEmpty && buttons.allSatisfy { row.contains($0) },
                    rowInWindow: row != .zero && window.frame.contains(row))
    }

    /// The sizes are those of the hub that the app shows: a second hub has its own, and the keeper shows them after a
    /// connect to it and one look (the validator's M1 of 23 November 2026). The bug that it catches: the keeper goes on
    /// with the first hub's sizes, or a connect takes them for the second hub's.
    @Test func theSizesAreOfTheHubThatTheAppShows() async throws {
        let mib: Int64 = 1 << 20
        let first = CopyFolder.Kept(newest: 117 * mib, count: 7, total: 822 * mib)
        let second = CopyFolder.Kept(newest: 3 * mib, count: 1, total: 3 * mib)
        let early = Date(timeIntervalSince1970: 1_792_400_000), later = Date(timeIntervalSince1970: 1_792_500_000)
        struct Shown: Sendable, Equatable { let sizes: CopyFolder.Kept?; let at: Date?; let failure: String? }
        let (shown, _) = try await ViewHost.onMainLoop(limit: 60) { () -> [Shown] in
            let state = try ViewHost.reading(needs: [], features: ["health", "restore"])
            _ = ViewHost.store(state)
            CopyKept.keep(sizes: first, hub: "http://127.0.0.1:9", in: AppDefaults.store)
            CopyKept.keep(at: early, hub: "http://127.0.0.1:9", database: state.db, in: AppDefaults.store)
            CopyKept.keep(sizes: second, hub: "http://127.0.0.1:10", in: AppDefaults.store)
            CopyKept.keep(at: later, hub: "http://127.0.0.1:10", database: state.db, in: AppDefaults.store)
            CopyKept.keep(failure: "The hub refused the copy.", at: later, hub: "http://127.0.0.1:10", in: AppDefaults.store)
            // The copies off: a tick takes no copy and makes no folder of the Mac's (the second reader's R16-1); what is
            // shown and what the generation check does come before that switch.
            AppDefaults.store.set(false, forKey: "copyAutomatic")
            let store = FleetStore()
            store.state = state
            let look = { Shown(sizes: store.copies.kept, at: store.copies.schedule.keptAt, failure: store.copies.schedule.failure) }
            // A tick of the first hub, with its own generation: its values stay (the validator's M4: a check of the
            // generation that forgot at each tick would take a copy at each one).
            Task { await store.copies.tick(store: store) }
            ViewHost.turn(1)
            let before = look()
            store.addressText = "http://127.0.0.1:10"
            // no hub answers there: the app's hub is that address all the same, as soon as the connect starts
            Task { await store.connect() }
            ViewHost.turn(10) { store.hub.absoluteString.hasPrefix("http://127.0.0.1:10") }
            Task { await store.copies.tick(store: store) }
            ViewHost.turn(10) { store.copies.kept == second }
            return [before, look()]
        }
        // The first hub's time, sizes and no failure; then the second hub's, with its own failure (R15-1, R15-4).
        #expect(shown == [Shown(sizes: first, at: early, failure: nil),
                          Shown(sizes: second, at: later, failure: "The hub refused the copy.")])
    }

    /// **The records at a hub's address are another fleet's now** (a server rebuilt or restored there, whose generation
    /// moved): the app forgets the time, the sizes and the failure that it kept for the fleet before (R15-2), so the new
    /// fleet's page says none of its copies and its first copy is due at once. The bug that it catches: the restored
    /// fleet's page says "1 copy, 0.2 MB" of the empty hub, and its first copy waits a day.
    @Test func aHubWhoseRecordsMovedIsForgotten() async throws {
        let mib: Int64 = 1 << 20
        let (shown, _) = try await ViewHost.onMainLoop(limit: 60) { () -> [Bool] in
            let state = try ViewHost.reading(needs: [], features: ["health", "restore"])
            _ = ViewHost.store(state)
            let hub = "http://127.0.0.1:9"
            CopyKept.keep(sizes: CopyFolder.Kept(newest: mib, count: 1, total: mib), hub: hub, in: AppDefaults.store)
            CopyKept.keep(at: Date(), hub: hub, database: "the-empty-hub", in: AppDefaults.store)
            AppDefaults.store.set(false, forKey: "copyAutomatic")       // no copy, no folder of the Mac's (R16-1)
            let store = FleetStore()
            store.state = state
            let before = store.copies.kept != nil && store.copies.schedule.keptAt != nil
            Task { await store.copies.tick(store: store) }
            ViewHost.turn(10) { store.copies.kept == nil }
            return [before, store.copies.kept == nil, store.copies.schedule.keptAt == nil,
                    CopyKept.database(hub: hub, in: AppDefaults.store) == nil]
        }
        #expect(shown == [true, true, true, true])
    }

    @Test func theWhereRowHoldsItsSizesAndItsButtonsAtTheLeastWidth() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 90) { () -> [Seen] in
            let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            NSApp.accessibilitySetValue(true, forAttribute: enhanced)
            defer { NSApp.accessibilitySetValue(false, forAttribute: enhanced) }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("where-\(UUID().uuidString)")
            let folder = root.appendingPathComponent("iCloud Drive › Founderizer")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let english = try Self.look("en", folder: folder)
            let spanish = try Localized.$bundle.withValue(try Self.spanish(in: root)) { try Self.look("es", folder: folder) }
            return [english, spanish]
        }
        let both = FleetCopyKeeper.iCloudDrive != nil ? 2 : 1     // Use iCloud Drive shows on a Mac that has it
        for one in seen {
            let read = one.read.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            for part in one.sizes.components(separatedBy: ", ") {     // "1,2 GB" keeps its decimal comma
                let words = part.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                    .split(whereSeparator: \.isWhitespace).joined(separator: " ")
                #expect(read.contains(words), "\(one.language): \"\(words)\" is not whole on the page: \(one.read)")
            }
            #expect(one.buttons == both, "\(one.language): \(one.buttons) buttons on the row")
            #expect(one.buttonsInRow, "\(one.language): a button stands outside the Where row")
            #expect(one.rowInWindow, "\(one.language): the Where row stands outside the window")
        }
        #expect(seen.count == 2 && seen[1].sizes != seen[0].sizes, "the Spanish page has the Spanish words")
        #expect(screen.stayedHis)
    }
}
