import AppKit
import SwiftUI

extension View {
    /// **The window's three buttons stand in the middle of the band over the panes** (the margins of 30 October 2026, row
    /// 1, with the owner's crop: the sidebar's Search and + touched the window's top edge). The band is
    /// `FleetSpace.lights` high, and what stands in it — these buttons, the sidebar's two circles, a notice and its button —
    /// has its centre on the band's middle line: 18 pt from the window's top at 100 %, and `band` / 2 at a zoom. AppKit put
    /// the buttons of a hidden title bar 4 pt higher, on a line of their own.
    ///
    /// `band` is the band's height in the window's own points: `FleetSpace.lights` times the zoom the window is drawn at.
    func windowButtonsCentred(inBand band: CGFloat) -> some View { background(WindowButtonsPlacement(band: band)) }
}

/// Puts the title bar as high as the band, at the window's top, and each of the three buttons in its middle, and puts
/// them there again whenever AppKit lays the title bar out again: AppKit moves them back after a resize, a zoom of the
/// window and a new title. The title bar stays clear: a click on the band reaches the page under it, as before. In full
/// screen the system shows the buttons in its own bar, and nothing here touches them; they are placed again when the
/// window comes back.
private struct WindowButtonsPlacement: NSViewRepresentable {
    let band: CGFloat

    func makeNSView(context: Context) -> Placer { Placer() }
    func updateNSView(_ view: Placer, context: Context) { view.band = band }

    final class Placer: NSView {
        var band = FleetSpace.lights { didSet { if band != oldValue { place() } } }
        private weak var watched: NSWindow?
        private var observers: [NSObjectProtocol] = []

        private static let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window !== watched else { return }
            stopWatching()
            watched = window
            guard let window, let container = Self.container(of: window) else { return }
            let center = NotificationCenter.default
            func watch(_ name: Notification.Name, of object: AnyObject) {
                observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.place() }
                })
            }
            for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                         NSWindow.didExitFullScreenNotification] { watch(name, of: window) }
            // AppKit's own layout of the title bar, which follows none of the window's notifications (a new title).
            container.postsFrameChangedNotifications = true
            watch(NSView.frameDidChangeNotification, of: container)
            for kind in Self.kinds {
                guard let button = window.standardWindowButton(kind) else { continue }
                button.postsFrameChangedNotifications = true
                watch(NSView.frameDidChangeNotification, of: button)
            }
            place()
        }

        /// The view that holds the title bar, at the top of the window's frame view.
        private static func container(of window: NSWindow) -> NSView? {
            window.standardWindowButton(.closeButton)?.superview?.superview
        }

        /// Each frame is set only where it differs, so the notices of the frames set here end at once. The title bar is
        /// the band's height in whole points; each button's top is the band's middle less half the button, on the
        /// screen's own pixels (at 115 % the band's middle is 20.7 pt down).
        private func place() {
            guard let window, !window.styleMask.contains(.fullScreen), let container = Self.container(of: window),
                  container.superview === window.contentView?.superview else { return }
            let height = band.rounded(.up)
            let frame = NSRect(x: 0, y: window.frame.height - height, width: window.frame.width, height: height)
            if container.frame != frame { container.frame = frame }
            let pixel = max(window.backingScaleFactor, 1)
            for kind in Self.kinds {
                guard let button = window.standardWindowButton(kind) else { continue }
                let top = (((band - button.frame.height) / 2) * pixel).rounded() / pixel
                // The title bar's own points run up from its bottom edge.
                let y = height - top - button.frame.height
                if button.frame.minY != y { button.setFrameOrigin(NSPoint(x: button.frame.minX, y: y)) }
            }
        }

        /// Also when the view leaves its window (`viewDidMoveToWindow` with no window).
        private func stopWatching() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }
    }
}
