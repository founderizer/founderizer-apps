import FleetCore
import SwiftUI

/// **The feedback box of a task's or a job's card** (design "Task details as a card over the page", part 2; the owner,
/// 21 November 2026: "Be able to give feedback on a task, probably reference it somehow (see the tagging thread) from
/// that same detail page!", and "Yes, build it" to its drawing). The chat's own capsule (`ComposerCapsule`): "+" for
/// files, "Give feedback…" in the field, and Send only while it can send, in the colour of the agent that it writes to,
/// as a chat's Send. Send makes one message of his in that agent's chat that names the task or the job (`about`), by the
/// chat's own send (`FleetStore.sendFeedback`): its outbox, its receipt, its "not sent" line (`PendingBar`). The card
/// shows it where the task takes no guidance, and at the job level, and only where its rule names an agent
/// (`HubState.feedback(onTask:)`, `feedback(onJob:)`) on a hub that takes `about`. Its words and its files are kept by
/// what the message is about (`FleetStore.feedbackDrafts`), so they stay through a change of the card's level and a
/// close of the card. Its place in the card is the caller's: the task level puts it in the column of prose. **A key
/// in it waits for his choice, as in the chat's composer** (`KeyHoldBanner`): one that he pastes is not pasted, and one
/// that he types holds Send, until he saves it as a secret or keeps it.
struct FeedbackBox: View {
    @Bindable var store: FleetStore
    let feedback: Feedback
    /// The capsule's whole surface gives its field the cursor (`ComposerCapsule`).
    @FocusState private var focused: Bool
    /// He chose "Keep it" or "Paste it anyway" for the key in these words: no second question while it is in them.
    @State private var keyAllowed = false

    /// The box's key in the store, for its words, its files and the guard of a key.
    private var key: String { FleetStore.stageKey(about: feedback.about, database: store.state?.db ?? "") }
    /// Its words: nothing while they are his message on its way, as the chat's field does (`WordsOnTheirWay.field`).
    private var text: String { WordsOnTheirWay.field(store.feedbackDrafts[key] ?? "", sending: store.feedbackOnItsWay(feedback)) }

    var body: some View {
        let words = Binding(get: { text }, set: { store.feedbackDrafts[key] = $0.isEmpty ? nil : $0 })
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = store.readyFiles(for: key)
        let canSend = store.canWrite && store.canChat(with: feedback.recipient) && !store.filesAreWaiting(for: key)
            && trimmed.count <= 16_000 && (!trimmed.isEmpty || !files.isEmpty)
        return ComposerCapsule(focus: $focused) {
            // The files that wait, and what is wrong with the text or a file, over the line, as in the chat's composer.
            StagedFilesStrip(store: store, composer: key)
            if let held = store.heldKey, held.composer == key {
                KeyHoldBanner(hold: held.hold, agent: feedback.recipient) { saveHeldKey(held, words: words) } goOn: {
                    keepHeldKey(held, words: words)
                }
            }
            if trimmed.count > 16_000 { Text("Use no more than \(16_000.formatted()) characters.").font(ChatStyle.detail).foregroundStyle(.orange) }
            if let line = store.fileError(for: key) {
                Text(line).font(ChatStyle.detail).foregroundStyle(.orange).help(store.fileCause(for: key) ?? "")
            }
        } line: {
            if store.supportsAttachments { AttachFilesButton(store: store, composer: key) }
            TextField("Give feedback…", text: words, axis: .vertical)
                .focused($focused)
                .accessibilityIdentifier("feedback-text")
                // The same keys as the chat composer: Return sends, Shift+Return makes a new line.
                .onKeyPress(keys: [.return], phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    guard canSend else { return .handled }
                    send()
                    return .handled
                }
                .composerField(alone: !store.supportsAttachments)
                .onChange(of: text) { _, now in heldKeyCheck(now) }
            SendSlot(shows: canSend) {
                Button { send() } label: { SendMark(agent: feedback.recipient) }
                    .buttonStyle(FleetIconButtonStyle(filled: true)).keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSend)
                    .accessibilityLabel("Send feedback")
                    .accessibilityIdentifier("feedback-send")
            }
        }
        .pasteAttachments(store: store, composer: focused ? key : nil)
        .keyPasteGuard(store: store, composer: focused && SecretEntryView.isOffered(by: store) ? key : nil)
        .stageDroppedFiles(store: store, composer: key)
        // A refused login text empties every draft, as it empties a task's guidance box.
        .onChange(of: store.secretRefusals) { _, _ in store.feedbackDrafts[key] = nil }
        .onChange(of: key) { _, _ in keyAllowed = false }
        // The question of a key goes with the box, so no other box waits behind it.
        .onDisappear { if store.heldKey?.composer == key { store.heldKey = nil } }
    }

    /// Sends his feedback, unless it holds what looks like a key that he did not choose to keep.
    private func send() {
        if SecretEntryView.isOffered(by: store) && !keyAllowed && KeyInText.contains(text) {
            store.heldKey = HeldKey(composer: key, hold: .text)
            return
        }
        let feedback = feedback
        Task { await store.sendFeedback(feedback) }
    }

    /// Words that hold a key, however they came in, get the question once; words without one end it.
    private func heldKeyCheck(_ now: String) {
        guard SecretEntryView.isOffered(by: store) else { return }
        if !KeyInText.contains(now) {
            keyAllowed = false
            if store.heldKey == HeldKey(composer: key, hold: .text) { store.heldKey = nil }
        } else if !keyAllowed && store.heldKey == nil {
            store.heldKey = HeldKey(composer: key, hold: .text)
        }
    }

    /// "Save it as a secret": the key goes into the secure form over the card and out of his words, and the agent that
    /// gets the feedback gets the secret's name in its chat. A paste reads the clipboard again now.
    private func saveHeldKey(_ held: HeldKey, words: Binding<String>) {
        store.heldKey = nil
        var cut: String?
        if held.hold == .paste { cut = KeyCut.onClipboard() }
        else if let split = KeyCut.split(words.wrappedValue) { words.wrappedValue = split.rest; cut = split.key }
        store.secretForm = SecretPreset(tell: feedback.recipient, key: cut, kept: SecretValueKept())
    }

    /// "Paste it anyway" or "Keep it": his choice, and no second question while the key is in his words.
    private func keepHeldKey(_ held: HeldKey, words: Binding<String>) {
        store.heldKey = nil
        keyAllowed = true
        if held.hold == .paste, let pasted = NSPasteboard.general.string(forType: .string) { words.wrappedValue += pasted }
    }
}

/// **His feedback on a task or a job, in its card** (design part 2): each message of his that names it
/// (`HubState.messages(aboutTask:)`, `messages(aboutJob:)`), oldest first, as the chat draws his message: his bubble,
/// and his files under it, or his files alone; under it the agent's words that answer it (`HubState.replies(to:)`), each
/// with its files, and the row of the work that it began (`ChatAskLine`), which opens that task in the card. **His
/// message stands from the frame he sends it** (`WordsOnTheirWay`), and the hub's copy takes its place, under the
/// same id. At the task level their words are selected as the thread's are (`selection`). The chat's own row views;
/// no read of the hub of its own.
struct FeedbackRows: View {
    @Bindable var store: FleetStore
    let messages: [OwnerMessage]
    let state: HubState
    /// The card's feedback, whose message on its way these rows draw, or nil where the card has no box.
    let feedback: Feedback?
    /// The message of it that the card saw go (`keepsFeedbackSent`).
    let sent: PendingRequest?
    /// The thread's selection, at the task level; nil at the job level.
    let selection: ChatSelection?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// His message on its way, until the reading holds the hub's copy; words of files alone come with that copy, as
    /// in the chat (`ManagerView.drawn`).
    private var going: PendingRequest? {
        feedback.flatMap { store.feedbackOnItsWay($0, kept: sent) }.flatMap { $0.text.isEmpty ? nil : $0 }
    }

    var body: some View {
        let going = going
        let drawn = messages + [going].compactMap { $0 }.map { OwnerMessage(onItsWay: $0) }
        // **The names in his words are badges, as in his chat** (`MessageText.chatNames`): the chat's one book, read
        // once for the rows. No badge of the task or the job over his words: the card is that task or that job.
        let book = store.chatNames
        ForEach(drawn) { message in
            VStack(alignment: .leading, spacing: ChatStyle.blockSpacing) {
                // As the chat's row of his message (`SentMessageView`): no empty bubble over files alone, and a
                // correction, which is about what its message is about (`FleetStore.sendEdit`), says so over it.
                VStack(alignment: .trailing, spacing: 6) {
                    if message.replaces_request_id != nil {
                        Text("Correction").font(ChatStyle.detail).foregroundStyle(FleetStyle.muted)
                    }
                    if !message.text.isEmpty { OwnerBubble(text: message.text, origin: message.origin, names: book) }
                    if let files = message.attachments, !files.isEmpty {
                        MessageFilesView(store: store, files: files).padding(.top, message.text.isEmpty ? 0 : 6)
                    }
                }.selectable(in: selection, row: "feedback-message-\(message.id)")
                ForEach(state.replies(to: message)) { report in
                    AgentReply(text: report.text, time: report.created, compact: true, detail: files(of: report))
                        .selectable(in: selection, row: "feedback-report-\(report.id)")
                }
                if let ask = store.asks.first(where: { $0.id.caseInsensitiveCompare(message.request_id) == .orderedSame }) {
                    ChatAskLine(store: store, row: ChatAskRow(ask, agent: message.chatRecipient, state: state))
                }
            }
            // A name's badge in his words opens what it names in this window, as in his chat (`openCardLink`): the
            // card's window has no such action of its own, and the Mac's would look for an app of the badge's link.
            .environment(\.openURL, OpenURLAction { store.openCardLink($0) })
            .environment(\.cardServerSymbols, store.chatServerSymbols)
            // No group of its own and no identifier on the stack: a group with no label is one more level for
            // VoiceOver, and an identifier on a stack stands on each element in it. His words, his files and the
            // answer stand in the thread's order, as the chat's rows do.
            // **His message comes up from the box**, as the chat's from its composer (`AnyTransition.sentMessage`):
            // only the one that he sends now, never a message of the reading.
            .transition(!reduceMotion && going.map { $0.requestID.uuidString.lowercased() == message.request_id } == true
                        ? .sentMessage : .identity)
        }
    }

    /// The agent's files under its words, as the chat draws them (`ManagerView.reportDetail`).
    private func files(of report: ManagerReport) -> AnyView? {
        guard let files = report.attachments, !files.isEmpty else { return nil }
        return AnyView(MessageFilesView(store: store, files: files, alignment: .leading, keeps: false)
            .padding(.top, report.text.isEmpty ? 0 : 8))
    }
}

extension FleetStore {
    /// **His feedback on its way**: his message to the feedback's agent on its way (`messageOnItsWay`) when it names
    /// what the card names, or `kept`, the one that a card saw go, once the hub confirmed it.
    func feedbackOnItsWay(_ feedback: Feedback, kept: PendingRequest? = nil) -> PendingRequest? {
        messageOnItsWay(to: feedback.recipient, kept: kept).flatMap { $0.about == feedback.about ? $0 : nil }
    }
}

extension View {
    /// **Keeps in `sent` his feedback that a card saw go**, from the frame it goes until the reading that holds the hub's
    /// copy, as a chat keeps its own (`ManagerView.sent`): the store lets the request go with its receipt, a round trip
    /// before that reading, and his bubble would leave the card for that round trip.
    func keepsFeedbackSent(_ sent: Binding<PendingRequest?>, store: FleetStore, feedback: Feedback?) -> some View {
        onChange(of: store.pending?.requestID, initial: true) { _, _ in
            if let feedback, let request = store.feedbackOnItsWay(feedback) { sent.wrappedValue = request }
        }
    }
}

private extension View {
    /// The rows' words selected as the thread's are, where the card gives a selection.
    @ViewBuilder func selectable(in selection: ChatSelection?, row: String) -> some View {
        if let selection { wordsSelectable(in: selection, row: row) } else { self }
    }
}

/// **The badge of the task or the job that his message is about, over his words in the agent's chat** (design "Task
/// details as a card over the page", part 2; the owner, 21 November 2026, "Yes, build it" to its drawing): the mark of
/// where it stands, as the board draws it (`StandingMarkView`), and its title on one line, cut at its end, in the look
/// of a name's badge in the chat: the card's fill, edge and corner (`CardBadge.draw`), violet because a press opens it,
/// and a little more of both under the pointer. **It is a plain button** with the hand of a link, as "Show more" of the
/// bubble is: no field of selectable words lies over it, and it takes Tab and Space with Full Keyboard Access, as every
/// other press of a chat's row; an AppKit press view (`BadgePress`) stands only over a text's words, in the row under
/// the pointer, because one in every such message would cost each frame of a scroll. A press opens the card over the
/// chat at the task, or at the whole job (`HubState.badge(about:jobs:)`), and the pointer on a task's badge reads that
/// task's thread first, as every opener of a task does (`opensTask`). For a task or a job that the reading has no more: the
/// hub's title alone, with no mark and no press, and the same fill and edge with no colour, because violet is what he
/// can press. It is never wider than a bubble can be, and a short message's bubble grows to hold it. **VoiceOver reads
/// it as one button**, its title and where it stands, and its own action opens the card: an element of
/// `.accessibilityElement(children: .ignore)` with no action of its own does not answer VoiceOver's press (the fault of
/// a job's task rows, 21 November 2026). `alone`: the badge of a message of files alone, which stands over them at the
/// column's trailing side, as a bubble does (`BubbleLayout`).
struct AboutBadgeView: View {
    let store: FleetStore
    let message: OwnerMessage
    var alone = false
    /// The pointer is on it: its fill and its edge are a little stronger.
    @State private var hovered = false

    var body: some View {
        if let about = message.about, let badge = store.aboutBadge(about) {
            if alone { BubbleLayout(trailing: true) { drawn(badge) } } else { drawn(badge) }
        }
    }

    @ViewBuilder private func drawn(_ badge: AboutBadge) -> some View {
        if let standing = badge.standing {
            let open = { store.show(standing.opens) }
            Button(action: open) { pill(badge.title, mark: standing.mark) }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .onHover { hovered = $0 }
                .modifier(OpensItsTask(store: store, task: standing.opens.task))
                // a badge that goes takes its hover with it: the pointer may have left it
                .onDisappear { hovered = false }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel([badge.title, standing.words].joined(separator: ", "))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default, open)
                .accessibilityIdentifier("message-about-\(message.id)")
        } else {
            // its words are static text: it opens nothing
            pill(badge.title, mark: nil)
        }
    }

    /// The pill: the mark where it has one, then the title, on the badge's fill and edge, in grey where it does not
    /// press.
    private func pill(_ title: String, mark: StandingMark?) -> some View {
        let presses = mark != nil, over = hovered
        return HStack(spacing: 5) {
            if let mark { StandingMarkView(mark: mark, size: Self.mark, store: store).accessibilityHidden(true) }
            Text(title).font(ChatStyle.font).foregroundStyle(presses ? FleetStyle.link : FleetStyle.text).lineLimit(1)
        }
        .padding(.leading, 5).padding(.trailing, 7).padding(.vertical, 2)
        .background {
            Canvas { context, size in
                if !presses { context.addFilter(.grayscale(1)) }
                CardBadge.draw(CGRect(origin: .zero, size: size), over: over, room: nil, at: nil, in: &context) { _, _ in }
            }
        }
        // the press and the hover reach the whole pill, its edge too
        .contentShape(Rectangle())
    }

    /// The size of its mark, under the chat's words of 14 points, as a name's badge has its icon.
    private static let mark: CGFloat = 12
}

