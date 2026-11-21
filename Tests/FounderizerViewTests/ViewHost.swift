import AppKit
import os
import FleetCore
import SwiftUI
import Testing
import Vision
@testable import Founderizer

/// **The room of the tests of the Mac app's views** (the areas App shell and look and Release, ship and tests, 21
/// November 2026): the real views, in a window that no screen shows, of an app that never comes in front.
///
/// - Once for each test process, before anything reads them: the app's defaults are a test's own (`TestDefaults`, in a
///   temporary folder) and its folder is that folder (`AppDefaults`, `AppFolders`), so no test reads or writes the
///   owner's settings, outbox or kept readings. The hub's address is one where no server answers (port 9 of this
///   Mac), so no read reaches a hub. The folder goes when the process ends.
/// - Each test has one window (`window`), and closes it at its end (`close`): borderless, clear (alpha 0) and far off
///   every screen, with the identifier of the app's main window, as the code that looks for the main window finds it.
///   It is the key window by its own word, so the app is never activated. Events go to it through `NSApp.sendEvent`,
///   which runs the app's own key monitors, never through the window server.
/// - A test's body runs from the main run loop itself (`onMainLoop`), as AppKit runs the app's events, and gives back
///   what it saw; the test checks it after. `Screen` says whether the owner's screen stayed his.
/// - The views draw English, whatever the Mac's language: in a test process `Localized.bundle` is the test program's
///   own bundle, which holds no table of the app's languages, so each word is its English key (`ready` checks it).
///   A test names a word as the app writes it (`String(l10n:)`), and Vision reads English (`middle`).
/// - A test waits for what it reads, never for a time: on a busy Mac it takes longer, never wrongly (`turn`, `middle`).
/// - Not behind the seam: the setup diagnosis that a store starts (`SetupChannel.attach`) reads, never writes,
///   whether agent programs exist under the home folder (`AgentPrograms.found`). A test of that diagnosis needs a seam
///   for it first.
@MainActor enum ViewHost {
    private static let ready: Void = {
        let defaults = TestDefaults("founderizer-views")
        AppDefaults.use(defaults)
        AppFolders.use(support: defaults.folder)
        defaults.set("http://127.0.0.1:9", forKey: "hubAddress")
        kept = defaults
        madeFolder = defaults.folder.path
        atexit { if let folder = madeFolder { try? FileManager.default.removeItem(atPath: folder) } }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        // the queue of the app's events runs, so that a key that a view posts again comes back through it
        NSApp.finishLaunching()
        precondition(Set(Localized.bundle.localizations).isSubset(of: ["en", "Base"]),
                     "the views of a test draw English: the bundle of the app's words holds another language")
    }()
    private static var kept: TestDefaults?

    /// A hub's reading with the manager and the items given, on a hub that names the features given. Each reading is
    /// of a database of its own, so that what the app keeps in memory by hub and database (a card's unsent words) is
    /// not an earlier test's.
    static func reading(needs: [[String: Any]], features: [String]) throws -> HubState {
        let agents: [[String: Any]] = [["name": "manager", "role": "manager", "runtime": "claude", "can": [],
                                        "placed": true]]
        let state: [String: Any] = ["schema_version": 1, "db": "view-test-\(UUID().uuidString)",
                                    "time": Int(Date().timeIntervalSince1970),
                                    "agents": agents, "tasks": [], "holds": [], "outcomes": [], "notes": [],
                                    "needs": needs, "permissions": [], "messages": [], "reports": [],
                                    "ui_features": features]
        return try HubState.decode(JSONSerialization.data(withJSONObject: state))
    }

    /// A store of the app on the test's defaults and folder, with a reading in place of the hub's first answer. The
    /// defaults hold only the hub's address: no draft or choice of an earlier test.
    static func store(_ state: HubState) -> FleetStore {
        _ = ready
        if let kept {
            for key in kept.dictionaryRepresentation().keys { kept.removeObject(forKey: key) }
            kept.set("http://127.0.0.1:9", forKey: "hubAddress")
        }
        let store = FleetStore()
        store.state = state
        return store
    }

    /// The app's main window for one test, drawn and laid out.
    static func window(_ store: FleetStore, size: NSSize = NSSize(width: 1180, height: 900)) -> NSWindow {
        _ = ready
        let host = NSHostingView(rootView: FleetView(store: store)
            .environment(\.glyphTeam, store.state?.agents.map(\.name) ?? [])
            .frame(width: size.width, height: size.height))
        host.sizingOptions = []
        let window = KeyWindow(contentRect: NSRect(origin: NSPoint(x: -40000, y: -40000), size: size),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.identifier = NSUserInterfaceItemIdentifier(SetupChannel.fleetWindow)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        window.orderFront(nil)
        window.makeKey()
        turn(0.2)                       // its first draw; a test then waits for what it reads (`middle`)
        return window
    }

    /// The end of a test's window, and of what its store kept in the test's folder (an outbox's request).
    static func close(_ window: NSWindow) {
        window.identifier = nil         // no wait of the app finds it as its main window after the test
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        try? FileManager.default.removeItem(at: AppFolders.support.appendingPathComponent("Founderizer"))
    }

    /// **A test's body, run from the main run loop itself**, on the main thread, as AppKit runs the app's events: its
    /// waits (`turn`) run the main actor's tasks and the view's draws, as the app's own run loop does. A test on the
    /// main actor runs as a job of the main queue, and inside such a job the run loop serves no other job of it: the
    /// tasks of the views wait until the test ends. `Seen` comes back, with the state of the owner's screen before and
    /// after the body; the test checks both after (an issue is a test's own, and the run loop's block is not in it).
    /// A body that has not ended in `limit` seconds fails the test, and ends no run (its result, if it comes later,
    /// is dropped).
    nonisolated static func onMainLoop<Seen: Sendable>(limit: Double = 50,
                                                       _ body: @escaping @MainActor () throws -> Seen) async throws
        -> (seen: Seen, screen: Screen) {
        try await withCheckedThrowingContinuation { (waiting: CheckedContinuation<(seen: Seen, screen: Screen), Error>) in
            let once = Once(waiting)
            DispatchQueue.global().asyncAfter(deadline: .now() + limit) {
                once.resume(throwing: Missing(description: "the test's body did not end in \(Int(limit)) s"))
            }
            let done = once
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
                MainActor.assumeIsolated {
                    _ = ready
                    let before = Screen.now
                    var cameActive = false
                    let watch = NotificationCenter.default.addObserver(
                        forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in cameActive = true }
                    defer { NotificationCenter.default.removeObserver(watch) }
                    do {
                        let seen = try body()
                        done.resume(returning: (seen, Screen(before: before, after: Screen.now, cameActive: cameActive)))
                    } catch { done.resume(throwing: error) }
                }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    /// The test's wait, resumed once: by its body, or by the time limit, whichever comes first.
    private final class Once<Value: Sendable>: Sendable {
        private let waiting: OSAllocatedUnfairLock<CheckedContinuation<Value, Error>?>

        init(_ waiting: CheckedContinuation<Value, Error>) { self.waiting = OSAllocatedUnfairLock(initialState: waiting) }

        func resume(returning value: Value) { take()?.resume(returning: value) }
        func resume(throwing error: Error) { take()?.resume(throwing: error) }

        private func take() -> CheckedContinuation<Value, Error>? {
            waiting.withLock { waiting in
                defer { waiting = nil }
                return waiting
            }
        }
    }

    /// **The owner's screen stayed his**: the app in front was not this process before the body or after it, and
    /// this process never became the active app, also not for a moment during the body (the app's own code asks for
    /// the front on some paths, as for a click that it drops: the policy "prohibited" refuses it).
    struct Screen: Sendable {
        let stayedHis: Bool

        fileprivate static var now: (front: pid_t?, active: Bool) {
            (NSWorkspace.shared.frontmostApplication?.processIdentifier, NSApp.isActive)
        }

        fileprivate init(before: (front: pid_t?, active: Bool), after: (front: pid_t?, active: Bool), cameActive: Bool) {
            let me = ProcessInfo.processInfo.processIdentifier
            stayedHis = before.front != me && after.front != me && !before.active && !after.active && !cameActive
        }
    }

    /// A step of a test that cannot go on: the words say which.
    struct Missing: Error, CustomStringConvertible {
        let description: String
    }

    /// **The middle of these words where the window shows them, in the window's own points**, found as a person finds
    /// them: in the window's picture, by the Mac's own text recognition (Vision, on this Mac, with no network), in
    /// English, as the views draw it here. A SwiftUI window makes no accessibility elements in a process that no
    /// assistive app reads, so they cannot be asked. Give the words as the app writes them (`String(l10n:)`). It waits,
    /// up to `seconds`, until the window shows them.
    static func middle(of words: String, in window: NSWindow, seconds: Double = 20) throws -> NSPoint? {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            if let found = try read(words, in: window) { return found }
            turn(0.3)
        } while Date() < end
        return nil
    }

    private static func read(_ words: String, in window: NSWindow) throws -> NSPoint? {
        guard let view = window.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        view.display()
        guard let picture = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: picture)
        guard let image = picture.cgImage else { return nil }
        let reading = VNRecognizeTextRequest()
        reading.recognitionLevel = .accurate
        reading.recognitionLanguages = ["en-US"]      // the views draw English (`ready`)
        reading.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([reading])
        for line in reading.results ?? [] {
            for text in line.topCandidates(3) {
                guard let range = text.string.range(of: words, options: [.caseInsensitive, .diacriticInsensitive]),
                      let box = try text.boundingBox(for: range)?.boundingBox else { continue }
                // the picture's share of its width and height, from its lower left corner, as the window counts points
                return NSPoint(x: box.midX * view.bounds.width, y: box.midY * view.bounds.height)
            }
        }
        return nil
    }

    /// A press of the pointer at a point of the window: its down and its up.
    static func click(_ point: NSPoint, in window: NSWindow) -> [NSEvent] {
        [NSEvent.EventType.leftMouseDown, .leftMouseUp].compactMap { type in
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
        }
    }

    /// The keys of these words, a down and an up for each; "\r" is Return.
    static func keys(_ words: String, in window: NSWindow) -> [NSEvent] {
        let codes: [Character: UInt16] = ["h": 4, "e": 14, "l": 37, "o": 31, "k": 40, "2": 19, " ": 49, "\r": 36]
        return words.flatMap { character in
            guard let code = codes[character] else {
                preconditionFailure("ViewHost.keys: no key code for \(character.debugDescription); add it to the table")
            }
            return [NSEvent.EventType.keyDown, .keyUp].compactMap { type in
                NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                 context: nil, characters: String(character),
                                 charactersIgnoringModifiers: String(character), isARepeat: false,
                                 keyCode: code)
            }
        }
    }

    /// **A busy Mac**: the events, one after the other, with no turn of the app between them, as an app that was
    /// held takes what waited in its queue. No view is drawn and no task runs between them.
    static func atOnce(_ events: [NSEvent]) {
        for event in events { NSApp.sendEvent(event) }
    }

    /// The app runs (`onMainLoop`) for this long, or until `done` is true: its tasks on the main actor, its draws, and
    /// the events that a view posted again. A busy Mac takes longer, so a test waits for what it reads, not for a time.
    @discardableResult
    static func turn(_ seconds: Double, until done: () -> Bool = { false }) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            while let event = NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
        return done()
    }

    /// The text of the field that has the keys, if a field has them.
    static func fieldWords(in window: NSWindow) -> String? {
        (window.firstResponder as? NSTextView)?.string
    }
}

/// The key window of an app that is not in front: AppKit gives the keys to the key window, and an app that is not
/// active has none.
private final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    /// While it stands, as the app's one window does; a closed test's window is no key window.
    override var isKeyWindow: Bool { isVisible }
}

nonisolated(unsafe) private var madeFolder: String?
