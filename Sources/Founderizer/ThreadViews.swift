import AppKit
import FleetCore
import FleetMark
import SwiftUI

/// The agent of a conversation, over the messages: its own mark, its name and its role in muted in a small pill
/// (`AgentNameLine`, "Nova · Customer Support"), in the middle of the column and over whatever scrolls under it. It
/// took the place of the mark that sat inside the message box (the owner, 19 October 2026): who the message goes to
/// belongs over the conversation, not in the field he writes in. The name and the role: the owner's answer of 22
/// November 2026, the name with the role in grey in the chat header.
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
            AgentNameLine(agent: agent).font(FormMetrics.title).foregroundStyle(FleetStyle.text)
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
    /// The chat's end is more than three of its room's heights away: "Latest" goes there in one frame (`knowsFarEnd`).
    @State private var farFromEnd = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    /// **His answers to this agent's requests, by request, kept as each card keeps its own** (`sent` of
    /// `NeedRequestCard`) from the frame they go until the reading says the request is answered: a card that folded at
    /// his answer draws no head, so its ask keeps its row for the round trip after the hub's receipt too, and the card
    /// stands at the chat's end, in the place of that answer, from the same frame (`answersOnTheirWay`).
    @State private var answersKept: [Int: PendingRequest] = [:]
    /// The rows whose words can be selected: the row under the pointer and the row whose words he pressed last.
    @State private var selection = ChatSelection()
    /// The replies of a run share one hover: the pointer on any of them shows Copy and the age under the last one.
    @State private var replyHover = ReplyRunHover()
    /// The gap between chat entries. A reply's footer takes its height from it, and every other entry gets the same
    /// height below it, so each gap stays 28 points.
    private static let entrySpacing: CGFloat = 28, footer = AgentReply.footer(compact: false)

    /// **The room under one of his messages, so a reply stands 28–30 points from it** (T-20, fix round): the chat's gap,
    /// and 3 points less over a reply, whose first line carries its own leading over its words (31–32.5 points under his
    /// bubble, 28.5 over his next one). His files have nothing under them (`OwnFileMenu` is on the file itself).
    static func gap(under message: OwnerMessage, before next: ChatEntry?) -> CGFloat {
        var gap = footer
        if case .report = next { gap -= 3 }
        return gap
    }
    /// The entry that stands right under the row at `index`, or nil at the chat's end and over a request's card.
    private static func entry(after index: Int, in rows: [ChatPart]) -> ChatEntry? {
        guard index + 1 < rows.count, case .entry(let next) = rows[index + 1] else { return nil }
        return next
    }
    /// The row under the one at `index` is the row of a thing that he asked for too.
    private static func askFollows(_ index: Int, in rows: [ChatPart]) -> Bool {
        guard index + 1 < rows.count, case .ask = rows[index + 1] else { return false }
        return true
    }
    /// Over the first message: the room the pill over the conversation stands in.
    private static let topInset: CGFloat = 26 + ChatAgentPill.bottom
    /// **The room under the chat's last row, over the composer** (the owner, 15 November 2026, with a picture of the
    /// Claude desktop chat: "increase the space between the last message received and the text input so it breathes
    /// more, like it happens in claude code"): the last words stood 39 points over the composer, and stand 127 over it
    /// now, as that chat's do. It is a row of the chat, over the row that the chat scrolls to, so the chat opens with
    /// it and keeps it when a reply comes (`threadRows`). A task's thread keeps the same room (`TaskView`).
    static let endRoom: CGFloat = 88
    private var entries: [ChatEntry] { store.chatTimeline.entries(for: agent, limit: visibleCount) }
    /// His message to this agent on its way, until the reading holds the hub's copy (fix round 3, item 11).
    private var requestOnItsWay: PendingRequest? { store.messageOnItsWay(to: agent, kept: sent) }
    /// His answers to requests of this agent on their way, his words or an option that he pressed, until the reading
    /// says each request is answered: the card of each stands in the place of that answer (`ChatRequestPlaces.inTime`),
    /// at the chat's end, from the frame he sends it.
    private var answersOnTheirWay: [PendingRequest] {
        mine.filter(\.isOpen).compactMap { store.answerOnItsWay(to: $0, kept: answersKept[$0.id]) }
    }
    /// How many answers to this agent's requests for a key or a login the reading holds that this Mac gave: the chat
    /// follows a new one (`body`). Only those: an option or words go with a request of the store, which the chat
    /// follows when it goes, and must not pull the chat a second time when the reading brings their copy.
    private var formsAnsweredHere: Int {
        let forms = Set(mine.filter(\.asksForSecret).map(\.id))
        guard !forms.isEmpty else { return 0 }
        return (store.state?.messages ?? []).reduce(0) { count, message in
            count + (message.kind == "answer" && message.client == store.installation
                     && message.need_id.map(forms.contains) == true ? 1 : 0)
        }
    }
    /// **The chat as it draws: the hub's entries, and his words on their way at their end** (fix round 3, item 11), a
    /// message, from the frame he sent it, under the request's id, which the hub's copy keeps, so that copy takes its
    /// place where it stands; words of files alone come with the hub's copy, its files with it. An answer to a request
    /// on its way is an entry too, which is not drawn: its card takes its place.
    private var drawn: [ChatEntry] {
        let going = [requestOnItsWay].compactMap { $0 }.filter { !$0.text.isEmpty } + answersOnTheirWay
        guard !going.isEmpty else { return entries }
        return entries + going.sorted { $0.createdAt < $1.createdAt }.map { .message(OwnerMessage(onItsWay: $0)) }
    }
    /// **What this agent asked him and still waits for** (the owner's yes of 28 October 2026, D-7): the request's card
    /// itself, at the column's width, so he answers in the chat where the agent told him about it ("It is in Needs
    /// you."), and Needs you has them all in its lane. A key or a login it asked for comes with its secure form.
    private var requests: [OwnerNeed] {
        store.openNeeds.filter { $0.by == agent }.sorted { ($0.raised, $0.id) < ($1.raised, $1.id) }
    }

    /// **Every request of this agent that waits stands where it was raised** (the owner, 14 November 2026:
    /// "Cards during a thread should appear wherever in the conversation they were requested, not all at the bottom of
    /// the conversation!"; `ChatRequestPlaces.inTime`): right after the agent's message that told him about it ("It is
    /// in Needs you.", D-7 item 1), else at its own time among the messages, so what came after it stands under it.
    /// Every waiting request that no message told him about stood at the end of the chat, under the newest reply.
    /// **An answered one stands folded where he answered it, with his answer on it** (the owner, 19 November 2026:
    /// "maybe we sohuld show a row/card with the reply there?", and "A: the card" to its picture; `Answered.atItsAnswer`),
    /// with the agent's reply under it ("When I reply to a card, the conversation should follow!"): an option that he
    /// pressed or words that he wrote, neither as a bubble of its own. The hub writes every answer as his message to
    /// the agent that asked (`kind` "answer"), and the card takes that message's place.
    /// **No card for a request that a new item replaced** (owner API 1.274, `drawn`): the new item's card stands in the
    /// chat, and the old one with the hub's words went. One whose answer of his is on its way or was refused keeps its
    /// card while the outbox holds it, so that the refusal has its place.
    private var mine: [OwnerNeed] {
        (store.state?.needs ?? []).filter { $0.by == agent }.drawn(holding: store.pending?.needID)
    }

    /// **What he asked this agent for in this chat, each as a row of its own** (the owner, 16 November 2026: "this
    /// tasks should also show inside the conversation!! like in codex or claude code!"; `ChatAskPlaces`): under the
    /// agent's reply of the turn in which the work began, where it stays when the work ends.
    private var asks: [Ask] { store.asks.filter { $0.agent == agent } }
    /// The message of his whose reply holds the row of his ask while that message is worked on: his newest message,
    /// not an answer to a request, and only while the line would move with his answers left out
    /// (`ChatWaiting.asksWaitOn`): in the manager's chat the line moves for an answer too, and a message whose turn
    /// is over holds no row then. A usage limit or a quiet machine waits for nothing that comes soon.
    private func waitsOn(_ entries: [ChatEntry]) -> String? {
        ChatWaiting.asksWaitOn(entries, moving: store.chatWaiting(for: agent, onItsWay: requestOnItsWay != nil,
                                                                  answers: false)?.moving == true)
    }

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
        // Read once for the rows and for the chat's end, which follows a row that comes.
        let asks = self.asks
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
                    let places = ChatRequestPlaces.inTime(needs: needs, in: held, whole: whole, answered: .atItsAnswer)
                    let byID = Dictionary(needs.map { ($0.id, $0) }) { first, _ in first }
                    // **One list of rows, the entries and the cards, each under its own id** (`ChatPart`): a card keeps
                    // its view, with the cursor in its answer, when an entry that comes moves it to another place.
                    // The row of each thing that he asked for in this chat stands under its turn's reply. **A thing that
                    // waits for a card of this chat is that card's head instead** (`ChatAskPlaces.onCards`), until he
                    // answers it: from the frame his answer goes, the card folds and the row stands again.
                    let placedAsks = ChatAskPlaces.rows(
                        places.rows(of: held), asks: asks,
                        open: needs.filter { $0.isOpen && store.answerOnItsWay(to: $0, kept: answersKept[$0.id]) == nil },
                        waitsOn: waitsOn(held))
                    // **The lines of the grants that the agent made are one card for each run of them**
                    // (`ChatGrantPlaces`; the owner, 19 November 2026: "A: the card"), at the place of the run's last
                    // line. It is the last step, so the rows of his asks stand as the lines place them.
                    let granted = ChatGrantPlaces(placedAsks.rows)
                    let rows = granted.rows, onCards = placedAsks.heads
                    let askByID = Dictionary(asks.map { ($0.id, $0) }) { first, _ in first }
                    // A card counts for the marks of a day or an hour as a message does, by the time it was raised, or
                    // by the time of his answer when it stands there.
                    let times = ChatRequestPlaces.times(of: rows, raised: places.cardTimes(of: needs), granted: granted.times)
                    let stamps = rows.indices.map { ChatStamp.time(times[$0], after: $0 > 0 ? times[$0 - 1] : nil) }
                    let stamped = stamps.map { $0 != nil }
                    let runs = ChatPart.replyRuns(in: rows, stamped: stamped)
                    // **A name in the messages is a badge, as on a request's card** (`MessageText.chatNames`), by the
                    // chat's own rules: one book, made again only when what it is made of changes
                    // (`FleetStore.chatNames`).
                    let book = store.chatNames
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if let time = stamps[index] {
                            ChatStamp(time: time)
                        }
                        switch row {
                        case .request(let id):
                            if let need = byID[id] {
                                // **Requests that he answered one after the other stand 8 points apart**, as the
                                // rows under one reply do, and as the picture that he said yes to showed them (19
                                // November 2026): one group of answers, over the agent's reply to them. Not over a
                                // mark of a day or an hour, which begins a part of the chat.
                                let next = index + 1 < rows.count ? rows[index + 1] : nil
                                let together = folds(need) && stamps.indices.contains(index + 1) && stamps[index + 1] == nil
                                    && Self.need(of: next).flatMap { byID[$0] }.map(folds) == true
                                requestCard(need, ask: onCards[id], together: together)
                            }
                        case .grants(let first):
                            if let lines = granted.runs[first] {
                                ChatGrantsCard(lines: lines).padding(.bottom, Self.footer)
                                    .wordsSelectable(in: selection, row: row.id).id(row.id)
                            }
                        case .ask(let id):
                            if let ask = askByID[id] {
                                // Rows under one reply stand 8 points apart, as the cards of a lane of Tasks.
                                ChatAskLine(store: store, row: ChatAskRow(ask, agent: agent, state: store.state))
                                    .padding(.bottom, Self.footer - (Self.askFollows(index, in: rows) ? Self.entrySpacing - 8 : 0))
                                    .id(row.id)
                            }
                        case .entry(.message(let message)):
                            // The room under his message is counted to the row under it: a reply, or a card.
                            messageRow(message, names: book).padding(.bottom, Self.gap(under: message, before: Self.entry(after: index, in: rows)))
                                // **His message comes up from the composer** (`AnyTransition.sentMessage`): only the
                                // one that he sends now, in the frame it goes, never a message of the reading.
                                .transition(!reduceMotion && comesFromComposer(message) ? .sentMessage : .identity)
                        // **A reply that arrives while he looks fades in where it stands** (T-20): 0.2 s, opacity
                        // only. It took the waiting line's place in one frame. Not on the first paint, and not for
                        // the earlier messages he asks for.
                        // Copy and its age only under the last reply of a run (`ChatPart.endsReplies`), on the hover
                        // of any reply of the run.
                        case .entry(.report(let report)):
                            reportRow(report, lastOfRun: ChatPart.endsReplies(at: index, in: rows, stamped: stamped),
                                      run: runs[index].map { replyHover.place(row: row.id, run: $0) }, names: book).id(row.id)
                                .transition(shownUpTo.map { report.id > $0 } == true
                                            ? ReplyArrival.transition(taking: lineShowing && places.atEnd.isEmpty ? lastWaiting : nil,
                                                                      agent: agent)
                                            : .identity)
                        }
                    }
                    // What the owner is waiting for, under his last message and above nothing: one muted line,
                    // in the place the answer will take.
                    if let waiting { ChatWaitingLine(waiting: waiting, agent: agent, moves: store.marksMove).padding(.bottom, Self.footer) }
                    Color.clear.frame(height: Self.endRoom)
                    Color.clear.frame(height: 1).id("latest")
                }.threadRows(top: Self.topInset)
                    // a badge of a message opens its page in this window (`FleetStore.openCardLink`), as on a card
                    .environment(\.openURL, OpenURLAction { store.openCardLink($0) })
                    .environment(\.cardServerSymbols, store.chatServerSymbols)
            }
            .keepsEnd($end, room: Self.endRoom)
            .knowsFarEnd($farFromEnd, room: Self.endRoom)
            // No row gets or loses its selectable words while the chat moves (`ChatWordsSelection`).
            .scrollsAsAChat(selection, store: store)
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
                // **The chat follows his answer to a request** (the owner, 14 November 2026: "When I reply to a card,
                // the conversation should follow!"): the card folds and stands at the chat's end, also when he
                // answered it further up, with words or with an option, and the agent's reply comes under it.
                var answers = false
                for need in mine where need.isOpen {
                    guard let request = store.answerOnItsWay(to: need) else { continue }
                    if answersKept[need.id]?.requestID != request.requestID { answers = true }
                    answersKept[need.id] = request
                }
                if answers {
                    end.followsLatest = true
                    proxy.scrollTo("latest", anchor: .bottom)
                }
            }
            // A match of the search card: the chat draws back to it and shows it in its middle.
            .onChange(of: store.chatFocus, initial: true) { _, focus in reveal(focus, proxy) }
            .onChange(of: requests.map(\.id)) { _, _ in
                if end.followsLatest { proxy.scrollTo("latest", anchor: .bottom) }
            }
            // **The chat follows the answer of a key's or a login's form on this Mac, with the reading that brings
            // it**: the form sends its answer by itself, with no request of the store, and its card then goes to
            // the chat's end, away from where he filled it. Not for an answer from his phone: he does not look here
            // then.
            .onChange(of: formsAnsweredHere) { before, now in
                guard now > before else { return }
                end.followsLatest = true
                proxy.scrollTo("latest", anchor: .bottom)
            }
            // A row of a thing that he asked for comes under the newest reply, as a card does.
            .onChange(of: asks.map(\.id)) { _, _ in
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
            // **"Latest" scrolls to the chat's end over 0.25 s** (`FleetMotion.latest`; the owner's yes of 17 November
            // 2026), as the iPhone's chat does: the view jumped there. An end that is far stays a jump.
            .overlay(alignment: .bottomTrailing) {
                ChatLatestButton(end: $end, far: $farFromEnd) { proxy.scrollTo("latest", anchor: .bottom) }
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
        // His answer to a request is no row of its own: the card of that request stands in its place.
        var row = focus.entry
        if case .message(let message)? = all.first(where: { $0.id == focus.entry }), message.kind == "answer",
           let need = message.need_id {
            row = "need-\(need)"
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            proxy.scrollTo(row, anchor: .center)
            // A chat that opens stands at its end, and the scroll view's first idle phase there sets `followsLatest`
            // to true again within those 50 ms. This scroll starts no phase that would correct it, so the next entry
            // pulled the chat to its end, away from the match, and Latest did not show (a real window, 13 November
            // 2026). So the chat stops following here, after the scroll, until he scrolls or presses Latest. **A match
            // that stands at the chat's end takes nothing from there** (`ChatEnd`; the owner, 14 November 2026): the
            // chat still follows, and Latest does not show over a chat with nothing under it.
            end.followsLatest = false
        }
    }

    /// His message that is on its way now: the row that he sent in this frame (`drawn`).
    private func comesFromComposer(_ message: OwnerMessage) -> Bool {
        requestOnItsWay?.requestID.uuidString.lowercased() == message.request_id
    }

    private func messageRow(_ message: OwnerMessage, names: ChatNames) -> some View {
        SentMessageView(store: store, message: message, names: names).wordsSelectable(in: selection, row: "message-\(message.id)")
            .id("message-\(message.id)")
    }

    /// The request whose card a row is, or nil.
    private static func need(of row: ChatPart?) -> Int? {
        if case .request(let id)? = row { id } else { nil }
    }

    /// The card of a request that is answered, in the reading or with his answer on its way: it folds, until he
    /// opens it again, and keeps its 8 points to the next such card then too.
    private func folds(_ need: OwnerNeed) -> Bool {
        !need.isOpen || store.answerOnItsWay(to: need, kept: answersKept[need.id]) != nil
    }

    /// A request's card in the chat, at the column's width, waiting or folded. `ask`: the thing that he asked for in
    /// this chat and that waits for it, which the card's head names (`ChatAskPlaces.onCards`). `together`: it is folded
    /// and the row under it is a folded card too, so the two stand 8 points apart.
    private func requestCard(_ need: OwnerNeed, ask: Ask?, together: Bool) -> some View {
        NeedRequestCard(store: store, need: need,
                        ask: ask.map { ChatAskRow($0, agent: agent, state: store.state) })
            // the card stands on the chat's page: an answer held here keeps its wait on every page, and the badge's
            // Undo brings him back to this chat (`AnswerHolds.Place`)
            .environment(\.cardOnPage, true)
            .padding(.bottom, Self.footer - (together ? Self.entrySpacing - 8 : 0))
            .wordsSelectable(in: selection, row: "need-\(need.id)").id("need-\(need.id)")
    }

    /// A reply, with its delivery icons when it went to a channel. **A message that the agent wrote first
    /// (`message_owner`) looks like any other** (D-2, the owner's yes of 28 October 2026): its "Sent first" line said
    /// what the conversation already shows, a message under no question of his.
    private func reportRow(_ report: ManagerReport, lastOfRun: Bool, run: ReplyRunHover.Place?, names: ChatNames) -> some View {
        AgentReply(text: report.text, time: report.created, detail: reportDetail(report), lastOfRun: lastOfRun, run: run,
                   names: names)
            .wordsSelectable(in: selection, row: "report-\(report.id)")
    }

    /// Under a reply: the files that the agent sent with it (CHAT-APPS.md 20; the owner's "Yes, build it" of 15
    /// November 2026), drawn as his own files are drawn under his messages, and its delivery icons when it went to a
    /// channel.
    private func reportDetail(_ report: ManagerReport) -> AnyView? {
        let files = report.attachments ?? []
        guard !files.isEmpty || report.delivery != nil else { return nil }
        return AnyView(VStack(alignment: .leading, spacing: 8) {
            // 12 points under the reply's words (its own gap is 4): the files breathe (the owner, 20 November 2026)
            if !files.isEmpty {
                MessageFilesView(store: store, files: files, alignment: .leading, keeps: false).padding(.top, report.text.isEmpty ? 0 : 8)
            }
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
    /// `answers`: false leaves his answers to requests out (`FleetAgent.chatWaiting`), as the rows of his asks wait.
    func chatWaiting(for agent: String, onItsWay: Bool, answers: Bool = true) -> ChatWaiting? {
        guard let state, let entry = state.agents.first(where: { $0.name == agent }) else { return nil }
        return entry.chatWaiting(in: state, sending: sending && onItsWay, fresh: isFresh,
                                 until: { fleetComingTime($0, now: state.time) }, answers: answers)
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
    /// The names that his words draw as badges (`MessageText.chatNames`).
    let names: ChatNames
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
            // **The badge of the task or the job that it is about stands over his words** (`AboutBadgeView`), and over
            // the files of a message of files alone.
            let about = message.about?.place != nil
            // **The badge of each skill that he gave with it stands at the start of his words** (`SkillBadge`,
            // `OwnerBubble.gifts`; owner feature `message_skills`), and alone in his bubble with no words, as the picture
            // of his yes drew it.
            let gifts = message.skills?.given ?? []
            // A message may carry files and no words: then the files are the message, and no empty bubble shows.
            // **The footer stands beside the bubble, on its last line** (T-20), and takes no height: under the
            // bubble it kept 26 points under every message he sent, so a reply stood 57 points from his question
            // and 29 from his next one. A message of files alone has no bubble, and keeps it under its files.
            if !message.text.isEmpty || !gifts.isEmpty {
                OwnerBubble(text: message.text, origin: message.origin, beside: AnyView(footer), names: names,
                            over: about ? AnyView(AboutBadgeView(store: store, message: message)) : nil, gifts: gifts,
                            mentions: message.mentions?.tags)
            } else if about {
                AboutBadgeView(store: store, message: message, alone: true)
            }
            if let files = message.attachments, !files.isEmpty {
                // 12 points under his bubble (the stack's spacing is 6), as under a reply
                MessageFilesView(store: store, files: files).padding(.top, message.text.isEmpty && gifts.isEmpty ? 0 : 6)
            }
            if message.text.isEmpty && gifts.isEmpty { footer }
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

/// **A task's thread**, the left column of its card over the window (`TaskDetail`): what the agent said, from the request
/// that the task began with to its result, in the column of prose, with its live line while its session works.
struct TaskView<After: View>: View {
    @Bindable var store: FleetStore
    let task: FleetTask
    let state: HubState
    let hub: URL
    let isFresh: Bool
    /// The room over its first row, into which its rows fade as they leave at the top: under the card's edge, or under
    /// the back link to a job (`TaskDetail`).
    let top: CGFloat
    /// **What stands at the thread's end, after its result**: the owner's feedback on the task with its answers
    /// (`FeedbackRows`), which its card gives, with the thread's selection, so their words are selected as the thread's
    /// are; and how many rows it has, so that a new one is followed to the end as a new row of the thread is.
    let after: (ChatSelection) -> After
    let afterCount: Int
    @State private var end = ChatEnd()
    /// The thread's end is more than three of its room's heights away: "Latest" goes there in one frame.
    @State private var farFromEnd = false
    @State private var latestActivity = 0
    /// Why the thread's last read failed, in the hub's words.
    @State private var readError: String?
    /// When the first of the reads that failed in a row failed: one break of them says nothing
    /// (`FleetStore.pageReadingIsOld`; 17 November 2026).
    @State private var readFailedSince: ContinuousClock.Instant?
    /// The rows whose words can be selected: the row under the pointer and the row whose words he pressed last.
    @State private var selection = ChatSelection()
    private var notes: [ProgressNote] { state.notes.filter { $0.task == task.id } }
    private var permissions: [FleetPermission] { state.permissions.filter { $0.task == task.id } }
    private var threadEvents: Bool { state.ui_features?.contains("thread_events") == true }
    /// **The room under the thread's last row**: the chat's (`ManagerView.endRoom`) as the thread's last block, which the
    /// thread scrolls to, and the gap between two blocks over it, so the last words stand as far over the guidance box
    /// as a chat's last words over its composer (the owner's yes of 17 November 2026 to the pictures of the Task page).
    /// They stood right on it. The scroll's measure of its end leaves it out (`keepsEnd(room:)`).
    private static var endRoom: CGFloat { ManagerView.endRoom + ChatStyle.blockSpacing }

    /// **The thread's live line while its session works** (the owner's yes of 17 November 2026 to the pictures of the
    /// Task page): the chat's "Thinking" line (`ChatWaitingLine`), the agent's glyph moving before what it does now:
    /// the hub's words for the call of its turn (`doing`), else the agent's own words for its newest step that has not
    /// ended, such as a capture in the background (`StepWords.running`), else "Working". Only by a current reading and
    /// only while the task is work now (`FleetTask.mark`), because motion says that the work goes on.
    private var liveLine: ChatWaiting? {
        guard isFresh, task.mark(in: state).inWork else { return nil }
        let words = task.doing ?? activity.flatMap { StepWords.running(in: $0.timeline, attempt: task.attempt) }
        return ChatWaiting(says: words ?? String(l10n: "Working"), moving: true)
    }
    /// What the thread read last on this hub generation (`TaskActivity`).
    private var activity: TaskActivity? { store.reading(TaskActivity.name(task.id)) }
    /// The thread of this task, which is still open, stops at an error of its current attempt that is no usage limit
    /// (`ActivityTimeline.stands`): its row says from the reading of the agent's server whether its provider is signed
    /// out there now (`RuntimeErrorLine`). An error that is a record reads no server.
    private var errorStands: Bool {
        guard !task.isTerminal, let timeline = activity?.timeline,
              let last = timeline.rows.last(where: { $0.event.parent == nil && $0.event.attempt == task.attempt })
        else { return false }
        return last.event.code != RuntimeErrorLine.limit && timeline.stands(last, attempt: task.attempt)
    }
    /// **The reading of the agent's server, for the error's row, only while an error stands and the fleet's reading is
    /// current.** The store reads the servers again every 15 seconds (`PagePrefetch.live`), and a thread that stops at
    /// no error does not draw again for it. With no answer from the hub the row says nothing about now: the hub's clock
    /// stops then, and a reading of any age would count as current.
    private var server: MachineStatus? {
        guard errorStands, isFresh else { return nil }
        return (store.reading("machines") as MachineList?)?.machines.first { $0.agent == task.owner }
    }
    /// The usage limit that holds this task now, for the thread's limit line (`HubState.limitHolding`).
    private var limitHolding: RuntimeLimit? { state.limitHolding(task) }

    /// **The thread comes in one frame, at its newest row** (T-06). A task opened again draws what it read last, at
    /// once. The first time, the column stays empty until the thread's reads have answered — every page of them — and
    /// then the whole thread shows, already at its end, with what its panel takes from the same reading (`TaskPanel`:
    /// the model, the child agents and the changed files). It arrived in three steps, and the request at its top jumped
    /// away as the rows under it came; on a hub slower than a second the request and "Started" came alone first, and
    /// the rest 664 points away from them (fix round 2).
    static func shows(_ task: FleetTask, store: FleetStore) -> Bool {
        store.reading(TaskActivity.name(task.id)) as TaskActivity? != nil || !store.isFresh
            || store.state?.ui_features?.contains("thread_events") != true
    }

    /// The guidance box that a dropped file goes to: the one under this thread, while it shows (`TaskSteering`) and
    /// takes files; else nil, and the thread takes no file.
    private var droppedFiles: String? {
        guard !task.isTerminal, state.ui_features?.contains("task_steering") == true,
              TaskSteering.shows(task, in: state) else { return nil }
        return store.guidanceComposer(for: task)
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
                LoadingLine(String(l10n: "Reading the task…")).padding(.horizontal, -FormMetrics.rowInset).threadRows(top: top)
            }
        }
        // A file dropped anywhere on the thread waits in its guidance box, as on a chat, while that box shows and takes
        // files (owner API 1.223; the owner's "Yes, build it" of 19 November 2026).
        .stageDroppedFiles(store: store, composer: droppedFiles, mark: true)
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
        // Each run of the reads counts its own break (`readFailedSince`).
        readError = nil; readFailedSince = nil
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
                if readError != nil { readError = nil; readFailedSince = nil }
                if first != nil, page.more { first = activity; continue }
                if first != nil {
                    await store.settle(since: start)
                    guard !Task.isCancelled, store.hub == hub, store.state?.db == database else { return }
                }
                // A new page of a thread that he scrolls waits until it rests, as the fleet's reading does
                // (`FleetStore.readingsRest`); the first one shows the thread, and waits for nothing.
                if first == nil, !page.events.isEmpty {
                    await store.readingsRest()
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
                if readFailedSince == nil { readFailedSince = .now }
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
                        let mark = task.mark(in: state)
                        Label(mark.words, systemImage: mark.symbol).font(ChatStyle.detail).foregroundStyle(.orange)
                            .help(state.limitHover(limit, owner: task.owner) ?? "")
                    }
                    // **The day and the time it began, over the request it began with** (`ChatStamp`), as a chat
                    // stamps its first message; the request in the words of whoever asked (`TaskRequest`).
                    VStack(alignment: .leading, spacing: 0) {
                        ChatStamp(time: task.created)
                        TaskRequest(task: task).wordsSelectable(in: selection, row: "request")
                    }
                    if threadEvents {
                        // Its "Activity is unavailable" only once its reads have failed one whole break, and also while
                        // the window's notice says the outage (fix round 3, item 33): that notice is under the card's dim.
                        RuntimeActivity(activity: activity ?? TaskActivity(), error: !store.pageReadingIsOld(failedSince: readFailedSince) ? nil : readError, task: task.id, attempt: task.attempt, stoppedAttempt: state.stoppedAttempt(of: task.id), terminal: task.isTerminal, isFresh: isFresh, followsLatest: $end.followsLatest,
                                        steers: state.steers?.filter { $0.task == task.id } ?? [],
                                        notes: notes, permissions: permissions,
                                        childRequest: $store.childThreadRequest, selection: selection, startedAt: task.created,
                                        machine: server, time: state.time, agent: state.agents.first { $0.name == task.owner },
                                        limit: limitHolding,
                                        // The link opens a page and writes nothing, so no write on its way takes it
                                        // away; it needs only a hub that has the sign-in.
                                        signIn: state.ui_features?.contains(MachineLogin.feature) == true
                                            ? { store.destination = .signIn(task.owner, $0) } : nil, store: store)
                            .id("\(hub.absoluteString)/\(state.db)/\(task.id)")
                    }
                    // A hub without `thread_events` has no thread to put them in, so there they stay rows of their own.
                    if !threadEvents {
                        ForEach(notes) { note in
                            AgentReply(text: note.text, time: note.ts, compact: true).wordsSelectable(in: selection, row: "note-\(note.id)")
                        }
                        ForEach(permissions.filter(\.needsReading)) { permission in
                            FoldRow(title: permission.tool, symbol: "hand.raised",
                                    status: permission.decision ?? TaskWords.waitingFor(task.requester), statusColor: .orange, chat: true) {
                                VStack(alignment: .leading, spacing: 9) {
                                    Text(permission.input).font(ChatStyle.code).selectableWords()
                                    if let reason = permission.reason { Text(reason).selectableWords() }
                                }
                            }.wordsSelectable(in: selection, row: "permission-\(permission.id)")
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
                    // It moves only by an answer of this wake (`marksMove`), as the chat's own.
                    if let live = liveLine { ChatWaitingLine(waiting: live, agent: task.owner, moves: store.marksMove) }
                    if task.delivered != nil {
                        Rule()
                        TaskResult(task: task, state: state).wordsSelectable(in: selection, row: "result")
                        if task.accepted == 1 {
                            let context = ArtifactContext(hub: hub, database: state.db, taskID: task.id)
                            ArtifactSection(context: context, isFresh: isFresh).id(context)
                        }
                    }
                    after(selection)
                    // **No name under the record**: the agent that did it heads the panel beside it (`TaskPanel`). Its
                    // muted name stood here, the one place the thread named it.
                    Color.clear.frame(height: ManagerView.endRoom).id("latest-task")
                }.threadRows(top: top)
            }
            .keepsEnd($end, room: Self.endRoom)
            .knowsFarEnd($farFromEnd, room: Self.endRoom)
            // No row gets or loses its selectable words while the thread moves (`ChatWordsSelection`).
            .scrollsAsAChat(selection, store: store)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // Its rows fade as they leave at the top, over the room the thread leaves above its first row (T-20): its first
            // row stands level with the head of the facts beside it (the margins of 30 October 2026, row 28, and its
            // review: it stood 12 pt under the panel's head beside it).
            .topFade(top)
            .onChange(of: latestActivity) { _, _ in
                if end.followsLatest { proxy.scrollTo("latest-task", anchor: .bottom) }
            }
            .onChange(of: task.state) { _, _ in
                if end.followsLatest { proxy.scrollTo("latest-task", anchor: .bottom) }
            }
            .onChange(of: afterCount) { _, _ in
                if end.followsLatest { proxy.scrollTo("latest-task", anchor: .bottom) }
            }
            .onChange(of: state.steers?.last(where: { $0.task == task.id })?.id) { _, _ in
                if end.followsLatest { proxy.scrollTo("latest-task", anchor: .bottom) }
            }
            // The live line comes, goes and says new words at the thread's end, so the view follows it as a new row.
            .onChange(of: liveLine?.says) { _, _ in
                if end.followsLatest { proxy.scrollTo("latest-task", anchor: .bottom) }
            }
            // Over 0.25 s, as a chat's (`FleetMotion.latest`); an end that is far stays a jump.
            .overlay(alignment: .bottomTrailing) {
                ChatLatestButton(end: $end, far: $farFromEnd) { proxy.scrollTo("latest-task", anchor: .bottom) }
                    .accessibilityIdentifier("task-latest")
            }
        }
    }
}

extension HubState {
    /// **The usage limit that holds `task` now, for its thread's limit line** (`HubState.limit(of:)`): while the task is
    /// open and neither an outcome that is not known nor a hold of the owner's comes first, the order of the task's mark
    /// (`FleetTask.mark`).
    func limitHolding(_ task: FleetTask) -> RuntimeLimit? {
        guard !task.isTerminal, !outcomeUnknown(task.id),
              holds?.contains(where: { $0.task == task.id && $0.state != "released" }) != true
        else { return nil }
        return limit(of: task)
    }

    /// **The hover of a held task's "Usage limit" in its thread** (owner API 1.330; the owner, 24 November 2026: the
    /// fleet had wrong data about an agent). Where the agent's own route is held, or on a hub without `task_limit`, the
    /// agent is at its limit, and the hover says so. Where only the task's own hold keeps it (a hold of the agent's screen
    /// route, while the agent itself works on), it says the usage bar's words, "Usage limit until 16:00", and nothing when
    /// the time of the reset is not known: the line says "Usage limit" already.
    func limitHover(_ limit: RuntimeLimit, owner: String) -> String? {
        let until = limit.reset_known ? fleetComingTime(limit.until, now: time) : nil
        guard !TaskLimit.served(ui_features) || agents.first(where: { $0.name == owner })?.limit != nil else {
            return until.map { String(l10n: "Usage limit until \($0)") }
        }
        let who = owner.agentLabel
        return until.map { String(l10n: "\(who) is at its usage limit until \($0).") } ?? String(l10n: "\(who) is at its usage limit.")
    }
}

/// **The request a task began with, in the words of whoever asked** (the owner's yes of 17 November 2026 to the pictures
/// of the Task page): his own request in his bubble at the right, as in his chats, also what he asked an agent for in
/// that agent's chat, where the hub makes the manager or a lead its requester (`FleetTask.ownersWords`); an agent's at
/// the left in the bubble's outline, under that agent's glyph and name, as the other side of a chat that he only reads
/// stands (`ReadBubble`). Every request stood in his bubble, which in a chat is always his own words, the Fleet
/// Manager's brief to an agent too.
struct TaskRequest: View {
    let task: FleetTask

    var body: some View {
        if task.requester == "owner" {
            OwnerBubble(text: task.details)
        } else if let words = task.ownersWords {
            OwnerBubble(text: words)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                AgentNamed(agent: task.requester) { Text(task.requester.agentLabel).lineLimit(1) }
                    .font(ChatStyle.detail).foregroundStyle(FleetStyle.muted)
                    .accessibilityAddTraits(.isHeader)
                OwnerBubble(text: task.details, theirs: true)
            }
        }
    }
}

/// **A task's result, once, at its thread's end** (the owner's yes of 17 November 2026 to the pictures of the Task
/// page): the check's mark in the board's colours with its words ("Accepted by Fleet Manager") and how long ago, then the
/// result's words folded to three lines; Show more opens them whole, with where the output is, how it was checked and
/// the requester's note. The words under the hairline said the agent's last message again, often in twelve lines, and
/// the check stood under them as one more grey fold row. At rest they are its plain line for him when it has one
/// (`FleetTask.resultAtRest`), and Show more opens the whole result in their place.
struct TaskResult: View {
    let task: FleetTask
    let state: HubState
    @State private var expanded = false
    /// Copy of the result's whole words stands at the end of its head line under the pointer, as a reply's Copy does.
    @State private var hovered = false
    @State private var copied = false
    /// The result at rest: the height of its first three lines, the last of them fading out.
    private static let foldedHeight = ChatStyle.line * 3 + ChatStyle.lineSpacing * 2

    /// The mark of the check: the board's green check for a result that its requester accepted, its red mark for one
    /// that failed or was not accepted (`failedResult`), and a muted circle while it waits for its check.
    private var mark: (symbol: String, color: Color) {
        if task.accepted == 1 { return ("checkmark.circle.fill", FleetTask.MarkTint.checked.color) }
        if task.failedResult != nil { return ("exclamationmark.circle.fill", FleetTask.MarkTint.failed.color) }
        return ("circle", FleetStyle.muted)
    }
    /// "Accepted by Fleet Manager", "Waiting for your check", or the word of a result that failed with no check.
    private var words: String { task.accepted == nil ? task.failedResult ?? task.checkStatus : task.checkStatus }
    private var what: String { task.what ?? String(l10n: "No result reported") }
    /// Its plain line stands at rest in place of the whole result. It does not change with `expanded`, so Show less
    /// stays when the whole result is short and has no other facts.
    private var plainAtRest: Bool { task.resultAtRest.map { $0 != what } ?? false }
    /// The words that it shows: at rest its plain line when it has one, opened the whole result.
    private var shown: String { expanded || !plainAtRest ? what : task.resultAtRest ?? what }
    /// The whole result is past three lines, which fold. A plain line never folds: it is one line of at most 280
    /// characters, and its end, the way a ticket ended, would show nowhere else.
    private var long: Bool { what.count > 240 || what.filter { $0 == "\n" }.count > 2 }
    /// Something waits behind Show more: words past three lines, the whole result behind a plain line, or the result's
    /// other facts.
    private var more: Bool {
        long || plainAtRest || task.where_ != nil || task.how != nil || task.check_note != nil
    }

    var body: some View {
        let folded = long && !expanded && !plainAtRest
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                // The check's mark, its words and its age are one item for VoiceOver; Copy is its own.
                HStack(spacing: 8) {
                    Image(systemName: mark.symbol).font(IconMetrics.symbol(14)).foregroundStyle(mark.color).accessibilityHidden(true)
                    Text(words).font(ChatStyle.font).foregroundStyle(FleetStyle.text)
                    if let time = task.checked_at ?? task.delivered {
                        Text(messageAge(time)).font(ChatStyle.detail).foregroundStyle(FleetStyle.muted).help(fleetDate(time))
                    }
                }
                .accessibilityElement(children: .combine)
                // Hidden by its opacity, never taken away, so the line keeps its size under the pointer (UI-PATTERNS:
                // no control of a row comes or goes with the pointer).
                MessageAction(symbol: copied ? "checkmark" : "square.on.square", label: String(l10n: "Copy message")) {
                    copyMessage(what); copied = true
                }
                .foregroundStyle(FleetStyle.muted)
                .opacity(hovered ? 1 : 0).allowsHitTesting(hovered).accessibilityHidden(!hovered)
            }
            VStack(alignment: .leading, spacing: 9) {
                MessageText(text: shown, chat: true, fold: folded ? Self.foldedHeight : nil).equatable()
                    .frame(maxHeight: folded ? Self.foldedHeight : nil, alignment: .top)
                    .mask {
                        VStack(spacing: 0) {
                            Color.black
                            if folded {
                                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: ChatStyle.line)
                            }
                        }
                    }
                if expanded {
                    VStack(alignment: .leading, spacing: 10) {
                        DetailField(title: String(l10n: "Output"), value: task.where_ ?? String(l10n: "Not reported"))
                        DetailField(title: String(l10n: "How it was checked"), value: task.how ?? String(l10n: "Not reported"))
                        if let check = task.check_note { MessageText(text: check) }
                    }
                }
                if more {
                    // The click reaches over and under the words (`IconMetrics.reach`), as a long message's Show more.
                    Button { expanded.toggle() } label: {
                        Text(expanded ? "Show less" : "Show more").padding(.vertical, IconMetrics.reach).contentShape(Rectangle())
                    }
                    .font(ChatStyle.detail).foregroundStyle(FleetStyle.muted).buttonStyle(.plain)
                    // the hand over all that a click reaches, as a long message's Show more
                    .pointerStyle(.link)
                    .padding(.vertical, -IconMetrics.reach)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovered = $0; if !$0 { copied = false } }
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

/// **"Latest" over a chat or a task thread, a view of its own** (the owner, 25 November 2026: "scrolling Fleet Manager
/// chat is SO slow"): it is the only view that reads where the scroll stands, so a scroll that leaves the end or comes
/// back to it draws this button again and not the whole chat, which took 30 to 42 ms of a frame each time (the
/// manager's chat on his fleet's reading, measured in a hidden copy of the app).
private struct ChatLatestButton: View {
    @Binding var end: ChatEnd
    /// Read only when he presses: the end is far, so the chat goes there in one frame.
    @Binding var far: Bool
    let go: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if end.showsLatest {
            Button("Latest", systemImage: "arrow.down") {
                withAnimation(reduceMotion || far ? nil : FleetMotion.latest) { go() }
                end.followsLatest = true
            }
                .buttonStyle(.plain).font(ChatStyle.detail).foregroundStyle(FleetStyle.muted)
                .padding(9).background(FleetStyle.surface, in: Capsule()).padding(12)
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

    /// **Whether the end of a chat or a task thread is far**: more than three heights of its room stand under the view.
    /// "Latest" then goes to the end in one frame, and scrolls there otherwise (`FleetMotion.latest`). As `keepsEnd`,
    /// it tells its answer only when that changes, not at each point of a scroll.
    func knowsFarEnd(_ far: Binding<Bool>, room: CGFloat = 0) -> some View {
        onScrollGeometryChange(for: Bool.self) {
            $0.contentSize.height - room - $0.visibleRect.maxY > 3 * $0.containerSize.height
        } action: { _, now in
            if far.wrappedValue != now { far.wrappedValue = now }
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
