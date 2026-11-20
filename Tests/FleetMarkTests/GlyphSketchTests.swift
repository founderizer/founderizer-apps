import CoreGraphics
import SwiftUI
import Testing
@testable import FleetMark

/// **The making of a glyph draws its own shape** (`GlyphSketch`; the owner's yes of 20 November 2026 to the moving
/// mock-up of "Setting up <agent>"): the pen's line fades into the glyph's colour at its end, so a way that left the
/// outline, a spark off the line, a construction line that builds nothing, or a point that ends away from the inner
/// mark would each show on the screen as a glyph that jumps or a line that misses its shape.
struct GlyphSketchTests {
    private let square = CGRect(x: 10, y: 20, width: 100, height: 100)
    /// Half a unit of the glyph's 100: about a quarter of a point at the setup pages' 48 points.
    private let near: CGFloat = 0.5

    /// The outline's edge, widened to `near` on each side.
    private func edge(_ kind: GlyphKind) -> CGPath {
        GlyphOutline(kind: kind).path(in: square).cgPath
            .copy(strokingWithWidth: 2 * near, lineCap: .round, lineJoin: .round, miterLimit: 1)
    }

    @Test("The pen goes round each shape's own outline, clockwise, from its start")
    func thePenDrawsTheOutline() {
        for kind in GlyphKind.allCases {
            let sketch = GlyphSketch(kind: kind, in: square), edge = edge(kind)
            let shares = (0...400).map { CGFloat($0) / 400 }
            let points = shares.map { sketch.point(at: $0) }
            for (share, point) in zip(shares, points) {
                #expect(edge.contains(point), "\(kind): the pen leaves the outline at \(share) of its way, at \(point)")
            }
            // Clockwise on the screen (y goes down): a positive area.
            let area = zip(points, points.dropFirst() + [points[0]])
                .reduce(CGFloat(0)) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y }
            #expect(area > 0, "\(kind): the pen goes anticlockwise")
            #expect(hypot(sketch.start.x - points[0].x, sketch.start.y - points[0].y) < 0.001)
        }
    }

    @Test("Each spark's joint is on the outline, in the pen's order, and the last one closes the way")
    func theJointsAreOnTheWay() {
        for kind in GlyphKind.allCases {
            let sketch = GlyphSketch(kind: kind, in: square), edge = edge(kind)
            #expect(sketch.joints.count >= 2, "\(kind) has no joints")
            for joint in sketch.joints {
                #expect(edge.contains(joint.point), "\(kind): a joint off the outline at \(joint.point)")
                let drawn = sketch.point(at: joint.at)
                #expect(hypot(drawn.x - joint.point.x, drawn.y - joint.point.y) < near,
                        "\(kind): the pen reaches the joint at \(joint.point) somewhere else, \(drawn)")
            }
            let shares = sketch.joints.map(\.at)
            #expect(zip(shares, shares.dropFirst()).allSatisfy { $0 < $1 }, "\(kind): joints out of order, \(shares)")
            #expect(shares.first.map { $0 > 0 } == true)
            #expect(shares.last == 1)
            if let last = sketch.joints.last {
                #expect(hypot(last.point.x - sketch.start.x, last.point.y - sketch.start.y) < near)
            }
        }
    }

    /// The shapes whose construction lines lie along the part that they build (a lobe's circle, a side, a corner's
    /// circle, the moon's two circles): each touches its part inside it, not only at a joint that it shares with the
    /// next part. The others (a spoke, the pulls of a curve, a side of the square around the circle) touch it at its
    /// ends.
    private let along: Set<GlyphKind> = [.clover, .flower, .squircle, .hexagon, .diamond, .triangle, .moon]

    @Test("Each construction line touches the part of the outline that it builds, in the pen's order")
    func theLinesBuildTheOutline() {
        for kind in GlyphKind.allCases {
            let sketch = GlyphSketch(kind: kind, in: square)
            #expect(!sketch.lines.isEmpty, "\(kind) has no construction lines")
            #expect(!sketch.last.path.isEmpty, "\(kind) has no last line")
            var after: CGFloat = 0
            for (index, line) in sketch.lines.enumerated() {
                guard let builds = line.builds else { Issue.record("\(kind): line \(index) builds no part"); continue }
                #expect(builds.lowerBound >= after && builds.upperBound > builds.lowerBound,
                        "\(kind): line \(index) builds \(builds) after \(after)")
                after = builds.upperBound
                // The line, widened by 1% of the glyph, holds some point of its part of the way: of its middle half
                // where the line lies along it.
                let line = line.path.cgPath.copy(strokingWithWidth: 2, lineCap: .round, lineJoin: .round, miterLimit: 1)
                let inside: ClosedRange<CGFloat> = along.contains(kind) ? 0.25...0.75 : 0...1
                let part = (0...40).map {
                    builds.lowerBound + (builds.upperBound - builds.lowerBound)
                        * (inside.lowerBound + (inside.upperBound - inside.lowerBound) * CGFloat($0) / 40)
                }
                #expect(part.contains { line.contains(sketch.point(at: $0)) },
                        "\(kind): line \(index) touches nothing of the part \(builds) that it builds")
            }
            #expect(sketch.last.builds == nil)
        }
    }

    @Test("The point ends where the inner mark stands, also where that is not the centre")
    func thePointEndsAtTheInnerMark() {
        for kind in GlyphKind.allCases {
            let sketch = GlyphSketch(kind: kind, in: square)
            let core = GlyphCore(kind: kind).path(in: square).boundingRect
            // The circle's inner mark is a ring with a dot on it: the point ends in the ring's middle.
            let place = kind == .circle ? CGPoint(x: square.midX, y: square.midY) : CGPoint(x: core.midX, y: core.midY)
            #expect(hypot(sketch.end.x - place.x, sketch.end.y - place.y) < 1,
                    "\(kind): the point ends at \(sketch.end), the inner mark stands at \(place)")
        }
    }
}
