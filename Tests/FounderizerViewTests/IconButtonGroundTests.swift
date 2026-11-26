import AppKit
import SwiftUI
import Testing
@testable import Founderizer

/// **An icon button has no grey ground at rest: the grey comes under the pointer and is stronger while pressed** (the
/// owner, 23 November 2026: "dont add the grey backgroundto the icon buttons unless on hover"). The bug that this catches:
/// the shared style draws the circle at rest again, or loses it under the pointer or on the press; or a disabled icon
/// button looks as an enabled one, now that no circle tells them apart.
@Suite(.serialized, .timeLimit(.minutes(10))) struct IconButtonGroundTests {
    /// How light the button's circle is, beside its symbol, over a black page.
    private struct Seen: Sendable { let rest, hover, pressed, away: Double }

    @MainActor private static func light(at point: NSPoint, in window: NSWindow) -> Double {
        guard let view = window.contentView, let picture = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return -1 }
        view.layoutSubtreeIfNeeded()
        view.cacheDisplay(in: view.bounds, to: picture)
        let scale = CGFloat(picture.pixelsWide) / view.bounds.width
        let color = picture.colorAt(x: Int(point.x * scale), y: Int((view.bounds.height - point.y) * scale))
        return color?.usingColorSpace(.deviceRGB).map { Double($0.redComponent) } ?? -1
    }

    @Test func theGreyOfAnIconButtonComesUnderThePointerAndNotAtRest() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop { () -> Seen in
            let size = NSSize(width: 80, height: 80)
            let view = NSHostingView(rootView: IconButton(symbol: "plus", words: "Add") {}
                .frame(width: size.width, height: size.height).background(Color.black))
            let window = ViewHost.window(showing: view, size: size)
            defer { ViewHost.close(window) }
            // 11 points beside the middle: in the circle of 28 points, and not on the symbol of 13
            let middle = NSPoint(x: 40, y: 40), beside = NSPoint(x: 51, y: 40)
            let rest = Self.light(at: beside, in: window)
            ViewHost.pointerComes(to: middle, in: window)
            ViewHost.turn(10) { Self.light(at: beside, in: window) > rest + 0.05 }
            let hover = Self.light(at: beside, in: window)
            let click = ViewHost.click(middle, in: window)
            ViewHost.atOnce([click[0]])
            ViewHost.turn(10) { Self.light(at: beside, in: window) > hover + 0.01 }
            let pressed = Self.light(at: beside, in: window)
            ViewHost.atOnce([click[1]])
            return Seen(rest: rest, hover: hover, pressed: pressed, away: Self.light(at: NSPoint(x: 5, y: 5), in: window))
        }
        #expect(seen.away == 0, "the page is black")
        #expect(seen.rest == 0, "no ground at rest")
        #expect(seen.hover > 0.08, "the grey under the pointer")
        #expect(seen.pressed > seen.hover + 0.01, "a step stronger while pressed")
        #expect(screen.stayedHis)
    }

    /// The lightest point of the symbol at `middle`: the brightest pixel within 3 points of it.
    @MainActor private static func symbol(at middle: NSPoint, in window: NSWindow) -> Double {
        var lightest = 0.0
        for dx in stride(from: -3.0, through: 3.0, by: 0.5) {
            for dy in stride(from: -3.0, through: 3.0, by: 0.5) {
                lightest = max(lightest, light(at: NSPoint(x: middle.x + dx, y: middle.y + dy), in: window))
            }
        }
        return lightest
    }

    @Test func aDisabledIconButtonIsDimmed() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop { () -> (on: Double, off: Double) in
            let size = NSSize(width: 160, height: 80)
            let view = NSHostingView(rootView: HStack(spacing: 0) {
                IconButton(symbol: "plus", words: "Add") {}.frame(width: 80, height: 80)
                IconButton(symbol: "plus", words: "Add") {}.disabled(true).frame(width: 80, height: 80)
            }.frame(width: size.width, height: size.height).background(Color.black))
            let window = ViewHost.window(showing: view, size: size)
            defer { ViewHost.close(window) }
            return (Self.symbol(at: NSPoint(x: 40, y: 40), in: window), Self.symbol(at: NSPoint(x: 120, y: 40), in: window))
        }
        #expect(seen.on > 0.3, "the symbol of an enabled icon button")
        #expect(seen.off < seen.on * 0.6, "a disabled one's is dimmed: \(seen.off) beside \(seen.on)")
        #expect(screen.stayedHis)
    }
}
