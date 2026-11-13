import FleetCore
import FleetMark
import SwiftUI
import UIKit

/// One agent's chat: the owner's messages in a grey bubble at the right and the agent's reports as bare text at the
/// left, as the Mac draws them (the owner's yes of 28 October 2026 to D-6: one look for his message on both screens),
/// a mark for the day and the time after a gap, and one time under the newest run. A message he wrote in WhatsApp or
/// Discord carries that app's mark on its bubble's corner. The requests the agent raised and that wait for him stand in
/// the conversation where they were raised, to answer there. The composer sends a message, and a long press on the last
/// message of this phone corrects it (MOBILE-APP.md 10). The manager's chat is where the owner writes a goal, as on the
/// Mac.
///
/// The shape is this platform's own chat: messages that follow each other from one side, in one client and within
/// five minutes, are one run, and the composer is one capsule of glass that grows with the text, with the
/// conversation scrolling under it. Over the conversation, the agent's mark and name stand in one glass
/// pill that opens its page; under his last message, the Mac's waiting line says what the answer waits for.
///
/// The conversation comes one page at a time from `GET /ui/mobile/chat/<agent>`: the last 30 items when the page
/// opens, then the items after its cursor while it stays open.
struct ChatPage: View {
    let store: MobileStore
    let agent: String
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.markTeam) private var team
    /// One line of the composer's text, so "+" and Send stand on that line's centre at every text size.
    @ScaledMetric(relativeTo: .body) private var line: CGFloat = 22
    /// The view is at the newest message, or within 100 points of it, so a new one may move it: the Mac's own rule.
    /// While the owner reads further up, nothing pulls him down ("incoming updates must not pull a reader away from
    /// older messages").
    @State private var followsLatest = true
    /// The chat was at its end when his drag began, and the keyboard was up: a drag that puts the keyboard away keeps
    /// it at its end (fix round 3, items 25 and 39).
    @State private var endAtDrag = false
    /// The chat went back to its end with the keyboard: the drag's own end does not undo it.
    @State private var repinned = false
    /// The composer's field has the cursor: a tap anywhere on its capsule gives it (fix round 2, item 53).
    @FocusState private var composerFocused: Bool
    /// The waiting line as it showed last, and whether it showed in the frame before this one: a reply that comes then
    /// takes its place (`ArrivalFade`), as on the Mac.
    @State private var lastLine: ChatWaiting?
    @State private var lineShowing = false
    /// The run that took the line's place and the line it took, so that its cross-fade keeps the line's words to its
    /// end: the line has gone from the frame after it came.
    @State private var taken: (run: String, line: ChatWaiting)?

    private var items: [MobileChatItem] { store.items(for: agent) }
    /// The open requests this agent raised, the oldest first, as the conversation reads.
    private var needs: [OwnerNeed] { store.openNeeds.filter { $0.by == agent }.sorted { $0.raised < $1.raised } }
    /// **Every request of this agent that the chat places: the open ones and the answered ones** (fix round 2, item
    /// 103), so an answered one folds where it stood. An item that the hub's two lists both name for a moment is open.
    private var requests: [OwnerNeed] {
        let open = needs
        let ids = Set(open.map(\.id))
        return open + store.answeredNeeds.filter { $0.by == agent && !ids.contains($0.id) }
    }
    /// The owner corrects a message of this chat now.
    private var isCorrecting: Bool { store.correcting != nil && store.correctable(in: agent) != nil }
    /// The request that waits for its receipt, when it belongs to this chat. It stays on screen until the hub
    /// confirms it or refuses it definitively, and a confirmed one until the chat's read brings the message itself.
    private var waiting: PendingRequest? {
        for request in [store.pending, store.delivered] {
            if let request, request.needID == nil, (request.recipient ?? "manager") == agent { return request }
        }
        return nil
    }
    /// The composer writes the correction while one is open, and this agent's draft otherwise.
    private var text: Binding<String> {
        isCorrecting
            ? Binding(get: { store.correctionText }, set: { store.correctionText = $0 })
            : Binding(get: { store.draft(for: agent) }, set: { store.setDraft($0, for: agent) })
    }
    private var trimmed: String { text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// The key of this chat's composer, for the files that the owner picked.
    private var composerKey: String { MobileStore.stageKey(agent: agent) }
    /// The files of this composer that the hub already holds. A correction carries none: it replaces the words of
    /// one message, and the files of that message stay with it.
    private var files: [Int] { isCorrecting ? [] : store.readyFiles(for: composerKey) }
    private var canSend: Bool {
        guard store.canWrite, store.canChat(with: agent), trimmed.count <= MobileStore.textLimit else { return false }
        guard !isCorrecting else { return !trimmed.isEmpty }
        if store.filesAreWaiting(for: composerKey) { return false }
        return !trimmed.isEmpty || !files.isEmpty
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // **One plain stack, not a lazy one** (fix round 1): a lazy stack measures the rows it has not drawn
                // by guess, so the end the chat opened at was a guess too — Nova's newest message stood under the
                // composer and Manager's at the largest text size stopped before its end. A chat holds its last
                // pages, tens of items, and every one of them is measured before the first frame.
                let rows = self.rows
                // His time stands under the newest run, also when a card follows it.
                let newest = rows.last { $0.isRun }?.id
                let arrived = store.arrivals[agent] ?? [:]
                VStack(alignment: .leading, spacing: 10) {
                    // **A chat that opened with nothing read says so after a second** (fix round 2, item 104): the one
                    // loading look in its first slot, held half a second once it shows (`MobileStore.settle`). On a
                    // slow hub the chat stood empty until its read came.
                    if isBlank && !store.hasRead(chat: agent) && store.readCanCome {
                        LoadingLine("Reading…")
                    }
                    ForEach(rows) { row in
                        switch row {
                        case .run(let run):
                            if let stamp = run.stamp { stampLine(stamp) }
                            // **A reply takes the waiting line's place in one cross-fade** (D-6, fix round 3d): the
                            // line went, and its place stood empty for three frames before the reply's fade began.
                            let arrival = Self.arrival(of: run, isLast: row.id == rows.last?.id,
                                                       arrived: Set(arrived.keys),
                                                       line: taken?.run == row.id ? taken?.line
                                                           : lineShowing ? lastLine : nil)
                            bubbles(run, isNewest: row.id == newest, arrived: arrived, taking: arrival.taking)
                        case .request(let need, let stamp):
                            // In the place of his answer, the answer's mark for the day or the hour stands over it.
                            if let stamp { stampLine(stamp) }
                            // **The request card in the chat** (D-7): what the agent asks him, answered where it is
                            // asked, on the text column as the agent's words are (fix round 2, item 78: it stood 2
                            // points wider at each side). Answered, it is two lines (item 103). **The stack's 10
                            // points from the message above it, as between two runs** (margins pass, fault 19): 4 more
                            // made it 14, though it belongs to the message above it.
                            NeedCard(store: store, need: need,
                                     answerFiles: items.last { $0.answer_to == need.id }?.attachments ?? [])
                        }
                    }
                    // **What the answer waits for** ("Thinking"), its room kept from the send's first frame (fix round 2,
                    // item 74), so it comes into it at the receipt and moves nothing; it fades in. **It goes in one
                    // frame, and a reply that takes its place draws its last words at the top of the reply's own
                    // place, where the two cross-fade** (`ArrivalFade`; fix round 3d), so no frame shows neither.
                    if let line = waitingLine {
                        ChatWaitingLine(waiting: line.waiting, agent: agent)
                            // Only its opacity moves: its place follows the conversation in the same frame.
                            .animation(.easeOut(duration: 0.15)) { $0.opacity(line.shows ? 1 : 0) }
                            .accessibilityHidden(!line.shows)
                            .transition(.identity)
                    }
                    // The end of the conversation, under the last run's time: the stack's 10 points above it and
                    // these 2 are the 12 at its foot, so a scroll to it shows the newest message whole.
                    Color.clear.frame(height: 2).id(Self.end)
                }
                // **The app's 16-point sides** (margins pass, fault 9): the column was 14, and the agent's words, the
                // cards and the lines stood 2 points in from it, so his bubbles alone reached 2 points past the edge
                // that every other page keeps.
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The scroll view that opens with messages stands at their end, whatever its own anchor makes of the
            // composer under it: a scroll that is already there moves nothing.
            .onAppear { if !isBlank { proxy.scrollTo(Self.end, anchor: .bottom) } }
            // **A chat's first messages come into a new scroll view, which opens at its end**: the first frame with
            // messages shows the newest one above the composer, and nothing moves after it. Into the scroll view
            // that stood empty they came at its top and then scrolled through the whole conversation to the newest
            // one — about 2,600 pt in 165 ms, with text sharp under the title until the push ended — or, in a short
            // one, came 31 px low and slid up over 200 ms.
            .id(isBlank)
            .background(Brand.canvas)
            // It opens at the end, a short chat sits on the composer, and what comes or goes at the end — a message,
            // the keyboard — keeps the end in view while he is there and keeps his place while he reads above.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .alignment)
            .defaultScrollAnchor(followsLatest ? .bottom : .top, for: .sizeChanges)
            .scrollDismissesKeyboard(.interactively)
            // **Nothing reads sharp under the composer** (fix round 2, items 52 and 91): the system's soft edge fades
            // the conversation where it runs under the glass and in the band below it.
            .softBottomEdge()
            .onScrollPhaseChange { oldPhase, phase, context in
                if phase == .interacting || phase == .tracking {
                    // At its end with the keyboard up: the drag may be the one that puts the keyboard away.
                    if oldPhase == .idle {
                        endAtDrag = followsLatest && context.geometry.contentInsets.bottom > 200
                        repinned = false
                    }
                    followsLatest = false
                } else if phase == .decelerating, repinned {
                    // **The drag's release flings the chat after the keyboard has gone** (fix round 3, items 25 and 39):
                    // it came back to its end with the keyboard, and the release's speed then carried it 166 points to
                    // its top over 0.5 s. A still scroll to the end in the fling's first frame stops it there.
                    Self.still { proxy.scrollTo(Self.end, anchor: .bottom) }
                } else if phase == .idle && oldPhase != .animating {
                    let atEnd = Self.toEnd(context.geometry) < 100
                    if repinned {
                        // Back at its end with the keyboard: it stays there until his next drag.
                    } else if endAtDrag {
                        // The keyboard may still be going: a drag that did not put it away is an ordinary scroll.
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(600))
                            if endAtDrag { endAtDrag = false; followsLatest = atEnd }
                        }
                    } else {
                        followsLatest = atEnd
                    }
                }
            }
            // **While he is at the end, the end stays in view**: when what the chat holds grows — a reply, the waiting
            // line, a request's card, a picture's place — or the room for it changes — the composer, the keyboard,
            // the line over the page — the newest line stands again on the composer, in the same frame. **The room
            // counts the insets** (fix round 2, items 73 and 77): the keyboard, the composer and the line over the page
            // change the scroll view's insets and not its frame, so the newest message stayed where the keyboard had
            // been, 45 to 145 points under the composer, and the next message jumped the chat 163 points.
            .onScrollGeometryChange(for: Room.self) { geometry in
                Room(content: geometry.contentSize.height, visible: geometry.visibleRect.height,
                     top: geometry.contentInsets.top, bottom: geometry.contentInsets.bottom)
            } action: { old, new in
                // **A drag that puts the keyboard away keeps a chat that was at its end there** (fix round 3, items 25
                // and 39), as Messages does: the drag itself scrolled the chat, and once the keyboard had gone the
                // newest message stood under the composer and a reply came out of view. The chat goes back to its end
                // with the keyboard, over its 0.25 s; nothing moves after the keyboard has gone.
                if endAtDrag, new.bottom < old.bottom - 40 {
                    endAtDrag = false
                    followsLatest = true
                    repinned = true
                    // At the animation's end a still scroll to the end stops what is left of the drag's own motion: it went
                    // on and took the chat 350 points away from its end over 0.75 s after the keyboard had gone.
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(Self.end, anchor: .bottom) } completion: {
                        Self.still { proxy.scrollTo(Self.end, anchor: .bottom) }
                    }
                    return
                }
                guard followsLatest, old != new else { return }
                Self.still { proxy.scrollTo(Self.end, anchor: .bottom) }
            }
            .onChange(of: items.last?.id) { old, id in
                // Only a new message in a chat that is already drawn moves the view, and only while he is at the end.
                guard old != nil, id != nil, followsLatest else { return }
                Self.still { proxy.scrollTo(Self.end, anchor: .bottom) }
            }
            .onChange(of: waiting?.requestID) { _, id in
                // **His own message is there in the frame his field empties in** (fix round 1), above the composer and
                // the keyboard, with no scroll to watch: it came 178 ms after the field cleared, at the end of an eased
                // scroll.
                guard id != nil else { return }
                followsLatest = true
                Self.still { proxy.scrollTo(Self.end, anchor: .bottom) }
            }
            // The line as it shows. The frame that a reply comes in still holds the line before it, so the reply takes
            // that line's place; once the line has gone, the run that took it keeps its words to its cross-fade's end.
            .onChange(of: shownLine, initial: true) { old, now in
                if let old, now == nil, let last = rows.last, case .run(let run) = last,
                   Self.arrival(of: run, isLast: true, arrived: Set((store.arrivals[agent] ?? [:]).keys),
                                line: old).taking != nil {
                    taken = (last.id, old)
                }
                lineShowing = now != nil
                if let now { lastLine = now }
            }
        }
        // A card that comes or goes. An answered one folds to its two lines in one step (`NeedAnswered`).
        .animation(.easeOut(duration: 0.25), value: requests.map(\.id))
        .overlay {
            // **An empty chat shows his logo, muted, in the middle of the free space** (the owner, 20 October 2026:
            // "just the Founderizer logo, muted, centred"; his yes of 28 October 2026 to D-7 for the phone too). It
            // stood as a symbol, "No messages yet" and a sentence. A chat that was not read yet is not empty: it shows
            // nothing until its first read answers. Nor is a chat whose newest line the fleet's read names.
            if isBlank && store.hasRead(chat: agent) && store.agent(agent)?.last == nil {
                FounderizerMark(size: 96, plate: Self.emptyPlate, ink: Self.emptyInk)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .composerBar { composer }
        .task(id: agent) {
            store.beginWait(chat: agent)
            await store.refresh()
        }
        // What came while the chat was open draws at once the next time (item 75).
        .onDisappear { store.settleArrivals(of: agent) }
        .refreshable { await store.refresh() }
        .navigationTitle(agentName(agent))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The pill draws its own glass: the bar's shared one would be a second shape around it.
            if #available(iOS 26.0, *) {
                ToolbarItem(placement: .principal) { titlePill }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .principal) { titlePill }
            }
        }
        // **No message text under the title** (fix round 1): a chat opens at its end, so its words stood sharp under
        // the title and Back for the whole push (+62 → +410 ms), until the bar's soft edge came. The bar is the
        // page's own canvas from the first frame, and the pill and Back stand on it.
        .toolbarBackground(Brand.canvas, for: .navigationBar)
        .toolbarBackgroundVisibility(.visible, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .hubBanner(store)
    }

    /// **The agent's mark and name in one glass pill over the conversation** (the owner's yes of 28 October 2026 to
    /// D-6): the mark at 20 points, breathing while the agent works, grey while it is offline and dashed in setup. **The
    /// name opens the agent's own page** (D-5), with the "›" that says so, as a chat app opens a contact from the name
    /// over the conversation.
    private var titlePill: some View {
        Button { store.chatRoute.append(.agent(agent)) } label: {
            HStack(spacing: 8) {
                // With its presence dot, as every mark before a name (fix round 3, item 54; D-8 item 2).
                AgentMark(name: agent, state: state, size: 20)
                Text(agentName(agent)).font(.headline).foregroundStyle(Color.primary)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Brand.muted)
            }
            // The same room at the two ends of the capsule (margins pass, fault 21): the chevron's ink stood 15.5
            // points from the right end, the mark 12.5 from the left.
            .padding(.leading, 12).padding(.trailing, 11)
            // **Drawn 36 points high, its tap 44** (fix round 2, item 93): it was drawn 40.
            .frame(minHeight: 36)
            .titlePill()
            // **The dot stands over the glass, not in it** (fix round 3b, item 54): inside, the glass's vibrancy made
            // the green of work pale mint and the orange yellow in dark, with a grey halo and the glyph's line across
            // it. Over it, the dot is Chats' colour in every mode. Its place is the mark's corner, as on Chats.
            .overlay(alignment: .leading) {
                if state.hasDot(reduceMotion: reduceMotion) {
                    StatusDot(state: state, size: 8).offset(x: 24, y: 6).allowsHitTesting(false)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(agentName(agent)), \(state.words)")
        .accessibilityHint("Opens the agent's page")
        .accessibilityIdentifier("open-agent")
    }

    /// This agent's state, as its row on Chats shows it: at work also while the line under his last message says
    /// "Thinking" and moves, so the mark over the chat moves with the line's own.
    private var state: AgentState {
        guard let entry = store.agent(agent), let snapshot = store.snapshot else { return .unknown }
        return entry.mobileState(in: snapshot, isFresh: store.showsCurrent, thinking: shownLine?.moving == true)
    }

    /// **What the answer waits for, as the Mac's chat says it** (`ChatWaiting`, FleetCore; the owner's yes of 28
    /// October 2026 to D-6): "Thinking" while the agent holds his newest message and no reply names it, and "Usage
    /// limit" or "Not answering" while something that is not its work holds it. Nothing from a reading that is not
    /// current. **While his message is on its way the line keeps its room, unseen** (`shows` false; fix round 2, item
    /// 74): it shows at the receipt, in the room it had, so his bubble does not move when it comes. **So does an old
    /// reading that is being read again** (D-1 rule 2; fix round 3d): its words go, since an old reading cannot say
    /// that the agent works now, and come back when a read answers; nothing moves. A failed read has no line.
    private var waitingLine: (waiting: ChatWaiting, shows: Bool)? {
        let current = store.showsCurrent
        guard current || store.readsAgain, let entry = store.agent(agent), let snapshot = store.snapshot else {
            return nil
        }
        let pending: ChatWaiting.Pending
        var shows = current
        if let waiting {
            // A message the hub took and the chat's read has not brought yet is his newest message.
            if store.delivered?.requestID == waiting.requestID {
                pending = .waiting
            } else if waiting.refusal == nil, store.sending {
                pending = .waiting
                // A line that already showed for his message before this one stays; else it waits for the receipt.
                shows = shows && Self.pending(in: items, turnEndedAfter: entry.turn_ended_after) == .waiting
            } else {
                return nil
            }
        } else {
            // a word of the agent with no link does not end the wait of a message that the hub calls late
            pending = Self.pending(in: items, turnEndedAfter: entry.turn_ended_after).late(entry.chat_undelivered)
        }
        guard let line = ChatWaiting.of(agent: agent, pending: pending, sending: false, limit: entry.limit,
                                        // also when its server answers and his message does not arrive
                                        offline: !entry.helperIsRecent(serverTime: snapshot.time)
                                            || entry.chat_undelivered == true,
                                        until: { comingTime($0, now: store.hubNow) }) else { return nil }
        return (line, shows)
    }

    /// The waiting line while it shows.
    private var shownLine: ChatWaiting? { waitingLine.flatMap { $0.shows ? $0.waiting : nil } }

    /// **How a run comes into the chat** (D-6, fix round 3d): a run of the agent's words that came while the chat was
    /// open fades in, and when it is the last row it takes the place of the waiting line that showed over it, as the
    /// Mac's reply does (`ArrivalFade`). Under a card that waits at the end the line stood lower, under the card, and
    /// simply goes.
    static func arrival(of run: Run, isLast: Bool, arrived: Set<String>,
                        line: ChatWaiting?) -> (fades: Bool, taking: ChatWaiting?) {
        guard run.fromAgent, let first = run.items.first, arrived.contains(first.id) else { return (false, nil) }
        return (true, isLast ? line : nil)
    }

    /// What the hub shows about his newest message in this chat, by the Mac's rule (`FleetAgent.pendingChat`): only a
    /// reply that names that message answers it; a report since then that names none says nothing either way; a
    /// report the agent wrote first is no reply. **His answer to a request is no message that waits** (item 103), as on
    /// the Mac, whose rule reads the messages of kind "message" only: "Thinking" stood under the folded card.
    /// **A message that the agent read in a turn that has ended is not worked on** (hub 1.110; the agent's
    /// `turn_ended_after`, as on the Mac): the manager wrote no reply to three messages that asked for none, and
    /// "Thinking" turned under them for more than an hour (10 November 2026).
    static func pending(in items: [MobileChatItem], turnEndedAfter: Double? = nil) -> ChatWaiting.Pending {
        guard let message = items.last(where: { $0.kind == .message && $0.answer_to == nil }) else { return .none }
        let replies = items.filter { $0.kind == .report && !$0.isPushed }
        if replies.contains(where: { $0.in_reply_to?.caseInsensitiveCompare(message.key) == .orderedSame }) {
            return .none
        }
        if replies.contains(where: { $0.in_reply_to == nil && $0.ts >= message.ts }) { return .spokenSince }
        if ChatWaiting.turnIsOver(sent: message.ts, turnEndedAfter: turnEndedAfter) { return .turnOver }
        return .waiting
    }

    /// What decides where the end of the chat stands: its content, the scroll view's height and its insets.
    private struct Room: Equatable {
        let content: CGFloat
        let visible: CGFloat
        let top: CGFloat
        let bottom: CGFloat
    }

    /// How far the end of the conversation stands below what shows over the composer: 0 at the end. The insets count,
    /// so a keyboard's 300 points under the composer are not taken for the end of the chat.
    static func toEnd(_ geometry: ScrollGeometry) -> CGFloat {
        geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY
    }

    /// A change of the view's place with no animation, whatever transaction it runs in.
    private static func still(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }

    /// **The empty chat's logo, muted, with its chevrons lighter than its plate in both appearances**, as the mark's own
    /// white chevrons are and as the Mac draws it (fix round 2, item 67): in dark the chevrons took the canvas, darker
    /// than the plate, and the logo read as its negative. Light keeps the bubble's plate and the canvas's chevrons; dark
    /// takes the Mac's two steps over the canvas.
    private static let emptyPlate = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0x1D / 255, green: 0x1E / 255, blue: 0x1F / 255, alpha: 1)
            : UIColor(named: "BrandBubble", in: nil, compatibleWith: traits) ?? .systemGray5
    })
    private static let emptyInk = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0x33 / 255, green: 0x34 / 255, blue: 0x36 / 255, alpha: 1)
            : UIColor(named: "BrandCanvas", in: nil, compatibleWith: traits) ?? .systemBackground
    })

    /// The id of the conversation's end.
    private static let end = "end"
    /// Nothing of the conversation is drawn yet: no message, no request of the agent's and none of his on its way.
    private var isBlank: Bool { items.isEmpty && waiting == nil && needs.isEmpty }

    // MARK: The runs

    /// One row of the conversation: a run of messages, or a request's card, with the mark for the day or the hour over
    /// a card that stands in the place of his answer.
    enum Row: Identifiable {
        case run(Run)
        case request(OwnerNeed, stamp: Double?)
        var id: String {
            switch self {
            case .run(let run): "run-" + run.id
            case .request(let need, _): "request-\(need.id)"
            }
        }
        var isRun: Bool { if case .run = self { true } else { false } }
    }

    /// The places of this agent's requests among the items, by the Mac's own rule (`ChatRequestPlaces`, FleetCore): each
    /// one right after the agent's message that told him about it ("It is in Needs you."), else a waiting one at the
    /// end and an answered one in the place of his answer. **An answered one whose answer this chat has not read yet
    /// stands at the end, where that answer comes** (item 103): the phone reads the requests and the chat one after the
    /// other, so between the two reads a card that no message told him about had no place, and went for a moment.
    static func places(of needs: [OwnerNeed], in items: [MobileChatItem], agent: String) -> ChatRequestPlaces {
        // Read only while the agent has a request: most chats have none.
        guard !needs.isEmpty else { return ChatRequestPlaces() }
        var places = ChatRequestPlaces.of(needs: needs, in: entries(items, agent: agent), whole: false)
        // **A waiting card whose answer this chat has read already shows that answer** (polish pass): the open chat
        // reads before the fleet, so for a moment his answer is in the chat while its request still waits at the end.
        // The answer stood as a bubble over the card until the fleet's read, and the chat moved up and back (48 points)
        // before the card folded. The fleet's read then puts the card in its answer's place, where it stands.
        for id in places.atEnd {
            if let answer = items.first(where: { $0.kind == .message && $0.answer_to == id }) {
                places.hidden.insert(answer.id)
            }
        }
        guard let newest = items.last?.ts else { return places }
        let placed = Set(places.after.values.joined()).union(places.atEnd).union(places.inPlaceOf.values)
        let late = needs.filter { !$0.isOpen && !placed.contains($0.id) && ($0.answered ?? 0) > newest }
        guard !late.isEmpty else { return places }
        places.atEnd = (needs.filter { places.atEnd.contains($0.id) } + late)
            .sorted { ($0.raised, $0.id) < ($1.raised, $1.id) }.map(\.id)
        return places
    }

    /// The runs, with **each request right after the agent's message that told him about it** ("It is in Needs you."),
    /// by the Mac's own rule (`places`): his next message and the agent's next line stand under the card on both
    /// screens. The message a card follows ends its run. **An answered card shows his answer, so the answer is no second
    /// bubble** (fix round 2, item 103): where a message told him, his answer is not drawn; where none did, the card
    /// takes his answer's place, between the runs around it, with the answer's mark for the day or the hour.
    static func rows(_ lines: [MobileChatItem], needs: [OwnerNeed], places: ChatRequestPlaces) -> [Row] {
        let byID = Dictionary(needs.map { ($0.id, $0) }) { first, _ in first }
        var rows: [Row] = []
        var run: [MobileChatItem] = []
        var stamp: Double?
        // The item before, drawn or in a card's place: the marks for the day and the hour count from it.
        var previous: MobileChatItem?

        func mark(over item: MobileChatItem) -> Double? {
            guard let previous else { return item.ts }
            let sameDay = Calendar.current.isDate(Date(timeIntervalSince1970: previous.ts),
                                                  inSameDayAs: Date(timeIntervalSince1970: item.ts))
            return item.ts - previous.ts > 3600 || !sameDay ? item.ts : nil
        }
        func close() {
            if !run.isEmpty { rows.append(.run(Run(items: run, stamp: stamp))) }
            run = []
        }

        for item in lines where !places.hidden.contains(item.id) {
            if let id = places.inPlaceOf[item.id], let need = byID[id] {
                close()
                rows.append(.request(need, stamp: mark(over: item)))
                previous = item
                continue
            }
            if let last = run.last,
               last.kind != item.kind || last.client != item.client || last.isPushed != item.isPushed
                   || item.ts - last.ts > 300 {
                close()
            }
            if run.isEmpty { stamp = mark(over: item) }
            run.append(item)
            previous = item
            let cards = (places.after[item.id] ?? []).compactMap { byID[$0] }
            if !cards.isEmpty {
                close()
                rows += cards.map { .request($0, stamp: nil) }
            }
        }
        close()
        return rows + places.atEnd.compactMap { byID[$0] }.map { .request($0, stamp: nil) }
    }

    /// The conversation as FleetCore's `ChatEntry`, so the Mac's rule reads the phone's items: the ids are the same
    /// ("message-<request>", "report-<number>"), and a message that answers a request is an answer to it, as the Mac
    /// reads it. `whole` is false for the phone, which holds the newest pages only: a request older than every item it
    /// holds waits at the end, where he sees it.
    static func entries(_ items: [MobileChatItem], agent: String) -> [ChatEntry] {
        items.compactMap { item in
            switch item.kind {
            case .message:
                var object: [String: Any] = ["request_id": item.key, "kind": "message", "text": item.text, "event_id": 0,
                                             "created": item.ts, "client": item.client ?? "", "recipient": agent]
                if let need = item.answer_to {
                    object["kind"] = "answer"
                    object["need_id"] = need
                }
                guard let data = try? JSONSerialization.data(withJSONObject: object),
                      let message = try? JSONDecoder().decode(OwnerMessage.self, from: data) else { return nil }
                return .message(message)
            case .report:
                guard let number = Int(item.key) else { return nil }
                let object: [String: Any] = ["id": number, "agent": agent, "text": item.text, "about": item.about ?? "",
                                             "created": item.ts]
                guard let data = try? JSONSerialization.data(withJSONObject: object),
                      let report = try? JSONDecoder().decode(ManagerReport.self, from: data) else { return nil }
                return .report(report)
            }
        }
    }

    /// Messages that follow each other from one side, written in one client and within five minutes, with the mark
    /// that goes above them when more than an hour or a day has passed since the message before.
    struct Run: Identifiable {
        let items: [MobileChatItem]
        let stamp: Double?
        var id: String { items.first?.id ?? "empty" }
        var fromAgent: Bool { items.first?.kind == .report }
    }

    /// **His message on its way, as the item it will be** (fix round 2, item 74), so it stands in its run, under its
    /// stamp, with the time's place under it from the send's first frame: the read that brings the message itself
    /// replaces it in place. It stood after every run, and the run above kept the newest time until the read moved it
    /// down, which lifted his bubble 16 points 63 ms after the send.
    private var waitingItem: MobileChatItem? {
        guard let waiting, inPlace == nil, !items.contains(where: { $0.kind == .message
            && $0.key.caseInsensitiveCompare(waiting.requestID.uuidString) == .orderedSame }) else { return nil }
        return MobileChatItem(waiting: waiting)
    }

    /// **His correction on its way of a message that nothing read yet, in that message's own bubble** (review A2; owner
    /// feature `edit_in_place`): the hub changes the message where it stands and writes no correction under it, so the
    /// new words show in its place and no second bubble comes. A stray "Correction" bubble stood at the end until his
    /// next send, and the old words stayed. The message's id, while the correction waits for its receipt.
    private var inPlace: String? { waiting.flatMap { store.editsInPlace($0) } }

    /// The conversation as it draws: what the hub gave, a correction on its way in its message's place, and his
    /// message on its way at its end.
    private var lines: [MobileChatItem] {
        let shown = if let inPlace, let waiting { MobileStore.edit(items, message: inPlace, to: waiting.text) } else { items }
        return shown + (waitingItem.map { [$0] } ?? [])
    }

    /// The conversation as rows: its runs, and the request cards in their places.
    private var rows: [Row] {
        let requests = self.requests
        return Self.rows(lines, needs: requests, places: Self.places(of: requests, in: items, agent: agent))
    }

    /// The run ends with the message that his correction on its way changes where it stands.
    private func endsInPlace(_ run: Run) -> Bool {
        guard let inPlace, let last = run.items.last else { return false }
        return last.kind == .message && last.key.caseInsensitiveCompare(inPlace) == .orderedSame
    }

    /// The mark for the day or the hour over a run, or over a card in his answer's place.
    private func stampLine(_ stamp: Double) -> some View {
        chatStamp(stamp)
            .font(.caption2).foregroundStyle(Brand.muted)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 6)
    }

    // MARK: The bubbles

    /// One run, and **one time under the newest run only** (the owner's yes of 28 October 2026 to D-7): a time under
    /// every run said again what the marks for the day and the hour already say.
    /// `arrived`: the agent's words that came while the chat was open, with when they came. `line`: the waiting line
    /// that this run takes the place of, or nil.
    private func bubbles(_ run: Run, isNewest: Bool, arrived: [String: Date], taking line: ChatWaiting?) -> some View {
        let side: HorizontalAlignment = run.fromAgent ? .leading : .trailing
        // The chat app his messages of this run came from, on the corner of the run's last bubble.
        let app = run.fromAgent ? nil : ChatAppMark.app(of: run.items.last?.client)
        // Bare reports of one run stand a paragraph apart; his bubbles of one run touch, as one block.
        let spacing: CGFloat = run.fromAgent ? 12 : 2
        return VStack(alignment: side, spacing: spacing) {
            ForEach(run.items) { item in
                // The agent's words that come while the chat is open fade in, as the Mac's reply does (item 75): its
                // words, not the time under them.
                ArrivalFade(since: run.fromAgent ? arrived[item.id] : nil) { shown in
                    Group {
                        if let waiting, item.id == waitingItem?.id {
                            waitingBubble(waiting)
                        } else {
                            bubble(item, fromAgent: run.fromAgent, app: item.id == run.items.last?.id ? app : nil)
                        }
                    }
                    .opacity(shown)
                }
                .id(item.id)
            }
            // **The time stands 3 points under every run, on the run's own edge** (margins pass, fault 4): under an
            // agent's words it stood 13 points down, past the run's paragraph spacing, and 2 points in from the words.
            if isNewest || endsInPlace(run) { footnote(run).padding(.top, 3 - spacing) }
        }
        .frame(maxWidth: .infinity, alignment: run.fromAgent ? .leading : .trailing)
        .overlay(alignment: .topLeading) {
            // **The waiting line's last words, still, at the top of the reply that takes its place** (fix round 3d), on
            // the same clock as the reply's words: they fade out as the reply fades in, so the frame the line goes in
            // shows its words where the reply will stand. Its shimmer is a moving layer, and this is its last fifth of a
            // second.
            if let line, let first = run.items.first, let since = arrived[first.id] {
                ArrivalFade(since: since) { shown in
                    ChatWaitingLine(waiting: line, agent: agent, still: true).opacity(1 - shown)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }

    /// One message or one report. A long press offers the correction, as this platform offers to edit the last
    /// message of a conversation. An agent's report is drawn from its Markdown, as the Mac draws it, bare on the page;
    /// the owner's own message is drawn from its Markdown too, in the Mac's grey bubble (D-6). It was violet, and the
    /// agent's report sat in a grey bubble: the two screens drew one conversation two ways. His words were literal
    /// until 3 November 2026, when his numbered list read as one block of plain text ("it is so plain").
    @ViewBuilder private func bubble(_ item: MobileChatItem, fromAgent: Bool, app: String? = nil) -> some View {
        let body = VStack(alignment: fromAgent ? .leading : .trailing, spacing: 4) {
            // A message may carry files and no words: then the files are the message, and no empty bubble shows.
            if !item.text.isEmpty {
                if fromAgent {
                    ReplyText(text: item.text)
                        .textSelection(.enabled)
                        .foregroundStyle(Color.primary)
                        .multilineTextAlignment(.leading)
                } else {
                    ReplyText(text: item.text)
                        .textSelection(.enabled)
                        .foregroundStyle(Color.primary)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Brand.bubble, in: Self.bubbleShape)
                        // Where he wrote it, when it was WhatsApp or Discord: the app's mark on the bubble's corner.
                        .overlay(alignment: .bottomLeading) {
                            if let app { ChatAppMark(app: app).offset(x: -9, y: 9) }
                        }
                }
            }
            if !item.attachments.isEmpty {
                AttachmentGallery(store: store, files: item.attachments,
                                  alignment: fromAgent ? .leading : .trailing)
            }
            if item.replaces != nil {
                Text("Correction").font(.caption2).foregroundStyle(Brand.muted)
            }
        }
        // A report takes the column's width, as the Mac's does; his bubble keeps its room at the left: 75 points, so it
        // is at most 80 % of the column (fix round 2, item 92; 56 let it take 85.5 %).
        .padding(fromAgent ? .trailing : .leading, fromAgent ? 24 : Self.bubbleRoom)
        .frame(maxWidth: .infinity, alignment: fromAgent ? .leading : .trailing)

        if store.canCorrect(item, in: agent) {
            body.contextMenu {
                // The composer takes the focus, its cursor after the last word (fix round 3c, item 1): it took one tap more.
                Button("Correct", systemImage: "pencil") { store.beginCorrection(item, in: agent); composerFocused = true }
            }
        } else {
            body
        }
    }

    /// His bubble: one radius at every corner, as the Mac's bubble has.
    private static let bubbleShape = RoundedRectangle(cornerRadius: 18, style: .continuous)
    /// The room at the left of his bubble.
    private static let bubbleRoom: CGFloat = 75

    /// The time the newest run says quietly under itself. Where he wrote his own message is the chat app's mark on
    /// its bubble, and nothing for his own apps; "Sent first" under a report that answers nothing went with D-2.
    /// **Under his message on its way, the time's place says where it stands** (fix round 2, item 74): "Sending…" for a
    /// send that takes a second, then the time when the hub took it, in the place the message's own time will take.
    @ViewBuilder private func footnote(_ run: Run) -> some View {
        if let waiting, let last = run.items.last, last.id == waitingItem?.id {
            waitingSlot(waiting)
        } else if let waiting, endsInPlace(run), waiting.refusal != nil || !store.sending {
            // A correction in place keeps the message's time while it goes; only what stops it takes the time's place.
            waitingSlot(waiting)
        } else {
            Text(run.items.last.map { fleetTime($0.ts) } ?? "")
                .font(.caption2).foregroundStyle(Brand.muted)
        }
    }

    /// The time's place under his message on its way: one line of the time's own height from the first frame.
    private func waitingSlot(_ request: PendingRequest) -> some View {
        ZStack(alignment: .trailing) {
            Text(verbatim: "0:00").font(.caption2).hidden()
            if store.delivered?.requestID == request.requestID {
                // Sent: the hub confirmed it, and the message itself takes this place with the chat's next read.
                Text(fleetTime(request.createdAt.timeIntervalSince1970)).font(.caption2).foregroundStyle(Brand.muted)
            } else if let refusal = request.refusal {
                // One line, as "Not sent · Try again" (fix round 3, item 29).
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(refusal).font(.caption2).foregroundStyle(Brand.warning)
                        .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                    // Each action only while it can act, never grey (review B2i).
                    TextAction(title: "Discard", font: .caption) { store.discardRefused() }
                }
            } else if store.sending {
                Held { Text("Sending…").font(.caption2).foregroundStyle(Brand.muted) }
            } else {
                HStack(spacing: 10) {
                    Text("Not sent").font(.caption2).foregroundStyle(Brand.warning)
                    if store.canRetry {
                        TextAction(title: "Try again", font: .caption) { Task { await store.retry() } }
                    }
                }
            }
        }
        .accessibilityIdentifier("waiting-state")
    }

    /// His message on its way: the same bubble as a sent one, its files and "Correction". Where it stands is said in
    /// the time's place under it (`waitingSlot`), as this platform's own chat does; a bubble faded until it is
    /// confirmed takes the words with it, and the words are the part that has to stay readable.
    private func waitingBubble(_ request: PendingRequest) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            // A 422 empties the text on this phone; then the bubble goes and only the reason stays.
            if !request.text.isEmpty {
                Text(verbatim: request.text)
                    .textSelection(.enabled)
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Brand.bubble, in: Self.bubbleShape)
            }
            if !request.attachments.isEmpty {
                AttachmentStrip(store: store, composer: composerKey, sending: request.attachments)
                    .frame(maxWidth: 240, alignment: .trailing)
            }
            if request.replacesRequestID != nil {
                Text("Correction").font(.caption2).foregroundStyle(Brand.muted)
            }
        }
        .padding(.leading, Self.bubbleRoom)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityIdentifier("waiting-message")
    }

    // MARK: The composer

    @ViewBuilder private var composer: some View {
        // **A chat that takes no message has no composer** (T-05): its one line says why, in the composer's glass.
        // Echo's chat drew a field that took no words, a plus and a Send that could do nothing.
        if let words = store.chatUnavailableWords(agent) {
            ComposerNote(words: words, isWarning: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18).padding(.vertical, 15)
                .composerGlass()
                .padding(.horizontal, 16).padding(.bottom, 6)
        } else {
            field
        }
    }

    /// **One capsule of glass, with "+" and Send inside it** (the owner's yes of 28 October 2026 to D-6), **16 points from
    /// the sides, the edge of the messages and the cards above it** (the owner, 30 October 2026: "16 pt, as the rest";
    /// margins pass, fault 17): it was 12, a 4-point step under a card. One line at rest is 50 points high; it grows with the text to ten lines, then scrolls, and a
    /// correction, the staged files and the one note stand inside it. The conversation scrolls under it.
    private var field: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isCorrecting { correctionBanner }
            if !isCorrecting {
                // 14 points from the capsule's edge at its side and at its top (margins pass, fault 20): the strip's own
                // 8 at the top, and 6 more.
                AttachmentStrip(store: store, composer: composerKey).padding(.horizontal, 14).padding(.top, 6)
            }
            HStack(alignment: .bottom, spacing: 0) {
                // The two buttons stop growing at the largest ordinary text size, each with its 44-point touch, so
                // the field keeps its room: at the largest size they took 153 points and the field read "Mess…".
                // The page's title names the agent, so there the field says only "Message".
                // **"+" and Send on the line's centre** (T-28, fix round 1): each stands in a box the height of the
                // field's one line, so at every text size they are centred on it, and on the last line once it grows.
                if showsPlus {
                    AttachmentButton(store: store, composer: composerKey, bare: true)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .frame(height: line + 28)
                }
                // The placeholder in the brand's colour for it: the system's grey was 1.7:1 on the field.
                let placeholder = isCorrecting ? "Correct your message"
                    : typeSize.isAccessibilitySize ? "Message" : "Message \(agentName(agent))"
                TextField(text: text, prompt: Text(placeholder).foregroundStyle(Brand.placeholder), axis: .vertical) {
                    Text(placeholder)
                }
                // Ten lines, then it scrolls, as the Mac's composer and his rule (fix round 2, item 94): it was six.
                .lineLimit(1...10)
                .textFieldStyle(.plain)
                .focused($composerFocused)
                .padding(.vertical, 14)
                .padding(.leading, showsPlus ? 0 : Self.wordsWithoutPlus - Self.rowStart)
                .padding(.trailing, 6)
                .accessibilityIdentifier("chat-text")
                // **Send is the agent's colour while it can send** (D-6): the circle in the glyph's own mid colour (fix
                // round 2, item 90; the deep step stood far from a blue glyph), the arrow near-black or white,
                // whichever reads stronger on it.
                let look = MarkTeam.look(of: agent, in: team)
                SendButton(enabled: canSend, label: isCorrecting ? "Send correction" : "Send message", side: 36,
                           fill: look.mid, arrow: Self.arrow(on: look.mid)) {
                    if isCorrecting { await store.sendCorrection(in: agent) } else { await store.send(to: agent) }
                }
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .frame(height: line + 28)
                .accessibilityIdentifier(isCorrecting ? "send-correction" : agent == "manager" ? "send-goal" : "send-message")
            }
            // **"+" is concentric with the capsule's round end, as Send is** (margins pass, fault 6): its centre stood
            // 28.8 points from the end, Send's 25.
            .padding(.leading, Self.rowStart).padding(.trailing, 7)
            if let note {
                // **On the left edge of the words that it counts** (margins pass, fault 5): it started 33.6 points to
                // their left, under "+".
                ComposerNote(words: note.words, isWarning: note.isWarning, detail: noteDetail)
                    .padding(.leading, showsPlus ? Self.rowStart + 44 : Self.wordsWithoutPlus)
                    .padding(.trailing, 18).padding(.bottom, 12)
            }
        }
        // **The whole capsule takes the tap** (fix round 2, item 53): only the field's 22-point line of words did.
        .background {
            RoundedRectangle(cornerRadius: 25, style: .continuous).fill(Color.clear)
                .contentShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
                .onTapGesture { composerFocused = true }
        }
        .composerGlass()
        .padding(.horizontal, 16).padding(.bottom, 6)
    }

    /// "+" stands at the start of the field's line, before the words.
    private var showsPlus: Bool { store.supportsAttachments && !isCorrecting }
    /// From the capsule's left end to the start of its line, where "+" stands (44 points, so its centre is 25 from the
    /// end), and to the words when no "+" stands there.
    private static let rowStart: CGFloat = 3
    private static let wordsWithoutPlus: CGFloat = 18

    /// The arrow on an agent's colour (`SendButton.arrow(on:)`), which the share extension's Send takes too.
    static func arrow(on fill: Color) -> Color { SendButton.arrow(on: fill) }

    /// The owner corrects the last message: the line says so, and Cancel ends it.
    private var correctionBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil")
            Text("Correcting your last message")
            Spacer(minLength: 8)
            TextAction(title: "Cancel", font: .caption) { store.cancelCorrection() }
        }
        .font(.caption).foregroundStyle(Brand.muted)
        .padding(.horizontal, 18).padding(.top, 12)
    }

    /// At most one line under the composer, and only when it says something that the screen does not: why this chat
    /// takes no message, that the Outbox is blocked, or how near the hub's limit the text is.
    /// The system's own words behind the note, when it is a failure that gave some.
    private var noteDetail: String? {
        if store.chatUnavailableWords(agent) != nil { return nil }
        if store.storageError != nil { return store.storageErrorDetail }
        return store.fileError != nil ? store.fileErrorDetail : nil
    }

    private var note: (words: String, isWarning: Bool)? {
        if let words = store.chatUnavailableWords(agent) { return (words, true) }
        if let words = store.storageError { return (words, true) }
        if let words = store.fileError { return (words, true) }
        if store.filesAreWaiting(for: composerKey) {
            return (store.uploading.isEmpty ? "A file did not go up. Send it again, or take it out." : "Sending a file…",
                    store.uploading.isEmpty)
        }
        let count = trimmed.count
        // The Mac's words over the limit, and one number format in both lines (T-33): it read "16.127 of 16,000
        // characters.", and then "16.000" near the limit and "16,000" over it.
        if count > MobileStore.textLimit {
            return ("Use no more than \(MobileStore.textLimit.formatted()) characters.", true)
        }
        if count > MobileStore.textLimit - 500 {
            return ("\(count.formatted()) of \(MobileStore.textLimit.formatted()) characters", false)
        }
        // No line while the hub does not answer: the line over the page says it once (D-2).
        return nil
    }
}

/// **The agent's words that came while the chat was open fade in, from the time they came**, opacity only, over 0.2 s,
/// easing out, as the Mac's reply does (fix round 2, item 75; D-6, fix round 3d). `content` takes how far they have
/// come, 0 to 1, and the waiting line's last words take the same clock, so the two cross-fade as one. The fade ran
/// from the view's own appearance, three frames after its room came, and those frames showed neither the line nor the
/// reply; SwiftUI's insertion transitions, tried first, ran the two fades at different times. What the chat opened
/// with draws at once, and only the fade's fifth of a second runs on the frame clock.
struct ArrivalFade<Content: View>: View {
    /// When the words came, or nil for words that stand at once.
    let since: Date?
    let content: (Double) -> Content
    /// The fade has ended: the frame clock stops.
    @State private var settled: Bool

    init(since: Date?, @ViewBuilder content: @escaping (Double) -> Content) {
        self.since = since
        self.content = content
        _settled = State(initialValue: since.map { Date().timeIntervalSince($0) > Self.length } ?? true)
    }

    static var length: TimeInterval { 0.2 }

    /// How far the words have come at `now`: 0 when they came, 1 a fifth of a second later, easing out.
    static func shown(since: Date, at now: Date) -> Double {
        let time = min(max(now.timeIntervalSince(since) / length, 0), 1)
        return 1 - (1 - time) * (1 - time)
    }

    var body: some View {
        if let since {
            TimelineView(.animation(minimumInterval: nil, paused: settled)) { context in
                content(settled ? 1 : Self.shown(since: since, at: context.date))
            }
            .task {
                guard !settled else { return }
                try? await Task.sleep(for: .milliseconds(Int(Self.length * 1000) + 50))
                settled = true
            }
        } else {
            content(1)
        }
    }
}

/// **The Mac's waiting line under his last message** (`ChatWaitingLine` there; the owner's yes of 28 October 2026 to
/// D-6): one muted line, no bubble. While the agent works on his message it says "Thinking" with a band of light moving
/// across it, the motion his own projects use for a wait ("remove that circle, I liked the Thinking text animation");
/// while something that is not the agent's work holds it, the two words stand still in orange beside a clock. Under
/// Reduce Motion and at the accessibility text sizes the words stand still. A change of words slides for 150 ms.
///
/// **The agent's own mark stands before "Thinking" and moves as it does at work** (the owner, 13 November 2026, of the
/// Mac's chat: "On the conversation itself, the Thinking label should have the agent icon animating too", and of the
/// phone: "Yes, iPhone too"): with no dot, at rest with Reduce Motion and in the line's last frames under a reply. A
/// wait that is not the agent's work keeps its orange mark and no agent's mark.
struct ChatWaitingLine: View {
    let waiting: ChatWaiting
    /// The agent whose answer the chat waits for, or nil for the words alone.
    var agent: String?
    /// The words without their band of light, as the line's last frames under a reply that takes its place.
    var still = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The mark's side beside the line's words: 18 points at the ordinary text size, and it grows with them by half.
    @ScaledMetric(relativeTo: .subheadline) private var scale: CGFloat = 1
    private var markSide: CGFloat { 18 * min(scale, 1.5) }

    var body: some View {
        HStack(spacing: 6) {
            if waiting.moving, let agent {
                AgentMark(name: agent, state: still ? .online : .working, size: markSide, moves: !still)
            }
            if waiting.moving && !still && !reduceMotion && !typeSize.isAccessibilitySize {
                ShimmeringWords(text: waiting.says, style: .subheadline)
            } else {
                if !waiting.moving {
                    // The state's own mark in the colour of its words: the board's hourglass for a usage limit (fix
                    // round 3), the clock for the other waits.
                    Image(systemName: waiting.symbol).foregroundStyle(Brand.warning)
                }
                Text(waiting.says)
                    .foregroundStyle(waiting.moving ? Brand.muted : Brand.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(waiting.says)
                    .transition(swap)
            }
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: waiting.says)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: waiting.moving)
        // The two words are the line; who waits and until when are what VoiceOver reads, as the Mac's hover gives.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(waiting.detail ?? waiting.says)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("chat-waiting")
    }

    private var swap: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(insertion: .offset(y: 8).combined(with: .opacity),
                           removal: .offset(y: -8).combined(with: .opacity))
    }
}

/// An agent's words, drawn from their Markdown by the Mac's own rules (`MessageBlock`, FleetCore): a heading at
/// `.headline`, list marks, a quote behind a 2-point bar, code as 13-point monospaced text on the bubble's inset fill in
/// a strip that scrolls sideways and never wraps (`CodeStrip`), a table as a grid that scrolls the same way, and bold,
/// italic, inline code and links inside them. The phone drew every mark as typed: `**`, `#`, `>`, the fences and `|---|`. It adds no
/// control: a code block's Copy waits for the owner's word on it.
struct ReplyText: View {
    let text: String

    var body: some View {
        let blocks = Self.drawn(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks.indices, id: \.self) { index in
                block(blocks[index])
            }
        }
    }

    @ViewBuilder private func block(_ block: Drawn) -> some View {
        switch block.kind {
        case .paragraph:
            if let link = Self.onlyLink(block.formatted) {
                // **A link that is a paragraph of its own takes a tap 44 points high** (fix round 2, item 53), the
                // line keeping its height: "Read the full announcement" took one on its 20-point line only.
                Link(destination: link) {
                    Text(block.formatted)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .padding(.vertical, -12)
            } else {
                Text(block.formatted)
            }
        case .heading:
            Text(block.formatted).font(.headline)
        case .item:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // Digits of one width (margins pass, fault 10): "1." was 2.6 points narrower than "2.", so the
                // first item's words started to the left of the others'.
                Text(block.marker).monospacedDigit()
                Text(block.formatted)
            }
            // An item under another starts where that item's words start, as on the Mac.
            .padding(.leading, CGFloat(block.level) * 16)
        case .quote:
            // The bar is the quote's own height, whatever the words wrap to.
            Text(block.formatted).foregroundStyle(Brand.muted)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Capsule().fill(.secondary.opacity(0.6)).frame(width: 2) }
        case .code:
            CodeStrip(text: block.text)
        case .rule:
            Divider()
        case .table:
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 6) {
                    ForEach(block.cells.indices, id: \.self) { row in
                        GridRow {
                            ForEach(block.cells[row].indices, id: \.self) { column in
                                Text(block.cells[row][column]).fontWeight(row == 0 ? .semibold : .regular)
                            }
                        }
                        if row == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                    }
                }
            }
        }
    }

    /// The address of a paragraph that is one link and nothing else, or nil.
    static func onlyLink(_ text: AttributedString) -> URL? {
        guard let first = text.runs.first?.link,
              text.runs.allSatisfy({ $0.link == first || String(text[$0.range].characters).allSatisfy(\.isWhitespace) })
        else { return nil }
        return first
    }

    // MARK: Reading the marks once

    /// One block with its inline marks read, ready to draw.
    private struct Drawn {
        let kind: MessageBlock.Kind
        let text: String
        let marker: String
        /// A list item's depth (`MessageBlock.level`).
        let level: Int
        let formatted: AttributedString
        let cells: [[AttributedString]]
    }

    private final class Parsed: NSObject {
        let blocks: [Drawn]
        init(_ blocks: [Drawn]) { self.blocks = blocks }
    }

    /// A reply is read once and drawn many times: a chat scrolls, and a read redraws it.
    private static let cache: NSCache<NSString, Parsed> = {
        let cache = NSCache<NSString, Parsed>()
        cache.countLimit = 200
        cache.totalCostLimit = 2 * 1024 * 1024
        return cache
    }()

    private static func drawn(_ text: String) -> [Drawn] {
        if let kept = cache.object(forKey: text as NSString) { return kept.blocks }
        let blocks = MessageBlock.parse(text).map { block in
            Drawn(kind: block.kind, text: block.text, marker: block.marker, level: block.level,
                  formatted: block.kind == .code || block.kind == .rule ? AttributedString() : inline(block.text),
                  cells: block.cells.map { $0.map(inline) })
        }
        cache.setObject(Parsed(blocks), forKey: text as NSString, cost: text.utf8.count * 4)
        return blocks
    }

    /// Bold, italic and links as the system draws them, and **inline code as the Mac's chip** (T-10): monospaced, on
    /// the bubble's fill, as the Mac draws it on `FleetStyle.bubble`. It stood on the card's white, the page's own
    /// tone in light, so it read as a square white patch.
    private static func inline(_ text: String) -> AttributedString {
        var result = MessageBlock.inline(text)
        for run in result.runs where run.inlinePresentationIntent?.contains(.code) == true {
            result[run.range].font = .system(.subheadline, design: .monospaced)
            result[run.range].backgroundColor = Brand.bubble
        }
        return result
    }
}

/// **A code block scrolls sideways and never wraps, as the Mac's does, and a line that runs on never reads as cut**
/// (T-10): while words stand past an edge, that edge fades over 16 points, and the system's scroll indicator shows
/// once when the block comes. A line ended at the block's edge inside a word ("…staging.brightde") with no sign that
/// there was more.
private struct CodeStrip: View {
    let text: String
    /// The edges that have words past them now.
    @State private var hidden: Edge.Set = []

    var body: some View {
        ScrollView(.horizontal) {
            Text(verbatim: text).font(.system(.footnote, design: .monospaced))
                .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .scrollIndicatorsFlash(onAppear: true)
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
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

