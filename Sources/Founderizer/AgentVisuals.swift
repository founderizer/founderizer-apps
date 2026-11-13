import AppKit
import FleetCore
import FleetMark
import SwiftUI

// The marks that stand for words in the agent views: the provider's icon, a status dot, a thin allowance meter, and
// the turning mark of a task in work.
// The words that a mark replaces show on hover and stay in the accessibility label. An agent's own mark is its glyph
// (AgentGlyph.swift). See UI-PATTERNS.md.

/// The mark of a provider, for a provider or its account and never as an agent's face: its real logo
/// (`ProviderLogo`). A provider with no logo here: a neutral symbol in a tile.
struct ProviderIcon: View {
    let runtime: String
    var size: CGFloat = 22

    var body: some View {
        Group {
            if let image = ProviderLogo.image(runtime) {
                image.resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "cpu").font(IconMetrics.symbol(size * 0.46, weight: .medium))
                    .foregroundStyle(FleetStyle.muted).frame(width: size * 0.84, height: size * 0.84)
                    .background(FleetStyle.bubble, in: RoundedRectangle(cornerRadius: size * 0.2))
            }
        }.frame(width: size, height: size)
            .help(providerName(runtime)).accessibilityLabel(providerName(runtime))
    }
}

/// What an agent does now, as one dot. A ring, not a filled dot, marks an agent that takes no work now, so color
/// is not the only cue. **A dot is a problem, and neither online nor work has one** (the owner, 13 November 2026:
/// "remove all green status dots. if agent is available, just dont show it (that should be the default). only show
/// red/other colors if there is some kind of problem"): an agent at work shows it by its glyph's motion and by the
/// moving line of its sidebar row (`StatusDot.shows`). Until that day work was one green dot (his yes of 28 October
/// 2026, D-8). Violet is what he can press and the brand's mark, and a state is never violet.
enum AgentPresence: Equatable {
    /// `workingAtLastRead`: at work by a reading that is old now — its colour as last read, and its glyph at rest,
    /// because motion would claim work that goes on now (the lead's call of 29 October 2026, fix round 2).
    case unknown, setup, offline, attention(String), limited, working, workingAtLastRead, online

    var label: String {
        switch self {
        // UI-PATTERNS' own word for an old reading; when it was read is on hover where the state shows.
        case .unknown: String(l10n: "Last reading")
        case .setup: String(l10n: "In setup")
        case .offline: String(l10n: "Not answering")
        case .attention(let problem): problem
        case .limited: String(l10n: "Usage limit")
        case .working, .workingAtLastRead: String(l10n: "Working")
        case .online: String(l10n: "Online")
        }
    }
    var color: Color {
        switch self {
        case .working, .workingAtLastRead, .online: .green
        case .offline, .attention, .limited: .orange
        case .unknown, .setup: FleetStyle.muted
        }
    }
    var isRing: Bool { self == .unknown || self == .setup || self == .offline }
}

extension FleetAgent {
    /// The agent's status: in setup, offline, a machine problem, limited, working, a task that needs the owner, online.
    /// Working means that the hub reports a task in work now, or that the agent works on the owner's newest chat
    /// message (`thinking`: its chat says "Thinking", `FleetAgent.thinks`): a paused, queued or waiting task is not
    /// work. Online says only that the helper answers; the hub reports no other activity, so it is not "idle".
    ///
    /// **An old reading keeps the agents' look** (fix round 2 of 29 October 2026; T-14, one cause and one sign): the status
    /// is the one the last reading says, whether or not that reading is current (`isFresh`), so a glyph turns grey only
    /// for a reading that says its agent is offline. While the hub's answer was late, every glyph went grey at the
    /// reading's first second, in two steps 250 ms apart, and came back in colour with the answer; the notice over the
    /// page is the one sign of an old reading, and the words that name a state say "Last reading" where they need to.
    /// **Only its motion rests**: an agent at work by an old reading is `workingAtLastRead`, its colour as last read
    /// and its glyph still, because a moving glyph says that the work goes on now.
    func presence(isFresh: Bool, serverTime: Double, openTasks: [FleetTask], holds: [TaskHold], problem: AgentAttention? = nil,
                  thinking: Bool = false) -> AgentPresence {
        if active == false { return .setup }
        if !helperIsRecent(serverTime: serverTime) { return .offline }
        if let problem { return .attention(problem.short) }
        if limit != nil { return .limited }
        let marks = openTasks.filter { $0.owner == name }.map { $0.mark(holds: holds) }
        if thinking || marks.contains(where: \.inWork) { return isFresh ? .working : .workingAtLastRead }
        if let waiting = marks.first(where: \.attention) { return .attention(waiting.words) }
        return .online
    }
}

/// A status as a dot alone; its words show on hover. `ring` is the color under the dot, as a gap of 1.5 points that
/// parts it from the glyph under it.
struct StatusDot: View {
    /// **One diameter for every status dot of the app** (the owner, 27 October 2026: "why are they different?!?! they
    /// should all be like the smaller ones").
    static let side: CGFloat = 6
    let presence: AgentPresence
    var size: CGFloat = StatusDot.side
    var ring: Color?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// **Whether a status has a dot: only what is not as usual** (the owner, 13 November 2026: "remove all green status
    /// dots. if agent is available, just dont show it ... only show red/other colors if there is some kind of
    /// problem"). Online is how an agent is, and work shows as motion: its glyph moves and the line of its sidebar row
    /// moves. With Reduce Motion nothing moves, so there work keeps its green dot, the one sign of it that is left.
    static func shows(_ presence: AgentPresence, reduceMotion: Bool) -> Bool {
        switch presence {
        case .online: false
        case .working, .workingAtLastRead: reduceMotion
        case .unknown, .setup, .offline, .attention, .limited: true
        }
    }

    var body: some View {
        if Self.shows(presence, reduceMotion: reduceMotion) {
            // **The dot keeps its own 6 points inside the ring** (T-04): without a frame of its own the circle took the
            // stack's 9 points and covered the ring, so every dot on a glyph measured 9 beside the sidebar's 6.
            ZStack {
                if let ring { Circle().fill(ring).frame(width: size + 3, height: size + 3) }
                Group {
                    if presence.isRing { Circle().strokeBorder(presence.color, lineWidth: 1.5) } else { Circle().fill(presence.color) }
                }.frame(width: size, height: size)
            }.frame(width: size, height: size)
                .help(presence.label).accessibilityLabel(presence.label)
        }
    }
}

/// One allowance window as a thin meter, in **the one colour scale of a usage reading** (`UsageBar.Level`): a soft
/// white below 80%, orange from 80% and red at the limit, 100%, of the whole percent its words show; gray for an old
/// reading; no fill for 0%. **Green is not a share** (the lead's call on T-08, 28 October 2026): it is an agent at work
/// (D-8), and a bar under 70% was the same green as the dot of a working agent beside it. One 4-point capsule on a quiet track on every screen (T-08): one account at 71% was orange on the Agents
/// table and violet on the Dashboard, in its chat's panel and in its Settings, and the bar 6 points high on one page
/// and 4 on the others. Its numbers are in the label beside it or in its help.
struct AllowanceMeter: View {
    /// The used share in percent. A provider can report more than 100.
    let used: Double
    var stale = false
    /// Its length; nil takes the width it is given, as in the panel of an agent's chat, whose width the owner sets.
    var width: CGFloat? = 44

    /// The fill of a share that is neither near nor at its limit: a soft white, lighter than an old reading's gray
    /// (6.6:1 on the track, the old gray 4.1:1).
    static let calm = Color.white.opacity(0.7)

    /// The fill of one share: the colour of its level, or gray for an old reading.
    static func color(percent: Int, stale: Bool) -> Color {
        if stale { return FleetStyle.muted }
        return switch UsageBar.Level(percent: percent) { case .low: calm; case .high: .orange; case .full: .red }
    }

    var body: some View {
        let color = Self.color(percent: Int(used.rounded()), stale: stale)
        let share = min(100, max(0, used)) / 100
        Capsule().fill(Color.white.opacity(0.10)).frame(width: width, height: 4)
            .overlay(alignment: .leading) {
                // No fill for no use; a small use stays visible.
                if share > 0 {
                    GeometryReader { track in
                        Capsule().fill(color).frame(width: max(2, track.size.width * share), height: 4)
                    }
                }
            }
            .accessibilityLabel("\(used.formatted(.number.precision(.fractionLength(0...1)))) percent used")
    }
}

/// **When an allowance window resets, under its bar** (the owner, 10 November 2026: "for usage, when showing % could
/// we show somewhere too WHEN it resets?", and his yes the same day to the mockup, "↻ 15:00" under every bar): the
/// `arrow.clockwise` mark and the coming time by the app's one rule for it (`fleetComingTime`): the time today, the
/// weekday and the time in the coming week, else the day and the month. Muted, in the detail size, under the bar of the
/// Agents table, of an agent's panel and of its Runs on. Nothing where the provider gave no reset or the reset has
/// passed: a time that is gone says nothing. The date in full stays in the window's help.
struct ResetLine: View {
    let window: UsageWindow
    /// The hub's time of the state.
    let now: Double
    /// Keep the line's height where there is no time, so that the bars of a table's row stand on one line.
    var holdsLine = false

    /// The coming time of the reset, or nil where there is none to say.
    static func time(_ window: UsageWindow, now: Double) -> String? {
        guard let resets = window.resets_at, resets > now else { return nil }
        return fleetComingTime(minute(resets), now: now)
    }

    /// A reset to the nearest minute: two readings of one account give 14:59:59.9 and 15:00:00.2 for one reset, and a
    /// time that cuts its seconds said 14:59 on one page and 15:00 on the next.
    static func minute(_ resets: Double) -> Double { (resets / 60).rounded() * 60 }

    var body: some View {
        if let time = Self.time(window, now: now) {
            HStack(spacing: Self.gap) {
                Image(systemName: Self.symbol).font(Self.markFont)
                Text(time).monospacedDigit()
            }
            .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).lineLimit(1)
            .accessibilityElement(children: .ignore).accessibilityLabel("Resets \(time)")
        } else if holdsLine {
            Text(" ").font(FormMetrics.detail).accessibilityHidden(true)
        }
    }

    static let symbol = "arrow.clockwise"
    private static let gap: CGFloat = 3
    private static let markFont = Font.system(size: 10, weight: .medium)

    /// The widest line this Mac writes for a reset: the mark and the longest coming time in its own language and
    /// clock, so that a table's column holds every one of them uncut.
    static let widest: CGFloat = {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let late = { (date: Date) in calendar.date(bySettingHour: 22, minute: 58, second: 0, of: date) ?? date }
        let first = calendar.date(from: calendar.dateComponents([.year, .month], from: start)) ?? start
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        let months = (0..<12).compactMap { calendar.date(byAdding: DateComponents(month: $0, day: 27), to: first) }
        let texts = days.map { late($0).formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
            + months.map { $0.formatted(.dateTime.day().month(.abbreviated)) }
            + [late(start).formatted(date: .omitted, time: .shortened)]
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let text = texts.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let mark = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))?.size.width ?? 10
        return (mark + gap + text).rounded(.up)
    }()
}

/// The mark of a task in work: `circle.dotted` that turns, in the green of work (D-8: a state is never violet). Core
/// Animation turns it, so the window does not draw again at each frame, as it did with a SwiftUI symbol effect that
/// repeats (Agents page with one mark: 22% of a core). A still copy of the symbol keeps its place in the layout and its
/// text baseline. It does not move with Reduce Motion.
struct WorkMark: View {
    var size: CGFloat = 12
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let work = AgentPresence.working.color
        let still = Image(systemName: "circle.dotted").font(IconMetrics.symbol(size)).foregroundStyle(work)
        if reduceMotion { still }
        else { still.hidden().overlay { TurningSymbol(name: "circle.dotted", size: size, color: NSColor(work)) } }
    }
}

private struct TurningSymbol: NSViewRepresentable {
    let name: String
    let size: CGFloat
    let color: NSColor

    func makeNSView(context: Context) -> TurningSymbolView { TurningSymbolView() }
    func updateNSView(_ view: TurningSymbolView, context: Context) { view.show(name, size: size, color: color) }
}

/// One symbol as a layer that turns about its center, with no end.
private final class TurningSymbolView: NSView {
    private let symbol = CALayer()
    private var look: (name: String, size: CGFloat, color: NSColor)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(symbol)
        symbol.contentsGravity = .center
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }

    /// A click goes to the row or the button under the mark.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ name: String, size: CGFloat, color: NSColor) {
        if let look, look.name == name, look.size == size, look.color == color { return }
        look = (name, size, color)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let look, bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2
        let configuration = NSImage.SymbolConfiguration(pointSize: look.size, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [look.color]))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        symbol.frame = bounds
        symbol.contentsScale = scale
        symbol.contents = NSImage(systemSymbolName: look.name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)?.layerContents(forContentsScale: scale)
        CATransaction.commit()
        turn()
    }

    /// A layer that left the window lost its motion.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { needsLayout = true }
    }

    private func turn() {
        guard symbol.animation(forKey: "turn") == nil else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0; turn.toValue = -2 * Double.pi; turn.duration = 3
        turn.repeatCount = .infinity; turn.isRemovedOnCompletion = false
        symbol.add(turn, forKey: "turn")
    }
}

/// A coming time in few characters: the time today, the weekday and time in the next week, else the day and month.
func fleetComingTime(_ timestamp: Double, now: Double) -> String {
    let date = Date(timeIntervalSince1970: timestamp), calendar = Calendar.current
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date(timeIntervalSince1970: now)), to: calendar.startOfDay(for: date)).day ?? 0
    if days == 0 { return date.formatted(date: .omitted, time: .shortened) }
    if days > 0 && days < 7 { return date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
    return date.formatted(.dateTime.day().month(.abbreviated))
}
