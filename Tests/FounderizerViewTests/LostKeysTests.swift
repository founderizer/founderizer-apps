import AppKit
import Testing

/// **A key that no view takes is kept and plays no sound, and a key that a responder takes still reaches it**
/// (`LostKeys`; the area Release, ship and tests, 22 November 2026). The bugs that these catch: a key of a test that goes
/// nowhere plays the Mac's alert sound, in each ship run that runs the view tests, and no test sees it; and a catch that
/// keeps a command or typed text that AppKit's own would pass on, as Esc from a field to the window's own
/// `cancelOperation:`, so a view test would no longer see what the app does. With a catch taken out, AppKit plays the
/// sound and keeps nothing. The sound itself is out of a test's reach: its proof is a `log stream` of `NSBeep` while the
/// suites run.
@Suite(.serialized, .timeLimit(.minutes(1))) struct LostKeysTests {
    /// A responder at the end of a window's chain that takes one command, the start of a line, and typed text, and says
    /// what it took.
    private final class Taker: NSResponder {
        var took: [String] = []

        override func moveWordLeft(_ sender: Any?) { took.append("moveWordLeft:") }
        override func moveToBeginningOfLine(_ sender: Any?) { took.append("moveToBeginningOfLine:") }
        override func insertText(_ insertString: Any) { took.append("insertText: \(insertString)") }
    }

    /// A local key monitor of the test: it takes a key down of its window, as FleetView's monitor takes one of its own
    /// window, and says what it took.
    @MainActor private final class Watcher {
        var window: NSWindow?
        var saw: [String] = []

        func takes(_ event: NSEvent) -> Bool {
            guard let window, event.window === window else { return false }
            saw.append(event.characters ?? "")
            return true
        }
    }

    /// A plain window that stands (ordered in) and is never key (a borderless window cannot become key), clear and far
    /// off every screen, as ViewHost's.
    @MainActor private static func standingWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -40000, y: -40000, width: 120, height: 60),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.orderFront(nil)
        return window
    }

    /// ViewBridge, which TextInputUI loads after a field took text: with it, AppKit's own end of a command asks the view
    /// bridge before it plays the sound, and so does the catch. Whether its class method is there.
    @MainActor private static func loadTheViewBridge() -> Bool {
        _ = dlopen("/System/Library/PrivateFrameworks/ViewBridge.framework/ViewBridge", RTLD_NOW)
        return class_getClassMethod(NSResponder.self, NSSelectorFromString("_viewBridgeDoCommandBySelector:sender:")) != nil
    }

    /// A key down that names no window (window number 0), as a held key whose window is gone.
    @MainActor private static func downWithNoWindow(_ character: String, code: UInt16) -> [NSEvent] {
        [NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                          characters: character, charactersIgnoringModifiers: character, isARepeat: false,
                          keyCode: code)].compactMap { $0 }
    }

    /// In a window whose one view takes no key, each of the ends: a key down that no responder takes, also one that names
    /// no window (AppKit gives it to the key window), a command of the key bindings that no responder performs (with the
    /// view bridge loaded), typed text that reaches no text view, and, once the window is closed, a key down that names
    /// no window while the app has no key window. Then, still with no key window, a key down that names a window
    /// that stands is not kept: it goes on to AppKit's own, whose local monitors see it first, as FleetView's monitor
    /// takes a key of its own window; a catch that kept it would take that key from the app.
    @Test func aKeyThatNoViewTakesIsKeptAndPlaysNoSound() async throws {
        typealias Seen = (lost: [LostKeys.Key], bridge: Bool, monitored: [String])
        let (seen, screen) = try await ViewHost.onMainLoop { () -> Seen in
            let bridge = Self.loadTheViewBridge()
            let window = ViewHost.window(showing: NSView(), size: NSSize(width: 200, height: 100))
            let before = LostKeys.seen.count
            ViewHost.atOnce(ViewHost.keys("k", in: window))
            ViewHost.atOnce(Self.downWithNoWindow("e", code: 14))
            window.doCommand(by: NSSelectorFromString("moveWordLeft:"))
            window.insertText("k")
            ViewHost.close(window)
            ViewHost.atOnce(Self.downWithNoWindow("o", code: 31))
            let watcher = Watcher(), standing = Self.standingWindow()
            watcher.window = standing
            let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                MainActor.assumeIsolated { watcher.takes(event) } ? nil : event
            }
            ViewHost.atOnce(ViewHost.keys("h", in: standing).filter { $0.type == .keyDown })
            if let monitor { NSEvent.removeMonitor(monitor) }
            standing.orderOut(nil)
            standing.close()
            return (Array(LostKeys.seen.dropFirst(before)), bridge, watcher.saw)
        }
        #expect(seen.bridge, "ViewBridge gives NSResponder its view bridge, so this test covers the catch's question")
        #expect(seen.lost == [LostKeys.Key(selector: "keyDown:", window: "KeyWindow", characters: "k"),
                              LostKeys.Key(selector: "keyDown:", window: "KeyWindow", characters: "e"),
                              LostKeys.Key(selector: "moveWordLeft:", window: "KeyWindow", characters: ""),
                              LostKeys.Key(selector: "insertText:", window: "KeyWindow", characters: "k"),
                              LostKeys.Key(selector: "sendEvent:", window: "", characters: "o")],
                "each end kept its key: \(seen.lost)")
        #expect(seen.monitored == ["h"],
                "a key that names a window that stands reached the app's monitors: \(seen.monitored)")
        #expect(LostKeys.missing.isEmpty, "each catch found its AppKit method: \(LostKeys.missing)")
        #expect(screen.stayedHis)
    }

    /// A command and typed text that the window passes on to a responder after it, sent from its view; a command that a
    /// responder performs itself; and a line's left end, which AppKit's own gives again as the start of the line: each
    /// reaches the responder, and nothing is kept.
    @Test func aKeyThatAResponderTakesReachesIt() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop { () -> (took: [String], lost: [LostKeys.Key]) in
            _ = Self.loadTheViewBridge()
            let taker = Taker()
            let window = ViewHost.window(showing: NSView(), size: NSSize(width: 200, height: 100))
            defer { ViewHost.close(window) }
            window.nextResponder = taker
            let before = LostKeys.seen.count
            window.contentView?.doCommand(by: NSSelectorFromString("moveWordLeft:"))
            window.contentView?.insertText("k")
            taker.doCommand(by: NSSelectorFromString("moveWordLeft:"))
            taker.doCommand(by: NSSelectorFromString("moveToLeftEndOfLine:"))
            window.nextResponder = nil
            return (taker.took, Array(LostKeys.seen.dropFirst(before)))
        }
        #expect(seen.took == ["moveWordLeft:", "insertText: k", "moveWordLeft:", "moveToBeginningOfLine:"],
                "each reached the responder: \(seen.took)")
        #expect(seen.lost.isEmpty, "nothing was kept: \(seen.lost)")
        #expect(screen.stayedHis)
    }
}
