import AppKit
import FleetCore
import SwiftUI

/// **His input to an agent's screen, one event after the other** (the take-over card): a click that a key overtook is a
/// click in the wrong place, so every event goes through one queue to the session, in the order that he made it. The
/// queue drops nothing: a lost key-up would leave a key held on the agent's screen.
@MainActor final class RemoteInput {
    enum Event: Sendable {
        case pointer(x: Int, y: Int, buttons: UInt8)
        case key(UInt32, down: Bool)
    }

    private var continuation: AsyncStream<Event>.Continuation?
    private var pump: Task<Void, Never>?

    /// Sends every later event to this session, until `detach`.
    func attach(_ session: RFBSession) {
        detach()
        let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        pump = Task {
            for await event in stream {
                switch event {
                case .pointer(let x, let y, let buttons): await session.pointer(x: x, y: y, buttons: buttons)
                case .key(let keysym, let down): await session.key(keysym, down: down)
                }
            }
        }
    }

    func detach() {
        continuation?.finish()
        continuation = nil
        pump?.cancel()
        pump = nil
    }

    func send(_ event: Event) { continuation?.yield(event) }
}

/// The agent's screen in the take-over card: its picture as large as the place allows, in its own shape, and his
/// pointer, wheel and keys to it. Esc goes to the card's window, which closes the card, and every ⌘ shortcut stays in
/// the app (the design's section 3.2). A character goes as itself, through the Mac's own text input, so a dead key's
/// accent (´ then a is á), the Option key's ñ and @ arrive as he sees them; Shift and Control go as keys of their own
/// only with a key that writes no character, with a Control letter, and with a click.
struct RemoteScreenView: NSViewRepresentable {
    let image: CGImage?
    let input: RemoteInput

    func makeNSView(context: Context) -> RemoteScreenNSView {
        let view = RemoteScreenNSView()
        view.input = input
        return view
    }

    func updateNSView(_ view: RemoteScreenNSView, context: Context) {
        view.input = input
        view.show(image)
    }
}

final class RemoteScreenNSView: NSView, @preconcurrency NSTextInputClient {
    var input: RemoteInput?
    private var screenSize = CGSize.zero
    private var buttons: UInt8 = 0
    /// The keysyms that a key that writes no character pressed, with their modifiers, to let go at its release.
    private var held: [UInt16: [UInt32]] = [:]
    /// Shift and Control as a click sent them, to let go when he lets go.
    private var clickModifiers: [UInt32] = []
    /// A trackpad's small scroll steps, added up until they make one step of a wheel.
    private var scrolled = CGPoint.zero
    /// The last place of his pointer on the agent's screen.
    private var lastPoint: (x: Int, y: Int)?
    /// A dead key's accent, which the Mac's text input holds until the next key.
    private var marked = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
        setAccessibilityRole(.image)
        setAccessibilityLabel(String(l10n: "The agent's screen"))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func show(_ image: CGImage?) {
        if let image { screenSize = CGSize(width: image.width, height: image.height) }
        layer?.contents = image
    }

    /// An observer that goes with its holder: the view's, freed with the view, also when its window is freed with it.
    private final class Watch {
        let token: NSObjectProtocol
        init(_ token: NSObjectProtocol) { self.token = token }
        deinit { NotificationCenter.default.removeObserver(token) }
    }
    private var resignWatch: Watch?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resignWatch = nil
        if let window {
            // ⌘Tab or a click in another app: the key-ups go to no window, so all that is down goes up now
            resignWatch = Watch(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                                       object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseAll() }
            })
        }
        window?.makeFirstResponder(self)
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    /// The place of the picture in the view: the whole screen, as large as the view allows, centred.
    private var pictureRect: CGRect {
        guard screenSize.width > 0, screenSize.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / screenSize.width, bounds.height / screenSize.height)
        let size = CGSize(width: screenSize.width * scale, height: screenSize.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// The point of the agent's screen under the event, or nil before the first picture; with `inside`, nil also on
    /// the black bars beside the picture (a press there goes nowhere, never to the screen's nearest edge).
    private func screenPoint(_ event: NSEvent, inside: Bool = false) -> (x: Int, y: Int)? {
        let rect = pictureRect
        guard rect.width > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        if inside, !rect.contains(point) { return nil }
        let x = (point.x - rect.minX) / rect.width * screenSize.width
        let y = (point.y - rect.minY) / rect.height * screenSize.height
        return (Int(x.rounded(.down)), Int(y.rounded(.down)))
    }

    private func pointer(_ event: NSEvent) {
        guard let point = screenPoint(event) else { return }
        lastPoint = point
        input?.send(.pointer(x: point.x, y: point.y, buttons: buttons))
    }

    /// Shift and Control down on the agent's screen as they are on this Mac, for a click.
    private func syncClickModifiers(_ flags: NSEvent.ModifierFlags) {
        let wanted = [(NSEvent.ModifierFlags.shift, RFBKeys.shift), (.control, RFBKeys.control)]
            .filter { flags.contains($0.0) }.map(\.1)
        for keysym in clickModifiers where !wanted.contains(keysym) { input?.send(.key(keysym, down: false)) }
        for keysym in wanted where !clickModifiers.contains(keysym) { input?.send(.key(keysym, down: true)) }
        clickModifiers = wanted
    }

    private func press(_ event: NSEvent, button: UInt8) {
        guard screenPoint(event, inside: true) != nil else { return }
        window?.makeFirstResponder(self)
        syncClickModifiers(event.modifierFlags)
        buttons |= button
        pointer(event)
    }

    private func release(_ event: NSEvent, button: UInt8) {
        guard buttons & button != 0 else { return }
        buttons &= ~button
        pointer(event)
        if buttons == 0 { syncClickModifiers(event.modifierFlags) }
    }

    override func mouseMoved(with event: NSEvent) { pointer(event) }
    override func mouseDragged(with event: NSEvent) { pointer(event) }
    override func rightMouseDragged(with event: NSEvent) { pointer(event) }
    override func otherMouseDragged(with event: NSEvent) { pointer(event) }
    override func mouseDown(with event: NSEvent) { press(event, button: 1) }
    override func mouseUp(with event: NSEvent) { release(event, button: 1) }
    override func rightMouseDown(with event: NSEvent) { press(event, button: 4) }
    override func rightMouseUp(with event: NSEvent) { release(event, button: 4) }
    override func otherMouseDown(with event: NSEvent) { press(event, button: 2) }
    override func otherMouseUp(with event: NSEvent) { release(event, button: 2) }

    override func flagsChanged(with event: NSEvent) {
        if !clickModifiers.isEmpty, buttons == 0 { syncClickModifiers(event.modifierFlags) }
    }

    /// A wheel's step is a press and a release of its button: 8 up, 16 down, 32 left, 64 right. A trackpad's small
    /// steps add up to one step each 12 points.
    override func scrollWheel(with event: NSEvent) {
        guard let point = screenPoint(event, inside: true) else { return }
        let unit: CGFloat = event.hasPreciseScrollingDeltas ? 12 : 1
        scrolled.x += event.scrollingDeltaX
        scrolled.y += event.scrollingDeltaY
        func steps(_ value: inout CGFloat) -> Int {
            let whole = Int((value / unit).rounded(.towardZero))
            value -= CGFloat(whole) * unit
            return max(-10, min(10, whole))
        }
        let vertical = steps(&scrolled.y), horizontal = steps(&scrolled.x)
        for (count, up, down) in [(vertical, UInt8(8), UInt8(16)), (horizontal, UInt8(32), UInt8(64))] where count != 0 {
            let button = count > 0 ? up : down
            for _ in 0..<abs(count) {
                input?.send(.pointer(x: point.x, y: point.y, buttons: buttons | button))
                input?.send(.pointer(x: point.x, y: point.y, buttons: buttons))
            }
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool { false }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 0x35 {                                                             // Esc
            if marked.isEmpty { window?.cancelOperation(nil) } else { dropAccent() }           // the accent first
            return
        }
        if flags.contains(.command) { super.keyDown(with: event); return }                    // the app's shortcuts
        if let special = RFBKeys.special(macKeyCode: event.keyCode), marked.isEmpty {
            if held[event.keyCode] == nil {
                var modifiers: [UInt32] = []
                if flags.contains(.shift) { modifiers.append(RFBKeys.shift) }
                if flags.contains(.control) { modifiers.append(RFBKeys.control) }
                modifiers.forEach { input?.send(.key($0, down: true)) }
                held[event.keyCode] = modifiers + [special]
            }
            input?.send(.key(special, down: true))                                            // a held key repeats
            return
        }
        if flags.contains(.control) {
            // Control's letter as itself under Control (Control-A, Control-C on the agent's screen)
            let keysyms = (event.charactersIgnoringModifiers?.lowercased() ?? "").unicodeScalars.compactMap(RFBKeys.keysym(for:))
            guard !keysyms.isEmpty else { return }
            input?.send(.key(RFBKeys.control, down: true))
            for keysym in keysyms { type(keysym) }
            input?.send(.key(RFBKeys.control, down: false))
            return
        }
        if event.isARepeat, marked.isEmpty {
            // a held letter repeats as itself, as on the agent's own keyboard (no accent menu of the Mac's)
            for scalar in (event.characters ?? "").unicodeScalars { if let keysym = RFBKeys.keysym(for: scalar) { type(keysym) } }
            return
        }
        interpretKeyEvents([event])                                                           // insertText below
    }

    override func keyUp(with event: NSEvent) {
        guard let keys = held.removeValue(forKey: event.keyCode) else { return }
        for keysym in keys.reversed() { input?.send(.key(keysym, down: false)) }
    }

    private func type(_ keysym: UInt32) {
        input?.send(.key(keysym, down: true))
        input?.send(.key(keysym, down: false))
    }

    /// Keys and buttons that are still down when the card loses the keyboard go up, so that nothing stays held on the
    /// agent's screen.
    override func resignFirstResponder() -> Bool {
        releaseAll()
        return super.resignFirstResponder()
    }

    private func releaseAll() {
        for keys in held.values { for keysym in keys.reversed() { input?.send(.key(keysym, down: false)) } }
        held = [:]
        if buttons != 0, let point = lastPoint { input?.send(.pointer(x: point.x, y: point.y, buttons: 0)) }
        buttons = 0
        for keysym in clickModifiers { input?.send(.key(keysym, down: false)) }
        clickModifiers = []
        dropAccent()
    }

    /// A dead key's accent that waits is dropped, in the Mac's text input too.
    private func dropAccent() {
        guard !marked.isEmpty else { return }
        marked = ""
        inputContext?.discardMarkedText()
    }

    // MARK: the Mac's text input: what he typed, composed

    func insertText(_ string: Any, replacementRange: NSRange) {
        marked = ""
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        for scalar in text.unicodeScalars { if let keysym = RFBKeys.keysym(for: scalar) { type(keysym) } }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
    }

    func unmarkText() { marked = "" }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange {
        marked.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: marked.utf16.count)
    }
    func hasMarkedText() -> Bool { !marked.isEmpty }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        window.map { $0.convertToScreen(convert(bounds, to: nil)) } ?? .zero
    }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
    /// A command of the text system (a key that writes no character, which `keyDown` sent before): nothing more.
    override func doCommand(by selector: Selector) {
        if selector == #selector(cancelOperation(_:)) { dropAccent() }
    }
}
