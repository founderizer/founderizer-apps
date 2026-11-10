import SwiftUI

// An agent's own mark: a shape and a colour that come from its name and from its place in the hub's list of agents,
// so one agent looks the same on every page, in both apps and in every run.
//
// This module holds the whole definition — the hash, the hues and the paths — and draws nothing. Each app renders it
// with its own views: the Mac app adds the Core Animation motion of a working agent (`AgentGlyph.swift`), the phone
// a plain SwiftUI one (`ios/Sources/AgentMark.swift`). It imports SwiftUI for `Shape` and `Color` and nothing
// else, which is why it is its own target rather than a part of `FleetCore`: the hub client and the models stay free
// of a UI framework.
//
// Nothing here may change without changing both apps' pictures. `FleetMarkTests` holds the marks of the owner's
// fleet, so a change to the hash or to the tables fails the build instead of quietly giving an agent a new face.

/// The silhouette of a glyph.
public enum GlyphKind: String, CaseIterable, Sendable {
    case sparkle, clover, flower, burst, squircle, hexagon, diamond, triangle, circle, moon, drop

    /// How a glyph moves while its agent works: a slow turn, a slow breath, or a small rock from side to side.
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

/// The outline of a glyph in a square.
public struct GlyphOutline: Shape {
    public let kind: GlyphKind
    public init(kind: GlyphKind) { self.kind = kind }

    public func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY), r = min(rect.width, rect.height) / 2
        switch kind {
        case .sparkle: return glyphStar(4, center: c, outer: r, inner: r * 0.12, curved: true, turn: -90)
        case .clover: return glyphLobes(4, center: c, lobe: r * 0.46, distance: r * 0.5, middle: r * 0.3, turn: -45)
        case .flower: return glyphLobes(6, center: c, lobe: r * 0.36, distance: r * 0.6, middle: r * 0.55, turn: -90)
        case .burst: return glyphStar(8, center: c, outer: r, inner: r * 0.7, curved: false, turn: -90)
        case .squircle:
            return RoundedRectangle(cornerRadius: r * 0.54, style: .continuous)
                .path(in: rect.insetBy(dx: rect.width / 2 - r * 0.88, dy: rect.height / 2 - r * 0.88))
        case .hexagon: return glyphPolygon(6, center: c, radius: r * 0.99, corner: r * 0.16, turn: -90)
        case .diamond: return glyphPolygon(4, center: c, radius: r, corner: r * 0.18, turn: -90)
        case .triangle:
            return glyphPolygon(3, center: CGPoint(x: c.x, y: c.y + r * 0.14), radius: r * 1.02, corner: r * 0.2, turn: -90)
        case .circle: return Path(ellipseIn: glyphCircle(c, r * 0.92))
        case .moon:
            return Path(ellipseIn: glyphCircle(CGPoint(x: c.x - r * 0.04, y: c.y + r * 0.03), r * 0.93))
                .subtracting(Path(ellipseIn: glyphCircle(CGPoint(x: c.x + r * 0.38, y: c.y - r * 0.26), r * 0.72)))
        case .drop:
            let top = CGPoint(x: c.x, y: c.y - r * 0.98), o = CGPoint(x: c.x, y: c.y + r * 0.27), radius = r * 0.7
            var path = Path()
            path.move(to: top)
            path.addCurve(to: CGPoint(x: o.x + radius, y: o.y), control1: CGPoint(x: c.x + r * 0.16, y: c.y - r * 0.6),
                          control2: CGPoint(x: o.x + radius, y: o.y - r * 0.5))
            path.addArc(center: o, radius: radius, startAngle: .zero, endAngle: .degrees(180), clockwise: false)
            path.addCurve(to: top, control1: CGPoint(x: o.x - radius, y: o.y - r * 0.5),
                          control2: CGPoint(x: c.x - r * 0.16, y: c.y - r * 0.6))
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
