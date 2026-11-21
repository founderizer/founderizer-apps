import AppKit
import FleetCore
import SwiftUI

/// **A value in a request's words is a chip with a copy icon** (the owner, 21 November 2026: "Sometimes tasks contain
/// names, codes and other values that need to be copied... it would be nice to identify those and add a small icon
/// button next to them to copy them directly", and his "Yes, as drawn"): each value that the agent put in inline code
/// (`CardValues`), in the reason, the task, the steps and the details of a request's card and of the request at hand on
/// Needs you (`MessageText.values`), stands in a chip of inline code's own fill, with the copy symbol after it inside
/// the chip, always shown. A press anywhere on the chip copies the value exactly, and the symbol is a check for 1.5
/// seconds.
///
/// The words stay one text, which wraps, selects and centres as before: the chip is drawn behind them from their own
/// layout (`Text.LayoutKey`), as a badge is (`CardBadges`), in the place of inline code's flat fill. **It adds no
/// character to the words**: the room of the icon is a kern on the value's last character, and the chip's edge before
/// it a kern on the character before it, so a selection and a copy of the words hold them as written, and the icon
/// never stands at a line's start apart from its value. A value that wraps is a chip on each of its lines, and only its
/// last line has the icon.
enum CardValueText {
    /// The room after a value, in the words' size: a gap, the icon's place (`icon`) and the chip's edge (`edge`).
    static let room: CGFloat = 1.45
    /// The icon's place, a square, in the words' size; the symbol in it is 0.8 of the words' size.
    static let icon: CGFloat = 0.95
    /// The chip's edge before its words (where they do not begin a line) and after its icon, in the words' size.
    static let edge: CGFloat = 0.22

    /// Words with no badge (`CardBadgeText.text`) with the marks of their values (`CardValues.runs`): no flat fill on
    /// a value (the chip is its fill), the room of its icon after it and its chip's edge before it. The values' ranges
    /// are those of the words that come back.
    static func marked(_ words: AttributedString, size: CGFloat)
        -> (words: AttributedString, values: [Range<AttributedString.Index>]) {
        let found = CardValues.runs(in: words)
        guard !found.isEmpty else { return (words, []) }
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
            let value = at(span.lowerBound)..<at(span.upperBound)
            marked[value].swiftUI.backgroundColor = nil
            kern(span.upperBound - 1, size * room)
            if span.lowerBound > 0 { kern(span.lowerBound - 1, size * edge) }
        }
        return (marked, CardValues.runs(in: marked))
    }

    /// The words of `range` of `words` (from `marked`), which have no link, as texts: each value among them a text of
    /// its own with its mark (`CardValue`), numbered from `index` on.
    static func texts(_ words: AttributedString, _ range: Range<AttributedString.Index>,
                      values: [Range<AttributedString.Index>], size: CGFloat, index: inout Int) -> [Text] {
        var texts: [Text] = [], start = range.lowerBound
        for value in values where range.lowerBound <= value.lowerBound && value.upperBound <= range.upperBound {
            if start < value.lowerBound { texts.append(Text(AttributedString(words[start..<value.lowerBound]))) }
            texts.append(Text(AttributedString(words[value]))
                .customAttribute(CardValue(index: index, words: String(words[value].characters), size: size)))
            index += 1
            start = value.upperBound
        }
        if start < range.upperBound { texts.append(Text(AttributedString(words[start..<range.upperBound]))) }
        return texts
    }
}

/// The mark of a value in a text's layout: which value of the text, its exact characters, and the size of the words
/// around it, which measures its chip.
struct CardValue: TextAttribute {
    let index: Int
    let words: String
    let size: CGFloat

    /// One value's chip on one line.
    struct Part: Identifiable {
        let value: Int
        let line: Int
        let words: String
        /// The chip, in the coordinates of the view that holds the texts.
        let frame: CGRect
        /// Where its icon stands, on the value's last line.
        let icon: CGRect?
        let size: CGFloat
        var id: String { "\(value)-\(line)" }
    }

    /// The chips of the values of the texts of a view, from their layouts: a block's words, one text, whose values
    /// are numbered in it.
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

    /// One chip: inline code's fill, a little lighter under the pointer, and on its last line the copy symbol, muted,
    /// in the words' colour under the pointer, a check after a press (`copied`).
    static func draw(_ part: Part, over: Bool, copied: Bool, in context: inout GraphicsContext) {
        let shape = RoundedRectangle(cornerRadius: part.frame.height / 1.3 * 0.36, style: .continuous)
        context.fill(shape.path(in: part.frame), with: .color(FleetStyle.bubble))
        if over { context.fill(shape.path(in: part.frame), with: .color(.white.opacity(0.06))) }
        guard let icon = part.icon else { return }
        let symbol = Text(Image(systemName: copied ? "checkmark" : "square.on.square"))
            .font(.system(size: part.size * 0.8)).foregroundColor(over ? FleetStyle.text : FleetStyle.muted)
        context.draw(symbol, at: CGPoint(x: icon.midX, y: icon.midY), anchor: .center)
    }
}

extension View {
    /// **The chips of the values of a block's words** (`CardValueText`; `values`, their values in their order, from
    /// `CardValues.values`): drawn behind the words, a press on each where the words can be selected, and VoiceOver's
    /// "Copy <value>" for each on the words. Words with no value stay as they are, with no state and no layer.
    @ViewBuilder func cardValues(_ values: [String]) -> some View {
        if values.isEmpty { self } else { modifier(CardValueChips(values: values)) }
    }
}

private struct CardValueChips: ViewModifier {
    let values: [String]
    /// The value under the pointer, whose chip is a little lighter.
    @State private var hovered: Int?
    /// The value pressed last, whose icon is a check until 1.5 seconds after the last press.
    @State private var copied: Int?
    @State private var presses = 0
    @Environment(\.messageWordsSelectable) private var selectable

    func body(content: Content) -> some View {
        content
            .backgroundPreferenceValue(Text.LayoutKey.self) { layouts in
                GeometryReader { proxy in
                    let parts = CardValue.parts(layouts, in: proxy)
                    Canvas { context, _ in
                        context.translateBy(x: CardBadge.bleed, y: CardBadge.bleed)     // the text's own places
                        for part in parts {
                            CardValue.draw(part, over: hovered == part.value, copied: copied == part.value,
                                           in: &context)
                        }
                    }
                    .padding(-CardBadge.bleed)      // a chip's edge reaches past the words, as a badge's does
                }
            }
            // A press where the words can be selected, as a link's and a badge's (`linkPresses`): never on a chat's
            // row that is not under the pointer, nor under a fold. The gate is inside the overlay, so the words keep
            // their place in the view when it changes; a card has few blocks with a value.
            .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
                if selectable {
                    GeometryReader { proxy in
                        ForEach(CardValue.parts(layouts, in: proxy)) { part in press(part) }
                    }
                }
            }
            // the press is hidden from VoiceOver, as a badge's: the words have an action for each value, in their
            // order, which AppKit lists from the last action given (seen off screen, 21 November 2026)
            .accessibilityActions {
                ForEach(Array(values.enumerated()).reversed(), id: \.offset) { index, value in
                    Button(String(l10n: "Copy \(value)")) { copy(index, value) }
                }
            }
            .task(id: presses) {
                guard presses > 0 else { return }
                do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
                copied = nil
            }
    }

    /// The press of a value's chip on one line: it copies the value, with the hand under the pointer at once
    /// (`BadgePress`, whose comment says why), also in a window that is not in front.
    private func press(_ part: CardValue.Part) -> some View {
        BadgePress(open: { copy(part.value, part.words) }, hover: { inside in
            if inside { hovered = part.value } else if hovered == part.value { hovered = nil }
        })
        .frame(width: part.frame.width, height: part.frame.height)
        .accessibilityHidden(true)
        // last: a modifier after it takes the whole text (`CardBadges.press`)
        .position(x: part.frame.midX, y: part.frame.midY)
    }

    /// Copies a value's exact characters; its icon is a check for 1.5 seconds, again from a second press.
    private func copy(_ value: Int, _ words: String) {
        copyMessage(words)
        copied = value
        presses += 1
    }
}
