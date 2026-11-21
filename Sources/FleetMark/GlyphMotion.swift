import SwiftUI

/// **How a glyph moves while its agent works or thinks: smooth and without a stop, in a way of its own for each of the
/// eleven kinds** (the owner, 21 November 2026: "can we make the movements continuous and smooth? with a bit more
/// variety and lively", then "Smooth" to the moving mock-up `mock-smooth-2026-11-21.html` of
/// `founderizer-plans/agent-icon-thinking-2026-11-20`, whose table `FLOW` is the reference for every formula here; it
/// replaces the eleven motions of keys of 20 November). The sparkle turns and pulses; the clover turns and sways; the
/// flower turns while it closes and opens; the burst spins with a pulsing ring; the squircle is jelly on its base while
/// its dot goes round; the hexagon and its core turn against each other; the diamond turns about its upright axis as a
/// gem and floats; the triangle hops and rolls a side further with each hop; the circle's dot runs round and pulls the
/// circle after it; the moon swings wider and narrower while its star twinkles; the drop bounces at changing heights,
/// leans, and its dot sloshes.
///
/// A glyph has four parts, one in the other: the **holder**, which moves and squeezes along the screen's axes; the
/// **figure**, which turns with its gradient; the **orbit**, which turns the inner mark about the centre; and the
/// **core**, the inner mark itself, which moves, turns and changes its size about its own place (`GlyphKind.coreAnchor`).
/// Each track is one value of one part, **a smooth function of the loop's share** (0 to 1): no value holds still, no
/// value goes too far and comes back, and a turn never stops or goes backward, its speed only goes up and down. The
/// tracks of one part move at different rhythms in one loop of 6 to 9.6 s, so a glyph repeats itself only after that.
/// Turns are in degrees, clockwise on the screen; a move is in units of the glyph's square (100 is its side), to the
/// right and down (up is negative). The Mac app and the iPhone app play the tracks in their own layers
/// (`GlyphLayerView`, `MarkLayerView`), each glyph at its own pace (`GlyphLook.phase`), from the glyph at rest
/// (`value(after:from:loop:)`). The Windows app keeps the three earlier moves (`GlyphKind.motion`).
public struct GlyphMotion: Sendable {
    public enum Part: Sendable, CaseIterable { case holder, figure, orbit, core }
    /// A turn; a size on both axes or on one; a move to the side (`side`, to the right) or up and down (`lift`, down).
    public enum Channel: Sendable, CaseIterable { case turn, scale, scaleX, scaleY, side, lift }

    public struct Track: Sendable {
        public let part: Part
        public let channel: Channel
        /// The value at a share of the loop: the same at 1 as at 0, and a turn a whole number of its part's own steps
        /// further.
        public let formula: @Sendable (Double) -> Double

        public init(part: Part, channel: Channel, formula: @escaping @Sendable (Double) -> Double) {
            self.part = part; self.channel = channel; self.formula = formula
        }

        /// The value at a share of the loop, from 0 to 1.
        public func value(at share: Double) -> Double { formula(share) }

        /// **The loop as points for an animation that mixes its points in straight lines**: a point for each 60th of a
        /// second at a loop of `seconds`, at even shares of the loop from 0 to 1, so the line between two points stays
        /// within a small part of a degree or a unit of the function.
        public func samples(over seconds: Double) -> [(at: Double, value: Double)] {
            let count = max(8, Int((seconds * GlyphMotion.pointsPerSecond).rounded(.up)))
            return (0...count).map { step in
                let share = Double(step) / Double(count)
                return (share, value(at: share))
            }
        }

        /// The value of the part at rest: no turn, the whole size, no move.
        public var rest: Double {
            switch channel {
            case .turn, .side, .lift: 0
            case .scale, .scaleX, .scaleY: 1
            }
        }

        /// **The value `time` seconds after the motion began, with its way in**: the part stood at `from` (at rest, or
        /// where a way back to rest had brought it), and its loop takes `seconds` at the glyph's own pace. For the first
        /// `GlyphMotion.wayIn` seconds the value mixes from `from` to the loop, which runs from its start meanwhile, so
        /// the motion grows from the glyph as it stood, with no jump and no sudden speed at either end of the way in;
        /// after it, the loop alone.
        public func value(after time: Double, from: Double, loop seconds: Double) -> Double {
            let time = max(time, 0), looped = value(at: (time / seconds).truncatingRemainder(dividingBy: 1))
            guard time < GlyphMotion.wayIn else { return looped }
            let done = time / GlyphMotion.wayIn, grown = done * done * (3 - 2 * done)
            return from + (looped - from) * grown
        }

        /// The way in as points for an animation that mixes its points in straight lines, at shares of
        /// `GlyphMotion.wayIn`, from 0 (the part at `from`) to 1 (the loop at its own place).
        public func wayInSamples(from: Double, loop seconds: Double) -> [(at: Double, value: Double)] {
            let count = Int((GlyphMotion.wayIn * 2 * GlyphMotion.pointsPerSecond).rounded(.up))
            return (0...count).map { step in
                let share = Double(step) / Double(count)
                return (share, value(after: share * GlyphMotion.wayIn, from: from, loop: seconds))
            }
        }
    }

    /// The length of one loop in seconds, at the kind's own pace: each track of the kind repeats in it.
    public let loop: Double
    public let tracks: [Track]
    /// The point that the holder squeezes about, and the point that the figure turns about, in the glyph's square.
    public let holderAnchor: UnitPoint
    public let figureAnchor: UnitPoint

    /// **The strength of every motion**: the mock-up's "Smooth" (1.4 was "Smooth, livelier", which he did not choose).
    public static let strength = 1.1
    /// **The way in from the glyph at rest, in seconds** (`Track.value(after:from:loop:)`): at the loop's start several
    /// values are not at rest (the flower is smaller, the drop is squeezed, the triangle's dot is large).
    public static let wayIn = 0.4
    /// The points of a loop for each second of it, for the apps' layers (`Track.samples(over:)`).
    public static let pointsPerSecond = 60.0
}

/// A curve of the web's `cubic-bezier`: the eased share at a share of the time. The apps' layers use it to know where
/// a part stands on Core Animation's own curve (`easeOut`).
public struct GlyphCurve: Sendable, Equatable {
    public let x1: Double, y1: Double, x2: Double, y2: Double

    public init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2
    }

    /// Core Animation's ease-out, of the way back to rest.
    public static let easeOut = GlyphCurve(0, 0, 0.58, 1)

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

/// The mock-up's words for its formulas: a whole wave at each whole share (`S`, `C`), the share in the current wave
/// (`fr`), and a hop from 0 up to 1 and back to 0 in one wave, softer at its ends for a larger `k` (`arc`).
private func S(_ x: Double) -> Double { sin(2 * .pi * x) }
private func C(_ x: Double) -> Double { cos(2 * .pi * x) }
private func fr(_ x: Double) -> Double { x - x.rounded(.down) }
private func arc(_ p: Double, _ k: Double) -> Double { pow(sin(.pi * p), 2 * k) }

private func track(_ part: GlyphMotion.Part, _ channel: GlyphMotion.Channel,
                   _ formula: @escaping @Sendable (Double) -> Double) -> GlyphMotion.Track {
    GlyphMotion.Track(part: part, channel: channel, formula: formula)
}

/// The square's units of a point of it, from its top-left corner (100 is its side).
private func point(_ x: Double, _ y: Double) -> UnitPoint { UnitPoint(x: x / 100, y: y / 100) }

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

    /// **The motion of this kind while its agent works or thinks** (`GlyphMotion`): the mock-up's `FLOW`, with `u` the
    /// share of the loop and `e` the strength.
    public var workMotion: GlyphMotion {
        let e = GlyphMotion.strength, centre = UnitPoint.center
        switch self {
        case .sparkle:
            // It turns and pulses, its core turns back twice as fast and beats with it, and it floats a little.
            return GlyphMotion(loop: 9.6, tracks: [
                track(.figure, .turn) { u in 720 * u + 11 * e * S(8 * u) },
                track(.holder, .scale) { u in 1 + 0.13 * e * (0.7 + 0.3 * S(u)) * S(8 * u + 0.25) },
                track(.holder, .lift) { u in -3 * e * S(2 * u) },
                track(.core, .turn) { u in -1440 * u },
                track(.core, .scale) { u in 1 + 0.4 * e * S(8 * u + 0.75) + 0.1 * S(3 * u) },
            ], holderAnchor: centre, figureAnchor: centre)
        case .clover:
            // It turns, sways from side to side with a small hop at each quarter, and squeezes as it lands.
            return GlyphMotion(loop: 8.4, tracks: [
                track(.figure, .turn) { u in 720 * u + 20 * e * S(4 * u) },
                track(.holder, .side) { u in 7 * e * S(2 * u) },
                track(.holder, .lift) { u in -5 * e * arc(fr(4 * u), 1) },
                track(.holder, .scaleX) { u in 1 + 0.07 * e * C(4 * u) },
                track(.holder, .scaleY) { u in 1 - 0.07 * e * C(4 * u) },
                track(.core, .scale) { u in 1 + 0.4 * e * S(4 * u + 0.3) },
            ], holderAnchor: centre, figureAnchor: centre)
        case .flower:
            // It turns while it closes and opens, and its core opens as it closes.
            return GlyphMotion(loop: 7.8, tracks: [
                track(.figure, .turn) { u in 360 * u + 14 * e * S(3 * u) },
                track(.holder, .scale) { u in 0.94 + 0.12 * e * S(3 * u) + 0.03 * S(6 * u + 0.3) },
                track(.holder, .side) { u in 3 * e * S(u) },
                track(.core, .scale) { u in 1 - 0.4 * e * S(3 * u) },
            ], holderAnchor: centre, figureAnchor: centre)
        case .burst:
            // It spins with a ripple in its speed, and its ring pulses.
            return GlyphMotion(loop: 6, tracks: [
                track(.figure, .turn) { u in 720 * u + 5 * e * S(16 * u) },
                track(.holder, .scale) { u in 1 + 0.06 * e * S(8 * u) },
                track(.holder, .lift) { u in -2 * e * S(2 * u) },
                track(.core, .scale) { u in 1 + 0.2 * e * S(4 * u) + 0.08 * e * S(16 * u + 0.3) },
            ], holderAnchor: centre, figureAnchor: centre)
        case .squircle:
            // Jelly on its base, wider and narrower, and it leans a little while its dot goes round.
            let jelly: @Sendable (Double) -> Double = { u in 0.14 * e * (0.75 + 0.25 * S(u)) * S(5 * u) }
            return GlyphMotion(loop: 8, tracks: [
                track(.holder, .scaleX) { u in 1 + jelly(u) },
                track(.holder, .scaleY) { u in 1 - jelly(u) },
                track(.figure, .turn) { u in 9 * e * S(2 * u) },
                track(.orbit, .turn) { u in 720 * u + 18 * e * S(4 * u) },
                track(.holder, .side) { u in 3 * e * S(u + 0.2) },
            ], holderAnchor: point(50, 94), figureAnchor: centre)
        case .hexagon:
            // It turns one way and its core the other, faster, while it beats and floats.
            return GlyphMotion(loop: 9, tracks: [
                track(.figure, .turn) { u in 360 * u + 12 * e * S(3 * u) },
                track(.core, .turn) { u in -1080 * u + 10 * e * S(6 * u) },
                track(.holder, .scale) { u in 1 + 0.08 * e * S(6 * u) },
                track(.core, .scale) { u in 1 + 0.28 * e * S(3 * u + 0.4) },
                track(.holder, .lift) { u in -4 * e * S(2 * u) },
            ], holderAnchor: centre, figureAnchor: centre)
        case .diamond:
            // A gem that turns about its upright axis (never thinner than 0.14 of itself, never mirrored) and floats.
            return GlyphMotion(loop: 7.2, tracks: [
                track(.holder, .scaleX) { u in
                    let c = C(3 * u + 0.06 * S(2 * u))
                    return (0.02 + 0.98 * c * c).squareRoot()
                },
                track(.holder, .lift) { u in -5 * e * (0.5 + 0.5 * S(2 * u - 0.25)) },
                track(.figure, .turn) { u in 5 * e * S(u) },
                track(.core, .turn) { u in 720 * u },
                track(.core, .scale) { u in 1 + 0.25 * e * S(6 * u) },
            ], holderAnchor: centre, figureAnchor: centre)
        case .triangle:
            // It hops on its base, higher and lower, and rolls a side further with each hop; its dot swells as it lands.
            return GlyphMotion(loop: 6.4, tracks: [
                track(.holder, .lift) { u in -(12 + 4 * S(2 * u)) * e * arc(fr(6 * u), 0.8) },
                track(.figure, .turn) { u in 120 * (6 * u - 0.11 * S(6 * u)) },
                track(.holder, .scaleX) { u in 1 + 0.08 * e * C(6 * u) },
                track(.holder, .scaleY) { u in 1 - 0.1 * e * C(6 * u) },
                track(.core, .scale) { u in 1 + 0.35 * e * pow(0.5 + 0.5 * C(6 * u), 2) },
            ], holderAnchor: point(50, 92), figureAnchor: point(50, 57))
        case .circle:
            // Its dot runs round, faster and slower, and pulls the circle a little after it.
            let orbit: @Sendable (Double) -> Double = { u in 1440 * u + 30 * e * S(4 * u) + 10 * S(u) }
            return GlyphMotion(loop: 8, tracks: [
                track(.orbit, .turn, orbit),
                track(.core, .scale) { u in 1 + 0.15 * e * S(3 * u) },
                track(.holder, .scale) { u in 1 + 0.05 * e * S(4 * u + 0.3) },
                // Towards the dot, which stands 40 degrees before the orbit's turn.
                track(.holder, .side) { u in 2.5 * e * cos((orbit(u) - 40) * .pi / 180) },
                track(.holder, .lift) { u in 2.5 * e * sin((orbit(u) - 40) * .pi / 180) - 2 * e * S(2 * u) },
            ], holderAnchor: centre, figureAnchor: centre)
        case .moon:
            // It swings from a point at its top, wider and narrower, while its star turns and twinkles.
            return GlyphMotion(loop: 9.6, tracks: [
                track(.figure, .turn) { u in (13 + 4 * S(u)) * e * S(4 * u) },
                track(.holder, .lift) { u in -3 * e * S(2 * u + 0.3) },
                track(.core, .turn) { u in 720 * u },
                track(.core, .scale) { u in 1 + 0.4 * e * (0.6 + 0.4 * S(3 * u)) * S(8 * u) },
            ], holderAnchor: centre, figureAnchor: point(50, 2))
        case .drop:
            // It bounces at changing heights, squeezed on the ground and long in the air, leans, and its dot sloshes.
            return GlyphMotion(loop: 6.6, tracks: [
                track(.holder, .lift) { u in -(12 + 5 * S(u) + 2 * S(2 * u + 0.3)) * e * arc(fr(6 * u), 0.75) },
                track(.holder, .scaleX) { u in 1 + 0.1 * e * C(6 * u) },
                track(.holder, .scaleY) { u in 1 - 0.11 * e * C(6 * u) },
                track(.figure, .turn) { u in 7 * e * S(3 * u) },
                track(.core, .side) { u in 2.5 * e * S(3 * u + 0.1) },
                track(.core, .lift) { u in 3.5 * e * C(6 * u) },
            ], holderAnchor: point(50, 98), figureAnchor: point(50, 96))
        }
    }
}
