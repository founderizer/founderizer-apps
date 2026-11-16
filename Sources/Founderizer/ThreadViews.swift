import AppKit
import FleetCore
import FleetMark
import SwiftUI

/// The agent of a conversation, over the messages: its own mark and its name in a small pill, in the middle of the
/// column and over whatever scrolls under it. It took the place of the mark that sat inside the message box (the
/// owner, 19 October 2026): who the message goes to belongs over the conversation, not in the field he writes in.
struct ChatAgentPill: View {
    let agent: String
    /// Where it ends, from the top of the conversation: the room over the first thing of every pane, and its 30. The
    /// first message stands 26 points under it (`ManagerView.topInset`).
    static let bottom: CGFloat = FleetSpace.underBand + 30

    var body: some View {
        // The glyph at the `row` step, 22 points (the lead's call on T-04 against B-BRAND-4: a chat's name avatar is 18–24,
        // Grok Bot's about 20), 4 points from the pill's round end all round, so the two curves stand one inside the other.
        HStack(spacing: 7) {
            AgentGlyph(name: agent, size: GlyphSize.row, moves: true, ground: FleetStyle.surface)
            Text(agent.agentLabel).font(FormMetrics.title).foregroundStyle(FleetStyle.text)
        }
        .padding(.leading, (30 - GlyphSize.row) / 2).padding(.trailing, 13).frame(height: 30)
        .background(FleetStyle.surface, in: Capsule(style: .circular))
        .overlay(Capsule(style: .circular).strokeBorder(FleetStyle.line, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
        // 50 pt from the window's top, as the first thing of every pane (the margins of 30 October 2026, row 28).
        .padding(.top, FleetSpace.underBand)
        // It names the conversation; it is no control, so nothing under it loses a click to it.
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore).accessibilityLabel("Chat with \(agent.agentLabel)")
        .accessibilityIdentifier("chat-agent-pill")
    }
}

struct ManagerView: View {
    @Bindable var store: FleetStore
    let agent: String
    @State private var end = ChatEnd()
    @State private var visibleCount = 60
    /// The newest reply when the chat drew first: a reply after it arrives while he looks, and fades in.
    @State private var shownUpTo: Int?
    /// The waiting line as it showed last, and whether it showed in the frame before this one: a reply that comes
    /// fades in over the line's words as they fade out where they stood (`ReplyArrival`).
    @State private var lastWaiting: ChatWaiting?
    @State private var lineShowing = false
    /// His message to this agent as the outbox saved it, kept from the frame it went until the reading that holds the
    /// hub's copy (`WordsOnTheirWay`): the store lets the request go with its receipt, a round trip before that reading.
    @State private var sent: PendingRequest?
    /// His answer in words to a request of this agent, kept in the same way: it is his message in this chat.
    @State private var answerSent: PendingRequest?
    /// The gap between chat entries. A reply's footer takes its height from it, and every other entry gets the same
    /// height below it, so each gap stays 28 points.
    private static let entrySpacing: CGFloat = 28, footer = AgentReply.footer(compact: false)

    /// **The room under one of his messages, so a reply stands 28–30 points from it** (T-20, fix round): the chat's gap,
    /// less the row under a file where he keeps it (`KeepFileRow`, which a message with files already has, and which
    /// put a reply 52.5 points under his picture), and 3 points less over a reply, whose first line carries its own
    /// leading over its words (31–32.5 points under his bubble, 28.5 over his next one).
    static func gap(under message: OwnerMessage, before next: ChatEntry?, keepsFiles: Bool) -> CGFloat {
        var gap = footer
        if keepsFiles, !(message.attachments ?? []).isEmpty { gap -= KeepFileRow.height + 1 }
        if case .report = next { gap -= 3 }
        return gap
    }
    /// The entry that stands right under the row at `index`, or nil at the chat's end and over a request's card.
    private static func entry(after index: Int, in rows: [ChatPart]) -> ChatEntry? {
        guard index + 1 < rows.count, case .entry(let next) = rows[index + 1] else { return nil }
        return next
    }
    /// Over the first message: the room the pill over the conversation stands in.
    private static let topInset: CGFloat = 26 + ChatAgentPill.bottom
    /// **The room under the chat's last row, over the composer** (the owner, 15 November 2026, with a picture of the
    /// Claude desktop chat: "increase the space between the last message received and the text input so it breathes
    /// more, like it happens in claude code"): the last words stood 39 points over the composer, and stand 127 over it
    /// now, as that chat's do. It is a row of the chat, over the row that the chat scrolls to, so the chat opens with
    /// it and keeps it when a reply comes (`threadRows`).
    private static let endRoom: CGFloat = 88
    private var entries: [ChatEntry] { store.chatTimeline.entries(for: agent, limit: visibleCount) }
    /// His message to this agent on its way, until the reading holds the hub's copy (fix round 3, item 11).
    private var requestOnItsWay: PendingRequest? { store.messageOnItsWay(to: agent, kept: sent) }
    /// His answer in his own words to a request of this agent, on its way, until the reading holds the hub's copy: his
    /// message in this chat, as the hub writes it (`ChatRequestPlaces.inTime`).
    private var answerOnItsWay: PendingRequest? { store.answerInWordsOnItsWay(toOneOf: mine, kept: answerSent) }
    /// **The chat as it draws: the hub's entries, and his words on their way at their end** (fix round 3, item 11), a
    /// message or an answer that he wrote to a request, from the frame he sent it, under the request's id, which the
    /// hub's copy keeps, so that copy takes its place where it stands. Words of files alone come with the hub's copy,
    /// its files with it.
    private var drawn: [ChatEntry] {
        let going = [requestOnItsWay, answerOnItsWay].compactMap { $0 }.filter { !$0.text.isEmpty }
        guard !going.isEmpty else { return entries }
        return entries + going.sorted { $0.createdAt < $1.createdAt }.map { .message(OwnerMessage(onItsWay: $0)) }
    }
    /// **What this agent asked him and still waits for** (the owner's yes of 28 October 2026, D-7): the request's card
    /// itself, at the column's width, so he answers in the chat where the agent told him about it ("It is in Needs
    /// you."), and Needs you has them all in its lane. A key or a login it asked for comes with its secure form.
    private var requests: [OwnerNeed] {
        store.openNeeds.filter { $0.by == agent }.sorted { ($0.raised, $0.id) < ($1.raised, $1.id) }
    }

    /// **Every request of this agent, waiting or answered, stands where it was raised** (the owner, 14 November 2026:
    /// "Cards during a thread should appear wherever in the conversation they were requested, not all at the bottom of
    /// the conversation!"; `ChatRequestPlaces.inTime`): right after the agent's message that told him about it ("It is
    /// in Needs you.", D-7 item 1), else at its own time among the messages, so what came after it stands under it.
    /// Every waiting request that no message told him about stood at the end of the chat, under the newest reply. An
    /// answered one folds where it stands (D-7 item 2). **What he answers in his own words is his message in the
    /// chat** ("When I reply to a card, the conversation should follow!"), at its time, with the agent's reply under
    /// it; an option that he pressed is no second bubble, because its card shows it. The hub writes every answer as
    /// his message to the agent that asked (`kind` "answer").
    private var mine: [OwnerNeed] { (store.state?.needs ?? []).filter { $0.by == agent } }

    /// What this chat is waiting for, or nil. Every part of it is already read: the hub's own answer about the
    /// owner's last message (`pendingChat`), this Mac's own request on its way, and the two things that stop the
    /// agent running at all — its usage limit and its machine going quiet.
    private var waiting: ChatWaiting? {
        // A reply the hub cannot link to his message is not proof that the agent is still working: see
        // ChatWaiting.Pending.spokenSince, which the manager's every reply is. Nor is a message that it read in a
        // turn that has ended with no reply (ChatWaiting.Pending.turnOver).
        store.chatWaiting(for: agent, onItsWay: requestOnItsWay != nil)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Self.entrySpacing - Self.footer) {
                    if store.chatTimeline.count(for: agent) > visibleCount {
                        Button("Earlier messages", systemImage: "arrow.up") { visibleCount += 60 }
                            .buttonStyle(.plain).font(ChatStyle.detail).foregroundStyle(FleetStyle.muted)
                            .frame(maxWidth: .infinity).padding(.bottom, 8 + Self.footer)
                    }
                    let whole = entries.count >= store.chatTimeline.count(for: agent)
                    let held = drawn
                    let needs = mine
                    let places = ChatRequestPlaces.inTime(needs: needs, in: held, whole: whole)
                    let byID = Dictionary(needs.map { ($0.id, $0) }) { first, _ in first }
                    // **One list of rows, the entries and the cards, each under its own id** (`ChatPart`): a card keeps
                    // its view, with the cursor in its answer, when an entry that comes moves it to another place.
                    let rows = places.rows(of: held)
                    // A card counts for the marks of a day or an hour as a message does, by the time it was raised.
                    let times = ChatRequestPlaces.times(of: rows, raised: byID.mapValues(\.raised))
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if let time = ChatStamp.time(times[index], after: index > 0 ? times[index - 1] : nil) {
                            ChatStamp(time: time)
                        }
                        switch row {
                        case .request(let id):
                            if let need = byID[id] { requestCard(need, spoken: places.spoken.contains(id)) }
                        case .entry(.message(let message)):
                            // The room under his message is counted to the row under it: a reply, or a card.
                            messageRow(message).padding(.bottom, Self.gap(under: message, before: Self.entry(after: index, in: rows),
                                                                          keepsFiles: store.supportsKeptFiles))
                        // **A reply that arrives while he looks fades in where it stands** (T-20): 0.2 s, opacity
                        // only. It took the waiting line's place in one frame. Not on the first paint, and not for
                        // the earlier messages he asks for.
                        case .entry(.report(let report)): reportRow(report).id(row.id)
                            .transition(shownUpTo.map { report.id > $0 } == true
                                        ? ReplyArrival.transition(taking: lineShowing && places.atEnd.isEmpty ? lastWaiting : nil,
                                                                  agent: agent)
                                        : .identity)
                        }
                    }
                    // What the owner is waiting for, under his last message and above nothing: one muted line,
                    // in the place the answer will take.
                    if let waiting { ChatWaitingLine(waiting: waiting, agent: agent).padding(.bottom, Self.footer) }
                    Color.clear.frame(height: Self.endRoom)
                    Color.clear.frame(height: 1).id("latest")
                }.threadRows(top: Self.topInset)
            }
            .keepsEnd($end, room: Self.endRoom)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // Text that scrolls up fades under the pill instead of running under it (T-20).
            .topFade(56)
            .onAppear { shownUpTo = store.state?.reports.lazy.filter { $0.chatAgent == agent }.map(\.id).max() ?? 0 }
            .onChange(of: store.chatTimeline.count(for: agent)) { oldCount, newCount in
                if !end.followsLatest && newCount > oldCount { visibleCount += newCount - oldCount }
            }
            // His message on its way is the newest entry from the frame it went, and the hub's copy, which takes its
            // place, may bring its files under it.
            .onChange(of: drawn.last) { _, _ in
                if end.followsLatest { proxy.scrollTo("latest", anchor: .bottom) }
            }
            .onChange(of: store.pending?.requestID, initial: true) { _, _ in
                if let request = store.messageOnItsWay(to: agent) { sent = request }
                // **The chat follows the answer that he writes to a request** (the owner, 14 November 2026: "When I
                // reply to a card, the conversation should follow!"): his words stand at the chat's end, also when
                // he wrote them in a card further up, and the agent's reply comes under them.
                if let request = store.answerInWordsOnItsWay(toOneOf: mine) {
                    if answerSent?.requestID != request.requestID {
                        end.followsLatest = true
                        proxy.scrollTo("latest", anchor: .bottom)
                    }
                    answerSent = request
                }
            }
            // A match of the search card: the chat draws back to it and shows it in its middle.
            .onChange(of: store.chatFocus, initial: true) { _, focus in reveal(focus, proxy) }
            .onChange(of: requests.map(\.id)) { _, _ in
                if end.followsLatest { proxy.scrollTo("latest", anchor: .bottom) }
            }
            // The line appears and goes under his last message, so the view follows it as it does a reply.
            .onChange(of: waiting?.says) { _, _ in
                if end.followsLatest { proxy.scrollTo("latest", anchor: .bottom) }
            }
            .onChange(of: waiting, initial: true) { _, now in
                lineShowing = now != nil
                if let now { lastWaiting = now }
            }
            // An empty conversation is the product's own mark, muted, and nothing else. The owner,
            // 20 October 2026: "just the Founderizer logo, muted, centred." What stood here told him to
            // chat with the agent, which he was about to do, and repeated the rule that work requests go
            // through the manager, which he wrote. A reader still hears what the view is. **Centred in the room it
            // has** (T-20), between the pill and the composer: it stood at the top, 265 points above that middle.
            .overlay {
                if drawn.isEmpty && requests.isEmpty && store.canChat(with: agent) {
                    FounderizerMark(size: 96, plate: Color.white.opacity(0.05), ink: Color.white.opacity(0.13))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("No messages with \(agent.agentLabel) yet")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, ChatAgentPill.bottom)
                        .allowsHitTesting(false)
                }
            }
            // The agent of this conversation stands over it, and stays there while it scrolls.
            .overlay(alignment: .top) { ChatAgentPill(agent: agent) }
            .overlay(alignment: .bottomTrailing) {
                if end.showsLatest {
                    Button("Latest", systemImage: "arrow.down") { proxy.scrollTo("latest", anchor: .bottom); end.followsLatest = true }
                        .buttonStyle(.plain).font(ChatStyle.detail).foregroundStyle(FleetStyle.muted)
                        .padding(9).background(FleetStyle.surface, in: Capsule()).padding(12)
                }
            }
            // Owner feature attachments: a file dropped anywhere in the conversation is staged in this chat's
            // composer, with the rules and the words of a file picked with the plus.
            .stageDroppedFiles(store: store, composer: FleetStore.stageKey(agent: agent), mark: true)
        }
    }

    /// **The chat at one message** (`FleetStore.chatFocus`, from the search card's "In messages"): the chat holds every
    /// message of the state read, so it draws back as far as the entry's time, with some entries over it
    /// (`MessageSearch.drawn`), and scrolls to it. An entry that it does not hold (the reading has not brought it yet)
    /// leaves the chat at its end.
    private func reveal(_ focus: ChatFocus?, _ proxy: ScrollViewProxy) {
        guard let focus, focus.agent == agent else { return }
        store.chatFocus = nil
        let all = store.chatTimeline.entries(for: agent, limit: .max)
        guard let from = all.firstIndex(where: { $0.created >= focus.at }) else { return }
        visibleCount = max(visibleCount, MessageSearch.drawn(count: all.count, index: from))
        end.followsLatest = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            proxy.scrollTo(focus.entry, anchor: .center)
            // A chat that opens stands at its end, and the scroll view's first idle phase there sets `followsLatest`
            // to true again within those 50 ms. This scroll starts no phase that would correct it, so the next entry
            // pulled the chat to its end, away from the match, and Latest did not show (a real window, 13 November
            // 2026). So the chat stops following here, after the scroll, until he scrolls or presses Latest. **A match
            // that stands at the chat's end takes nothing from there** (`ChatEnd`; the owner, 14 November 2026): the
            // chat still follows, and Latest does not show over a chat with nothing under it.
            end.followsLatest = false
        }
    }

    private func messageRow(_ message: OwnerMessage) -> some View {
        SentMessageView(store: store, message: message).id("message-\(message.id)")
    }

    /// A request's card in the chat, at the column's width, waiting or folded. `spoken`: his answer stands in the chat
    /// as his own message, so the folded card does not say it again.
    private func requestCard(_ need: OwnerNeed, spoken: Bool) -> some View {
        NeedRequestCard(store: store, need: need, spoken: spoken).padding(.bottom, Self.footer).id("need-\(need.id)")
    }

    /// A reply, with its delivery icons when it went to a channel. **A message that the agent wrote first
    /// (`message_owner`) looks like any other** (D-2, the owner's yes of 28 October 2026): its "Sent first" line said
    /// what the conversation already shows, a message under no question of his.
    private func reportRow(_ report: ManagerReport) -> some View {
        AgentReply(text: report.text, time: report.created, detail: reportDetail(report))
    }

    /// Under a reply: the files that the agent sent with it (CHAT-APPS.md 20; the owner's "Yes, build it" of 15
    /// November 2026), drawn as his own files are drawn under his messages, and its delivery icons when it went to a
    /// channel.
    private func reportDetail(_ report: ManagerReport) -> AnyView? {
        let files = report.attachments ?? []
        guard !files.isEmpty || report.delivery != nil else { return nil }
        return AnyView(VStack(alignment: .leading, spacing: 8) {
            if !files.isEmpty { MessageFilesView(store: store, files: files, alignment: .leading, keeps: false) }
            if let delivery = report.delivery { DeliveryLine(store: store, delivery: delivery) }
        })
    }
}

/// **His words on their way** (`WordsOnTheirWay`; fix round 3, item 11): what the chat, its field and a request's card
/// draw from the request that the outbox saved, from the frame he sends it until the reading that holds the hub's copy.
extension FleetStore {
    /// His message to `agent` on its way, or `kept`, the one a chat saw go, once the hub confirmed it.
    func messageOnItsWay(to agent: String, kept: PendingRequest? = nil) -> PendingRequest? {
        WordsOnTheirWay.message(to: agent, pending: pending, kept: kept, receipt: lastReceipt, hub: hub,
                                database: state?.db, messages: state?.messages ?? [])
    }

    /// **What an agent's chat waits for, or nil**: one rule for the chat's own line and for the agent's row of the
    /// sidebar (`FleetAgent.chatWaiting`). Every part of it is already read: the hub's own answer about his last
    /// message, this Mac's own request on its way (`onItsWay`), and the two things that stop the agent running at all,
    /// its usage limit and its server going quiet.
    func chatWaiting(for agent: String, onItsWay: Bool) -> ChatWaiting? {
        guard let state, let entry = state.agents.first(where: { $0.name == agent }) else { return nil }
        return entry.chatWaiting(in: state, sending: sending && onItsWay, fresh: isFresh,
                                 until: { fleetComingTime($0, now: state.time) })
    }

    /// **Whether an agent works on his newest chat message now**: its chat says "Thinking". Its glyph then moves and
    /// its sidebar line moves, as for a task in work (`FleetAgent.presence`).
    func thinks(_ agent: String) -> Bool {
        chatWaiting(for: agent, onItsWay: sending && messageOnItsWay(to: agent) != nil)?.moving == true
    }

    /// His answer to `need` on its way, or `kept`, the one a card saw go, once the hub confirmed it.
    func answerOnItsWay(to need: OwnerNeed, kept: PendingRequest? = nil) -> PendingRequest? {
        WordsOnTheirWay.answer(to: need, pending: pending, kept: kept, receipt: lastReceipt, hub: hub, database: state?.db)
    }

    /// His answer in his own words to one of `needs`, an agent's requests, on its way, or `kept`, the one that agent's
    /// chat saw go, once the hub confirmed it: his message in that chat.
    func answerInWordsOnItsWay(toOneOf needs: [OwnerNeed], kept: PendingRequest? = nil) -> PendingRequest? {
        WordsOnTheirWay.answerInWords(toOneOf: needs, pending: pending, kept: kept, receipt: lastReceipt, hub: hub,
                                      database: state?.db, messages: state?.messages ?? [])
    }

    /// The chat's field: his draft, and nothing while it is his message on its way, so the field empties in the frame
    /// his bubble comes in; the store clears the draft itself with the hub's receipt.
    func composerText(for agent: String) -> String {
        WordsOnTheirWay.field(draft(for: agent), sending: messageOnItsWay(to: agent))
    }

    /// A request's answer box: as the chat's field, for its answer on its way.
    func answerText(for need: OwnerNeed) -> String {
        WordsOnTheirWay.field(answers[String(need.id)] ?? "", sending: answerOnItsWay(to: need))
    }
}

private struct SentMessageView: View {
    @Bindable var store: FleetStore
    let message: OwnerMessage
    @State private var hovered = false
    @State private var copied = false
    /// **Edit shows only where it can ever act** (the owner, 26 October 2026: "dont show the send button if it's not
    /// clickable"): a message he sent from this Mac, to a chat the hub corrects. One from his phone or a chat app, or
    /// on a hub without corrections, had a dead Edit under it. While a request is on its way it waits, as Send does.
    private var editable: Bool {
        store.supportsCorrections && message.kind == "message" && message.client == store.installation
            && store.canChat(with: message.chatRecipient)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if message.replaces_request_id != nil {
                Text("Correction").font(ChatStyle.detail).foregroundStyle(FleetStyle.muted)
            }
            // A message may carry files and no words: then the files are the message, and no empty bubble shows.
            // **The footer stands beside the bubble, on its last line** (T-20), and takes no height: under the
            // bubble it kept 26 points under every message he sent, so a reply stood 57 points from his question
            // and 29 from his next one. A message of files alone has no bubble, and keeps it under its files.
            if !message.text.isEmpty { OwnerBubble(text: message.text, origin: message.origin, beside: AnyView(footer)) }
            if let files = message.attachments, !files.isEmpty {
                MessageFilesView(store: store, files: files)
            }
            if message.text.isEmpty { footer }
        }.contentShape(Rectangle()).onHover { hovered = $0; if !$0 { copied = false } }
            // The same symbols as the two buttons under the bubble, as the agent rows' right-click has its own.
            .contextMenu {
                Group {
                    Button("Copy message", systemImage: "square.on.square") { copyMessage(message.text) }
                    if editable {
                        Button("Correct", systemImage: "arrow.uturn.right") { store.beginEdit(message) }
                            .disabled(!store.canEdit(message))
                    }
                }.labelStyle(.titleAndIcon)
            }
    }

    /// How long ago he sent it (`messageAge`), Copy and Edit, under the pointer only.
    private var footer: some View {
        HStack(spacing: 10) {
            Text(messageAge(message.created))
                .help("\(fleetDate(message.created)) · \(message.read_at == nil ? String(l10n: "Received, not read yet") : String(localized: "Read (a message)", defaultValue: "Read", bundle: Localized.bundle, locale: Localized.digits))"
                      + (message.edited.map { " · " + String(l10n: "Edited \(messageTime($0))") } ?? ""))
            MessageAction(symbol: copied ? "checkmark" : "square.on.square", label: String(l10n: "Copy message")) {
                copyMessage(message.text); copied = true
            }
            // His own icon for it (20 October 2026): the hooked arrow of resending, not a pencil. The words
            // of the hover say what this one will do — replace the message, or go under it as a correction.
            if editable {
                MessageAction(symbol: "arrow.uturn.right", label: String(l10n: "Correct"),
                              help: store.editHelp(message)) { store.beginEdit(message) }
                    .disabled(!store.canEdit(message))
            }
        }.font(ChatStyle.detail).foregroundStyle(FleetStyle.muted)
            .frame(height: 20).padding(.trailing, 3)
            .opacity(hovered ? 1 : 0).allowsHitTesting(hovered)
            .accessibilityHidden(!hovered)
    }
}

struct TaskView: View {
    @Bindable var store: FleetStore
    let task: FleetTask
    let state: HubState
    let hub: URL
    let isFresh: Bool
    @State private var end = ChatEnd()
    @State private var latestActivity = 0
    /// Why the thread's last read failed, in the hub's words.
    @State private var readError: String?
    private var notes: [ProgressNote] { state.notes.filter { $0.task == task.id } }
    private var permissions: [FleetPermission] { state.permissions.filter { $0.task == task.id } }
    private var threadEvents: Bool { state.ui_features?.contains("thread_events") == true }
    /// What the thread read last on this hub generation (`TaskActivity`).
    private var activity: TaskActivity? { store.reading(TaskActivity.name(task.id)) }
    /// The usage limit that holds this task now: its agent's, while the task is open and neither an outcome that is not
    /// known nor a hold of the owner's comes first — the order of the task's mark (`FleetTask.mark`).
    private var limitHolding: RuntimeLimit? {
        guard !task.isTerminal, !state.outcomeUnknown(task.id),
              state.holds?.contains(where: { $0.task == task.id && $0.state != "released" }) != true
        else { return nil }
        return state.agents.first { $0.name == task.owner }?.limit
    }

    /// **The thread comes in one frame, at its newest row** (T-06). A task opened again draws what it read last, at
    /// once. The first time, the column stays empty until the thread's reads have answered — every page of them — and
    /// then the whole thread shows, already at its end, with every fact of its panel in the same frame
    /// (`FleetView.inspector`), its AI provider included. It arrived in three steps, and the request at its top jumped
    /// away as the rows under it came; on a hub slower than a second the request and "Started" came alone first, and
    /// the rest 664 points away from them (fix round 2).
    static func shows(_ task: FleetTask, store: FleetStore) -> Bool {
        store.reading(TaskActivity.name(task.id)) as TaskActivity? != nil || !store.isFresh
            || store.state?.ui_features?.contains("thread_events") != true
    }

    var body: some View {
        // A stack and not a group: the reads below belong to the page, and must not start again when the thread
        // takes the empty column's place.
        ZStack(alignment: .top) {
            Color.clear
            if Self.shows(task, store: store) {
                thread
            } else {
                // **A first read that takes longer than a second says so in the thread's first slot** (the loading
                // contract, D-1 rule 1; fix round 2): the one loading line, at the column's edge where the request will
                // stand, and nothing of the thread until all of it comes.
                LoadingLine(String(l10n: "Reading the task…")).padding(.horizontal, -FormMetrics.rowInset).threadRows(top: FleetSpace.underBand)
            }
        }
        .task(id: "\(state.db)/\(isFresh)/\(task.isTerminal)") { await readActivity() }
        // A thread that shows without a reading keeps an empty one, so a read that comes later adds its rows to the
        // thread that shows instead of taking it away: one that opened while the hub did not answer, or on a hub
        // without its events.
        .task(id: "\(state.db)/\(isFresh)") {
            let name = TaskActivity.name(task.id)
            if !(isFresh && threadEvents), store.reading(name) as TaskActivity? == nil { store.keep(TaskActivity(), as: name) }
        }
    }

    /// Reads the thread's events after the newest one it has, every 3 seconds and at each change the hub announces.
    /// The first read of a task keeps nothing until it has every page; one that took more than a second keeps its
    /// loading line half a second (`settle`).
    private func readActivity() async {
        guard isFresh, threadEvents else { return }
        let name = TaskActivity.name(task.id), database = state.db, client = HubClient(), start = ContinuousClock.now
        var first: TaskActivity? = store.reading(name) as TaskActivity? == nil ? TaskActivity() : nil
        while !Task.isCancelled {
            do {
                var activity = first ?? store.reading(name) ?? TaskActivity()
                // The first read in pages of the hub's most, so a long task comes in one round trip (fix round 3b).
                let page = try await client.events(hub: hub, database: database, task: task.id, after: activity.cursor,
                                                   limit: first != nil ? RuntimePage.most : 200)
                try Task.checkCancellation()
                guard store.hub == hub, store.state?.db == database else { return }
                activity.append(page)
                if readError != nil { readError = nil }
                if first != nil, page.more { first = activity; continue }
                if first != nil {
                    await store.settle(since: start)
                    guard !Task.isCancelled, store.hub == hub, store.state?.db == database else { return }
                }
                // A read that brought nothing new keeps nothing, so the thread and its panel do not draw again for it.
                if first != nil || !page.events.isEmpty { store.keep(activity, as: name) }
                first = nil
                if !page.events.isEmpty { latestActivity = activity.cursor }
                if page.more { continue }
                if task.isTerminal { return }
            } catch {
                if Task.isCancelled { return }
                readError = HubError.said(error) ?? String(l10n: "Activity is unavailable. Retrying…")
                if let partial = first {
                    await store.settle(since: start)
                    guard !Task.isCancelled else { return }
                    store.keep(partial, as: name); first = nil
                }
            }
            do { try await store.nap(3) } catch { return }
        }
    }

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Activity already pages its rows. Keep their changing heights out of
                // a lazy parent, which can loop while a scrolled task becomes terminal.
                VStack(alignment: .leading, spacing: ChatStyle.blockSpacing) {
                    if task.supportsDesktopPreview(in: state) {
                        let context = DesktopContext(hub: hub, database: state.db, task: task.id, attempt: task.attempt)
                        DesktopView(context: context, isFresh: isFresh).id(context)
                    }
                    if let reason = task.stalled_reason { Label(reason, systemImage: "exclamationmark.circle").foregroundStyle(.orange).font(ChatStyle.detail) }
                    // **Two words, and its end on hover, as the chat's line says it** (fix round 2): "Usage limit until 29 Oct
                    // 2026 at 3:26" stood here in eight. **In the task's own mark, and only while the limit holds the task**
                    // (fix round 3, item 7; `FleetTask.mark`): the board's hourglass where a clock stood, and no line on a
                    // task that is over or that his hold holds first.
                    if let limit = limitHolding {
                        let who = task.owner.agentLabel, mark = task.mark(in: state)
                        Label(mark.words, systemImage: mark.symbol).font(ChatStyle.detail).foregroundStyle(.orange)
                            .help(limit.reset_known ? "\(who) is at its usage limit until \(fleetComingTime(limit.until, now: state.time))."
                                                    : "\(who) is at its usage limit.")
                    }
                    OwnerBubble(text: task.details)
                    if threadEvents {
                        // Its "Activity is unavailable" not while the window's notice says the outage
                        // (`FleetStore.hubNoticeShows`; fix round 3, item 33).
                        RuntimeActivity(activity: activity ?? TaskActivity(), error: store.hubNoticeShows ? nil : readError, task: task.id, attempt: task.attempt, stoppedAttempt: state.stoppedAttempt(of: task.id), terminal: task.isTerminal, isFresh: isFresh, followsLatest: $end.followsLatest,
                                        steers: state.steers?.filter { $0.task == task.id } ?? [],
                                        notes: notes, permissions: permissions,
                                        childRequest: $store.childThreadRequest)
                            .id("\(hub.absoluteString)/\(state.db)/\(task.id)")
                    }
                    // A hub without `thread_events` has no thread to put them in, so there they stay rows of their own.
                    if !threadEvents {
                        ForEach(notes) { note in AgentReply(text: note.text, time: note.ts, compact: true) }
                        ForEach(permissions.filter(\.needsReading)) { permission in
                            FoldRow(title: permission.tool, symbol: "hand.raised",
                                    status: permission.decision ?? TaskWords.waitingFor(task.requester), statusColor: .orange, chat: true) {
                                VStack(alignment: .leading, spacing: 9) {
                                    Text(permission.input).font(ChatStyle.code).textSelection(.enabled)
                                    if let reason = permission.reason { Text(reason).textSelection(.enabled) }
                                }
                            }
                        }
                    }
                    // **The thread says its state once** (review B6): the head's word ("Reconnecting", "Stalled") is the
                    // state; here only when the session went, and the stall's own reason above. "· waiting for helper"
                    // and "Stalled · hub has sent a nudge" said the head's word again.
                    if let missing = task.missing_since, !task.isTerminal {
                        StatusLabel(text: String(l10n: "Session missing since \(fleetDate(missing))"), color: .orange)
                    }
                    // What it waits for, in his words: the hub's "Q-1" (or "P-3", "CM-7", "its screen") is a
                    // question, a prompt or a person that its requester answers (T-12), and a name is that agent; who
                    // it is, as the state word names them (`TaskWords`, fix round 2: "an answer" named nobody).
                    if let waiting = task.waiting_on, !waiting.isEmpty {
                        if let other = TaskWords.waiter(of: waiting) {
                            DetailField(title: String(l10n: "Waiting on"), value: other, agent: waiting.lowercased())
                        } else {
                            DetailField(title: String(l10n: "Waiting for"), value: task.requester == "owner" ? String(l10n: "You") : task.requester.agentLabel,
                                        agent: task.requester)
                        }
                    }
                    if task.delivered != nil {
                        Rule()
                        if let what = task.what { AgentReply(text: what, time: task.delivered, compact: true) }
                        else { MessageText(text: String(l10n: "No result reported")) }
                        FoldRow(title: task.checkStatus, symbol: "checkmark.circle", chat: true) {
                            VStack(alignment: .leading, spacing: 10) {
                                DetailField(title: String(l10n: "Output"), value: task.where_ ?? String(l10n: "Not reported"))
                                DetailField(title: String(l10n: "How it was checked"), value: task.how ?? String(l10n: "Not reported"))
                                if let check = task.check_note { MessageText(text: check) }
                                if let checked = task.checked_at { Text(fleetDate(checked)).font(ChatStyle.detail).foregroundStyle(FleetStyle.muted) }
                            }
                        }
                        if task.accepted == 1 {
                            let context = ArtifactContext(hub: hub, database: state.db, taskID: task.id)
                            ArtifactSection(context: context, isFresh: isFresh).id(context)
                        }
                    }
                    // Who did it, at the end, where it is the footer of the record and not a row between the agent's
                    // words. No hub number: the title over the thread names the task.
                    Text(task.owner.agentLabel).font(ChatStyle.detail).foregroundStyle(FleetStyle.muted)
                        .textSelection(.enabled)
                    Color.clear.frame(height: 1).id("latest-task")
                }.threadRows(top: FleetSpace.underBand)
            }
            .keepsEnd($end)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // Its rows fade as they leave at the top, over the room the thread leaves above its first row (T-20): its first
            // row stands 14 pt under the band, level with the first thing of every pane (the margins of 30 October 2026,
            // row 28, and its review: it stood 26 pt under it, 12 under the panel's head beside it).
            .topFade(FleetSpace.underBand)
            .onChange(of: latestActivity) { _, _ in
                if end.followsLatest { proxy.scrollTo("latest-task", anchor: .bottom) }
            }
            .onChange(of: task.state) { _, _ in
                if end.followsLatest { proxy.scrollTo("latest-task", anchor: .bottom) }
            }
            .onChange(of: state.steers?.last(where: { $0.task == task.id })?.id) { _, _ in
                if end.followsLatest { proxy.scrollTo("latest-task", anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if end.showsLatest {
                    Button("Latest", systemImage: "arrow.down") {
                        proxy.scrollTo("latest-task", anchor: .bottom); end.followsLatest = true
                    }.buttonStyle(.plain).font(ChatStyle.detail).foregroundStyle(FleetStyle.muted)
                        .padding(9).background(FleetStyle.surface, in: Capsule()).padding(12)
                        .accessibilityIdentifier("task-latest")
                }
            }
        }
    }
}

/// **A centred time over a message that comes an hour or a day after the one before** (the owner's yes of 28 October
/// 2026, D-7; the phone's rule): 12 points, muted — "Today 15:06", "Tuesday 10:56" — over the first message and after
/// each gap, as dots and Grok Bot put a separator between the parts of a day and no time under every message. A
/// message's own time stays in its footer, under the pointer.
struct ChatStamp: View {
    let time: Double

    /// The stamp over `entry`: its time when nothing comes before it in the chat, or when the one before came more than an
    /// hour earlier or on another day; else none.
    static func time(of entry: ChatEntry, after previous: ChatEntry?) -> Double? {
        time(entry.created, after: previous?.created)
    }

    /// The same rule for any two times of a chat, also one that the owner only reads (`ReadChat`).
    static func time(_ created: Double, after previous: Double?) -> Double? {
        guard let previous else { return created }
        let calendar = Calendar.current
        let sameDay = calendar.isDate(Date(timeIntervalSince1970: previous), inSameDayAs: Date(timeIntervalSince1970: created))
        return created - previous > 3600 || !sameDay ? created : nil
    }

    /// The day, then the time, as the phone writes them: Today, Yesterday, a weekday within the week, else the date.
    static func words(_ timestamp: Double) -> String {
        let date = Date(timeIntervalSince1970: timestamp), calendar = Calendar.current
        let day: String
        if calendar.isDateInToday(date) { day = String(l10n: "Today") }
        else if calendar.isDateInYesterday(date) { day = String(l10n: "Yesterday") }
        else if let weekBack = calendar.date(byAdding: .day, value: -6, to: .now), date > weekBack {
            day = date.formatted(.dateTime.weekday(.wide))
        } else { day = date.formatted(date: .abbreviated, time: .omitted) }
        return day + " " + date.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        Text(Self.words(time)).font(ChatStyle.detail).foregroundStyle(FleetStyle.muted)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.bottom, 16)
            .help(fleetDate(time))
            .accessibilityIdentifier("chat-stamp")
    }
}

/// **A reply takes the waiting line's place in one cross-fade** (T-20, fix round of 28 October 2026): its words fade in
/// over 0.2 s while the line's own words fade out where they stood — the top of the reply's place, under his message —
/// so no frame shows neither (one did: the line went in the frame the reply came in at nothing). It is drawn only where
/// the line stood right over the reply; under a request that waits, the line stood lower and simply goes.
private struct ReplyArrival: ViewModifier {
    /// The line the reply takes the place of, or nil.
    let line: ChatWaiting?
    /// The agent of the chat, whose glyph stands before the line's moving words (`ChatWaitingLine`).
    let agent: String
    /// The first frame of the arrival: the reply clear, the line whole.
    let arriving: Bool

    static func transition(taking line: ChatWaiting?, agent: String) -> AnyTransition {
        .asymmetric(insertion: .modifier(active: ReplyArrival(line: line, agent: agent, arriving: true),
                                         identity: ReplyArrival(line: line, agent: agent, arriving: false))
                        .animation(.easeOut(duration: 0.2)),
                    removal: .identity)
    }

    func body(content: Content) -> some View {
        content.opacity(arriving ? 0 : 1)
            .overlay(alignment: .topLeading) {
                // The line's still words: its shimmer is a moving layer, and this is the last fifth of a second of it,
                // with the agent's glyph at rest where it moved, so the words go from where they stood.
                if let line {
                    HStack(spacing: ChatWaitingLine.glyphGap) {
                        if line.moving { ChatWaitingLine.glyph(agent, moves: false) }
                        HStack(spacing: 8) {
                            if !line.moving { Image(systemName: line.symbol).font(IconMetrics.symbol(11)).foregroundStyle(.orange) }
                            Text(line.says).font(ChatStyle.detail).foregroundStyle(line.moving ? FleetStyle.muted : .orange)
                        }
                    }
                    .opacity(arriving ? 1 : 0)
                    .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
    }
}

/// What `keepsEnd` reads of a scroll: whether it stands at its end (0 points under it, or `ChatEnd.near`), how long the
/// chat is and how high its room.
private struct EndMeasure: Equatable { let under: Double, chat: Double, room: Double }

extension View {
    /// **The rows of a chat or a task thread end at their last row**, one rule for both (T-06, fix round of 28 October
    /// 2026): each opens at its end in one frame by the scroll's own bottom anchor, and later follows its newest row by
    /// `scrollTo(…, anchor: .bottom)`, which leaves out whatever stands under that row. Room under the last row showed on
    /// the first and not on the second: the task thread ended 66 points over its status line where it had always ended
    /// 40, and a chat's last message stood 26 points higher over its composer when it opened than after a reply. So the
    /// rows keep room over their first row only, and the column of prose.
    func threadRows(top: CGFloat) -> some View { padding(.top, top).chatColumn() }

    /// **The scroll of a chat or a task thread says where it stands** (`ChatEnd`): its phases say that he took the
    /// view in hand and where it came to rest, and its own measure says whether it stands at its end now, by whatever
    /// way it came there and whatever took it from there. The measure is asked only when the answer changes, or the
    /// chat's length or its room, not at each point of a scroll. `room` is the empty room that the rows keep under
    /// their last row (`ManagerView.endRoom`): it is no part of the chat, so the measure is of the rows over it, and
    /// "Latest" shows when 100 points of messages stand under the view, as it did before the chat had that room.
    func keepsEnd(_ end: Binding<ChatEnd>, room: CGFloat = 0) -> some View {
        func under(_ geometry: ScrollGeometry) -> Double { geometry.contentSize.height - room - geometry.visibleRect.maxY }
        func keep(_ change: (inout ChatEnd) -> Void) {
            var now = end.wrappedValue
            change(&now)
            if now != end.wrappedValue { end.wrappedValue = now }
        }
        return onScrollPhaseChange { oldPhase, phase, context in
            if phase == .interacting || phase == .tracking { keep { $0.taken() } }
            else if phase == .idle { keep { $0.rested(under: under(context.geometry), jumped: oldPhase == .animating) } }
        }
        .onScrollGeometryChange(for: EndMeasure.self) {
            EndMeasure(under: ChatEnd.isEnd(under($0)) ? 0 : ChatEnd.near, chat: $0.contentSize.height, room: $0.containerSize.height)
        } action: { old, now in
            keep { $0.stands(under: now.under, moved: old.chat == now.chat && old.room == now.room) }
        }
    }

    /// **What scrolls under the top edge fades out over `height` points** (T-20): clear at the edge, whole at that
    /// depth. A message ran under the opaque pill of an agent's chat and was cut by it; Grok Bot fades its messages
    /// under its own.
    func topFade(_ height: CGFloat) -> some View {
        mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: height)
                Color.black
            }
        }
        .modifier(SoftTopEdge())
    }
}

/// The system's own soft edge at the top of a scroll, where the system has one (macOS 26 and later).
private struct SoftTopEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) { content.scrollEdgeEffectStyle(.soft, for: .top) } else { content }
    }
}
