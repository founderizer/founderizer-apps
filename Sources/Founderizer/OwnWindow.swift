import AppKit
import SwiftUI

/// **The window that a view stands in, for a watch of the app's keys that acts only for its own window.** A request
/// card can stand in two windows at once, the chat's and its own (`NeedWindows`), and each of its fields can have the
/// cursor of its own window: a watch of the app's keys (`NSEvent.addLocalMonitorForEvents`) sees every key of the app,
/// so the watch of one would take a key that he typed in the other window. A view gives its window with
/// `ownWindow(_:)`, and the watch asks `takes(_:)` at each key.
@MainActor final class OwnWindow {
    fileprivate(set) weak var window: NSWindow?

    init() {}

    /// The key is this view's: it came in this view's window, or one of the two windows is not known (a key that the
    /// app sent again, a view that stands in no window yet), where the watch acts as it did before.
    func takes(_ event: NSEvent) -> Bool {
        guard let window, let other = event.window else { return true }
        return other === window
    }
}

extension View {
    /// Tells `own` the window that this view stands in (`OwnWindow`).
    func ownWindow(_ own: OwnWindow) -> some View { background(OwnWindowReader(own: own)) }
}

/// A view of no size, which takes no click, that knows its window.
private struct OwnWindowReader: NSViewRepresentable {
    let own: OwnWindow

    func makeNSView(context: Context) -> Reader { Reader(own: own) }

    func updateNSView(_ view: Reader, context: Context) {
        view.own = own
        own.window = view.window
    }

    final class Reader: NSView {
        var own: OwnWindow

        init(own: OwnWindow) {
            self.own = own
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            own.window = window
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
