import FleetMark
import SwiftUI
import UIKit

// How the phone draws an agent's mark. The mark itself — the shape, the colour and the rule that gives a name its
// own — is `FleetMark`, which both apps link, so one agent looks the same on the owner's phone and on his Mac.
// `FleetMarkTests` holds the marks of his fleet still.
//
// At rest the mark is SwiftUI shapes. **While its agent works it moves on Core Animation layers** (fix round 2,
// item 83), with the same paths and the Mac glyph's own motion: a SwiftUI animation that repeats without an end draws
// the page again in every frame (`UI-PATTERNS.md`: motion that runs for ever is Core Animation).

/// The looks of the team that the phone read last, so that each row does not find them again.
@MainActor enum MarkTeam {
    private static var names: [String] = []
    private static var looks: [String: GlyphLook] = [:]

    /// An agent that is not in the team (an earlier agent of an old task) has the first look of its name.
    static func look(of name: String, in team: [String]) -> GlyphLook {
        if team != names { names = team; looks = GlyphLook.team(team) }
        return looks[name] ?? GlyphLook(name: name)
    }
}

extension GlyphLook {
    /// **The glyph's own colour as the eye reads it: the middle of its two steps** (fix round 2, item 90). A chat's Send
    /// takes it: the deep step stood 11 to 18 ΔE2000 from a blue agent's glyph (Nova's #1470B8 beside a #508CD4 body).
    var mid: Color {
        var one: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0), two = one
        UIColor(light).getRed(&one.0, green: &one.1, blue: &one.2, alpha: &one.3)
        UIColor(deep).getRed(&two.0, green: &two.1, blue: &two.2, alpha: &two.3)
        return Color(red: Double(one.0 + two.0) / 2, green: Double(one.1 + two.1) / 2, blue: Double(one.2 + two.2) / 2)
    }
}

extension EnvironmentValues {
    /// The names of the hub's agents in the hub's order, for the marks. The app gives it one time.
    @Entry var markTeam: [String] = []
}

/// An agent's mark with its state. The state is in the mark itself, as it is on the Mac: colour for an agent that
/// answers, **grey, drawn whole, for one that is offline or not known**, and **a dashed outline in neutral grey for one
/// in setup** (fix round 2, item 66: one state, one look on both screens; the phone drew setup in the agent's own colour
/// and an offline agent in its colour at half strength). A word or a dot says the same beside it, so colour is never
/// the only cue.
struct AgentMark: View {
    let name: String
    var state: AgentState = .online
    var size: CGFloat = 40
    /// It moves while its agent works only where it stands for the agent itself — a row of Chats, the pill over
    /// its chat, the "Thinking" of its chat, its own page — and rests where a list names it, as the Mac's glyph does.
    var moves = true
    @Environment(\.markTeam) private var team
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The moving layers stay until their motion is back at rest, so work never ends with a snap.
    @State private var layered = false

    /// The grey of an agent that is not there, the Mac's two steps (`AgentGlyph.absentLight`, `absentDeep`).
    static let absentLight = Color(white: 0.62)
    static let absentDeep = Color(white: 0.42)

    var body: some View {
        let look = MarkTeam.look(of: name, in: team)
        Group {
            if moving || layered {
                MovingMark(look: look, moving: moving, eased: !reduceMotion) { layered = false }
            } else {
                figure(look)
            }
        }
        .frame(width: size, height: size)
        .onChange(of: moving, initial: true) { _, now in if now { layered = true } }
        .accessibilityHidden(true)
    }

    /// An agent at work moves, only while its page is on screen. Reduce Motion stops it.
    private var moving: Bool { moves && state == .working && !reduceMotion }

    @ViewBuilder private func figure(_ look: GlyphLook) -> some View {
        if state.base == .setup {
            GlyphUnion(kind: look.kind)
                .stroke(Brand.muted, style: StrokeStyle(lineWidth: max(1.2, size * 0.06), lineCap: .round,
                                                        lineJoin: .round, dash: [size * 0.13, size * 0.11]))
                .padding(size * 0.05)
        } else {
            let absent = state.base == .offline || state.base == .unknown
            let light = absent ? Self.absentLight : look.light
            let deep = absent ? Self.absentDeep : look.deep
            ZStack {
                GlyphOutline(kind: look.kind)
                    .fill(LinearGradient(colors: [light, deep], startPoint: .topLeading, endPoint: .bottomTrailing))
                GlyphCore(kind: look.kind)
                    .fill(look.kind == .moon ? AnyShapeStyle(light)
                          : AnyShapeStyle(Color.white.opacity(GlyphLook.coreOpacity)))
            }
        }
    }
}

/// **The outline of the glyph's whole shape** (fix round 3, item 52): a lobed glyph (clover, flower) is circles over one
/// another, and the dashed stroke of each circle was a tangle of dashes in setup; the stroke goes round the shape they
/// make together.
private struct GlyphUnion: Shape {
    let kind: GlyphKind
    func path(in rect: CGRect) -> Path {
        Path(GlyphOutline(kind: kind).path(in: rect).cgPath.normalized(using: .winding))
    }
}

/// The mark of an agent at work, as Core Animation layers with the same paths as the mark at rest: the figure moves
/// on the render server, and the page draws once.
private struct MovingMark: UIViewRepresentable {
    let look: GlyphLook
    /// At work now; false while the layers go back to rest.
    let moving: Bool
    /// The way back to rest is a motion too, which Reduce Motion leaves out.
    let eased: Bool
    /// The layers are at rest, and the mark at rest can take their place.
    let rested: () -> Void

    func makeUIView(context: Context) -> MarkLayerView { MarkLayerView() }
    func updateUIView(_ view: MarkLayerView, context: Context) {
        view.show(look, moving: moving, eased: eased, rested: rested)
    }
}

/// **The layers of a moving mark, as the Mac's glyph (`GlyphLayerView`), in four parts, one in the other**: the
/// holder, which moves and squeezes along the screen's axes; the figure in it, which turns with its colour (the
/// gradient under the outline as a mask); the orbit, which turns the inner mark about the mark's centre; and the inner
/// mark, which turns and changes its size about its own centre. Each kind moves in its own way (`GlyphMotion`, the
/// owner's "A · Own character" of 20 November 2026, and of the phone: "Yes, iPhone too"), and a squeeze stands on the
/// holder because a squeeze on a figure that has turned goes askew.
///
/// **The motion is the Mac's, value for value**: `move` and `settle` are `GlyphLayerView`'s, so a change to one of
/// them goes to the other. Work is plain to see (the owner, 13 November 2026, of the Mac's sidebar: "the agent icon
/// should animate more to make it more obvious that is working"), and the motion is the one sign of work now that work
/// has no dot.
final class MarkLayerView: UIView {
    private let holder = CALayer(), figure = CALayer(), gradient = CAGradientLayer(), outline = CAShapeLayer()
    private let orbit = CALayer(), core = CAShapeLayer()
    private var look: GlyphLook?
    /// The kind, the colour and the size that the layers show now.
    private var drawn: (kind: GlyphKind, tone: Int, size: CGSize)?
    /// The layers move; false from the moment work ends, while they go back to rest.
    private var moving = true
    /// What to tell once the layers are back at rest, while they go there.
    private var rested: (() -> Void)?
    /// The number of the way back to rest that runs now: the end of a way back that work cut short tells nothing, also
    /// when work ended again before that end came.
    private var settles = 0
    /// When each track of the motion began its loops, its loop at the mark's own pace, and where its tween into the
    /// loop started: for the way back to rest.
    private var loops: [(track: GlyphMotion.Track, begin: CFTimeInterval, seconds: Double, from: Double)] = []
    /// The way back to rest while it runs: each value from where it was to rest, from when and for how long. Work that
    /// starts again in it goes on from where each part stands, with no jump.
    private var ways: [(part: GlyphMotion.Part, channel: GlyphMotion.Channel, from: Double, to: Double,
                        begin: CFTimeInterval, seconds: Double)] = []
    /// CA's ease-out, to know where a part stands on its way back.
    private static let easeOut = GlyphCurve(0, 0, 0.58, 1)
    /// The tween into a loop from rest, or from where a part stands on its way back, and the way back to rest at the
    /// end of work.
    private static let tween: CFTimeInterval = 0.25

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        layer.addSublayer(holder)
        holder.addSublayer(figure)
        figure.addSublayer(gradient)
        gradient.mask = outline
        figure.addSublayer(orbit)
        orbit.addSublayer(core)
        gradient.startPoint = .zero
        gradient.endPoint = CGPoint(x: 1, y: 1)
        // A view that is laid out before it is in a window does not know its screen's scale yet: its layers take the
        // scale when it comes, as the Mac's take a new backing scale.
        registerForTraitChanges([UITraitDisplayScale.self]) { (view: MarkLayerView, _: UITraitCollection) in
            view.scaleLayers()
        }
    }

    required init?(coder: NSCoder) { nil }

    /// The layers' pixels at the screen's scale.
    private func scaleLayers() {
        let scale = max(traitCollection.displayScale, 1)
        for part in [gradient, outline, core] as [CALayer] { part.contentsScale = scale }
    }

    func show(_ look: GlyphLook, moving: Bool, eased: Bool, rested: @escaping () -> Void) {
        self.look = look
        if moving != self.moving {
            self.moving = moving
            if !moving { settle(eased: eased, then: rested) } else if drawn != nil { move(look) }
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let look, bounds.width > 0, bounds.height > 0 else { return }
        if let drawn, drawn.kind == look.kind, drawn.tone == look.tone, drawn.size == bounds.size { return }
        // The same look at a new size (every place sizes its mark with the text size) goes on with its motion where it
        // is; a new look starts its own motion.
        let resized = drawn.map { $0.kind == look.kind && $0.tone == look.tone } ?? false
        drawn = (look.kind, look.tone, bounds.size)
        let motion = look.kind.workMotion
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Each part moves, so it takes its place by its bounds and position, never by a frame, and turns and squeezes
        // about a point of its own: the triangle squeezes on its base and turns about its middle, the drop squeezes on
        // its bottom, the moon swings from its top, the inner mark about its own centre.
        func place(_ part: CALayer, about anchor: UnitPoint) {
            part.bounds = bounds
            part.anchorPoint = CGPoint(x: anchor.x, y: anchor.y)
            part.position = CGPoint(x: bounds.width * anchor.x, y: bounds.height * anchor.y)
        }
        place(holder, about: motion.holderAnchor)
        place(figure, about: motion.figureAnchor)
        place(orbit, about: .center)
        place(core, about: look.kind.coreAnchor)
        for part in [gradient, outline] as [CALayer] { part.frame = bounds }
        scaleLayers()
        gradient.colors = [UIColor(look.light).cgColor, UIColor(look.deep).cgColor]
        outline.path = GlyphOutline(kind: look.kind).path(in: bounds).cgPath
        core.path = GlyphCore(kind: look.kind).path(in: bounds).cgPath
        core.fillColor = look.kind == .moon ? UIColor(look.light).cgColor
            : UIColor.white.withAlphaComponent(GlyphLook.coreOpacity).cgColor
        CATransaction.commit()
        if moving { if resized, looping { lift() } else { move(look) } }
    }

    /// A layer that left the window can lose its motion; one that kept it goes on as it is.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, moving, let look, drawn != nil, !looping else { return }
        move(look)
    }

    /// Every loop of the motion still runs on its layer: a layer out of a window can lose them, and a mark that lost
    /// one starts its whole motion again, not with a part of it.
    private var looping: Bool {
        !loops.isEmpty && loops.indices.allSatisfy {
            layer(of: loops[$0].track.part).animation(forKey: "loop.\($0)") != nil
        }
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
        case .lift: "transform.translation.y"
        }
    }

    /// A track's value as its layer takes it: a turn in radians, a lift in points of this mark.
    private func shown(_ value: Double, _ channel: GlyphMotion.Channel) -> Double {
        switch channel {
        case .turn: value * .pi / 180
        case .lift: value * Double(bounds.height) / 100
        case .scale, .scaleX, .scaleY: value
        }
    }

    /// **The motion of its kind, without an end, from the mark at rest or from where each part stands on its way back
    /// to rest (`ways`)**, so work starts without a jump: each track loops from its first key, a track that does not
    /// start where its part stands first eases there (`tween`), and the loops of a kind start together, so its parts
    /// keep in step. Each mark keeps its own pace, within 10% of its kind's (`GlyphLook.phase`), so two marks at work
    /// do not move in step.
    private func move(_ look: GlyphLook) {
        rested = nil
        loops = []
        let pace = 0.9 + 0.2 * look.phase / (2 * .pi), now = CACurrentMediaTime(), tracks = look.kind.workMotion.tracks
        // Where each part stands on a way back to rest that runs now; at rest otherwise.
        func standing(_ track: GlyphMotion.Track) -> Double {
            guard let way = ways.first(where: { $0.part == track.part && $0.channel == track.channel }) else {
                return track.rest
            }
            let done = min(max((now - way.begin) / way.seconds, 0), 1)
            // A turn on its way back stands a whole turn from rest at most: its loop starts at no turn.
            let value = way.from + (way.to - way.from) * Self.easeOut(done)
            return way.channel == .turn ? value - way.to : value
        }
        let from = tracks.map(standing)
        ways = []
        for part in [holder, figure, orbit, core] as [CALayer] { part.removeAllAnimations() }
        // The loops of a kind start together, so its parts keep in step: after the tween when one of them needs it.
        let begin = now + (zip(tracks, from).contains { abs($0.value(at: 0) - $1) > 1e-9 } ? Self.tween : 0)
        for (index, track) in tracks.enumerated() {
            let layer = layer(of: track.part), keyPath = Self.keyPath(track.channel), seconds = track.loop * pace
            let start = track.value(at: 0)
            if abs(start - from[index]) > 1e-9 {
                let tween = CABasicAnimation(keyPath: keyPath)
                tween.fromValue = shown(from[index], track.channel)
                tween.toValue = shown(start, track.channel)
                tween.duration = Self.tween
                tween.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                tween.beginTime = layer.convertTime(now, from: nil)
                layer.add(tween, forKey: "rest.\(index)")
            }
            layer.add(loop(track, seconds: seconds, from: begin, on: layer), forKey: "loop.\(index)")
            loops.append((track, begin, seconds, from[index]))
        }
    }

    /// A track's loop without an end, from `begin`, in its layer's values at the mark's size now.
    private func loop(_ track: GlyphMotion.Track, seconds: Double, from begin: CFTimeInterval,
                      on layer: CALayer) -> CAKeyframeAnimation {
        let points = track.samples(over: seconds)
        let loop = CAKeyframeAnimation(keyPath: Self.keyPath(track.channel))
        loop.values = points.map { NSNumber(value: shown($0.value, track.channel)) }
        loop.keyTimes = points.map { NSNumber(value: $0.at) }
        loop.calculationMode = .linear
        loop.duration = seconds
        loop.repeatCount = .infinity
        loop.beginTime = layer.convertTime(begin, from: nil)
        loop.isRemovedOnCompletion = false
        return loop
    }

    /// **The lifts again at a new size, in step with the loops that run**: a lift is in points of the mark and no
    /// other value is, so the motion goes on where it is (`move` again would send each part to rest first). A lift on
    /// its tween into its loop ends that tween at its old size, within 0.25 s. The Mac's glyph keeps its size.
    private func lift() {
        for (index, loop) in loops.enumerated() where loop.track.channel == .lift {
            let layer = layer(of: loop.track.part)
            layer.add(self.loop(loop.track, seconds: loop.seconds, from: loop.begin, on: layer),
                      forKey: "loop.\(index)")
        }
    }

    /// **Work ends on the mark at rest, not with a snap and not on a frozen frame**: each value goes back from where it
    /// is shown now to rest, easing out, and only then does the mark at rest take the layers' place. **A turn goes to
    /// the nearest whole turn, back or on**, because the gradient turns with the figure and only a whole turn looks as
    /// the mark at rest does; an inner mark, which has no gradient, to the nearest turn of its own symmetry
    /// (`GlyphKind.coreSymmetry`). A long way back takes a little longer.
    private func settle(eased: Bool, then rested: @escaping () -> Void) {
        self.rested = rested
        settles += 1
        let settle = settles, now = CACurrentMediaTime(), symmetry = Double(look?.kind.coreSymmetry ?? 1)
        typealias Way = (part: GlyphMotion.Part, channel: GlyphMotion.Channel, from: Double, to: Double)
        let ways = loops.map { loop -> Way in
            let track = loop.track
            let value: Double
            if now < loop.begin {
                // Still on its tween into its loop, from rest or from where a way back stood: CA's ease-in-out.
                let done = min(max(1 - (loop.begin - now) / Self.tween, 0), 1)
                value = loop.from + (track.value(at: 0) - loop.from) * GlyphCurve.swing(done)
            } else {
                value = track.value(at: ((now - loop.begin) / loop.seconds).truncatingRemainder(dividingBy: 1))
            }
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
            let seconds = Self.tween + (way.channel == .turn ? 0.35 * min(abs(way.from - way.to), 180) / 180 : 0)
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

/// An agent at the head of a row: its mark, with its state as the badge that a list of conversations puts on it.
/// Orange while it needs him or is limited, an orange ring offline and a grey one in setup or unknown; **an agent that
/// works or is simply online has no badge** (`AgentState.hasDot`; the owner, 13 November 2026: "remove all green status
/// dots ... only show red/other colors if there is some kind of problem"; his yes of 28 October 2026 to D-8 for
/// online). Work is the mark's motion, and with Reduce Motion its green badge as before.
///
/// **The badge is 8 points at every size of the mark, the size of the unread dot beside it**, in a 2-point ring of
/// the page. It was 22 % of the mark — 12 points on a Chats row, beside the 8-point unread dot of the same row, and
/// two dots of one list at two sizes are what the owner reads as a bug ("why are they different?!?! they should all be
/// like the smaller ones").
///
/// **It keeps its place on the mark's own shape at every text size** (polish pass): at the ordinary size its centre
/// stands 4 points in from the mark's corner, and as the mark grows it moves with the shape's edge (`badgeCentre`).
/// It kept the 4 points from the box's corner, and at the largest size it stood 5.5 points off a round mark that it
/// touches at the ordinary size.
struct AgentAvatar: View {
    let name: String
    let state: AgentState
    /// Its size at the ordinary text size.
    var base: CGFloat = 40
    /// Whether the mark moves while its agent works: where it stands for the agent itself (a row of Chats), and not
    /// where a list names it.
    var moves = true
    /// What the badge's ring is cut from: the page under the mark.
    var ring: Color = Brand.canvas
    @Environment(\.markTeam) private var team
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .headline) private var scale: CGFloat = 1
    private var size: CGFloat { Self.side(base: base, scale: scale) }

    /// The side of a mark of `base` points at the ordinary text size, where the headline's scale is `scale`: it grows
    /// with the text, but only by half, because past that the row has no width left for the words.
    static func side(base: CGFloat, scale: CGFloat) -> CGFloat { base * min(scale, 1.5) }

    var body: some View {
        AgentMark(name: name, state: state, size: size, moves: moves)
            .overlay(alignment: .bottomTrailing) {
                if state.hasDot(reduceMotion: reduceMotion) {
                    // From the 12-point badge's place in the corner to its centre on the mark's diagonal.
                    let shift = Self.badgeCentre(kind: MarkTeam.look(of: name, in: team).kind, base: base, size: size)
                        - size + 6
                    StatusDot(state: state, size: 8)
                        .padding(2)
                        .background(ring, in: Circle())
                        .offset(x: shift, y: shift)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(agentName(name)), \(state.words)")
    }

    /// **Where the badge's centre stands on the diagonal of a mark of `size` points that is `base` points at the
    /// ordinary text size**, from the mark's top-leading corner: `base - 4` at the ordinary size, and from there it
    /// moves as the shape's edge on that diagonal moves (`GlyphCorner`), so it keeps its distance to the shape.
    static func badgeCentre(kind: GlyphKind, base: CGFloat, size: CGFloat) -> CGFloat {
        base - 4 + GlyphCorner.share(of: kind) * (size - base)
    }
}

/// **Where a glyph's own edge crosses its square's diagonal to the bottom-trailing corner**, as a share of the side from
/// the top-leading corner: 0.83 for the round glyph, whose edge stands at 92 % of the half side. Found once for each
/// shape, from the corner in, so a crescent or a star gives its outer edge.
@MainActor enum GlyphCorner {
    private static var shares: [GlyphKind: CGFloat] = [:]

    static func share(of kind: GlyphKind) -> CGFloat {
        if let share = shares[kind] { return share }
        let side: CGFloat = 1000
        let path = GlyphOutline(kind: kind).path(in: CGRect(x: 0, y: 0, width: side, height: side))
        func inShape(_ t: CGFloat) -> Bool { path.contains(CGPoint(x: t, y: t)) }
        // In steps from the corner to the first point of the shape, then halves of the last step.
        var outside = side, inside = side / 2
        var t = side
        while t > side / 2 {
            if inShape(t) { inside = t; break }
            outside = t
            t -= 4
        }
        for _ in 0..<12 {
            let middle = (outside + inside) / 2
            if inShape(middle) { inside = middle } else { outside = middle }
        }
        let share = inside / side
        shares[kind] = share
        return share
    }
}
