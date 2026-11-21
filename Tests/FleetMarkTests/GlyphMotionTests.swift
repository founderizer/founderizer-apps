import CoreGraphics
import SwiftUI
import Testing
@testable import FleetMark

/// **The motion of a glyph at work is smooth and without a stop, its own for each kind, and it stays in its place**
/// (`GlyphMotion`; the owner's "Smooth" of 21 November 2026). A value that jumps or holds still reads as a fault on the
/// one sign of work, a loop that does not close jumps once each round, a turn that stops or goes back rocks the glyph in
/// place, and a part that moves out of its room is cut by its row.
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

    /// The largest change of a function of the share between two neighbours of `steps` even steps from 0 to 1.
    private func largestStep(_ value: (Double) -> Double, _ steps: Int) -> Double {
        (0..<steps).map { abs(value(Double($0 + 1) / Double(steps)) - value(Double($0) / Double(steps))) }.max() ?? 0
    }

    /// **The mock-up's own values** (`FLOW` in `mock-smooth-2026-11-21.html`, with `EN.D` = 1.1), at two shares of
    /// each loop, by the mock-up's names: `rot` the figure's turn, `orb` the orbit's, `kr` the core's; `s` the holder's
    /// size, `sx` and `sy` its size on one axis, `x` and `y` its move; `ks` the core's size, `kx` and `ky` its move.
    /// Each kind's loop and its pivots, in units of its square, as the mock-up has them.
    private static let mock: [GlyphKind: (loop: Double, holder: CGPoint, figure: CGPoint,
                                          at: [Double: [String: Double]])] = [
        .sparkle: (9.6, CGPoint(x: 50, y: 50), CGPoint(x: 50, y: 50), [
            0.13: ["rot": 96.609148, "s": 1.127245, "y": -3.293488, "kr": -187.2, "ks": 0.637566],
            0.58: ["rot": 408.27679, "s": 0.949368, "y": -2.786282, "kr": -835.2, "ks": 1.180664]]),
        .clover: (8.4, CGPoint(x: 50, y: 50), CGPoint(x: 50, y: 50), [
            0.13: ["rot": 90.842669, "x": 7.684806, "y": -5.478315, "sx": 0.923607, "sy": 1.076393, "ks": 0.601876],
            0.58: ["rot": 437.506195, "x": 6.501325, "y": -3.920893, "sx": 0.967215, "sy": 1.032785, "ks": 0.698799]]),
        .flower: (7.8, CGPoint(x: 50, y: 50), CGPoint(x: 50, y: 50), [
            0.13: ["rot": 56.616329, "s": 1.038593, "x": 2.405596, "ks": 0.719533],
            0.58: ["rot": 193.430388, "s": 0.778792, "x": -1.589787, "ks": 1.439132]]),
        .burst: (6, CGPoint(x: 50, y: 50), CGPoint(x: 50, y: 50), [
            0.13: ["rot": 96.249645, "s": 1.016414, "y": -2.195659, "ks": 1.032667],
            0.58: ["rot": 423.00258, "s": 0.949146, "y": -1.857521, "ks": 1.156668]]),
        .squircle: (8, CGPoint(x: 50, y: 94), CGPoint(x: 50, y: 50), [
            0.13: ["sx": 0.883853, "sy": 1.116147, "rot": 9.880465, "orb": 91.118402, "x": 2.891812],
            0.58: ["sx": 0.943013, "sy": 1.056987, "rot": 8.358846, "orb": 435.515576, "x": -3.241548]]),
        .hexagon: (9, CGPoint(x: 50, y: 50), CGPoint(x: 50, y: 50), [
            0.13: ["rot": 55.213997, "kr": -151.20516, "s": 0.913559, "ks": 0.701676, "y": -4.391318],
            0.58: ["rot": 195.626047, "kr": -625.021334, "s": 1.011029, "ks": 1.237318, "y": -3.715043]]),
        .diamond: (7.2, CGPoint(x: 50, y: 50), CGPoint(x: 50, y: 50), [
            0.13: ["sx": 0.951835, "y": -2.922674, "rot": 4.009327, "kr": 93.6, "ks": 0.729871],
            0.58: ["sx": 0.28737, "y": -1.276476, "rot": -2.649645, "kr": 417.6, "ks": 1.034467]]),
        .triangle: (6.4, CGPoint(x: 50, y: 92), CGPoint(x: 50, y: 57), [
            0.13: ["y": -8.558227, "rot": 106.566192, "sx": 1.01649, "sy": 0.979388, "ks": 1.1357],
            0.58: ["y": -16.86167, "rot": 415.945601, "sx": 0.912694, "sy": 1.109133, "ks": 1.000006]]),
        .circle: (8, CGPoint(x: 50, y: 50), CGPoint(x: 50, y: 50), [
            0.13: ["orb": 190.35369, "ks": 1.105175, "s": 0.950235, "x": -2.390012, "y": -0.835386],
            0.58: ["orb": 860.241756, "ks": 0.835326, "s": 0.96235, "x": -0.488955, "y": 0.848661]]),
        .moon: (9.6, CGPoint(x: 50, y: 50), CGPoint(x: 50, y: 2), [
            0.13: ["rot": -2.194267, "y": 1.214811, "kr": 93.6, "ks": 1.093554],
            0.58: ["rot": 11.02105, "y": -0.820677, "kr": 417.6, "ks": 0.931927]]),
        .drop: (6.6, CGPoint(x: 50, y: 98), CGPoint(x: 50, y: 96), [
            0.13: ["y": -8.345877, "sx": 1.020612, "sy": 0.977327, "rot": 4.908165, "kx": 0.172674, "ky": 0.721418],
            0.58: ["y": -11.064641, "sx": 0.890867, "sy": 1.120046, "rot": -7.684806, "kx": -2.321902,
                   "ky": -3.819642]]),
    ]

    /// The mock-up's name of a track.
    private func name(_ track: GlyphMotion.Track) -> String {
        switch (track.part, track.channel) {
        case (.figure, .turn): "rot"
        case (.orbit, .turn): "orb"
        case (.core, .turn): "kr"
        case (.holder, .scale): "s"
        case (.holder, .scaleX): "sx"
        case (.holder, .scaleY): "sy"
        case (.holder, .side): "x"
        case (.holder, .lift): "y"
        case (.core, .scale): "ks"
        case (.core, .side): "kx"
        case (.core, .lift): "ky"
        default: "\(track.part) \(track.channel)"
        }
    }

    @Test("Each kind moves as the mock-up that he chose: its loop, its pivots and each value at two moments")
    func eachValueIsTheMockUps() {
        for kind in GlyphKind.allCases {
            guard let mock = Self.mock[kind] else { Issue.record("\(kind) has no values of the mock-up"); continue }
            let motion = kind.workMotion
            #expect(motion.loop == mock.loop, "\(kind) loops in \(motion.loop) s, the mock-up in \(mock.loop) s")
            #expect(abs(100 * motion.holderAnchor.x - mock.holder.x) < 1e-9
                    && abs(100 * motion.holderAnchor.y - mock.holder.y) < 1e-9, "\(kind): its holder's pivot")
            #expect(abs(100 * motion.figureAnchor.x - mock.figure.x) < 1e-9
                    && abs(100 * motion.figureAnchor.y - mock.figure.y) < 1e-9, "\(kind): its figure's pivot")
            for (share, values) in mock.at {
                // The same values move, no more and no fewer: a value that a row does not name is at rest.
                #expect(Set(motion.tracks.map(name)) == Set(values.keys), "\(kind) moves \(motion.tracks.map(name))")
                for track in motion.tracks {
                    guard let wanted = values[name(track)] else { continue }
                    let value = track.value(at: share)
                    #expect(abs(value - wanted) < 1e-5, "\(kind) \(name(track)) at \(share): \(value), not \(wanted)")
                }
            }
        }
    }

    @Test("Each value is smooth: no jump between two moments, and no stretch of a quarter second where it holds still")
    func eachValueIsSmooth() {
        for kind in GlyphKind.allCases {
            let motion = kind.workMotion, steps = Int(motion.loop * 240)
            for track in motion.tracks {
                let value = track.value(at:)
                // A continuous value changes half as much over half the step; a jump stays as large.
                let coarse = largestStep(value, steps), fine = largestStep(value, 2 * steps)
                #expect(fine < 0.6 * coarse, "\(kind) \(track.part) \(track.channel) jumps by \(fine)")
                // In every quarter of a second the value moves by a part of its range over the loop.
                let samples = (0...steps).map { value(Double($0) / Double(steps)) }
                let range = (samples.max() ?? 0) - (samples.min() ?? 0), window = 60
                #expect(range > 0, "\(kind) \(track.part) \(track.channel) does not move")
                for start in stride(from: 0, to: steps - window, by: 6) {
                    let part = samples[start...(start + window)]
                    #expect((part.max() ?? 0) - (part.min() ?? 0) > 0.001 * range,
                            "\(kind) \(track.part) \(track.channel) holds still from \(Double(start) / Double(steps))")
                }
            }
        }
    }

    @Test("A turn never stops and never goes back: its speed only goes up and down")
    func noTurnStopsOrGoesBack() {
        for kind in GlyphKind.allCases {
            let motion = kind.workMotion, steps = Int(motion.loop * 240)
            for track in motion.tracks where track.channel == .turn {
                let whole = track.value(at: 1) - track.value(at: 0)
                // A turn that swings (the moon's, the drop's lean) has no way to go: it comes back.
                guard abs(whole) > 1 else { continue }
                var slowest = Double.infinity
                for step in 0..<steps {
                    let one = track.value(at: Double(step) / Double(steps))
                    let two = track.value(at: Double(step + 1) / Double(steps))
                    slowest = min(slowest, (two - one) * (whole > 0 ? 1 : -1) * 240)
                }
                // The flower's is the slowest, about 9 degrees a second at its slowest.
                #expect(slowest > 8, "\(kind) \(track.part) turns at \(slowest) degrees a second at its slowest")
            }
        }
    }

    @Test("Each loop ends where it starts, at the same speed, so a round never jumps or jolts")
    func eachLoopCloses() {
        for kind in GlyphKind.allCases {
            let motion = kind.workMotion, step = 1 / (motion.loop * 240)
            for track in motion.tracks {
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
                // The end of a loop comes into its start as the loop before it would: a wave that does not fit the
                // loop a whole number of times can end at its start's value and still change its speed there.
                for back in [step, 10 * step] {
                    let coming = end - track.value(at: 1 - back), before = start - track.value(at: -back)
                    #expect(abs(coming - before) < 1e-9,
                            "\(kind) \(track.part) \(track.channel) comes to its end by \(coming), to its start by \(before)")
                }
            }
        }
    }

    @Test("The way in starts from where the glyph stands, at no speed, and grows into its loop with no jump")
    func theWayInStartsAtRest() {
        let wayIn = GlyphMotion.wayIn, tiny = 1e-4
        for kind in GlyphKind.allCases {
            for track in kind.workMotion.tracks {
                // At the quickest pace and the slowest, from rest and from where a way back to rest stood.
                for seconds in [kind.workMotion.loop * 0.9, kind.workMotion.loop * 1.1] {
                    for from in [track.rest, track.rest + (track.channel == .turn ? -120 : 0.2)] {
                        func at(_ time: Double) -> Double { track.value(after: time, from: from, loop: seconds) }
                        let loop = { (time: Double) in track.value(at: time / seconds) }
                        let label = "\(kind) \(track.part) \(track.channel) from \(from)"
                        #expect(abs(at(0) - from) < 1e-12, "\(label): it starts at \(at(0))")
                        // No sudden speed where it starts, though its loop starts elsewhere: it leaves its place slowly.
                        #expect(abs(at(tiny) - from) <= 1e-5 * max(1, abs(loop(0) - from)),
                                "\(label) leaves its place at once, by \(at(tiny) - from)")
                        // After the way in, the loop itself, and as it ends the way in has the loop's speed.
                        #expect(abs(at(wayIn) - loop(wayIn)) < 1e-9, "\(label) ends its way in at \(at(wayIn))")
                        let inner = at(wayIn) - at(wayIn - tiny), looped = loop(wayIn) - loop(wayIn - tiny)
                        #expect(abs(inner - looped) <= 1e-5 * max(1, abs(loop(wayIn) - from)),
                                "\(label) ends its way in at a speed of \(inner), its loop at \(looped)")
                        // No jump on the way: half the step, half the change.
                        let span = { (share: Double) in at(share * (wayIn + 0.2)) }
                        #expect(largestStep(span, 240) < 0.6 * largestStep(span, 120), "\(label) jumps on its way in")
                        // The points that an app plays are the way in itself, from where it stands to its loop.
                        let points = track.wayInSamples(from: from, loop: seconds)
                        #expect(points.first?.at == 0 && points.first?.value == from && points.last?.at == 1
                                && abs((points.last?.value ?? 0) - loop(wayIn)) < 1e-9, "\(label): its points")
                    }
                }
            }
        }
    }

    @Test("The points that an app plays follow each value to within a small part of a degree or of a unit")
    func thePointsFollowTheValues() {
        for kind in GlyphKind.allCases {
            for track in kind.workMotion.tracks {
                // At the iPhone's largest mark, 96 pt, a tenth of a unit of a move is a tenth of a point, a tenth of a
                // degree moves its edge by less, and three thousandths of its size by under a third of a point. The
                // drop's landing, where its lift turns at once, and the diamond at its narrowest are the farthest from
                // their points.
                let near = switch track.channel {
                case .turn: 0.1
                case .scale, .scaleX, .scaleY: 0.003
                case .side, .lift: 0.1
                }
                // At the pace of the quickest and the slowest glyph.
                for seconds in [kind.workMotion.loop * 0.9, kind.workMotion.loop * 1.1] {
                    let points = track.samples(over: seconds)
                    #expect(points.first?.at == 0 && points.last?.at == 1, "\(kind) \(track.part) \(track.channel)")
                    #expect(zip(points, points.dropFirst()).allSatisfy { $0.at < $1.at },
                            "\(kind) \(track.part) \(track.channel): points out of order")
                    var next = 0
                    for step in 0...4000 {
                        let share = Double(step) / 4000
                        // What a layer shows between two points: the straight mix of them.
                        while next < points.count - 1 && points[next].at < share { next += 1 }
                        let one = points[max(next - 1, 0)], two = points[next]
                        let mixed = two.at > one.at
                            ? one.value + (two.value - one.value) * (share - one.at) / (two.at - one.at) : two.value
                        let wanted = track.value(at: share)
                        #expect(abs(mixed - wanted) < near,
                                "\(kind) \(track.part) \(track.channel) at \(share): \(mixed), not \(wanted)")
                    }
                }
            }
        }
    }

    @Test("No motion leaves the room that the places where it moves give it")
    func eachMotionStaysInItsRoom() {
        let square = CGRect(x: 0, y: 0, width: 100, height: 100)
        for kind in GlyphKind.allCases {
            let motion = kind.workMotion, steps = Int(motion.loop * 240)
            // Points along the outline, at 240 moments a second of the loop.
            let points = points(of: GlyphOutline(kind: kind).path(in: square))
            var up: CGFloat = 0, down: CGFloat = 0, sides: CGFloat = 0
            func value(_ part: GlyphMotion.Part, _ channel: GlyphMotion.Channel, _ share: Double) -> CGFloat {
                guard let track = motion.tracks.first(where: { $0.part == part && $0.channel == channel }) else {
                    return channel == .scale || channel == .scaleX || channel == .scaleY ? 1 : 0
                }
                return CGFloat(track.value(at: share))
            }
            for step in 0...steps {
                let share = Double(step) / Double(steps)
                let uniform = value(.holder, .scale, share)
                let sx = uniform * value(.holder, .scaleX, share), sy = uniform * value(.holder, .scaleY, share)
                let side = value(.holder, .side, share), lift = value(.holder, .lift, share)
                let turn = value(.figure, .turn, share) * .pi / 180
                let pivot = CGPoint(x: 100 * motion.figureAnchor.x, y: 100 * motion.figureAnchor.y)
                let hold = CGPoint(x: 100 * motion.holderAnchor.x, y: 100 * motion.holderAnchor.y)
                for point in points {
                    // The figure turns about its pivot, then the holder squeezes about its own point and moves.
                    let dx = point.x - pivot.x, dy = point.y - pivot.y
                    let turned = CGPoint(x: pivot.x + dx * cos(turn) - dy * sin(turn),
                                         y: pivot.y + dx * sin(turn) + dy * cos(turn))
                    let placed = CGPoint(x: hold.x + (turned.x - hold.x) * sx + side,
                                         y: hold.y + (turned.y - hold.y) * sy + lift)
                    up = max(up, -placed.y)
                    down = max(down, placed.y - 100)
                    sides = max(sides, -placed.x, placed.x - 100)
                }
            }
            // Up: the drop's highest bounce, long at its top, goes 27.4 units over the square. The 28-pt sidebar row
            // has 11 pt over its glyph, 39 units; the iPhone's agent page gives its mark 0.3 of its side
            // (`AgentPage.markRoom`), and a row of Chats takes 5% of its mark more over it than for the 23.2 units of
            // the motion of 20 November (`ChatsPage.markRoom`). The 30-pt pill over a Mac chat has 4 pt over its 22,
            // 18 units, which the drop passes by about 2 pt: nothing there cuts it.
            #expect(up < 28, "\(kind) goes \(up) units over its square")
            // Down: the sparkle's points and the hexagon's float, as far as the sparkle's points went on 20 November.
            #expect(down < 10, "\(kind) goes \(down) units under its square")
            // To each side: the moon's swing, less wide than on 20 November (15.3 units).
            #expect(sides < 15.5, "\(kind) goes \(sides) units to a side of its square")
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
