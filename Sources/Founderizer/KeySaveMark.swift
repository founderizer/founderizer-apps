import AppKit
import FleetCore
import SwiftUI

/// **The mark at the end of a key request's title in a chat** (`KeySaveLook`; the owner, 20 November 2026: "no text
/// needed, just a nice animation of loading and then a nice and smooth check"): a ring that turns while his save runs,
/// then a check in a circle that draws itself, white, and goes quiet, as the check of an answer on Needs you does
/// (`NeedAnswered`). The folded card of a request that a saved key answered shows the same check at rest. The ring turns
/// by Core Animation ("Marks before words": a motion that goes on never makes the window draw again); the check's draw
/// is one short change. Under Reduce Motion the ring is whole and still, and the check comes with no draw. The word
/// stands behind the mark: in its hover text and for VoiceOver.
struct KeySaveMark: View {
    /// The check; false: the ring.
    let saved: Bool
    /// The check draws itself as it comes, white, and goes quiet: the save on this card ended now. False: the check at
    /// rest, as the folded card shows it.
    var draws = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The drawn check went quiet: muted, as the folded card's.
    @State private var quiet = false

    /// The mark's square, at the end of a title of 14 points.
    static let side: CGFloat = 16
    /// The point size of the check in its circle; the ring takes the circle's size.
    static let point: CGFloat = 14
    /// From the check's start: white for this long, as the check of an answer on Needs you after its draw starts, then
    /// muted over `quieting`; then the folded card can take the card's place (`NeedRequestCard`), with the same check
    /// at rest.
    static let white = 0.31, quieting = 0.3
    static var settles: Duration { .milliseconds(Int((white + quieting) * 1000) + 60) }

    var body: some View {
        ZStack {
            if saved {
                Image(systemName: "checkmark.circle").font(IconMetrics.symbol(Self.point, weight: .medium))
                    .foregroundStyle(draws && !quiet ? Color.white : FleetStyle.muted)
                    .transition(draws && !reduceMotion ? .drawsOn : .opacity)
            } else {
                TurningRing(turns: !reduceMotion).transition(.opacity)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .help(saved ? String(l10n: "Saved") : String(l10n: "Saving…"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(saved ? Text("Saved") : Text("Saving…"))
        .task(id: saved) {
            guard saved, draws else { return }
            try? await Task.sleep(for: .milliseconds(Int(Self.white * 1000)))
            withAnimation(.easeOut(duration: Self.quieting)) { quiet = true }
        }
    }
}

/// The ring of a key save: a third of a circle, round at its ends, in the muted colour, once round every 0.9 s with no
/// end; under Reduce Motion the whole circle, still. Its circle is the size of the check's circle, so the check takes
/// its place.
private struct TurningRing: NSViewRepresentable {
    let turns: Bool

    func makeNSView(context: Context) -> TurningRingView { TurningRingView() }
    func updateNSView(_ view: TurningRingView, context: Context) { view.turns = turns }
}

private final class TurningRingView: NSView {
    private let ring = CAShapeLayer()
    var turns = true {
        didSet { if turns != oldValue { needsLayout = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(ring)
        ring.fillColor = nil
        ring.lineCap = .round
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }

    /// A click goes to the card under the mark.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }
        // The circle of `checkmark.circle` at 14 points medium: 13.6 points across, its line 1.4.
        let width: CGFloat = 1.4, across: CGFloat = 13.6
        let box = CGRect(x: (bounds.width - across) / 2 + width / 2, y: (bounds.height - across) / 2 + width / 2,
                         width: across - width, height: across - width)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ring.frame = bounds
        ring.contentsScale = window?.backingScaleFactor ?? 2
        ring.lineWidth = width
        ring.path = CGPath(ellipseIn: box, transform: nil)
        ring.strokeEnd = turns ? 0.32 : 1
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ring.strokeColor = NSColor(FleetStyle.muted).cgColor
        }
        CATransaction.commit()
        if turns { turn() } else { ring.removeAnimation(forKey: "turn") }
    }

    /// A layer that left the window lost its motion; a new appearance (Increase Contrast) gives the colour again.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { needsLayout = true }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    /// A window moved to a display of another scale: the ring is drawn again at that scale.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    private func turn() {
        guard ring.animation(forKey: "turn") == nil else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0; turn.toValue = -2 * Double.pi; turn.duration = 0.9
        turn.repeatCount = .infinity; turn.isRemovedOnCompletion = false
        ring.add(turn, forKey: "turn")
    }
}
