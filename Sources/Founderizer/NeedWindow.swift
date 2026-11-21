import AppKit
import Carbon.HIToolbox
import FleetCore
import SwiftUI

/// **A request card in a window of its own, over every app** (the owner, 21 November 2026: "I have to come back again to
/// the Founderizer full window to follow the steps, it would be nice to have like a pop-out functionality so the card
/// can open in another window I can drag around and keep on top of others until it is closed. I would also like to be
/// able to reply from it", and his "Yes, as drawn" to its picture). The card's icon "Open in its own window" opens it,
/// or brings it to the front: one window for each request (`NeedWindows.open`).
///
/// **An AppKit panel, because a SwiftUI window cannot stand over another app's full-screen space**: a panel that does
/// not make the app active, at the floating level, on every Space and beside a full-screen app, that stays when another
/// app comes to the front, and that he drags by its ground. It takes the keyboard, so he types and pastes in it while
/// his browser stays the active app, and a first click acts at once (`NeedHosting`). Its ground is the card's own fill,
/// in the dark look, with no bar at the top: the window's three buttons stand at its top left over that ground, and the
/// card begins under their band. It is drawn at his zoom (`viewZoomed`), and never has the main window's identifier,
/// which the app's own key routing reads (`SetupChannel.fleetWindow`). VoiceOver names it by the card's title. No Dock
/// item, no item in a menu, and no fade: it comes and goes as the system's own windows do.
///
/// **What it holds**: the card of the request (`NeedRequestCard`), read from the store at each drawing, in a vertical
/// scroll: its words, its chips and badges, Details, the form of a key or the answers, his own words and files, Needs
/// clarification, Run and Copy prompt, all as in the chat. The card knows that it stands in a window from
/// `EnvironmentValues.needWindow`: it then draws no icon to open a window, has its long part open from the start, draws
/// no fill and no edge of its own (the window's ground is that fill), and tells the window its key save
/// (`NeedWindowLink.card`). The card of the same request in the chat stays as it is meanwhile.
///
/// **Its size and place, kept on this Mac** (no setting on any page): about 420 points wide at first, and then the width
/// that he gave a card's window last; its height fits the card, up to the screen's visible height less a margin, and
/// the card scrolls beyond that. Once he changes its height himself, that window keeps his height. The first window opens
/// at the top right of the screen of the main window, and each later one where he left a card's window last; a second
/// window that would stand on another one exactly stands a step down and to the left of it. **It comes on the screen
/// one turn of the main queue after its first layout**, which gives it the card's height (the first `Shown.fit`): it
/// does not grow under his eyes from its least height.
///
/// **It closes** with its close button, and with File › Close Window ⌘W while it has the keyboard (`ClosableWindow`):
/// never with Esc, because he may be typing. It closes by itself once the hub has his answer and no save or run holds
/// the card, never while his answer is only on its way, and when the request is gone; a failed save keeps it
/// (`NeedWindowEnd`). When the app quits, it goes with it; when the main
/// window closes, it stays.
@MainActor enum NeedWindows {
    /// One request of one hub and hub generation: a request of another hub with the same number is another request.
    struct Key: Hashable {
        let hub: URL
        let database: String?
        let id: Int

        /// The request as the store's reading holds it now, or nil where the store reads another hub or generation, or
        /// holds no such request.
        @MainActor func reading(in store: FleetStore) -> OwnerNeed? {
            guard store.hub == hub, let state = store.state, state.db == database else { return nil }
            return state.needs.first { $0.id == id }
        }
    }

    /// The width of the first window, and its least size.
    static let width: CGFloat = 420
    static let least = CGSize(width: 340, height: 240)
    /// From the screen's edges, and the step of a window that would stand on another one.
    static let margin = FleetSpace.margin
    static let step: CGFloat = 24
    /// Where he left a card's window last, and its width: kept on this Mac (`AppDefaults.store`).
    static let placeKey = "needWindowPlace", widthKey = "needWindowWidth"

    private static var shown: [Key: Shown] = [:]

    /// **A card's window is open: the app does not install a build by itself now** (`AppUpdateModel.tick`). An
    /// automatic install starts the app again once he has been away from it for two minutes, and he is away from it
    /// exactly while he follows the card's steps in another app: the restart would take the window away. The build
    /// goes in once no card's window is open, and his own press of Update installs it at any time.
    static var anyOpen: Bool { !shown.isEmpty }

    /// Opens the window of `need`'s card, or brings it to the front when it is open already.
    static func open(store: FleetStore, need: OwnerNeed) {
        guard let state = store.state, need.isOpen else { return }
        let key = Key(hub: store.hub, database: state.db, id: need.id)
        if let open = shown[key] {
            open.front()
            return
        }
        let link = NeedWindowLink(key: key, store: store)
        let panel = NeedPanel(contentRect: frame(), styleMask: [.titled, .closable, .resizable, .fullSizeContentView,
                                                                .nonactivatingPanel],
                              backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.tabbingMode = .disallowed
        panel.isRestorable = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = NSColor(FleetStyle.surface)
        panel.contentMinSize = least
        panel.title = need.shownTitle
        panel.identifier = NSUserInterfaceItemIdentifier("need-window-\(need.id)")
        let open = Shown(key: key, panel: panel, link: link)
        panel.delegate = open
        // the app ends: the window's own secure input ends before it (`NeedPanel`)
        open.quitWatch = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                object: nil, queue: .main) { [weak panel] _ in
            MainActor.assumeIsolated { panel?.endSecureInput() }
        }
        shown[key] = open
        let hosting = NeedHosting(rootView: NeedWindowRoot(store: store, link: link,
                                                           fit: { [weak open] in open?.fit($0) },
                                                           titled: { [weak panel] in panel?.title = $0 }))
        // The window's size is its own (`fit`, and his), never the content's.
        hosting.sizingOptions = []
        panel.contentView = hosting
        // The card's first height comes within this layout (`Shown.fit`; an off-screen panel showed it, 21 November
        // 2026), so the window comes on the screen after this turn at that height, never inside the layout itself. Where
        // no height came, it comes with the least height and takes the card's when it says it.
        hosting.layoutSubtreeIfNeeded()
        DispatchQueue.main.async { [weak open] in open?.show() }
    }

    /// Closes the window of `key` when its rule says so (`NeedWindowEnd`): the reading of the request as the store holds
    /// it, the store's run of its command, and the card's key save. Asked after each reading that changes the request or
    /// its run, and after the card's word of its key save. The close comes later, on the main queue: the window's own
    /// drawing asks it.
    fileprivate static func check(_ key: Key) {
        guard let open = shown[key], !open.closing, let store = open.link.store else { return }
        guard NeedWindowEnd.closes(reading: key.reading(in: store), runs: store.needRuns[key.id]?.busy == true,
                                   keySave: open.link.keySave) else { return }
        open.closing = true
        DispatchQueue.main.async { open.panel.close() }
    }

    /// The window closed, by his press or by itself.
    fileprivate static func closed(_ key: Key) {
        guard let open = shown.removeValue(forKey: key) else { return }
        if let watch = open.quitWatch { NotificationCenter.default.removeObserver(watch) }
        keep(open.panel.frame)
        // The card's views go after the event that closed the window, whose views stay until it is done.
        DispatchQueue.main.async { withExtendedLifetime(open) { open.panel.contentView = nil } }
    }

    /// Keeps where a card's window stands and its width, for the next one.
    fileprivate static func keep(_ frame: NSRect) {
        AppDefaults.store.set([Double(frame.minX), Double(frame.maxY)], forKey: placeKey)
        AppDefaults.store.set(Double(frame.width), forKey: widthKey)
    }

    /// The frame of a new window: the kept width, at least the least, at the kept place where a screen still holds it,
    /// or at the top right of the screen of the main window; a step down and left of a window that stands there already.
    /// Its height is the least until the card says its own (`Shown.fit`).
    private static func frame() -> NSRect {
        let defaults = AppDefaults.store
        let kept = (defaults.array(forKey: placeKey) as? [Double]).flatMap { $0.count == 2 ? NSPoint(x: $0[0], y: $0[1]) : nil }
        let keptScreen = kept.flatMap { point in
            NSScreen.screens.first { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(NSPoint(x: point.x + 1, y: point.y - 1)) }
        }
        let place = keptScreen == nil ? nil : kept
        let main = NSApp.windows.first { $0.identifier?.rawValue == SetupChannel.fleetWindow }
        let room = (keptScreen ?? main?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let keptWidth = defaults.double(forKey: widthKey)
        let width = min(max(keptWidth > 0 ? CGFloat(keptWidth) : Self.width, least.width), room.width - margin * 2)
        var left = place.map { CGFloat($0.x) } ?? room.maxX - margin - width
        var top = place.map { CGFloat($0.y) } ?? room.maxY - margin
        while shown.values.contains(where: { abs($0.panel.frame.minX - left) < 2 && abs($0.panel.frame.maxY - top) < 2 }) {
            left -= step
            top -= step
        }
        left = min(max(left, room.minX), room.maxX - width)
        top = min(max(top, room.minY + least.height), room.maxY)
        return NSRect(x: left, y: top - least.height, width: width, height: least.height)
    }

    /// One open window: its panel, its link with the card, and how it fits the card.
    @MainActor private final class Shown: NSObject, NSWindowDelegate {
        let key: Key
        let panel: NeedPanel
        let link: NeedWindowLink
        /// Its rule closed it, and it goes on the next turn.
        var closing = false
        /// The watch of the app's end (`NeedPanel.endSecureInput`).
        var quitWatch: NSObjectProtocol?
        /// He changed its height himself: it keeps his height.
        private var ownHeight = false
        /// The card's height, as it said it last.
        private var cardHeight: CGFloat?
        /// Its height when his resize began.
        private var heightBefore: CGFloat = 0
        /// The app sets its frame now: no move of his.
        private var placing = false
        /// It is on the screen (`show`).
        private var onScreen = false

        init(key: Key, panel: NeedPanel, link: NeedWindowLink) {
            self.key = key
            self.panel = panel
            self.link = link
        }

        /// The card's height, in the window's points: the window takes it, with its top where it stands, up to the
        /// screen's visible height less a margin, and not under the screen's visible bottom.
        func fit(_ height: CGFloat) {
            cardHeight = height
            guard !ownHeight, !panel.inLiveResize else { return }
            let screen = panel.screen ?? NSScreen.screens.first { $0.frame.intersects(panel.frame) } ?? NSScreen.main
            let room = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let target = min(max(height.rounded(.up), NeedWindows.least.height), room.height - NeedWindows.margin * 2)
            var frame = panel.frame
            guard abs(frame.height - target) > 0.5 else { return }
            let top = frame.maxY
            frame.size.height = target
            frame.origin.y = max(top - target, room.minY)
            placing = true
            panel.setFrame(frame, display: true)
            placing = false
        }

        /// The window comes on the screen and takes the keyboard, once. **No view takes the cursor by itself**
        /// (`NeedPanel.coming`): AppKit gives a window that comes on the screen the first view of its key loop as its
        /// first responder. With the system's keyboard navigation on that is the card's title, which then stood in the
        /// keyboard's ring; with it off it is the form's first field, so a key card's window came with the cursor in
        /// its Key field and the system's Passwords offer under it, and the keys typed next went into that field. The
        /// window comes with none: a click or Tab gives the first one.
        func show() {
            guard !onScreen, !closing else { return }
            onScreen = true
            panel.coming = true
            panel.makeKeyAndOrderFront(nil)
            panel.coming = false
            // a system that gives the first one by another way than `makeFirstResponder`: it goes again
            if panel.firstResponder !== panel { _ = panel.makeFirstResponder(nil) }
        }

        /// His press of the card's icon again: the window comes to the front, or comes as it is ready (`show`).
        func front() {
            if onScreen { panel.makeKeyAndOrderFront(nil) }
        }

        func windowWillClose(_ notification: Notification) {
            // an answer that waits with Undo goes at once: the window of its Undo closed (`AnswerHolds`)
            AnswerHolds.shared.release(key.id)
            NeedWindows.closed(key)
        }

        func windowDidMove(_ notification: Notification) {
            if !placing, panel.isVisible, !closing { NeedWindows.keep(panel.frame) }
        }

        func windowWillStartLiveResize(_ notification: Notification) { heightBefore = panel.frame.height }

        func windowDidEndLiveResize(_ notification: Notification) {
            if abs(panel.frame.height - heightBefore) > 0.5 { ownHeight = true }
            NeedWindows.keep(panel.frame)
            if let cardHeight { fit(cardHeight) }
        }
    }
}

/// The card's window: it takes the keyboard, so that his answer and a key's field work in it while another app stays in
/// front, and it is never the main window, so File › Close Window and the app's key routing reach it only while it has
/// the keyboard. **Esc does not close it**, as it closes a panel of AppKit: he may be typing in it.
///
/// **Secure input while it has the keyboard in a secure field** (the Vault area's check of 21 November 2026): this
/// window never brings the app to the front, so a key typed into the key form here while his browser is in front must
/// stay closed to a program that watches the keyboard. AppKit holds secure event input for the editor of a secure field
/// in the window that has the keyboard, in this window too (measured on macOS 26.6 with this window's own calls taken
/// out: `IsSecureEventInputEnabled` was true while the cursor stood in the Key field and Finder was in front). The
/// field's protection does not rest on that alone: the window holds secure input itself (`EnableSecureEventInput`)
/// while it is the visible key window and its first responder edits a secure field, and lets it go at every way out:
/// the cursor leaves the field, the window loses the keyboard, it closes, the app ends. One flag, so that each Enable
/// of its own has exactly one Disable: the count is per process and AppKit keeps its own beside it, which this window
/// never turns off. **The system names as the holder the app that is in front when it begins**, not this app:
/// `kCGSSessionSecureInputPID` in `ioreg` is Finder's pid while the cursor stands in this window's Key field and Finder
/// is in front, so a check reads that a pid stands there, and not whose.
private final class NeedPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) {}

    /// This window's own Enable of secure input is on, and owes its one Disable.
    private var secureInput = false
    /// It comes on the screen now (`Shown.show`): no view becomes its first responder.
    var coming = false

    override func becomeKey() {
        super.becomeKey()
        keepSecureInput()
    }

    override func resignKey() {
        super.resignKey()
        keepSecureInput()
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        // AppKit's own choice for a window that comes on the screen (`Shown.show`)
        if coming, let responder, responder !== self { return false }
        keepSecureInput()
        let made = super.makeFirstResponder(responder)
        keepSecureInput()
        return made
    }

    /// Also after each event: an editor that ends with no new first responder of the window's (`endEditing`).
    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        keepSecureInput()
    }

    override func close() {
        endSecureInput()
        super.close()
    }

    /// **A command of the Edit menu that no field of this window takes ends in this window.** AppKit offers such a
    /// command to the window that has the keyboard and then to the main window: with this window's keyboard and no
    /// cursor in it, ⌘V pasted into the field of the main window behind it. That was the chat's box, whose paste
    /// guard takes no key of another window, so an example key on the clipboard stood in the box (a guest's check,
    /// 21 November 2026). A field of this window, or its words that he can select, takes Paste, Paste and Match Style,
    /// Cut, Delete and Select All first; without one they do nothing here, and their items of the menu are off. The
    /// paste with its style (`pasteAsRichText:`) ends here too: a text view takes it, and a menu or a Services item
    /// can send it (the Vault area's read).
    private static let ownEdits: Set<Selector> = [#selector(paste(_:)), #selector(pasteAsPlainText(_:)),
                                                  #selector(pasteAsRichText(_:)), #selector(cut(_:)),
                                                  #selector(delete(_:)), #selector(selectAll(_:))]
    @objc func paste(_ sender: Any?) {}
    @objc func pasteAsPlainText(_ sender: Any?) {}
    @objc func pasteAsRichText(_ sender: Any?) {}
    @objc func cut(_ sender: Any?) {}
    @objc func delete(_ sender: Any?) {}
    override func selectAll(_ sender: Any?) {}

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let action = item.action, Self.ownEdits.contains(action) { return false }
        return super.validateMenuItem(item)
    }

    /// The first responder edits a secure field: the editor of a SwiftUI `SecureField` (an `NSSecureTextField`), or
    /// the field itself.
    private var editsSecureField: Bool {
        firstResponder is NSSecureTextField || (firstResponder as? NSTextView)?.delegate is NSSecureTextField
    }

    /// Secure input as the window stands now: on while it is the visible key window and edits a secure field.
    func keepSecureInput() { setSecureInput(isVisible && isKeyWindow && editsSecureField) }

    /// Off, for good: the window closes, or the app ends.
    func endSecureInput() { setSecureInput(false) }

    private func setSecureInput(_ on: Bool) {
        guard on != secureInput else { return }
        secureInput = on
        if on { _ = EnableSecureEventInput() } else { _ = DisableSecureEventInput() }
    }
}

/// The card's views in its window. **A first click acts at once**: on a badge, a chip, a button or a field of a window
/// that does not have the keyboard, as on a badge (`BadgePress`), with no click first to wake the window.
private final class NeedHosting: NSHostingView<NeedWindowRoot> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// What the card knows of the window that it stands in (`EnvironmentValues.needWindow`), and what it tells it.
@MainActor final class NeedWindowLink {
    fileprivate let key: NeedWindows.Key
    fileprivate weak var store: FleetStore?
    /// The card's key save, as it told it last: the one thing of the rule that the reading does not hold.
    fileprivate private(set) var keySave = KeySaveCard()

    fileprivate init(key: NeedWindows.Key, store: FleetStore) {
        self.key = key
        self.store = store
    }

    /// **The card tells its key save**, at once and at each change: the ring and the check that still draws hold the
    /// window, and a failed save keeps it. The window reads his answer and the run of its command from the store itself,
    /// never from the card, so an answer that is only on its way closes nothing (`NeedWindowEnd`).
    func card(keySave: KeySaveCard) {
        guard keySave != self.keySave else { return }
        self.keySave = keySave
        NeedWindows.check(key)
    }

    /// **A press on a name in the card's words** (a badge): an agent's page, a server's page or a page of the app opens
    /// in the main window, which comes to the front with the app (`showMainWindow`); a repository's page and every other
    /// link open as a link does, a web page in the browser.
    func open(_ url: URL) -> OpenURLAction.Result {
        guard let store, let target = CardNames.Target(url: url) else { return .systemAction }
        if case .repository = target { return .systemAction }
        let result = store.openCardLink(url)
        showMainWindow()
        return result
    }

    /// The main window comes to the front with the app, also once he closed it: after a press in the card that opens a
    /// page of the app there. The card's window stays over it.
    func showMainWindow() {
        store?.notifications.showWindow?()
        NSApp.activate()
        NSApp.windows.first { $0.identifier?.rawValue == SetupChannel.fleetWindow }?.makeKeyAndOrderFront(nil)
    }
}

extension EnvironmentValues {
    /// **The window that a request card stands in**, or nil for a card in a chat or on Needs you (`NeedWindows`). A card
    /// in a window draws no icon to open a window, has its long part open from the start, draws no fill and no edge of its
    /// own, opens the names of its words through it (`NeedWindowLink.open`), and tells it its key save
    /// (`NeedWindowLink.card`).
    @Entry var needWindow: NeedWindowLink? = nil
}

extension FleetStore {
    /// Every agent's presence, for the glyphs that are given none, as the main window gives it (`FleetView`): the
    /// glyphs and badges of a card's window take the same.
    var glyphPresences: [String: AgentPresence] {
        guard let state else { return [:] }
        var presences: [String: AgentPresence] = [:]
        for agent in state.agents {
            let open = state.tasks.filter { $0.owner == agent.name && !$0.isTerminal }
            presences[agent.name] = agent.presence(isFresh: marksMove, serverTime: state.time, openTasks: open,
                                                   holds: state.holds ?? [], waits: state.ownerWaits(of: open),
                                                   request: state.ownKeyRequest(of: agent.name), thinking: thinks(agent.name))
        }
        return presences
    }
}

/// The root of a card's window: the store's agents for the glyphs, the window's link, the dark look and his zoom.
private struct NeedWindowRoot: View {
    @Bindable var store: FleetStore
    let link: NeedWindowLink
    /// The card's height in the window's points, and its title, for the window.
    let fit: (CGFloat) -> Void
    let titled: (String) -> Void

    var body: some View {
        NeedWindowCard(store: store, link: link, fit: fit, titled: titled)
            .viewZoomed()
            .preferredColorScheme(.dark)
            .environment(\.needWindow, link)
            .environment(\.glyphTeam, store.state?.agents.map(\.name) ?? [])
            .environment(\.glyphPresence, store.glyphPresences)
            .environment(\.glyphAdding, Set((store.state?.agents ?? []).map(\.name).filter(store.isAdding)))
            .font(FleetStyle.body)
            .foregroundStyle(FleetStyle.text)
            .tint(FleetStyle.accent)
            .background(FleetStyle.surface)
    }
}

/// The card of the window's request, as the reading holds it now, under the band of the window's buttons, in a scroll.
private struct NeedWindowCard: View {
    @Bindable var store: FleetStore
    let link: NeedWindowLink
    let fit: (CGFloat) -> Void
    let titled: (String) -> Void
    @Environment(\.viewZoom) private var zoom

    var body: some View {
        let need = link.key.reading(in: store)
        // what the window's rule reads of the store (`NeedWindowEnd`): the request gone, replaced or answered, and its run
        let ends = [need == nil, need?.replaced_by != nil, need?.isOpen == true, store.needRuns[link.key.id]?.busy == true]
        ScrollView {
            if let need {
                NeedRequestCard(store: store, need: need)
                    .padding(.top, FleetSpace.lights)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fit($0 * zoom) }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        // The window's three buttons on the band's middle line, as the main window's (`windowButtonsCentred`).
        .windowButtonsCentred(inBand: FleetSpace.lights * zoom)
        .onChange(of: ends, initial: true) { _, _ in NeedWindows.check(link.key) }
        .onChange(of: need?.shownTitle, initial: true) { _, title in if let title { titled(title) } }
    }
}

/// **The keys of a card's own window that wait for its field of Needs clarification** (`NeedAnswerBox.holdWindowKeys`):
/// a watch of the app's keys that takes only keys of that window, while the field has no cursor yet. The chat has its
/// own route (`FleetStore.clarifying`, `FleetView.typeIntoBox`) and a step its own watch (`PageKeys`); a card's window
/// has neither, so its keys before the field's editor were lost. It holds a key that types or edits words: no Command
/// or Control, and none of Escape, Return, Enter and Tab, which do in that window what they did.
@MainActor final class ClarifyWindowKeys {
    /// The card's window (`OwnWindow`), which `ClarifyWindowKeysPlace` gives.
    let own = OwnWindow()
    private var watch: Any?
    /// The watch that runs now, so that an old one ends only itself.
    private var current = UUID()

    var window: NSWindow? { own.window }

    /// Takes the window's keys while `holding` says so, each one to `take`; then the watch ends by itself.
    func hold(while holding: @escaping () -> Bool, take: @escaping (NSEvent) -> Void) {
        stop()
        let own = own, id = UUID()
        current = id
        watch = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // The monitor runs on the main thread, before the window and its field see the key.
            let held = MainActor.assumeIsolated { () -> Bool in
                guard !AppFront.holdsKeys else { return false }     // no key after a front from outside (`AppFront`)
                guard holding() else {
                    DispatchQueue.main.async { MainActor.assumeIsolated { if self?.current == id { self?.stop() } } }
                    return false
                }
                guard let window = own.window, event.window === window, Self.types(event) else { return false }
                take(event)
                return true
            }
            return held ? nil : event
        }
    }

    func stop() {
        if let watch { NSEvent.removeMonitor(watch) }
        watch = nil
    }

    /// A key that types or edits words in a field: no Command or Control, no Escape, and of the special keys only the
    /// arrows and the two deletes.
    static func types(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control]).isEmpty, event.keyCode != 53 else { return false }
        guard let special = event.specialKey else { return true }
        return [.delete, .deleteForward, .leftArrow, .rightArrow, .upArrow, .downArrow].contains(special)
    }
}

/// The place of a card's window keys (`ClarifyWindowKeys`): its window, and its end with the answer box. A card in a
/// chat and a step pass nil, and stay as they are.
struct ClarifyWindowKeysPlace: ViewModifier {
    let keys: ClarifyWindowKeys?

    func body(content: Content) -> some View {
        if let keys {
            content.ownWindow(keys.own).onDisappear { keys.stop() }
        } else {
            content
        }
    }
}
