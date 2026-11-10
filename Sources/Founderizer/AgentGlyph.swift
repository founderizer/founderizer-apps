import AppKit
import FleetMark
import SwiftUI

// An agent's own mark: a shape and a color that come from its name and from its place in the hub's list of agents,
// so an agent looks the same on every page, on every Mac and in every run. The provider's icon is for the provider
// and its account, not for the agent. The glyph moves a little while its agent works, and once when the pointer
// comes to it. Core Animation moves it: the app does no work for a frame. See UI-PATTERNS.md.
//
// The mark itself — `GlyphKind`, `GlyphLook` and the two shapes — is `FleetMark`, which this app and the owner's
// iPhone app both link, so one agent wears one face on his two screens. Everything below is this app's own: the
// view, the layers and the motion, which a phone does not use.

/// **The four sizes of an agent's glyph**, and every glyph of the app stands at one of them. The owner, 27 October
/// 2026, of two dot sizes side by side: "why are they different?!?! they should all be like the smaller ones" — and
/// the glyphs came in ten sizes, 14 to 48 points, most of them under 6 points apart, so two lists side by side drew
/// one agent at two sizes that read as a mistake. Four steps, each a clear step from the next.
enum GlyphSize {
    /// Beside a name in a line of words: a select, a server's agents, a Tasks card, Knowledge, a conversation, agent
    /// messages, Secrets, a request's "From".
    static let inline: CGFloat = 16
    /// The leading mark of a form row (`RowMark`, as wide as its column): Conversations, a person's page, Access; the
    /// chat's pill (the lead's call on T-04); and the head of an agent's page, whose name begins where its rows' words do.
    static let row: CGFloat = 22
    /// A list of agents: the main sidebar.
    static let list: CGFloat = 28
    /// The mark over a setup step, the agents to choose from in Add person, and the head of an agent's status panel
    /// (the lead's call on T-04).
    static let hero: CGFloat = 48
}

struct AgentGlyph: View {
    let name: String
    /// nil: the agent's presence as the window knows it (`glyphPresence`), so one agent wears one look in every place
    /// of a screen — grey while it is offline, in its own colours from the moment it is added; an agent the window does
    /// not know is the mark alone, at rest and in colour, with no dot.
    var presence: AgentPresence?
    var size: CGFloat = GlyphSize.list
    /// **Whether this glyph shows the agent's work by moving**: only where the agent itself is what the eye is on —
    /// its row of the main sidebar, the pill over its chat and its status panel. A table or a card draws an agent at
    /// work at rest, so a screen does not move in five places for one agent.
    var moves = false
    /// **Its status dot stands on its lower right corner, by default** (D-8 item 2, "as everywhere else"; fix round 2 of
    /// 29 October 2026): wherever the glyph stands for the agent, it wears the dot of the presence it shows, as its
    /// sidebar row does. The search card's rows, the Tasks cards and the task panel drew the glyph alone beside a
    /// sidebar that drew the same agent with its dot. False where the caller draws no status.
    var dot = true
    /// What the dot's ring stands on, so the ring parts the dot from the glyph: nil for a card's surface on a card and the
    /// canvas elsewhere.
    var ground: Color?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.glyphTeam) private var team
    @Environment(\.glyphPresence) private var presences
    @Environment(\.onCard) private var onCard
    @Environment(\.glyphDots) private var dots
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
            // Layers that the window server moves. A SwiftUI timeline made the window update its whole view tree for
            // each frame: about 30% of a processor core for two glyphs of 18 points.
            if moving || layered {
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
        // The small jump is for the pointer only: work starts from the glyph at rest, without a jump of its own.
        .onHover { inside in if inside && !reduceMotion { pops += 1 } }
        .onChange(of: moving, initial: true) { _, now in if now { layered = true } }
        .accessibilityHidden(true)
        // The one dot of the app, 6 points at every size of the glyph, its centre on the glyph's lower right corner; it
        // neither jumps nor moves with the glyph, and its words are its hover and its VoiceOver label (`StatusDot`).
        .overlay(alignment: .bottomTrailing) {
            if dot, dots, let state {
                StatusDot(presence: state, ring: ground ?? (onCard ? FleetStyle.surface : FleetStyle.canvas))
                    .offset(x: StatusDot.side / 2, y: StatusDot.side / 2)
            }
        }
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
    /// The notices stand over a conversation or a task thread, whose column is the narrower one of prose (FleetNotice).
    @Entry var noticeReading = false
    /// False where a glyph is the subject of what shows and no status: **a setup step's mark draws no dot** (the lead's
    /// call of 29 October 2026, fix round 2; `SetupStep`), as the agent being set up is the step's subject.
    @Entry var glyphDots = true
}

/// The looks of the last team, so that each glyph does not find them again.
@MainActor private enum GlyphTeams {
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

/// The layers of a moving glyph: the figure (it turns, breathes or rocks), its color under the outline as a mask, and
/// the inner mark, which turns about the glyph's center and changes its size about its own center.
private final class GlyphLayerView: NSView {
    private let figure = CALayer(), gradient = CAGradientLayer(), outline = CAShapeLayer(), orbit = CALayer(), core = CAShapeLayer()
    private var look: GlyphLook?
    /// The kind, the color and the size that the layers show now.
    private var drawn: (kind: GlyphKind, tone: Int, size: CGSize)?
    /// The layers move; false from the moment work ends, while they go back to rest.
    private var moving = true
    /// What to tell once the layers are back at rest, while they go there.
    private var rested: (() -> Void)?
    /// The tween into a swing and back to rest at the end of work.
    private static let tween: CFTimeInterval = 0.25

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(figure)
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
        let anchor = look.kind.coreAnchor, scale = window?.backingScaleFactor ?? 2
        for part in [figure, gradient, outline, orbit] { part.frame = bounds }
        core.bounds = bounds; core.anchorPoint = CGPoint(x: anchor.x, y: anchor.y)
        core.position = CGPoint(x: bounds.width * anchor.x, y: bounds.height * anchor.y)
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

    /// **The motion of each kind, without an end, and from the glyph at rest**, so work starts without a jump: a turn
    /// starts at 0°, a breath at its full size, and a swing with rest in its middle first reaches its end in a tween
    /// (`tween`). Each glyph keeps its own pace, within 10% of its kind's (`GlyphLook.phase`), so two glyphs at work do
    /// not move in step. It used to start each glyph at its own point of the loop, which was a jump of up to a whole
    /// turn in the first frame.
    private func move(_ look: GlyphLook) {
        rested = nil
        for part in [figure, orbit, core] as [CALayer] { part.removeAllAnimations() }
        let pace = 0.9 + 0.2 * look.phase / (2 * .pi), now = CACurrentMediaTime()
        switch look.kind.motion {
        case .turn:
            turn(figure, to: 2 * .pi, seconds: 18 * pace, now)
            turn(orbit, to: -2 * .pi, seconds: 7.2 * pace, now)
            swing(core, "transform.scale", 0.88, 1.12, rest: 1, seconds: 1.3 * pace, now)
        case .breathe:
            swing(figure, "transform.scale", 0.9, 1, rest: 1, seconds: 1.3 * pace, now)
            if look.kind == .drop { swing(core, "transform.scale", 0.75, 1.25, rest: 1, seconds: 1.05 * pace, now) }
            else { turn(orbit, to: 2 * .pi, seconds: 4.5 * pace, now) }
        case .rock:
            swing(figure, "transform.rotation.z", -0.14, 0.14, rest: 0, seconds: 1.43 * pace, now)
            swing(core, "transform.scale", 0.8, 1.2, rest: 1, seconds: 1.05 * pace, now)
        }
    }

    /// A turn without an end, from 0.
    private func turn(_ layer: CALayer, to angle: Double, seconds: Double, _ now: CFTimeInterval) {
        let motion = CABasicAnimation(keyPath: "transform.rotation.z")
        motion.fromValue = 0; motion.toValue = angle; motion.duration = seconds
        motion.repeatCount = .infinity
        motion.timingFunction = CAMediaTimingFunction(name: .linear)
        motion.beginTime = layer.convertTime(now, from: nil)
        motion.isRemovedOnCompletion = false
        layer.add(motion, forKey: "turn")
    }

    /// A swing between two values without an end. Where rest is one of its ends it starts there; where rest is in its
    /// middle, a tween takes the part from rest to the end the swing starts from.
    private func swing(_ layer: CALayer, _ key: String, _ low: Double, _ high: Double, rest: Double, seconds: Double,
                       _ now: CFTimeInterval) {
        let start = rest == low ? low : high, other = start == low ? high : low
        var begin = now
        if rest != start {
            let tween = CABasicAnimation(keyPath: key)
            tween.fromValue = rest; tween.toValue = start; tween.duration = Self.tween
            tween.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            tween.beginTime = layer.convertTime(now, from: nil)
            layer.add(tween, forKey: key + ".from-rest")
            begin = now + Self.tween
        }
        let motion = CABasicAnimation(keyPath: key)
        motion.fromValue = start; motion.toValue = other; motion.duration = seconds
        motion.autoreverses = true; motion.repeatCount = .infinity
        motion.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        motion.beginTime = layer.convertTime(begin, from: nil)
        motion.isRemovedOnCompletion = false
        layer.add(motion, forKey: key)
    }

    /// **Work ends on the glyph at rest, not with a snap and not on a frozen frame**: each part goes back from where
    /// it is shown now to rest in 250 ms, easing out, and only then does the glyph at rest take the layers' place.
    private func settle(eased: Bool, then rested: @escaping () -> Void) {
        self.rested = rested
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.moving, let rested = self.rested else { return }
                self.rested = nil
                rested()
            }
        }
        for part in [figure, orbit, core] as [CALayer] {
            let shown = part.presentation()?.transform ?? part.transform
            part.removeAllAnimations()
            guard eased, !CATransform3DIsIdentity(shown) else { continue }
            let back = CABasicAnimation(keyPath: "transform")
            back.fromValue = NSValue(caTransform3D: shown)
            back.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            back.duration = Self.tween
            back.timingFunction = CAMediaTimingFunction(name: .easeOut)
            part.add(back, forKey: "rest")
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
