import AppKit
import FleetCore

/// **The window that the sidebar's Update opens** (`UpdateAsk`; the owner, 15 November 2026: "a button above the
/// settings one, where I can click, I see a small confirmation modal to update, and be able to do it from there ...
/// This applies to the fleet and to the app", and "a macOS dialog ... it should show everytime there is a fleet update or
/// a macOS update!"). Until then one press of the banner put this Mac's build in place and started the app again at
/// once, with no question, and a release of the fleet alone was taken on the Updates page.
///
/// The system's small window, with the app's icon, as Founderizer › Check for Updates… opens it (`UpdateCheck`). A click
/// reads the fleet's releases and our channel now, so that the window names what is there to take this moment, and not
/// what an hour-old read found: "Update now?", a line for each update, **Update and Restart** while this Mac's build is
/// in it and **Update** while only the fleet's is, and **Cancel**. The press closes the window, and the sidebar's Update
/// says what goes on. A window whose reads found nothing to take says so, with OK. It is one window: a second click
/// brings it to the front.
@MainActor
final class UpdateDialog: NSObject {
    static let shared = UpdateDialog()

    private var alert: NSAlert?
    /// What the open window offers.
    private var ask: UpdateAsk?
    private weak var store: FleetStore?
    /// The reads are on their way: a second click waits for their window.
    private var reading = false

    func press(store: FleetStore) {
        NSApp.activate()
        if let window = alert?.window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard !reading else { return }
        reading = true
        self.store = store
        Task {
            let fleet = UpdatesModel.of(store)
            async let fleetRead: Void = fleet.read(store: store)
            async let appRead = store.updates.readNow(store: store)
            let (_, answer) = await (fleetRead, appRead)
            reading = false
            show(UpdateAsk.of(fleet: fleet.state, app: answer, running: AppVersion.running,
                              cannotReplace: store.updates.cannotReplace))
        }
    }

    private func show(_ ask: UpdateAsk) {
        alert?.window.orderOut(nil)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = ask.title
        alert.informativeText = ask.lines.joined(separator: "\n")
        if let press = ask.press {
            add(press, #selector(update), to: alert)
            add(String(l10n: "Cancel"), #selector(close), to: alert).keyEquivalent = "\u{1b}"
        } else {
            add(String(l10n: "OK"), #selector(close), to: alert)
        }
        // **One line for each update**: the system's window is narrow, and it broke "Your fleet: 2026.11.494 →
        // 2026.11.495" between its two versions. An empty view of 300 points widens it to fit the line (drawn off the
        // screen on 15 November 2026, before the first build).
        alert.accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 0))
        alert.layout()
        self.alert = alert
        self.ask = ask
        NSApp.activate()
        alert.window.center()
        alert.window.makeKeyAndOrderFront(nil)
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, to alert: NSAlert) -> NSButton {
        let button = alert.addButton(withTitle: title)
        button.target = self
        button.action = action
        return button
    }

    @objc private func close() {
        alert?.window.orderOut(nil)
        alert = nil
        ask = nil
    }

    /// **The press**: the window closes, and the sidebar's Update says what goes on. The fleet's release goes first,
    /// because its run goes on in the hub whatever this app does; then this Mac's build, which starts the app again.
    @objc private func update() {
        guard let ask, let store else { return }
        close()
        Task {
            if ask.fleet != nil { await UpdatesModel.of(store).update(store: store) }
            if let build = ask.app { await store.updates.pressInstall(build) }
        }
    }
}
