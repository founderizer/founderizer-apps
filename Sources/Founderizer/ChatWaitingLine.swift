import FleetCore
import SwiftUI

/// **One muted line under the conversation while the owner waits for an answer.**
///
/// It takes the idiom of his other product (its `ui/thinking-status.tsx`): one line of muted text, not a
/// bubble and not a card; a label that **swaps** when the state changes, sliding for 150 ms; and motion only
/// while something is genuinely happening, with a mark beside the words when it is not.
///
/// **The shimmer is his, and so is the absence of a spinner** (20 October 2026, reading the first build: "remove
/// that circle, I liked the Thinking text animation we had in chatgpt and in [his other product] with no spinner", then of the
/// second: "It needs to be continuous and not so fast", with the recipe both his projects take it from —
/// transitions.dev, "Shimmer text").
///
/// `UI-PATTERNS.md`, "Marks before words", measures an endless SwiftUI animation at about 30% of a core, because
/// it redraws the window every frame. Nothing here breaks that: `ShimmeringWords` is one `NSView`, four layers
/// and one `CABasicAnimation`, which the render server runs while the window draws once. The rule forbids the
/// cost, not the motion.
///
/// A wait that is **not** the agent's work keeps its mark and stays still, as before: motion means something is
/// happening, and his own file settled that half.
struct ChatWaitingLine: View {
    let waiting: ChatWaiting
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            if waiting.moving && !reduceMotion {
                // No mark: the words themselves carry the motion, as they do in his own project.
                ShimmeringWords(text: waiting.says)
            } else {
                if !waiting.moving {
                    Image(systemName: waiting.symbol).font(IconMetrics.symbol(11)).foregroundStyle(.orange)
                }
                Text(waiting.says).font(ChatStyle.detail)
                    .foregroundStyle(waiting.moving ? FleetStyle.muted : .orange)
                    .fixedSize(horizontal: false, vertical: true)
                    // The swap of his own component: the new words slide up out of a blur, the old ones leave
                    // upward. SwiftUI has no blur in a transition, so this is the slide alone.
                    .id(waiting.says)
                    .transition(swap)
            }
            Spacer(minLength: 0)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: waiting.says)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: waiting.moving)
        // The two words are the line; who waits and until when are on hover, and VoiceOver reads them whole.
        .help(waiting.detail ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(waiting.detail ?? waiting.says)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("chat-waiting")
    }

    private var swap: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(insertion: .offset(y: 8).combined(with: .opacity),
                           removal: .offset(y: -8).combined(with: .opacity))
    }
}

/// **The word, muted, with a brighter band sweeping across its glyphs, right to left, for ever.**
///
/// It is transitions.dev's "Shimmer text" recipe, which both of the owner's projects take it from, in layers
/// instead of CSS and with the same geometry:
///
///   - the gradient box is **four times the width of the word** (`background-size: 400%`), with the light at
///     40% → 50% → 60% of that box, so the bright band is **0.8 of the word wide** and soft at both edges;
///   - the box **slides by three word-widths**, from the band standing off the right to the band standing off
///     the left (`background-position: 100% 0` → `0% 0`), and starts again;
///   - the mask does not move. Only the box under it does.
///
/// **The first attempt animated the gradient's own `locations` past 0 and 1**, which Core Animation clamps, so
/// the band collapsed at both ends and the sweep read as a blink rather than a pass. Sliding a wide box under a
/// fixed mask is what the recipe does and what CSS does, and it has no clamp in it.
///
/// **Why it is AppKit and not SwiftUI.** A repeating SwiftUI animation drives the whole window's draw loop every
/// frame; a `CABasicAnimation` on a layer runs on the render server and the window draws once. The result on
/// screen is the same and the cost is not, which is the whole of `UI-PATTERNS.md`'s rule.
struct ShimmeringWords: NSViewRepresentable {
    let text: String
    /// The chat's line is 12 points; a setup step's moving title is larger (`SetupTitle`).
    var font: NSFont = .systemFont(ofSize: 12)

    func makeNSView(context: Context) -> ShimmerView { ShimmerView() }
    func updateNSView(_ view: ShimmerView, context: Context) {
        view.show(text, font: font, base: NSColor(FleetStyle.muted), light: NSColor(FleetStyle.text))
    }
    /// **SwiftUI has to be told, or it hands a representable the whole width it is offered.** The first build of
    /// this built the sweep out of `bounds.width`, got a view far wider than the word, and swept most of each
    /// pass across empty space — which is exactly the gap the owner saw. The view now measures the word, and the
    /// sweep below is built from the word too, so neither depends on what it is offered.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ShimmerView, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

/// The word twice and a gradient between them: the muted word, then a sliding band of light that only reaches
/// the screen where the second copy of the word lets it through.
///
/// **Both copies are drawn images, not `CATextLayer`s.** A text layer used as a mask does not give back the
/// alpha its glyphs look like it should — the first build of this came out with the word at exactly its base
/// grey and no light through it at all. An image drawn with `NSAttributedString` has the alpha of its own
/// antialiasing, which is what a mask needs, and it is the idiom `TurningSymbolView` already uses here.
final class ShimmerView: NSView {
    /// How long one pass takes. The recipe's own default is 2 seconds; this is slower because the owner asked
    /// for slower, and because a line that sits under his message for minutes should not hurry.
    private static let pass: CFTimeInterval = 2.8
    /// The gradient box, as a multiple of the word's width (`background-size: 400%`).
    private static let box: CGFloat = 4
    /// Where the light begins and ends inside that box — the recipe's `transparent 40% … transparent 60%`.
    private static let lightBegins: CGFloat = 0.4
    private static let lightEnds: CGFloat = 0.6

    private let word = CALayer()
    private let lit = CALayer()             // holds the band and carries the fixed mask
    private let band = CAGradientLayer()
    private let glyphs = CALayer()          // the mask: the same word, not moving
    private var look: (text: String, font: NSFont, base: NSColor, light: NSColor)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(word)
        layer?.addSublayer(lit)
        lit.addSublayer(band)
        lit.mask = glyphs
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        band.locations = [0, NSNumber(value: Double(Self.lightBegins)), 0.5,
                          NSNumber(value: Double(Self.lightEnds)), 1]
        band.anchorPoint = CGPoint(x: 0, y: 0)
        word.contentsGravity = .left
        glyphs.contentsGravity = .left
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }

    /// A click goes to the row under the line; this view is a picture of a word.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The line's own size, so SwiftUI lays the row out around it as it would around a `Text`.
    override var intrinsicContentSize: NSSize { wordSize }

    /// The word's own size. Every layer and the sweep are built from this and never from `bounds`, so a view
    /// that is handed more room than it asked for still shimmers across the word and not across the room.
    private var wordSize: NSSize {
        guard let look else { return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
        let size = (look.text as NSString).size(withAttributes: [.font: look.font])
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    func show(_ text: String, font: NSFont, base: NSColor, light: NSColor) {
        if let look, look.text == text, look.font == font, look.base == base, look.light == light { return }
        look = (text, font, base, light)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let look, wordSize.width > 0, wordSize.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let word_ = NSRect(origin: .zero, size: wordSize)
        word.frame = word_
        word.contentsScale = scale
        word.contents = Self.drawn(look.text, font: look.font, color: look.base, size: word_.size, scale: scale)
        lit.frame = word_
        glyphs.frame = NSRect(origin: .zero, size: word_.size)
        glyphs.contentsScale = scale
        // The mask reads alpha, so the colour only has to be opaque where the glyphs are.
        glyphs.contents = Self.drawn(look.text, font: look.font, color: .white, size: word_.size, scale: scale)
        band.frame = CGRect(x: 0, y: 0, width: word_.width * Self.box, height: word_.height)
        let clear = look.light.withAlphaComponent(0).cgColor     // the same colour, so the fade has no grey in it
        band.colors = [clear, clear, look.light.cgColor, clear, clear]
        CATransaction.commit()
        sweep()
    }

    /// One copy of the word, as layer contents. `flipped: true` so the text sits where AppKit would draw it.
    private static func drawn(_ text: String, font: NSFont, color: NSColor,
                              size: NSSize, scale: CGFloat) -> Any? {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let image = NSImage(size: size, flipped: true) { _ in
            (text as NSString).draw(at: .zero, withAttributes: attributes)
            return true
        }
        return image.layerContents(forContentsScale: scale)
    }

    /// A layer that left the window lost its motion; the same guard `TurningSymbolView` keeps.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { needsLayout = true }
    }

    /// **One pass is the band crossing the word and nothing else.** The recipe slides the box by its whole extra
    /// width, which leaves the band standing off the edge for about two fifths of every cycle — a gap the owner
    /// named as the thing to fix ("It needs to be continuous"). So the box slides only as far as the crossing
    /// itself: the bright centre enters half a band-width off the right edge and leaves half a band-width past
    /// the left, and the next pass begins there. Nothing bright is ever parked off the side.
    ///
    /// The bright centre sits at half the box, so a translation of `-(0.5 · box ± …)` word-widths puts it where
    /// this wants it: from `+(1 + half)` to `-half`, with `half` the band's own half-width in word-widths.
    private func sweep() {
        let half = (Self.lightEnds - Self.lightBegins) * Self.box / 2      // the band's half-width, in words
        let centre = Self.box / 2                                          // where the light sits in the box
        let from = (1 + half - centre) * wordSize.width
        let travel = (-half - centre) * wordSize.width
        if let running = band.animation(forKey: "sweep") as? CABasicAnimation,
           (running.toValue as? CGFloat) == travel { return }
        band.removeAnimation(forKey: "sweep")
        let sweep = CABasicAnimation(keyPath: "transform.translation.x")
        sweep.fromValue = from
        sweep.toValue = travel
        sweep.duration = Self.pass
        sweep.timingFunction = CAMediaTimingFunction(name: .linear)
        sweep.repeatCount = .infinity
        sweep.isRemovedOnCompletion = false
        band.add(sweep, forKey: "sweep")
    }
}
