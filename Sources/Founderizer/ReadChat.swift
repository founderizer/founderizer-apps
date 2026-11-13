import FleetCore
import SwiftUI

/// Who said a message of a chat that the owner reads: the name over a run of bubbles, with its mark.
enum ReadChatSpeaker: Equatable {
    case agent(String)
    case person(String)

    var name: String {
        switch self {
        case .agent(let agent): People.agentWord(agent)
        case .person(let name): name
        }
    }
}

/// One message in a bubble: at the right when the agent of the page said it (`ours`), else at the left.
struct ReadChatMessage {
    let id: String
    let ours: Bool
    let who: ReadChatSpeaker
    let text: String
    /// An agent's words to another agent are drawn from their Markdown, as in its chat; the words of a conversation with
    /// a person stay plain text, as the chat app carried them.
    let markdown: Bool
    let created: Double?
    /// What stands under the bubble and always shows: how a reply was delivered, or that a person's message waits.
    var under: AnyView? = nil
}

/// One line in the middle of the chat, between its bubbles, in the look of its time stamps: what the agent asked the
/// owner and what he answered, which the other side of the chat never sees.
struct ReadChatNote {
    let id: String
    let created: Double?
    let symbol: String
    let who: String
    let state: (words: String, attention: Bool)?
    let text: String
}

/// One entry of a chat that the owner reads and does not write in (`ReadChat`).
enum ReadChatEntry: Identifiable {
    case message(ReadChatMessage)
    case note(ReadChatNote)

    var id: String {
        switch self {
        case .message(let message): message.id
        case .note(let note): note.id
        }
    }

    var created: Double? {
        switch self {
        case .message(let message): message.created
        case .note(let note): note.created
        }
    }
}

/// **A conversation that the owner reads, drawn as a chat** (the owner, 6 November 2026: "it needs to look like a
/// chat", and his yes to its mockup the same day; the look of the inbox of his other product, where he reads a buyer's
/// conversation with his store): the agent of the page at the right and the other side at the left, both in bubbles,
/// with the speaker's name over each run of its messages, the day and the time in the middle when an hour or a day lies
/// between two messages (`ChatStamp`), and the newest at the bottom, where the chat opens.
///
/// **Both sides have a bubble** because the bubble at the right of the agent's own chat is always his words: here a
/// filled one is the agent of the page and an outlined one the other side, and a name says whose run it is. **No
/// composer and no Pause of its own**: he reads what the two sides wrote. The time and Copy of a message are on hover,
/// beside its bubble, as in his own chat.
struct ReadChat: View {
    let entries: [ReadChatEntry]
    /// What stands under the newest entry: the reading's own line.
    var footer: AnyView? = nil
    @State private var followsLatest = true

    /// Between two runs of messages, and over a line in the middle.
    private static let runGap: CGFloat = 18
    /// Between two bubbles of one run.
    private static let bubbleGap: CGFloat = 6

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        let previous = index > 0 ? entries[index - 1] : nil
                        let stamp = entry.created.flatMap { ChatStamp.time($0, after: previous?.created) }
                        if let stamp { ChatStamp(time: stamp).padding(.top, previous == nil ? 0 : Self.runGap) }
                        row(entry, after: stamp == nil ? previous : nil, first: previous == nil || stamp != nil)
                            .accessibilityIdentifier("chat-item-\(entry.id)")
                    }
                    footer
                    Color.clear.frame(height: 1).id("latest")
                }
                .padding(.bottom, FleetSpace.bottom)
                .threadRows(top: FleetSpace.block)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // What scrolls up fades under the name over it instead of being cut by it, as an agent's chat fades under its
            // pill (`topFade`).
            .topFade(24)
            .onScrollPhaseChange { oldPhase, phase, context in
                if phase == .interacting || phase == .tracking { followsLatest = false }
                else if phase == .idle && oldPhase != .animating {
                    followsLatest = context.geometry.contentSize.height - context.geometry.visibleRect.maxY < 100
                }
            }
            // A message that comes while he reads the newest stands under it, and the chat follows it there.
            .onChange(of: entries.last?.id) { _, _ in
                if followsLatest { proxy.scrollTo("latest", anchor: .bottom) }
            }
        }
    }

    /// An entry under the one before it: a bubble of the same speaker's run closes up under it, a new run starts with
    /// its speaker's name, and a line in the middle stands on its own.
    @ViewBuilder private func row(_ entry: ReadChatEntry, after previous: ReadChatEntry?, first: Bool) -> some View {
        switch entry {
        case .message(let message):
            let sameRun: Bool = if case .message(let before) = previous { before.who == message.who && before.ours == message.ours } else { false }
            VStack(alignment: message.ours ? .trailing : .leading, spacing: 5) {
                if !sameRun { speaker(message) }
                ReadBubble(message: message)
            }
            .padding(.top, sameRun ? Self.bubbleGap : first ? 0 : Self.runGap)
        case .note(let note):
            noteLine(note).padding(.top, first ? 0 : Self.runGap)
        }
    }

    /// The name over a run, with its mark beside it on the run's own side.
    private func speaker(_ message: ReadChatMessage) -> some View {
        HStack(spacing: 6) {
            if !message.ours { mark(message.who) }
            Text(message.who.name).lineLimit(1)
            if message.ours { mark(message.who) }
        }
        .font(ChatStyle.detail).foregroundStyle(FleetStyle.muted)
        .frame(maxWidth: .infinity, alignment: message.ours ? .trailing : .leading)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private func mark(_ who: ReadChatSpeaker) -> some View {
        switch who {
        case .agent(let agent): AgentGlyph(name: agent, size: GlyphSize.inline)
        case .person: Image(systemName: "person.crop.circle").font(IconMetrics.symbol(13)).accessibilityHidden(true)
        }
    }

    /// What the agent asked the owner, or what he answered: in the middle, in the stamps' size, with its state where it
    /// waits for him. Its whole text is on hover.
    private func noteLine(_ note: ReadChatNote) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: note.symbol).font(IconMetrics.symbol(11)).accessibilityHidden(true)
                Text(note.who)
                if let state = note.state {
                    Text(state.words).foregroundStyle(state.attention ? Color.orange : FleetStyle.muted)
                }
            }
            if !note.text.isEmpty {
                Text(verbatim: note.text).lineLimit(3).multilineTextAlignment(.center).textSelection(.enabled)
            }
        }
        .font(ChatStyle.detail).foregroundStyle(FleetStyle.muted)
        .frame(maxWidth: .infinity)
        .help(note.text)
        .accessibilityElement(children: .combine)
    }
}

/// One message of a `ReadChat` in its bubble, with its time and Copy beside it on hover, on its last line and taking no
/// height, as the owner's own message has them (`OwnerBubble`); what stands under it always shows.
struct ReadBubble: View {
    let message: ReadChatMessage
    @State private var hovered = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: message.ours ? .trailing : .leading, spacing: 4) {
            BubbleLayout(trailing: message.ours) {
                words
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background {
                        // The agent of the page in the fill of the owner's own bubble, the other side in its outline.
                        let shape = RoundedRectangle(cornerRadius: ChatStyle.bubbleRadius)
                        if message.ours { shape.fill(ChatStyle.bubble) } else { shape.strokeBorder(FleetStyle.hairline(0.16), lineWidth: 1) }
                    }
                    .overlay(alignment: message.ours ? .bottomLeading : .bottomTrailing) {
                        footer.fixedSize()
                            .alignmentGuide(.leading) { $0[.trailing] + 8 }
                            .alignmentGuide(.trailing) { $0[.leading] - 8 }
                            // Its middle on the middle of the last line: the bubble's 12 points under it, then half a line.
                            .alignmentGuide(.bottom) { $0[VerticalAlignment.center] + 12 + ChatStyle.line / 2 }
                    }
            }
            if let under = message.under {
                under.frame(maxWidth: .infinity, alignment: message.ours ? .trailing : .leading)
            }
        }
        .contentShape(Rectangle()).onHover { hovered = $0; if !$0 { copied = false } }
        .contextMenu {
            Button("Copy message", systemImage: "square.on.square") { copyMessage(message.text) }.labelStyle(.titleAndIcon)
        }
    }

    @ViewBuilder private var words: some View {
        if message.markdown {
            MessageText(text: message.text, chat: true).equatable()
        } else {
            Text(verbatim: message.text).font(ChatStyle.font).lineSpacing(ChatStyle.lineSpacing)
                .foregroundStyle(FleetStyle.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Its time and Copy, under the pointer only: Copy next to the bubble on either side.
    private var footer: some View {
        HStack(spacing: 10) {
            if message.ours { time }
            MessageAction(symbol: copied ? "checkmark" : "square.on.square", label: String(l10n: "Copy message")) {
                copyMessage(message.text); copied = true
            }
            if !message.ours { time }
        }
        .font(ChatStyle.detail).foregroundStyle(FleetStyle.muted).frame(height: 20)
        .opacity(hovered ? 1 : 0).allowsHitTesting(hovered).accessibilityHidden(!hovered)
    }

    @ViewBuilder private var time: some View {
        if let created = message.created { Text(messageTime(created)).help(fleetDate(created)) }
    }
}

/// **A chat that the owner reads, under its name, with the way back over the name**: the name and the back link stand
/// where every page has its own, with the page's actions at the right, and they stay while the chat under them scrolls,
/// because a name that scrolls out of reach is no name. The chat stands in the column of prose (`ReadChat`).
struct ReadChatPage<Actions: View, Chat: View>: View {
    let title: String
    let back: FleetBack
    @ViewBuilder var actions: Actions
    @ViewBuilder var chat: Chat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title) { actions }
                .frame(maxWidth: FormMetrics.formWidth, alignment: .leading)
                .padding(.top, FleetSpace.top)
                .overlay(alignment: .topLeading) { back.padding(.top, FleetSpace.back) }
                .fleetColumn()
            chat.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}
