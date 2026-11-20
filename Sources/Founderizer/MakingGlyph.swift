import AppKit
import FleetMark
import SwiftUI

// **The making of an agent's glyph while the agent is added and set up** (the owner, 20 November 2026, with a picture
// of an agent's "Setting up <agent>": "can we maybe generate a super nice animation on its icon? like creating it or
// something very clean and enjoyable to see while we wait", then "much richer and longer! it takes like 10-15 seconds
// to create the agent I think?", and "Yes, build it" to the full sequence of the moving mock-up in
// `founderizer-plans/agent-icon-making-2026-11-20/mock.html`, the reference for every time and size).
//
// On "Adding <agent>" and "Setting up <agent>" the glyph draws itself as a designer would: a point of light, a dotted
// circle and hairlines, the construction lines of its own shape (`GlyphSketch`), the point drawing the outline over
// them, the colour growing from the middle, the point becoming the inner mark, one jump with a ring and six rays.
// That plays one time, in about 11 s. Then, until the chat opens, the light of the moving words passes over it too, a
// short light goes round its outline, and a soft ring goes out every 5.6 s. The chat opens the moment it is ready,
// also in the middle of the sequence. Under Reduce Motion the glyph stands still, as it did (`AgentGlyph`).
//
// **One clock for one agent** (`GlyphMakingClock`), which runs while a glyph of its making is on the screen: "Adding"
// and "Setting up" are other views on other pages, a page draws again many times, and the install and the sign-in
// come between them with the provider's icon for minutes, but the sequence goes on from where it stood, and each part
// plays one time. A glyph that shows after 11 s of it shows part 6 at once. Only the press on Add agent starts it
// again. The chat's own "Setting up" makes the glyph only for an agent that this Mac adds, or to go on with a making
// that shows as it comes: the chat of an agent whose session starts again after a release shows its glyph still
// (`AgentGlyph.begins`).
//
// Core Animation moves it, as every motion that goes on ("Show motion that continues" in UI-PATTERNS.md): the layers
// are given their whole timeline once, from the clock, and the app draws nothing for a frame.

/// The glyph of an agent that makes itself, at its place on a setup step: the layout keeps the glyph's own square, and
/// the motion draws around it, as far as its ring goes (86 points from the middle at the pages' 96,
/// `GlyphSize.making`).
struct MakingGlyph: View {
    let name: String
    let kind: GlyphKind
    let light: Color
    let deep: Color
    /// The step's moving words, whose light passes over the glyph too.
    let words: String
    let size: CGFloat

    var body: some View {
        MakingLayers(name: name, kind: kind, light: NSColor(light), deep: NSColor(deep), words: words)
            .frame(width: size * 2, height: size * 2)
            .padding(-size / 2)
            .allowsHitTesting(false)
    }
}

/// **How far the making of each agent has gone, for this run of the app: a clock that runs only while a glyph of it is
/// in a window.** The views of "Adding" and "Setting up" are others for each page and each step, and each of them goes
/// on from here; the install's and the sign-in's pages, which show the provider's icon, hold it where it stands, so he
/// sees the rest of the making on the "Setting up" that comes after them, and no part two times.
@MainActor enum GlyphMakingClock {
    private struct Making {
        /// The seconds that it showed before its glyph's latest showing.
        var shown: CFTimeInterval = 0
        /// When its glyph's latest showing began; nil while none is in a window.
        var since: CFTimeInterval?
        /// Its views in a window.
        var views = 0
    }
    private static var makings: [String: Making] = [:]
    private static let live = NSHashTable<GlyphMakingView>.weakObjects()

    /// A glyph of the agent's making is in a window now: a page that comes in its place goes on with it.
    static func showing(_ name: String) -> Bool { (makings[name]?.views ?? 0) > 0 }

    /// **The moment that its making would have begun had it shown all the time**, in Core Animation's time: the start
    /// of each view's timeline. A making that has not shown yet begins now.
    static func start(_ name: String) -> CFTimeInterval {
        let making = makings[name] ?? Making()
        return (making.since ?? CACurrentMediaTime()) - making.shown
    }

    /// A glyph of the agent's making comes into a window: the clock goes on from where it stood.
    static func shows(_ view: GlyphMakingView, _ name: String) {
        var making = makings[name] ?? Making()
        if making.views == 0 { making.since = CACurrentMediaTime() }
        making.views += 1
        makings[name] = making
        live.add(view)
    }

    /// A glyph of the agent's making leaves its window: with none left, the clock stops where it stands.
    static func hides(_ name: String) {
        guard var making = makings[name], making.views > 0 else { return }
        making.views -= 1
        if making.views == 0, let since = making.since {
            making.shown += CACurrentMediaTime() - since
            making.since = nil
        }
        makings[name] = making
    }

    /// **A new making begins now**: his press on Add agent, also for a name that an agent had before (one removed and
    /// added again). The glyph that shows it starts again from its first part.
    static func restart(_ name: String) {
        var making = makings[name] ?? Making()
        making.shown = 0
        making.since = making.views > 0 ? CACurrentMediaTime() : nil
        makings[name] = making
        for view in live.allObjects where view.name == name { view.play() }
    }
}

private struct MakingLayers: NSViewRepresentable {
    let name: String
    let kind: GlyphKind
    let light: NSColor
    let deep: NSColor
    let words: String

    func makeNSView(context: Context) -> GlyphMakingView { GlyphMakingView() }
    func updateNSView(_ view: GlyphMakingView, context: Context) {
        view.show(name: name, kind: kind, light: light, deep: deep, words: words)
    }
}

// MARK: - The sizes

/// The sizes of the making in units of the glyph's square (100 is its side), as the mock-up draws them.
private enum Units {
    static let point: CGFloat = 4.6, halo: CGFloat = 10.5, haloOpacity = 0.22
    static let circle: CGFloat = 50, circleLine: CGFloat = 1.4, circleDots: [CGFloat] = [1.5, 6.354]
    static let hairline: CGFloat = 64, hairlineLine: CGFloat = 1.2
    static let sketchLine: CGFloat = 1.4, dot: CGFloat = 1.8
    static let pen: CGFloat = 3.4, bright = 0.1
    static let spark: CGFloat = 3.2, lastSpark: CGFloat = 4.6
    static let ring: CGFloat = 2, rays: (from: CGFloat, to: CGFloat, out: CGFloat, line: CGFloat) = (54, 60, 14, 2.2)
    static let comet: CGFloat = 2.6
}

/// The curves of the mock-up, as CSS's `cubic-bezier`.
private struct Curve {
    let x1: Double, y1: Double, x2: Double, y2: Double

    static let linear = Curve(x1: 0, y1: 0, x2: 1, y2: 1)
    /// The pen along the outline.
    static let pen = Curve(x1: 0.3, y1: 0, x2: 0.7, y2: 1)
    /// In and out: a line that draws itself, the point's way to the outline and back.
    static let inOut = Curve(x1: 0.45, y1: 0, x2: 0.25, y2: 1)
    /// Out: a pop, the circle that opens, the jump and what goes out.
    static let out = Curve(x1: 0.2, y1: 0.8, x2: 0.2, y2: 1)
    /// The colour that grows past its edge and back.
    static let grows = Curve(x1: 0.3, y1: 1.35, x2: 0.5, y2: 1)

    var isLinear: Bool { x1 == y1 && x2 == y2 }

    private func at(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
    }

    /// The eased share at a share of the time.
    func callAsFunction(_ x: Double) -> Double {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        var low = 0.0, high = 1.0, t = x
        for _ in 0..<60 {
            if at(t, x1, x2) < x { low = t } else { high = t }
            t = (low + high) / 2
        }
        return at(t, y1, y2)
    }

    /// The share of the time at which the eased share first reaches `y` (the curve rises the whole way).
    func time(of y: Double) -> Double {
        var low = 0.0, high = 1.0
        for _ in 0..<60 {
            let middle = (low + high) / 2
            if self(middle) < y { low = middle } else { high = middle }
        }
        return (low + high) / 2
    }
}

// MARK: - Tracks

/// A value that a layer's property can take, and the mix of two of them.
private protocol Keyed {
    static func mix(_ one: Self, _ two: Self, _ t: Double) -> Self
    var boxed: Any { get }
}

extension Double: Keyed {
    static func mix(_ one: Double, _ two: Double, _ t: Double) -> Double { one + (two - one) * t }
    var boxed: Any { NSNumber(value: self) }
}

extension CGPoint: Keyed {
    static func mix(_ one: CGPoint, _ two: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: one.x + (two.x - one.x) * t, y: one.y + (two.y - one.y) * t)
    }
    var boxed: Any { NSValue(point: self) }
}

/// A colour by its sRGB parts, so that two of them mix.
private struct Paint: Keyed {
    let red: Double, green: Double, blue: Double, alpha: Double

    init(_ color: NSColor) {
        let rgb = color.usingColorSpace(.sRGB) ?? .white
        red = rgb.redComponent; green = rgb.greenComponent; blue = rgb.blueComponent; alpha = rgb.alphaComponent
    }
    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
    static func white(_ alpha: Double) -> Paint { Paint(red: 1, green: 1, blue: 1, alpha: alpha) }
    static func mix(_ one: Paint, _ two: Paint, _ t: Double) -> Paint {
        Paint(red: .mix(one.red, two.red, t), green: .mix(one.green, two.green, t), blue: .mix(one.blue, two.blue, t),
              alpha: .mix(one.alpha, two.alpha, t))
    }
    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var boxed: Any { cgColor }

    /// The same hue with less colour: the point of light (`tip`, the mock-up's #F8E8CC on sand) and the newest part of
    /// the drawn line (`hot`, #FFF4DC on sand), so each hue has its own light and a grey glyph a white one.
    func lighter(saturation: Double, brightness: Double) -> Paint {
        let most = max(red, green, blue), least = min(red, green, blue), spread = most - least
        // Its hue, in sixths of the circle, and its saturation, as HSB has them.
        var hue = 0.0
        if spread > 0 {
            if most == red { hue = (green - blue) / spread } else if most == green { hue = 2 + (blue - red) / spread }
            else { hue = 4 + (red - green) / spread }
        }
        hue = (hue + 6).truncatingRemainder(dividingBy: 6)
        let colour = (most > 0 ? spread / most : 0) * saturation, value = brightness
        let low = value * (1 - colour), part = hue - hue.rounded(.down)
        let falling = value * (1 - colour * part), rising = value * (1 - colour * (1 - part))
        switch Int(hue) {
        case 0: return Paint(red: value, green: rising, blue: low, alpha: 1)
        case 1: return Paint(red: falling, green: value, blue: low, alpha: 1)
        case 2: return Paint(red: low, green: value, blue: rising, alpha: 1)
        case 3: return Paint(red: low, green: falling, blue: value, alpha: 1)
        case 4: return Paint(red: rising, green: low, blue: value, alpha: 1)
        default: return Paint(red: value, green: low, blue: falling, alpha: 1)
        }
    }
}

/// **One property of one layer over the whole sequence**: it holds its value between its moves, and each move eases
/// through its values (the mock-up's keyframes) over its time. It becomes one keyframe animation from the agent's
/// clock, so a glyph that shows in the middle of the sequence is at its moment of it at once.
private struct Track<Value: Keyed> {
    private(set) var keys: [(time: Double, value: Value)] = []
    private var rest: Value

    /// The value before the first move.
    init(_ value: Value) { rest = value }

    var last: Value { keys.last?.value ?? rest }

    /// From `at`, over `takes`: through `values` at their shares of the move (the first at 0, the last at 1), on the
    /// curve of the whole move, as an animation of the web eases its keyframes.
    mutating func move(_ at: Double, _ takes: Double, _ values: [(Double, Value)], _ curve: Curve = .linear) {
        sample(at, takes, curve, keys: curve.isLinear ? values.map(\.0) : nil) { share in
            // The values on each side of the eased share, and past the ends the first or the last two (an overshoot).
            var index = 0
            while index < values.count - 2 && share > values[index + 1].0 { index += 1 }
            let one = values[index], two = values[min(index + 1, values.count - 1)]
            let gap = two.0 - one.0
            return gap > 0 ? Value.mix(one.1, two.1, (share - one.0) / gap) : two.1
        }
    }

    /// From `at`, over `takes`: the value of a function of the eased share, at `keys` (shares of the time) or 120
    /// times a second. Until `at` the value before it holds.
    mutating func sample(_ at: Double, _ takes: Double, _ curve: Curve = .linear, keys shares: [Double]? = nil,
                         _ value: (Double) -> Value) {
        keys.append((at, keys.last?.value ?? rest))
        let steps = max(8, Int((takes * 120).rounded(.up)))
        for share in shares ?? (0...steps).map({ Double($0) / Double(steps) }) {
            keys.append((at + takes * share, value(curve(share))))
        }
    }

    /// Its animation for the clock's start `began`, or nil once it is over at `now` (the model value is its last then).
    func animation(_ keyPath: String, on layer: CALayer, began: CFTimeInterval, now: CFTimeInterval) -> CAAnimation? {
        guard let first = keys.first?.time, let end = keys.last?.time, end > first, began + end > now else {
            return nil
        }
        // A jump is two keys at one moment; Core Animation can take the second one for the time before the motion,
        // so each key is a tenth of a millisecond after the one before it at least.
        var times = keys.map(\.time)
        for index in times.indices.dropFirst() where times[index] < times[index - 1] + 0.0001 {
            times[index] = times[index - 1] + 0.0001
        }
        let last = times[times.count - 1]
        let motion = CAKeyframeAnimation(keyPath: keyPath)
        motion.values = keys.map(\.value.boxed)
        motion.keyTimes = times.map { NSNumber(value: ($0 - first) / (last - first)) }
        motion.duration = last - first
        motion.beginTime = layer.convertTime(began + first, from: nil)
        motion.calculationMode = .linear
        // Its first value before it starts, its model value (its last) after it ends. It stays on the layer until the
        // next play: Core Animation drops a removable motion of a layer that is not in a window yet when a transaction
        // ends, and a layer can be drawn before its view is in the window.
        motion.fillMode = .backwards
        motion.isRemovedOnCompletion = false
        return motion
    }
}

/// What the layers play: a layer, a property, its value at rest, and its motion from the clock.
private struct Play {
    let layer: CALayer
    let keyPath: String
    let rest: Any
    let motion: (_ began: CFTimeInterval, _ now: CFTimeInterval) -> CAAnimation?

    init<Value: Keyed>(_ layer: CALayer, _ keyPath: String, _ track: Track<Value>) {
        self.layer = layer
        self.keyPath = keyPath
        rest = track.last.boxed
        motion = { began, now in track.animation(keyPath, on: layer, began: began, now: now) }
    }

    /// A motion without an end, from a time of the clock.
    init(_ layer: CALayer, _ keyPath: String, rest: Any, from at: Double, _ make: @escaping () -> CAAnimation) {
        self.layer = layer
        self.keyPath = keyPath
        self.rest = rest
        motion = { began, _ in
            let motion = make()
            motion.beginTime = layer.convertTime(began + at, from: nil)
            motion.repeatCount = .infinity
            motion.isRemovedOnCompletion = false
            return motion
        }
    }

    var key: String { "making." + keyPath }
}

// MARK: - The layers

/// The layers of a glyph that makes itself, on a square twice the glyph's side with the glyph in its middle.
final class GlyphMakingView: NSView {
    private(set) var name = ""
    private var kind: GlyphKind?
    private var light = NSColor.white, deep = NSColor.gray
    private var words = ""
    /// What the layers are drawn for: its kind, its colours and its size.
    private var drawn: (kind: GlyphKind, light: NSColor, deep: NSColor, size: CGSize)?
    private let stage = CALayer()
    private var plays: [Play] = []
    /// The light of the moving words: its band, the words' width, and the width that its pass was made for.
    private let band = CAGradientLayer()
    private var wordsWidth: CGFloat = 0
    private var swept: CGFloat?
    /// The clock counts this view as one in a window.
    private var counted = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(stage)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }

    /// A view that goes with its window, with no move out of it, leaves the clock too.
    isolated deinit {
        if counted { GlyphMakingClock.hides(name) }
    }

    override var isFlipped: Bool { true }
    /// A click goes to what is under the glyph.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(name: String, kind: GlyphKind, light: NSColor, deep: NSColor, words: String) {
        if name != self.name {
            // Another agent in the same place goes on from its own clock.
            if counted { GlyphMakingClock.hides(self.name); GlyphMakingClock.shows(self, name) }
            self.name = name
            play()
        }
        if words != self.words {
            self.words = words
            // The words of the step's moving title (`SetupTitle`): its size and weight, digits of one width.
            let font = NSFont.monospacedDigitSystemFont(ofSize: SetupMetrics.title, weight: .semibold)
            wordsWidth = ceil((words as NSString).size(withAttributes: [.font: font]).width)
            needsLayout = true
        }
        if kind != self.kind || light != self.light || deep != self.deep {
            self.kind = kind
            self.light = light
            self.deep = deep
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        guard let kind, bounds.width > 0, bounds.height > 0 else { return }
        if let drawn, drawn.kind == kind, drawn.light == light, drawn.deep == deep, drawn.size == bounds.size {
            sweep()
            return
        }
        drawn = (kind, light, deep, bounds.size)
        build(kind)
        play()
        sweep()
    }

    /// **The clock runs while the glyph is in a window**, and a layer that left the window lost its motion.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            // A layout that came before the view had its size drew nothing.
            needsLayout = true
        }
        if window != nil, !counted {
            counted = true
            GlyphMakingClock.shows(self, name)
        } else if window == nil, counted {
            counted = false
            GlyphMakingClock.hides(name)
        }
        guard window != nil, drawn != nil else { return }
        play()
        if band.animation(forKey: "sweep") == nil { swept = nil; sweep() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        func set(_ layer: CALayer) {
            layer.contentsScale = scale
            if let mask = layer.mask { set(mask) }
            layer.sublayers?.forEach(set)
        }
        set(stage)
    }

    /// **The whole timeline from the agent's clock**: each property at its value at rest, and its motion from where the
    /// sequence is now. Called again by the clock when a new making of the agent begins.
    func play() {
        guard drawn != nil else { return }
        let began = GlyphMakingClock.start(name), now = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for play in plays {
            play.layer.removeAnimation(forKey: play.key)
            play.layer.setValue(play.rest, forKeyPath: play.keyPath)
            if let motion = play.motion(began, now) { play.layer.add(motion, forKey: play.key) }
        }
        CATransaction.commit()
    }

    /// **The light of the moving words passes over the glyph as it passes over the words** (`ShimmerView`): the same
    /// band, 0.8 of the words' width, the same way and pace, 2.8 s for each pass from half a band right of the words to
    /// half a band left of them, and from the same moment, as the two come with the same step. The words are centred
    /// under the glyph, so the light crosses the glyph's middle as it crosses the words' middle.
    private func sweep() {
        let width = wordsWidth
        guard drawn != nil, width > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        band.bounds = CGRect(x: 0, y: 0, width: 0.8 * width, height: bounds.height)
        band.position = CGPoint(x: bounds.midX, y: bounds.midY)
        // At rest the band stands where a pass ends, off the glyph: a still picture of the layers shows no light.
        band.setValue(-0.9 * width, forKeyPath: "transform.translation.x")
        CATransaction.commit()
        // Its pass goes on while the words are the same, as theirs does.
        if swept == width, band.animation(forKey: "sweep") != nil { return }
        swept = width
        band.removeAnimation(forKey: "sweep")
        let sweep = CABasicAnimation(keyPath: "transform.translation.x")
        sweep.fromValue = 0.9 * width
        sweep.toValue = -0.9 * width
        sweep.duration = 2.8
        sweep.timingFunction = CAMediaTimingFunction(name: .linear)
        sweep.repeatCount = .infinity
        sweep.isRemovedOnCompletion = false
        band.add(sweep, forKey: "sweep")
    }

    // MARK: building

    /// The layers of one kind at one size, with the timeline of each property.
    private func build(_ kind: GlyphKind) {
        stage.sublayers?.forEach { $0.removeFromSuperlayer() }
        plays = []
        let side = bounds.width / 2, u = side / 100, scale = window?.backingScaleFactor ?? 2
        let glyph = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        let c = CGPoint(x: glyph.midX, y: glyph.midY)
        let sketch = GlyphSketch(kind: kind, in: glyph)
        let times = FleetMotion.Making.self
        let lightPaint = Paint(light), tip = lightPaint.lighter(saturation: 0.5, brightness: 0.97)
        let hot = lightPaint.lighter(saturation: 0.38, brightness: 1)
        let core = kind == .moon ? lightPaint : Paint.white(GlyphLook.coreOpacity)
        // The time at which the pen has drawn a share of the way.
        let pen = { (share: CGFloat) in times.pen.at + times.pen.takes * Curve.pen.time(of: Double(share)) }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.frame = bounds

        func shape(_ path: Path?, line: CGFloat = 0, stroke: Paint? = nil, fill: Paint? = nil) -> CAShapeLayer {
            let layer = CAShapeLayer()
            layer.frame = bounds
            layer.contentsScale = scale
            layer.path = path?.cgPath
            layer.lineWidth = line
            layer.strokeColor = stroke?.cgColor
            layer.fillColor = fill?.cgColor
            return layer
        }
        /// A disc of `radius` that scales about its middle at `at`.
        func disc(_ radius: CGFloat, at point: CGPoint, _ paint: Paint) -> CAShapeLayer {
            let layer = CAShapeLayer()
            layer.bounds = CGRect(x: 0, y: 0, width: 2 * radius, height: 2 * radius)
            layer.position = point
            layer.contentsScale = scale
            layer.path = CGPath(ellipseIn: layer.bounds, transform: nil)
            layer.fillColor = paint.cgColor
            return layer
        }
        func container(_ parent: CALayer) -> CALayer {
            let layer = CALayer()
            layer.frame = bounds
            parent.addSublayer(layer)
            return layer
        }
        func fades(_ layer: CALayer, at: (at: Double, takes: Double)) {
            var opacity = Track(1.0)
            opacity.move(at.at, at.takes, [(0, 1), (1, 0)])
            plays.append(Play(layer, "opacity", opacity))
        }
        /// Each the colour of the glyph: its gradient from the light step at the top left to the deep step at the
        /// bottom right of its square, as the glyph at rest (`AgentGlyph.figure`).
        func colour(_ mask: CALayer) -> CAGradientLayer {
            let gradient = CAGradientLayer()
            gradient.frame = bounds
            gradient.contentsScale = scale
            gradient.colors = [light.cgColor, deep.cgColor]
            gradient.startPoint = CGPoint(x: glyph.minX / bounds.width, y: glyph.minY / bounds.height)
            gradient.endPoint = CGPoint(x: glyph.maxX / bounds.width, y: glyph.maxY / bounds.height)
            gradient.mask = mask
            return gradient
        }

        // Part 1 and 2: the frame of lines and the sketch, which go together at the end.
        let scaffold = container(stage)
        var scaffoldIn = Track(0.0)
        scaffoldIn.move(times.frame.at, times.frame.takes, [(0, 0), (1, 1)])
        plays.append(Play(scaffold, "opacity", scaffoldIn))

        let turn = container(scaffold)
        var turning = Track(-30.0 * .pi / 180)
        turning.move(times.turns.at, times.turns.takes, [(0, -30.0 * .pi / 180), (1, 70.0 * .pi / 180)])
        plays.append(Play(turn, "transform.rotation.z", turning))
        let round50 = Path(ellipseIn: CGRect(x: c.x - Units.circle * u, y: c.y - Units.circle * u,
                                             width: 2 * Units.circle * u, height: 2 * Units.circle * u))
        let dotted = shape(round50, line: Units.circleLine * u, stroke: .white(0.32))
        dotted.lineCap = .round
        dotted.lineDashPattern = Units.circleDots.map { NSNumber(value: Double($0 * u)) }
        turn.addSublayer(dotted)
        var opens = Track(0.0)
        opens.move(times.circle.at, times.circle.takes, [(0, 0), (1, 1)], .out)
        plays.append(Play(dotted, "transform.scale", opens))
        fades(dotted, at: times.frameGoes)

        let ways = [CGVector(dx: 1, dy: 0), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: 1), CGVector(dx: 0, dy: -1)]
        for (index, way) in ways.enumerated() {
            var line = Path()
            line.move(to: c)
            line.addLine(to: CGPoint(x: c.x + way.dx * Units.hairline * u, y: c.y + way.dy * Units.hairline * u))
            let hairline = shape(line, line: Units.hairlineLine * u, stroke: .white(0.2))
            scaffold.addSublayer(hairline)
            var draws = Track(0.0)
            draws.move(times.hairlines.at + Double(index) * times.hairlines.apart, times.hairlines.takes,
                       [(0, 0), (1, 1)], .out)
            plays.append(Play(hairline, "strokeEnd", draws))
            fades(hairline, at: times.frameGoes)
        }

        // The construction lines, one after the other in their time, each with its dots, and the last one.
        let count = Double(sketch.lines.count)
        let apart = (times.lines.to - times.lines.from - times.lines.overlap) / count
        let takes = apart + times.lines.overlap
        // A line goes once the pen is through most of the part that it builds.
        let leaves = { (part: ClosedRange<CGFloat>) in
            (at: pen(part.lowerBound + CGFloat(times.lineGoes.through) * (part.upperBound - part.lowerBound)),
             takes: times.lineGoes.takes)
        }
        let lines = sketch.lines.enumerated().map { index, line in
            (line: line, at: times.lines.from + Double(index) * apart, takes: takes,
             goes: line.builds.map(leaves) ?? times.frameGoes)
        } + [(line: sketch.last, at: times.lastLine.at, takes: times.lastLine.takes, goes: times.frameGoes)]
        for item in lines {
            let drawnLine = shape(item.line.path, line: Units.sketchLine * u, stroke: .white(0.32))
            scaffold.addSublayer(drawnLine)
            var draws = Track(0.0)
            draws.move(item.at, item.takes, [(0, 0), (1, 1)], .inOut)
            plays.append(Play(drawnLine, "strokeEnd", draws))
            fades(drawnLine, at: item.goes)
            for point in item.line.dots {
                let dot = disc(Units.dot * u, at: point, .white(0.6))
                scaffold.addSublayer(dot)
                var pops = Track(0.0)
                pops.move(item.at - times.dot.before, times.dot.takes, [(0, 0), (0.6, 1.6), (1, 1)], .out)
                plays.append(Play(dot, "transform.scale", pops))
                fades(dot, at: item.goes)
            }
        }

        // Part 5's ring, under the glyph: once at the jump, then softly every 5.6 s in part 6.
        let ring = shape(round50, line: Units.ring * u, stroke: lightPaint)
        stage.addSublayer(ring)
        var ringScale = Track(1.0), ringOpacity = Track(0.0)
        ringScale.move(times.ring.at, times.ring.takes, [(0, 1), (1, 1.75)], .out)
        ringOpacity.move(times.ring.at, times.ring.takes, [(0, 0.6), (1, 0)], .out)
        plays.append(Play(ring, "transform.scale", ringScale))
        plays.append(Play(ring, "opacity", ringOpacity))
        let pulse = container(stage)
        pulse.addSublayer(shape(round50, line: Units.ring * u, stroke: lightPaint))
        pulse.opacity = 0
        for (keyPath, values) in [("transform.scale", [1, 1.03, 1.65, 1.65]), ("opacity", [0, 0.4, 0, 0])] {
            plays.append(Play(pulse, keyPath, rest: keyPath == "opacity" ? 0 : 1, from: times.pulse.at) {
                let soft = CAKeyframeAnimation(keyPath: keyPath)
                soft.values = values.map { NSNumber(value: $0) }
                soft.keyTimes = [0, 0.03, 0.3, 1]
                soft.duration = times.pulse.every
                return soft
            })
        }

        // The glyph: its colour, the drawn line, the sparks and the point, which jump together.
        let body = container(stage)
        var jump = Track(1.0)
        jump.move(times.jump.at, times.jump.takes, [(0, 1), (0.4, 1.09), (1, 1)], .out)
        plays.append(Play(body, "transform.scale", jump))

        let fill = container(body)
        fill.addSublayer(colour(shape(GlyphOutline(kind: kind).path(in: glyph), fill: .white(1))))
        var grows = Track(0.1), shows = Track(0.0)
        grows.move(times.colour.at, times.colour.takes, [(0, 0.1), (1, 1)], .grows)
        shows.move(times.colour.at, times.colour.takes, [(0, 0), (0.3, 1), (1, 1)], .grows)
        plays.append(Play(fill, "transform.scale", grows))
        plays.append(Play(fill, "opacity", shows))

        let drawnLine = container(body)
        let stroke = shape(sketch.way, line: Units.pen * u, stroke: .white(1))
        stroke.lineCap = .round
        stroke.lineJoin = .round
        drawnLine.addSublayer(colour(stroke))
        var draws = Track(0.0), drawnShows = Track(0.0)
        draws.move(times.pen.at, times.pen.takes, [(0, 0), (1, 1)], .pen)
        drawnShows.move(times.drawn.at, times.drawn.takes, [(0, 1), (0.875, 1), (1, 0)])
        plays.append(Play(stroke, "strokeEnd", draws))
        plays.append(Play(drawnLine, "opacity", drawnShows))

        // The newest tenth of the line, bright.
        let bright = shape(sketch.way, line: Units.pen * u, stroke: hot)
        bright.lineCap = .round
        bright.lineJoin = .round
        body.addSublayer(bright)
        var brightEnd = Track(0.0), brightStart = Track(0.0), brightShows = Track(0.0)
        brightEnd.move(times.pen.at, times.pen.takes, [(0, 0), (1, 1)], .pen)
        brightStart.sample(times.pen.at, times.pen.takes, .pen) { max(0, $0 - Units.bright) }
        brightShows.move(times.bright.at, times.bright.takes, [(0, 0), (0.06, 0.95), (0.93, 0.95), (1, 0)])
        plays.append(Play(bright, "strokeEnd", brightEnd))
        plays.append(Play(bright, "strokeStart", brightStart))
        plays.append(Play(bright, "opacity", brightShows))

        // A spark at each joint as the pen passes it; the last one, where the outline closes, larger.
        for (index, joint) in sketch.joints.enumerated() {
            let last = index == sketch.joints.count - 1
            let spark = disc((last ? Units.lastSpark : Units.spark) * u, at: joint.point, hot)
            body.addSublayer(spark)
            let at = pen(joint.at) - times.spark.before, takes = last ? times.spark.last : times.spark.takes
            var sparkScale = Track(0.0), sparkOpacity = Track(0.0)
            sparkScale.move(at, takes, [(0, 0), (0.3, 1.5), (1, 0.3)])
            sparkOpacity.move(at, takes, [(0, 0), (0.3, 1), (1, 0)])
            plays.append(Play(spark, "transform.scale", sparkScale))
            plays.append(Play(spark, "opacity", sparkOpacity))
        }

        // The inner mark, at its place: a round one is the point itself, grown; any other shape takes the point's place
        // as the point goes.
        let round = [GlyphKind.clover, .flower, .squircle, .triangle, .drop].contains(kind)
        let coreBox = GlyphCore(kind: kind).path(in: glyph).boundingRect
        let grown = max(coreBox.width, coreBox.height) / 2 / (Units.point * u)
        if !round {
            let mark = shape(GlyphCore(kind: kind).path(in: glyph), fill: core)
            mark.anchorPoint = CGPoint(x: sketch.end.x / bounds.width, y: sketch.end.y / bounds.height)
            mark.position = sketch.end
            body.addSublayer(mark)
            var markScale = Track(1 / grown), markOpacity = Track(0.0), markPaint = Track(tip)
            markScale.move(times.core.at, times.core.takes, [(0, 1 / grown), (0.65, 1.135), (1, 1)], .out)
            markOpacity.move(times.core.at, times.core.takes * 0.4, [(0, 0), (1, 1)])
            markPaint.move(times.core.at, times.core.takes, [(0, tip), (1, core)], .out)
            plays.append(Play(mark, "transform.scale", markScale))
            plays.append(Play(mark, "opacity", markOpacity))
            plays.append(Play(mark, "fillColor", markPaint))
        }

        // The point: from the middle to the outline's start, round the outline, and to the inner mark's place.
        let point = CALayer()
        point.bounds = .zero
        body.addSublayer(point)
        var goes = Track(c)
        goes.move(times.toOutline.at, times.toOutline.takes, [(0, c), (1, sketch.start)], .inOut)
        goes.sample(times.pen.at, times.pen.takes, .pen) { sketch.point(at: CGFloat($0)) }
        goes.move(times.back.at, times.back.takes, [(0, sketch.start), (1, sketch.end)], .inOut)
        plays.append(Play(point, "position", goes))

        let halo = disc(Units.halo * u, at: .zero, tip)
        point.addSublayer(halo)
        var haloOpacity = Track(0.0), haloScale = Track(1.0)
        haloOpacity.move(times.halo.at, times.halo.takes, [(0, 0), (1, Units.haloOpacity)])
        haloOpacity.move(times.haloGoes.at, times.haloGoes.takes, [(0, Units.haloOpacity), (1, 0)])
        haloScale.move(times.swell.at, times.swell.takes, [(0, 1), (0.5, 1.9), (1, 1)])
        plays.append(Play(halo, "opacity", haloOpacity))
        plays.append(Play(halo, "transform.scale", haloScale))

        let dot = disc(Units.point * u, at: .zero, tip)
        point.addSublayer(dot)
        var dotScale = Track(0.0)
        dotScale.move(times.point.at, times.point.takes, [(0, 0), (0.6, 1.4), (1, 1)], .out)
        dotScale.move(times.core.at, times.core.takes, [(0, 1), (0.65, 1.135 * grown), (1, grown)], .out)
        plays.append(Play(dot, "transform.scale", dotScale))
        if round {
            var dotPaint = Track(tip)
            dotPaint.move(times.core.at, times.core.takes, [(0, tip), (1, core)], .out)
            plays.append(Play(dot, "fillColor", dotPaint))
        } else {
            var dotOpacity = Track(1.0)
            dotOpacity.move(times.core.at, times.core.takes * 0.4, [(0, 1), (1, 0)])
            plays.append(Play(dot, "opacity", dotOpacity))
        }

        // Six short rays that go out with the ring.
        for index in 0..<6 {
            let angle = (-90 + 60 * CGFloat(index)) * .pi / 180, way = CGVector(dx: cos(angle), dy: sin(angle))
            var line = Path()
            line.move(to: CGPoint(x: c.x + way.dx * Units.rays.from * u, y: c.y + way.dy * Units.rays.from * u))
            line.addLine(to: CGPoint(x: c.x + way.dx * Units.rays.to * u, y: c.y + way.dy * Units.rays.to * u))
            let ray = shape(line, line: Units.rays.line * u, stroke: lightPaint)
            ray.lineCap = .round
            stage.addSublayer(ray)
            let at = times.rays.at + Double(index) * times.rays.apart, middle = CGPoint(x: bounds.midX, y: bounds.midY)
            var out = Track(middle), rayOpacity = Track(0.0)
            let away = CGPoint(x: middle.x + way.dx * Units.rays.out * u, y: middle.y + way.dy * Units.rays.out * u)
            out.move(at, times.rays.takes, [(0, middle), (1, away)], .out)
            rayOpacity.move(at, times.rays.takes, [(0, 0), (0.25, 1), (1, 0)], .out)
            plays.append(Play(ray, "position", out))
            plays.append(Play(ray, "opacity", rayOpacity))
        }

        // Part 6: the words' light over the glyph, inside its outline.
        let lit = container(stage)
        lit.mask = shape(GlyphOutline(kind: kind).path(in: glyph), fill: .white(1))
        band.colors = [Paint.white(0).cgColor, Paint.white(0.45).cgColor, Paint.white(0).cgColor]
        band.locations = [0, 0.5, 1]
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        band.contentsScale = scale
        lit.addSublayer(band)
        var litIn = Track(0.0)
        litIn.move(times.light.at, times.light.takes, [(0, 0), (1, 1)])
        plays.append(Play(lit, "opacity", litIn))

        // A short light round the outline: its head at 80%, a tail at 28%, once round each 4.2 s from the clock's
        // start.
        let comet = container(stage)
        for (share, opacity, from) in [(0.16, 0.28, 1.0), (0.06, 0.8, 1.9)] {
            let paint = Paint(red: hot.red, green: hot.green, blue: hot.blue, alpha: opacity)
            let light = shape(sketch.way, line: Units.comet * u, stroke: paint)
            light.lineCap = .round
            let length = Double(sketch.length)
            light.lineDashPattern = [NSNumber(value: length * share), NSNumber(value: length * (1 - share))]
            comet.addSublayer(light)
            plays.append(Play(light, "lineDashPhase", rest: length * from, from: 0) {
                let round = CABasicAnimation(keyPath: "lineDashPhase")
                round.fromValue = length * from
                round.toValue = length * (from - 1)
                round.duration = times.comet.round
                round.timingFunction = CAMediaTimingFunction(name: .linear)
                return round
            })
        }
        var cometIn = Track(0.0)
        cometIn.move(times.comet.at, times.comet.takes, [(0, 0), (1, 1)])
        plays.append(Play(comet, "opacity", cometIn))
        CATransaction.commit()
    }
}
