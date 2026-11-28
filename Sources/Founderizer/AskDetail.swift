import FleetCore
import SwiftUI

/// **One ask of his, open in the card over the window** (owner feature `ask_follow_ups`; the owner's "Yes, this" of 25
/// November 2026 to round 2 of `my-asks-tracking-2026-11-25`, the picture `r3-mac-open.png`): what he asked, the
/// answers and the work in order, in one place, and the chat field of its agent at the end.
///
/// From the top: its mark and its name with the close button; the agents in it, each with its glyph; the orange bar of
/// the request that waits for him, whose Answer opens that request on Needs you; then by day his messages as bubbles at
/// the right with their time beside them, each answer at the left under its agent's glyph, name and time, and under an
/// answer the rows of the work that his message began (a task's mark, its title, its agent and its time, as a task's
/// row of a job card on the board), which open that task in the same card, over this ask; and at the end
/// "Message <agent>", the chat's own field, whose message goes on with this ask for sure (`AskComposer`). His follow-ups
/// stand on it as he wrote them: the card says no word of a join. The card reads the ask from the hub when it opens and
/// again when its row moves (`GET /ui/mobile/asks/<id>`): the Mac's window of messages holds about three days. Opening it marks
/// its newest answer as seen (`AskSeen`).
struct AskDetail: View {
    @Bindable var store: FleetStore
    /// The request id of the ask's first message.
    let id: String
    let state: HubState
    @State private var card: AskCard?
    /// Why the card could not be read, while it has no card.
    @State private var failure: String?
    /// His message that this card saw go, until the card that the hub reads holds it.
    @State private var sent: PendingRequest?
    @AppStorage(AskSeen.key, store: AppDefaults.store) private var seenWords = ""

    /// The card's size where the window has room for it: the picture's column, and the task level's height.
    static let size = CGSize(width: 720, height: TaskDetail.size.height)

    /// Its row of his list, as this reading has it.
    private var row: AskedRow? { store.askedByMe?.rows.first { $0.id.caseInsensitiveCompare(id) == .orderedSame } }
    /// The agent of its chat field: the one that he asked first.
    private var agent: String { card?.asked ?? row?.agent ?? state.managerName }
    /// **What reads the card again**: another hub or generation, a move of its row (a message of his, an answer), and a
    /// task that comes or goes, which the row's time does not move.
    private var readKey: String {
        "\(store.hub.absoluteString)|\(state.db)|\(id)|\(row?.moved ?? 0)|\((row?.tasks.map(\.id) ?? []).sorted())"
    }

    var body: some View {
        let row = self.row
        VStack(alignment: .leading, spacing: 0) {
            head(row)
            if let need = row?.request.flatMap({ request in store.openNeeds.first { $0.id == request } }) { needBar(need) }
            // **The field follows the last line, and the lines scroll when they are more than the card holds**, so the
            // field stays at the card's foot then.
            ViewThatFits(in: .vertical) {
                VStack(alignment: .leading, spacing: 0) { conversation; composer }
                VStack(alignment: .leading, spacing: 0) {
                    ScrollView { conversation }.defaultScrollAnchor(.bottom)
                    composer
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, FleetSpace.under)
        .task(id: readKey) { await read() }
        .onChange(of: row?.answered, initial: true) { _, answered in seen(answered) }
        .onChange(of: store.pending?.requestID, initial: true) { _, _ in
            if let request = store.pending, request.ask?.caseInsensitiveCompare(id) == .orderedSame { sent = request }
        }
    }

    /// Its mark and its name, the close button, and the agents in it.
    private func head(_ row: AskedRow?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 11) {
                if let row { AskedMark(row: row, size: 17, store: store).accessibilityHidden(true) }
                Text(row?.name ?? card?.name ?? "").font(ChatStyle.heading).foregroundStyle(FleetStyle.text)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                // Esc closes it, also while the cursor is in its field (`fleetModal`'s card: a button's key goes first).
                Button { store.closeDetail() } label: {
                    Image(systemName: "xmark").font(IconMetrics.symbol(13, weight: .semibold)).foregroundStyle(FleetStyle.muted)
                }
                .buttonStyle(FleetIconButtonStyle()).keyboardShortcut(.cancelAction)
                .help("Close").accessibilityLabel("Close").accessibilityIdentifier("detail-done")
            }
            let agents = card?.agents ?? row.map { [$0.agent] } ?? []
            HStack(spacing: 6) {
                ForEach(Array(agents.enumerated()), id: \.element) { index, name in
                    if index > 0 { Text(verbatim: "·") }
                    AgentGlyph(name: name, size: 14, dot: false)
                    Text(name.agentLabel).lineLimit(1)
                }
            }
            .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).padding(.leading, row == nil ? 0 : 28)
            .accessibilityElement(children: .combine)
        }
    }

    /// **The orange bar of the request that waits for him**: its title, and Answer, which opens it on Needs you.
    private func needBar(_ need: OwnerNeed) -> some View {
        Button { store.selectedNeed = need.id; store.destination = .needs } label: {
            HStack(spacing: 10) {
                Image(systemName: "hand.raised.fill").font(IconMetrics.symbol(15))
                Text(need.shownTitle).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 12)
                HStack(spacing: 4) {
                    Text("Answer").fontWeight(.semibold)
                    Image(systemName: "chevron.right").font(IconMetrics.symbol(10, weight: .semibold))
                }
            }
            .font(FormMetrics.text).foregroundStyle(.orange)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: FormMetrics.inner))
            .overlay(RoundedRectangle(cornerRadius: FormMetrics.inner).strokeBorder(Color.orange.opacity(0.28), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: FormMetrics.inner))
        }
        .buttonStyle(.plain).pointerStyle(.link).padding(.top, 14)
        .help("Open this request on Needs you").accessibilityIdentifier("ask-request-\(need.id)")
    }

    /// His messages, the answers and the work, by day (`AskCard.lines`), and his message on its way at the end.
    private var conversation: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let card {
                ForEach(card.lines()) { line in self.line(line) }
            } else if let failure {
                Text(failure).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
            }
            if let going, !going.text.isEmpty {
                OwnerBubble(text: going.text, beside: AnyView(stamp(going.created)))
            }
        }
        .padding(.top, 10).padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func line(_ line: AskCard.Line) -> some View {
        switch line {
        case .day(let time):
            Text(Self.day(time)).font(ChatStyle.detail).foregroundStyle(FleetStyle.muted)
                .frame(maxWidth: .infinity, alignment: .center).padding(.top, 6)
                .accessibilityAddTraits(.isHeader)
        case .mine(let message):
            VStack(alignment: .trailing, spacing: 6) {
                // a correction is marked as the chat marks it (`SentMessageView`)
                if message.replaces_request_id != nil {
                    Text("Correction").font(ChatStyle.detail).foregroundStyle(FleetStyle.muted)
                }
                if !message.text.isEmpty { OwnerBubble(text: message.text, beside: AnyView(stamp(message.created))) }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .reply(let report):
            answer(from: report.speaker, at: report.created, text: report.text)
        case .result(let head):
            answer(from: head.owner, at: head.time, text: head.plainWords ?? "")
        case .work(_, let heads):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(heads) { head in taskRow(head) }
            }
            .padding(.leading, 12)
            .overlay(alignment: .leading) { Rectangle().fill(FleetStyle.hairline(0.10)).frame(width: 1) }
            .padding(.leading, 30)
        }
    }

    /// An agent's words at the left: its glyph, its name and the time, and the words (an answer, or what a task came to).
    private func answer(from agent: String, at time: Double, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            AgentGlyph(name: agent, size: 20, dot: false).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "\(agent.agentLabel) · \(Self.clock(time))")
                    .font(ChatStyle.detail).foregroundStyle(FleetStyle.muted)
                MessageText(text: text, chat: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    /// The time beside his bubble.
    private func stamp(_ time: Double) -> some View {
        Text(Self.clock(time)).font(ChatStyle.detail).foregroundStyle(FleetStyle.muted).help(fleetDate(time))
    }

    /// **One task of the work, as a task's row of a job card** (`JobCard`): its mark, its title, and its agent with the
    /// time it came into its state; one that waits for him has the orange hand, its title in orange and "Waits for
    /// you". It opens the task level in this card, over the ask, while the reading has the task.
    private func taskRow(_ head: AskCard.TaskHead) -> some View {
        let task = state.tasks.first { $0.id == head.id }
        let waits = task.flatMap { state.ownerWaits(of: [$0])[$0.id] } != nil
        let ended = task?.isTerminal ?? head.isTerminal
        let when = Self.short(task?.stateSince ?? head.time, now: state.time)
        let open = { store.show(.task(head.id), inCard: true) }
        return Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                taskMark(head, task: task, waits: waits).frame(width: 16).accessibilityHidden(true)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                Text(head.title).font(FormMetrics.text).lineLimit(1)
                    .foregroundStyle(waits ? Color.orange : ended ? FleetStyle.muted : FleetStyle.text)
                Spacer(minLength: 6)
                if waits {
                    Text("Waits for you").foregroundStyle(.orange).lineLimit(1).fixedSize()
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        AgentGlyph(name: head.owner, size: GlyphSize.inline, dot: false)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                        Text(head.owner.agentLabel).lineLimit(1)
                        Text(verbatim: "·")
                        Text(when).monospacedDigit().lineLimit(1).fixedSize()
                    }.foregroundStyle(FleetStyle.muted).layoutPriority(1)
                }
            }
            .font(FormMetrics.detail)
            .frame(minHeight: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(task == nil)
        .help(Text(verbatim: "\(head.title)\n\(head.owner.agentLabel) · \(when)"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([head.title, head.owner.agentLabel, waits ? String(l10n: "Waits for you") : nil, when]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, open)
        .accessibilityIdentifier("ask-task-\(head.id)")
    }

    /// A task's mark as the board draws it (`FleetTask.mark`); for a task that this reading no longer holds, the mark of
    /// how its head ended.
    @ViewBuilder private func taskMark(_ head: AskCard.TaskHead, task: FleetTask?, waits: Bool) -> some View {
        if waits {
            Image(systemName: "hand.raised.fill").font(IconMetrics.symbol(Self.mark)).foregroundStyle(.orange)
        } else if let task {
            let mark = task.mark(in: state)
            if mark.inWork && store.isFresh { WorkMark(size: Self.mark, moves: store.marksMove) }
            else { Image(systemName: mark.symbol).font(IconMetrics.symbol(Self.mark)).foregroundStyle(task.tint(in: state).color) }
        } else {
            let checked = head.state == "completed" && head.accepted == 1
            let failed = ["failed", "rejected"].contains(head.state) || (head.state == "completed" && head.accepted == 0)
            Image(systemName: checked ? "checkmark.circle.fill" : failed ? "exclamationmark.circle.fill" : "circle")
                .font(IconMetrics.symbol(Self.mark))
                .foregroundStyle(checked ? FleetTask.MarkTint.checked.color : failed ? FleetTask.MarkTint.failed.color : FleetStyle.muted)
        }
    }

    /// The size of a task's mark, as in a job card.
    private static let mark: CGFloat = 13

    /// The chat field of its agent, under the last line.
    private var composer: some View {
        AskComposer(store: store, ask: id, agent: agent).padding(.top, 4)
    }

    /// **His message from this card on its way**, until the card that the hub reads holds it: the request in the
    /// outbox, then the hub's copy in the reading.
    private var going: (text: String, created: Double)? {
        let held = Set(card?.messages.map { $0.request_id.lowercased() } ?? [])
        if let request = store.messageOnItsWay(to: agent, kept: sent), request.ask?.caseInsensitiveCompare(id) == .orderedSame,
           !held.contains(request.requestID.uuidString.lowercased()) {
            return (request.text, request.createdAt.timeIntervalSince1970)
        }
        if let sent, !held.contains(sent.requestID.uuidString.lowercased()),
           let copy = state.messages.first(where: { $0.request_id.caseInsensitiveCompare(sent.requestID.uuidString) == .orderedSame }) {
            return (copy.text, copy.created)
        }
        return nil
    }

    /// One read of the card; a card of another hub or generation, or one that came after this view left, is dropped.
    private func read() async {
        let hub = store.hub, database = state.db, asked = id
        do {
            let fresh = try await HubClient().askCard(hub: hub, database: database, id: asked)
            guard !Task.isCancelled, store.hub == hub, store.state?.db == database else { return }
            card = fresh
            failure = nil
        } catch {
            guard !Task.isCancelled, card == nil else { return }
            // a refusal says its own words; an answer of another shape, the app's; no answer at all, nothing here,
            // because the window's notice says it
            var unreadable = error is DecodingError
            if case HubError.invalidResponse = error { unreadable = true }
            failure = HubError.said(error) ?? (unreadable ? String(l10n: "Your hub answered something this app could not read.") : nil)
        }
    }

    /// He opened the card: its newest answer is seen, and its name is no longer semibold in his list.
    private func seen(_ answered: Double?) {
        guard let answered, let list = store.askedByMe, let row else { return }
        var marks = AskSeen(words: seenWords)
        marks.note(row.id, answered: answered, db: state.db, keep: Set(list.rows.map(\.id)))
        if marks.words != seenWords { seenWords = marks.words }
    }

    /// A day of the card, as the chat's stamp says it: Today, Yesterday, a weekday within the week, else the date.
    static func day(_ time: Double, calendar: Calendar = .current) -> String {
        let date = Date(timeIntervalSince1970: time)
        if calendar.isDateInToday(date) { return String(l10n: "Today") }
        if calendar.isDateInYesterday(date) { return String(l10n: "Yesterday") }
        if let weekBack = calendar.date(byAdding: .day, value: -6, to: .now), date > weekBack {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// A time of the card's day, under its day's line.
    static func clock(_ time: Double) -> String {
        Date(timeIntervalSince1970: time).formatted(date: .omitted, time: .shortened)
    }

    /// **A past time in few characters**, as a coming time is written (`fleetComingTime`): the time today, the weekday
    /// within the week, else the day and month.
    static func short(_ time: Double, now: Double, calendar: Calendar = .current) -> String {
        let date = Date(timeIntervalSince1970: time)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: Date(timeIntervalSince1970: now))).day ?? 0
        if days <= 0 { return date.formatted(date: .omitted, time: .shortened) }
        if days < 7 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// **The chat field of an ask's card** (`AskDetail`): the chat's own capsule (`ComposerCapsule`), "Message <agent>" in
/// the field, and Send in the agent's colour only while it can send, as in the agent's chat. **Words only**: the
/// picture r3 that he said yes to has no "+" for files and a skill, so neither a paste nor a drop of files stages one
/// here (the Mac validator, 26 November 2026); files go in the agent's chat.
/// Send makes one message of his in that agent's chat that goes on with this ask for sure (`ask`), by the chat's own
/// send (`FleetStore.sendAsk`): its outbox, its receipt, its "not sent" line. **Its words, its files, their errors and
/// its skills are its own** (`FleetStore.stageKey(ask:)`, `askDrafts`), never the agent's chat draft (the Chat and
/// files area, 25 November 2026). A key in it waits for his choice, as in the chat's composer (`KeyHoldBanner`).
struct AskComposer: View {
    @Bindable var store: FleetStore
    /// The request id of the ask's first message.
    let ask: String
    /// The agent that he asked first, which the field writes to.
    let agent: String
    @FocusState private var focused: Bool
    /// He chose "Keep it" or "Paste it anyway" for the key in these words: no second question while it is in them.
    @State private var keyAllowed = false

    /// The field's key in the store, for its words, its files and the guard of a key.
    private var key: String { FleetStore.stageKey(ask: ask) }
    /// His message from this field on its way.
    private var onItsWay: PendingRequest? {
        store.messageOnItsWay(to: agent).flatMap { $0.ask?.caseInsensitiveCompare(ask) == .orderedSame ? $0 : nil }
    }
    /// Its words: nothing while they are his message on its way, as the chat's field does (`WordsOnTheirWay.field`).
    private var text: String { WordsOnTheirWay.field(store.askDrafts[key] ?? "", sending: onItsWay) }

    var body: some View {
        let words = Binding(get: { text }, set: { store.askDrafts[key] = $0.isEmpty ? nil : $0 })
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let reaches = store.canChat(with: agent)
        let canSend = store.canWrite && reaches && trimmed.count <= 16_000 && !trimmed.isEmpty
        return ComposerCapsule(focus: $focused) {
            // What is wrong with the text, over the line, as in the chat's composer.
            if let held = store.heldKey, held.composer == key {
                KeyHoldBanner(hold: held.hold, agent: agent) { saveHeldKey(held, words: words) } goOn: {
                    keepHeldKey(held, words: words)
                }
            }
            if trimmed.count > 16_000 { Text("Use no more than \(16_000.formatted()) characters.").font(ChatStyle.detail).foregroundStyle(.orange) }
        } line: {
            TextField("Message \(agent.agentLabel)", text: words, axis: .vertical)
                .disabled(!reaches)
                .focused($focused)
                .accessibilityIdentifier("ask-message")
                // The same keys as the chat composer: Return sends, Shift+Return makes a new line.
                .onKeyPress(keys: [.return], phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    guard canSend else { return .handled }
                    send()
                    return .handled
                }
                .composerField(alone: true)
                .onChange(of: text) { _, now in heldKeyCheck(now) }
            SendSlot(shows: canSend) {
                Button { send() } label: { SendMark(agent: agent) }
                    .buttonStyle(FleetIconButtonStyle(filled: true)).keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSend)
                    .help("Send this message to \(agent.agentLabel)")
                    .accessibilityLabel("Send message")
                    .accessibilityIdentifier("ask-send")
            }
        }
        .keyPasteGuard(store: store, composer: focused && SecretEntryView.isOffered(by: store) ? key : nil)
        // A refused login text empties every draft, as it empties a card's feedback box.
        .onChange(of: store.secretRefusals) { _, _ in store.askDrafts[key] = nil }
        .onChange(of: key) { _, _ in keyAllowed = false }
        // The question of a key goes with the field, so no other box waits behind it.
        .onDisappear { if store.heldKey?.composer == key { store.heldKey = nil } }
    }

    /// Sends his message, unless it holds what looks like a key that he did not choose to keep.
    private func send() {
        if SecretEntryView.isOffered(by: store) && !keyAllowed && KeyInText.contains(text) {
            store.heldKey = HeldKey(composer: key, hold: .text)
            return
        }
        let ask = ask, agent = agent
        Task { await store.sendAsk(ask, to: agent) }
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

    /// "Save it as a secret": the key goes into the secure form over the card and out of his words, and the agent of
    /// the field gets the secret's name in its chat. A paste reads the clipboard again now.
    private func saveHeldKey(_ held: HeldKey, words: Binding<String>) {
        store.heldKey = nil
        var cut: String?
        if held.hold == .paste { cut = KeyCut.onClipboard() }
        else if let split = KeyCut.split(words.wrappedValue) { words.wrappedValue = split.rest; cut = split.key }
        store.secretForm = SecretPreset(tell: agent, key: cut, kept: SecretValueKept())
    }

    /// "Paste it anyway" or "Keep it": his choice, and no second question while the key is in his words.
    private func keepHeldKey(_ held: HeldKey, words: Binding<String>) {
        store.heldKey = nil
        keyAllowed = true
        if held.hold == .paste, let pasted = NSPasteboard.general.string(forType: .string) { words.wrappedValue += pasted }
    }
}
