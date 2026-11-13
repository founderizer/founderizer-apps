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
    /// The breathing layers stay until their motion is back at rest, so work never ends with a snap.
    @State private var layered = false

    /// The grey of an agent that is not there, the Mac's two steps (`AgentGlyph.absentLight`, `absentDeep`).
    static let absentLight = Color(white: 0.62)
    static let absentDeep = Color(white: 0.42)

    var body: some View {
        let look = MarkTeam.look(of: name, in: team)
        Group {
            if breathes || layered {
                BreathingMark(look: look, breathing: breathes, eased: !reduceMotion) { layered = false }
            } else {
                figure(look)
            }
        }
        .frame(width: size, height: size)
        .onChange(of: breathes, initial: true) { _, now in if now { layered = true } }
        .accessibilityHidden(true)
    }

    /// An agent at work moves, only while its page is on screen. Reduce Motion stops it.
    private var breathes: Bool { moves && state == .working && !reduceMotion }

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
private struct BreathingMark: UIViewRepresentable {
    let look: GlyphLook
    /// At work now; false while the layers go back to rest.
    let breathing: Bool
    /// The way back to rest is a motion too, which Reduce Motion leaves out.
    let eased: Bool
    /// The layers are at rest, and the mark at rest can take their place.
    let rested: () -> Void

    func makeUIView(context: Context) -> BreathingMarkView { BreathingMarkView() }
    func updateUIView(_ view: BreathingMarkView, context: Context) {
        view.show(look, breathing: breathing, eased: eased, rested: rested)
    }
}

/// The layers of a moving mark, as the Mac's (`GlyphLayerView`): the figure (it turns, breathes or rocks), its colour
/// under the outline as a mask, and the inner mark, which turns about the mark's centre (`orbit`) and changes its size
/// about its own centre.
///
/// **Work is plain to see** (the owner, 13 November 2026, of the Mac's sidebar: "the agent icon should animate more to
/// make it more obvious that is working", and of the phone: "Yes, iPhone too"): the motion is the Mac's, value for
/// value (`GlyphLayerView.move`), and it is the one sign of work now that work has no dot. Until that day the figure
/// only grew by 6 % and back, 1.3 seconds each way.
final class BreathingMarkView: UIView {
    private let figure = CALayer(), gradient = CAGradientLayer(), outline = CAShapeLayer(), orbit = CALayer(), core = CAShapeLayer()
    private var look: GlyphLook?
    /// The kind, the colour and the size that the layers show now.
    private var drawn: (kind: GlyphKind, tone: Int, size: CGSize)?
    private var breathing = true
    /// What to tell once the layers are back at rest, while they go there.
    private var rested: (() -> Void)?
    /// The tween into a swing and back to rest at the end of work.
    private static let tween: CFTimeInterval = 0.25

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        layer.addSublayer(figure)
        figure.addSublayer(gradient)
        gradient.mask = outline
        figure.addSublayer(orbit)
        orbit.addSublayer(core)
        gradient.startPoint = .zero
        gradient.endPoint = CGPoint(x: 1, y: 1)
    }

    required init?(coder: NSCoder) { nil }

    func show(_ look: GlyphLook, breathing: Bool, eased: Bool, rested: @escaping () -> Void) {
        self.look = look
        if breathing != self.breathing {
            self.breathing = breathing
            if !breathing { settle(eased: eased, then: rested) } else if drawn != nil { breathe() }
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let look, bounds.width > 0, bounds.height > 0 else { return }
        if let drawn, drawn.kind == look.kind, drawn.tone == look.tone, drawn.size == bounds.size { return }
        drawn = (look.kind, look.tone, bounds.size)
        let scale = max(traitCollection.displayScale, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The figure moves, so it takes its place by its bounds and position, never by a frame.
        figure.bounds = bounds
        figure.position = CGPoint(x: bounds.midX, y: bounds.midY)
        orbit.bounds = bounds
        orbit.position = CGPoint(x: bounds.midX, y: bounds.midY)
        for part in [gradient, outline] as [CALayer] { part.frame = bounds }
        // The inner mark changes its size about its own centre, which is not the mark's for a moon, a drop or a triangle.
        let anchor = look.kind.coreAnchor
        core.bounds = bounds
        core.anchorPoint = CGPoint(x: anchor.x, y: anchor.y)
        core.position = CGPoint(x: bounds.width * anchor.x, y: bounds.height * anchor.y)
        for part in [gradient, outline, core] as [CALayer] { part.contentsScale = scale }
        gradient.colors = [UIColor(look.light).cgColor, UIColor(look.deep).cgColor]
        outline.path = GlyphOutline(kind: look.kind).path(in: bounds).cgPath
        core.path = GlyphCore(kind: look.kind).path(in: bounds).cgPath
        core.fillColor = look.kind == .moon ? UIColor(look.light).cgColor
            : UIColor.white.withAlphaComponent(GlyphLook.coreOpacity).cgColor
        CATransaction.commit()
        // New paths or a new kind: its own motion, from rest.
        if breathing { breathe(again: true) }
    }

    /// A layer that left the window lost its motion.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, breathing, drawn != nil { breathe() }
    }

    /// **The motion of each kind, without an end, and from the mark at rest**, so work starts without a jump: a turn
    /// starts at 0°, a breath at its full size, and a swing with rest in its middle first reaches its end in a tween.
    /// Every kind breathes, so every mark at work has one common beat. Each mark keeps its own pace, within 10% of
    /// its kind's (`GlyphLook.phase`), so two marks at work do not move in step. The Mac's values (`GlyphLayerView.move`).
    private func breathe(again: Bool = false) {
        rested = nil
        // Every kind's figure breathes: while that breath runs, a second call leaves the motion as it is.
        guard let look, again || figure.animation(forKey: Self.breath) == nil else { return }
        for part in [figure, orbit, core] as [CALayer] { part.removeAllAnimations() }
        let pace = 0.9 + 0.2 * look.phase / (2 * .pi), now = CACurrentMediaTime()
        switch look.kind.motion {
        case .turn:
            turn(figure, to: 2 * .pi, seconds: 6 * pace, now)
            swing(figure, "transform.scale", 0.86, 1, rest: 1, seconds: 0.95 * pace, now)
            turn(orbit, to: -2 * .pi, seconds: 3 * pace, now)
            swing(core, "transform.scale", 0.75, 1.25, rest: 1, seconds: 0.8 * pace, now)
        case .breathe:
            swing(figure, "transform.scale", 0.8, 1, rest: 1, seconds: 0.85 * pace, now)
            if look.kind == .drop { swing(core, "transform.scale", 0.6, 1.4, rest: 1, seconds: 0.7 * pace, now) }
            else { turn(orbit, to: 2 * .pi, seconds: 2.2 * pace, now) }
        case .rock:
            swing(figure, "transform.rotation.z", -0.3, 0.3, rest: 0, seconds: 0.95 * pace, now)
            swing(figure, "transform.scale", 0.88, 1, rest: 1, seconds: 0.95 * pace, now)
            swing(core, "transform.scale", 0.7, 1.3, rest: 1, seconds: 0.7 * pace, now)
        }
    }

    /// The key of the figure's breath, which every kind has (`swing` keys a motion by its key path).
    private static let breath = "transform.scale"

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

    /// **Work ends on the mark at rest, not with a snap**: each part goes back from where it is shown now to rest in
    /// 250 ms, easing out, and only then does the mark at rest take the layers' place.
    private func settle(eased: Bool, then rested: @escaping () -> Void) {
        self.rested = rested
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.breathing, let rested = self.rested else { return }
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
    /// Whether the mark breathes while its agent works: where it stands for the agent itself (a row of Chats), and not
    /// where a list names it.
    var moves = true
    /// What the badge's ring is cut from: the page under the mark.
    var ring: Color = Brand.canvas
    @Environment(\.markTeam) private var team
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .headline) private var scale: CGFloat = 1
    /// It grows with the text, but only by half: past that the row has no width left for the words.
    private var size: CGFloat { base * min(scale, 1.5) }

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
