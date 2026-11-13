import AppKit
import FleetCore
import SwiftUI

/// Markdown is display-only: a copy takes the words as they were written. Checked files use literal Text instead.
struct MessageText: View, Equatable {
    let text: String
    /// An agent's text in a chat or a task thread: the chat's measures (`ChatStyle`). Else the size of a form.
    var chat = false
    /// Under the title of a step, where everything takes the step's one size (`SetupMetrics.text`): the words of a
    /// request at hand on Needs you (`NeedStep`).
    var step = false
    /// The script of the door's card (API 1.125, `DoorCall.checked`): its code block wraps and does not scroll
    /// sideways, so that the end of a long line is on screen before he signs Run it once.
    var script = false
    /// Code in a line of a step's words: a little under the words' 15 points, as the chat's code is under its 14.
    private static let stepCode = Font.system(size: 13.5, design: .monospaced)

    private struct Block {
        let kind: MessageBlock.Kind
        let text: String
        var marker = ""
        /// A list item's depth (`MessageBlock.level`).
        var level = 0
        var formatted = AttributedString()
        /// The rows of a table, the header first.
        var cells: [[AttributedString]] = []
    }

    private final class Parsed: NSObject {
        let blocks: [Block]
        init(_ blocks: [Block]) { self.blocks = blocks }
    }
    private static let cache: NSCache<NSString, Parsed> = {
        let cache = NSCache<NSString, Parsed>()
        cache.countLimit = 256
        cache.totalCostLimit = 2 * 1024 * 1024
        return cache
    }()
    private var blocks: [Block] {
        // The inline code of the chat is larger, so the two forms of one text have their own entries.
        let key = ((step ? "step\u{0}" : chat ? "chat\u{0}" : "form\u{0}") + text) as NSString
        if let cached = Self.cache.object(forKey: key) { return cached.blocks }
        let parsed = Self.parse(text, code: step ? Self.stepCode : chat ? ChatStyle.code : FormMetrics.code)
        Self.cache.setObject(Parsed(parsed), forKey: key, cost: text.utf8.count * 4)
        return parsed
    }
    /// The blocks of a text by the rules both apps share (`MessageBlock`, FleetCore), with their inline marks drawn in
    /// this app's fonts.
    private static func parse(_ text: String, code: Font) -> [Block] {
        MessageBlock.parse(text).map { block in
            var drawn = Block(kind: block.kind, text: block.text, marker: block.marker, level: block.level)
            switch block.kind {
            case .code, .rule: break
            case .table: drawn.cells = block.cells.map { $0.map { inline($0, code: code) } }
            default: drawn.formatted = inline(block.text, code: code)
            }
            return drawn
        }
    }

    private static func inline(_ value: String, code: Font) -> AttributedString {
        var result = MessageBlock.inline(value)
        for run in result.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                result[run.range].font = code
                result[run.range].backgroundColor = FleetStyle.bubble
            }
        }
        return result
    }

    var body: some View {
        let blocks = blocks, lines = chat ? ChatStyle.lineSpacing : 5
        VStack(alignment: .leading, spacing: chat ? 0 : 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                Group {
                switch block.kind {
                case .paragraph:
                    Text(block.formatted).lineSpacing(lines)
                case .heading:
                    Text(block.formatted)
                        .font(step ? Font.system(size: SetupMetrics.text, weight: .semibold) : chat ? ChatStyle.heading : FormMetrics.title)
                        .padding(.top, chat ? 0 : 3)
                case .item:
                    // An item under another starts its mark where that item's words start: the mark's 12 and the 9
                    // after it, for each level.
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text(block.marker).frame(minWidth: 12, alignment: .trailing)
                        Text(block.formatted).lineSpacing(lines)
                    }.padding(.leading, 3 + CGFloat(block.level) * 21)
                case .quote:
                    HStack(spacing: 10) {
                        Rectangle().fill(FleetStyle.muted.opacity(0.4)).frame(width: 2)
                        Text(block.formatted).foregroundStyle(FleetStyle.muted).lineSpacing(lines)
                    }
                case .code: CodeBlock(text: block.text, chat: chat, wraps: script)
                case .rule: Rule().padding(.vertical, 4)
                case .table:
                    Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 7) {
                        ForEach(Array(block.cells.enumerated()), id: \.offset) { index, row in
                            GridRow {
                                ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                    Text(cell).fontWeight(index == 0 ? .medium : .regular).lineSpacing(3)
                                }
                            }
                            if index == 0 { Rule().gridCellUnsizedAxes(.horizontal) }
                        }
                    }.padding(.vertical, 2)
                }
                }
                // In a chat, the reference's space between blocks, and less between two items of one list.
                .padding(.top, !chat || index == 0 ? 0 :
                            block.kind == .item && blocks[index - 1].kind == .item ? ChatStyle.itemSpacing : ChatStyle.blockSpacing)
            }
        }.font(step ? SetupMetrics.textFont : chat ? ChatStyle.font : FleetStyle.body).textSelection(.enabled)
            // A link's words in the link colour, which reads 4.5:1 and more (fix round 2): the accent drew them 3.4:1.
            .tint(FleetStyle.link)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A block of code in a message. **A line of code stays one line**: in a narrow window the block scrolls sideways
/// instead of breaking every row in two ("shipping step before 75.6% now 86.9%" at 960 pt).
///
/// **In a chat, a copy icon at its top right while the pointer is over it** (the owner's yes of 28 October 2026, D-7,
/// as Grok Bot and ChatGPT put one on their code): one click copies the code alone — Vps's `open https://…` without the
/// sentence around it — where the message's own Copy takes all of its words.
private struct CodeBlock: View {
    let text: String
    let chat: Bool
    /// The script of the door's card: a long line wraps, so its end is on screen (`MessageText.script`).
    var wraps = false
    @State private var hovered = false
    @State private var copied = false

    var body: some View {
        Group {
            if wraps {
                Text(verbatim: text).font(chat ? ChatStyle.code : FormMetrics.code).lineSpacing(chat ? 5 : 4)
                    .fixedSize(horizontal: false, vertical: true).padding(12)
            } else {
                ScrollView(.horizontal) {
                    Text(verbatim: text).font(chat ? ChatStyle.code : FormMetrics.code).lineSpacing(chat ? 5 : 4)
                        .fixedSize(horizontal: true, vertical: false).padding(12)
                }
                .sidewaysFade()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FleetStyle.surface, in: RoundedRectangle(cornerRadius: FormMetrics.inner))
        .overlay(alignment: .topTrailing) {
            if chat && !wraps {     // over a wrapped script, the icon would cover the end of its first row
                // A one-line block is 41 points high, so the 28-point icon 6 points in from its corner stands in its
                // middle; a longer block keeps it at its top.
                IconButton(symbol: copied ? "checkmark" : "square.on.square", words: String(l10n: "Copy code"), size: 12) {
                    copyMessage(text); copied = true
                }
                .padding(6)
                .opacity(hovered ? 1 : 0).allowsHitTesting(hovered)
                .accessibilityHidden(!hovered)
            }
        }
        .onHover { hovered = $0; if !$0 { copied = false } }
    }
}

extension View {
    /// **A block that scrolls sideways fades its edge while words stand past it** (fix round 2; the iPhone's code block,
    /// one look on both): over 16 points, at each edge that has more beyond it, so a line its edge cuts reads as one that
    /// goes on. A code block of a message and the first run's prompt block (a 960-point window cut both at their edge
    /// with no sign that they scroll). Put it on the scroll view itself, before its background.
    func sidewaysFade() -> some View { modifier(SidewaysFade()) }
}

private struct SidewaysFade: ViewModifier {
    /// The edges that have words past them now.
    @State private var hidden: Edge.Set = []

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Edge.Set.self) { geometry in
                var edges: Edge.Set = []
                if geometry.visibleRect.minX > 0.5 { edges.insert(.leading) }
                if geometry.visibleRect.maxX < geometry.contentSize.width - 0.5 { edges.insert(.trailing) }
                return edges
            } action: { _, edges in
                hidden = edges
            }
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: hidden.contains(.leading) ? 16 : 0)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: hidden.contains(.trailing) ? 16 : 0)
                }
            }
    }
}

struct OwnerBubble: View {
    let text: String
    /// The chat app that the owner sent the message from: its mark sits in the bubble's corner.
    var origin: MessageOrigin?
    /// What stands at the bubble's leading side, 8 points from it and centred on its last line, taking no height of
    /// its own: a message's hover footer (`SentMessageView`).
    var beside: AnyView?
    @State private var expanded = false
    private var canCollapse: Bool { text.count > 420 || text.filter { $0 == "\n" }.count > 5 }
    /// A long message at rest: the height of its first six lines, the last of them fading into the bubble.
    private static let foldedHeight = ChatStyle.line * 6 + ChatStyle.lineSpacing * 5

    var body: some View {
        let folded = canCollapse && !expanded
        BubbleLayout {
        VStack(alignment: .leading, spacing: 9) {
            // **His words are drawn from their Markdown, as an agent's are** (3 November 2026: "chat messages dont
            // have any format... it is so plain"): his numbered list, his paragraphs and his bold read as the reply
            // under them reads, where the literal text ran them all together.
            MessageText(text: text, chat: true).equatable()
                .frame(maxHeight: folded ? Self.foldedHeight : nil, alignment: .top)
                .mask {
                    VStack(spacing: 0) {
                        Color.black
                        if folded {
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: ChatStyle.line)
                        }
                    }
                }
            if canCollapse {
                // The click reaches over and under the words (`IconMetrics.reach`); the bubble keeps its size.
                Button { expanded.toggle() } label: {
                    Text(expanded ? "Show less" : "Show more").padding(.vertical, IconMetrics.reach).contentShape(Rectangle())
                }
                    .font(ChatStyle.detail).foregroundStyle(FleetStyle.muted).buttonStyle(.plain)
                    .padding(.vertical, -IconMetrics.reach)
            }
        }.padding(.horizontal, 16).padding(.vertical, 12)
            .background(ChatStyle.bubble, in: RoundedRectangle(cornerRadius: ChatStyle.bubbleRadius))
            .overlay(alignment: .bottomLeading) {
                if let origin {
                    ChatAppMark(app: origin.app, size: 18, help: String(l10n: "Sent from \(ChatApps.title(origin.app))")).offset(x: -7, y: 5)
                }
            }
            .overlay(alignment: .bottomLeading) {
                // **The guides stand on the overlay's own view, never inside an `if`** (fix round 2): SwiftUI drops a
                // guide set inside a condition, and the footer stood in the bubble's lower left corner, over its fill
                // and under his words, where these two guides put it 8 points left of the bubble.
                (beside ?? AnyView(EmptyView())).fixedSize()
                    .alignmentGuide(.leading) { $0[.trailing] + 8 }
                    // Its middle on the middle of the last line: the bubble's 12 points under it, then half a line.
                    .alignmentGuide(.bottom) { $0[VerticalAlignment.center] + 12 + ChatStyle.line / 2 }
            }
        }
    }
}

/// Propose a maximum width but keep the bubble's intrinsic width for short text: at the column's right edge, or at its
/// left for the other side of a chat that the owner only reads (`ReadBubble`).
struct BubbleLayout: Layout {
    var trailing = true

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? FleetStyle.readingWidth
        let size = subviews[0].sizeThatFits(.init(width: width * 0.74, height: nil))
        return CGSize(width: width, height: size.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: CGPoint(x: trailing ? bounds.maxX : bounds.minX, y: bounds.minY),
                          anchor: trailing ? .topTrailing : .topLeading,
                          proposal: .init(width: bounds.width * 0.74, height: nil))
    }
}

/// The time in a message footer: the time today, the weekday and time in the last week, else the date and time.
func messageTime(_ timestamp: Double) -> String {
    let date = Date(timeIntervalSince1970: timestamp), calendar = Calendar.current
    if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: Date())).day ?? 0
    return days > 0 && days < 7 ? date.formatted(.dateTime.weekday(.wide).hour().minute()) : date.formatted(date: .abbreviated, time: .shortened)
}

func copyMessage(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// One quiet icon action of a message footer, in a fixed frame so that the footer keeps its size. It is an icon
/// button like every other (`FleetIconButtonStyle`): the pointer fills the square behind the symbol, which is the
/// small square of an icon in a line of words (22 × 22) whatever the height of the line, and the click reaches 28 ×
/// 28. The square took the line's height and came out 22 × 15, 22 × 16 and 22 × 20 on one screen.
struct MessageAction: View {
    let symbol: String
    let label: String
    var help: String?
    /// The height the action takes in its line, which the line keeps.
    var height: CGFloat = 20
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(IconMetrics.symbol(height < 18 ? 10.5 : 12))
                .frame(width: IconMetrics.small, height: IconMetrics.small)
        }.buttonStyle(FleetIconButtonStyle(side: IconMetrics.small))
            .frame(width: IconMetrics.small, height: height)
            .help(help ?? label).accessibilityLabel(label)
    }
}

/// An agent's reply with its hover footer below it on the left: Copy, then its time when the hub reported one. The
/// footer has its own space in the reply, hidden until hover, so hover never resizes a message or moves the scroll.
/// The text keeps its own selection and menu.
struct AgentReply: View {
    /// The height of a reply's footer: the air above the icons and the row itself, regular in a chat, compact in a task
    /// thread. A stack of replies takes it from its spacing and gives it to its other rows, so the thread keeps its
    /// density.
    nonisolated static func footer(compact: Bool) -> CGFloat { compact ? 20 : 28 }
    let text: String
    let time: Double?
    var compact = false
    /// A line under the text that always shows: the delivery of a reply to a chat app.
    var detail: AnyView?
    @State private var hovered = false
    @State private var copied = false

    var body: some View {
        let row: CGFloat = compact ? 15 : 22
        // A detail line stays with the text. The icons take the rest of the footer as air above them: the reference
        // keeps its row clear of the last line, and a row under the text reads as a part of it.
        let gap: CGFloat = compact ? 5 : 4
        VStack(alignment: .leading, spacing: gap) {
            MessageText(text: text, chat: true).equatable()
            if let detail { detail }
            HStack(spacing: 10) {
                MessageAction(symbol: copied ? "checkmark" : "square.on.square", label: String(l10n: "Copy message"), height: row) {
                    copyMessage(text); copied = true
                }
                if let time { Text(messageTime(time)).help(fleetDate(time)) }
            }.font(ChatStyle.detail).foregroundStyle(FleetStyle.muted).frame(height: row)
                .padding(.top, Self.footer(compact: compact) - row - gap)
                .opacity(hovered ? 1 : 0).allowsHitTesting(hovered)
        }.contentShape(Rectangle()).onHover { hovered = $0; if !$0 { copied = false } }
    }
}
