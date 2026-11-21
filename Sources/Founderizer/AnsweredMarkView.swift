import AppKit
import FleetCore
import SwiftUI

/// **The mark of an answered request, in the place of its check** (owner feature `need_marks`; the owner's "Yes, as
/// drawn" and "Orange mark" of 21 November 2026): the check, the turning green mark of work, the red mark of work that
/// failed, or the orange mark of a task that needs him (`OwnerNeed.answeredMark`). The folded card in a chat and the
/// answered step of Needs you draw it alike (his "Yes, same marks there", 21 November 2026), so a request never shows
/// red in the chat and a check on Needs you.
///
/// **The hover of a task's work is a tag that only draws** (his "Yes, badge as drawn", 21 November 2026): the agent's
/// badge with its icon, then " · <task title>" (`CardNames`, as the card's own words). The tag stands in a window of its
/// own over the app's window (`HoverTag`), so neither the card nor the chat's scroll edge cuts it, and it takes no
/// click, no key and no focus: the folded card stays one button. The other marks keep their words as the system's
/// tooltip (`.help`), as before: his yes was to the tag of a task's work. VoiceOver reads the same words from the
/// card's value (`foldedMarkWords`, and the step's own value). `mark` nil: his answer is on its way, and the check
/// stands as before, with no words.
struct AnsweredMarkView: View {
    let mark: AnsweredMark?
    /// The work mark turns (`FleetStore.marksMove`).
    let moves: Bool
    /// The check's size and weight where it stands: 10 semibold on a card in a chat, 12 on the step of Needs you.
    var size: CGFloat = 10
    var weight: Font.Weight = .semibold
    /// The names that the tag draws as badges: the card's own (`FleetStore.cardNames(for:)`).
    var names: CardNames?
    @State private var hovering = false
    @State private var shown = false
    @Environment(\.glyphTeam) private var team
    @Environment(\.glyphPresence) private var presences
    @Environment(\.cardServerSymbols) private var symbols

    var body: some View {
        if let mark, case .working(_, let agent?, _) = mark, !agent.isEmpty {
            look(mark)
                .background(HoverTagAnchor(shown: shown && !mark.words.isEmpty) { AnyView(tag(mark)) })
                .onHover { inside in
                    hovering = inside
                    if inside {
                        // the pointer rests a moment first, as on any mark of the app, so a tag does not flash past
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(350))
                            if hovering { shown = true }
                        }
                    } else {
                        shown = false
                    }
                }
                .onDisappear { hovering = false; shown = false }
        } else if let mark {
            look(mark).help(mark.words)
        } else {
            check
        }
    }

    private var check: some View { Image(systemName: "checkmark").font(IconMetrics.symbol(size, weight: weight)) }

    @ViewBuilder private func look(_ mark: AnsweredMark) -> some View {
        switch mark {
        case .done: check
        case .working: WorkMark(size: size, moves: moves)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").font(IconMetrics.symbol(size))
                .foregroundStyle(FleetTask.MarkTint.failed.color)
        case .attention(let symbol, _):
            Image(systemName: symbol).font(IconMetrics.symbol(size)).foregroundStyle(FleetTask.MarkTint.attention.color)
        }
    }

    /// The tag's words: the mark's words, each name in them as its badge, in the look of the app's small cards.
    func tag(_ mark: AnsweredMark) -> some View {
        let words = AttributedString(mark.words)
        return CardBadgeText.text(words, names: names, size: FormMetrics.detailSize)
            .font(FormMetrics.detail).foregroundStyle(FleetStyle.text)
            .cardBadges(names != nil, links: false)
            // **A width of its own**: its words on one line, or `HoverTag.widest`, where they wrap. With no width the
            // words measured as one line, and the tag's window cut a reason of two lines.
            .frame(width: Self.width(of: words, names: names), alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, HoverTag.inset.width).padding(.vertical, HoverTag.inset.height)
            .background(RoundedRectangle(cornerRadius: FormMetrics.inner, style: .continuous).fill(FleetStyle.lifted))
            .overlay(RoundedRectangle(cornerRadius: FormMetrics.inner, style: .continuous)
                .strokeBorder(FleetStyle.hairline(0.12), lineWidth: 1))
            .environment(\.glyphTeam, team).environment(\.glyphPresence, presences)
            .environment(\.cardServerSymbols, symbols)
            .environment(\.colorScheme, .dark)
            .accessibilityHidden(true)
    }
}

extension AnsweredMarkView {
    /// The width of a tag's words on one line, as they draw with their badges (`CardBadgeText`), at most
    /// `HoverTag.widest`. Measured, not reckoned: a reckoned width was a few points short, and the words wrapped. A tag
    /// is made only when it shows (`HoverTagAnchor`), so this runs on hover alone.
    @MainActor static func width(of words: AttributedString, names: CardNames?) -> CGFloat {
        let line = NSHostingView(rootView: CardBadgeText.text(words, names: names, size: FormMetrics.detailSize)
            .font(FormMetrics.detail).fixedSize())
        return min(ceil(line.fittingSize.width) + 1, HoverTag.widest)
    }
}

/// **A tag that only draws, over the app's window, beside the view under the pointer**: one borderless panel at a time,
/// a child of that window, that takes no mouse event, never becomes the key or the main window and activates nothing.
/// It goes when its view says so, when its view leaves the window, and at a click, a key or a scroll anywhere in the app,
/// so it never stands over something that moved. That watch asks no hold (`AppFront`): it only takes the tag away and
/// passes the event on, so a click that the hold drops changes nothing else.
@MainActor enum HoverTag {
    /// The widest that a tag's words run before they wrap.
    nonisolated static let widest: CGFloat = 360
    /// The room around a tag's words, and between the tag and its view.
    nonisolated static let inset = CGSize(width: 9, height: 6)
    nonisolated static let gap: CGFloat = 6

    private static var panel: TagPanel?
    private static weak var owner: NSView?
    private static var watch: Any?
    /// The view whose tag a click, a key or a scroll took away: it shows no tag again until its own view lets it go
    /// (`hide(of:)`, the pointer leaving), so a redraw of the card does not bring it back under his typing.
    private static weak var silenced: NSView?

    /// The tag under `view`, its left edge with the view's words, or above it where the screen ends: under the mark it
    /// hides no title or question of the card (the area Needs-you and the manager, 21 November 2026).
    static func show(_ tag: AnyView, over view: NSView) {
        guard let window = view.window, silenced !== view else { return }
        if owner === view, panel != nil { return }        // its tag stands already
        hide()
        let host = NSHostingView(rootView: tag)
        let size = host.fittingSize          // the tag's words have a width of their own (`AnsweredMarkView.tag`)
        let anchor = window.convertToScreen(view.convert(view.bounds, to: nil))
        var origin = NSPoint(x: anchor.minX - inset.width, y: anchor.minY - gap - size.height)
        if let screen = window.screen?.visibleFrame {
            if origin.y < screen.minY { origin.y = anchor.maxY + gap }
            origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
        }
        let panel = TagPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true          // the app goes to the background, and its tag with it
        panel.contentView = host
        window.addChildWindow(panel, ordered: .above)
        self.panel = panel
        owner = view
        watch = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .rightMouseDown, .keyDown]) { event in
            MainActor.assumeIsolated {
                silenced = owner
                hide()
            }
            return event
        }
    }

    /// The tag goes: any tag, or only the one of `view`.
    static func hide(of view: NSView? = nil) {
        if let view, silenced === view { silenced = nil }
        if let view, owner !== view { return }
        if let watch { NSEvent.removeMonitor(watch) }
        watch = nil
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        owner = nil
    }
}

/// The tag's window: it never takes the keyboard or the main window's place.
private final class TagPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The place of a mark in its window, which shows and hides its tag (`HoverTag`).
private struct HoverTagAnchor: NSViewRepresentable {
    let shown: Bool
    /// The tag, made only when it shows.
    let tag: () -> AnyView

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        if shown { HoverTag.show(tag(), over: view) } else { HoverTag.hide(of: view) }
    }

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        MainActor.assumeIsolated { HoverTag.hide(of: view) }
    }
}
