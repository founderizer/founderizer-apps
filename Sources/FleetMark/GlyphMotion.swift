import SwiftUI

/// **How a glyph moves while its agent works or thinks: a motion of its own for each of the eleven kinds** (the owner,
/// 20 November 2026: "also I want you to design more movement for the "thinking" status of every agent icon, so there
/// is more variety", and "A · Own character" to the moving mock-up of
/// `founderizer-plans/agent-icon-thinking-2026-11-20`, whose function `own` is the reference for every number here).
/// The sparkle twinkles in quarter turns, the clover tumbles, the flower closes and opens, the burst ticks as a gear,
/// the squircle is jelly, the hexagon turns as a nut, the diamond flips with a hop, the triangle jumps onto its next
/// side, the circle's dot runs round, the moon swings as a cradle and the drop bounces.
///
/// A glyph has four parts, one in the other: the **holder**, which moves and squeezes along the screen's axes; the
/// **figure**, which turns with its gradient; the **orbit**, which turns the inner mark about the centre; and the
/// **core**, the inner mark itself, which turns and changes its size about its own place (`GlyphKind.coreAnchor`). Each
/// track is one value of one part over one loop, as the keyframes of an animation of the web: its keys at their shares
/// of the loop, each eased to the next by its curve (linear with none). Turns are in degrees, clockwise on the screen;
/// a lift is in units of the glyph's square (100 is its side), up negative. The Mac app plays the tracks in its own
/// layers (`GlyphLayerView`), each glyph at its own pace (`GlyphLook.phase`), from the glyph at rest.
public struct GlyphMotion: Sendable {
    public enum Part: Sendable, CaseIterable { case holder, figure, orbit, core }
    public enum Channel: Sendable { case turn, scale, scaleX, scaleY, lift }

    public struct Key: Sendable {
        /// The key's share of the loop, from 0 to 1.
        public let at: Double
        public let value: Double
        /// From this key to the next; nil: linear.
        public let curve: GlyphCurve?
    }

    public struct Track: Sendable {
        public let part: Part
        public let channel: Channel
        /// The length of one loop in seconds, at the kind's own pace.
        public let loop: Double
        /// From the first key at 0 to the last at 1.
        public let keys: [Key]

        /// The value at a share of the loop: its keys mixed by their curves.
        public func value(at share: Double) -> Double {
            let share = min(max(share, 0), 1)
            guard let next = keys.firstIndex(where: { $0.at > share }) else { return keys[keys.count - 1].value }
            guard next > 0 else { return keys[0].value }
            let from = keys[next - 1], to = keys[next], gap = to.at - from.at
            let progress = gap > 0 ? (share - from.at) / gap : 1
            return from.value + (to.value - from.value) * (from.curve?(progress) ?? progress)
        }

        /// **The loop as points for an animation that mixes its points in straight lines**: each key, and in each
        /// part with a curve a point for each 120th of a second (at a loop of `seconds`), so a curve that goes a little
        /// too far keeps its shape. Shares of the loop, from 0 to 1.
        public func samples(over seconds: Double) -> [(at: Double, value: Double)] {
            var points: [(at: Double, value: Double)] = []
            for (one, two) in zip(keys, keys.dropFirst()) {
                points.append((one.at, one.value))
                guard let curve = one.curve, two.at > one.at else { continue }
                let count = max(4, Int(((two.at - one.at) * seconds * 120).rounded(.up)))
                for step in 1..<count {
                    let part = Double(step) / Double(count)
                    let value = one.value + (two.value - one.value) * curve(part)
                    points.append((one.at + (two.at - one.at) * part, value))
                }
            }
            if let last = keys.last { points.append((last.at, last.value)) }
            return points
        }

        /// The value of the part at rest: no turn, the whole size, no lift.
        public var rest: Double {
            switch channel {
            case .turn, .lift: 0
            case .scale, .scaleX, .scaleY: 1
            }
        }
    }

    public let tracks: [Track]
    /// The point that the holder squeezes about, and the point that the figure turns about, in the glyph's square.
    public let holderAnchor: UnitPoint
    public let figureAnchor: UnitPoint
}

/// A curve of the web's `cubic-bezier`: the eased share at a share of the time.
public struct GlyphCurve: Sendable, Equatable {
    public let x1: Double, y1: Double, x2: Double, y2: Double

    public init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2
    }

    /// The mock-up's four curves, and the web's `ease-in-out` of a swing that goes and comes back.
    public static let inOut = GlyphCurve(0.45, 0, 0.55, 1)
    public static let over = GlyphCurve(0.3, 1.5, 0.5, 1)
    public static let out = GlyphCurve(0.2, 0.7, 0.3, 1)
    public static let into = GlyphCurve(0.6, 0, 0.9, 0.4)
    public static let swing = GlyphCurve(0.42, 0, 0.58, 1)
    /// The circle's ring: slow at its start point, fast between.
    public static let orbit = GlyphCurve(0.65, 0, 0.35, 1)

    private func at(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
    }

    public func callAsFunction(_ x: Double) -> Double {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        var low = 0.0, high = 1.0, t = x
        for _ in 0..<50 {
            if at(t, x1, x2) < x { low = t } else { high = t }
            t = (low + high) / 2
        }
        return at(t, y1, y2)
    }
}

// MARK: - The eleven motions

private typealias K = GlyphMotion.Key

/// A loop of keys `(share, value, curve)`, with a key at 0 that holds the first value when the first key comes later.
private func track(_ part: GlyphMotion.Part, _ channel: GlyphMotion.Channel, _ loop: Double,
                   _ keys: [(Double, Double, GlyphCurve?)]) -> GlyphMotion.Track {
    var made = keys.map { K(at: $0.0, value: $0.1, curve: $0.2) }
    if let first = made.first, first.at > 0 { made.insert(K(at: 0, value: first.value, curve: nil), at: 0) }
    return GlyphMotion.Track(part: part, channel: channel, loop: loop, keys: made)
}

/// `steps` turns of `degrees` each over `steps` times `step` seconds: each starts at `from` and ends at `to` of its own
/// step (shares of it) on its curve, and the part rests between them. The loop ends a whole number of turns round.
private func steps(_ part: GlyphMotion.Part, _ steps: Int, _ degrees: Double, _ step: Double, from: Double, to: Double,
                   _ curve: GlyphCurve) -> GlyphMotion.Track {
    var keys: [(Double, Double, GlyphCurve?)] = []
    for index in 0..<steps {
        keys.append(((Double(index) + from) / Double(steps), Double(index) * degrees, curve))
        keys.append(((Double(index) + to) / Double(steps), Double(index + 1) * degrees, nil))
    }
    keys.append((1, Double(steps) * degrees, nil))
    return track(part, .turn, Double(steps) * step, keys)
}

/// A squeeze along both axes: two tracks with the same keys, `(share, x, y, curve)`.
private func squeeze(_ loop: Double, _ keys: [(Double, Double, Double, GlyphCurve?)]) -> [GlyphMotion.Track] {
    [track(.holder, .scaleX, loop, keys.map { ($0.0, $0.1, $0.3) }),
     track(.holder, .scaleY, loop, keys.map { ($0.0, $0.2, $0.3) })]
}

extension GlyphKind {
    /// **The turns after which the inner mark looks the same**: four for the stars of the sparkle and the moon and for
    /// the diamond's square, six for the hexagon; one for the other kinds, whose inner mark does not turn. A core that
    /// turns may come back to rest at any of them.
    public var coreSymmetry: Int {
        switch self {
        case .sparkle, .diamond, .moon: 4
        case .hexagon: 6
        case .clover, .flower, .burst, .squircle, .triangle, .circle, .drop: 1
        }
    }

    /// **The motion of this kind while its agent works or thinks** (`GlyphMotion`).
    public var workMotion: GlyphMotion {
        let io = GlyphCurve.inOut, over = GlyphCurve.over, out = GlyphCurve.out, into = GlyphCurve.into
        let centre = UnitPoint.center
        switch self {
        case .sparkle:
            // Twinkle: a quarter turn that goes a little too far, while the glyph grows and the core turns back.
            return GlyphMotion(tracks: [
                steps(.figure, 4, 90, 1.2, from: 0, to: 0.4, over),
                track(.holder, .scale, 1.2, [(0, 1, nil), (0.2, 1.2, nil), (0.4, 1, nil), (1, 1, nil)]),
                steps(.core, 4, -180, 1.2, from: 0, to: 0.5, io),
                track(.core, .scale, 1.2, [(0, 1, nil), (0.25, 1.7, nil), (0.5, 1, nil), (1, 1, nil)]),
            ], holderAnchor: centre, figureAnchor: centre)
        case .clover:
            // Tumble: a quarter turn with a squeeze, and the core swells after it.
            return GlyphMotion(tracks: [
                steps(.figure, 4, 90, 1.4, from: 0.1, to: 0.5, over),
                track(.holder, .scale, 1.4, [(0, 0.9, nil), (0.25, 1.08, nil), (0.5, 1, nil), (0.88, 1, nil),
                                             (1, 0.9, nil)]),
                track(.core, .scale, 1.4, [(0, 1, nil), (0.45, 1, nil), (0.58, 1.6, nil), (0.78, 1, nil), (1, 1, nil)]),
            ], holderAnchor: centre, figureAnchor: centre)
        case .flower:
            // Bloom: it closes, opens a little too far with a sixth of a turn, and its core answers.
            return GlyphMotion(tracks: [
                track(.holder, .scale, 2.6, [(0, 1, io), (0.35, 0.72, over), (0.62, 1.08, io), (0.78, 1, nil),
                                             (1, 1, nil)]),
                steps(.figure, 6, 60, 2.6, from: 0.35, to: 0.7, io),
                track(.core, .scale, 2.6, [(0, 1, io), (0.35, 1.55, io), (0.62, 0.8, io), (0.8, 1, nil), (1, 1, nil)]),
            ], holderAnchor: centre, figureAnchor: centre)
        case .burst:
            // Gear: an eighth of a turn at each tick.
            return GlyphMotion(tracks: [
                steps(.figure, 8, 45, 0.62, from: 0, to: 0.38, over),
                track(.core, .scale, 0.62, [(0, 1, nil), (0.2, 1.3, nil), (0.5, 1, nil), (1, 1, nil)]),
                track(.holder, .scale, 0.62, [(0, 1, nil), (0.2, 0.93, nil), (0.45, 1, nil), (1, 1, nil)]),
            ], holderAnchor: centre, figureAnchor: centre)
        case .squircle:
            // Jelly: it squeezes one way and the other while its dot goes from corner to corner.
            return GlyphMotion(tracks: squeeze(1.6, [(0, 1, 1, io), (0.25, 1.16, 0.86, io), (0.5, 1, 1, io),
                                                     (0.75, 0.86, 1.16, io), (1, 1, 1, nil)])
                                   + [steps(.orbit, 4, 90, 0.8, from: 0, to: 0.5, io)],
                               holderAnchor: centre, figureAnchor: centre)
        case .hexagon:
            // Nut: a sixth of a turn, and its core turns back.
            return GlyphMotion(tracks: [
                steps(.figure, 6, 60, 2, from: 0, to: 0.3, io),
                steps(.core, 6, -120, 2, from: 0.45, to: 0.78, io),
                track(.holder, .scale, 2, [(0, 1, nil), (0.15, 0.88, nil), (0.3, 1, nil), (1, 1, nil)]),
            ], holderAnchor: centre, figureAnchor: centre)
        case .diamond:
            // Flip: about its upright axis with a small hop, there and back.
            return GlyphMotion(tracks: [
                track(.holder, .scaleX, 2.4, [(0, 1, io), (0.21, -1, nil), (0.5, -1, io), (0.71, 1, nil), (1, 1, nil)]),
                track(.holder, .lift, 2.4, [(0, 0, out), (0.105, -11, into), (0.21, 0, nil), (0.5, 0, out),
                                            (0.605, -11, into), (0.71, 0, nil), (1, 0, nil)]),
                steps(.core, 4, 90, 1.2, from: 0, to: 0.42, io),
            ], holderAnchor: centre, figureAnchor: centre)
        case .triangle:
            // Jump: it squeezes on its base, jumps and lands on its next side.
            let jump = track(.holder, .lift, 1.6, [(0, 0, io), (0.15, 3, out), (0.42, -16, into), (0.66, 0, nil),
                                                   (1, 0, nil)])
            let land = squeeze(1.6, [(0, 1, 1, io), (0.15, 1.12, 0.86, out), (0.3, 0.92, 1.1, io),
                                     (0.6, 0.95, 1.06, into), (0.66, 1.14, 0.84, out), (0.82, 1, 1, nil),
                                     (1, 1, 1, nil)])
            let swell = track(.core, .scale, 1.6, [(0, 1, nil), (0.66, 1, nil), (0.75, 1.6, nil), (0.92, 1, nil),
                                                   (1, 1, nil)])
            return GlyphMotion(tracks: [jump] + land + [steps(.figure, 3, 120, 1.6, from: 0.15, to: 0.66, io), swell],
                               holderAnchor: UnitPoint(x: 0.5, y: 0.92), figureAnchor: UnitPoint(x: 0.5, y: 0.57))
        case .circle:
            // Orbit: the ring with its dot runs round, slow at its start point; the glyph beats at each round.
            return GlyphMotion(tracks: [
                track(.orbit, .turn, 1.5, [(0, 0, .orbit), (1, 360, nil)]),
                track(.holder, .scale, 1.5, [(0, 1.08, io), (0.22, 1, nil), (0.78, 1, io), (1, 1.08, nil)]),
            ], holderAnchor: centre, figureAnchor: centre)
        case .moon:
            // Cradle: it swings from a point at its top while its star twinkles.
            return GlyphMotion(tracks: [
                track(.figure, .turn, 2.4, [(0, -20, .swing), (0.5, 20, .swing), (1, -20, nil)]),
                track(.core, .scale, 1.2, [(0, 1, io), (0.25, 0.4, io), (0.5, 1.45, io), (0.75, 0.7, io), (1, 1, nil)]),
                track(.core, .turn, 1.2, [(0, 0, nil), (1, 90, nil)]),
            ], holderAnchor: centre, figureAnchor: UnitPoint(x: 0.5, y: 0.02))
        case .drop:
            // Bounce: it squeezes on the ground, goes up and comes down, and its dot goes with it.
            return GlyphMotion(tracks: [track(.holder, .lift, 1.1, [(0, 0, out), (0.45, -14, into), (1, 0, nil)])]
                                   + squeeze(1.1, [(0, 1.16, 0.84, out), (0.2, 0.9, 1.12, io), (0.45, 1, 1, io),
                                                   (0.8, 0.94, 1.08, into), (1, 1.16, 0.84, nil)])
                                   + [track(.core, .lift, 1.1, [(0, 3, out), (0.45, -4, into), (1, 3, nil)])],
                               holderAnchor: UnitPoint(x: 0.5, y: 0.98), figureAnchor: centre)
        }
    }
}
