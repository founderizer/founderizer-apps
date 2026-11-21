import FleetCore
import FleetMark
import SwiftUI
import UIKit

/// Needs you: the open items in full, newest first, each with the agent that raised it, the question, the reason and
/// what it wants. Each item has its own answer and its own draft, which stays on this phone until the hub takes it
/// (MOBILE-APP.md 10).
///
/// **One item is one card, the same card as in the chat of the agent that raised it** (`NeedCard`; fix round 2, items
/// 76, 95 and 96): who asks and when over it, the question, its two fields, the agent's own options and the answer in
/// it, and what that answer is waiting for under it. It was a section of the system's grouped list, whose corners
/// (26) and widths differed from the chat's card, and whose removal drew the next item over the answered one.
///
/// **Under the open items stand the tasks that only he can move** (fix round 1, the lead's call on D-4): the tab's
/// count included them, and its page did not show them.
struct NeedsPage: View {
    let store: MobileStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The items on the page: the open ones, and an answered one while it folds away. nil before the page first shows,
    /// so its first frame draws the store's own list.
    @State private var shown: [OwnerNeed]?
    /// The answered items that fold away now.
    @State private var folding: Set<Int> = []
    /// **His answer to each item on the page, from the frame the hub's request for it began, and when** (the owner's
    /// yes of 11 November 2026 to its moving picture: "Yes, build it"): the item shows it, an option that he pressed
    /// with a check that draws itself, takes no more touch, and folds 0.78 s after it at the earliest, so that he sees
    /// his answer taken. **Words that he wrote have no check** (the owner, 14 November 2026: "when I typed a custom
    /// answer instead of choosign one of the suggested ones, do not show the CHECK animation because it is
    /// misleading"): they stay in the field and Send goes. The store forgets the answer at the reading that folds the
    /// item; the page keeps it until the fold ends.
    @State private var given: [Int: MobileStore.GivenAnswer] = [:]
    @State private var givenAt: [Int: ContinuousClock.Instant] = [:]
    /// An answer of his folded the items that went last: the mark of "Nothing needs you" then draws itself.
    @State private var folded = false
    /// One more for each answer that he gives while the page shows: its soft tap.
    @State private var taps = 0
    /// The column of a task's mark, as on a task's row: it grows with the mark.
    @ScaledMetric(relativeTo: .title3) private var markWidth: CGFloat = 22
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if store.readsTheHub {
                    LoadingLine(String(l10n: "Reading the hub…"))
                        .padding(.horizontal, 16).padding(.vertical, 12)
                }
                ForEach(Self.drawn(shown ?? store.openNeeds, open: store.openNeeds)) { need in
                    let folds = folding.contains(need.id)
                    // **An answered item folds away** (items 76 and 95): its height goes to nothing over 250 ms, easing
                    // out, its content clipped to what is left of it and fading, and the items under it rise into the
                    // room it frees, never over it.
                    Fold(shown: folds ? 0 : 1) {
                        NeedCard(store: store, need: need, header: true, given: given[need.id])
                            .padding(.bottom, NeedCard.gap)
                    }
                    .clipped()
                    .opacity(folds ? 0 : 1)
                    .allowsHitTesting(!folds && given[need.id] == nil)
                    .accessibilityHidden(folds)
                    .accessibilityIdentifier("need-\(need.id)")
                }
                if !store.ownerTasks.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(store.ownerTasks.enumerated()), id: \.element.id) { index, task in
                            // From the words to 16 points before the card's edge, as a list's row line (margins
                            // pass, fault 24): it started under the mark and ran to the edge. At the accessibility
                            // sizes the words start under the mark, at the row's edge.
                            if index > 0 {
                                RowLine().padding(.leading, typeSize.isAccessibilitySize ? 16 : 16 + markWidth + 12)
                                    .padding(.trailing, 16)
                            }
                            ownerTask(task)
                        }
                    }
                    .background(Brand.surface, in: NeedCard.shape(onPage: true))
                    .overlay(NeedCard.shape(onPage: true).strokeBorder(Brand.cardEdge, lineWidth: 1))
                    .padding(.top, NeedCard.head)
                }
            }
            // The page's whole width (fix round 3, item 24): empty, the column was 32 points and "Nothing needs you"
            // broke inside its words.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear { if shown == nil { shown = store.openNeeds } }
        // **The copies that the page keeps follow each reading** (review B, round 2): a card that closes is drawn from
        // the last reading that had it open, with its talk, and not from the copy of the last time a card came or
        // went, whose talk went in the frame the hub closed the card, under his answer's check.
        .onChange(of: store.snapshot?.time) { _, _ in
            if let kept = shown { shown = Self.drawn(kept, open: store.openNeeds) }
        }
        .onChange(of: store.openNeeds.map(\.id)) { _, ids in fold(to: ids) }
        .onChange(of: goingAnswers, initial: true) { before, going in
            for (id, answer) in going where given[id] == nil {
                given[id] = answer
                givenAt[id] = .now
                // Not for an answer that was on its way when the page opened: the first pass has no change.
                if before != going { taps += 1 }
            }
            // The hub refused it, and the item waits again: it is his to answer once more.
            for id in given.keys where going[id] == nil && store.openNeeds.contains(where: { $0.id == id }) {
                given[id] = nil
                givenAt[id] = nil
            }
        }
        // One soft tap as his answer is taken.
        .sensoryFeedback(.success, trigger: taps)
        .background(Brand.canvas)
        .overlay {
            // One title and no second line (D-2); a hub that does not answer says so once, over the page. It comes
            // when the last item has folded, not over it.
            if (shown ?? store.openNeeds).isEmpty && store.ownerTasks.isEmpty && store.snapshot != nil
                && store.showsCurrent {
                NothingNeedsYou(draws: folded && !reduceMotion)
            }
        }
        .refreshable { await store.refresh() }
        .tabRootPage()
        .hubBanner(store)
    }

    /// **What the page draws for each item that it keeps: the reading's own copy while the item is open**, and the copy
    /// that it kept of one that folds away. The page kept its copies until an item came or went, so a card that changed
    /// while it stayed open stood as it was until then: his message under it and the agent's reply (Needs
    /// clarification; review B of 20 November 2026), and its options or its words.
    nonisolated static func drawn(_ kept: [OwnerNeed], open: [OwnerNeed]) -> [OwnerNeed] {
        let current = Dictionary(open.map { ($0.id, $0) }) { first, _ in first }
        return kept.map { current[$0.id] ?? $0 }
    }

    /// The page follows the hub's list: a new item comes in at once, in its place, and an item that left folds away
    /// where it stood and then goes. Under Reduce Motion it fades where it stands, and then goes.
    private func fold(to ids: [Int]) {
        let open = store.openNeeds
        let gone = (shown ?? []).filter { !ids.contains($0.id) }
        // The ones that fold keep their place among the open ones, in the hub's order (the newest first).
        shown = (open + gone.filter { need in !open.contains { $0.id == need.id } })
            .sorted { ($0.raised, $0.id) > ($1.raised, $1.id) }
        guard !gone.isEmpty else { folded = false; return }
        let goneIDs = Set(gone.map(\.id))
        // An item that he answered a moment ago stays until its answer has stood for 0.78 s.
        let stood = goneIDs.compactMap { givenAt[$0] }.map { ContinuousClock.now - $0 }.min()
        let hold = reduceMotion ? nil : stood.map { Duration.milliseconds(780) - $0 }
        folded = goneIDs.contains { given[$0] != nil }
        Task { @MainActor in
            if let hold, hold > .zero { try? await Task.sleep(for: hold) }
            withAnimation(.easeOut(duration: reduceMotion ? 0.2 : 0.25)) { folding.formUnion(goneIDs) }
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 210 : 260))
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) {
                // One that came back while it folded stays, open again.
                let open = Set(store.openNeeds.map(\.id))
                shown = shown?.filter { !goneIDs.contains($0.id) || open.contains($0.id) }
                folding.subtract(goneIDs)
                for id in goneIDs where !open.contains(id) {
                    given[id] = nil
                    givenAt[id] = nil
                }
            }
        }
    }

    /// His answers that the store has on their way or taken, for the items on the page.
    private var goingAnswers: [Int: MobileStore.GivenAnswer] {
        Dictionary((shown ?? store.openNeeds).compactMap { need in store.givenAnswer(to: need.id).map { (need.id, $0) } }) { first, _ in first }
    }

    /// A task that only he can move, as the Mac's Needs you page draws it: its orange mark, its title, and its agent,
    /// its number and what waits. It opens the task in Tasks, where its back leads.
    private func ownerTask(_ task: MobileStore.OwnerTask) -> some View {
        Button {
            store.taskRoute = [task.id]
            store.tab = .tasks
        } label: {
            // **The mark in its 22-point column, as on a task's row** (margins pass, fault 11): the words started
            // after the mark's own width, at x 67.3, where the same task's words on Tasks start at 66. **At the
            // accessibility sizes the mark stands over the words, as on a task's row** (T-38; review B): the column
            // kept the words about 70 points right of the rows above and below them.
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            layout {
                Image(systemName: task.symbol).font(.title3).foregroundStyle(Brand.warning)
                    .frame(width: typeSize.isAccessibilitySize ? nil : markWidth)
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title).fixedSize(horizontal: false, vertical: true)
                    // **The agent's mark with its dot before its name** (fix round 2, item 69; D-8 item 4), at the size
                    // of the marks of the requests' heads on this page, at rest: the row named Atlas in words alone.
                    // 8 points after the 20-point mark, as a request's head and the chat's pill (margins pass,
                    // fault 23).
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let owner = task.owner {
                            // Centred on the line's first row of words, also when the words wrap.
                            AgentAvatar(name: owner, state: store.state(of: owner), base: 20, moves: false,
                                        ring: Brand.surface)
                                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                        }
                        MetaLine(parts: [task.owner.map(agentName) ?? "", task.words])
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("needs-task-\(task.id)")
    }
}

extension MobileStore {
    /// The state of an agent, as its row on Chats shows it.
    func state(of name: String) -> AgentState {
        guard let agent = agent(name), let snapshot else { return .unknown }
        return agent.mobileState(in: snapshot, isFresh: showsCurrent)
    }
}

/// **A height that folds to nothing**, for an answered item: it lays its content out whole and reports only `shown`
/// of its height, so the content below rises as it folds; the caller clips what is left over.
private struct Fold: Layout {
    /// 1 open, 0 folded.
    var shown: CGFloat
    var animatableData: CGFloat {
        get { shown }
        set { shown = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? size.width, height: size.height * max(0, shown))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

/// **Two views in one place, whose height goes from the first's to the second's** as `shown` goes from 0 to 1 (fix
/// round 3d): both stand at its top, whole, and the caller clips what stands past it. A folding card keeps its question
/// in one of them and the rows under it in another, so the question stands once.
struct CrossFold: Layout {
    /// 0 the first view's height, 1 the second's.
    var shown: CGFloat
    var animatableData: CGFloat {
        get { shown }
        set { shown = newValue }
    }

    /// The height at `shown`, from one height to the other.
    static func height(from first: CGFloat, to second: CGFloat, shown: CGFloat) -> CGFloat {
        first + (second - first) * min(max(shown, 0), 1)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) }
        guard let first = sizes.first, let second = sizes.last else { return .zero }
        return CGSize(width: proposal.width ?? max(first.width, second.width),
                      height: Self.height(from: first.height, to: second.height, shown: shown))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}

/// **One open request, on Needs you and in the chat of the agent that raised it** (the owner's yes of 28 October 2026 to
/// D-7): one card for both, so he answers where he is asked, and Needs you keeps them all. On Needs you who asks and
/// when stand over it ("From Iris · 0:08"); in the chat, the chat says it. **In a chat the card's corners are the
/// bubble's 18 and its option rows 10** (fix round 2, item 96), so a chat with a card has three radii. **On Needs you its
/// corners are the 26 of the cards on Tasks, a task and Settings** (the owner, 30 October 2026: "26 pt, as other pages";
/// margins pass, fault 18). **In the chat an answered one stays, folded** (item 103; `NeedAnswered`): to two lines, or to
/// its title alone where his answer stands in the chat as his own message (`spoken`).
struct NeedCard: View {
    let store: MobileStore
    let need: OwnerNeed
    /// The card was open when it was last drawn, and how far its fold has gone (fix round 3, item 40).
    @State private var wasOpen = false
    @State private var foldShare: CGFloat = 0
    /// The open card took his message under it (`OwnerNeed.clarify`): its link stays while it folds, since the hub's
    /// answered item takes none, and the rows under the question would lose its height in the fold's first frame.
    @State private var tookTalk = false
    /// The field of Needs clarification stands on this card (`NeedClarify.stands`): the card keeps it, so the field
    /// stays while the card folds, where the rows under the question are drawn again (review B of 20 November 2026).
    @State private var clarifyStands = false
    /// Who asks and when, over the card: on Needs you.
    var header = false
    /// The files of the message that answered it, which its answer shows.
    var answerFiles: [MessageAttachment] = []
    /// His answer as Needs you keeps it until the item folds (`NeedsPage.given`); in a chat, as the store has it.
    var given: MobileStore.GivenAnswer? = nil
    /// In a chat: his answer stands there as his own message (`ChatRequestPlaces.spoken`), so the folded card does not
    /// say it a second time.
    var spoken = false

    /// The card's shape: 26 on Needs you, as a card of the system's lists, and 18 in a chat, as a bubble.
    static func shape(onPage: Bool) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: onPage ? 26 : 18, style: .continuous)
    }
    /// From one item's foot to the next item's head, and from a head to its card: the grouped list's measures.
    static let gap: CGFloat = 20
    static let head: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if header { NeedHead(store: store, need: need, took: answerGiven != nil) }
            Group {
                // **An answered card folds to its two lines frame by frame, over 250 ms, easing out** (fix round 3, item
                // 40): the open rows' height goes as the two lines' comes, so the chat's height and its place change in
                // each frame. It changed in one step, and the conversation dropped 348 points in one frame.
                if wasOpen && !need.isOpen {
                    folding(foldShare)
                // An answered card pads itself, inside its button, so its whole card takes the tap (fix round 3, HIG).
                } else if need.isOpen {
                    open.padding(16)
                } else {
                    NeedAnswered(store: store, need: need, files: answerFiles, spoken: spoken)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.surface, in: Self.shape(onPage: header))
            // The card's edge, under Increase Contrast only (item 55).
            .overlay(Self.shape(onPage: header).strokeBorder(Brand.cardEdge, lineWidth: 1))
            // **The line under the card folds with the card** (polish pass: the receipt's jump): in a chat its height
            // goes on the fold's own clock, and on Needs you the page folds the card and its line as one. It went in
            // the frame the fold began, or at the receipt, one read before the fold.
            if need.isOpen || wasOpen {
                Fold(shown: 1 - foldShare) {
                    NeedFooter(store: store, need: need)
                        .padding(.horizontal, 16)
                }
                // Cut to its height only while it folds: a "Try again" in it keeps its 44-point touch.
                .clipShape(Rectangle().inset(by: foldShare > 0 ? 0 : -24))
                .opacity(1 - foldShare)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-need-\(need.id)")
        .onAppear { wasOpen = need.isOpen; tookTalk = need.isOpen && need.clarify == true }
        .onChange(of: need.isOpen) { was, now in
            if now { wasOpen = true; foldShare = 0; tookTalk = need.clarify == true; return }
            guard was else { return }
            withAnimation(.easeOut(duration: 0.25)) { foldShare = 1 } completion: { wasOpen = false }
        }
        .onChange(of: need.clarify) { _, now in if need.isOpen { tookTalk = now == true } }
    }

    /// **The card takes his message under it** (Needs clarification, owner feature `need_clarify`): on a hub that names
    /// the feature, where the hub says so of the open item, and while the card folds where it said so when it was open.
    private var takesTalk: Bool { store.supportsTalk && (need.isOpen ? need.clarify == true : tookTalk) }

    private var open: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(need.shownTitle).font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            openRows
        }
    }

    /// His answer to this request, from the hub's request for it until the item folds.
    private var answerGiven: MobileStore.GivenAnswer? { given ?? store.givenAnswer(to: need.id) }

    /// **The answered card while it folds: its question once, and under it the open rows going as the answer's line
    /// comes** (fix round 3d), `share` 0 open and 1 folded. The open card and the two lines stood one over the other,
    /// so the question showed twice for about 130 ms. The height goes from the open card's to the two lines', 16
    /// points inside the card's edge as both are, so nothing jumps where the fold begins or ends.
    private func folding(_ share: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // The question: the open card's words, whose lines under the first go with the rows, and the folded card's
            // one line coming over the first, with its "…" where the words do not fit. The lines under the first fade
            // in 0.1 s, faster than the 0.25 s of the row that cuts them, so it cuts only words that have nearly gone.
            CrossFold(shown: share) {
                Text(need.shownTitle).font(.headline).fixedSize(horizontal: false, vertical: true)
                    .mask(alignment: .top) {
                        ZStack(alignment: .top) {
                            Color.black.opacity(1 - share).animation(.easeOut(duration: 0.1), value: share)
                            NeedAnswered.titleLine(need).hidden().frame(maxWidth: .infinity).background(Color.black)
                        }
                    }
                    .accessibilityHidden(true)
                NeedAnswered.titleLine(need).opacity(share)
            }
            .clipped()
            // Under it: the open rows go, and the answer's line comes in its place under the question. Where his words
            // are his own message in the chat, no line comes, and the rows go to nothing.
            CrossFold(shown: share) {
                openRows.padding(.top, 12)
                    .opacity(1 - share).allowsHitTesting(false).accessibilityHidden(true)
                if NeedAnswered.saysAnswer(need, spoken: spoken) {
                    NeedAnswered.answerLine(need).padding(.top, 4).opacity(share)
                } else {
                    Color.clear.frame(height: 0)
                }
            }
            .clipped()
        }
        .padding(16)
    }

    /// What the open card holds under its question.
    private var openRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !need.why.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                RowLine()
                FieldRow(title: String(l10n: "Why"), value: need.why)
            }
            if NeedScript.text(need) != nil {
                RowLine()
                NeedScript(need: need)
            }
            if NeedOptions.asksInWords(need) {
                RowLine()
                FieldRow(title: String(l10n: "What it wants"), value: need.todo)
            }
            RowLine()
            // owner feature need_clarify: his talk with the agent under the card, over its answers, also where the
            // card takes no more of it: the talk is his record of the item, and it stays whole beside his answer
            let talk = store.talk(of: need)
            if !talk.isEmpty { NeedTalkLines(talk: talk) }
            if need.asksForSecret {
                NeedSecretNote(need: need)
                // Needs clarification, under the line about the Mac, for a hub that takes his words from a phone
                if store.supportsClarify {
                    NeedClarify(store: store, need: need, sent: answerGiven?.words, stands: $clarifyStands)
                }
            } else {
                // the options, and on an item with none the row of the words that its agent recommends; each row dims
                // by itself beside the answer that he gave
                if !need.phoneRows.isEmpty || NeedOptions.recommendedWords(need, store: store) != nil {
                    NeedOptions(store: store, need: need, given: answerGiven)
                }
                NeedAnswerBox(store: store, need: need, sent: answerGiven?.words)
                    .opacity(answerGiven?.option != nil ? NeedOptions.dimmed : 1)
                // owner feature need_clarify: the quiet link Needs clarification under his answer, which stays (the
                // owner's "Keep Your answer too"), where the hub says that the card takes his message; once he gave an
                // answer it dims with the rows, and takes no touch, VoiceOver's neither
                if takesTalk {
                    NeedClarify(store: store, need: need, stands: $clarifyStands)
                        .opacity(answerGiven != nil ? NeedOptions.dimmed : 1)
                        .disabled(answerGiven != nil)
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: answerGiven)
    }
}

extension MobileStore {
    /// His answer to a request, as an item shows it while it goes: the option that he pressed, or his words.
    enum GivenAnswer: Equatable, Sendable {
        case option(Int), words(String)

        var option: Int? { if case .option(let index) = self { index } else { nil } }
        var words: String? { if case .words(let text) = self { text } else { nil } }
    }

    /// His answer to `need` that the hub's request carries now, or that the hub took and the reading does not have
    /// yet. A press that waits for the hub is no answer yet: its item says "Sending…". **An answer that did not go is
    /// none either** (review of 11 November 2026): its item says "Not sent" with Try again, which he must be able to
    /// press, so only a request of this hub and generation that goes now counts (`goes`).
    func givenAnswer(to need: Int) -> GivenAnswer? {
        let going = pending.flatMap { Self.goes($0, to: need, of: hub, database: snapshot?.db, sending: sending) ? $0 : nil }
        guard let request = going ?? answersTaken[need]?.request else { return nil }
        return request.choice.map(GivenAnswer.option) ?? .words(request.text)
    }

    /// **A waiting request is his answer on its way only while a send carries it.** One that waits with no send is
    /// none: an error stopped it, or the app started with it in the Outbox, and the app sends a kept request only at
    /// his Try again. The rule counted every request that no error had stopped, and after a start no error is
    /// recorded: the item on Needs you counted as answered and took no touch, while its line said "Not sent" with Try
    /// again (found on 20 November 2026 by the review of the key card's Needs clarification).
    static func goes(_ request: PendingRequest, to need: Int, of hub: URL, database: String?, sending: Bool) -> Bool {
        sending && request.needID == need && request.refusal == nil && request.hub == hub && request.database == database
    }
}

/// **The check of an answer that he gave**: it draws itself, stroke by stroke, where the system can (iOS 26), and
/// fades in before that. It keeps its place from the first frame, so nothing beside it moves while it draws.
struct DrawnMark: View {
    let symbol: String
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let mark = Image(systemName: symbol)
        mark.hidden().overlay { if drawn { mark.transition(Self.drawsOn) } }
            .accessibilityHidden(true)
            .task {
                guard !drawn else { return }
                if reduceMotion { drawn = true; return }
                try? await Task.sleep(for: .milliseconds(110))
                withAnimation(.easeOut(duration: 0.26)) { drawn = true }
            }
    }

    static var drawsOn: AnyTransition {
        if #available(iOS 26, *) { AnyTransition(.symbolEffect(.drawOn)) } else { .opacity }
    }
}

/// "Nothing needs you", where the items stood. **Its mark draws itself when his answer folded the last item away**,
/// and its words come after it; on a page that opens with no item it stands at once, as before.
private struct NothingNeedsYou: View {
    /// As the page said it when the words first showed: a later change does not cut the drawing short.
    @State private var draws: Bool
    @State private var said = false

    init(draws: Bool) { _draws = State(initialValue: draws) }

    var body: some View {
        ContentUnavailableView {
            Label {
                Text("Nothing needs you").opacity(draws && !said ? 0 : 1)
            } icon: {
                if draws { DrawnMark(symbol: "checkmark.circle") } else { Image(systemName: "checkmark.circle") }
            }
        }
        .task {
            guard draws else { return }
            try? await Task.sleep(for: .milliseconds(640))
            withAnimation(.easeOut(duration: 0.32)) { said = true }
        }
    }
}

/// **An answered request folds to two lines in the chat** (fix round 2, item 103; D-7 item 2, as the Mac's
/// `NeedRequestCard` folds it): its title, as the open card's, and what he answered, in the card's small type and its
/// quiet colour; the rest on a tap — the request, "Answered", and his answer with its files — and a tap on its title
/// folds it again. **The check is for an option that he pressed** ("✓ Correos"; the owner, 14 November 2026: "when I
/// typed a custom answer instead of choosign one of the suggested ones, do not show the CHECK animation because it is
/// misleading"): words that he wrote can ask something back or say no, so they stand with no check, and where they
/// are his own message in the chat (`spoken`) the card folds to its title alone. (The Mac's card says his answer
/// always, and stands where he answered it, since 19 November 2026: `ChatRequestPlaces.Answered`.)
private struct NeedAnswered: View {
    let store: MobileStore
    let need: OwnerNeed
    let files: [MessageAttachment]
    /// His answer stands in the chat as his own message: the folded card does not say it a second time.
    var spoken = false
    @State private var expanded = false

    private var answer: String { need.answer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    /// What he answered, in the folded card's second line: his words or the option he pressed.
    private var answerWords: String { Self.words(of: need) }
    static func words(of need: OwnerNeed) -> String {
        // owner feature need_run: a press of Run on the Mac, in this phone's words: "Ran on <Mac>"
        if !need.isOpen, need.run_command != nil, need.run_status != nil {
            let place = need.run_on == NeedRun.ownMac || need.run_on == nil ? String(l10n: "your Mac") : need.run_on!
            return String(l10n: "Ran on \(place)")
        }
        let answer = need.answer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return answer.isEmpty ? String(l10n: "Answered") : answer
    }

    /// The folded card's first line: the question on one line. Its fold draws the same line (`NeedCard`).
    static func titleLine(_ need: OwnerNeed) -> some View { Text(need.shownTitle).font(.headline).lineLimit(1) }

    /// The folded card has its second line: not where his own words stand in the chat as his message.
    static func saysAnswer(_ need: OwnerNeed, spoken: Bool) -> Bool { !(need.answeredInWords && spoken) }

    /// The folded card's second line: what he answered, an option that he pressed with a check ("✓ Correos"), and
    /// words that he wrote with none.
    static func answerLine(_ need: OwnerNeed) -> some View {
        HStack(spacing: 5) {
            // a cross for a command that he ran on the Mac and that ended with another exit status than 0
            if !need.answeredInWords {
                Image(systemName: (need.run_status ?? 0) == 0 ? "checkmark" : "xmark").font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
            }
            Text(verbatim: words(of: need)).lineLimit(1)
        }
        .font(.caption).foregroundStyle(Brand.muted)
        // VoiceOver: a run that failed says its exit status, which the cross alone does not say
        .accessibilityElement(children: .combine)
        .accessibilityLabel((need.run_status ?? 0) == 0 ? words(of: need)
                            : words(of: need) + ", " + String(l10n: "exit status \(need.run_status ?? 0)"))
    }

    /// **It changes in one step, as the Mac's card does when it is answered** (item 103): the chat stands on its newest
    /// line, so a card that grows or shrinks moves the conversation above it, and an animation of it moved that in one
    /// frame anyway — the scroll view takes the new height at once — and then slid the rest (255 points, then 93).
    var body: some View {
        if expanded { whole } else { folded }
    }

    private var whole: some View {
        wholeRows.padding(16)
    }

    private var wholeRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { expanded = false } label: {
                HStack(alignment: .firstTextBaseline) {
                    Text(need.shownTitle).font(.headline)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text("Answered").font(.caption).foregroundStyle(Brand.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.primary)
            .accessibilityHint("Folds the request")
            .accessibilityIdentifier("need-fold-\(need.id)")
            if !need.why.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                RowLine()
                FieldRow(title: String(l10n: "Why"), value: need.why)
            }
            if NeedOptions.asksInWords(need) {
                RowLine()
                FieldRow(title: String(l10n: "What it wants"), value: need.todo)
            }
            // owner feature need_clarify: **an answered card keeps his talk with the agent, read only**, before his
            // answer, as the Mac's card keeps it: no link and no field
            let talk = store.talk(of: need)
            if !talk.isEmpty {
                RowLine()
                NeedTalkLines(talk: talk)
            }
            if !answer.isEmpty || !files.isEmpty {
                RowLine()
                if answer.isEmpty {
                    Text("Your answer").font(.caption).foregroundStyle(Brand.muted)
                } else {
                    FieldRow(title: String(l10n: "Your answer"), value: answer)
                }
                if !files.isEmpty { AttachmentGallery(store: store, files: files, alignment: .leading) }
            }
        }
    }

    private var folded: some View {
        Button { expanded = true } label: {
            VStack(alignment: .leading, spacing: 4) {
                Self.titleLine(need)
                if Self.saysAnswer(need, spoken: spoken) { Self.answerLine(need) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
        .accessibilityElement(children: .ignore)
        // Words that stand in the chat as his own message are read there, not here a second time.
        .accessibilityLabel(Self.saysAnswer(need, spoken: spoken) ? Text("\(need.shownTitle), answered: \(answerWords)")
                            : Text("\(need.shownTitle), answered"))
        .accessibilityHint("Shows the whole request")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("need-folded-\(need.id)")
    }
}

/// Who asks and when, over a request on Needs you: **the agent's mark before its name** (the owner's yes of 28 October
/// 2026 to D-8), at rest, in its own look — grey while it is offline, dashed in setup — **with its presence dot, as
/// every mark before a name has it** (the lead's call on item 69), **in the Mac's form**, "From Iris · 0:08" (fix round
/// 2, item 31): it was "Iris" and "12 min ago" at the far right.
private struct NeedHead: View {
    let store: MobileStore
    let need: OwnerNeed
    /// He gave his answer: 0.3 s later the agent's mark makes one small jump, as the Mac's glyph does.
    var took = false
    @State private var jumps = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Half the height of the headline's capitals: the mark's centre stands this far over the first line's baseline.
    @ScaledMetric(relativeTo: .headline) private var capHalf: CGFloat = 6

    var body: some View {
        // **The mark stands on the head's first line** (margins pass, fault 15), as on the row of a task that only he
        // can move: at the largest text sizes the head takes two lines, and the mark stood on their middle.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            AgentAvatar(name: need.by, state: store.state(of: need.by), base: 20, moves: false)
                .keyframeAnimator(initialValue: 1.0, trigger: jumps) { view, scale in view.scaleEffect(scale) } keyframes: { _ in
                    KeyframeTrack {
                        SpringKeyframe(1.18, duration: 0.14)
                        SpringKeyframe(1.0, duration: 0.45, spring: .bouncy)
                    }
                }
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + capHalf }
            Text(requestHead(by: need.by, raised: need.raised))
            Spacer(minLength: 0)
        }
        // The grouped list's own header type, which this head had as a section's header.
        .font(.headline)
        // The quiet words' colour, 5.3:1 on the light canvas (T-29).
        .foregroundStyle(Brand.muted)
        .padding(.horizontal, 16)
        .padding(.top, NeedCard.head).padding(.bottom, NeedCard.head)
        .accessibilityElement(children: .combine)
        .task(id: took) {
            guard took, !reduceMotion else { return }
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { jumps += 1 }
        }
    }
}

/// **The answers the agent offered, as rows to press** (the owner's yes of 28 October 2026 to D-7): each one the whole
/// width of the item and 44 points high, in the quiet grey of what is his to press, and a press sends that answer, as
/// the ping's button for it does. The item asked him to press buttons it did not draw ("Press one, or write another
/// time."), so that line of the agent's goes where its options stand.
///
/// **They are never drawn grey** (fix round 2, item 51): a press while the hub cannot take it waits and goes when it
/// can, and the item says "Sending…" under it (`MobileStore.press`). They went grey at 1.71:1 whenever the hub was slow
/// or away or another write waited.
///
/// **An option that only a Mac or a PC can press is not drawn** (`OwnerNeed.phoneRows`): Give, a team card's yes and
/// the door card's Full access, whose place `NeedComputerNote` takes. The others keep their own index, which their
/// press sends.
struct NeedOptions: View {
    let store: MobileStore
    let need: OwnerNeed
    /// His answer, while it goes: the option that he pressed takes a check that draws itself, and the others dim.
    var given: MobileStore.GivenAnswer? = nil
    /// What an answer that he did not give looks like beside the one that he gave.
    static let dimmed = 0.38

    /// The agent's "What it wants" stands only for an item without options: with them, what it wants are the rows.
    static func asksInWords(_ need: OwnerNeed) -> Bool {
        need.choices.isEmpty && !need.todo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// **The words that the agent recommends on an item with no options** (owner feature `need_recommended`, API 1.269):
    /// one row of their own over his answer; nil on every other item. The phone has none of the Mac's three replies, so
    /// no reply takes their badge.
    static func recommendedWords(_ need: OwnerNeed, store: MobileStore) -> String? {
        guard case .words(let words) = need.recommendedRow(features: Array(store.features), replies: []) else {
            return nil
        }
        return words
    }

    /// Over and under the words of the recommended row: a first line that wraps stands under the badge, and one line
    /// keeps the row's 44 points. It grows with the badge, which stops growing at the largest ordinary text size.
    @ScaledMetric(relativeTo: .caption) private var clearScaled: CGFloat = 11
    private var clear: CGFloat { min(clearScaled, RecommendedBadge.clearMost) }

    var body: some View {
        let rows = need.phoneRows
        // owner feature need_recommended: the row of the answer that the agent recommends, with its badge
        let recommended = need.recommendedRow(features: Array(store.features), replies: [])
        VStack(alignment: .leading, spacing: 8) {
            if case .words(let words) = recommended { recommendedWords(words) }
            ForEach(rows, id: \.self) { row in
                switch row {
                case .option(let index):
                    option(index, recommended: recommended == .option(index))
                case .onTheComputer:
                    // it stands for answers that he does not give here, so it dims with them once he gives one; as the
                    // first row it keeps 16 points to the row under it, as the line of Give and of a team card had
                    NeedComputerNote(need: need)
                        .padding(.bottom, row == rows.first ? 4 : 0)
                        .opacity(given != nil ? Self.dimmed : 1)
                }
            }
        }
    }

    /// One option to press: its press sends its own index. The answer that the agent recommends has its badge on the
    /// row's top edge (`RecommendedBadge`), and **no edge of its own** (the owner, 20 November 2026: "the recommended
    /// options should only have the badge, not the border over the option, otherwise it looks alraedy selected").
    private func option(_ index: Int, recommended marks: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button { store.press(needID: need.id, choice: index) } label: {
            // The agent's words, drawn as a plain label: they are data, never markup.
            HStack(spacing: 10) {
                if given == .option(index) { DrawnMark(symbol: "checkmark").fontWeight(.semibold) }
                Text(verbatim: need.choices[index])
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
                .padding(.vertical, marks ? clear : 0)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 14)
                .background(Brand.bubble, in: shape)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
        .recommendedBadge(by: marks ? need.by : nil)
        // it dims, with its badge, beside the answer that he gave: another option, or his words
        .opacity(given.map { $0 != .option(index) } == true ? Self.dimmed : 1)
        .accessibilityAddTraits(given?.option == index ? .isSelected : [])
        .accessibilityValue(marks ? Text("Recommended") : Text(verbatim: ""))
        .accessibilityIdentifier("need-option-\(need.id)-\(index)")
    }

    /// **The words that the agent recommends, as one row over his own answer** (owner feature `need_recommended`): a
    /// press sends them as his answer in words, as if he had typed them, so they stand in the field while they go and
    /// the hub knows them as the agent's words, not as an option. Its badge stands on its top edge, with no edge of its
    /// own, as an option's.
    private func recommendedWords(_ words: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button { send(words) } label: {
            // The agent's words, drawn as a plain label: they are data, never markup.
            Text(verbatim: words)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, clear)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 14)
                .background(Brand.bubble, in: shape)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
        .recommendedBadge(by: need.by)
        .opacity(given.map { $0 != .words(words) } == true ? Self.dimmed : 1)
        .accessibilityValue(Text("Recommended"))
        .accessibilityIdentifier("need-recommended-\(need.id)")
    }

    /// His answer in the words that the agent recommends (`MobileStore.press(needID:words:)`): they stand in the field
    /// and go as his words go, and a press that waits for the hub says "Sending…", as a press on an option does.
    private func send(_ words: String) {
        guard given == nil else { return }
        store.press(needID: need.id, words: words)
    }
}

/// **The badge of the answer that the agent recommends** (owner feature `need_recommended`, API 1.269; the owner's pick
/// "B: badge on the edge" of three pictures, 20 November 2026, whose words said that the word shows on the iPhone too,
/// where there is no hover): the Mac's `RecommendedBadge`, a capsule on the top edge of that answer's row, at its
/// trailing side and half over the edge, with the glyph of the agent that raised the item, at rest, and the word
/// Recommended, in that agent's own colour (`GlyphLook.mid`). **In light its word is the glyph's deep step, darkened**:
/// the Mac's word, a light tint for a dark card, read under 2:1 on the phone's white card (`MobileRecommendedTests`).
/// A press goes to the row under it, and VoiceOver reads the word on the row.
struct RecommendedBadge: View {
    let agent: String
    @Environment(\.markTeam) private var team
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .caption) private var glyph: CGFloat = 14

    /// **The badge stops growing at the largest ordinary text size**, as the round buttons of a chat do: at the largest
    /// accessibility size it stood wider than a 375-pt phone's row (two reviews of 20 November 2026).
    static let largest = DynamicTypeSize.xxxLarge
    /// The room over the badge's row, and the space over the row's own words, at that size.
    static let roomMost: CGFloat = 13
    static let clearMost: CGFloat = 14

    /// The colours of the badge.
    struct Colours {
        /// A part of the agent's colour over the card, which hides the row's top under the badge.
        let fill: Color
        let edge: Color
        let word: Color
    }

    /// The Mac's colours on a dark card (a quarter of the colour, its light step half way to white for the word), and on
    /// the phone's white card a lighter fill and a word half way from the deep step to black.
    static func colours(of look: GlyphLook, dark: Bool) -> Colours {
        let mid = look.mid
        return Colours(fill: mid.opacity(dark ? 0.25 : 0.15), edge: mid.opacity(0.8),
                       word: dark ? mix(look.light, .white, 0.5) : mix(look.deep, .black, 0.5))
    }

    /// The colour `part` of the way from `one` to `two`, in sRGB, as `GlyphLook.mid` mixes its two steps.
    static func mix(_ one: Color, _ two: Color, _ part: Double) -> Color {
        var a: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0), b = a
        UIColor(one).getRed(&a.0, green: &a.1, blue: &a.2, alpha: &a.3)
        UIColor(two).getRed(&b.0, green: &b.1, blue: &b.2, alpha: &b.3)
        return Color(red: Double(a.0 + (b.0 - a.0) * part), green: Double(a.1 + (b.1 - a.1) * part),
                     blue: Double(a.2 + (b.2 - a.2) * part))
    }

    var body: some View {
        let colours = Self.colours(of: MarkTeam.look(of: agent, in: team), dark: scheme == .dark)
        HStack(spacing: 5) {
            AgentMark(name: agent, size: glyph, moves: false)
            Text("Recommended").font(.caption).lineLimit(1)
        }
        .foregroundStyle(colours.word)
        .padding(.leading, 4).padding(.trailing, 9).padding(.vertical, 2)
        .background(Capsule().fill(Brand.surface).overlay(Capsule().fill(colours.fill)))
        .overlay(Capsule().strokeBorder(colours.edge, lineWidth: 1))
        .fixedSize()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The badge of the answer that `agent` recommends on a row, when it is not nil: its middle on the row's top edge and
/// its end 12 points from the row's, with room over the row for its upper half. The row is one view with or without it,
/// so a read that brings the badge keeps the row's own state.
private struct RecommendedPlace: ViewModifier {
    let agent: String?
    @ScaledMetric(relativeTo: .caption) private var room: CGFloat = 10

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                // the guide stands on a view that is always there, as on the Mac
                ZStack {
                    if let agent { RecommendedBadge(agent: agent).dynamicTypeSize(...RecommendedBadge.largest) }
                }
                .alignmentGuide(.top) { $0[VerticalAlignment.center] }
                .padding(.trailing, 12)
            }
            .padding(.top, agent == nil ? 0 : min(room, RecommendedBadge.roomMost))
    }
}

extension View {
    /// The badge of the answer that `agent` recommends on this row (`RecommendedBadge`); nothing for nil.
    func recommendedBadge(by agent: String?) -> some View { modifier(RecommendedPlace(agent: agent)) }
}

/// **The answer of one item in words or files, in the chat composer's look** (fix round 2, item 78): one capsule with
/// the plain "+" at its left, the field, and the round Send at its right, "+" and Send on the field's one line. It was a
/// filled grey "+" circle beside a field of its own shape, a second composer look on a chat that already has one. Send
/// is the accent's violet, as every Send that is not a chat's (item 68). The whole capsule takes a tap (item 53).
struct NeedAnswerBox: View {
    let store: MobileStore
    let need: OwnerNeed
    /// His words went: they stay in the field until the item folds, and Send goes, as it does whenever nothing can go.
    /// **No check takes its place** (the owner, 14 November 2026: "when I typed a custom answer instead of choosign one
    /// of the suggested ones, do not show the CHECK animation because it is misleading"): Send became a check that
    /// drew itself, over words that can ask something back or say no.
    var sent: String? = nil
    @FocusState private var focused: Bool
    /// One line of the field, so "+" and Send stand on its centre at every text size.
    @ScaledMetric(relativeTo: .body) private var line: CGFloat = 22

    private static let capsule = RoundedRectangle(cornerRadius: 25, style: .continuous)

    var body: some View {
        // The words that the hub took stay in the field until the item folds with them (`answersTaken`): the field
        // emptied at the receipt, and a longer answer's field shrank one read before the fold. A press on an option
        // wrote nothing in the field, so its field stays as it is.
        let taken = store.answersTaken[need.id]
        let typed = taken.flatMap { $0.request.choice == nil ? $0.request.text : nil }
        let text = Binding(get: { sent ?? typed ?? store.answerDraft(for: need.id) },
                           set: { store.setAnswerDraft($0, for: need.id) })
        let trimmed = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let composer = MobileStore.stageKey(need: need.id)
        let files = store.readyFiles(for: composer)
        let waiting = store.filesAreWaiting(for: composer)
        let canSend = sent == nil && taken == nil && store.canWrite && !waiting && trimmed.count <= MobileStore.textLimit
            && (!trimmed.isEmpty || !files.isEmpty)
        VStack(alignment: .leading, spacing: 8) {
            AttachmentStrip(store: store, composer: composer)
            HStack(alignment: .bottom, spacing: 0) {
                // As in a chat: the round buttons stop growing at the largest ordinary text size.
                if store.supportsAttachments {
                    AttachmentButton(store: store, composer: composer, bare: true)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .frame(height: line + 28)
                }
                TextField(text: text, prompt: Text("Your answer").foregroundStyle(Brand.placeholder), axis: .vertical) {
                    Text("Your answer")
                }
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .focused($focused)
                .padding(.vertical, 14)
                .padding(.leading, store.supportsAttachments ? 0 : 15)
                .padding(.trailing, 6)
                .accessibilityIdentifier("answer-\(need.id)")
                // The keyboard goes with the answer, before the item folds (item 95): it does not carry the page.
                SendButton(enabled: canSend, label: String(l10n: "Send answer"), side: 36) {
                    focused = false
                    await store.send(needID: need.id)
                }
                .accessibilityIdentifier("send-answer-\(need.id)")
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .frame(height: line + 28)
            }
            // "+" concentric with the capsule's round end, as Send is and as in a chat (margins pass, fault 6).
            .padding(.leading, 3).padding(.trailing, 7)
            .background {
                Self.capsule.fill(Brand.bubble)
                    .onTapGesture { focused = true }
            }
            // **The files of the answer on its way stay under the field until the item folds** (polish pass): the
            // send's and, after the receipt, the taken answer's, in the same row, so its pictures stay drawn. The row
            // went at the receipt, one read before the fold.
            let going = store.pending.flatMap { $0.needID == need.id ? $0 : nil }
            if let ids = going?.attachments ?? taken?.request.attachments, !ids.isEmpty {
                AttachmentStrip(store: store, composer: composer, sending: ids, held: going == nil ? taken?.files : nil)
            }
        }
    }
}

/// **The root script that the door card's Run it once lets through once** (the lane "Give on the iPhone"; the owner's
/// "Show the script" of 19 November 2026 to its picture): under Why, the text of the card's details, one code block,
/// byte for byte as the check reads it (`DoorCall.shown`), in the code font of a chat. **Each line wraps, as the Mac's
/// card wraps its script** (`MessageText.script`), so the end of a long line is on screen before he signs: the hub's
/// rules of a script (no wide gap, no run of blank lines) keep a command in his sight only where nothing scrolls. On
/// the card's own fill it stands in a well of the page's colour, as on the Mac's card, or no edge would show. The phone
/// signs Run it once only for the hash of that script (`DeviceSigningKey.approval`).
struct NeedScript: View {
    let need: OwnerNeed

    /// The script that the card shows, or nil: no door card of a run, no script, or details that are not one code block.
    static func text(_ need: OwnerNeed) -> String? {
        guard need.door_host?.isEmpty == false, need.door_script != nil, let details = need.details else { return nil }
        return DoorCall.shown(details: details)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(String(l10n: "Script")).font(.caption).foregroundStyle(Brand.muted)
            Text(verbatim: Self.text(need) ?? "")
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.canvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A request for a key or a login takes no answer here. A key typed on this phone would go out as words, into the
/// agent's conversation, before anything could mask it, and the hub refuses an answer in words. Founderizer on the
/// Mac answers it with its secure form, which puts the value straight into the vault.
struct NeedSecretNote: View {
    let need: OwnerNeed

    var body: some View {
        // The key in the column of a task's mark (margins pass, fault 11).
        MarkedLine(symbol: "key.horizontal",
                   words: String(l10n: "Type it in Founderizer on your Mac: it goes straight into the vault, and no agent sees it."))
            .font(.callout)
            .padding(.vertical, 4)
            .accessibilityIdentifier("secret-need-\(need.id)")
    }
}

/// **Needs clarification on the phone's card of a request for a key or a login** (the owner's "Yes, build it" of 20
/// November 2026 to its picture; on the Mac's card since 19 November 2026: "There should be a way to Reply or comment
/// to the card, to give more context or clarify something", "I prefer Needs clarification", "and THEN show the text
/// input"): under the line about the Mac, the link, and after a tap the field in its place, "Message to" and the agent
/// that asked, with Send. The phone saves no secret, so the card has no other answer. His message closes the request
/// and goes to the agent that asked, which asks again; it is saved and sent as an answer is (`MobileStore.clarify`),
/// so a failure sends the same request again and never a second one.
///
/// **Every other card that takes his message has the same link, under his answer** (Needs clarification on every card,
/// owner feature `need_clarify`, API 1.272; the owner, 20 November 2026: "a button link, that then shows the extra text
/// input", and his pick "Keep Your answer too" to the picture of the card): at the card's edge under the answer's
/// capsule, which stays and answers. His message there is no answer: it goes to the agent on its own route
/// (`MobileStore.talk`), the card stays open, and once the hub has it the field goes back to its link and the message
/// stands in the card's talk over the answers (`NeedTalkLines`). It is saved and sent once in the same way, and the
/// lines of an answer stand under the card while it goes.
///
/// **Words that look like a key do not go** (`KeyInText`), and one line over the field says so: a key typed here
/// would go out as words, into the agent's conversation. The field's words are the store's, in memory only
/// (`MobileStore.clarifyDrafts`): nothing writes them to a file, and the store empties them when the hub refuses
/// registered login text, so no copy of them stays on the screen.
struct NeedClarify: View {
    let store: MobileStore
    let need: OwnerNeed
    /// A key card: his words went as its answer, and they stay in the field until the item folds, and Send goes, as in
    /// an answer's box.
    var sent: String? = nil
    /// His message under a card that is no key request: it keeps the card open (`MobileStore.talk`), where a key card's
    /// words answer it.
    private var talks: Bool { !need.asksForSecret }
    /// The field stands on this card: he tapped the link, or words that stand in the store opened it (they open it on
    /// each card of the request). It stays until the card goes: a field that went back to the link at the last
    /// deleted character took the keyboard from under the cursor (review round 2). The card keeps it (`NeedCard`), so
    /// it stays while the card folds. His message under a card that the hub took sends the field back to its link.
    @Binding var stands: Bool
    /// The field takes the cursor once it stands: set in the tap that makes the field, the cursor could stay where it
    /// was (the chat's own composer), as the Mac's card found.
    @State private var takesCursor = false
    /// The send found words that look like a key: the line over the field, until he changes them.
    @State private var looksLikeKey = false
    @FocusState private var focused: Bool
    /// One line of the field, so Send stands on its centre at every text size.
    @ScaledMetric(relativeTo: .body) private var line: CGFloat = 22
    /// Where the words of the line over the link begin (`MarkedLine`: its mark's column and its gap); at the
    /// accessibility sizes that line's mark stands over its words, so the link begins at the card's edge too.
    @ScaledMetric(relativeTo: .title3) private var markWidth: CGFloat = 22
    @Environment(\.dynamicTypeSize) private var typeSize

    private static let capsule = RoundedRectangle(cornerRadius: 25, style: .continuous)
    /// The hub's most for those words, counted as the hub counts (`NeedSecret.length`). The field takes more, as an
    /// answer's box does: Send stops then, and the line under the card says the most (`NeedFooter`).
    private var most: Int { talks ? NeedTalk.most : NeedSecret.clarifyMost }

    var body: some View {
        let taken = store.answersTaken[need.id]
        // A key card's words that the hub took as its answer stay in the field until it folds; the answer of any other
        // card is never his message under it.
        let typed = talks ? nil : taken.flatMap { $0.request.choice == nil ? $0.request.text : nil }
        // The field's words are the store's (`MobileStore.clarifyDrafts`): no copy here outlives what the store empties.
        let draft = store.clarifyDraft(for: need.id)
        // His words that wait in the Outbox with no send (a send that failed, also before the app's last start): the
        // field shows them, because the line under the card says "Not sent" and Try again sends those words. His
        // message under a card stands there while it goes too.
        let kept = store.clarifyKept(for: need.id)
        let shown = Binding(get: { sent ?? typed ?? store.clarifyKept(for: need.id) ?? store.clarifyDraft(for: need.id) }, set: { text in
            // Nothing changes the words that went, while the item folds, or the words that wait for Try again.
            guard sent == nil, store.answersTaken[need.id] == nil, store.clarifyKept(for: need.id) == nil else { return }
            changed(text)
        })
        let trimmed = shown.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let canSend = sent == nil && taken == nil && kept == nil && store.canWrite && !trimmed.isEmpty
            && NeedSecret.length(trimmed) <= most
        VStack(alignment: .leading, spacing: 8) {
            if stands || !draft.isEmpty || kept != nil || (!talks && (sent != nil || taken != nil)) {
                // Over the field: under it, the keyboard stands on the line (the look check of 20 November 2026).
                if looksLikeKey {
                    ComposerNote(words: String(l10n: "That looks like a key. Never send a key in a message."), isWarning: true)
                        .accessibilityIdentifier("clarify-key-\(need.id)")
                }
                HStack(alignment: .bottom, spacing: 0) {
                    TextField(text: shown, prompt: Text("Message to \(agentName(need.by))").foregroundStyle(Brand.placeholder), axis: .vertical) {
                        Text("Message to \(agentName(need.by))")
                    }
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .padding(.vertical, 14)
                    .padding(.leading, 15)
                    .padding(.trailing, 6)
                    // The words that wait for Try again take no cursor: a field that took one showed what he typed,
                    // and none of it would go.
                    .allowsHitTesting(kept == nil)
                    .accessibilityIdentifier("clarify-\(need.id)")
                    SendButton(enabled: canSend, label: String(l10n: "Send message"), side: 36) {
                        // Words that look like a key stay here, with the line that says why, and nothing is saved.
                        if KeyInText.contains(trimmed) { looksLikeKey = true; return }
                        // The keyboard goes with the message, before the item folds, as with an answer.
                        focused = false
                        if talks { await store.talk(needID: need.id, words: trimmed) }
                        else { await store.clarify(needID: need.id, words: trimmed) }
                    }
                    .accessibilityIdentifier("send-clarify-\(need.id)")
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .frame(height: line + 28)
                }
                // The words begin where the words of an answer's box with no plus begin, and Send has its room.
                .padding(.leading, 3).padding(.trailing, 7)
                .background {
                    Self.capsule.fill(Brand.bubble)
                        .onTapGesture { if kept == nil { focused = true } }
                }
                .onAppear {
                    stands = true
                    if takesCursor { focused = true; takesCursor = false }
                }
            } else {
                // The link, with a row's height for the finger: on a key card in the column of the words of the line
                // over it, and under an answer's capsule at the card's edge, where its rows begin.
                TextAction(title: String(l10n: "Needs clarification"), font: .callout) { stands = true; takesCursor = true }
                    .foregroundStyle(Brand.accent)
                    .padding(.leading, talks || typeSize.isAccessibilitySize ? 0 : markWidth + 12)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("clarify-link-\(need.id)")
            }
        }
        // The hub refused registered login text: the store emptied the words, and the line about a key goes with them.
        .onChange(of: store.secretRefusals) { _, _ in looksLikeKey = false }
        // The hub took his message under the card, which now stands in its talk: the field goes back to its link.
        .onChange(of: store.talkReceipts[need.id]) { _, _ in
            stands = false
            focused = false
            looksLikeKey = false
        }
    }

    /// The field's words changed: the line about a key goes once they hold none, and the store keeps them, in memory
    /// only. Nothing cuts them here: a cut that changed nothing in the store left the field with words that the store
    /// did not have, and Send sent the shorter ones (review round 2).
    private func changed(_ text: String) {
        if looksLikeKey, !KeyInText.contains(text) { looksLikeKey = false }
        store.setClarifyDraft(text, for: need.id)
    }
}

/// **His talk with the agent under a card** (Needs clarification on every card, owner feature `need_clarify`), as the
/// Mac's card shows it (`NeedTalkLines` there), in the look of this phone's chat: his messages at the trailing side in
/// his bubble, and the agent's replies at the leading side after its mark, at rest, oldest first. Each line keeps the
/// other side's room free, so none takes the whole width of an answer's row. The words are plain text, as he and the
/// agent wrote them. It stands over the answers of an open card, and read only before his answer on an answered one.
struct NeedTalkLines: View {
    let talk: [NeedMessage]
    /// The agent's mark beside its reply's first line, at a request's head's size, growing by half at most.
    @ScaledMetric(relativeTo: .body) private var mark: CGFloat = 20
    /// Half the height of the words' capitals: the mark's centre stands this far over the first line's baseline.
    @ScaledMetric(relativeTo: .body) private var capHalf: CGFloat = 6
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The side that a line leaves free; at the accessibility sizes less, where the words need the width (review B of
    /// 20 November 2026: a reply had 225 points at the largest size on a 375-point phone).
    private var room: CGFloat { typeSize.isAccessibilitySize ? 16 : 48 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(talk.enumerated()), id: \.offset) { _, line in
                if line.fromOwner { own(line) } else { reply(line) }
            }
        }
    }

    /// His message: the bubble of his messages in a chat.
    private func own(_ line: NeedMessage) -> some View {
        Text(verbatim: line.text)
            .textSelection(.enabled)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Brand.bubble, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.leading, room)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("You: \(line.text)"))
    }

    /// The agent's reply: its words bare after its mark, as an agent's words stand in a chat; at the accessibility
    /// sizes the mark stands over the words, as on a task's row.
    private func reply(_ line: NeedMessage) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        return layout {
            AgentMark(name: line.who, size: min(mark, 30), moves: false)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + capHalf }
            Text(verbatim: line.text)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.trailing, room)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(agentName(line.who)): \(line.text)"))
    }
}

/// **Give, and a team card's yes, are pressed in Founderizer on a Mac or a PC, and the door card's Full access on the
/// Mac** (the lane "Give on the iPhone"; the owner's "Line to the Mac" of 19 November 2026 to the phone's picture of an
/// item that carries its grant, and his "Yes, add it" of the same day for the door's card): the hub takes them only
/// from there, so one line with a key stands in their place, as on a request for a key. No, the agent's other options
/// and an answer in words stay: the hub takes them from here, except words that are the own words of Give, of a yes
/// option, or of Run it once or Full access on the door's card.
struct NeedComputerNote: View {
    let need: OwnerNeed

    var body: some View {
        MarkedLine(symbol: "key.horizontal", words: words)
            .font(.callout)
            .padding(.vertical, 4)
            .accessibilityIdentifier("computer-need-\(need.id)")
    }

    /// The first word of the hub's own answers that it stands for (`OwnerNeed.onlyOnAComputer`): a team card's yes
    /// options start with "Yes:", and Give's one with "Give". The door card's Full access is signed only by the owner
    /// key on the Mac (the owner's "Yes, add it" of 19 November 2026), so no PC is named there.
    private var words: String {
        switch need.onlyOnAComputer {
        case .teamYes: return String(l10n: "Press Yes in Founderizer on your Mac or PC.")
        case .fullAccess: return String(l10n: "Press Full access in Founderizer on your Mac.")
        case .give, nil: return String(l10n: "Press Give in Founderizer on your Mac or PC.")
        }
    }
}

/// Under the item: where its answer stands, or the one line that says why nothing can go now.
///
/// **A line brings its room with it** (polish pass): the 6 points over the line are the line's own, so a wait whose
/// words have not shown yet takes no room. The footer took them for every wait, also for "Sending…" in its quiet
/// second: when the hub took a press more slowly than one frame, the chat moved 6 points up and back before the card
/// folded, and on Needs you the next item jumped 5.7 points and slid back.
struct NeedFooter: View {
    let store: MobileStore
    let need: OwnerNeed

    /// From the card to the line under it.
    static let above: CGFloat = 6

    var body: some View {
        let composer = MobileStore.stageKey(need: need.id)
        // (a key request's words are the words about it, where its card takes them, counted as the hub counts them
        // against their own most. On another card his answer is counted, and his message under the card, counted so
        // against its most, which is far under an answer's: the line is of the one that is over its most, else of the
        // message once it nears its most, else of the answer; review B of 20 November 2026)
        let message = NeedSecret.length(store.clarifyDraft(for: need.id).trimmingCharacters(in: .whitespacesAndNewlines))
        let answer = store.answerDraft(for: need.id).trimmingCharacters(in: .whitespacesAndNewlines).count
        let messageMost = need.asksForSecret ? NeedSecret.clarifyMost : NeedTalk.most
        let counted = need.asksForSecret
            || (answer <= MobileStore.textLimit && message > messageMost - 500)
        let count = counted ? message : answer
        let most = counted ? messageMost : MobileStore.textLimit
        let taken = store.answersTaken[need.id] != nil
        // A request for a key takes no answer here but his words about it (`NeedClarify`), and only from a hub that
        // takes them from a phone. Then the lines of an answer stand under it too: a send, one that did not go, and
        // why nothing can go now (a file that cannot be saved, another request on its way). A card whose Send went
        // dead with no line was the fault of the first build.
        if need.asksForSecret && !store.supportsClarify {
            EmptyView()
        } else if taken || sends {
            // **This answer on its way is one line, from the press to the fold** (polish pass: the receipt's jump): a
            // press that waits for the hub (item 51), the send, and the answer that the hub took until its item folds.
            // Only a wait that takes a second says so (items 76 and 95), so its words never come once the hub took
            // the answer; words that came stay, and the item folds them away. They went at the receipt, with their
            // room, one read before the fold.
            Held(comes: !taken) { ComposerNote(words: String(l10n: "Sending…")).padding(.top, Self.above) }
                .accessibilityIdentifier("waiting-answer")
        } else if let pending = store.pending, pending.needID == need.id || store.talks(pending, under: need.id) {
            // (his message under the card is the card's own request too: its lines are an answer's)
            stoppedLine(pending)
        } else if let note = note(count: count, most: most, files: store.filesAreWaiting(for: composer)) {
            ComposerNote(words: note.words, isWarning: note.isWarning,
                         detail: store.storageError != nil ? store.storageErrorDetail
                             : store.fileError != nil ? store.fileErrorDetail : nil)
                .padding(.top, Self.above)
        } else if let other = store.pending, store.sending {
            // **Why this answer waits, in his words, and only for a wait that lasts** (fix round 2, item 42): "Another
            // request waits for its receipt." stood under every other item for each send, the hub's books in words.
            // A send that answers inside a second shows nothing that blinks away.
            Held {
                ComposerNote(words: other.needID == nil ? String(l10n: "Sending your message…") : String(l10n: "Sending your other answer…"))
                    .padding(.top, Self.above)
            }
        }
    }

    /// This item's own answer goes now: a press that waits for the hub, or a send that waits for its receipt; or his
    /// message under the card, on its way.
    private var sends: Bool {
        if store.waitingPresses[need.id] != nil { return true }
        guard let pending = store.pending, pending.needID == need.id || store.talks(pending, under: need.id) else { return false }
        return pending.refusal == nil && store.sending
    }

    /// This answer did not go: one line and the one action that fits. It stays until the hub confirms the answer or the
    /// owner discards a refused one.
    private func stoppedLine(_ request: PendingRequest) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let refusal = request.notSentLine {
                ComposerNote(words: refusal, isWarning: true)
                // Each action only while it can act, never grey (review B2i).
                TextAction(title: String(l10n: "Discard"), font: .caption) { store.discardRefused() }
            } else {
                ComposerNote(words: String(l10n: "Not sent"), isWarning: true)
                if store.canRetry {
                    TextAction(title: String(l10n: "Try again"), font: .caption) { Task { await store.retry() } }
                }
            }
        }
        .padding(.top, Self.above)
        .accessibilityIdentifier("waiting-answer")
    }

    /// At most one line under an answer: how near the hub's limit it is, or why nothing can go now.
    private func note(count: Int, most: Int, files waiting: Bool) -> (words: String, isWarning: Bool)? {
        if let words = store.storageError { return (words, true) }
        if let words = store.fileError { return (words, true) }
        if waiting {
            return (store.uploading.isEmpty ? String(l10n: "A file did not go up. Send it again, or take it out.") : String(l10n: "Sending a file…"),
                    store.uploading.isEmpty)
        }
        // The Mac's words over the limit, and one number format near it, as the chat's composer says them.
        if count > most {
            return (String(l10n: "Use no more than \(most.formatted()) characters."), true)
        }
        if count > most - 500 {
            return (String(l10n: "\(count.formatted()) of \(most.formatted()) characters"), false)
        }
        // No line while the hub does not answer: the line over the page says it once (D-2).
        return nil
    }
}
