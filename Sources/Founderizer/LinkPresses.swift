import AppKit
import SwiftUI

/// **A link in a text shows the hand, and a press on it opens it** (the owner, 20 November 2026, after the hand on the
/// names' badges: "ok also links should show the hand cursor"). A link's words carry this mark (`CardBadgeText.text`),
/// so the text's layout tells where they stand, and `linkPresses` lays a badge's press (`BadgePress`) over them, with no
/// fill: the link looks as it did.
struct LinkRun: TextAttribute {
    /// Which link of the text.
    let index: Int
    let url: URL

    /// One link on one line: a link that wraps has a press on each of its lines.
    struct Part: Identifiable {
        /// The text's place in the view and the link's in the text, which all lines of one link share.
        let link: String
        let line: Int
        let url: URL
        /// In the coordinates of the view that holds the texts.
        let frame: CGRect
        var id: String { "\(link)-\(line)" }
    }

    /// Whether `text` has a link.
    static func has(_ text: AttributedString) -> Bool { text.runs[\.link].contains { $0.0 != nil } }

    /// The links of the texts of a view, from their layouts. A link past a line limit's cut has no run there, and no
    /// part.
    static func parts(_ layouts: Text.LayoutKey.Value, in proxy: GeometryProxy) -> [Part] {
        var parts: [Part] = []
        for (place, anchored) in layouts.enumerated() {
            let origin = proxy[anchored.origin]
            for (number, line) in anchored.layout.enumerated() {
                var order: [Int] = [], frames: [Int: CGRect] = [:], urls: [Int: URL] = [:]
                for run in line {
                    guard let link = run[LinkRun.self] else { continue }
                    let frame = run.typographicBounds.rect.offsetBy(dx: origin.x, dy: origin.y)
                    if let kept = frames[link.index] { frames[link.index] = kept.union(frame) } else {
                        order.append(link.index)
                        frames[link.index] = frame
                        urls[link.index] = link.url
                    }
                }
                for index in order {
                    guard let frame = frames[index], let url = urls[index] else { continue }
                    parts.append(Part(link: "\(place)-\(index)", line: number, url: url, frame: frame))
                }
            }
        }
        return parts
    }
}

extension View {
    /// **The press with the hand on each link of the texts of this view** (`LinkRun`), while their words can be
    /// selected (`messageWordsSelectable`). Only there does the I-beam of the words' field stand over a link, which the
    /// press must cover; and a press costs each frame of a scroll (off screen, a chat of 200 messages with two links
    /// each took 17 ms of each frame with a press on every link, most of it the overlay that reads each text's layout,
    /// which SwiftUI runs again at every frame; 0.3 ms with none), so a chat's links have theirs only in the row under
    /// the pointer and the row whose words he pressed last, as its fields (`ChatSelection`). The gate takes the presses
    /// away and does not keep an empty overlay: an overlay on each of the 200 messages, empty where the words could not
    /// be selected, still took 3 to 4 ms of each frame. A block of a knowledge file over 2,000 bytes keeps its fields,
    /// and so its presses (an imported file with 100 links in one block: about 1.5 ms of each frame; with 400: about 8).
    ///
    /// `always`: words with no selection field (a card's folded reason, `cardBadges`), where no I-beam ever stands, keep
    /// their presses also in a chat's row that the pointer is not on. `fold`: where a fold cuts the words of the
    /// `MessageText` around them (`MessageText.fold`), under which no link has a press.
    func linkPresses(_ on: Bool, fold: CGFloat? = nil, always: Bool = false) -> some View {
        modifier(LinkPresses(on: on, fold: fold, always: always))
    }
}

struct LinkPresses: ViewModifier {
    /// The coordinate space of a `MessageText`'s words, from whose top its fold is measured.
    static let space = "MessageText.words"
    let on: Bool
    let fold: CGFloat?
    let always: Bool
    @Environment(\.messageWordsSelectable) private var selectable
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        if on && (always || selectable) {
            content.overlayPreferenceValue(Text.LayoutKey.self) { layouts in
                GeometryReader { proxy in
                    // the fold's cut, in the coordinates of these texts
                    let cut = fold.map { $0 - proxy.frame(in: .named(Self.space)).minY }
                    ForEach(LinkRun.parts(layouts, in: proxy)) { part in
                        if let frame = Self.shown(part.frame, above: cut) { press(part, at: frame) }
                    }
                }
            }
        } else {
            content
        }
    }

    /// Where a link's press stands: its frame, cut where the fold cuts it, and nil for a link under the fold.
    static func shown(_ frame: CGRect, above cut: CGFloat?) -> CGRect? {
        guard let cut else { return frame }
        guard frame.minY < cut else { return nil }
        return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: min(frame.maxY, cut) - frame.minY)
    }

    /// The press of one link on one line: its address opens, as a press on the link did, with the hand under the
    /// pointer. The words keep their link for the keyboard and VoiceOver, so this press is hidden from both.
    private func press(_ part: LinkRun.Part, at frame: CGRect) -> some View {
        BadgePress(open: { openURL(part.url) }, hover: { _ in })
            .frame(width: frame.width, height: frame.height)
            .accessibilityHidden(true)
            // last: a modifier after it takes the whole text (`CardBadges.press`)
            .position(x: frame.midX, y: frame.midY)
    }
}
