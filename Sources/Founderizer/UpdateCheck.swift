import AppKit
import FleetCore

/// **Founderizer › Check for Updates…** (the owner's yes of 14 November 2026 to its two pictures: the item under About
/// Founderizer, and the system's small window that it opens). It works on every screen, the setup's included: before
/// any hub answered this Mac it asks our channel as a Mac that has just downloaded the app (`AppAutoUpdate.readNow`).
///
/// The window is the system's alert, with the app's icon: "Founderizer 0.1.207 is ready" over "You have 0.1.206." with
/// **Update and Restart** and **Later**, or "Founderizer is up to date" with OK, or the channel's own line under the
/// version that runs (`AppUpdateWords.check`). Update and Restart downloads the build, checks it as every update is
/// checked, puts it in place and starts the app again at once; its steps stand in the window's line meanwhile. It is
/// one window: a second press brings it to the front.
@MainActor
final class UpdateCheck: NSObject {
    static let shared = UpdateCheck()

    private var alert: NSAlert?
    /// The build that Update and Restart takes.
    private var build: AppManifest?
    private weak var store: FleetStore?
    /// The read of the channel is on its way: a second press waits for its window.
    private var reading = false
    /// Update and Restart was pressed and its install runs: the window's line says its steps.
    private var installing = false

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
            let answer = await store.updates.readNow(store: store)
            reading = false
            let words = AppUpdateWords.check(answer, running: AppVersion.running, cannotReplace: store.updates.cannotReplace)
            build = words.offers ? answer.manifest : nil
            show(words)
        }
    }

    private func show(_ words: AppUpdateWords.Check) {
        alert?.window.orderOut(nil)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = words.title
        alert.informativeText = words.line
        if words.offers {
            add(String(l10n: "Update and Restart"), #selector(update), to: alert)
            add(String(l10n: "Later"), #selector(close), to: alert).keyEquivalent = "\u{1b}"
        } else {
            add(String(l10n: "OK"), #selector(close), to: alert)
        }
        alert.layout()
        self.alert = alert
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
        build = nil
    }

    /// The one press: nothing in the window can be pressed while the build goes in, because nothing can stop it halfway;
    /// the app then starts again by itself. A failure takes the window's line, with OK.
    @objc private func update() {
        guard let build, let store, let alert, !installing else { return }
        installing = true
        for button in alert.buttons { button.isEnabled = false }
        say(AppUpdateInstaller.Step.downloading(-1).says)
        Task {
            let failure = await store.updates.installNow(build) { step in
                Task { @MainActor in UpdateCheck.shared.say(step.says) }
            }
            guard let failure else { return }
            installing = false
            self.build = nil
            // Under the version that still runs, as every window that offers nothing.
            let failed = AppUpdateReading(status: 0, says: failure)
            show(AppUpdateWords.check(failed, running: AppVersion.running, cannotReplace: nil))
        }
    }

    /// A step of the install, in the window's line. Its digits keep one width, so the line does not shake as the
    /// download counts up (`UI-PATTERNS.md`, "A wait that knows its count").
    private func say(_ words: String) {
        guard installing, let alert, alert.informativeText != words else { return }
        alert.informativeText = words
        alert.layout()
        if let field = alert.window.contentView.flatMap({ UpdateCheck.field(saying: words, in: $0) }) {
            field.font = NSFont.monospacedDigitSystemFont(ofSize: field.font?.pointSize ?? NSFont.smallSystemFontSize,
                                                          weight: .regular)
        }
    }

    /// The alert's own field that shows these words.
    private static func field(saying words: String, in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.stringValue == words { return field }
        for child in view.subviews {
            if let found = field(saying: words, in: child) { return found }
        }
        return nil
    }
}
