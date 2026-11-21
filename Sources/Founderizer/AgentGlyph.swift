import AppKit
import FleetMark
import SwiftUI

// An agent's own mark: a shape and a color that come from its name and from its place in the hub's list of agents,
// so an agent looks the same on every page, on every Mac and in every run. The provider's icon is for the provider
// and its account, not for the agent. The glyph moves while its agent works, plainly enough to be the one sign of
// work (an agent at work has no dot), and once when the pointer comes to it. Core Animation moves it: the app does no work for a frame. See UI-PATTERNS.md.
//
// The mark itself — `GlyphKind`, `GlyphLook` and the two shapes — is `FleetMark`, which this app and the owner's
// iPhone app both link, so one agent wears one face on his two screens, and so is the motion of each kind
// (`GlyphMotion`). Everything below is this app's own: the view and the layers that play the motion.

/// **The sizes of an agent's glyph**, and every glyph of the app stands at one of them. The owner, 27 October 2026, of
/// two dot sizes side by side: "why are they different?!?! they should all be like the smaller ones" — and the
/// glyphs came in ten sizes, 14 to 48 points, most of them under 6 points apart, so two lists side by side drew one
/// agent at two sizes that read as a mistake. Four steps, each a clear step from the next, and a fifth on the two
/// pages where the glyph makes itself (`making`).
enum GlyphSize {
    /// Beside a name in a line of words: a select, a server's agents, a Tasks card, Knowledge, a conversation, agent
    /// messages, Secrets, a request's "From".
    static let inline: CGFloat = 16
    /// The leading mark of a form row (`RowMark`, as wide as its column): Conversations, a person's page, Access; the
    /// chat's pill (the lead's call on T-04); and the head of an agent's page, whose name begins where its rows' words do.
    static let row: CGFloat = 22
    /// A list of agents: the main sidebar, and the first card of an agent's status panel and of a task's panel.
    static let list: CGFloat = 28
    /// The mark over a setup step, the agents to choose from in Add person, and the agent on the card that deletes it.
    static let hero: CGFloat = 48
    /// **The glyph that makes itself on "Adding <agent>" and "Setting up <agent>"** (`AgentGlyph.making`; the owner,
    /// 20 November 2026, of those pages: "while you're at it, maybe in these sscreens we can make the icon larger to be
    /// more important"): twice a setup step's mark, and its whole motion with it. It is the size of those pages also
    /// while it stands still: under Reduce Motion, or on the chat's "Setting up" of an agent that this Mac does not
    /// add.
    static let making: CGFloat = 96
}

struct AgentGlyph: View {
    let name: String
    /// nil: the agent's presence as the window knows it (`glyphPresence`), so one agent wears one look in every place
    /// of a screen — grey while it is offline, in its own colours from the moment it is added; an agent the window does
    /// not know is the mark alone, at rest and in colour, with no dot.
    var presence: AgentPresence?
    var size: CGFloat = GlyphSize.list
    /// **Whether this glyph shows the agent's work by moving**: only where the agent itself is what the eye is on —
    /// its row of the main sidebar, the pill over its chat, its status panel, the chat's "Thinking", the head of a
    /// task's panel, a task's live line and a card of Working. A table draws an agent at work at rest, so a screen
    /// does not move in many places for one agent.
    var moves = false
    /// **Its status dot stands on its lower right corner, by default** (D-8 item 2, "as everywhere else"; fix round 2 of
    /// 29 October 2026): wherever the glyph stands for the agent, it wears the dot of the presence it shows, as its
    /// sidebar row does. The search card's rows, the Tasks cards and the task panel drew the glyph alone beside a
    /// sidebar that drew the same agent with its dot. False where the caller draws no status.
    var dot = true
    /// What the dot's ring stands on, so the ring parts the dot from the glyph: nil for a card's surface on a card and the
    /// canvas elsewhere.
    var ground: Color?
    /// It makes its one jump when this turns true: the agent took his answer to its request (`NeedsBoard.took`).
    var jumps = false
    /// **The moving words of "Adding <agent>" or "Setting up <agent>" under it, while the glyph makes itself**
    /// (`MakingGlyph`; the owner's "Yes, build it" of 20 November 2026): the sequence of its making from the agent's
    /// one clock, and the light of those words over it. Nil everywhere else. It stands still under Reduce Motion.
    var making: String?
    /// False: it makes itself only for an agent that this Mac adds (`glyphAdding`), or to go on with a making of its
    /// agent that shows as it comes (the chat's own "Setting up", which also shows while the session of an agent that
    /// ran for weeks starts again: the owner's words were "when creating an agent or setitng it up for the first
    /// time"). Else it stands still.
    var begins = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.glyphTeam) private var team
    @Environment(\.glyphPresence) private var presences
    @Environment(\.onCard) private var onCard
    @Environment(\.glyphDots) private var dots
    @Environment(\.glyphAdding) private var adding
    @State private var pops = 0
    /// The moving layers stay until their motion is back at rest, so work never ends with a snap.
    @State private var layered = false

    private struct Pop { var scale = 1.0 }

    /// A glyph moves only for an agent at work by a current reading (`working`; at work by an old one it rests,
    /// `workingAtLastRead`), and never with Reduce Motion.
    static func moves(_ presence: AgentPresence?, reduceMotion: Bool) -> Bool { presence == .working && !reduceMotion }

    var body: some View {
        let look = GlyphTeams.look(of: name, in: team)
        let state = presence ?? presences[name]
        let moving = moves && Self.moves(state, reduceMotion: reduceMotion)
        Group {
            if let making, !reduceMotion, begins || adding.contains(name) || GlyphMakingClock.showing(name) {
                let absent = state == .offline || state == .unknown
                MakingGlyph(name: name, kind: look.kind, light: absent ? Self.absentLight : look.light,
                            deep: absent ? Self.absentDeep : look.deep, words: making, size: size)
            // Layers that the window server moves. A SwiftUI timeline made the window update its whole view tree for
            // each frame: about 30% of a processor core for two glyphs of 18 points.
            } else if moving || layered {
                MovingGlyph(look: look, moving: moving, eased: !reduceMotion) { layered = false }.allowsHitTesting(false)
            } else {
                figure(look, state)
            }
        }
        .frame(width: size, height: size)
        .keyframeAnimator(initialValue: Pop(), trigger: pops) { view, pop in view.scaleEffect(pop.scale) } keyframes: { _ in
            KeyframeTrack(\.scale) {
                SpringKeyframe(1.18, duration: 0.14)
                SpringKeyframe(1, duration: 0.45, spring: .bouncy)
            }
        }
        // The small jump is for the pointer only: work starts from the glyph at rest, without a jump of its own. A
        // glyph that makes itself has a jump of its own in its sequence.
        .onHover { inside in if inside && !reduceMotion && making == nil { pops += 1 } }
        .onChange(of: jumps) { _, now in if now && !reduceMotion { pops += 1 } }
        .onChange(of: moving, initial: true) { _, now in if now { layered = true } }
        // **The glyph at rest that begins to make itself starts its agent's making again** (his press on Add agent);
        // a glyph that comes making goes on from the agent's clock.
        .onChange(of: making != nil) { was, now in if !was && now { GlyphMakingClock.restart(name) } }
        .accessibilityHidden(true)
        // The one dot of the app, 6 points at every size of the glyph, its centre on the glyph's lower right corner; it
        // neither jumps nor moves with the glyph, and its words are its hover and its VoiceOver label (`StatusDot`).
        .overlay(alignment: .bottomTrailing) {
            if dot, dots, let state {
                StatusDot(presence: state, ring: ground ?? (onCard ? FleetStyle.surface : FleetStyle.canvas))
                    .offset(x: StatusDot.side / 2, y: StatusDot.side / 2)
            }
        }
        // **A glyph that makes itself keeps the mock-up's room under it**: the step's gap grows with the glyph, 36 pt
        // under the pages' 96 as 18 under the mock-up's 48, so its rings stop at the title, as he saw them. Also when
        // it stands still, so the page does not move between the two.
        .padding(.bottom, making == nil ? 0 : max(0, SetupMetrics.gap * (size / GlyphSize.hero - 1)))
    }

    /// The grey of an agent that is not there: offline (an old reading keeps its look, `FleetAgent.presence`), its two steps for the glyph's
    /// gradient. A colour drawn faint read as a dimmed colour, not as grey (T-24, fix round: Mini offline was a rose at
    /// half strength), so the glyph is drawn in grey, whole; on the canvas its deep step reads 3.3:1.
    static let absentLight = Color(white: 0.62), absentDeep = Color(white: 0.42)

    /// The glyph at rest. **An agent in setup wears its own colours** (the owner, 7 November 2026: "agents should always
    /// come with their icon", and his yes to the mockup): it was a grey dashed outline until it worked.
    @ViewBuilder private func figure(_ look: GlyphLook, _ presence: AgentPresence?) -> some View {
        let absent = presence == .offline || presence == .unknown
        let light = absent ? Self.absentLight : look.light, deep = absent ? Self.absentDeep : look.deep
        ZStack {
            GlyphOutline(kind: look.kind)
                .fill(LinearGradient(colors: [light, deep], startPoint: .topLeading, endPoint: .bottomTrailing))
            GlyphCore(kind: look.kind)
                .fill(look.kind == .moon ? AnyShapeStyle(light) : AnyShapeStyle(Color.white.opacity(GlyphLook.coreOpacity)))
        }
    }
}

extension EnvironmentValues {
    /// The names of the hub's agents in the hub's order, for the glyphs. The window gives it one time.
    @Entry var glyphTeam: [String] = []
    /// Every agent's presence, as the window reads it, for the glyphs that are given none: the Agents table drew
    /// Scout filled and Mini in colour while the sidebar beside it drew Scout in setup and Mini offline.
    @Entry var glyphPresence: [String: AgentPresence] = [:]
    /// The notices stand over a conversation or a task thread, whose column is the narrower one of prose (`BandNotice`).
    @Entry var noticeReading = false
    /// False where a glyph is the subject of what shows and no status: **a setup step's mark draws no dot** (the lead's
    /// call of 29 October 2026, fix round 2; `SetupStep`), as the agent being set up is the step's subject.
    @Entry var glyphDots = true
    /// The agents that this Mac adds, until their chat opens (`FleetStore.isAdding`): the chat's own "Setting up" makes
    /// their glyph (`AgentGlyph.begins`). The window gives it.
    @Entry var glyphAdding: Set<String> = []
}

/// The looks of the last team, so that each glyph does not find them again: also each badge of an agent in a
/// request's words (`CardBadges`).
@MainActor enum GlyphTeams {
    private static var names: [String] = []
    private static var looks: [String: GlyphLook] = [:]

    /// An agent that is not in the team (an earlier agent of an old task) has the first look of its name.
    static func look(of name: String, in team: [String]) -> GlyphLook {
        if team != names { names = team; looks = GlyphLook.team(team) }
        return looks[name] ?? GlyphLook(name: name)
    }
}

/// **An agent's own colour, where a control speaks to that agent** (the owner's yes of 28 October 2026, D-6: a chat's Send
/// in the agent's colour): **the middle of its glyph's own gradient**, half way from its light step to its deep one —
/// Manager's lime, Nova's blue #508CD4 — so the Send reads as the glyph beside it (fix round 2): the deep step, which
/// T-15 made darker for blue and orchid, stood ΔE 11–18 from a blue glyph. **Its ink is white wherever white reads 3:1
/// on it** — the least a symbol asks — **and near-black (`FleetStyle.ink`) on the lighter hues** (fix round 3, item 53):
/// D-6 approved a white arrow on blue and orchid, and the lighter mid colour of fix round 2 had turned both near-black
/// by a rule that took whichever ink stood further from it.
struct AgentTint {
    let fill: Color
    let ink: Color

    @MainActor init(agent: String, team: [String]) {
        let look = GlyphTeams.look(of: agent, in: team)
        let tint = Self.tint(of: look)
        fill = tint.fill
        ink = tint.ink
    }

    /// The colour of a look that no agent of the team has: a model's in Settings › Stats, where the models of one chart
    /// take the looks of a team of their own (`GlyphLook.team`), so they differ as a team's agents do.
    @MainActor init(look: GlyphLook) {
        let tint = Self.tint(of: look)
        fill = tint.fill
        ink = tint.ink
    }

    @MainActor private static var tints: [Int: (fill: Color, ink: Color)] = [:]

    /// The middle of a look's gradient and its ink, by white's contrast on it (WCAG 2), once for each hue.
    @MainActor private static func tint(of look: GlyphLook) -> (fill: Color, ink: Color) {
        if let known = tints[look.tone] { return known }
        func components(_ color: Color) -> [CGFloat] {
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return [0, 0, 0] }
            return [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
        }
        let mid = zip(components(look.light), components(look.deep)).map { ($0 + $1) / 2 }
        func luminance(_ rgb: [CGFloat]) -> CGFloat {
            func linear(_ value: CGFloat) -> CGFloat { value <= 0.040_45 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(rgb[0]) + 0.7152 * linear(rgb[1]) + 0.0722 * linear(rgb[2])
        }
        let fill = luminance(mid)
        let tint = (fill: Color(.sRGB, red: Double(mid[0]), green: Double(mid[1]), blue: Double(mid[2])),
                    ink: 1.05 / (fill + 0.05) >= 3 ? Color.white : FleetStyle.ink)
        tints[look.tone] = tint
        return tint
    }
}

/// The glyph of an agent at work, as Core Animation layers with the same paths as the glyph at rest.
private struct MovingGlyph: NSViewRepresentable {
    let look: GlyphLook
    /// At work now; false while the layers go back to rest.
    let moving: Bool
    /// The way back to rest is a motion too, which Reduce Motion leaves out.
    let eased: Bool
    /// The layers are at rest, and the glyph at rest can take their place.
    let rested: () -> Void

    func makeNSView(context: Context) -> GlyphLayerView { GlyphLayerView() }
    func updateNSView(_ view: GlyphLayerView, context: Context) { view.show(look, moving: moving, eased: eased, rested: rested) }
}

/// **The layers of a moving glyph, in four parts, one in the other**: the holder, which moves and squeezes along the
/// screen's axes; the figure in it, which turns with its colour (the gradient under the outline as a mask); the orbit,
/// which turns the inner mark about the glyph's centre; and the inner mark, which moves, turns and changes its size
/// about its own centre. Each kind moves in its own way, smooth and without a stop (`GlyphMotion`, the owner's "Smooth"
/// of 21 November 2026), and a squeeze stands on the holder because a squeeze on a figure that has turned goes askew.
private final class GlyphLayerView: NSView {
    private let holder = CALayer(), figure = CALayer(), gradient = CAGradientLayer(), outline = CAShapeLayer()
    private let orbit = CALayer(), core = CAShapeLayer()
    private var look: GlyphLook?
    /// The kind, the color and the size that the layers show now.
    private var drawn: (kind: GlyphKind, tone: Int, size: CGSize)?
    /// The layers move; false from the moment work ends, while they go back to rest.
    private var moving = true
    /// What to tell once the layers are back at rest, while they go there.
    private var rested: (() -> Void)?
    /// The number of the way back to rest that runs now: the end of a way back that work cut short tells nothing, also
    /// when work ended again before that end came.
    private var settles = 0
    /// When each track of the motion began, its loop at the glyph's own pace, and where its way in started: for the way
    /// back to rest.
    private var loops: [(track: GlyphMotion.Track, begin: CFTimeInterval, seconds: Double, from: Double)] = []
    /// The way back to rest while it runs: each value from where it was to rest, from when and for how long. Work that
    /// starts again in it goes on from where each part stands, with no jump.
    private var ways: [(part: GlyphMotion.Part, channel: GlyphMotion.Channel, from: Double, to: Double,
                        begin: CFTimeInterval, seconds: Double)] = []
    /// The way back to rest at the end of work, at its shortest.
    private static let wayBack: CFTimeInterval = 0.25

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(holder)
        holder.addSublayer(figure)
        figure.addSublayer(gradient); gradient.mask = outline
        figure.addSublayer(orbit); orbit.addSublayer(core)
        gradient.startPoint = .zero; gradient.endPoint = CGPoint(x: 1, y: 1)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    /// A click goes to the row or the button under the glyph.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ look: GlyphLook, moving: Bool, eased: Bool, rested: @escaping () -> Void) {
        self.look = look
        if moving != self.moving {
            self.moving = moving
            if !moving { settle(eased: eased, then: rested) } else if drawn != nil { move(look) }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let look, bounds.width > 0, bounds.height > 0 else { return }
        if let drawn, drawn.kind == look.kind, drawn.tone == look.tone, drawn.size == bounds.size { return }
        drawn = (look.kind, look.tone, bounds.size)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let motion = look.kind.workMotion, scale = window?.backingScaleFactor ?? 2
        // Each part turns and squeezes about a point of its own: the triangle squeezes on its base and turns about its
        // middle, the drop squeezes on its bottom, the moon swings from its top, the inner mark about its own centre.
        func place(_ part: CALayer, about anchor: UnitPoint) {
            part.bounds = bounds
            part.anchorPoint = CGPoint(x: anchor.x, y: anchor.y)
            part.position = CGPoint(x: bounds.width * anchor.x, y: bounds.height * anchor.y)
        }
        place(holder, about: motion.holderAnchor)
        place(figure, about: motion.figureAnchor)
        place(orbit, about: .center)
        place(core, about: look.kind.coreAnchor)
        for part in [gradient, outline] { part.frame = bounds }
        for part in [gradient, outline, core] as [CALayer] { part.contentsScale = scale }
        gradient.colors = [NSColor(look.light).cgColor, NSColor(look.deep).cgColor]
        outline.path = GlyphOutline(kind: look.kind).path(in: bounds).cgPath
        core.path = GlyphCore(kind: look.kind).path(in: bounds).cgPath
        core.fillColor = look.kind == .moon ? NSColor(look.light).cgColor : NSColor.white.withAlphaComponent(GlyphLook.coreOpacity).cgColor
        CATransaction.commit()
        if moving { move(look) }
    }

    /// A layer that left the window lost its motion.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, moving, let look, drawn != nil { move(look) }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        for part in [gradient, outline, core] as [CALayer] { part.contentsScale = window?.backingScaleFactor ?? 2 }
    }

    private func layer(of part: GlyphMotion.Part) -> CALayer {
        switch part {
        case .holder: holder
        case .figure: figure
        case .orbit: orbit
        case .core: core
        }
    }

    private static func keyPath(_ channel: GlyphMotion.Channel) -> String {
        switch channel {
        case .turn: "transform.rotation.z"
        case .scale: "transform.scale"
        case .scaleX: "transform.scale.x"
        case .scaleY: "transform.scale.y"
        case .side: "transform.translation.x"
        case .lift: "transform.translation.y"
        }
    }

    /// A track's value as its layer takes it: a turn in radians, a move in points of this glyph.
    private func shown(_ value: Double, _ channel: GlyphMotion.Channel) -> Double {
        switch channel {
        case .turn: value * .pi / 180
        case .side: value * Double(bounds.width) / 100
        case .lift: value * Double(bounds.height) / 100
        case .scale, .scaleX, .scaleY: value
        }
    }

    /// **The motion of its kind, without an end, from the glyph at rest or from where each part stands on its way back
    /// to rest (`ways`)**, so work starts without a jump: for its first 0.4 s each value grows from where its part stands
    /// into its loop, which runs from its start meanwhile (`GlyphMotion.Track.value(after:from:loop:)`), and then the
    /// loop alone goes on. The tracks of a kind start together, so its parts keep in step. Each glyph keeps its own pace,
    /// within 10% of its kind's (`GlyphLook.phase`), so two glyphs at work do not move in step.
    ///
    /// **Work is plain to see at the sidebar's 28 points** (the owner, 13 November 2026: "the agent icon should animate
    /// more to make it more obvious that is working"), and the motion is the one sign of work now that work has no dot
    /// (`StatusDot.shows`).
    private func move(_ look: GlyphLook) {
        rested = nil
        loops = []
        let motion = look.kind.workMotion, now = CACurrentMediaTime()
        let seconds = motion.loop * (0.9 + 0.2 * look.phase / (2 * .pi))
        // Where each part stands on a way back to rest that runs now; at rest otherwise.
        func standing(_ track: GlyphMotion.Track) -> Double {
            guard let way = ways.first(where: { $0.part == track.part && $0.channel == track.channel }) else {
                return track.rest
            }
            let done = min(max((now - way.begin) / way.seconds, 0), 1)
            // A turn on its way back stands a whole turn from rest at most: its loop starts at no turn.
            let value = way.from + (way.to - way.from) * GlyphCurve.easeOut(done)
            return way.channel == .turn ? value - way.to : value
        }
        let from = motion.tracks.map(standing)
        ways = []
        for part in [holder, figure, orbit, core] as [CALayer] { part.removeAllAnimations() }
        for (index, track) in motion.tracks.enumerated() {
            let layer = layer(of: track.part), keyPath = Self.keyPath(track.channel)
            // The loop from the end of the way in, where it stands then: it runs from its start with the way in.
            let points = track.samples(over: seconds)
            let loop = CAKeyframeAnimation(keyPath: keyPath)
            loop.values = points.map { NSNumber(value: shown($0.value, track.channel)) }
            loop.keyTimes = points.map { NSNumber(value: $0.at) }
            loop.calculationMode = .linear
            loop.duration = seconds
            loop.repeatCount = .infinity
            loop.beginTime = layer.convertTime(now + GlyphMotion.wayIn, from: nil)
            loop.timeOffset = GlyphMotion.wayIn
            loop.isRemovedOnCompletion = false
            layer.add(loop, forKey: "loop.\(index)")
            let entry = track.wayInSamples(from: from[index], loop: seconds)
            let way = CAKeyframeAnimation(keyPath: keyPath)
            way.values = entry.map { NSNumber(value: shown($0.value, track.channel)) }
            way.keyTimes = entry.map { NSNumber(value: $0.at) }
            way.calculationMode = .linear
            way.duration = GlyphMotion.wayIn
            way.beginTime = layer.convertTime(now, from: nil)
            // Kept after its end, where it shows nothing: Core Animation drops a removable motion of a layer that is not
            // in a window yet when a transaction commits, and the part would stand at rest until its loop.
            way.isRemovedOnCompletion = false
            layer.add(way, forKey: "in.\(index)")
            loops.append((track, now, seconds, from[index]))
        }
    }

    /// **Work ends on the glyph at rest, not with a snap and not on a frozen frame**: each value goes back from where
    /// it is shown now to rest, easing out, and only then does the glyph at rest take the layers' place. **A turn goes
    /// to the nearest whole turn, back or on**, because the gradient turns with the figure and only a whole turn looks
    /// as the glyph at rest does; an inner mark, which has no gradient, to the nearest turn of its own symmetry
    /// (`GlyphKind.coreSymmetry`). A long way back takes a little longer.
    private func settle(eased: Bool, then rested: @escaping () -> Void) {
        self.rested = rested
        settles += 1
        let settle = settles, now = CACurrentMediaTime(), symmetry = Double(look?.kind.coreSymmetry ?? 1)
        typealias Way = (part: GlyphMotion.Part, channel: GlyphMotion.Channel, from: Double, to: Double)
        let ways = loops.map { loop -> Way in
            let track = loop.track
            // On its way in or in its loop, as the layer shows it now.
            let value = track.value(after: now - loop.begin, from: loop.from, loop: loop.seconds)
            let whole = track.part == .core ? 360 / symmetry : 360
            let to = track.channel == .turn ? (value / whole).rounded() * whole : track.rest
            return (track.part, track.channel, value, to)
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.moving, self.settles == settle, let rested = self.rested else { return }
                self.rested = nil
                rested()
            }
        }
        for part in [holder, figure, orbit, core] as [CALayer] { part.removeAllAnimations() }
        loops = []
        self.ways = []
        for (index, way) in ways.enumerated() where eased && abs(way.from - way.to) > 1e-6 {
            let seconds = Self.wayBack + (way.channel == .turn ? 0.35 * min(abs(way.from - way.to), 180) / 180 : 0)
            let back = CABasicAnimation(keyPath: Self.keyPath(way.channel))
            back.fromValue = shown(way.from, way.channel)
            back.toValue = shown(way.to, way.channel)
            back.duration = seconds
            back.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer(of: way.part).add(back, forKey: "rest.\(index)")
            self.ways.append((way.part, way.channel, way.from, way.to, now, seconds))
        }
        CATransaction.commit()
    }
}

/// An agent as its glyph with the status dot of a presence its caller knows, on the ground its caller names. The dot is
/// the one dot of the app, 6 points at every size of the glyph, with a ring of the surface under it, and its centre on
/// the glyph's lower right corner: it grew with the glyph and stood 11 points beside the sidebar's 6 on every agent page
/// (the owner, 27 October 2026: "they should all be like the smaller ones"). Every glyph draws it (`AgentGlyph.dot`).
struct AgentAvatar: View {
    let name: String
    let presence: AgentPresence
    var size: CGFloat = GlyphSize.list
    var surface = FleetStyle.surface
    /// The glyph shows the agent's work by moving (`AgentGlyph.moves`): the head of its status panel.
    var moves = false

    var body: some View {
        AgentGlyph(name: name, presence: presence, size: size, moves: moves, ground: surface)
    }
}
