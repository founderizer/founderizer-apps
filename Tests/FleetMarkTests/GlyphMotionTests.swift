import CoreGraphics
import SwiftUI
import Testing
@testable import FleetMark

/// **The motion of a glyph at work is its own for each kind, and it loops and stays in its place** (`GlyphMotion`; the
/// owner's "A · Own character" of 20 November 2026). A loop that does not close jumps once each round, which reads as a
/// fault on the one sign of work; a part that moves out of its room is cut by its row, its pill or its card.
struct GlyphMotionTests {
    /// Points along a path: each line and curve at ten steps, from its own formula.
    private func points(of path: Path) -> [CGPoint] {
        var points: [CGPoint] = [], at = CGPoint.zero
        path.forEach { element in
            switch element {
            case .move(let to): at = to; points.append(to)
            case .line(let to):
                points += (1...10).map { step -> CGPoint in
                    let t = CGFloat(step) / 10
                    return CGPoint(x: at.x + (to.x - at.x) * t, y: at.y + (to.y - at.y) * t)
                }
                at = to
            case .quadCurve(let to, let control):
                points += (1...10).map { step -> CGPoint in
                    let t = CGFloat(step) / 10, u = 1 - t
                    return CGPoint(x: u * u * at.x + 2 * u * t * control.x + t * t * to.x,
                                   y: u * u * at.y + 2 * u * t * control.y + t * t * to.y)
                }
                at = to
            case .curve(let to, let one, let two):
                points += (1...10).map { step -> CGPoint in
                    let t = CGFloat(step) / 10, u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                    return CGPoint(x: a * at.x + b * one.x + c * two.x + d * to.x,
                                   y: a * at.y + b * one.y + c * two.y + d * to.y)
                }
                at = to
            case .closeSubpath: break
            }
        }
        return points
    }

    @Test("Each loop ends as it starts and keeps in step with the kind's other loops, so a round never jumps")
    func eachLoopCloses() {
        for kind in GlyphKind.allCases {
            let motion = kind.workMotion
            #expect(!motion.tracks.isEmpty, "\(kind) has no motion")
            // A loop that is no whole number of the shortest drifts away from the others: the sparkle grows out of
            // step with its turn.
            let shortest = motion.tracks.map(\.loop).min() ?? 1
            for track in motion.tracks {
                let rounds = track.loop / shortest
                #expect(abs(rounds - rounds.rounded()) < 1e-9,
                        "\(kind) \(track.part) loops in \(track.loop) s, \(shortest) s")
                #expect(track.keys.first?.at == 0 && track.keys.last?.at == 1, "\(kind) \(track.part) \(track.channel)")
                #expect(zip(track.keys, track.keys.dropFirst()).allSatisfy { $0.at <= $1.at },
                        "\(kind) \(track.part) \(track.channel): keys out of order")
                let start = track.value(at: 0), end = track.value(at: 1)
                if track.channel == .turn {
                    // The figure turns with its gradient and the orbit carries the dot: whole turns. A core may end at
                    // a turn of its own symmetry.
                    let whole = track.part == .core ? 360 / Double(kind.coreSymmetry) : 360
                    let left = (end - start).truncatingRemainder(dividingBy: whole)
                    #expect(abs(left) < 1e-9, "\(kind) \(track.part) turns \(end - start) degrees in a loop")
                } else {
                    #expect(abs(end - start) < 1e-9,
                            "\(kind) \(track.part) \(track.channel) ends at \(end), starts at \(start)")
                }
            }
        }
    }

    @Test("No motion leaves its room or sinks below its place")
    func eachMotionStaysInItsRoom() {
        let square = CGRect(x: 0, y: 0, width: 100, height: 100)
        for kind in GlyphKind.allCases {
            let motion = kind.workMotion
            // Points along the outline, and the longest loop of the kind, at 60 frames a second.
            let points = points(of: GlyphOutline(kind: kind).path(in: square))
            let longest = motion.tracks.map(\.loop).max() ?? 1
            var reach: CGFloat = 0, sinks: CGFloat = 0
            for frame in 0...Int(longest * 60) {
                let time = Double(frame) / 60
                func value(_ part: GlyphMotion.Part, _ channel: GlyphMotion.Channel, _ rest: Double) -> Double {
                    guard let track = motion.tracks.first(where: { $0.part == part && $0.channel == channel }) else {
                        return rest
                    }
                    return track.value(at: time.truncatingRemainder(dividingBy: track.loop) / track.loop)
                }
                let uniform = value(.holder, .scale, 1)
                let sx = CGFloat(uniform * value(.holder, .scaleX, 1))
                let sy = CGFloat(uniform * value(.holder, .scaleY, 1))
                let lift = CGFloat(value(.holder, .lift, 0)), turn = CGFloat(value(.figure, .turn, 0) * .pi / 180)
                let pivot = CGPoint(x: 100 * motion.figureAnchor.x, y: 100 * motion.figureAnchor.y)
                let hold = CGPoint(x: 100 * motion.holderAnchor.x, y: 100 * motion.holderAnchor.y)
                sinks = max(sinks, lift)
                for point in points {
                    // The figure turns about its pivot, then the holder squeezes about its own point and lifts.
                    let dx = point.x - pivot.x, dy = point.y - pivot.y
                    let turned = CGPoint(x: pivot.x + dx * cos(turn) - dy * sin(turn),
                                         y: pivot.y + dx * sin(turn) + dy * cos(turn))
                    let placed = CGPoint(x: hold.x + (turned.x - hold.x) * sx,
                                         y: hold.y + (turned.y - hold.y) * sy + lift)
                    reach = max(reach, -placed.x, -placed.y, placed.x - 100, placed.y - 100)
                }
            }
            // The highest jump (the drop's, as the mock-up draws it) goes about 23 units over the square: the 28-pt
            // sidebar row has 11 pt over its glyph, 39 units; the 30-pt pill over a chat has 4 pt over its 22, 18,
            // which the drop passes by 5, as the lane says: this limit is the sidebar's, not the pill's.
            #expect(reach < 25, "\(kind) reaches \(reach) units out of its square")
            // A squeeze on the ground presses down a little; no lift goes down more.
            #expect(sinks <= 3, "\(kind) sinks \(sinks) units under its place")
        }
    }

    @Test("The points that an app plays follow each loop's curves to its end")
    func thePointsFollowTheCurves() {
        for kind in GlyphKind.allCases {
            for track in kind.workMotion.tracks {
                // At the pace of the quickest and the slowest glyph.
                for seconds in [track.loop * 0.9, track.loop * 1.1] {
                    let points = track.samples(over: seconds)
                    #expect(points.first?.at == 0 && points.last?.at == 1, "\(kind) \(track.part) \(track.channel)")
                    #expect(zip(points, points.dropFirst()).allSatisfy { $0.at <= $1.at },
                            "\(kind) \(track.part) \(track.channel): points out of order")
                    let low = track.keys.map(\.value).min() ?? 0, high = track.keys.map(\.value).max() ?? 1
                    let span = max(high - low, 1)
                    for step in 0...240 {
                        let share = Double(step) / 240
                        // What a layer shows between two points: the straight mix of them.
                        let next = points.firstIndex { $0.at >= share } ?? points.count - 1
                        let one = points[max(next - 1, 0)], two = points[next]
                        let mixed = two.at > one.at
                            ? one.value + (two.value - one.value) * (share - one.at) / (two.at - one.at) : two.value
                        let wanted = track.value(at: share)
                        #expect(abs(mixed - wanted) < 0.02 * span,
                                "\(kind) \(track.part) \(track.channel) at \(share): \(mixed), not \(wanted)")
                    }
                }
            }
        }
    }

    @Test("Each inner mark looks the same after a turn of its symmetry, where the way back to rest may stop it")
    func eachCoreHasItsSymmetry() {
        let square = CGRect(x: 0, y: 0, width: 100, height: 100)
        for kind in GlyphKind.allCases {
            // The edge widened by 1.5 units on each side: Core Graphics strokes the sparkle's sharp curves only that
            // closely. A wrong symmetry moves a corner by far more.
            let core = GlyphCore(kind: kind).path(in: square), edge = core.strokedPath(StrokeStyle(lineWidth: 3))
            let anchor = CGPoint(x: 100 * kind.coreAnchor.x, y: 100 * kind.coreAnchor.y)
            let turn = 2 * CGFloat.pi / CGFloat(kind.coreSymmetry)
            for point in points(of: core) {
                let dx = point.x - anchor.x, dy = point.y - anchor.y
                let turned = CGPoint(x: anchor.x + dx * cos(turn) - dy * sin(turn),
                                     y: anchor.y + dx * sin(turn) + dy * cos(turn))
                #expect(edge.contains(turned),
                        "\(kind): its core turned by \(360 / kind.coreSymmetry) degrees leaves its shape at \(point)")
            }
        }
    }
}
