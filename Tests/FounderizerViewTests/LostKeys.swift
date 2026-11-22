import AppKit
import ObjectiveC
import os

/// **A key that goes nowhere plays no sound in a test, and a test can read it** (the area Release, ship and tests, 22
/// November 2026). The owner heard the Mac's alert sound again and again, and a `log stream` of `NSBeep` caught the test
/// process of these tests in a ship run (the session "Sound on the Mac"): the tests send keys (`ViewHost.keys`, a
/// suite's own), and a key that no view takes ends where AppKit plays that sound.
///
/// `install` (once for the process, from `ViewHost`, before its first window) puts four catches in place of AppKit's
/// own, in `NSResponder` and `NSApplication` themselves, so they cover every window of the process: ViewHost's, a test's
/// own, and one that the app or SwiftUI opens. No class has its own `noResponderFor:`; `NSWindow`'s and
/// `NSApplication`'s `doCommandBySelector:` end in `[super doCommandBySelector:]`; `NSTextView` takes its own text. Each
/// catch does what AppKit's own does (read in AppKit's code, macOS 27), with a record in place of the sound:
/// - `noResponderFor:`: a key down that no responder took. AppKit's own plays the sound for `keyDown:` and does nothing
///   for any other event.
/// - `doCommandBySelector:` at the end of the chain: a command of the key bindings (Esc's `cancelOperation:`, an
///   arrow's `moveUp:`) that no responder performs. AppKit's own runs whenever the receiver performs the command, maps it
///   to another (the four line ends), or has a next responder to pass it to; at the end it asks the view bridge (a
///   class method that ViewBridge adds once it is loaded, as TextInputUI loads it after a field took text), and plays
///   the sound when the bridge does not take the command. The catch asks the bridge the same way.
/// - `insertText:` at the end of the chain: typed text that reached no text view.
/// - `sendEvent:` of `NSApplication`: a key down that names no window that stands, while the app has no key window.
///   AppKit's own sends a key down only to its key window, whatever window the event names; with none, it offers the
///   key to the key equivalents and then plays the sound. The app sends such a key when it posts a held key again
///   (`NSApp.postEvent`) after its test closed the window. The catch keeps it and returns before AppKit's own, so the
///   key skips more than the main menu (a test process has none): also the app's local key monitors, and AppKit's offer
///   of key equivalents to every window and to the status items. A key down that names a window that stands goes on to
///   AppKit's own, also with no key window: the app's key monitor of the chat's box (`FleetView`) takes a key whose
///   window is its own and is key (`event.window === window && window.isKeyWindow`), and ViewHost's window is key while
///   it stands. It reads AppKit's own key window (`_keyWindow`): the public one is nil in an app that is not active, and
///   a test's app never is. The same catch keeps the event in dispatch, which gives a record of the other three its
///   characters (a test gives its events straight to `NSApp.sendEvent`, which sets no current event).
///
/// A record names the selector (`sendEvent:` for a key down with no key window), the class of the window, and the
/// characters. `seen` lists them, so that a test can check that no key of it went nowhere: the bug that these tests look
/// for. A catch whose AppKit method is not there (a later macOS) stays out, and `missing` names it, which fails
/// LostKeysTests; the other suites run.
enum LostKeys {
    struct Key: Sendable, Equatable, CustomStringConvertible {
        /// `keyDown:`, the command of the key bindings, `insertText:`, or `sendEvent:`.
        let selector: String
        /// The class of the window that the key went to; "" for none.
        let window: String
        /// The characters of the key that the app was sending; with none, the text of `insertText:`.
        let characters: String

        var description: String {
            "\(selector) in \(window.isEmpty ? "no window" : window), \(characters.debugDescription)"
        }
    }

    /// Every key that went nowhere in this test process, in the order in which they came.
    static var seen: [Key] { state.withLock { $0.seen } }

    /// The AppKit methods that a catch did not find, so that the catch stays out.
    static var missing: [String] { state.withLock { $0.missing } }

    /// The catches, in place once for the process.
    static func install() {
        let first = state.withLock { (kept: inout State) -> Bool in
            defer { kept.installed = true }
            return !kept.installed
        }
        guard first else { return }
        catchTheKeyWithNoWindow()
        catchTheKeyDown()
        catchTheCommand()
        catchTheText()
    }

    private struct State: Sendable {
        var installed = false
        var seen: [Key] = []
        var missing: [String] = []
        /// The events that `NSApplication.sendEvent:` is sending, the innermost last: the class of the event's window
        /// and its characters ("" for an event that is not a key).
        var sending: [(window: String, characters: String)] = []
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    private static func catchTheKeyWithNoWindow() {
        typealias Send = @convention(c) (NSObject, Selector, NSEvent?) -> Void
        let name = NSSelectorFromString("sendEvent:")
        guard let method = instanceMethod(NSApplication.self, name) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: Send.self)
        let send: @convention(block) (NSObject, NSEvent?) -> Void = { app, event in
            let key = event?.type == .keyDown || event?.type == .keyUp
            if let event, event.type == .keyDown, !namesAStandingWindow(event), !hasKeyWindow(app) {
                remember(Key(selector: "sendEvent:", window: "", characters: event.characters ?? ""))
                return
            }
            let sent = (window: event?.window.map { String(describing: type(of: $0)) } ?? "",
                        characters: key ? event?.characters ?? "" : "")
            state.withLock { $0.sending.append(sent) }
            defer { state.withLock { _ = $0.sending.popLast() } }
            original(app, name, event)
        }
        _ = method_setImplementation(method, imp_implementationWithBlock(send))
    }

    private static func catchTheKeyDown() {
        typealias End = @convention(c) (NSObject, Selector, Selector) -> Void
        let name = NSSelectorFromString("noResponderFor:"), keyDown = NSSelectorFromString("keyDown:")
        guard let method = instanceMethod(NSResponder.self, name) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: End.self)
        let end: @convention(block) (NSObject, Selector) -> Void = { responder, event in
            if event == keyDown { keep("keyDown:", at: responder) } else { original(responder, name, event) }
        }
        _ = method_setImplementation(method, imp_implementationWithBlock(end))
    }

    private static func catchTheCommand() {
        typealias Command = @convention(c) (NSObject, Selector, Selector) -> Void
        let name = NSSelectorFromString("doCommandBySelector:")
        guard let method = instanceMethod(NSResponder.self, name) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: Command.self)
        // the commands that AppKit's own gives again as another command: a line's left and right end
        let lineEnds = Set(["moveToLeftEndOfLine:", "moveToRightEndOfLine:", "moveToLeftEndOfLineAndModifySelection:",
                            "moveToRightEndOfLineAndModifySelection:"].map { NSSelectorFromString($0) })
        let command: @convention(block) (NSObject, Selector) -> Void = { responder, selector in
            if responder.responds(to: selector) || lineEnds.contains(selector) || hasNext(responder) {
                original(responder, name, selector)
            } else if !bridgeTakes(selector) {
                keep(NSStringFromSelector(selector), at: responder)
            }
        }
        _ = method_setImplementation(method, imp_implementationWithBlock(command))
    }

    private static func catchTheText() {
        typealias Insert = @convention(c) (NSObject, Selector, AnyObject?) -> Void
        let name = NSSelectorFromString("insertText:")
        guard let method = instanceMethod(NSResponder.self, name) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: Insert.self)
        let insert: @convention(block) (NSObject, AnyObject?) -> Void = { responder, text in
            if hasNext(responder) {
                original(responder, name, text)
            } else {
                keep("insertText:", at: responder, text: (text as? NSAttributedString)?.string ?? (text as? String) ?? "")
            }
        }
        _ = method_setImplementation(method, imp_implementationWithBlock(insert))
    }

    /// The method of AppKit's own; with none, its name goes into `missing`, and its catch stays out.
    private static func instanceMethod(_ type: AnyClass, _ name: Selector) -> Method? {
        guard let method = class_getInstanceMethod(type, name) else {
            let named = "-[\(NSStringFromClass(type)) \(NSStringFromSelector(name))]"
            state.withLock { $0.missing.append(named) }
            return nil
        }
        return method
    }

    /// Whether the responder has a next one, as AppKit's own ends read it: from its instance variable. When it cannot
    /// tell, it says yes, and AppKit's own end runs.
    private static func hasNext(_ responder: NSObject) -> Bool {
        if let next = class_getInstanceVariable(NSResponder.self, "_nextResponder") {
            return object_getIvar(responder, next) != nil
        }
        guard Thread.isMainThread else { return true }
        let responder = responder as? NSResponder
        return MainActor.assumeIsolated { responder?.nextResponder != nil }
    }

    /// Whether the view bridge takes the command, asked as AppKit's own end asks it, when ViewBridge is loaded.
    private static func bridgeTakes(_ command: Selector) -> Bool {
        typealias Bridge = @convention(c) (AnyClass, Selector, Selector, AnyObject?) -> Bool
        let bridge = NSSelectorFromString("_viewBridgeDoCommandBySelector:sender:")
        guard let method = class_getClassMethod(NSResponder.self, bridge) else { return false }
        let takes = unsafeBitCast(method_getImplementation(method), to: Bridge.self)
        return takes(NSResponder.self, bridge, command, nil)
    }

    /// Whether the event names a window that stands (is visible): the app's key monitors may take its key. When it
    /// cannot tell, it says yes, and AppKit's own runs.
    private static func namesAStandingWindow(_ event: NSEvent) -> Bool {
        guard let window = event.window else { return false }
        guard Thread.isMainThread else { return true }
        return MainActor.assumeIsolated { window.isVisible }
    }

    /// Whether the app has a key window, as AppKit's own `sendEvent:` reads it (`_keyWindow`; the public `keyWindow` is
    /// nil in an app that is not active). When it cannot tell, it says yes, and AppKit's own runs.
    private static func hasKeyWindow(_ app: NSObject) -> Bool {
        let own = NSSelectorFromString("_keyWindow")
        guard app.responds(to: own) else { return true }
        return app.perform(own)?.takeUnretainedValue() != nil
    }

    private static func keep(_ selector: String, at responder: NSObject, text: String = "") {
        let sending = state.withLock { $0.sending.last }
        let receiver = responder as? NSResponder
        var own: String?
        if Thread.isMainThread { own = MainActor.assumeIsolated { windowClass(of: receiver) } }
        let characters = sending?.characters ?? ""
        remember(Key(selector: selector, window: own ?? sending?.window ?? "",
                     characters: characters.isEmpty ? text : characters))
    }

    private static func remember(_ key: Key) {
        state.withLock { $0.seen.append(key) }
    }

    /// The class of the window of the responder at the end of the chain: a window, a view, or their controller.
    @MainActor private static func windowClass(of responder: NSResponder?) -> String? {
        let window = responder as? NSWindow ?? (responder as? NSView)?.window
            ?? (responder as? NSWindowController)?.window ?? (responder as? NSViewController)?.viewIfLoaded?.window
        return window.map { String(describing: type(of: $0)) }
    }
}
