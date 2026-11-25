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
///
/// **His answer in it closes it at once, as the badge of that answer** (the owner, 23 November 2026: "When I reply to a
/// card, it should do the animation and close immediately ... a small floating badge on the side that says Undo", and
/// his answer F22-2 (a) to its picture): while his answer waits its 5 seconds (`AnswerHolds`, place `.window`), the
/// card window shrinks into a capsule window "✓ <answer>  Undo" at its top-right corner, over 0.25 s, ease-out, and
/// that capsule floats as the card window does (`Shown.becomeBadge`). Its Undo grows it back into the card, as it was,
/// with its top-right corner where the capsule stands and inside the screen, and the card takes the keys again. The
/// capsule takes the keys only where the card had them: ⌘Z takes the answer back there, and VoiceOver hears the answer
/// when the card becomes it. When the hold ends (5 seconds, his next answer anywhere, a quit), the capsule fades out
/// over 0.12 s and the window closes, before the hub has the answer, as a card in a chat folds with it: a send that
/// does not go leaves the request open on Needs you, with the line of what did not go under the main window's page
/// (`PendingBar`). Under Reduce Motion each change comes in one frame. A key card is never held, so it never becomes a
/// badge.
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

    fileprivate static var shown: [Key: Shown] = [:]

    /// **The room that a card's window opens and fits in**, in place of its screen's visible frame: a test gives one off
    /// every screen, so that no window of a test stands on his screen, and the card's window stays in it
    /// (`NeedPanel.constrainFrameRect`). Nil: the screen's.
    static var room: NSRect?

    /// The visible room of the screen that `frame` stands on, or the test's room.
    fileprivate static func visibleRoom(around frame: NSRect, screen: NSScreen?) -> NSRect {
        room ?? (screen ?? NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// The window that the card of `need` stands in now: its own, or the capsule window of his held answer that it
    /// became (`Shown.becomeBadge`). A test reads it.
    static func window(of need: Int) -> NSWindow? {
        guard let open = shown.first(where: { $0.key.id == need })?.value else { return nil }
        return open.badgePanel ?? open.panel
    }

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
        let place = frame()
        let panel = NeedPanel(contentRect: place, styleMask: [.titled, .closable, .resizable, .fullSizeContentView,
                                                              .nonactivatingPanel],
                              backing: .buffered, defer: false)
        // in a test's room off every screen: AppKit made the window on a screen
        if room != nil { panel.setFrame(place, display: false) }
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
    static func stepAside(_ key: Key) { shown[key]?.panel.orderOut(nil) }

    static func comeBack(_ key: Key) {
        guard let open = shown[key], !open.closing else { return }
        open.panel.orderFront(nil)
    }

    fileprivate static func check(_ key: Key) {
        guard let open = shown[key], !open.closing, let store = open.link.store else { return }
        guard NeedWindowEnd.closes(reading: key.reading(in: store), runs: store.needRuns[key.id]?.busy == true,
                                   keySave: open.link.keySave) else { return }
        // as the badge of his answer: the badge fades out, and the window closes then
        if open.badgePanel != nil { open.badgeWent(still: FleetMotion.reduced); return }
        open.closing = true
        DispatchQueue.main.async { open.panel.close() }
    }

    /// The window closed, by his press or by itself.
    fileprivate static func closed(_ key: Key) {
        guard let open = shown.removeValue(forKey: key) else { return }
        // the card's own frame, also when the window closes as the badge of his answer (its hold ended, or the request
        // went meanwhile)
        let frame = open.cardPlace ?? open.panel.frame
        open.dropBadge()
        if let watch = open.quitWatch { NotificationCenter.default.removeObserver(watch) }
        keep(frame)
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
        let place = keptScreen == nil || Self.room != nil ? nil : kept
        let main = NSApp.windows.first { $0.identifier?.rawValue == SetupChannel.fleetWindow }
        let room = Self.room ?? (keptScreen ?? main?.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
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
    @MainActor fileprivate final class Shown: NSObject, NSWindowDelegate {
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
        /// **The capsule window that this window became while his answer in it waits** (`becomeBadge`), and the card's
        /// frame before it, which Undo gives back.
        private var badge: NeedBadgePanel?
        private var cardFrame: NSRect?
        private let motion = PanelMotion()
        private let badgeFade = WindowFade()

        init(key: Key, panel: NeedPanel, link: NeedWindowLink) {
            self.key = key
            self.panel = panel
            self.link = link
        }

        /// The card's height, in the window's points: the window takes it, with its top where it stands, up to the
        /// screen's visible height less a margin, and not under the screen's visible bottom.
        func fit(_ height: CGFloat) {
            cardHeight = height
            guard !ownHeight, !panel.inLiveResize, badge == nil, !motion.runs else { return }
            let room = NeedWindows.visibleRoom(around: panel.frame, screen: panel.screen)
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

        /// His press of the card's icon again: the window comes to the front, or comes as it is ready (`show`); as the
        /// badge of his answer, the badge does.
        func front() {
            if let badge { badge.orderFront(nil); return }
            if onScreen { panel.makeKeyAndOrderFront(nil) }
        }

        /// **His answer in this window waits: the window becomes its badge** (F22-2 (a)). The card window shrinks into a
        /// capsule window at its top-right corner, over 0.25 s, ease-out, and fades as the capsule comes; then the card
        /// window stands hidden behind it, as it was, for Undo. A new look of the same answer changes only the capsule's
        /// words. `still`: Reduce Motion, all in one frame.
        func becomeBadge(_ look: AnswerBadge.Look, need: OwnerNeed, store: FleetStore, still: Bool) {
            guard !closing, onScreen else { return }
            let host = NeedBadgeHosting(rootView: AnswerBadgeCapsule(look: look, title: need.shownTitle) {
                AnswerHolds.shared.undo(need, store: store)
            }
                .frame(maxWidth: panel.frame.width, alignment: .trailing)
                .font(FleetStyle.body).tint(FleetStyle.accent).preferredColorScheme(.dark))
            let size = host.fittingSize
            if let badge {
                let top = badge.frame.maxY, right = badge.frame.maxX
                badge.contentView = host
                badge.setFrame(NSRect(x: right - size.width, y: top - size.height, width: size.width, height: size.height),
                               display: true)
                return
            }
            let card = panel.frame
            let hadKeys = panel.isKeyWindow
            cardFrame = card
            let target = NSRect(x: card.maxX - size.width, y: card.maxY - size.height, width: size.width, height: size.height)
            let badge = NeedBadgePanel(contentRect: target, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                                       defer: false)
            badge.isFloatingPanel = true
            badge.level = .floating
            badge.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            badge.hidesOnDeactivate = false
            badge.isReleasedWhenClosed = false
            badge.isExcludedFromWindowsMenu = true
            badge.isMovableByWindowBackground = true
            badge.isOpaque = false
            badge.backgroundColor = .clear
            badge.hasShadow = true
            badge.appearance = NSAppearance(named: .darkAqua)
            badge.title = need.shownTitle
            badge.identifier = NSUserInterfaceItemIdentifier("need-window-badge-\(key.id)")
            badge.contentView = host
            badge.takesKeys = hadKeys
            self.badge = badge
            // **Edit › Undo (⌘Z) takes it back while the badge has the keys**, as the sidebar's badge does for an
            // answer on a page; Tab reaches its Undo with the keyboard's full access
            badge.undoManager?.registerUndo(withTarget: self) { _ in
                MainActor.assumeIsolated { AnswerHolds.shared.undo(need, store: store) }
            }
            // VoiceOver's focus was on what he pressed, which went: it hears his answer
            let words = look.words == String(l10n: "Answered") ? look.words : String(l10n: "Answered: \(look.words)")
            AccessibilityNotification.Announcement(words).post()
            let show = { [weak badge] in
                guard let badge else { return }
                if hadKeys { badge.makeKeyAndOrderFront(nil) } else { badge.orderFront(nil) }
            }
            if still {
                motion.stop()
                panel.orderOut(nil)
                badge.alphaValue = 1
                show()
                return
            }
            badge.alphaValue = 0
            show()
            badgeFade.run(badge, to: 1, over: 0.25)
            placing = true
            motion.run(panel, to: target, alpha: 0, over: 0.25) { [weak self] in
                guard let self else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
                self.placing = false
            }
        }

        /// **The card's frame with its top-right corner where the badge stands** (he may have moved the badge), inside
        /// the visible room of the badge's screen; nil while the window is no badge.
        var cardPlace: NSRect? {
            guard let badge, let card = cardFrame else { return nil }
            let room = NeedWindows.visibleRoom(around: badge.frame, screen: badge.screen)
            var frame = NSRect(x: badge.frame.maxX - card.width, y: badge.frame.maxY - card.height, width: card.width,
                               height: min(card.height, room.height))
            frame.origin.x = min(max(frame.minX, room.minX), room.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, room.minY), room.maxY - frame.height)
            return frame
        }

        /// **Undo of his answer: the badge grows back into the card**, as it was, with its top-right corner where the
        /// badge stands and inside the screen (`cardPlace`), over 0.25 s, and the card takes the keys, also after
        /// VoiceOver's action, which gives the badge none. `still`: in one frame. Not while the window closes.
        func becomeCard(still: Bool) {
            guard !closing, let badge, let frame = cardPlace else { return }
            badge.undoManager?.removeAllActions(withTarget: self)
            self.badge = nil
            cardFrame = nil
            motion.stop()
            badgeFade.stop()
            placing = true
            // the capsule goes at once, and the card grows from its place (a fade of its own would race the next badge's)
            let from = badge.frame
            badge.orderOut(nil)
            badge.close()
            if still {
                panel.setFrame(frame, display: true)
                panel.alphaValue = 1
                panel.makeKeyAndOrderFront(nil)
                placing = false
                NeedWindows.keep(panel.frame)
                if let cardHeight { fit(cardHeight) }
                return
            }
            panel.setFrame(from, display: false)
            panel.alphaValue = 0.3
            panel.makeKeyAndOrderFront(nil)
            motion.run(panel, to: frame, alpha: 1, over: 0.25) { [weak self] in
                guard let self else { return }
                self.placing = false
                NeedWindows.keep(self.panel.frame)
                if let height = self.cardHeight { self.fit(height) }
            }
        }

        /// **His answer went** (its hold ended: 5 seconds, his next answer, a quit), **or the request went meanwhile**
        /// (`NeedWindows.check`): the badge fades out over 0.12 s, and the window closes then, with the card's own
        /// frame kept for the next window (`closed`). `still`: at once, and the close after the change of the window's
        /// own view that asked it, as `check` closes.
        func badgeWent(still: Bool) {
            guard let badge, !closing else { return }
            closing = true
            badge.undoManager?.removeAllActions(withTarget: self)
            if still {
                badge.orderOut(nil)
                DispatchQueue.main.async { self.panel.close() }
                return
            }
            badgeFade.run(badge, to: 0, over: FleetMotion.cardOut) { [weak self] in
                badge.orderOut(nil)
                self?.panel.close()
            }
        }

        /// The window goes: its badge with it.
        func dropBadge() {
            motion.stop()
            badgeFade.stop()
            badge?.undoManager?.removeAllActions(withTarget: self)
            badge?.orderOut(nil)
            badge?.close()
            badge = nil
        }

        /// The window shows as the badge of his answer now (a test reads it).
        var badgePanel: NSPanel? { badge }

        func windowWillClose(_ notification: Notification) {
            // an answer given in this window and that waits with Undo goes at once: the window of its Undo closed
            // (`AnswerHolds`); an answer of the same request given on a page keeps its own badge and its hold
            if AnswerHolds.shared.held[key.id]?.place == .window { AnswerHolds.shared.release(key.id) }
            NeedWindows.closed(key)
        }

        func windowDidMove(_ notification: Notification) {
            guard badge == nil else { return }
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

    /// **A test's room off every screen keeps the window** (`NeedWindows.room`): AppKit moves a titled window that it
    /// orders in or moves off every screen onto a screen, so the card's window of a view test stood on his screen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        NeedWindows.room == nil ? super.constrainFrameRect(frameRect, to: screen) : frameRect
    }

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

    /// **The take-over card stands over the main window** (`TakeOverCard`): this window steps aside, so that it covers
    /// no part of the agent's screen, and comes back when the card closes with the request still open.
    func stepAside() { NeedWindows.stepAside(key) }
    func comeBack() { NeedWindows.comeBack(key) }

    /// **His answer in this window waits, went or was taken back** (`NeedWindowCard`): the window becomes its badge,
    /// closes, or becomes the card again (F22-2 (a)).
    func badge(_ look: AnswerBadge.Look, need: OwnerNeed, store: FleetStore, still: Bool) {
        NeedWindows.shown[key]?.becomeBadge(look, need: need, store: store, still: still)
    }
    func answerWent(still: Bool) { NeedWindows.shown[key]?.badgeWent(still: still) }
    func answerBack(still: Bool) { NeedWindows.shown[key]?.becomeCard(still: still) }

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// **His answer in this window**: it waits (the window is its badge), it went, or it is none.
    private enum Answer: Equatable {
        case nothing, waits(AnswerBadge.Look), went
    }

    var body: some View {
        let need = link.key.reading(in: store)
        // what the window's rule reads of the store (`NeedWindowEnd`): the request gone, replaced or answered, and its run
        let ends = [need == nil, need?.replaced_by != nil, need?.isOpen == true, store.needRuns[link.key.id]?.busy == true]
        // his answer given in this window (`AnswerHolds.Place.window`), held or now on its way out of the hold
        let held = need.flatMap { AnswerHolds.shared.held($0, in: store) }.flatMap { $0.place == .window ? $0 : nil }
        let leaving = need.flatMap { AnswerHolds.shared.leaving($0, in: store) }.flatMap { $0.place == .window ? $0 : nil }
        let answer: Answer = held.map { Answer.waits(AnswerBadge.Look($0.shown)) }
            ?? (leaving != nil ? Answer.went : Answer.nothing)
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
        // the window becomes the badge of his answer, goes with it, or comes back as the card (F22-2 (a))
        .onChange(of: answer, initial: true) { before, now in
            switch now {
            case .waits(let look):
                guard let need else { return }
                link.badge(look, need: need, store: store, still: reduceMotion)
            case .went:
                // the hold ended: the badge goes, and the window with it; a send that does not go leaves the request
                // open on Needs you, with its line under the main window's page
                link.answerWent(still: reduceMotion)
            case .nothing:
                // his Undo: the card comes back (a request that went meanwhile closes by the window's rule)
                if case .waits = before, need?.isOpen == true { link.answerBack(still: reduceMotion) }
            }
        }
    }
}

/// **The capsule window of a card window's held answer** (`NeedWindows.Shown.becomeBadge`): it floats as the card
/// window does; it takes the keys only where the card had them (`takesKeys`), never the main window, so that ⌘Z and
/// Tab reach its Undo there, and a drag of it while another app is in front leaves that app the keys; its first click
/// acts at once (`NeedBadgeHosting`), and Esc does not close it, as it does not close the card's window.
private final class NeedBadgePanel: NSPanel {
    var takesKeys = false
    override var canBecomeKey: Bool { takesKeys }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) {}
}

/// The capsule's views: a first click acts at once, as in the card window (`NeedHosting`).
private final class NeedBadgeHosting<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// **A window's frame and alpha from where they stand to an end, over a time, ease-out** (the card window that becomes
/// a badge, and back): its own clock, 120 times a second, as `WindowFade` sets an alpha. A new run takes the place of the
/// one before it; a run whose owner is gone ends its own timer.
@MainActor private final class PanelMotion {
    private var timer: Timer?
    private var step: (() -> Void)?
    var runs: Bool { timer != nil }

    func run(_ window: NSWindow, to end: NSRect, alpha: CGFloat, over seconds: Double,
             then done: @escaping @MainActor () -> Void = {}) {
        stop()
        let start = window.frame, from = window.alphaValue, began = CACurrentMediaTime()
        step = { [weak self, weak window] in
            guard let self else { return }
            guard let window else { self.stop(); return }
            let passed = min(1, (CACurrentMediaTime() - began) / max(seconds, 0.001))
            let eased = 1 - (1 - passed) * (1 - passed)
            func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * eased }
            window.setFrame(NSRect(x: mix(start.minX, end.minX), y: mix(start.minY, end.minY),
                                   width: mix(start.width, end.width), height: mix(start.height, end.height)), display: true)
            window.alphaValue = mix(from, alpha)
            if passed >= 1 {
                self.stop()
                done()
            }
        }
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            guard self != nil else { timer.invalidate(); return }
            MainActor.assumeIsolated { self?.step?() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        step = nil
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
