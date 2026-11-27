import AppKit
import FleetCore
import SwiftUI

/// Markdown is display-only: a copy of selected words takes what shows, which is an agent's name and its role where its
/// words named it by its whole role (`RoleNames`); Copy message takes the words as they were written. Checked files use
/// literal Text instead.
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
    /// The text stands on a card (a request's card in a chat): a code block is a well in the canvas's colour there,
    /// because the fill of a code block is the card's own fill.
    var card = false
    /// The block of a hand step's command that has Run (owner feature `need_run`): the code block whose text is its
    /// command, and no other, shows Run (`NeedRunTarget`).
    var run: NeedRunTarget? = nil
    /// **The names that a request's words link** (`CardNames`; the lane "Give on a card"): an agent, a repository, a
    /// server and a page of the app, where a card draws the words. A chat's message takes `chatNames` instead.
    var names: CardNames? = nil
    /// **Each value that the agent put in inline code is a chip with a copy icon** (`CardValueText`; the owner's "Yes,
    /// as drawn" of 21 November 2026): only in the reason, the task, the steps and the details of a request's card and
    /// of the request at hand on Needs you. Inline code everywhere else keeps its flat fill.
    var values = false
    /// **The names that a chat's message draws as badges** (`AgentReply`, `OwnerBubble`; the owner, 20 November 2026:
    /// "ok but use always the agent badges and icons!!"): the card's names by the chat's stricter rules (`ChatNames`),
    /// drawn with the words in every row and pressed in the row under the pointer (`chatBadges`). A table's cells keep
    /// their words, and so does every text with none: a task's thread and a conversation he reads.
    var chatNames: ChatNames? = nil
    /// **His @ tags in these words** (owner feature `agent_tags`; `OwnerBubble`): with `chatNames`, each tag is its
    /// agent's badge over its whole range, "@" included (`ChatNames.pieces`). Their places are in his text, which the
    /// blocks take from it with a mark for each tag (`AgentTags.marked`).
    var mentions: [AgentTags.Mention]? = nil
    /// **The owner's own words keep a role as he wrote it** (`OwnerBubble`; `RoleNames.Written`): an agent's words draw
    /// its name there.
    var asWritten = false
    /// **Each block of the text, and each cell of a table, is a row of this selection** (a long file in the knowledge
    /// reader): only the row under the pointer and the row whose words he pressed last can be selected, as only two
    /// rows of a chat can (`ChatSelection`), and a block or a cell longer than `keepsFields` can always be selected.
    /// Nil: each block takes the selection of the view around it.
    var selection: ChatSelection? = nil
    /// **Where a fold cuts the words**, from their top: a long message at rest (`OwnerBubble`) or a long result
    /// (`TaskResult`) draws its words whole under a frame of this height, hidden under the cut. A link under the cut has
    /// no press (`linkPresses`), so neither the hand nor a press stands in the room under the fold, where the next rows
    /// are. **Folded words cannot be selected** (`FoldedWords`): the selection field lies over the whole text, so its
    /// I-beam stood under the fold too, over Show more and the rows below; Show more opens them, selectable as before.
    /// Their links keep their presses above the cut, as words with no field do. A folded text takes no `selection`: its
    /// blocks would set their own selection inside `FoldedWords`, and their fields would come back under the fold.
    var fold: CGFloat? = nil
    /// **The room before the words of the first block, when it is a paragraph**: what stands at the start of his words
    /// on their first line (the badges of the skills that he gave, `OwnerBubble`) lies over it. A kern on a no-break
    /// space before the words, so that the line's other words and the next lines wrap as before; 0 for no room.
    var lead: CGFloat = 0
    /// **A block or a cell of more than this many bytes (UTF-8) keeps its fields** in a text with a selection (a
    /// block's Markdown, a cell's words): making or dropping the field of a block took about 4 ms for each 1,000
    /// characters (266 to 295 ms for a block of 70,089, as a Word, RTF or PDF file comes in: its paragraphs end with
    /// one line break, so the whole file can be one block), and a pointer that comes and goes would pay that each time.
    /// Without a selection, every block keeps its fields, and the file paid it once.
    private static let keepsFields = 2_000
    /// Code in a line of a step's words: a little under the words' 15 points, as the chat's code is under its 14.
    private static let stepCode = Font.system(size: 13.5, design: .monospaced)

    /// One block as the text draws it (not private: its test reads the blocks).
    struct Block {
        let kind: MessageBlock.Kind
        let text: String
        var marker = ""
        /// A list item's depth (`MessageBlock.level`).
        var level = 0
        var formatted = AttributedString()
        /// The rows of a table, the header first.
        var cells: [[AttributedString]] = []
        /// Its words, or a cell of its table, have a link (`LinkRun`).
        var links = false
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
    /// The text's blocks, read once for each form of it: the cache keys his own words apart (`asWritten`), so that
    /// his bubble and an agent's reply with the same words never share a reading.
    var blocks: [Block] {
        // his tags, only where the chat draws badges: the text with a mark for each (`AgentTags.marked`); a list,
        // also an empty one, says that only its entries are tags (`AgentTags.Given`)
        let given = chatNames != nil && mentions != nil
        let marked = given ? mentions.flatMap { AgentTags.marked(text, mentions: $0) } : nil
        // The inline code of the chat is larger, so the two forms of one text have their own entries.
        let key = ((step ? "step\u{0}" : chat ? "chat\u{0}" : "form\u{0}") + (given ? "given\u{0}" : "")
                   + (asWritten ? "written\u{0}" : "") + (marked?.key ?? text)) as NSString
        if let cached = Self.cache.object(forKey: key) { return cached.blocks }
        let parsed = Self.parse(text, code: step ? Self.stepCode : chat ? ChatStyle.code : FormMetrics.code, marked: marked,
                                given: given, asWritten: asWritten)
        Self.cache.setObject(Parsed(parsed), forKey: key, cost: text.utf8.count * 4)
        return parsed
    }
    /// The blocks of a text by the rules both apps share (`MessageBlock`, FleetCore), with their inline marks drawn in
    /// this app's fonts. `marked`: the text with the marks of its tags, which each block's words give back as "@" and
    /// as the tag's words (`AgentTags.unmarked`).
    private static func parse(_ text: String, code: Font, marked: AgentTags.Marked? = nil, given: Bool = false,
                              asWritten: Bool = false) -> [Block] {
        MessageBlock.parse(marked?.text ?? text).map { block in
            let words = marked.map { AgentTags.unmarked(block.text, by: $0) } ?? block.text
            var drawn = Block(kind: block.kind, text: words, marker: block.marker, level: block.level)
            switch block.kind {
            case .code, .rule: break
            case .table:
                drawn.cells = block.cells.map { row in
                    row.map { cell in inline(marked.map { AgentTags.unmarked(cell, by: $0) } ?? cell, code: code) }
                }
                drawn.links = drawn.cells.contains { $0.contains(where: LinkRun.has) }
            default:
                drawn.formatted = inline(block.text, code: code)
                if let marked { drawn.formatted = AgentTags.unmarked(drawn.formatted, by: marked) }
                if given {
                    var mark = AttributeContainer()
                    mark[AgentTags.Given.self] = true
                    drawn.formatted.mergeAttributes(mark)
                }
                if asWritten { drawn.formatted = RoleNames.written(drawn.formatted) }
                drawn.links = LinkRun.has(drawn.formatted)
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

    /// The words stand under a fold now (`fold`).
    private var folded: Bool { fold != nil }

    /// A block's words with the names of `names` as links, an agent and a server as a badge (`CardBadgeText`), or as
    /// they are. The size is the words' own: a step's, the chat's (`ChatStyle.font`) or a form's (`FleetStyle.body`).
    /// Each link of the words is a piece of its own, which `linkPresses` gives the hand (`LinkRun`). In a chat's message,
    /// the chat's book reads the words once (`ChatNames.words`), and `badges` are where its names stand, for their
    /// drawing (`chatBadges`). **The text is the same in every row**: the pointer that comes onto the message or leaves
    /// it makes none of its texts again (`ChatBadges`).
    private func linked(_ block: Block, room: CGFloat = 0) -> (text: Text, badges: [ChatBadgeMap.Entry], lead: CGFloat) {
        let size = step ? SetupMetrics.text : chat ? ChatStyle.size : FleetStyle.bodySize
        var formatted = block.formatted
        if room > 0 {
            var before = AttributedString("\u{00A0}")
            before.swiftUI.kern = room
            formatted = before + formatted
        }
        guard let chatNames else {
            return (CardBadgeText.text(formatted, names: names, size: size, values: values), [], 0)
        }
        return ChatBadgeText.text(chatNames.words(formatted), links: block.links, size: size)
    }

    var body: some View {
        let blocks = blocks, lines = chat ? ChatStyle.lineSpacing : 5
        // owner feature need_run: the first block of the command has Run, and no second one
        let runs = run.flatMap { run in blocks.firstIndex { $0.kind == .code && $0.text == run.command } }
        // a request's values, by block: their chips, their presses and VoiceOver's actions on the block's words
        // (`cardValues`)
        let valued = blocks.map { values ? CardValues.values(in: $0.formatted, names: names) : [] }
        VStack(alignment: .leading, spacing: chat ? 0 : 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                Group {
                switch block.kind {
                case .paragraph:
                    let words = linked(block, room: index == 0 ? lead : 0)
                    ChatBadgeText.led(words.text, lead: words.lead).lineSpacing(lines).selectableWords()
                        .chatBadges(words.badges, block: index, lead: words.lead, fold: fold)
                        .linkPresses(block.links, fold: fold, always: folded).cardValues(valued[index])
                case .heading:
                    let words = linked(block)
                    ChatBadgeText.led(words.text, lead: words.lead)
                        .font(step ? Font.system(size: SetupMetrics.text, weight: .semibold) : chat ? ChatStyle.heading : FormMetrics.title)
                        .selectableWords().chatBadges(words.badges, block: index, lead: words.lead, fold: fold)
                        .linkPresses(block.links, fold: fold, always: folded).cardValues(valued[index])
                        .padding(.top, chat ? 0 : 3)
                case .item:
                    // An item under another starts its mark where that item's words start: the mark's 12 and the 9
                    // after it, for each level.
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text(block.marker).selectableWords().frame(minWidth: 12, alignment: .trailing)
                        let words = linked(block)
                        ChatBadgeText.led(words.text, lead: words.lead).lineSpacing(lines).selectableWords()
                            .chatBadges(words.badges, block: index, lead: words.lead, fold: fold)
                            .linkPresses(block.links, fold: fold, always: folded).cardValues(valued[index])
                    }.padding(.leading, 3 + CGFloat(block.level) * 21)
                case .quote:
                    HStack(spacing: 10) {
                        Rectangle().fill(FleetStyle.muted.opacity(0.4)).frame(width: 2)
                        let words = linked(block)
                        ChatBadgeText.led(words.text, lead: words.lead).foregroundStyle(FleetStyle.muted).lineSpacing(lines)
                            .selectableWords().chatBadges(words.badges, block: index, lead: words.lead, fold: fold)
                            .linkPresses(block.links, fold: fold, always: folded).cardValues(valued[index])
                    }
                case .code: CodeBlock(text: block.text, font: chat ? ChatStyle.code : step && !script ? Self.stepCode : FormMetrics.code,
                                      spacing: chat ? 5 : 4, fill: card ? FleetStyle.canvas : FleetStyle.surface,
                                      wraps: script, copies: (chat || step) && !script, run: index == runs ? run : nil)
                case .rule: Rule().padding(.vertical, 4)
                case .table:
                    Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 7) {
                        ForEach(Array(block.cells.enumerated()), id: \.offset) { line, row in
                            GridRow {
                                ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                                    // a cell's links have their press; its names stay words, as they were
                                    CardBadgeText.text(cell, names: nil, size: FleetStyle.bodySize)
                                        .fontWeight(line == 0 ? .medium : .regular).lineSpacing(3)
                                        .selectableWords().linkPresses(block.links && LinkRun.has(cell), fold: fold, always: folded)
                                        // A table can be long: each of its cells is a row of the selection.
                                        .modifier(BlockWords(selection: selection.flatMap {
                                            String(cell.characters).utf8.count > Self.keepsFields ? nil : $0
                                        }, row: "block-\(index)-\(line)-\(column)"))
                                }
                            }
                            if line == 0 { Rule().gridCellUnsizedAxes(.horizontal) }
                        }
                    }.padding(.vertical, 2)
                }
                }
                // In a chat, the reference's space between blocks, and less between two items of one list.
                .padding(.top, !chat || index == 0 ? 0 :
                            block.kind == .item && blocks[index - 1].kind == .item ? ChatStyle.itemSpacing : ChatStyle.blockSpacing)
                .modifier(BlockWords(selection: block.kind == .table || block.text.utf8.count > Self.keepsFields ? nil
                                        : selection, row: "block-\(index)"))
            }
        }
        .modifier(FoldedWords(folded: folded))
        // the fold of a long message is measured from here (`fold`)
        .coordinateSpace(.named(LinkPresses.space))
        .modifier(TextPointer(selection: selection))
        // an agent and a server in a card's words are badges, which a press opens (`CardBadges`); each block lays the
        // presses of its own links, where its words can be selected
        .cardBadges(names != nil, links: false)
        // a chat's badges: one canvas behind them and one view with their presses, in the row under the pointer
        .chatBadgeLayer(chatNames != nil, fold: fold)
        .font(step ? SetupMetrics.textFont : chat ? ChatStyle.font : FleetStyle.body)
            // A link's words in the link colour, which reads 4.5:1 and more (fix round 2): the accent drew them 3.4:1.
            .tint(FleetStyle.link)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension EnvironmentValues {
    /// Whether the words of a message (`MessageText`) can be selected here: everywhere, and in a chat, a thread, a
    /// conversation he reads and a knowledge file only in the row under the pointer and the row whose words he pressed
    /// last (`ChatSelection`).
    @Entry var messageWordsSelectable = true
}

extension View {
    /// **Each text takes the selection itself**, where `messageWordsSelectable` says so: a change gives or takes the
    /// selection of each text and makes nothing else of the row again, so a code block keeps the place that he
    /// scrolled it to sideways, and its copy icon its state. A text that he can select in a long scroll view (a
    /// message, a thread's step, a conversation he reads, a knowledge file) takes it so, in place of
    /// `.textSelection(.enabled)`.
    func selectableWords() -> some View { modifier(SelectableWords()) }
}

/// The words of a folded text cannot be selected (`MessageText.fold`); else as the view around them says.
private struct FoldedWords: ViewModifier {
    let folded: Bool
    @Environment(\.messageWordsSelectable) private var selectable

    func body(content: Content) -> some View {
        // a chat's badges keep their presses above the fold (`chatBadges`)
        content.environment(\.messageWordsSelectable, selectable && !folded).environment(\.messageRowLive, selectable)
    }
}

/// A text's selection where `messageWordsSelectable` says so. The modifier reads the value itself, so a message whose
/// words did not change (`MessageText` is equatable) still follows it.
private struct SelectableWords: ViewModifier {
    @Environment(\.messageWordsSelectable) private var selectable

    func body(content: Content) -> some View {
        if selectable { content.textSelection(.enabled) } else { content }
    }
}

/// A block of a text, or a cell of its table, as a row of the text's selection (`MessageText.selection`): its words can
/// be selected while the selection says so, and it tells the selection where it stands in the text, for the text's one
/// hover (`TextPointer`). Without a selection, as it was.
private struct BlockWords: ViewModifier {
    let selection: ChatSelection?
    let row: String

    func body(content: Content) -> some View {
        if let selection {
            content
                .environment(\.messageWordsSelectable, selection.flag(row).on)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(TextPointer.space)) } action: {
                    selection.place(row, at: $0)
                }
                .onDisappear { selection.place(row, at: nil) }
        } else {
            content
        }
    }
}

/// The one hover of a text whose blocks are rows of a selection (`ChatSelection.pointer(at:)`): the row under the
/// pointer is the one whose place holds it.
private struct TextPointer: ViewModifier {
    static let space = "MessageText.rows"
    let selection: ChatSelection?

    func body(content: Content) -> some View {
        if let selection {
            content
                .coordinateSpace(.named(Self.space))
                // The whole text, also the room in a row where nothing is drawn (an item's indent, the space after its
                // mark, beside a quote's bar): a hover that ended there would take the row's fields and give them back.
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let point): selection.pointer(at: point)
                    case .ended: selection.pointer(at: nil)
                    }
                }
                // A hover does not end when its view goes (the editor takes the text's place): no row of it is under
                // the pointer then.
                .onDisappear { selection.pointer(at: nil) }
        } else {
            content
        }
    }
}

/// A block of code in a message. **A line of code stays one line**: in a narrow window the block scrolls sideways
/// instead of breaking every row in two ("shipping step before 75.6% now 86.9%" at 960 pt).
///
/// **In a chat, a copy icon at its top right while the pointer is over it** (the owner's yes of 28 October 2026, D-7,
/// as Grok Bot and ChatGPT put one on their code): one click copies the code alone — Vps's `open https://…` without the
/// sentence around it — where the message's own Copy takes all of its words. **A request at hand on Needs you has the
/// same icon** (the owner, 15 November 2026, of a request's task: "formatted like the chat messages (links, code
/// format etc)"): the command of his task is what he copies there.
private struct CodeBlock: View {
    let text: String
    /// The code's font where it stands: a chat's, a step's or a form's.
    let font: Font
    let spacing: CGFloat
    /// What it is filled with: the surface on the canvas, and the canvas on a card (`MessageText.card`).
    var fill = FleetStyle.surface
    /// The script of the door's card: a long line wraps, so its end is on screen (`MessageText.script`).
    var wraps = false
    /// The copy icon shows under the pointer. Never over a wrapped script, where it would cover the end of its first
    /// row.
    var copies = false
    /// **The command of a hand step that has Run** (owner feature `need_run`, the owner's "Yes, as drawn" of 16 November
    /// 2026): Run stands at the block's right, always, with the copy icon beside it under the pointer, and the line of
    /// a run that did not reach its Mac stands under the block. Only the block whose text is the command has it. **Its
    /// command wraps, and Run stands beside it, never over it**, as the door's card wraps its script: every character
    /// that Run runs is on screen, also the end of a long line (the review of 16 November 2026: a block that scrolled
    /// sideways under Run could hide a second command at its end).
    var run: NeedRunTarget? = nil
    @State private var hovered = false
    @State private var copied = false

    private var runs: Bool { run?.command == text && !wraps }

    var body: some View {
        if runs, let run {
            VStack(alignment: .leading, spacing: 6) {
                block
                NeedRunLine(target: run)
            }
        } else {
            block
        }
    }

    private var copyIcon: some View {
        // A one-line block is 41 points high, so the 28-point icon 6 points in from its corner stands in its middle; a
        // longer block keeps it at its top.
        IconButton(symbol: copied ? "checkmark" : "square.on.square", words: String(l10n: "Copy code"), size: 12) {
            copyMessage(text); copied = true
        }
        .opacity(hovered ? 1 : 0).allowsHitTesting(hovered)
        .accessibilityHidden(!hovered)
    }

    private var block: some View {
        Group {
            if runs, let run {
                HStack(alignment: .center, spacing: 6) {
                    Text(verbatim: text).font(font).lineSpacing(spacing).selectableWords()
                        .fixedSize(horizontal: false, vertical: true).padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if copies { copyIcon }
                    NeedRunButton(target: run)
                }
                .padding(.leading, 12).padding(.trailing, 6)
            } else if wraps {
                Text(verbatim: text).font(font).lineSpacing(spacing).selectableWords()
                    .fixedSize(horizontal: false, vertical: true).padding(12)
            } else {
                ScrollView(.horizontal) {
                    Text(verbatim: text).font(font).lineSpacing(spacing).selectableWords()
                        .fixedSize(horizontal: true, vertical: false).padding(12)
                }
                .sidewaysFade()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: FormMetrics.inner))
        .overlay(alignment: .topTrailing) {
            if copies && !wraps && !runs { copyIcon.padding(6) }
        }
        .modifier(CopyIconHover(copies: copies, hovered: $hovered, copied: $copied))
    }
}

/// The pointer's hover on a block of code that shows its copy icon under the pointer. A block with no icon (the
/// knowledge reader's) has no hover: each hover costs time at each frame of a scroll under the pointer.
private struct CopyIconHover: ViewModifier {
    let copies: Bool
    @Binding var hovered: Bool
    @Binding var copied: Bool

    func body(content: Content) -> some View {
        if copies { content.onHover { hovered = $0; if !$0 { copied = false } } } else { content }
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
    /// **Somebody else's words**, at the column's left in the bubble's outline and not in its fill, as the other side
    /// of a chat that he only reads stands (`ReadBubble`): the filled bubble is always his own words. A task that an
    /// agent asked for opens with that agent's request so (`TaskRequest`).
    var theirs = false
    /// **Whose hand sent these words** (owner feature `message_hands`, `OwnerHand`): words that another hand sent for
    /// him stand in the bubble's outline, still at the right, and an AI session's have its mark in the bubble's lower
    /// left corner, where a chat app's mark goes (`AISessionMark`; the owner's "B, go ahead" of 24 November 2026).
    var hand: OwnerHand.Look = .his
    /// The names that his words draw as badges, in an agent's chat (`MessageText.chatNames`).
    var names: ChatNames? = nil
    /// What stands over his words, 6 points over them, inside the bubble and above its fold: the badge of the task or
    /// the job that the message is about (`SentMessageView`, `AboutBadgeView`).
    var over: AnyView? = nil
    /// **The names of the skills that he gave with these words** (owner feature `message_skills`): each its badge with
    /// the bolt (`SkillBadge`), as his picture drew it, at the start of his words on their first line, with a space
    /// after it, and the whole bubble of a gift with no words. Over his words where they do not begin with a paragraph
    /// (a list, a heading, code) or where the badges would fill most of a line.
    var gifts: [String] = []
    /// His @ tags in these words, each its agent's badge (`MessageText.mentions`).
    var mentions: [AgentTags.Mention]? = nil
    @State private var expanded = false
    private var canCollapse: Bool { text.count > 420 || text.filter { $0 == "\n" }.count > 5 }
    /// A long message at rest: the height of its first six lines, the last of them fading into the bubble.
    private static let foldedHeight = ChatStyle.line * 6 + ChatStyle.lineSpacing * 5
    /// The widest that the gifts' badges stand on the line of his words.
    private static let giftsInLineMost: CGFloat = 320

    /// The room of the gifts' badges before his words on their first line, or nil where they stand over his words.
    private var giftsRoom: CGFloat? {
        guard !gifts.isEmpty, !text.isEmpty, MessageBlock.parse(text).first?.kind == .paragraph else { return nil }
        let width = SkillBadge.width(of: gifts)
        return width <= Self.giftsInLineMost ? width : nil
    }

    private var giftBadges: some View {
        HStack(spacing: SkillBadge.spacing) {
            ForEach(Array(gifts.enumerated()), id: \.offset) { _, name in SkillBadge(name: name) }
        }.fixedSize()
    }

    var body: some View {
        let folded = canCollapse && !expanded, room = giftsRoom
        BubbleLayout(trailing: !theirs) {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 6) {
            if let over { over }
            if !gifts.isEmpty, room == nil { giftBadges }
            // **His words are drawn from their Markdown, as an agent's are** (3 November 2026: "chat messages dont
            // have any format... it is so plain"): his numbered list, his paragraphs and his bold read as the reply
            // under them reads, where the literal text ran them all together.
            if !text.isEmpty {
                MessageText(text: text, chat: true, chatNames: names, mentions: mentions, asWritten: !theirs,
                            fold: folded ? Self.foldedHeight : nil, lead: room ?? 0)
                    .equatable()
                    .frame(maxHeight: folded ? Self.foldedHeight : nil, alignment: .top)
                    .mask {
                        VStack(spacing: 0) {
                            Color.black
                            if folded {
                                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: ChatStyle.line)
                            }
                        }
                        // A badge's edge reaches over the first line and under the last (`CardBadge.bleed`): the mask cut
                        // it. Not under a fold, which still ends where it fades.
                        .padding(names == nil ? EdgeInsets()
                                 : EdgeInsets(top: -CardBadge.bleed, leading: -CardBadge.bleed,
                                              bottom: folded ? 0 : -CardBadge.bleed, trailing: -CardBadge.bleed))
                    }
                    // the gifts' badges in the room before his words, their middle on the middle of the first line
                    .overlay(alignment: .topLeading) {
                        if room != nil {
                            giftBadges.alignmentGuide(.top) { $0[VerticalAlignment.center] - ChatStyle.line / 2 }
                                .allowsHitTesting(false)
                        }
                    }
            }
            }
            if canCollapse {
                // The click reaches over and under the words (`IconMetrics.reach`); the bubble keeps its size.
                Button { expanded.toggle() } label: {
                    Text(expanded ? "Show less" : "Show more").padding(.vertical, IconMetrics.reach).contentShape(Rectangle())
                }
                    .font(ChatStyle.detail).foregroundStyle(FleetStyle.muted).buttonStyle(.plain)
                    // the hand under the pointer, as a link shows it, over all that a click reaches: before the padding
                    // that gives the reach back to the layout
                    .pointerStyle(.link)
                    .padding(.vertical, -IconMetrics.reach)
            }
        }.padding(.horizontal, 16).padding(.vertical, 12)
            .background {
                let shape = RoundedRectangle(cornerRadius: ChatStyle.bubbleRadius)
                if theirs || hand.outlined {
                    shape.strokeBorder(FleetStyle.hairline(0.16), lineWidth: 1)
                } else {
                    shape.fill(ChatStyle.bubble)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let origin {
                    ChatAppMark(app: origin.app, size: ChatAppMark.onBubble,
                                help: String(l10n: "Sent from \(ChatApps.title(origin.app))"))
                        .offset(ChatAppMark.corner)
                } else if let mark = hand.mark {
                    AISessionMark(runtime: mark).offset(ChatAppMark.corner)
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

/// **A skill that he gave the agent with his message** (owner feature `message_skills`; his yes of 21 November 2026 to the
/// skill's badge with the bolt, and of 22 November to the given skill): the name badge of a card's words (`CardBadge`),
/// with the skill's mark (`CardBadgeIcon.skill`) in the room before the skill's name, at the start of his words. It opens
/// nothing, as his picture drew it (a badge with no press): the app has no page of a skill.
struct SkillBadge: View {
    let name: String

    /// Between two badges of one message.
    static let spacing: CGFloat = 4

    /// **The width of these badges side by side, as the words of a chat measure them**: the room of the icon
    /// (`ChatBadgeText.room`), each name in the chat's font, and the end of each badge. The room before his words
    /// (`MessageText.lead`) is this, and the no-break space before them is the space after the last badge.
    static func width(of names: [String]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: ChatStyle.size)
        let badges = names.map { name in
            ChatBadgeText.room(ChatStyle.size) + (name as NSString).size(withAttributes: [.font: font]).width
                + ChatStyle.size * CardBadgeText.end
        }
        return badges.reduce(0, +) + spacing * CGFloat(max(names.count - 1, 0))
    }

    var body: some View {
        let room = ChatBadgeText.room(ChatStyle.size)
        Text(name).font(ChatStyle.font).foregroundStyle(FleetStyle.link).lineLimit(1).truncationMode(.middle)
            .padding(.leading, room).padding(.trailing, ChatStyle.size * CardBadgeText.end).padding(.vertical, 1)
            .background {
                Canvas { context, size in
                    // as a name's badge in the words: its room before the name, and the icon in it (`CardBadge.icon`)
                    let frame = CGRect(origin: .zero, size: size)
                    let place = CardBadge.icon(room: CGRect(x: 0, y: 0, width: room, height: size.height), frame: frame)
                    CardBadge.draw(frame, over: false, room: .symbol(CardBadgeIcon.skillSymbol), at: place,
                                   in: &context) { _, _ in }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(name)
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

/// **The time under the pointer, in a message's footer: how long ago** (the owner, 15 November 2026, with the hover row
/// of the Claude desktop chat, "2 minutes ago": "apply the style of the hover time (relative too)"), in the app's own
/// words of an age (`activityAge`: "Just now", "5 min ago", "3 h ago", "2 days ago", then the date). It was the clock
/// time. The exact date and time are its hover (`fleetDate`). It is read when the footer shows, by this Mac's clock.
func messageAge(_ timestamp: Double) -> String { activityAge(timestamp, now: Date().timeIntervalSince1970) }

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

/// An agent's reply with its hover footer below it on the left: Copy, then how long ago it came (`messageAge`), in a
/// chat under the last reply of a run only (`lastOfRun`), and there on the hover of any reply of the run (`run`). The
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
    /// False for a reply with another reply of its run right under it (`ChatPart.endsReplies`): it keeps the room of
    /// the footer, so the chat's gaps stay, and shows nothing there on hover.
    var lastOfRun = true
    /// In an agent's chat, this reply's place in its run: the pointer on any reply of the run shows the footer under its
    /// last one (`ReplyRunHover`). Nil in a task thread, where each reply has a hover of its own.
    var run: ReplyRunHover.Place?
    /// The names that its words draw as badges, in an agent's chat (`MessageText.chatNames`).
    var names: ChatNames? = nil
    @State private var hovered = false
    @State private var copied = false

    var body: some View {
        let row: CGFloat = compact ? 15 : 22
        // A detail line stays with the text. The icons take the rest of the footer as air above them: the reference
        // keeps its row clear of the last line, and a row under the text reads as a part of it.
        let gap: CGFloat = compact ? 5 : 4
        // Only the reply that shows the footer reads its run's hover, so a change draws that reply again and no other.
        let shown = lastOfRun && (run?.shown ?? hovered)
        VStack(alignment: .leading, spacing: gap) {
            MessageText(text: text, chat: true, chatNames: names).equatable()
            if let detail { detail }
            if lastOfRun {
                HStack(spacing: 10) {
                    MessageAction(symbol: copied ? "checkmark" : "square.on.square", label: String(l10n: "Copy message"), height: row) {
                        copyMessage(text); copied = true
                    }
                    if let time { Text(messageAge(time)).help(fleetDate(time)) }
                }.font(ChatStyle.detail).foregroundStyle(FleetStyle.muted).frame(height: row)
                    .padding(.top, Self.footer(compact: compact) - row - gap)
                    .opacity(shown ? 1 : 0).allowsHitTesting(shown)
            } else {
                Color.clear.frame(height: Self.footer(compact: compact) - gap)
            }
        }.contentShape(Rectangle()).onHover { inside in
            if let run { run.hover(inside: inside) } else { hovered = inside }
        }
        .onChange(of: shown) { _, now in if !now { copied = false } }
        // A reply that goes while the pointer is on it leaves no run that shows its footer to nobody.
        .onDisappear { run?.hover(inside: false) }
    }
}

/// **The replies of a run in an agent's chat share one hover** (`ChatRunHover` in FleetCore says why): the pointer on
/// any of them shows Copy and the age under the last one. Each run has a flag of its own, which only its last reply
/// reads, so a change draws that reply again and not the chat.
@MainActor final class ReplyRunHover {
    @MainActor @Observable final class Flag {
        fileprivate(set) var on = false
    }

    /// A reply's place in its run (`ChatPart.replyRuns`): it tells the run its hover, and its footer reads the run's.
    @MainActor struct Place {
        fileprivate let runs: ReplyRunHover
        fileprivate let row: String
        fileprivate let run: String
        /// The pointer is on a reply of this run.
        var shown: Bool { runs.flag(run).on }
        func hover(inside: Bool) { runs.hover(row, run: run, inside: inside) }
    }

    private var rule = ChatRunHover()
    private var flags: [String: Flag] = [:]

    /// The place of the reply `row` in the run `run`.
    func place(row: String, run: String) -> Place { Place(runs: self, row: row, run: run) }

    private func flag(_ run: String) -> Flag {
        if let flag = flags[run] { return flag }
        let flag = Flag()
        flag.on = rule.run == run
        flags[run] = flag
        return flag
    }

    private func hover(_ row: String, run: String, inside: Bool) {
        let before = rule.run
        rule.hover(row, run: run, inside: inside)
        guard rule.run != before else { return }
        if let before { flags[before]?.on = false }
        if let now = rule.run { flags[now]?.on = true }
    }
}
