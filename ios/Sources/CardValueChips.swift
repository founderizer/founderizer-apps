import FleetCore
import SwiftUI
import UIKit

/// **A value in a request's words is a chip with a copy icon** (the owner, 21 November 2026: "Sometimes tasks contain
/// names, codes and other values that need to be copied... it would be nice to identify those and add a small icon
/// button next to them to copy them directly", and his "Yes, as drawn"; the Mac's `CardValueText`): each value that the
/// agent put in inline code (`CardValues`, FleetCore), in the Why and the What it wants of a request's card
/// (`NeedWords`), open and answered, stands in a chip of inline code's own fill (`Brand.bubble`), with the system's
/// copy symbol after it inside the chip, muted, always shown. A press on the chip copies the value exactly to the
/// system's pasteboard, and the symbol is a check for 1.5 seconds; while the finger is down the chip is a little darker.
///
/// The words stay one text, which wraps and selects as before: the chip is drawn behind them from their own layout
/// (`Text.LayoutKey`), in the place of inline code's flat fill. **It adds no character to the words**: the room of the
/// icon is a kern on the value's last character, and the chip's edge before it a kern on the character before it, so
/// a copy of the words holds them as written, and the icon never stands at a line's start apart from its value. A
/// value that wraps is a chip on each of its lines, and only its last line has the icon. The press of each line is at
/// least 44 points high and wide, and the chip, its room and its symbol grow with the type, up to the accessibility
/// sizes.
enum CardValueText {
    /// The room after a value, in the code's size: a gap, the icon's place (`icon`) and the chip's edge (`edge`).
    static let room: CGFloat = 1.45
    /// The icon's place, a square, in the code's size; the symbol in it is 0.8 of the code's size.
    static let icon: CGFloat = 0.95
    /// The chip's edge before its words (where they do not begin a line) and after its icon, in the code's size.
    static let edge: CGFloat = 0.22

    /// One piece of a block's words: words with no value, or one value with its mark.
    struct Piece {
        let words: AttributedString
        let value: CardValue?
    }

    /// A block's words as `ReplyText` marks them, in pieces: each value (`CardValues.runs`) a piece with its mark,
    /// numbered in their order, with no flat fill (the chip is its fill), the room of its icon after it and its chip's
    /// edge before it. The pieces hold every character of `words`, in their order, and nothing more. `size` is the size
    /// of the code's font. Words with no value are one piece.
    static func pieces(_ words: AttributedString, size: CGFloat) -> [Piece] {
        let found = CardValues.runs(in: words)
        guard !found.isEmpty else { return [Piece(words: words, value: nil)] }
        let characters = words.characters
        let spans = found.map {
            characters.distance(from: characters.startIndex, to: $0.lowerBound)
                ..< characters.distance(from: characters.startIndex, to: $0.upperBound)
        }
        var marked = words
        // each place is found again after each change, in the words as they are then
        func at(_ offset: Int) -> AttributedString.Index {
            marked.characters.index(marked.startIndex, offsetBy: offset)
        }
        func kern(_ offset: Int, _ more: CGFloat) {
            let range = at(offset)..<at(offset + 1)
            let kept = marked[range].swiftUI.kern ?? 0
            marked[range].swiftUI.kern = kept + more
        }
        for span in spans {
            marked[at(span.lowerBound)..<at(span.upperBound)].swiftUI.backgroundColor = nil
            kern(span.upperBound - 1, size * room)
            if span.lowerBound > 0 { kern(span.lowerBound - 1, size * edge) }
        }
        var pieces: [Piece] = [], start = marked.startIndex
        for (index, value) in CardValues.runs(in: marked).enumerated() {
            if start < value.lowerBound {
                pieces.append(Piece(words: AttributedString(marked[start..<value.lowerBound]), value: nil))
            }
            let words = AttributedString(marked[value])
            let mark = CardValue(index: index, words: String(words.characters), size: size)
            pieces.append(Piece(words: words, value: mark))
            start = value.upperBound
        }
        if start < marked.endIndex { pieces.append(Piece(words: AttributedString(marked[start...]), value: nil)) }
        return pieces
    }

    /// The pieces as one text, each value with its mark in the layout (`CardValue`).
    static func text(_ pieces: [Piece]) -> Text {
        let texts = pieces.map { piece in
            piece.value.map { Text(piece.words).customAttribute($0) } ?? Text(piece.words)
        }
        guard let first = texts.first else { return Text(verbatim: "") }
        return texts.dropFirst().reduce(first) { Text("\($0)\($1)") }
    }
}

/// The mark of a value in a text's layout: which value of the text, its exact characters, and the size of the code,
/// which measures its chip.
struct CardValue: TextAttribute {
    let index: Int
    let words: String
    let size: CGFloat

    /// One value's chip on one line.
    struct Part: Identifiable {
        let value: Int
        let line: Int
        let words: String
        /// The chip, in the coordinates of the view that holds the text.
        let frame: CGRect
        /// Where its icon stands, on the value's last line.
        let icon: CGRect?
        let size: CGFloat
        var id: String { "\(value)-\(line)" }
    }

    /// The chips of the values of a text, from its layout: one block's words, whose values are numbered in it.
    static func parts(_ layouts: Text.LayoutKey.Value, in proxy: GeometryProxy) -> [Part] {
        var found: [(value: CardValue, line: Int, frame: CGRect, begins: Bool)] = []
        for anchored in layouts {
            let origin = proxy[anchored.origin]
            for (number, line) in anchored.layout.enumerated() {
                let start = line.typographicBounds.rect.minX + origin.x
                var order: [Int] = [], frames: [Int: (value: CardValue, frame: CGRect)] = [:]
                for run in line {
                    guard let value = run[CardValue.self] else { continue }
                    let frame = run.typographicBounds.rect.offsetBy(dx: origin.x, dy: origin.y)
                    if let kept = frames[value.index] {
                        frames[value.index] = (value, kept.frame.union(frame))
                    } else {
                        order.append(value.index)
                        frames[value.index] = (value, frame)
                    }
                }
                for index in order {
                    guard let one = frames[index] else { continue }
                    found.append((one.value, number, one.frame, one.frame.minX - start < 0.5))
                }
            }
        }
        let last = Dictionary(found.map { ($0.value.index, $0.line) }, uniquingKeysWith: { Swift.max($0, $1) })
        return found.map { one in
            let em = one.value.size, edge = em * CardValueText.edge, ends = last[one.value.index] == one.line
            // the edge before its words, but where they begin the line, which keeps the words' column; its last line
            // ends with the room of its icon, edge included, and a line that it goes on from ends where the line does
            let before = one.begins ? 0 : edge
            var frame = CGRect(x: one.frame.minX - before, y: one.frame.minY, width: one.frame.width + before,
                               height: one.frame.height)
            frame = frame.insetBy(dx: 0, dy: -frame.height * 0.06)
            let side = em * CardValueText.icon
            let icon = ends ? CGRect(x: frame.maxX - edge - side, y: frame.midY - side / 2, width: side, height: side)
                            : nil
            return Part(value: one.value.index, line: one.line, words: one.value.words, frame: frame, icon: icon,
                        size: em)
        }
    }

    /// One chip: inline code's fill, a little darker while the finger is down, and on its last line the copy symbol,
    /// muted, in the words' colour while pressed, a check after a press (`copied`).
    static func draw(_ part: Part, pressed: Bool, copied: Bool, in context: inout GraphicsContext) {
        let shape = RoundedRectangle(cornerRadius: part.frame.height / 1.3 * 0.36, style: .continuous)
        context.fill(shape.path(in: part.frame), with: .color(Brand.bubble))
        if pressed { context.fill(shape.path(in: part.frame), with: .color(.primary.opacity(0.1))) }
        guard let icon = part.icon else { return }
        let symbol = Text(Image(systemName: copied ? "checkmark" : "doc.on.doc"))
            .font(.system(size: part.size * 0.8)).foregroundStyle(pressed ? Color.primary : Brand.muted)
        context.draw(symbol, at: CGPoint(x: icon.midX, y: icon.midY), anchor: .center)
    }
}

/// **The words of one block of a request with their values as chips** (`CardValueText`): drawn behind the words, a
/// press on each, and VoiceOver's "Copy <value>" for each on the words, in their order. `ReplyText(values:)` draws
/// words with no value as the `Text` that they were, with no state and no layer.
struct CardValueWords: View {
    /// A block's words as `ReplyText` marks them.
    let words: AttributedString
    /// The size of inline code's font (`ReplyText`: `.subheadline`, monospaced), which the chip's room follows.
    @ScaledMetric(relativeTo: .subheadline) private var size: CGFloat = 15
    /// The value under the finger, whose chip is a little darker.
    @State private var pressed: Int?
    /// The value pressed last, whose icon is a check until 1.5 seconds after the last press.
    @State private var copied: Int?
    @State private var presses = 0

    /// The press's least side, the system's touch target.
    static let touch: CGFloat = 44
    /// How far a chip may reach past the words: its edge before a value that starts the text, and its height.
    private static let bleed: CGFloat = 6

    var body: some View {
        let pieces = CardValueText.pieces(words, size: size)
        let values = pieces.compactMap(\.value)
        CardValueText.text(pieces)
            .backgroundPreferenceValue(Text.LayoutKey.self) { layouts in
                GeometryReader { proxy in
                    let parts = CardValue.parts(layouts, in: proxy)
                    Canvas { context, _ in
                        context.translateBy(x: Self.bleed, y: Self.bleed)     // the text's own places
                        for part in parts {
                            CardValue.draw(part, pressed: pressed == part.value, copied: copied == part.value,
                                           in: &context)
                        }
                    }
                    .padding(-Self.bleed)
                }
                .accessibilityHidden(true)
            }
            .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
                GeometryReader { proxy in
                    ForEach(CardValue.parts(layouts, in: proxy)) { part in press(part) }
                }
            }
            // the presses are hidden from VoiceOver: the words have an action for each value, in their order, which
            // the system lists from the last action given (seen in a check on the simulator, 21 November 2026)
            .accessibilityActions {
                ForEach(values.reversed(), id: \.index) { value in
                    Button(String(l10n: "Copy \(value.words)")) { copy(value.index, value.words) }
                }
            }
            .task(id: presses) {
                guard presses > 0 else { return }
                do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
                copied = nil
            }
    }

    /// The press of a value's chip on one line: at least 44 points each way, around the chip.
    private func press(_ part: CardValue.Part) -> some View {
        Button { copy(part.value, part.words) } label: { Color.clear }
            .buttonStyle(ChipPress { down in
                if down { pressed = part.value } else if pressed == part.value { pressed = nil }
            })
            .frame(width: max(part.frame.width, Self.touch), height: max(part.frame.height, Self.touch))
            .accessibilityHidden(true)
            .position(x: part.frame.midX, y: part.frame.midY)
    }

    /// Copies a value's exact characters; its icon is a check for 1.5 seconds, again from a second press.
    private func copy(_ value: Int, _ words: String) {
        UIPasteboard.general.string = words
        copied = value
        presses += 1
    }
}

/// A chip's press: its whole frame takes the touch, and it says when the finger goes down and up.
private struct ChipPress: ButtonStyle {
    let changed: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(Rectangle())
            .onChange(of: configuration.isPressed) { _, down in changed(down) }
    }
}
