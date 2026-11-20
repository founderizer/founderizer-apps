import SwiftUI

/// **The making of a glyph, as a designer draws it** (the owner's "Yes, build it" of 20 November 2026 to the moving
/// mock-up of an agent's glyph on "Adding <agent>" and "Setting up <agent>"): the construction lines that its outline
/// is built on, drawn one after the other; the way that a pen goes around the outline, from a joint and clockwise; the
/// joints that the pen passes; and the place where its point ends and becomes the inner mark.
///
/// Everything comes from the numbers of the outline (`GlyphKind.figure`) and of the inner mark (`GlyphCore`: its place,
/// the circle's ring and the moon's star), so each of the eleven shapes has lines of its own: a flower or a clover its
/// lobe circles and its middle circle, a polygon its sharp sides and the circle that touches them, a curved star the
/// pulls of its curves, a straight star its spokes and its inner circle, the squircle its corner circles and its
/// square, the circle the square around it, the moon its two circles, the drop the pulls of its sides and its round
/// bottom. This draws nothing: the Mac app moves it (`MakingGlyph.swift`).
public struct GlyphSketch {
    /// One construction line, in the order that the sketch draws them.
    public struct Line {
        public let path: Path
        /// Where a small dot pops as the line is drawn: a circle's centre, a corner, a pull.
        public let dots: [CGPoint]
        /// The part of the pen's way (shares of its length, 0 to 1) that the line builds: the line goes once the pen
        /// has drawn most of it. Nil for the sketch's last line, which goes with its frame of lines.
        public let builds: ClosedRange<CGFloat>?
    }

    /// A joint of the outline that the pen passes (where two lobes meet, a corner, a point), with its share of the way.
    public struct Joint {
        public let point: CGPoint
        public let at: CGFloat
    }

    /// The construction lines, each for one part of the way, in the pen's order.
    public let lines: [Line]
    /// The line drawn last: the one that holds the shape together (a flower's middle circle).
    public let last: Line
    /// The outline as the pen draws it: from `start`, clockwise, closed, in fine straight steps.
    public let way: Path
    /// The length of the way.
    public let length: CGFloat
    /// The joints in the pen's order; the last one is where the way closes, at the start.
    public let joints: [Joint]
    /// Where the pen starts on the outline.
    public let start: CGPoint
    /// Where the point ends: the place of the inner mark (`GlyphCore`), which is not the centre for some kinds.
    public let end: CGPoint

    private let steps: [CGPoint]
    private let lengths: [CGFloat]

    public init(kind: GlyphKind, in rect: CGRect) {
        let c = CGPoint(x: rect.midX, y: rect.midY), r = min(rect.width, rect.height) / 2
        var outline = Self.flattened(GlyphOutline(kind: kind).path(in: rect), step: r / 100)
        // Clockwise on the screen, where y goes down: a positive area.
        if Self.area(outline) < 0 { outline.reverse() }

        var start = c, marks: [CGPoint] = [], lines: [(path: Path, dots: [CGPoint], part: Int)] = []
        var last = (path: Path(), dots: [CGPoint]())
        switch kind.figure {
        case .lobes(let count, let lobe, let distance, let middle, let turn):
            let step = 360 / CGFloat(count), half = step / 2
            // Two neighbouring lobes meet at the circle of the joints, out of the middle.
            let joint = r * distance * cos(half * .pi / 180)
                + sqrt(max(0, pow(r * lobe, 2) - pow(r * distance * sin(half * .pi / 180), 2)))
            for index in 0..<count {
                let angle = turn + CGFloat(index) * step, centre = Self.at(c, r * distance, angle)
                // Drawn from its side toward the middle, as a compass starts at the point nearest the needle's.
                lines.append((Self.circle(centre, r * lobe, from: angle + 180), [centre], index))
                marks.append(Self.at(c, joint, angle + half))
            }
            start = Self.at(c, joint, turn - half)
            last = (Self.circle(c, r * middle, from: 0), [])
        case .star(let points, let outer, let inner, let curved, let turn):
            let step = 360 / CGFloat(points)
            let tip = { (index: Int) in Self.at(c, r * outer, turn + CGFloat(index) * step) }
            let pull = { (index: Int) in Self.at(c, r * inner, turn + (CGFloat(index) + 0.5) * step) }
            for index in 0..<points {
                var line = Path()
                if curved {
                    // The pulls of the curve: from a point in to its pull and out to the next point.
                    line.move(to: tip(index)); line.addLine(to: pull(index)); line.addLine(to: tip(index + 1))
                } else {
                    // A spoke from the centre to the point.
                    line.move(to: c); line.addLine(to: tip(index))
                }
                lines.append((line, [tip(index)], index))
                marks.append(tip(index + 1))
            }
            start = tip(0)
            // A curved star's waist, where its curves come nearest the centre; a straight star's inner circle.
            let waist = curved ? Self.distance(c, Self.mid(tip(0), pull(0), tip(1))) : r * inner
            last = (Self.circle(c, waist, from: -90), [])
        case .polygon(let sides, let radius, let corner, let turn, let lower):
            let middle = CGPoint(x: c.x, y: c.y + r * lower), step = 360 / CGFloat(sides)
            let half = cos(step / 2 * .pi / 180)
            // The top of a round corner: the corner moved in by the round's own reach.
            let apex = r * radius - r * corner / half + r * corner
            for index in 0..<sides {
                let angle = turn + CGFloat(index) * step
                var side = Path()
                side.move(to: Self.at(middle, r * radius, angle))
                side.addLine(to: Self.at(middle, r * radius, angle + step))
                lines.append((side, [Self.at(middle, r * radius, angle)], index))
                marks.append(Self.at(middle, apex, angle + step))
            }
            start = Self.at(middle, apex, turn)
            // The circle that touches each side at its middle.
            last = (Self.circle(middle, r * radius * half, from: -90), [])
        case .squircle(let half, let corner):
            let reach = r * half - r * corner
            let centres = [CGPoint(x: c.x + reach, y: c.y - reach), CGPoint(x: c.x + reach, y: c.y + reach),
                           CGPoint(x: c.x - reach, y: c.y + reach), CGPoint(x: c.x - reach, y: c.y - reach)]
            for (index, centre) in centres.enumerated() {
                lines.append((Self.circle(centre, r * corner, from: Self.angle(of: c, from: centre)), [centre], index))
            }
            let side = r * half
            marks = [CGPoint(x: c.x + side, y: c.y), CGPoint(x: c.x, y: c.y + side), CGPoint(x: c.x - side, y: c.y),
                     CGPoint(x: c.x, y: c.y - side)]
            start = marks[3]
            var square = Path()
            square.move(to: start)
            for corner in [CGPoint(x: c.x + side, y: c.y - side), CGPoint(x: c.x + side, y: c.y + side),
                           CGPoint(x: c.x - side, y: c.y + side), CGPoint(x: c.x - side, y: c.y - side)] {
                square.addLine(to: corner)
            }
            square.closeSubpath()
            last = (square, [])
        case .circle(let radius):
            let reach = r * radius
            let touches = [CGPoint(x: c.x, y: c.y - reach), CGPoint(x: c.x + reach, y: c.y),
                           CGPoint(x: c.x, y: c.y + reach), CGPoint(x: c.x - reach, y: c.y)]
            let corners = [CGPoint(x: c.x - reach, y: c.y - reach), CGPoint(x: c.x + reach, y: c.y - reach),
                           CGPoint(x: c.x + reach, y: c.y + reach), CGPoint(x: c.x - reach, y: c.y + reach)]
            for index in 0..<4 {
                // The side of the square around it that touches it here, drawn the pen's way round.
                var side = Path()
                side.move(to: corners[index]); side.addLine(to: corners[(index + 1) % 4])
                lines.append((side, [touches[index]], index))
                marks.append(touches[(index + 1) % 4])
            }
            start = touches[0]
            // The ring of its inner mark (`GlyphCore`).
            last = (Self.circle(c, r * 0.5, from: -90), [])
        case .moon(let body, let radius, let bite, let biteRadius):
            let centre = CGPoint(x: c.x + r * body.dx, y: c.y + r * body.dy)
            let bitten = CGPoint(x: c.x + r * bite.dx, y: c.y + r * bite.dy)
            let horns = Self.meet(centre, r * radius, bitten, r * biteRadius)
            // The pen starts at the horn from which its way goes round the body first, and comes back by the bite.
            let first = horns.first { horn in
                let way = Self.rotated(outline, to: horn)
                return abs(Self.distance(way[way.count / 8], centre) - r * radius) < r * 0.02
            } ?? horns[0]
            let other = Self.distance(first, horns[0]) < 0.001 ? horns[1] : horns[0]
            lines.append((Self.circle(centre, r * radius, from: Self.angle(of: first, from: centre)), [centre], 0))
            lines.append((Self.circle(bitten, r * biteRadius, from: Self.angle(of: other, from: bitten)), [bitten], 1))
            marks = [other, first]
            start = first
        case .drop(let tip, let bottom, let radius, let shoulder, let side):
            let top = CGPoint(x: c.x, y: c.y - r * tip), o = CGPoint(x: c.x, y: c.y + r * bottom), round = r * radius
            let right = CGPoint(x: o.x + round, y: o.y), left = CGPoint(x: o.x - round, y: o.y)
            let pulls = [CGPoint(x: c.x + r * shoulder.dx, y: c.y + r * shoulder.dy),
                         CGPoint(x: right.x, y: o.y - r * side), CGPoint(x: left.x, y: o.y - r * side),
                         CGPoint(x: c.x - r * shoulder.dx, y: c.y + r * shoulder.dy)]
            var down = Path(), up = Path()
            down.move(to: top); down.addLine(to: pulls[0]); down.move(to: pulls[1]); down.addLine(to: right)
            up.move(to: left); up.addLine(to: pulls[2]); up.move(to: pulls[3]); up.addLine(to: top)
            lines = [(down, [pulls[0], pulls[1]], 0), (up, [pulls[2], pulls[3]], 2)]
            marks = [right, left, top]
            start = top
            last = (Self.circle(o, round, from: 0), [o])
        }
        let end = Self.end(of: kind, center: c, r: r)
        if case .moon = kind.figure {
            // The place of its little star, which the point goes to at the end. No dot: the point lands there, and a
            // dot stood 5 units from the bite's centre.
            last = (Self.circle(end, r * 0.27, from: -90), [])
        }

        let steps = Self.rotated(outline, to: start)
        self.steps = steps
        var lengths: [CGFloat] = [0]
        for index in 1..<steps.count {
            lengths.append(lengths[index - 1] + Self.distance(steps[index - 1], steps[index]))
        }
        let length = lengths[lengths.count - 1] + Self.distance(steps[steps.count - 1], steps[0])
        self.lengths = lengths
        self.length = length
        self.start = steps[0]
        self.end = end
        var way = Path()
        way.move(to: steps[0])
        for point in steps.dropFirst() { way.addLine(to: point) }
        way.closeSubpath()
        self.way = way

        // Each mark at its place on the way; the last one closes the way, at its start.
        let shares = marks.enumerated().map { index, mark in
            index == marks.count - 1 ? 1 : Self.share(of: mark, on: steps, lengths: lengths, length: length)
        }
        joints = zip(marks, shares).map { Joint(point: $0, at: $1) }
        self.lines = lines.map { line in
            let from = line.part == 0 ? 0 : shares[line.part - 1]
            return Line(path: line.path, dots: line.dots, builds: from...max(from, shares[line.part]))
        }
        self.last = Line(path: last.path, dots: last.dots, builds: nil)
    }

    /// The pen's place when it has drawn `share` of the way.
    public func point(at share: CGFloat) -> CGPoint {
        let along = min(max(share, 0), 1) * length
        var low = 0, high = steps.count - 1
        guard along < lengths[high] else {
            let from = steps[high], rest = length - lengths[high]
            let part = rest > 0 ? (along - lengths[high]) / rest : 0
            return CGPoint(x: from.x + (steps[0].x - from.x) * part, y: from.y + (steps[0].y - from.y) * part)
        }
        while high - low > 1 {
            let middle = (low + high) / 2
            if lengths[middle] <= along { low = middle } else { high = middle }
        }
        let part = (along - lengths[low]) / max(lengths[high] - lengths[low], .ulpOfOne)
        return CGPoint(x: steps[low].x + (steps[high].x - steps[low].x) * part,
                       y: steps[low].y + (steps[high].y - steps[low].y) * part)
    }

    // MARK: - Geometry

    /// The place of a kind's inner mark (`GlyphCore`): its centre, or for a mark that is not round, the centre of its
    /// round part (the circle's ring).
    private static func end(of kind: GlyphKind, center c: CGPoint, r: CGFloat) -> CGPoint {
        switch kind {
        case .squircle: at(c, r * 0.36, -45)
        case .triangle: CGPoint(x: c.x, y: c.y + r * 0.14)
        case .moon: CGPoint(x: c.x + r * 0.42, y: c.y - r * 0.36)
        case .drop: CGPoint(x: c.x - r * 0.22, y: c.y + r * 0.36)
        case .sparkle, .clover, .flower, .burst, .hexagon, .diamond, .circle: c
        }
    }

    private static func at(_ center: CGPoint, _ radius: CGFloat, _ degrees: CGFloat) -> CGPoint {
        CGPoint(x: center.x + radius * cos(degrees * .pi / 180), y: center.y + radius * sin(degrees * .pi / 180))
    }

    private static func distance(_ one: CGPoint, _ two: CGPoint) -> CGFloat { hypot(two.x - one.x, two.y - one.y) }

    /// The angle of `point` seen from `center`, in degrees.
    private static func angle(of point: CGPoint, from center: CGPoint) -> CGFloat {
        atan2(point.y - center.y, point.x - center.x) * 180 / .pi
    }

    /// The middle of a quadratic curve.
    private static func mid(_ from: CGPoint, _ pull: CGPoint, _ to: CGPoint) -> CGPoint {
        CGPoint(x: 0.25 * from.x + 0.5 * pull.x + 0.25 * to.x, y: 0.25 * from.y + 0.5 * pull.y + 0.25 * to.y)
    }

    /// A whole circle that starts at `degrees` and goes clockwise on the screen.
    private static func circle(_ center: CGPoint, _ radius: CGFloat, from degrees: CGFloat) -> Path {
        var path = Path()
        path.addArc(center: center, radius: radius, startAngle: .degrees(Double(degrees)),
                    endAngle: .degrees(Double(degrees) + 360), clockwise: false)
        return path
    }

    /// The two points where two circles meet.
    private static func meet(_ one: CGPoint, _ r1: CGFloat, _ two: CGPoint, _ r2: CGFloat) -> [CGPoint] {
        let d = max(distance(one, two), .ulpOfOne), along = (r1 * r1 - r2 * r2 + d * d) / (2 * d)
        let across = sqrt(max(0, r1 * r1 - along * along))
        let ux = (two.x - one.x) / d, uy = (two.y - one.y) / d
        let foot = CGPoint(x: one.x + along * ux, y: one.y + along * uy)
        return [CGPoint(x: foot.x - across * uy, y: foot.y + across * ux),
                CGPoint(x: foot.x + across * uy, y: foot.y - across * ux)]
    }

    /// Twice the area of a closed run of points; positive when it goes clockwise on the screen.
    private static func area(_ points: [CGPoint]) -> CGFloat {
        points.indices.reduce(0) { sum, index in
            let one = points[index], two = points[(index + 1) % points.count]
            return sum + one.x * two.y - two.x * one.y
        }
    }

    /// The outline as one closed run of points at most `step` apart: its largest part, where an area has more than one.
    private static func flattened(_ path: Path, step: CGFloat) -> [CGPoint] {
        var runs: [[CGPoint]] = [], run: [CGPoint] = [], at = CGPoint.zero, begin = CGPoint.zero
        func add(_ point: CGPoint) {
            if let previous = run.last, distance(previous, point) < 1e-6 { return }
            run.append(point)
        }
        func close() {
            if let first = run.first, let tail = run.last, distance(first, tail) < 1e-6 { run.removeLast() }
            if run.count > 2 { runs.append(run) }
            run = []
        }
        func pieces(_ reach: CGFloat) -> Int { max(4, Int((reach / step).rounded(.up))) }
        path.forEach { element in
            switch element {
            case .move(let to):
                close(); begin = to; at = to; add(to)
            case .line(let to):
                let count = pieces(distance(at, to))
                for index in 1...count {
                    let t = CGFloat(index) / CGFloat(count)
                    add(CGPoint(x: at.x + (to.x - at.x) * t, y: at.y + (to.y - at.y) * t))
                }
                at = to
            case .quadCurve(let to, let control):
                let count = pieces(distance(at, control) + distance(control, to))
                for index in 1...count {
                    let t = CGFloat(index) / CGFloat(count), u = 1 - t
                    add(CGPoint(x: u * u * at.x + 2 * u * t * control.x + t * t * to.x,
                                y: u * u * at.y + 2 * u * t * control.y + t * t * to.y))
                }
                at = to
            case .curve(let to, let one, let two):
                let count = pieces(distance(at, one) + distance(one, two) + distance(two, to))
                for index in 1...count {
                    let t = CGFloat(index) / CGFloat(count), u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, d = 3 * u * t * t, e = t * t * t
                    add(CGPoint(x: a * at.x + b * one.x + d * two.x + e * to.x,
                                y: a * at.y + b * one.y + d * two.y + e * to.y))
                }
                at = to
            case .closeSubpath:
                add(begin); close(); at = begin
            }
        }
        close()
        return runs.max { abs(area($0)) < abs(area($1)) } ?? []
    }

    /// The run of points from the point of the way nearest to `start`, which is put in.
    private static func rotated(_ points: [CGPoint], to start: CGPoint) -> [CGPoint] {
        var best = (index: 0, t: CGFloat(0), gap: CGFloat.infinity)
        for index in points.indices {
            let one = points[index], two = points[(index + 1) % points.count]
            let (t, foot) = project(start, one, two)
            let gap = distance(foot, start)
            if gap < best.gap { best = (index, t, gap) }
        }
        let one = points[best.index], two = points[(best.index + 1) % points.count]
        let foot = CGPoint(x: one.x + (two.x - one.x) * best.t, y: one.y + (two.y - one.y) * best.t)
        let after = Array(points[(best.index + 1)...]) + Array(points[...best.index])
        var run = [foot]
        for point in after where distance(point, foot) > 1e-6 { run.append(point) }
        if let tail = run.last, distance(tail, foot) < 1e-6 { run.removeLast() }
        return run
    }

    /// Where `point` falls on the segment from `one` to `two`: its share of the segment and the foot.
    private static func project(_ point: CGPoint, _ one: CGPoint, _ two: CGPoint) -> (CGFloat, CGPoint) {
        let dx = two.x - one.x, dy = two.y - one.y, square = dx * dx + dy * dy
        let t = square > 0 ? min(max(((point.x - one.x) * dx + (point.y - one.y) * dy) / square, 0), 1) : 0
        return (t, CGPoint(x: one.x + dx * t, y: one.y + dy * t))
    }

    /// The share of the way at the point of the way nearest to `mark`.
    private static func share(of mark: CGPoint, on steps: [CGPoint], lengths: [CGFloat], length: CGFloat) -> CGFloat {
        var best = (along: CGFloat(0), gap: CGFloat.infinity)
        for index in steps.indices {
            let one = steps[index], next = (index + 1) % steps.count, two = steps[next]
            let (t, foot) = project(mark, one, two)
            let gap = distance(foot, mark)
            let reach = (next == 0 ? length : lengths[next]) - lengths[index]
            if gap < best.gap { best = (lengths[index] + reach * t, gap) }
        }
        return best.along / length
    }
}
