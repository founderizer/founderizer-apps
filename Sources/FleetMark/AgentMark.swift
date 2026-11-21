import SwiftUI

// An agent's own mark: a shape and a colour that come from its name and from its place in the hub's list of agents,
// so one agent looks the same on every page, in both apps and in every run.
//
// This module holds the whole definition — the hash, the hues, the paths and the motion of a working agent
// (`GlyphMotion.swift`) — and draws nothing. Each app renders it with its own views: the Mac app and the phone play
// the motion on Core Animation layers (`AgentGlyph.swift`, `ios/Sources/AgentMark.swift`). It imports SwiftUI for
// `Shape` and `Color` and nothing else, which is why it is its own target rather than a part of `FleetCore`: the hub
// client and the models stay free of a UI framework.
//
// Nothing here may change without changing both apps' pictures. `FleetMarkTests` holds the marks of the owner's
// fleet, so a change to the hash or to the tables fails the build instead of quietly giving an agent a new face.

/// The silhouette of a glyph.
public enum GlyphKind: String, CaseIterable, Sendable {
    case sparkle, clover, flower, burst, squircle, hexagon, diamond, triangle, circle, moon, drop

    /// How a glyph moves while its agent works in the Windows app: a slow turn, a slow breath, or a small rock from
    /// side to side (`app/vectors/agent-marks.json`). The Mac app and the iPhone app give each kind a motion of its
    /// own (`workMotion`).
    public enum Motion: Sendable { case turn, breathe, rock }
    public var motion: Motion {
        switch self {
        case .sparkle, .clover, .flower, .burst: .turn
        case .squircle, .hexagon, .circle, .drop: .breathe
        case .diamond, .triangle, .moon: .rock
        }
    }

    /// The centre of the inner mark, for a mark that changes its size in place.
    public var coreAnchor: UnitPoint {
        switch self {
        case .moon: UnitPoint(x: 0.71, y: 0.32)
        case .drop: UnitPoint(x: 0.39, y: 0.68)
        case .triangle: UnitPoint(x: 0.5, y: 0.57)
        default: .center
        }
    }
}

/// The shape and the colours of one agent's glyph.
public struct GlyphLook: Sendable {
    public let kind: GlyphKind
    /// The place of its colour in the list of hues.
    public let tone: Int
    public let light: Color
    public let deep: Color
    /// A start time of its own in seconds, so that two glyphs do not move as one.
    public let phase: Double

    /// How much white the inner mark puts on the glyph.
    public static let coreOpacity = 0.38
    /// Nine hues with room between them on the dark canvas, each as a lighter and a deeper step. **The deep blue and the
    /// deep orchid stand at least ΔE2000 16 from the brand's violet #635BFF** (T-15, fix round of 28 October 2026): at
    /// #406EE0 and #994CE0 they were 9.4 and 10.1 from it, so an agent's mark read as the brand's. Blue is now an azure
    /// (#1470B8, 17.2) and orchid a deeper magenta-purple (#AD29C7, 16.9); every two hues still stand 17 or more apart,
    /// and both still read 3:1 on the canvas. The phone draws the same tones.
    private static let tones: [(light: Color, deep: Color)] = [
        (Color(red: 1.00, green: 0.62, blue: 0.54), Color(red: 0.94, green: 0.34, blue: 0.28)),     // coral
        (Color(red: 1.00, green: 0.81, blue: 0.40), Color(red: 0.95, green: 0.60, blue: 0.09)),     // amber
        (Color(red: 0.79, green: 0.92, blue: 0.44), Color(red: 0.50, green: 0.74, blue: 0.17)),     // lime
        (Color(red: 0.47, green: 0.92, blue: 0.76), Color(red: 0.12, green: 0.71, blue: 0.53)),     // mint
        (Color(red: 0.49, green: 0.86, blue: 0.97), Color(red: 0.11, green: 0.62, blue: 0.83)),     // sky
        (Color(red: 0.56, green: 0.71, blue: 0.99), Color(red: 0.08, green: 0.44, blue: 0.72)),     // blue
        (Color(red: 0.90, green: 0.76, blue: 0.58), Color(red: 0.68, green: 0.45, blue: 0.22)),     // sand
        (Color(red: 0.83, green: 0.61, blue: 0.98), Color(red: 0.68, green: 0.16, blue: 0.78)),     // orchid
        (Color(red: 0.98, green: 0.60, blue: 0.81), Color(red: 0.88, green: 0.27, blue: 0.60)),     // rose
    ]
    public static let toneCount = tones.count

    /// The look of a name. `attempt` 0 is its first look; each next number is its next look, for a team where an
    /// earlier agent has the same shape or colour.
    public init(name: String, attempt: Int = 0) {
        // FNV-1a, not `hashValue`, which changes with each run. The prefix was selected one time, so that the names of
        // the first fleet get different shapes and colours. Do not change it: each agent would get another glyph.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in ("fleet-glyph-13675:" + name.lowercased() + (attempt == 0 ? "" : "#\(attempt)")).utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        kind = GlyphKind.allCases[Int(hash % UInt64(GlyphKind.allCases.count))]
        tone = Int((hash >> 20) % UInt64(Self.tones.count))
        light = Self.tones[tone].light
        deep = Self.tones[tone].deep
        phase = Double(hash % 6283) / 1000
    }

    /// The look of a kind in one hue of the list, with no name behind it: the marks of the first run's welcome page,
    /// which stand for a team that does not exist yet (the owner's yes of 14 November 2026 to its moving mock). `tone`
    /// is a place in the list of hues (0 coral, 1 amber, 2 lime, 3 mint, 4 sky, 5 blue, 6 sand, 7 orchid, 8 rose), and
    /// one out of the list is taken modulo its length. No agent's look comes from here.
    public init(kind: GlyphKind, tone: Int) {
        self.kind = kind
        self.tone = ((tone % Self.tones.count) + Self.tones.count) % Self.tones.count
        light = Self.tones[self.tone].light
        deep = Self.tones[self.tone].deep
        phase = 0
    }

    /// The looks of a team, in the hub's order of its agents. The first agent keeps the first look of its name. A
    /// later agent takes the next look of its name while an earlier agent has its shape or its colour. So the agents
    /// of one team differ in shape and in colour while the team is not larger than the lists, and a new agent at the
    /// end of the list changes no other agent.
    public static func team(_ names: [String]) -> [String: GlyphLook] {
        var looks: [String: GlyphLook] = [:], kinds = Set<GlyphKind>(), hues = Set<Int>()
        for name in names where looks[name] == nil {
            if kinds.count == GlyphKind.allCases.count { kinds = [] }
            if hues.count == tones.count { hues = [] }
            let look = (0..<200).lazy.map { GlyphLook(name: name, attempt: $0) }
                .first { !kinds.contains($0.kind) && !hues.contains($0.tone) } ?? GlyphLook(name: name)
            looks[name] = look
            kinds.insert(look.kind)
            hues.insert(look.tone)
        }
        return looks
    }
}

// MARK: - The shapes

private func glyphPoint(_ center: CGPoint, _ radius: CGFloat, _ degrees: CGFloat) -> CGPoint {
    CGPoint(x: center.x + radius * cos(degrees * .pi / 180), y: center.y + radius * sin(degrees * .pi / 180))
}

private func glyphCircle(_ center: CGPoint, _ radius: CGFloat) -> CGRect {
    CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
}

/// A regular polygon with round corners. `turn` is the angle of its first corner; -90 is the top.
private func glyphPolygon(_ sides: Int, center: CGPoint, radius: CGFloat, corner: CGFloat, turn: CGFloat) -> Path {
    let corners = (0..<sides).map { glyphPoint(center, radius, turn + CGFloat($0) * 360 / CGFloat(sides)) }
    var path = Path()
    path.move(to: CGPoint(x: (corners[sides - 1].x + corners[0].x) / 2, y: (corners[sides - 1].y + corners[0].y) / 2))
    for index in 0..<sides {
        path.addArc(tangent1End: corners[index], tangent2End: corners[(index + 1) % sides], radius: corner)
    }
    path.closeSubpath()
    return path
}

/// Round lobes about a round middle, as one area: **their union, so the shape has one edge** (fix round 3, item 52), which
/// the dashed outline of an agent in setup follows on both apps. The circles laid one over another filled the same
/// area, but a stroke drew every circle whole: a clover or a flower in setup was a tangle of dashes.
private func glyphLobes(_ count: Int, center: CGPoint, lobe: CGFloat, distance: CGFloat, middle: CGFloat,
                        turn: CGFloat) -> Path {
    var path = Path(ellipseIn: glyphCircle(center, middle))
    for index in 0..<count {
        path = path.union(Path(ellipseIn: glyphCircle(glyphPoint(center, distance, turn + CGFloat(index) * 360 / CGFloat(count)), lobe)))
    }
    return path
}

/// A star. With `curved`, each side bends in to `inner`; else it has a corner there.
private func glyphStar(_ points: Int, center: CGPoint, outer: CGFloat, inner: CGFloat, curved: Bool,
                       turn: CGFloat) -> Path {
    let step = 360 / CGFloat(points)
    var path = Path()
    path.move(to: glyphPoint(center, outer, turn))
    for index in 0..<points {
        let next = glyphPoint(center, outer, turn + CGFloat(index + 1) * step)
        let between = glyphPoint(center, inner, turn + (CGFloat(index) + 0.5) * step)
        if curved { path.addQuadCurve(to: next, control: between) } else { path.addLine(to: between); path.addLine(to: next) }
    }
    path.closeSubpath()
    return path
}

/// **The numbers that a kind's outline is built from**, in parts of the glyph's half side and from its centre (angles
/// in degrees, -90 is the top). The outline (`GlyphOutline`) and the sketch of its making (`GlyphSketch`) both read
/// them, so the lines that the sketch draws are the lines that the outline is built on.
public enum GlyphFigure: Sendable, Equatable {
    /// `points` points on a circle of `outer`; each side bends in to `inner` (`curved`) or has a corner there.
    case star(points: Int, outer: CGFloat, inner: CGFloat, curved: Bool, turn: CGFloat)
    /// `count` round lobes of radius `lobe` on a circle of `distance`, about a round middle of `middle`, as one area.
    case lobes(count: Int, lobe: CGFloat, distance: CGFloat, middle: CGFloat, turn: CGFloat)
    /// A regular polygon whose corners stand on a circle of `radius` and are round with `corner`; its centre stands
    /// `lower` under the glyph's.
    case polygon(sides: Int, radius: CGFloat, corner: CGFloat, turn: CGFloat, lower: CGFloat)
    /// A square of half side `half` with continuous corners of `corner`.
    case squircle(half: CGFloat, corner: CGFloat)
    case circle(radius: CGFloat)
    /// A disc with a round bite out of it, each a centre from the glyph's centre and a radius.
    case moon(body: CGVector, radius: CGFloat, bite: CGVector, biteRadius: CGFloat)
    /// A drop: its tip `tip` over the centre, its round bottom of `radius` about a point `bottom` under the centre,
    /// and its two sides, which leave the tip toward `shoulder` (mirrored on the left) and reach the bottom from `side`
    /// over it.
    case drop(tip: CGFloat, bottom: CGFloat, radius: CGFloat, shoulder: CGVector, side: CGFloat)
}

extension GlyphKind {
    /// The numbers of this kind's outline.
    public var figure: GlyphFigure {
        switch self {
        case .sparkle: .star(points: 4, outer: 1, inner: 0.12, curved: true, turn: -90)
        case .clover: .lobes(count: 4, lobe: 0.46, distance: 0.5, middle: 0.3, turn: -45)
        case .flower: .lobes(count: 6, lobe: 0.36, distance: 0.6, middle: 0.55, turn: -90)
        case .burst: .star(points: 8, outer: 1, inner: 0.7, curved: false, turn: -90)
        case .squircle: .squircle(half: 0.88, corner: 0.54)
        case .hexagon: .polygon(sides: 6, radius: 0.99, corner: 0.16, turn: -90, lower: 0)
        case .diamond: .polygon(sides: 4, radius: 1, corner: 0.18, turn: -90, lower: 0)
        case .triangle: .polygon(sides: 3, radius: 1.02, corner: 0.2, turn: -90, lower: 0.14)
        case .circle: .circle(radius: 0.92)
        case .moon:
            .moon(body: CGVector(dx: -0.04, dy: 0.03), radius: 0.93, bite: CGVector(dx: 0.38, dy: -0.26),
                  biteRadius: 0.72)
        case .drop: .drop(tip: 0.98, bottom: 0.27, radius: 0.7, shoulder: CGVector(dx: 0.16, dy: -0.6), side: 0.5)
        }
    }
}

/// The outline of a glyph in a square.
public struct GlyphOutline: Shape {
    public let kind: GlyphKind
    public init(kind: GlyphKind) { self.kind = kind }

    public func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY), r = min(rect.width, rect.height) / 2
        switch kind.figure {
        case .star(let points, let outer, let inner, let curved, let turn):
            return glyphStar(points, center: c, outer: r * outer, inner: r * inner, curved: curved, turn: turn)
        case .lobes(let count, let lobe, let distance, let middle, let turn):
            return glyphLobes(count, center: c, lobe: r * lobe, distance: r * distance, middle: r * middle, turn: turn)
        case .squircle(let half, let corner):
            return RoundedRectangle(cornerRadius: r * corner, style: .continuous)
                .path(in: rect.insetBy(dx: rect.width / 2 - r * half, dy: rect.height / 2 - r * half))
        case .polygon(let sides, let radius, let corner, let turn, let lower):
            return glyphPolygon(sides, center: CGPoint(x: c.x, y: c.y + r * lower), radius: r * radius,
                                corner: r * corner, turn: turn)
        case .circle(let radius): return Path(ellipseIn: glyphCircle(c, r * radius))
        case .moon(let body, let radius, let bite, let biteRadius):
            return Path(ellipseIn: glyphCircle(CGPoint(x: c.x + r * body.dx, y: c.y + r * body.dy), r * radius))
                .subtracting(Path(ellipseIn: glyphCircle(CGPoint(x: c.x + r * bite.dx, y: c.y + r * bite.dy),
                                                         r * biteRadius)))
        case .drop(let tip, let bottom, let radius, let shoulder, let side):
            let top = CGPoint(x: c.x, y: c.y - r * tip), o = CGPoint(x: c.x, y: c.y + r * bottom), round = r * radius
            var path = Path()
            path.move(to: top)
            path.addCurve(to: CGPoint(x: o.x + round, y: o.y),
                          control1: CGPoint(x: c.x + r * shoulder.dx, y: c.y + r * shoulder.dy),
                          control2: CGPoint(x: o.x + round, y: o.y - r * side))
            path.addArc(center: o, radius: round, startAngle: .zero, endAngle: .degrees(180), clockwise: false)
            path.addCurve(to: top, control1: CGPoint(x: o.x - round, y: o.y - r * side),
                          control2: CGPoint(x: c.x - r * shoulder.dx, y: c.y + r * shoulder.dy))
            path.closeSubpath()
            return path
        }
    }
}

/// The lighter mark in a glyph. It gives the glyph depth, and the motion something to move.
public struct GlyphCore: Shape {
    public let kind: GlyphKind
    public init(kind: GlyphKind) { self.kind = kind }

    public func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY), r = min(rect.width, rect.height) / 2
        switch kind {
        case .sparkle: return glyphStar(4, center: c, outer: r * 0.42, inner: r * 0.05, curved: true, turn: -45)
        case .clover: return Path(ellipseIn: glyphCircle(c, r * 0.24))
        case .flower: return Path(ellipseIn: glyphCircle(c, r * 0.3))
        case .burst: return Path(ellipseIn: glyphCircle(c, r * 0.36)).strokedPath(StrokeStyle(lineWidth: r * 0.15))
        case .squircle: return Path(ellipseIn: glyphCircle(glyphPoint(c, r * 0.36, -45), r * 0.18))
        case .hexagon: return glyphPolygon(6, center: c, radius: r * 0.47, corner: r * 0.07, turn: -60)
        case .diamond: return glyphPolygon(4, center: c, radius: r * 0.42, corner: r * 0.07, turn: -90)
        case .triangle: return Path(ellipseIn: glyphCircle(CGPoint(x: c.x, y: c.y + r * 0.14), r * 0.2))
        case .circle:
            var path = Path(ellipseIn: glyphCircle(c, r * 0.5)).strokedPath(StrokeStyle(lineWidth: r * 0.11))
            path.addEllipse(in: glyphCircle(glyphPoint(c, r * 0.5, -40), r * 0.15))
            return path
        case .moon:
            return glyphStar(4, center: CGPoint(x: c.x + r * 0.42, y: c.y - r * 0.36), outer: r * 0.27, inner: r * 0.04,
                             curved: true, turn: -90)
        case .drop: return Path(ellipseIn: glyphCircle(CGPoint(x: c.x - r * 0.22, y: c.y + r * 0.36), r * 0.15))
        }
    }
}
