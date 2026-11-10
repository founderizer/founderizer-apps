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
    @State private var followsLatest = true
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
    /// Over the first message: the room the pill over the conversation stands in.
    private static let topInset: CGFloat = 26 + ChatAgentPill.bottom
    private var entries: [ChatEntry] { store.chatTimeline.entries(for: agent, limit: visibleCount) }
    /// His message to this agent on its way, until the reading holds the hub's copy (fix round 3, item 11).
    private var requestOnItsWay: PendingRequest? { store.messageOnItsWay(to: agent, kept: sent) }
    /// **The chat as it draws: the hub's entries, and his message on its way at their end** (fix round 3, item 11), from
    /// the frame he sent it, under the request's id, which the hub's copy keeps, so that copy takes its place where it
    /// stands. A message of files alone comes with the hub's copy, its files with it.
    private var drawn: [ChatEntry] {
        guard let request = requestOnItsWay, !request.text.isEmpty else { return entries }
        return entries + [.message(OwnerMessage(onItsWay: request))]
    }
    /// **What this agent asked him and still waits for** (the owner's yes of 28 October 2026, D-7): the request card
    /// itself — Needs you's, at the column's width — so he answers in the chat where the agent told him about it ("It is
    /// in Needs you."), and Needs you keeps them all. A key or a login it asked for comes with its secure form.
    private var requests: [OwnerNeed] {
        store.openNeeds.filter { $0.by == agent }.sorted { ($0.raised, $0.id) < ($1.raised, $1.id) }
    }

    /// **Every request of this agent, waiting or answered, stands right after the agent's message that told him about
    /// it** (D-7 item 1, the lead's call of 29 October 2026; `ChatRequestPlaces`): under "It is in Needs you.", as the
    /// mockup draws it, so his next message and the agent's next line stand under the card. A waiting card stood at the
    /// end of the chat, and his next message went above it. One that no message told him about waits at the end; an
    /// answered one folds to two lines where it stood (D-7 item 2), and his answer, which it shows, is no second
    /// bubble — or, told by no message, it takes his answer's place. The hub writes every answer as his message to the
    /// agent that asked (`kind` "answer").
    private var mine: [OwnerNeed] { (store.state?.needs ?? []).filter { $0.by == agent } }

    /// What this chat is waiting for, or nil. Every part of it is already read: the hub's own answer about the
    /// owner's last message (`pendingChat`), this Mac's own request on its way, and the two things that stop the
    /// agent running at all — its usage limit and its machine going quiet.
    private var waiting: ChatWaiting? {
        guard let state = store.state, let entry = state.agents.first(where: { $0.name == agent }) else { return nil }
        // A reply the hub cannot link to his message is not proof that the agent is still working: see
        // ChatWaiting.Pending.spokenSince, which the manager's every reply is. Nor is a message that it read in a
        // turn that has ended with no reply (ChatWaiting.Pending.turnOver).
        let pending = entry.pendingChat(in: state)?.waits ?? .none
        return ChatWaiting.of(agent: agent, pending: pending,
                              sending: store.sending && requestOnItsWay != nil,
                              limit: entry.limit,
                              offline: store.isFresh && !entry.helperIsRecent(serverTime: state.time),
                              until: { fleetComingTime($0, now: state.time) })
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
                    let places = ChatRequestPlaces.of(needs: needs, in: held, whole: whole)
                    let byID = Dictionary(needs.map { ($0.id, $0) }) { first, _ in first }
                    let shown = held.filter { !places.hidden.contains($0.id) }
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                        if let time = ChatStamp.time(of: entry, after: index > 0 ? shown[index - 1] : nil) {
                            ChatStamp(time: time)
                        }
                        switch entry {
                        case .message(let message):
                            if let id = places.inPlaceOf[entry.id], let need = byID[id] {
                                requestCard(need)
                            } else {
                                messageRow(message).padding(.bottom, Self.gap(under: message,
                                                                              before: index + 1 < shown.count ? shown[index + 1] : nil,
                                                                              keepsFiles: store.supportsKeptFiles))
                            }
                        // **A reply that arrives while he looks fades in where it stands** (T-20): 0.2 s, opacity
                        // only. It took the waiting line's place in one frame. Not on the first paint, and not for
                        // the earlier messages he asks for.
                        case .report(let report): reportRow(report).id(entry.id)
                            .transition(shownUpTo.map { report.id > $0 } == true
                                        ? ReplyArrival.transition(taking: lineShowing && places.atEnd.isEmpty ? lastWaiting : nil)
                                        : .identity)
                        }
                        // The requests this message told him about, in the order they were raised.
                        ForEach(places.after[entry.id] ?? [], id: \.self) { id in
                            if let need = byID[id] { requestCard(need) }
                        }
                    }
                    ForEach(places.atEnd, id: \.self) { id in
                        if let need = byID[id] { requestCard(need) }
                    }
                    // What the owner is waiting for, under his last message and above nothing: one muted line,
                    // in the place the answer will take.
                    if let waiting { ChatWaitingLine(waiting: waiting).padding(.bottom, Self.footer) }
                    Color.clear.frame(height: 1).id("latest")
                }.threadRows(top: Self.topInset)
            }
            .onScrollPhaseChange { oldPhase, phase, context in
                if phase == .interacting || phase == .tracking { followsLatest = false }
                else if phase == .idle && oldPhase != .animating {
                    followsLatest = context.geometry.contentSize.height - context.geometry.visibleRect.maxY < 100
                }
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // Text that scrolls up fades under the pill instead of running under it (T-20).
            .topFade(56)
            .onAppear { shownUpTo = store.state?.reports.lazy.filter { $0.chatAgent == agent }.map(\.id).max() ?? 0 }
            .onChange(of: store.chatTimeline.count(for: agent)) { oldCount, newCount in
                if !followsLatest && newCount > oldCount { visibleCount += newCount - oldCount }
            }
            // His message on its way is the newest entry from the frame it went, and the hub's copy, which takes its
            // place, may bring its files under it.
            .onChange(of: drawn.last) { _, _ in
                if followsLatest { proxy.scrollTo("latest", anchor: .bottom) }
            }
            .onChange(of: store.pending?.requestID, initial: true) { _, _ in
                if let request = store.messageOnItsWay(to: agent) { sent = request }
            }
            .onChange(of: requests.map(\.id)) { _, _ in
                if followsLatest { proxy.scrollTo("latest", anchor: .bottom) }
            }
            // The line appears and goes under his last message, so the view follows it as it does a reply.
            .onChange(of: waiting?.says) { _, _ in
                if followsLatest { proxy.scrollTo("latest", anchor: .bottom) }
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
                if !followsLatest {
                    Button("Latest", systemImage: "arrow.down") { proxy.scrollTo("latest", anchor: .bottom); followsLatest = true }
                        .buttonStyle(.plain).font(ChatStyle.detail).foregroundStyle(FleetStyle.muted)
                        .padding(9).background(FleetStyle.surface, in: Capsule()).padding(12)
                }
            }
            // Owner feature attachments: a file dropped anywhere in the conversation is staged in this chat's
            // composer, with the rules and the words of a file picked with the plus.
            .stageDroppedFiles(store: store, composer: FleetStore.stageKey(agent: agent), mark: true)
        }
    }

    private func messageRow(_ message: OwnerMessage) -> some View {
        SentMessageView(store: store, message: message).id("message-\(message.id)")
    }

    /// A request's card in the chat: Needs you's own, at the column's width, waiting or folded.
    private func requestCard(_ need: OwnerNeed) -> some View {
        NeedRequestCard(store: store, need: need, inChat: true).padding(.bottom, Self.footer).id("need-\(need.id)")
    }

    /// A reply, with its delivery icons when it went to a channel. **A message that the agent wrote first
    /// (`message_owner`) looks like any other** (D-2, the owner's yes of 28 October 2026): its "Sent first" line said
    /// what the conversation already shows, a message under no question of his.
    private func reportRow(_ report: ManagerReport) -> some View {
        AgentReply(text: report.text, time: report.created,
                   detail: report.delivery.map { AnyView(DeliveryLine(store: store, delivery: $0)) })
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

    /// His answer to `need` on its way, or `kept`, the one a card saw go, once the hub confirmed it.
    func answerOnItsWay(to need: OwnerNeed, kept: PendingRequest? = nil) -> PendingRequest? {
        WordsOnTheirWay.answer(to: need, pending: pending, kept: kept, receipt: lastReceipt, hub: hub, database: state?.db)
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

    /// Its time, Copy and Edit, under the pointer only.
    private var footer: some View {
        HStack(spacing: 10) {
            Text(messageTime(message.created))
                .help("\(fleetDate(message.created)) · \(message.read_at == nil ? "Received, not read yet" : "Read")"
                      + (message.edited.map { " · Edited \(messageTime($0))" } ?? ""))
            MessageAction(symbol: copied ? "checkmark" : "square.on.square", label: "Copy message") {
                copyMessage(message.text); copied = true
            }
            // His own icon for it (20 October 2026): the hooked arrow of resending, not a pencil. The words
            // of the hover say what this one will do — replace the message, or go under it as a correction.
            if editable {
                MessageAction(symbol: "arrow.uturn.right", label: "Correct",
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
    @State private var followsLatest = true
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
                LoadingLine("Reading the task…").padding(.horizontal, -FormMetrics.rowInset).threadRows(top: FleetSpace.underBand)
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
                readError = HubError.said(error) ?? "Activity is unavailable. Retrying…"
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
                        RuntimeActivity(activity: activity ?? TaskActivity(), error: store.hubNoticeShows ? nil : readError, task: task.id, attempt: task.attempt, stoppedAttempt: state.stoppedAttempt(of: task.id), terminal: task.isTerminal, isFresh: isFresh, followsLatest: $followsLatest,
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
                        StatusLabel(text: "Session missing since \(fleetDate(missing))", color: .orange)
                    }
                    // What it waits for, in his words: the hub's "Q-1" (or "P-3", "CM-7", "its screen") is a
                    // question, a prompt or a person that its requester answers (T-12), and a name is that agent; who
                    // it is, as the state word names them (`TaskWords`, fix round 2: "an answer" named nobody).
                    if let waiting = task.waiting_on, !waiting.isEmpty {
                        if let other = TaskWords.waiter(of: waiting) {
                            DetailField(title: "Waiting on", value: other, agent: waiting.lowercased())
                        } else {
                            DetailField(title: "Waiting for", value: task.requester == "owner" ? "You" : task.requester.agentLabel,
                                        agent: task.requester)
                        }
                    }
                    if task.delivered != nil {
                        Rule()
                        if let what = task.what { AgentReply(text: what, time: task.delivered, compact: true) }
                        else { MessageText(text: "No result reported") }
                        FoldRow(title: task.checkStatus, symbol: "checkmark.circle", chat: true) {
                            VStack(alignment: .leading, spacing: 10) {
                                DetailField(title: "Output", value: task.where_ ?? "Not reported")
                                DetailField(title: "How it was checked", value: task.how ?? "Not reported")
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
            .onScrollPhaseChange { oldPhase, phase, context in
                if phase == .interacting || phase == .tracking { followsLatest = false }
                else if phase == .idle && oldPhase != .animating {
                    followsLatest = context.geometry.contentSize.height - context.geometry.visibleRect.maxY < 100
                }
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // Its rows fade as they leave at the top, over the room the thread leaves above its first row (T-20): its first
            // row stands 14 pt under the band, level with the first thing of every pane (the margins of 30 October 2026,
            // row 28, and its review: it stood 26 pt under it, 12 under the panel's head beside it).
            .topFade(FleetSpace.underBand)
            .onChange(of: latestActivity) { _, _ in
                if followsLatest { proxy.scrollTo("latest-task", anchor: .bottom) }
            }
            .onChange(of: task.state) { _, _ in
                if followsLatest { proxy.scrollTo("latest-task", anchor: .bottom) }
            }
            .onChange(of: state.steers?.last(where: { $0.task == task.id })?.id) { _, _ in
                if followsLatest { proxy.scrollTo("latest-task", anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !followsLatest {
                    Button("Latest", systemImage: "arrow.down") {
                        proxy.scrollTo("latest-task", anchor: .bottom); followsLatest = true
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
        if calendar.isDateInToday(date) { day = "Today" }
        else if calendar.isDateInYesterday(date) { day = "Yesterday" }
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
    /// The first frame of the arrival: the reply clear, the line whole.
    let arriving: Bool

    static func transition(taking line: ChatWaiting?) -> AnyTransition {
        .asymmetric(insertion: .modifier(active: ReplyArrival(line: line, arriving: true),
                                         identity: ReplyArrival(line: line, arriving: false))
                        .animation(.easeOut(duration: 0.2)),
                    removal: .identity)
    }

    func body(content: Content) -> some View {
        content.opacity(arriving ? 0 : 1)
            .overlay(alignment: .topLeading) {
                // The line's still words: its shimmer is a moving layer, and this is the last fifth of a second of it.
                if let line {
                    HStack(spacing: 8) {
                        if !line.moving { Image(systemName: line.symbol).font(IconMetrics.symbol(11)).foregroundStyle(.orange) }
                        Text(line.says).font(ChatStyle.detail).foregroundStyle(line.moving ? FleetStyle.muted : .orange)
                    }
                    .opacity(arriving ? 1 : 0)
                    .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
    }
}

extension View {
    /// **The rows of a chat or a task thread end at their last row**, one rule for both (T-06, fix round of 28 October
    /// 2026): each opens at its end in one frame by the scroll's own bottom anchor, and later follows its newest row by
    /// `scrollTo(…, anchor: .bottom)`, which leaves out whatever stands under that row. Room under the last row showed on
    /// the first and not on the second: the task thread ended 66 points over its status line where it had always ended
    /// 40, and a chat's last message stood 26 points higher over its composer when it opened than after a reply. So the
    /// rows keep room over their first row only, and the column of prose.
    func threadRows(top: CGFloat) -> some View { padding(.top, top).chatColumn() }

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
