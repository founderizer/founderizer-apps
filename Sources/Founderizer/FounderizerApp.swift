import AppKit
import SwiftUI

@main
struct FounderizerApp: App {
    @NSApplicationDelegateAdaptor(FleetAppDelegate.self) private var delegate
    @State private var store = FleetStore()

    var body: some Scene {
        Window("Founderizer", id: "fleet") {
            // The window at the zoom he chose in View (D-8): laid out in its size divided by the zoom, drawn at the zoom.
            FleetView(store: store)
                .viewZoomed()
                .preferredColorScheme(.dark)
                .frame(minWidth: 960, minHeight: 560)
                .task { store.start() }
                // The website's Open Founderizer button: `founderizer://claim?key=…` (ClaimFromLink).
                .onOpenURL { url in store.openLink(url) }
        }
        // The window opens over the whole visible screen at each start, also after a smaller window was closed.
        .defaultWindowPlacement { _, context in
            WindowPlacement(context.defaultDisplay.visibleRect.origin, size: context.defaultDisplay.visibleRect.size)
        }
        .restorationBehavior(.disabled)
        // **The app's own content runs to the top edge, with the traffic lights over it.** A hidden title bar
        // alone does that; `.windowToolbarStyle(.unifiedCompact)` beside it kept a compact toolbar area reserved,
        // and this app puts nothing in a toolbar, so the reserved strip was an empty band with the three lights
        // in it and the owner's desktop above (20 October 2026: "remove the top bar, it does not look good").
        .windowStyle(.hiddenTitleBar)
        .commands {
            // **About Founderizer**, where every Mac app has it: the system's own window, with the credit under the
            // version (`AboutPanel`; the owner's yes of 10 November 2026).
            AboutCommand()
            // **File holds Close Window ⌘W and nothing else** (the owner's yes of 30 October 2026, to the polish that named
            // the missing File menu): every Mac app has it, and nothing closed the window from the keyboard. The system's
            // group of new items stays as it is, empty for this window: emptied here, it put a line over Close Window.
            CloseWindowCommand()
            // **Help holds the system's search field and Report a problem…, and nothing else** (the polish of 30 October
            // 2026): the system's own group held two dead items, Founderizer Help, which only said "Help isn't available
            // for Founderizer." (the app has no help book), and a hidden "Toggle Sidebar ⌥⌘S".
            CommandGroup(replacing: .help) {}
            // **Settings… ⌘,** in the Founderizer menu, where every Mac app has it (the owner's yes of 28 October 2026
            // to D-4). It opens Settings › General in the window.
            SettingsCommand(store: store)
            CommandGroup(after: .toolbar) {
                Button("Refresh Founderizer") { Task { await store.refresh() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
            // View › Bigger ⌘+, Smaller ⌘− and Actual Size ⌘0, under Refresh Founderizer (D-8).
            ViewZoomCommands()
            // Help is where a Mac has always kept this, and it is reachable from every screen, which is what a
            // report needs: the customer presses it while the thing that broke is still in front of him.
            ReportProblemCommand()
        }

        // Its own window, beside the page it is about, rather than a card over it.
        Window("Report a problem", id: Self.reportWindow) {
            ReportProblemView(store: store).preferredColorScheme(.dark)
        }
        .defaultSize(width: 620, height: 780)
        // No bar of any kind at the top, as the main window (margins row 11).
        .windowStyle(.hiddenTitleBar)
        .restorationBehavior(.disabled)
    }

    static let reportWindow = "report"
}

/// Founderizer › About Founderizer, in the place of the system's own item: the same window, with the credit
/// (`AboutPanel`).
private struct AboutCommand: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Founderizer") { AboutPanel.show() }
        }
    }
}

/// File › Close Window ⌘W, **on only while it can close a window** (`ClosableWindow`; the review of 30 October 2026: with
/// no window open it stood on and did nothing). Its own `Commands` type for the object it watches.
private struct CloseWindowCommand: Commands {
    @ObservedObject private var windows = ClosableWindow.shared
    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("Close Window") { (NSApp.keyWindow ?? NSApp.mainWindow)?.performClose(nil) }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(!windows.canClose)
        }
    }
}

/// **Whether File › Close Window can act**: the window that has the keyboard has a close button, or, while none has the
/// keyboard, a window of the app is open. A card over the page has the keyboard in a window with no close button (Esc
/// closes it), and turns it off.
@MainActor final class ClosableWindow: ObservableObject {
    static let shared = ClosableWindow()
    @Published private(set) var canClose = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                // A window that closes still shows when its notice comes: look once it has gone.
                DispatchQueue.main.async { MainActor.assumeIsolated { ClosableWindow.shared.look() } }
            })
        }
        look()
    }

    private func look() {
        let open = NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized && $0.styleMask.contains(.closable) }
        let can = NSApp.keyWindow.map { $0.styleMask.contains(.closable) } ?? open
        if canClose != can { canClose = can }
    }
}

/// Founderizer → Settings…, with ⌘,: the window comes to the front on Settings › General. Its own `Commands` type, for
/// the same reason as Report a problem's: `openWindow` belongs to a dynamic property.
private struct SettingsCommand: Commands {
    let store: FleetStore
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                openWindow(id: "fleet")
                store.destination = .settings(.general)
            }.keyboardShortcut(",", modifiers: .command)
        }
    }
}

/// Help → Report a problem. It is its own `Commands` type because the environment's `openWindow` belongs to a
/// dynamic property, which a command group's own body cannot hold.
private struct ReportProblemCommand: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .help) {
            Button("Report a problem…") { openWindow(id: FounderizerApp.reportWindow) }
        }
    }
}

@MainActor
final class FleetAppDelegate: NSObject, NSApplicationDelegate {
    /// Every right-click menu opens in the app's own menu (`FleetContextMenus`).
    func applicationDidFinishLaunching(_ notification: Notification) { FleetContextMenus.start() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { ScreenSharingSession.shared.shutdown() }
}
