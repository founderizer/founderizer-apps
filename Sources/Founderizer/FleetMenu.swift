import AppKit
import FleetCore
import SwiftUI

// **The app's one menu** (the owner, 10 November 2026, with Grok's right-click menu beside it: "for the right click
// context menu I prefer the attached style (from grok bot), which breathes more. same in other context menus too"): a
// dark panel with round corners, rows of 32 points with words of 14 points and a muted symbol before them, the
// highlight a rounded fill inside the panel's inset of 6 points, groups parted by a line that stops short of the
// edges, and an item that deletes in red. It draws every right-click menu of the app (`FleetContextMenus`) and every
// list of a `FleetSelect`, so the right-click of an agent's row and the "…" of its Runs on are one menu.
//
// It is a window of its own that never takes the keyboard, as a macOS menu: the window under it keeps its key focus
// (the composer keeps its cursor), its own watch of the keys takes the arrows, Return, Esc and a filter's letters while
// it is open, and a click anywhere else closes it and goes no further.

/// The measures of the menu, from the reference (Grok's right-click menu, measured on his screenshot).
enum FleetMenuMetrics {
    /// The least and the most width of the panel: the reference is 200 points wide.
    static let minWidth: CGFloat = 200, maxWidth: CGFloat = 380
    /// The panel's corners, and the room between its edge and a row's highlight.
    static let radius: CGFloat = 16, inset: CGFloat = 6
    /// A row of one line, a row with a muted line under its title, the room between two rows, and the corners of the
    /// highlight, which follow the panel's.
    static let row: CGFloat = 32, twoLineRow: CGFloat = 46, spacing: CGFloat = 2, rowRadius: CGFloat = 10
    /// From a row's edge to its mark, the mark's column and the room after it: the words begin 39 points from the
    /// panel's edge, as in the reference. A row's words end 12 points before its edge.
    static let lead: CGFloat = 9, markColumn: CGFloat = 18, markGap: CGFloat = 6, trail: CGFloat = 12
    static let font = Font.system(size: 14)
    static let detail = Font.system(size: 12)
    /// A row's symbol: 14 points in the light weight, whose thin lines are the reference's (15 points in the regular
    /// weight stood heavier than the words beside them).
    static let symbol: CGFloat = 14
    static let symbolWeight = Font.Weight.light, symbolImageWeight = NSFont.Weight.light
    /// The line between two groups: 8 points in from a row's edges (14 from the panel's) and 4 points over and under
    /// it, besides the rows' own spacing.
    static let lineInset: CGFloat = 8, lineSpace: CGFloat = 4
    /// The most height of the rows before they scroll.
    static let maxHeight: CGFloat = 420
    /// Between a control and the list under it.
    static let gap: CGFloat = 4
    /// Its fill, a step over the rail (#202020) and the cards it opens on, and the highlight over that fill.
    static let fill = Color(white: 0.15)
    static let highlight = Color.white.opacity(0.07)
    /// The words of an item that deletes: the danger button's red (`FleetDangerButtonStyle`).
    static let danger = Color(red: 0.93, green: 0.42, blue: 0.38)
}

/// One item of the menu.
struct FleetMenuItem {
    var title: String
    /// One muted line under the title.
    var subtitle: String?
    /// A short muted word after the title: an ID or a count.
    var detail: String?
    var mark: FleetSelectMark = .none
    /// The check mark of a list's selection.
    var checked = false
    var enabled = true
    /// An item that deletes, in red.
    var destructive = false
    /// The heading of its group, which shows where the section changes; a section of spaces alone is a line between
    /// two groups (the agent's one menu), and an item with no section stands in the first group.
    var section: String?
}

/// What the menu shows now: its items, the highlighted one and a list's filter.
@MainActor final class FleetMenuModel: ObservableObject {
    let items: [FleetMenuItem]
    /// A list of more than eight rows filters as the owner types.
    let filters: Bool
    /// The most height of the rows here: less than `FleetMenuMetrics.maxHeight` where the screen has less room.
    let maxHeight: CGFloat
    @Published var highlighted: Int?
    /// The row that the keys moved to: the list scrolls to it, and the pointer does not scroll it.
    @Published var scrolledTo: Int?
    /// A filter's words: the first row that matches takes the highlight, as the keys own it until the pointer moves.
    @Published var query = "" {
        didSet { pointer = nil; highlighted = shown.first { items[$0].enabled }; scrolledTo = highlighted }
    }
    /// The width of the full list, kept while a filter hides rows.
    @Published var width: CGFloat?
    /// Each shown row's frame in the panel's own points, for the pointer (`FleetMenuSurface`).
    private(set) var frames: [Int: CGRect] = [:]
    /// The part of the panel where rows show, in its own points: a row scrolled out of it keeps a frame under the
    /// filter's field or past the panel's edge, and the pointer must not find it there.
    var visible: CGRect?
    /// Where the pointer stands in the panel, in its own points: nil outside it, and after a key moved the highlight,
    /// until the pointer moves again.
    private var pointer: CGPoint?
    var choose: (Int) -> Void = { _ in }
    /// The words typed to jump to an item of a menu that does not filter, and when the last letter came.
    private var typed = "", typedAt = Date.distantPast

    init(items: [FleetMenuItem], filters: Bool, highlighted: Int?, maxHeight: CGFloat) {
        self.items = items; self.filters = filters; self.highlighted = highlighted; self.maxHeight = maxHeight
    }

    /// The rows that show, as indices of `items`.
    var shown: [Int] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return Array(items.indices) }
        return items.indices.filter { index in
            [items[index].title, items[index].detail, items[index].subtitle].contains { $0?.localizedStandardContains(text) == true }
        }
    }

    /// Whether any row has a mark: then every row keeps the mark's column, so their words begin at one place.
    var marks: Bool { items.contains { !$0.mark.isNone } }
    /// Whether any row has the check mark: then every row keeps its column.
    var checks: Bool { items.contains(where: \.checked) }

    /// The shown row under a point of the panel, in its own points, only where the rows show.
    func row(at point: CGPoint) -> Int? {
        guard visible?.contains(point) ?? true else { return nil }
        return shown.first { frames[$0]?.contains(point) == true }
    }

    /// The pointer at a point of the panel, or out of it: the row under it takes the highlight, and an item that cannot
    /// act takes none, as in a macOS menu.
    func point(_ at: CGPoint?) {
        pointer = at
        hover(at.flatMap(row(at:)))
    }

    /// A row's new frame: when the rows move under a pointer that did not (the wheel, a filter), the highlight follows
    /// the row under it, as in a macOS menu.
    func framed(_ index: Int, _ frame: CGRect) {
        frames[index] = frame
        if let pointer { hover(row(at: pointer)) }
    }

    private func hover(_ index: Int?) {
        let next = index.flatMap { items[$0].enabled ? $0 : nil }
        if highlighted != next { highlighted = next }
    }

    /// The arrow keys: the next item that can act, or the one before; the first or the last when none is highlighted.
    func step(_ by: Int) {
        let choosable = shown.filter { items[$0].enabled }
        guard !choosable.isEmpty else { return }
        let next: Int
        if let highlighted, let at = choosable.firstIndex(of: highlighted) {
            next = choosable[min(max(at + by, 0), choosable.count - 1)]
        } else {
            next = by > 0 ? choosable[0] : choosable[choosable.count - 1]
        }
        pointer = nil
        highlighted = next; scrolledTo = next
    }

    /// Letters in a menu that does not filter: the next item whose title begins with them, as in a macOS menu.
    func jump(_ letters: String) {
        typed = Date.now.timeIntervalSince(typedAt) < 1 ? typed + letters : letters
        typedAt = .now
        let choosable = shown.filter { items[$0].enabled }
        let start = highlighted.flatMap { choosable.firstIndex(of: $0) }.map { typed.count == 1 ? $0 + 1 : $0 } ?? 0
        let order = Array(choosable[min(start, choosable.count)...]) + Array(choosable[..<min(start, choosable.count)])
        if let hit = order.first(where: { items[$0].title.lowercased().hasPrefix(typed.lowercased()) }) {
            pointer = nil
            highlighted = hit; scrolledTo = hit
        }
    }
}

/// The menu's panel as it is drawn: the filter of a long list, the rows, and the lines and headings of their groups.
struct FleetMenuList: View {
    @ObservedObject var model: FleetMenuModel
    @Environment(\.colorSchemeContrast) private var contrast
    /// The panel's own points, in which each row gives its frame.
    static let space = "fleetMenu"

    var body: some View {
        let shown = model.shown
        let shape = RoundedRectangle(cornerRadius: FleetMenuMetrics.radius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            if model.filters {
                filterField
                Rectangle().fill(FleetStyle.hairline(0.1)).frame(height: 0.5).accessibilityHidden(true)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: FleetMenuMetrics.spacing) {
                        ForEach(Array(shown.enumerated()), id: \.element) { position, index in
                            if let section = model.items[index].section,
                               position == 0 ? !section.trimmingCharacters(in: .whitespaces).isEmpty
                                             : model.items[shown[position - 1]].section != section {
                                header(section, first: position == 0)
                            }
                            row(index)
                        }
                        if shown.isEmpty {
                            Text("No matches").font(FleetMenuMetrics.font).foregroundStyle(FleetStyle.muted)
                                .padding(.horizontal, FleetMenuMetrics.lead)
                                .frame(height: FleetMenuMetrics.row)
                        }
                    }
                    .padding(FleetMenuMetrics.inset)
                }
                .frame(maxHeight: model.maxHeight).fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { model.visible = $0 }
                .onChange(of: model.scrolledTo) { _, index in if let index { proxy.scrollTo(index) } }
                .onAppear { if let highlighted = model.highlighted { proxy.scrollTo(highlighted, anchor: .center) } }
            }
        }
        .frame(minWidth: FleetMenuMetrics.minWidth, maxWidth: FleetMenuMetrics.maxWidth, alignment: .leading)
        .frame(width: model.width)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { if model.width == nil, model.filters { model.width = $0 } }
        .background(FleetMenuMetrics.fill, in: shape)
        .overlay(shape.strokeBorder(FleetStyle.hairline(0.1), lineWidth: FleetStyle.edgeWidth(contrast)))
        .clipShape(shape)
        .coordinateSpace(.named(Self.space))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private var filterField: some View {
        HStack(spacing: FleetMenuMetrics.markGap) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(FleetStyle.muted)
                .frame(width: FleetMenuMetrics.markColumn)
            Text(model.query.isEmpty ? "Type to filter" : model.query).lineLimit(1)
                .foregroundStyle(model.query.isEmpty ? FleetStyle.muted : FleetStyle.text)
            Spacer(minLength: 0)
        }
        .font(FleetMenuMetrics.font)
        .padding(.horizontal, FleetMenuMetrics.inset + FleetMenuMetrics.lead).frame(height: 38)
        .accessibilityElement(children: .combine)
    }

    /// A group's heading, or, for a section of spaces alone, the line between two groups.
    @ViewBuilder private func header(_ title: String, first: Bool) -> some View {
        if title.trimmingCharacters(in: .whitespaces).isEmpty {
            Rectangle().fill(FleetStyle.hairline(0.1)).frame(height: 0.5)
                .padding(.horizontal, FleetMenuMetrics.lineInset).padding(.vertical, FleetMenuMetrics.lineSpace)
                .accessibilityHidden(true)
        } else {
            Text(title).font(FormMetrics.detailTitle).foregroundStyle(FleetStyle.muted).lineLimit(1)
                .padding(.horizontal, FleetMenuMetrics.lead).padding(.top, first ? 4 : 10).padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func row(_ index: Int) -> some View {
        let item = model.items[index]
        let words: Color = !item.enabled ? FleetStyle.muted : item.destructive ? FleetMenuMetrics.danger : FleetStyle.text
        let markTint: Color = item.destructive && item.enabled ? FleetMenuMetrics.danger : FleetStyle.muted
        return HStack(spacing: FleetMenuMetrics.markGap) {
            if model.marks {
                FleetMenuMark(mark: item.mark, tint: markTint).opacity(item.enabled ? 1 : 0.5)
                    .frame(width: FleetMenuMetrics.markColumn)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.title).font(FleetMenuMetrics.font).foregroundStyle(words)
                    if let detail = item.detail { Text(detail).font(FleetMenuMetrics.detail).foregroundStyle(FleetStyle.muted) }
                }
                if let subtitle = item.subtitle { Text(subtitle).font(FleetMenuMetrics.detail).foregroundStyle(FleetStyle.muted) }
            }.lineLimit(1)
            Spacer(minLength: 12)
            if model.checks {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(FleetStyle.text)
                    .opacity(item.checked ? 1 : 0).accessibilityHidden(true)
            }
        }
        .padding(.leading, FleetMenuMetrics.lead).padding(.trailing, FleetMenuMetrics.trail)
        .frame(minHeight: item.subtitle == nil ? FleetMenuMetrics.row : FleetMenuMetrics.twoLineRow)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(model.highlighted == index ? FleetMenuMetrics.highlight : .clear,
                    in: RoundedRectangle(cornerRadius: FleetMenuMetrics.rowRadius, style: .continuous))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { model.framed(index, $0) }
        .id(index)
        // A row is a button for assistive apps, and their press chooses it as a click or Return does.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.title, item.detail, item.mark.presence?.label, item.subtitle].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(item.checked ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { if item.enabled { model.choose(index) } }
        // An item that cannot act is dimmed for VoiceOver, as the system's menu says it.
        .disabled(!item.enabled)
    }
}

/// A row's mark: a symbol in the menu's own size, in the muted colour (red for an item that deletes), and the other
/// marks as a select draws them.
private struct FleetMenuMark: View {
    let mark: FleetSelectMark
    let tint: Color

    var body: some View {
        switch mark {
        case .symbol(let name):
            Image(systemName: name).font(.system(size: FleetMenuMetrics.symbol, weight: FleetMenuMetrics.symbolWeight))
                .foregroundStyle(tint)
        case .image(let image): Image(nsImage: image).renderingMode(.template).foregroundStyle(tint)
        default: FleetSelectMarkView(mark: mark, size: FleetMenuMetrics.markColumn)
        }
    }
}

/// The view that the menu's panel holds. It takes every event of the pointer itself, so the panel never needs the
/// keyboard: its tracking area watches the pointer in a window that is not key, and the rows answer by their frames.
/// The scroll wheel goes on to the list's own scroll view (SwiftUI's `ScrollView` is an `NSScrollView` in it).
private final class FleetMenuSurface: NSView {
    let model: FleetMenuModel
    /// The zoom the menu is drawn at (View › Bigger): the rows' frames are in the panel's points before it.
    var zoom: CGFloat = 1
    private var area: NSTrackingArea?
    /// A wheel event on its way to the list's scroll view (`scrollWheel`).
    private var forwarding = false

    init(model: FleetMenuModel, content: NSView) {
        self.model = model
        super.init(frame: .zero)
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard frame.contains(point) else { return nil }
        // The list's scroll bar takes its own drag: one that stands in a room of its own everywhere, and one that lies
        // over the rows' right ends (an overlay scroll bar, which is there also while it is faded) only on its knob, so
        // a click on a row's end still chooses the row. Every other event of the pointer is this view's.
        if let hit = super.hitTest(point),
           let scroller = sequence(first: hit, next: { $0.superview }).first(where: { $0 is NSScroller }) as? NSScroller,
           scroller.scrollerStyle == .legacy || scroller.rect(for: .knob).contains(scroller.convert(point, from: superview)) {
            return hit
        }
        return self
    }

    override func scrollWheel(with event: NSEvent) {
        // A list that cannot scroll that way (a short list, a sideways swipe, its end) sends the wheel back up its
        // responders, which reach this view again: it stops here, or the two would send it to each other for ever.
        guard !forwarding, let list = Self.scrollView(in: self) else { return }
        forwarding = true
        list.scrollWheel(with: event)
        forwarding = false
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        for child in view.subviews {
            if let list = child as? NSScrollView ?? scrollView(in: child) { return list }
        }
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let made = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
                                  owner: self)
        addTrackingArea(made)
        area = made
    }

    /// A point of the window in the panel's own points, before the zoom.
    func point(atWindowPoint point: NSPoint) -> CGPoint {
        let local = convert(point, from: nil)
        return CGPoint(x: local.x / zoom, y: local.y / zoom)
    }

    /// The row under a point of the window.
    func row(atWindowPoint point: NSPoint) -> Int? { model.row(at: self.point(atWindowPoint: point)) }

    /// The pointer of an event inside the panel, or out of it.
    private func track(_ event: NSEvent) {
        let at = point(atWindowPoint: event.locationInWindow)
        model.point(bounds.contains(convert(event.locationInWindow, from: nil)) ? at : nil)
    }

    override func mouseMoved(with event: NSEvent) { track(event) }
    override func mouseEntered(with event: NSEvent) { track(event) }
    override func mouseExited(with event: NSEvent) { model.point(nil) }
    override func mouseDown(with event: NSEvent) { track(event) }
    override func mouseDragged(with event: NSEvent) { track(event) }
    override func rightMouseDown(with event: NSEvent) { track(event) }
    override func rightMouseDragged(with event: NSEvent) { track(event) }
    override func otherMouseDown(with event: NSEvent) {}

    /// The release over an item chooses it, with either button, as in a macOS menu.
    override func mouseUp(with event: NSEvent) { release(at: event.locationInWindow) }
    override func rightMouseUp(with event: NSEvent) { release(at: event.locationInWindow) }

    func release(at point: NSPoint) {
        guard let index = row(atWindowPoint: point), model.items[index].enabled else { return }
        model.choose(index)
    }
}

/// The menu's window. It takes the keyboard only for VoiceOver, so that its rows can be read and pressed there.
private final class FleetMenuPanel: NSPanel {
    var keyable = false
    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }
}

/// **The one menu that is open**, and its watches: a click anywhere else, the scroll wheel elsewhere, another app and
/// a move of the window under it close it; its keys are the arrows, Return, Space, Esc and a filter's letters.
@MainActor enum FleetMenu {
    enum Place {
        /// A right-click's menu, at the pointer (screen points).
        case pointer(NSPoint)
        /// A list under its control (the control's frame in screen points).
        case under(NSRect)
    }

    private final class Shown {
        let panel: FleetMenuPanel
        let model: FleetMenuModel
        let surface: FleetMenuSurface
        weak var host: NSWindow?
        weak var owner: AnyObject?
        let place: Place
        let screen: NSRect
        /// The event that opened it, which its own watches must not take as a click elsewhere.
        let opened: TimeInterval
        let start: NSPoint
        let choose: (Int) -> Void
        let closed: () -> Void
        var watches: [Any] = []
        var observers: [NSObjectProtocol] = []

        init(panel: FleetMenuPanel, model: FleetMenuModel, surface: FleetMenuSurface, host: NSWindow?, owner: AnyObject?,
             place: Place, screen: NSRect, opened: TimeInterval, choose: @escaping (Int) -> Void, closed: @escaping () -> Void) {
            self.panel = panel; self.model = model; self.surface = surface; self.host = host; self.owner = owner
            self.place = place; self.screen = screen; self.opened = opened; self.choose = choose; self.closed = closed
            start = NSEvent.mouseLocation
        }
    }

    private static var shown: Shown?

    static var isOpen: Bool { shown != nil }

    /// Opens the menu, in place of the one that is open. `choose` gets the index of the chosen item after the menu
    /// closed, and `closed` comes whenever it closes.
    static func show(_ items: [FleetMenuItem], highlighted: Int? = nil, filters: Bool = false, at place: Place,
                     over host: NSWindow?, zoom: CGFloat, owner: AnyObject? = nil, opened: TimeInterval? = nil,
                     choose: @escaping (Int) -> Void, closed: @escaping () -> Void = {}) {
        close()
        guard !items.isEmpty else { closed(); return }
        let point: NSPoint
        switch place {
        case .pointer(let at): point = at
        case .under(let control): point = NSPoint(x: control.midX, y: control.midY)
        }
        let screen = (NSScreen.screens.first { $0.frame.contains(point) } ?? host?.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let room: CGFloat
        switch place {
        case .pointer(let at): room = MenuPlacement.room(pointer: at, screen: screen)
        case .under(let control): room = MenuPlacement.room(control: control, screen: screen, gap: FleetMenuMetrics.gap)
        }
        // The rows' most height, less the panel's inset and a filter's field, at the zoom it is drawn at.
        let maxHeight = max(FleetMenuMetrics.row * 3,
                            min(FleetMenuMetrics.maxHeight, room / zoom - FleetMenuMetrics.inset * 2 - (filters ? 39 : 0)))
        let model = FleetMenuModel(items: items, filters: filters, highlighted: highlighted, maxHeight: maxHeight)
        // Drawn at the zoom of the window it opens from (View › Bigger), as the window's own content is.
        let hosting = NSHostingView(rootView: FleetMenuList(model: model).fixedSize()
            .zoomedAsItsWindow().environment(\.viewZoom, zoom)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in resize(to: size) })
        hosting.sizingOptions = [.intrinsicContentSize]
        let surface = FleetMenuSurface(model: model, content: hosting)
        surface.zoom = zoom
        let panel = FleetMenuPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        // VoiceOver's menu takes the keyboard, but only in the app in front: a right-click in a window behind another
        // app comes without that app's keyboard, and the menu must not take it.
        panel.keyable = NSWorkspace.shared.isVoiceOverEnabled && NSApp.isActive
        panel.contentView = surface
        let open = Shown(panel: panel, model: model, surface: surface, host: host, owner: owner, place: place, screen: screen,
                         opened: opened ?? NSApp.currentEvent?.timestamp ?? 0, choose: choose, closed: closed)
        model.choose = { index in FleetMenu.choose(index) }
        shown = open
        hosting.layoutSubtreeIfNeeded()
        panel.setFrame(frame(for: hosting.fittingSize, open), display: true)
        panel.orderFrontRegardless()
        // The shadow follows the panel's round shape once the list is drawn, which is after this turn.
        DispatchQueue.main.async { [weak panel] in panel?.invalidateShadow() }
        if panel.keyable { panel.makeKey() }
        watch(open)
    }

    /// Closes the menu that is open.
    static func close() {
        guard let open = shown else { return }
        shown = nil
        for watch in open.watches { NSEvent.removeMonitor(watch) }
        for observer in open.observers { NotificationCenter.default.removeObserver(observer) }
        open.panel.orderOut(nil)
        if open.panel.keyable, let host = open.host, host.isVisible { host.makeKey() }
        open.closed()
        // A click or a VoiceOver press on a row closes the menu from inside the panel's own event: its window and views
        // stay until that event is done.
        DispatchQueue.main.async { withExtendedLifetime(open) {} }
    }

    /// Closes the menu if `owner` opened it: its control left the window.
    static func close(owner: AnyObject) {
        if shown?.owner === owner { close() }
    }

    private static func choose(_ index: Int) {
        guard let open = shown, open.model.items.indices.contains(index), open.model.items[index].enabled else { return }
        close()
        open.choose(index)
    }

    /// The panel's frame for the size its list asks: at the pointer or under the control, on the screen.
    private static func frame(for size: CGSize, _ open: Shown) -> NSRect {
        switch open.place {
        case .pointer(let at): return MenuPlacement.atPointer(size, pointer: at, screen: open.screen)
        case .under(let control):
            return MenuPlacement.under(size, control: control, window: open.host?.frame ?? open.screen, screen: open.screen,
                                       gap: FleetMenuMetrics.gap)
        }
    }

    /// A filter changed the list's height: the panel keeps the edge that stands at its pointer or its control.
    private static func resize(to size: CGSize) {
        guard let open = shown, size.width > 0, size.height > 0 else { return }
        let old = open.panel.frame
        guard abs(old.width - size.width) > 0.5 || abs(old.height - size.height) > 0.5 else { return }
        let placed = frame(for: size, open)
        // The side it opened on stays: the top edge for a menu under its pointer or control, the bottom one over it.
        let opensDown = abs(old.maxY - placed.maxY) < abs(old.minY - placed.minY) || old.height == 0
        var next = placed
        if old.height > 0 { next.origin.y = opensDown ? old.maxY - size.height : old.minY }
        open.panel.setFrame(next, display: true)
        open.panel.invalidateShadow()
    }

    private static func watch(_ open: Shown) {
        // A click anywhere else closes it, and goes no further, as with a macOS menu.
        local([.leftMouseDown, .rightMouseDown, .otherMouseDown], open) { event in
            guard let open = shown, event.timestamp > open.opened, event.window !== open.panel else { return false }
            close()
            return true
        }
        // The button held from the click that opened it (the right button, or the left one of a Control-click): its
        // release over an item chooses that item, as with a macOS menu. A release where it was pressed leaves the menu
        // open. A later click elsewhere closed the menu at its press, so a release here is always that first click's.
        local([.rightMouseDragged, .rightMouseUp, .leftMouseDragged, .leftMouseUp], open) { event in
            guard let open = shown, event.window !== open.panel else { return false }
            let point = open.panel.convertPoint(fromScreen: NSEvent.mouseLocation)
            if event.type == .rightMouseDragged || event.type == .leftMouseDragged {
                let inside = open.surface.bounds.contains(open.surface.convert(point, from: nil))
                open.model.point(inside ? open.surface.point(atWindowPoint: point) : nil)
            } else if hypot(NSEvent.mouseLocation.x - open.start.x, NSEvent.mouseLocation.y - open.start.y) > 4 {
                open.surface.release(at: point)
            }
            return true
        }
        // The scroll wheel elsewhere closes it, and scrolls nothing under it. A trackpad also sends wheel events that
        // move nothing — two fingers that touch it (`mayBegin`) or lift (`cancelled`, `ended`), as for its two-finger
        // right-click — and those leave the menu open. The momentum of a swipe before it opened scrolls nothing either.
        local([.scrollWheel], open) { event in
            guard let open = shown, event.window !== open.panel else { return false }
            let moves = !event.phase.isDisjoint(with: [.began, .changed]) || (event.phase.isEmpty && event.momentumPhase.isEmpty)
            if moves { close(); return true }
            return !event.momentumPhase.isEmpty
        }
        local([.keyDown], open) { event in key(event) }
        // A click in another app.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { _ in
            MainActor.assumeIsolated { close() }
        }) { open.watches.append(global) }
        let center = NotificationCenter.default
        open.observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { close() }
        })
        guard let host = open.host else { return }
        var names = [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.willCloseNotification,
                     NSWindow.didMiniaturizeNotification]
        // Another window of the app takes the keyboard; but VoiceOver's menu takes it itself (`FleetMenuPanel`).
        if !open.panel.keyable { names.append(NSWindow.didResignKeyNotification) }
        for name in names {
            open.observers.append(center.addObserver(forName: name, object: host, queue: .main) { _ in
                MainActor.assumeIsolated { close() }
            })
        }
    }

    /// A watch of the app's own events while the menu is open: `take` says whether the menu took the event, which then
    /// goes no further.
    private static func local(_ kinds: NSEvent.EventTypeMask, _ open: Shown, take: @escaping @MainActor (NSEvent) -> Bool) {
        guard let watch = NSEvent.addLocalMonitorForEvents(matching: kinds, handler: { event in
            MainActor.assumeIsolated { take(event) } ? nil : event
        }) else { return }
        open.watches.append(watch)
    }

    /// The menu's keys. A key with ⌘ closes it and goes on to the window, as with a macOS menu; every other key stays
    /// in the menu, so nothing is typed into the page under it.
    private static func key(_ event: NSEvent) -> Bool {
        guard let open = shown else { return false }
        let model = open.model
        if event.modifierFlags.contains(.command) { close(); return false }
        if event.keyCode == 53 {
            if model.query.isEmpty { close() } else { model.query = "" }
            return true
        }
        switch event.specialKey {
        case .downArrow?: model.step(1)
        case .upArrow?: model.step(-1)
        case .carriageReturn?, .enter?, .newline?:
            if let highlighted = model.highlighted { choose(highlighted) }
        case .delete?, .backspace?:
            if model.filters, !model.query.isEmpty { model.query.removeLast() }
        case .some: break
        case nil:
            guard let letters = event.characters, !letters.isEmpty, event.modifierFlags.isDisjoint(with: [.control]),
                  letters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 })
            else { break }
            if model.filters {
                model.query += letters
            } else if letters == " " {
                if let highlighted = model.highlighted { choose(highlighted) }
            } else {
                model.jump(letters)
            }
        }
        return true
    }
}

/// **Every right-click menu of SwiftUI opens in the app's menu** (`FleetMenu`). A view keeps its `.contextMenu`, so
/// SwiftUI still decides which view's menu a point has and what its items do, and VoiceOver's Show Menu keeps the
/// system's menu. This watch takes the right-click (and the Control-click) before AppKit shows that menu: it asks the
/// view under the pointer for its menu, as AppKit does, and draws its items itself. A menu of another view — a text's
/// Copy and Look Up, a field's Cut and Paste — and a menu with an item the app's menu cannot draw (a submenu, a view of
/// its own) stay the system's.
@MainActor enum FleetContextMenus {
    private static var watch: Any?

    /// **The words of the items that delete**, in red: SwiftUI's `role: .destructive` does not reach the menu item it
    /// makes (macOS 27: `isDestructive` stays false), so the menu knows them by their titles.
    static let destructive: Set<String> = [AgentMenu.deleteTitle]

    static func start() {
        guard watch == nil else { return }
        watch = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            MainActor.assumeIsolated { open(event) } ? nil : event
        }
    }

    private static func open(_ event: NSEvent) -> Bool {
        guard event.type == .rightMouseDown || event.modifierFlags.contains(.control), !FleetMenu.isOpen,
              let window = event.window, let frameView = window.contentView?.superview else { return false }
        var view = frameView.hitTest(event.locationInWindow)
        while let candidate = view {
            if let menu = candidate.menu(for: event) {
                guard swiftUIMenu(menu, from: candidate) else { return false }
                return show(menu, for: event, in: window)
            }
            view = candidate.superview
        }
        return false
    }

    /// Whether a menu is a `.contextMenu` of SwiftUI: the menu of a SwiftUI hosting view (`NSHostingView`, and the
    /// window's own `WindowLayoutHostingView`), whose delegate is SwiftUI's context-menu responder. A text's menu comes
    /// from its own view (`AppKitTextInteractionView`) and stays the system's.
    private static func swiftUIMenu(_ menu: NSMenu, from view: NSView) -> Bool {
        NSStringFromClass(type(of: view)).contains("HostingView")
            || menu.delegate.map { NSStringFromClass(type(of: $0)).contains("ContextMenuResponder") } == true
    }

    private static func show(_ menu: NSMenu, for event: NSEvent, in window: NSWindow) -> Bool {
        menu.delegate?.menuNeedsUpdate?(menu)
        var items: [FleetMenuItem] = []
        // Each item's menu item, and its place in the menu.
        var sources: [(item: NSMenuItem, place: Int)] = []
        var group = 0
        var section: String?
        for (place, item) in menu.items.enumerated() where !item.isHidden {
            if item.isSeparatorItem {
                if !items.isEmpty { group += 1; section = String(repeating: " ", count: group) }
                continue
            }
            if item.isSectionHeader { group += 1; section = item.title; continue }
            guard !item.hasSubmenu, item.view == nil else { return false }
            let image = item.image.map {
                $0.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: FleetMenuMetrics.symbol,
                                                                       weight: FleetMenuMetrics.symbolImageWeight)) ?? $0
            }
            items.append(FleetMenuItem(title: item.title, mark: image.map { .image($0) } ?? .none, checked: item.state == .on,
                                       enabled: item.isEnabled, destructive: destructive.contains(item.title), section: section))
            sources.append((item, place))
        }
        guard !items.isEmpty else { return false }
        let chosen = UserDefaults.standard.object(forKey: ViewZoom.key) as? Double ?? 1
        let zoom = ViewZoom.shown(chosen, in: window.contentView?.bounds.size ?? .zero)
        menu.delegate?.menuWillOpen?(menu)
        FleetMenu.show(items, at: .pointer(window.convertPoint(toScreen: event.locationInWindow)), over: window, zoom: zoom,
                       opened: event.timestamp, choose: { index in
                           // The item he chose, where the menu has it now. SwiftUI makes the menu's items again as it
                           // closes (in the app's window: the same words, new items), and can change them while it is
                           // open, so the item is found by itself, else by its words at its own place, else by its
                           // words; one that is gone or cannot act any more does nothing.
                           let (chosen, was) = sources[index]
                           let now = menu.items
                           let place = now.firstIndex { $0 === chosen }
                               ?? (now.indices.contains(was) && now[was].title == chosen.title ? was : nil)
                               ?? now.firstIndex { !$0.isSeparatorItem && !$0.isSectionHeader && $0.title == chosen.title }
                           if let place, now[place].isEnabled { menu.performActionForItem(at: place) }
                       }, closed: { menu.delegate?.menuDidClose?(menu) })
        return true
    }
}

/// The view of a control that opens a list (`FleetSelect`), for the place of its list: no size of its own, no click.
struct FleetMenuAnchor: NSViewRepresentable {
    /// The control's view, kept by its `FleetSelect`, and what a choice in its list does as the page stands now: the
    /// list keeps the rows it opened with, and a choice made after a reading changed the page goes to the page's newest
    /// action (a save that sends the other values of the page sends their newest).
    final class Spot {
        weak var view: NSView?
        var select: ((AnyHashable) -> Void)?
    }
    let spot: Spot
    var select: ((AnyHashable) -> Void)?

    func makeNSView(context: Context) -> NSView {
        let view = Holder()
        spot.view = view
        spot.select = select
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        spot.view = view
        spot.select = select
    }

    static func dismantleNSView(_ view: NSView, coordinator: ()) { FleetMenu.close(owner: view) }

    private final class Holder: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// A control that left its window for good closes its list. SwiftUI takes a view out of the window and puts it
        /// back when views before it change (`FleetModalAnchor`), so it closes when the view is still out after that turn.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window == nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window == nil else { return }
                FleetMenu.close(owner: self)
            }
        }
    }
}
