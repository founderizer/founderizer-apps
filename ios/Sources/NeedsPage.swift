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
    /// **His answer to each item on the page, from the frame the hub's request for it began, and when the hub took it**
    /// (the owner's yes of 11 November 2026 to its moving picture: "Yes, build it"): the item shows it, takes no more
    /// touch, and folds 0.78 s after the hub took it at the earliest, so that he sees his answer taken: an option that
    /// he pressed with a check that draws itself in the place of the ring that turned while it went (F10, B1; his "Yes,
    /// as drawn" of 22 November 2026), and one soft tap. **Words that he wrote have no check** (the owner, 14 November
    /// 2026: "when I typed a custom answer instead of choosign one of the suggested ones, do not show the CHECK
    /// animation because it is misleading"): their ring goes. The store keeps an answer that the hub took until a new
    /// request for its item or a change of generation, and one on its way while a send carries it; the page keeps its
    /// copy until the fold ends. **Before that, his answer waits 5 seconds on its folded card,
    /// with Undo** (`MobileStore.hold`; his "Yes, Undo there too" of 21 November 2026): the item stays.
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
                let going = goingAnswers
                let openIDs = Set(store.openNeeds.map(\.id))
                ForEach(Self.drawn(shown ?? store.openNeeds, open: store.openNeeds)) { need in
                    let folds = folding.contains(need.id)
                    let answer = Self.kept(given[need.id], of: need.id, going: going, open: openIDs)
                    // **An answered item folds away** (items 76 and 95): its height goes to nothing over 250 ms, easing
                    // out, its content clipped to what is left of it and fading, and the items under it rise into the
                    // room it frees, never over it.
                    Fold(shown: folds ? 0 : 1) {
                        NeedCard(store: store, need: need, header: true, given: answer)
                            .padding(.bottom, NeedCard.gap)
                    }
                    .clipped()
                    .opacity(folds ? 0 : 1)
                    .allowsHitTesting(!folds && answer == nil)
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
        .onChange(of: goingAnswers, initial: true) { _, going in
            for (id, answer) in going where given[id] == nil { given[id] = answer }
            // The hub refused it, and the item waits again: it is his to answer once more.
            for id in given.keys where going[id] == nil && store.openNeeds.contains(where: { $0.id == id }) {
                given[id] = nil
                givenAt[id] = nil
            }
        }
        // **The hub took his answer**: the time from which it stands, and one soft tap with its check. Not for an
        // answer that was taken when the page opened: the first pass has no change.
        .onChange(of: takenAnswers, initial: true) { before, taken in
            for id in taken where givenAt[id] == nil {
                givenAt[id] = .now
                if before != taken { taps += 1 }
            }
        }
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
        // (an answer that the hub took in the same moment as the read that folds its item stands from now)
        for id in goneIDs where givenAt[id] == nil && store.answersTaken[id] != nil {
            givenAt[id] = .now
            taps += 1
        }
        // An item that he answered a moment ago stays until the hub's taking of its answer has stood for 0.78 s.
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

    /// **His answer that an item draws: the store's while it has one, the page's copy while the item folds away, and
    /// none on an item that the hub still lists as open with no answer of his on its way or taken** (`given`). The copy
    /// follows the store's answers by an onChange call, and SwiftUI drops a call of one onChange that comes after others
    /// in one frame (`NeedCard.followAnswer`): a copy whose removal was dropped would hold the open card folded with its
    /// check, and it would take no touch.
    nonisolated static func kept(_ copy: MobileStore.GivenAnswer?, of id: Int, going: [Int: MobileStore.GivenAnswer],
                                 open: Set<Int>) -> MobileStore.GivenAnswer? {
        if let answer = going[id] { return answer }
        return open.contains(id) ? nil : copy
    }

    /// His answers that the store has on their way or taken, for the items on the page.
    private var goingAnswers: [Int: MobileStore.GivenAnswer] {
        Dictionary((shown ?? store.openNeeds).compactMap { need in store.givenAnswer(to: need.id).map { (need.id, $0) } }) { first, _ in first }
    }

    /// The items on the page whose answer the hub took.
    private var takenAnswers: Set<Int> {
        Set((shown ?? store.openNeeds).map(\.id).filter { store.answersTaken[$0] != nil })
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
    /// How far his answer has folded the open card (`goingNow`), and the last answer that folded it, which its line
    /// keeps while Undo opens the card again.
    @State private var answerShare: CGFloat = 0
    @State private var going: Going?
    /// The open card took his message under it (`OwnerNeed.clarify`): its link stays while it folds, since the hub's
    /// answered item takes none, and the rows under the question would lose its height in the fold's first frame.
    @State private var tookTalk = false
    /// The field of Needs clarification stands on this card (`NeedClarify.stands`): the card keeps it, so the field
    /// stays while the card folds, where the rows under the question are drawn again (review B of 20 November 2026).
    @State private var clarifyStands = false
    /// **Details is open** (the owner's "Yes, as drawn" of 22 November 2026 to pictures 2 and 3 of F9): the reason
    /// whole, and under the link the task and the long part. The card keeps what he opened while it stands.
    @State private var detailsOpen = false
    /// The reason is longer than four and a half of its lines, so the front shows its first three with "…".
    @State private var reasonCut = false
    /// On Needs you, the card was opened from its rest (`atRest`), or it stood open (`standsOpen`); it stays open while
    /// it stands.
    @State private var expanded = false
    /// **The options that he ticked, on a card whose options combine**: the card keeps them, so the card at rest and the
    /// open card show the same ticks and the same Send (the readers of 22 November 2026: a press that opened the card
    /// took his ticks away, since each form drew its own rows).
    @State private var ticked: Set<Int> = []
    /// VoiceOver goes on at the open card's title, which takes the place of the title that he pressed.
    @AccessibilityFocusState private var titleFocused: Bool
    /// His answer folds the card from the form that it had when the fold began, at rest or open (`folding`), until it
    /// opens again; nil while no answer folds it.
    @State private var foldFrom: Bool?
    /// One more at the end of each fold of his answer: the fold looks at the state once more then (`followAnswer`).
    /// **Not tested**: the frame test (`aCardOpensAgainAfterChangesInOneFrame`) changes whether an answer stands only
    /// once in its frame, so it passes without this look; the case is two such changes in one frame.
    @State private var foldChecks = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        let goes = goingNow
        VStack(alignment: .leading, spacing: 0) {
            if header { NeedHead(store: store, need: need, took: answerTaken) }
            Group {
                // **An answered card folds to its two lines frame by frame, over 250 ms, easing out** (fix round 3, item
                // 40): the open rows' height goes as the two lines' comes, so the chat's height and its place change in
                // each frame. It changed in one step, and the conversation dropped 348 points in one frame. **His answer
                // folds the open card in the same way, from his press** (`goingNow`), and Undo opens it again.
                if (wasOpen && !need.isOpen) || (need.isOpen && (goes != nil || answerShare > 0)) {
                    folding(need.isOpen ? answerShare : max(foldShare, answerShare), rests: foldFrom ?? rests)
                // An answered card pads itself, inside its button, so its whole card takes the tap (fix round 3, HIG).
                } else if need.isOpen {
                    // on Needs you each card stands alone at rest, and a press opens it (`atRest`)
                    if rests { atRest } else { open.padding(16) }
                } else {
                    NeedAnswered(store: store, need: need, files: answerFiles, spoken: spoken, onPage: header)
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
            } else if let task = need.task, let state = store.pauseState(of: task) {
                // his Pause of the answered card's task that did not go: its own line, where an open card's lines stand
                NeedPauseLine(store: store, need: need, task: task, state: state)
                    .padding(.horizontal, 16)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-need-\(need.id)")
        .onAppear {
            wasOpen = need.isOpen
            tookTalk = need.isOpen && need.clarify == true
            going = goes
            answerShare = need.isOpen && goes != nil ? 1 : 0
        }
        .onChange(of: need.isOpen) { was, now in
            if now {
                wasOpen = true; foldShare = 0; tookTalk = need.clarify == true
                answerShare = goingNow != nil ? 1 : 0
                return
            }
            guard was else { return }
            withAnimation(.easeOut(duration: 0.25)) { foldShare = 1 } completion: { wasOpen = false; answerShare = 0 }
        }
        .onChange(of: need.clarify) { _, now in if need.isOpen { tookTalk = now == true } }
        // a card that stands open once stays open while it stands; not while his answer waits or goes, whose words in
        // the box are no reason to open it (`standsOpen`)
        .onChange(of: header && need.isOpen && goes == nil && standsOpen, initial: true) { _, now in
            if now { expanded = true }
        }
        // the line of his answer, which the fold keeps while the card opens again
        .onChange(of: goes) { _, now in if let now { going = now } }
        // his answer comes or goes: the open card folds, or opens again, over the same 250 ms (`followAnswer`)
        .onChange(of: goes != nil) { _, _ in followAnswer() }
        .onChange(of: foldChecks) { _, _ in followAnswer() }
    }

    /// **The open card's fold follows whether an answer of his stands now** (`goingNow`), over 250 ms: the fold starts
    /// from the form that the card had; the way back opens to the form that it has now (after "Not sent" or a refusal
    /// it stands open), so nothing changes in the frame where the way back ends. **SwiftUI drops a call of one onChange
    /// that comes after others in one frame** (its log: "action tried to update multiple times per frame"): under load
    /// the end of his wait, the send, the receipt and the reading after it changed his answer in one frame, and the card
    /// that the hub still lists as open stood folded with no options (the ship runs of 24 and 25 November 2026). So the
    /// fold follows a change of whether an answer stands, which changed once there; it reads the state as it is now; and
    /// the end of each fold looks once more (`foldChecks`), so a change whose call was dropped is followed. **Each look
    /// takes the line of the answer that stands now** (`going`): a dropped call of the line's own onChange left the
    /// line of an earlier answer, which the 250 ms fade showed as the card opened. A drop in the frame that opens the
    /// card can still show it, since no answer stands then.
    private func followAnswer() {
        if let now = goingNow, now != going { going = now }
        let answered = goingNow != nil
        guard need.isOpen, (answerShare > 0) != answered else { return }
        foldFrom = rests
        withAnimation(.easeOut(duration: 0.25)) { answerShare = answered ? 1 : 0 } completion: {
            if goingNow == nil { foldFrom = nil }
            foldChecks += 1
        }
    }

    /// **His answer as the folded open card shows it**: the answer, whether it waits with Undo, and its mark.
    struct Going: Equatable {
        let answer: MobileStore.GivenAnswer
        /// Nothing of it left the phone: Undo stands at the line's end.
        let waits: Bool
        let mark: Mark

        /// **The mark in the check's place** (F10, B1: the owner's "Yes, as drawn" of 22 November 2026 to "a ring that
        /// turns, then the check, with no word"): none while it waits its 5 seconds with Undo; the ring while it is on
        /// its way, from the end of that wait to the hub's receipt, also while it waits for the hub or for this phone's
        /// key; then the check that draws itself, for an option or ticked options (his picture of 11 November 2026),
        /// and none for words that he wrote, whose ring goes (14 November 2026). "Sending…" stood under the card.
        enum Mark: Equatable { case none, ring, check }

        /// The check stands on the line: the hub took the answer.
        var checks: Bool { mark == .check }
    }

    /// **His answer folds the open card, from his press until the hub's reading folds it as an answered card** (his "Yes,
    /// 5 seconds (Recommended)" of 21 November 2026: "The folded card shows Undo at the end of its answer line... After
    /// that the card shows its mark as now"; the Mac's `NeedRequestCard.onItsWay`): while it waits with Undo, while it
    /// waits for the hub and this phone's key, and on its way. An answer that did not go opens the card again, with its
    /// line under it ("Not sent", Try again). The key card keeps its own form.
    private var goingNow: Going? { Self.going(need, store: store, given: answerGiven) }

    /// **Undo stays while nothing left the phone, and the check comes only with the hub's receipt** (the owner, 22
    /// November 2026: "cards on the phone are left with Sending... and never complete", and his "Yes, as drawn" to the
    /// ring of F10, B1): an answer that waits with Undo has no mark; a press that waits for the hub or for this phone's
    /// key after that keeps Undo and has the ring; a request on its way has the ring and no Undo, and so does one that
    /// goes again by itself (`MobileStore.answerGoes`); the answer that the hub took has its check. A press that waited
    /// showed the check and no Undo, so the card read "done" while nothing was saved or sent, and he could not take it
    /// back; and the check of a request on its way said "done" before the hub had it.
    static func going(_ need: OwnerNeed, store: MobileStore, given: MobileStore.GivenAnswer?) -> Going? {
        guard need.isOpen, !need.asksForSecret else { return nil }
        if let held = store.heldAnswer(to: need.id) { return Going(answer: held.shown, waits: true, mark: .none) }
        if let given {
            let mark: Going.Mark = store.answerGoes(to: need.id) ? .ring : given.words == nil ? .check : .none
            return Going(answer: given, waits: false, mark: mark)
        }
        return store.waitingPresses[need.id].map { Going(answer: MobileStore.GivenAnswer($0), waits: true, mark: .ring) }
    }

    /// **The hub took his answer** (F10, B1): the check stands, and the agent's mark jumps once.
    private var answerTaken: Bool { answerGiven != nil && !store.answerGoes(to: need.id) }

    /// **The card takes his message under it** (Needs clarification, owner feature `need_clarify`): on a hub that names
    /// the feature, where the hub says so of the open item, and while the card folds where it said so when it was open.
    private var takesTalk: Bool { store.supportsTalk && (need.isOpen ? need.clarify == true : tookTalk) }

    private var open: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: Self.drawnTitle(need.shownTitle)).font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(Text(verbatim: need.shownTitle))
                .accessibilityFocused($titleFocused)
                .accessibilityIdentifier("need-title-\(need.id)")
            openRowsPlaced
        }
    }

    // MARK: The card at rest on Needs you

    /// **Each card alone at rest on Needs you** (the owner's "Form A: each card alone" of 22 November 2026, to the
    /// pictures of a simpler page; his "It has to be simpler"): its question with `chevron.down` at the end of its first
    /// line, one line of its reason, and the one thing that he presses here: its options, the words that its agent
    /// recommends or its pictures, or a key request's line. A press anywhere else on the card opens it as the single
    /// card of pictures 2 and 3 (`open`), with the reason, Details, his talk, Your answer and Needs clarification. In a
    /// chat the card is always open.
    private var atRest: some View {
        VStack(alignment: .leading, spacing: 0) {
            restTitle(chevron: 1).opensOnTap(boxAtRest) { openFromRest() }
            restRows
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        // the whole card takes the press, except its own controls, which take theirs; a card whose one control is its
        // answer's box opens from its question and its reason only, so a touch of the field never opens it
        .opensOnTap(!boxAtRest) { openFromRest() }
    }

    /// The question of the card at rest, with `chevron.down` at the end of its first line: also the first frame of its
    /// fold, whose chevron fades as the fold goes (`folding`).
    private func restTitle(chevron: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: Self.drawnTitle(need.shownTitle)).font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(Text(verbatim: need.shownTitle))
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Shows the whole request")
                .accessibilityAction { openFromRest() }
                .accessibilityIdentifier("need-rest-\(need.id)")
            Spacer(minLength: 0)
            Image(systemName: "chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(Brand.muted)
                .opacity(chevron)
                .accessibilityHidden(true)
        }
    }

    /// What stands under the question at rest: one line of the reason, 6 points under the question, and 12 points
    /// under it what he presses here.
    private var restRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            if hasReason {
                Text(NeedReason.inline(need.why)).font(.subheadline).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opensOnTap(boxAtRest) { openFromRest() }
                    .accessibilityIdentifier("need-reason-\(need.id)")
            }
            restControls.padding(.top, 6)
        }
        .padding(.top, 6)
    }

    /// **The card stands at rest**: on Needs you, until a press opens it, and where it does not stand open.
    private var rests: Bool { header && !expanded && !standsOpen }

    /// **The card stands open on Needs you, with no press** (the readers of 22 November 2026): where the card at rest
    /// would hide what he must read or what he left on it — the door card's script behind Script (his picture 11a), his
    /// talk with the agent under the card, his words or files in its answer's box, his message under the card in its
    /// field or on its way, a request of the card that did not go ("Not sent", or the hub's refusal). Once open, it
    /// stays open. **Not for his words in the box while his answer waits or goes** (the second reading): a press on
    /// the agent's recommended words puts them there, and the card at rest stood open for good, also after Undo. Not
    /// for the words of a card whose box stands at rest (`boxAtRest`): they show there.
    private var standsOpen: Bool {
        NeedScript.text(need) != nil
            || !store.talk(of: need).isEmpty
            || (!boxAtRest && goingNow == nil && (!store.answerDraft(for: need.id).isEmpty
                || !store.stagedFiles(for: MobileStore.stageKey(need: need.id)).isEmpty))
            || !store.clarifyDraft(for: need.id).isEmpty || clarifyStands || store.clarifyKept(for: need.id) != nil
            || store.waitsUnsent(for: need.id) || refusedHere
    }

    /// **A card with nothing to press at rest has its answer's box there** (the second reading, after his Form A: "one
    /// line of reason and the one thing that you press or type"): no option, no recommended words, no picture, and no
    /// key request's line. A press of its question or its reason opens it as the others.
    private var boxAtRest: Bool {
        !need.asksForSecret && NeedPictures.drawn(need, features: store.features) == nil && need.phoneRows.isEmpty
            && NeedOptions.recommendedWords(need, store: store) == nil
    }

    /// A request of this card, of this hub and generation, that the hub refused: its line says why under the card.
    private var refusedHere: Bool {
        guard let pending = store.pending, pending.refusal != nil else { return false }
        return (pending.needID == need.id || pending.talkNeed == need.id) && pending.hub == store.hub
            && pending.database == store.snapshot?.db
    }

    /// The one thing that he presses or types on the card at rest.
    @ViewBuilder private var restControls: some View {
        if need.asksForSecret {
            NeedSecretNote(need: need)
        } else if let pictures = NeedPictures.drawn(need, features: store.features) {
            NeedPictures(store: store, need: need, pictures: pictures, ticked: $ticked, given: answerGiven)
        } else if !need.phoneRows.isEmpty || NeedOptions.recommendedWords(need, store: store) != nil {
            NeedOptions(store: store, need: need, ticked: $ticked, given: answerGiven)
        } else {
            // nothing to press: the answer's box is the one thing that he types (`boxAtRest`)
            NeedAnswerBox(store: store, need: need, sent: answerGiven?.words)
        }
    }

    /// The open card's rows in their place under its question: the reason 6 points under it, as a subtitle, anything
    /// else 12.
    private var openRowsPlaced: some View { openRows.padding(.top, hasReason ? 6 : 12) }

    /// What goes while his answer folds the card: the rows of the card as it stood, at rest or open, in their place.
    @ViewBuilder private func foldingRows(rests: Bool) -> some View {
        if rests { restRows } else { openRowsPlaced }
    }

    private func openFromRest() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { expanded = true }
        // VoiceOver goes on at the open card's title, once it stands
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            titleFocused = true
        }
    }

    // MARK: The front and Details

    /// **The title as it is drawn: a long name of a key breaks after an underscore, with no hyphen** (pictures 1 and 7
    /// of F9 broke a name as "DOOR_EXAMPLE_PROVI-" over "DER_KEY" does): a name of capitals and digits joined by
    /// underscores has no place to break, so the system cut it with a hyphen that is not part of the name, and he could
    /// read or copy the wrong name. A zero-width space after each of its underscores gives it those places. For drawing only: VoiceOver reads
    /// the title as it is, and no value or chip takes these spaces.
    nonisolated static func drawnTitle(_ title: String) -> String {
        guard title.contains("_") else { return title }
        return title.replacing(/[A-Z0-9]+(?:_[A-Z0-9]+)+/) { name in
            name.output.replacingOccurrences(of: "_", with: "_\u{200B}")
        }
    }

    private var hasReason: Bool { !need.why.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// **The task stands behind Details** where the agent wrote it, as on the Mac's card: never the hub's own sentence
    /// of a key request, nor the words of an item that carries its grant, whose step is Give, nor the door's card,
    /// whose words sign a call.
    private var taskBehind: Bool {
        !need.asksForSecret && need.give == nil && NeedScript.text(need) == nil
            && !need.todo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    /// The long part stands behind Details too; on the door's card it is the script, which the card shows itself.
    private var longPartBehind: Bool {
        NeedScript.text(need) == nil && !(need.details ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    /// The link shows only where there is more: the reason is cut, or there is a task or a long part behind it, or the
    /// door card's script.
    private var hasMore: Bool { reasonCut || taskBehind || longPartBehind || NeedScript.text(need) != nil }

    /// What Details opens, under the link, 12 points apart and with no labels, in the reason's type. **On the door's
    /// card of a run the link is Script, and it opens the script in its well** (the owner's "Yes, as drawn" to picture
    /// 11 of F9, "Behind a Script link, as on the Mac"): the phone signs Run it once for the hash of the script that the
    /// card holds (`DeviceSigningKey.approval`), drawn or not, as the Mac's card has it behind the same link.
    @ViewBuilder private var behindDetails: some View {
        if NeedScript.text(need) != nil { NeedScript(need: need) }
        if taskBehind { NeedPlainWords(words: need.todo).accessibilityIdentifier("need-task-\(need.id)") }
        if longPartBehind {
            NeedPlainWords(words: need.details ?? "").accessibilityIdentifier("need-long-\(need.id)")
        }
    }

    /// His answer to this request, from the hub's request for it until the item folds.
    private var answerGiven: MobileStore.GivenAnswer? { given ?? store.givenAnswer(to: need.id) }

    /// **The answered card while it folds: its question once, and under it the open rows going as the answer's line
    /// comes** (fix round 3d), `share` 0 open and 1 folded. The open card and the two lines stood one over the other,
    /// so the question showed twice for about 130 ms. The height goes from the open card's to the two lines', 16
    /// points inside the card's edge as both are, so nothing jumps where the fold begins or ends.
    private func folding(_ share: CGFloat, rests: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // The question: the open card's words, whose lines under the first go with the rows, and the folded card's
            // one line coming over the first, with its "…" where the words do not fit. The lines under the first fade
            // in 0.1 s, faster than the 0.25 s of the row that cuts them, so it cuts only words that have nearly gone.
            // **Its first frame is the card that it folds** (the readers of 22 November 2026: the fold jumped): at rest,
            // the question with its chevron, which fades, and the rows of the card at rest in their place; open, the
            // open card's question and rows.
            CrossFold(shown: share) {
                Group {
                    if rests {
                        restTitle(chevron: 1 - share)
                    } else {
                        Text(verbatim: Self.drawnTitle(need.shownTitle)).font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                    .mask(alignment: .top) {
                        ZStack(alignment: .top) {
                            Color.black.opacity(1 - share).animation(.easeOut(duration: 0.1), value: share)
                            NeedAnswered.titleLine(need).hidden().frame(maxWidth: .infinity).background(Color.black)
                        }
                    }
                    .accessibilityHidden(true)
                // the folded card's title row: its chevron comes with the answered card's fold, never on the folded
                // line of an answer that goes (`NeedAnswered.titleRow`)
                NeedAnswered.titleRow(need, chevron: need.isOpen ? 0 : foldShare).opacity(share)
            }
            .clipped()
            // Under it: the open rows go, and the answer's line comes in its place under the question. Where his words
            // are his own message in the chat, no line comes, and the rows go to nothing.
            CrossFold(shown: share) {
                foldingRows(rests: rests)
                    .opacity(1 - share).allowsHitTesting(false).accessibilityHidden(true)
                if need.isOpen, let line = goingNow ?? going {
                    goingLine(line).padding(.top, 4).opacity(share)
                } else if NeedAnswered.saysAnswer(need, spoken: spoken) {
                    NeedAnswered.answerLine(need, mark: NeedAnswered.mark(of: need, store: store))
                        .padding(.top, 4).opacity(share)
                } else {
                    Color.clear.frame(height: 0)
                }
            }
            .clipped()
        }
        .padding(16)
    }

    /// **His answer on the open card that it folds** (`goingNow`): while it waits, his answer with Undo at the end of its
    /// line, and no check, no words beside Undo and no count (his "Yes, 5 seconds": "the answer line "Tide" with "Undo"
    /// at its end, and no check mark"); on its way, the ring in the check's place (F10, B1), with Undo while it waits
    /// for the hub; once the hub took it, an option that he pressed with its check, which draws itself, and his words
    /// with none (the owner, 14 November 2026), until the hub's reading draws what came of it.
    private func goingLine(_ line: Going) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            switch line.mark {
            case .ring: SendingRing().accessibilityIdentifier("need-ring-\(need.id)")
            case .check: DrawnMark(symbol: "checkmark").font(.caption.weight(.semibold))
            case .none: EmptyView()
            }
            Text(verbatim: Self.words(of: line.answer, in: need)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if line.waits {
                TextAction(title: String(l10n: "Undo"), font: .caption) { store.undo(needID: need.id) }
                    .accessibilityIdentifier("need-undo-\(need.id)")
            }
        }
        .font(.caption).foregroundStyle(Brand.muted)
    }

    /// The words of his answer on its line: the option's own words, the ticked ones joined as the hub joins them, or
    /// his words; "Answered" for an answer of files alone.
    nonisolated static func words(of answer: MobileStore.GivenAnswer, in need: OwnerNeed) -> String {
        let words = switch answer {
        case .option(let index): need.choices.indices.contains(index) ? need.choices[index] : ""
        case .options(let indexes): indexes.filter(need.choices.indices.contains).map { need.choices[$0] }.joined(separator: "; ")
        case .words(let text): text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return words.isEmpty ? String(l10n: "Answered") : words
    }

    /// **What the open card holds under its question** (the owner's "Yes, as drawn" of 22 November 2026 to pictures 2
    /// and 3 of F9: "cards on the phone have TOO much information at once"): the reason, with no label and no line, at
    /// most four lines, else three with "…"; the link Details where there is more, and what it opens; then, as before,
    /// his talk and what he can press here. No dividing line and no label: the room between them parts them.
    private var openRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            if hasReason {
                NeedReason(words: need.why, whole: detailsOpen, cut: $reasonCut)
                    .accessibilityIdentifier("need-reason-\(need.id)")
            }
            if hasMore {
                NeedDetailsLink(word: NeedScript.text(need) != nil ? String(l10n: "Script") : String(l10n: "Details"),
                                open: $detailsOpen, reduceMotion: reduceMotion)
                    .accessibilityIdentifier("need-details-\(need.id)")
            }
            if detailsOpen { behindDetails }
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
                // by itself beside the answer that he gave. owner feature need_pictures: on a hub that names it, an
                // item with one picture for each option draws them over their words; any other item, the rows of before
                if let pictures = NeedPictures.drawn(need, features: store.features) {
                    NeedPictures(store: store, need: need, pictures: pictures, ticked: $ticked, given: answerGiven)
                } else if !need.phoneRows.isEmpty || NeedOptions.recommendedWords(need, store: store) != nil {
                    NeedOptions(store: store, need: need, ticked: $ticked, given: answerGiven)
                }
                NeedAnswerBox(store: store, need: need, sent: answerGiven?.words)
                    .opacity(answerGiven.map { $0.words == nil } == true ? NeedOptions.dimmed : 1)
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

private extension View {
    /// A press of this part opens the card at rest (`NeedCard.atRest`), where `opens`; else the part takes no press of
    /// its own, so the press reaches what is under it.
    @ViewBuilder func opensOnTap(_ opens: Bool, _ open: @escaping () -> Void) -> some View {
        if opens { contentShape(Rectangle()).onTapGesture(perform: open) } else { self }
    }
}

/// **The reason on the card's front**: no label and no line, in the subheadline type and the text's colour. Whole when
/// it fits four and a half of its lines, drawn from its Markdown with its copy chips; else its first three lines with
/// "…", as one text (code as code, no chip), as the Mac folds a long reason; and whole again when Details opens.
struct NeedReason: View {
    let words: String
    let whole: Bool
    @Binding var cut: Bool

    /// The reason as one text, for its first three lines: its inline Markdown, its line breaks as spaces.
    static func inline(_ words: String) -> AttributedString {
        let flat = words.replacingOccurrences(of: "\n", with: " ")
        return (try? AttributedString(markdown: flat, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(flat)
    }

    var body: some View {
        Group {
            if whole || !cut {
                NeedPlainWords(words: words)
            } else {
                Text(Self.inline(words))
                    .font(.subheadline)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // the whole reason's height against one of its lines, measured where nobody sees it
        .background(alignment: .topLeading) { Measure(words: words, cut: $cut) }
    }

    private struct Measure: View {
        let words: String
        @Binding var cut: Bool
        @State private var height: CGFloat = 0
        @State private var line: CGFloat = 0

        var body: some View {
            ZStack(alignment: .topLeading) {
                Text(NeedReason.inline(words)).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0; decide() }
                Text(verbatim: "A").font(.subheadline)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { line = $0; decide() }
            }
            .hidden()
            .accessibilityHidden(true)
        }

        private func decide() {
            guard line > 0, height > 0 else { return }
            let over = height > line * 4.5
            if over != cut { cut = over }
        }
    }
}

/// The agent's words on the front and behind Details: drawn from their Markdown, with their copy chips, in the
/// subheadline type of the reason, with no label, so the reason does not change its size when it opens.
struct NeedPlainWords: View {
    let words: String

    var body: some View {
        ReplyText(text: words, values: true)
            .font(.subheadline)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .wholePoints()
    }
}

/// **Details**, or Script on the door's card: a line high, at the card's leading edge, in the accent colour, with
/// `chevron.down` while closed and `chevron.up` while open (the owner, 20 November 2026: what a click opens in place
/// shows a sign), and a touch of 44 points; a second tap folds it. Under Reduce Motion the card changes in one step.
struct NeedDetailsLink: View {
    let word: String
    @Binding var open: Bool
    var reduceMotion = false

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { open.toggle() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(word)
                Image(systemName: open ? "chevron.up" : "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .accessibilityHidden(true)
            }
            // a touch of 44 points or more at every text size, as `TextAction` has, with no change to what is drawn
            .padding(.vertical, 15).padding(.horizontal, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -15).padding(.horizontal, -7)
        .font(.callout.weight(.medium))
        .foregroundStyle(Brand.accent)
        .accessibilityValue(open ? Text("Expanded") : Text("Collapsed"))
    }
}

extension MobileStore {
    /// His answer to a request, as an item shows it while it goes: the option that he pressed, the options that he
    /// ticked (a card of pictures whose options combine, `NeedPictures`), or his words.
    enum GivenAnswer: Equatable, Sendable {
        case option(Int), options([Int]), words(String)

        /// A press that waits, or that waits with Undo, as the card shows it meanwhile.
        init(_ press: WaitingPress) {
            switch press {
            case .option(let index): self = .option(index)
            case .ticked(let indexes): self = .options(indexes)
            case .words(let words, _): self = .words(words)
            }
        }

        var option: Int? { if case .option(let index) = self { index } else { nil } }
        var options: [Int]? { if case .options(let indexes) = self { indexes } else { nil } }
        var words: String? { if case .words(let text) = self { text } else { nil } }
    }

    /// His answer to `need` that the hub's request carries now, or that the hub took and the reading does not have
    /// yet. A press that waits for the hub is no answer yet: its card has the ring and Undo. **An answer that did not
    /// go is none either** (review of 11 November 2026): its item says "Not sent" with Try again, which he must be able
    /// to press, so only a request of this hub and generation that goes now counts (`goes`).
    func givenAnswer(to need: Int) -> GivenAnswer? {
        let going = pending.flatMap { answerGoes($0, to: need) ? $0 : nil }
        guard let request = going ?? answersTaken[need]?.request else { return nil }
        return request.choice.map(GivenAnswer.option) ?? request.choices.map(GivenAnswer.options) ?? .words(request.text)
    }

    /// **His answer to `need` is on its way, and the hub has not taken it** (F10, B1: its card has the ring): its
    /// request of this hub and generation goes now, or goes again by itself after the next read that worked
    /// (`onItsWay`, F10 C1).
    func answerGoes(to need: Int) -> Bool { pending.map { answerGoes($0, to: need) } ?? false }

    private func answerGoes(_ request: PendingRequest, to need: Int) -> Bool {
        Self.goes(request, to: need, of: hub, database: snapshot?.db, sending: onItsWay(request))
    }

    /// **A waiting request is his answer on its way only while a send carries it**, or while it goes again by itself
    /// (F10, C1). One that waits with no send is none: an error stopped it, or the app started with it in the Outbox,
    /// and the app sends a kept request only at his Try again. The rule counted every request that no error had
    /// stopped, and after a start no error is recorded: the item on Needs you counted as answered and took no touch,
    /// while its line said "Not sent" with Try again (found on 20 November 2026 by the review of the key card's Needs
    /// clarification).
    static func goes(_ request: PendingRequest, to need: Int, of hub: URL, database: String?, sending: Bool) -> Bool {
        sending && request.needID == need && request.refusal == nil && request.hub == hub && request.database == database
    }
}

/// **The ring of an answer on its way** (F10, B1: the owner's "Yes, as drawn" of 22 November 2026 to "a ring that turns,
/// then the check, with no word"; pictures `f10-b1-*`): a third of a circle in the muted colour, with a line of about
/// 1.4 points, in the check's place on the answer line and at its size, 11 points across at the default text size and
/// growing with the caption type. Core Animation turns it once every 0.9 s, as the Mac's ring of a key save
/// (`KeySaveMark`): a motion that goes on never makes the page draw again. Under Reduce Motion it is the whole circle,
/// still. VoiceOver reads it as "Sending". The check that draws itself takes its place when the hub took the answer.
struct SendingRing: View {
    @ScaledMetric(relativeTo: .caption) private var side: CGFloat = 11
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // the check's own box keeps the line's height and the words' place
        Image(systemName: "checkmark").font(.caption.weight(.semibold)).hidden()
            .overlay { SendingRingLayer(turns: !reduceMotion).frame(width: side, height: side) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Sending"))
    }
}

private struct SendingRingLayer: UIViewRepresentable {
    let turns: Bool

    func makeUIView(context: Context) -> SendingRingView { SendingRingView() }
    func updateUIView(_ view: SendingRingView, context: Context) { view.turns = turns }
}

/// The ring's layer: a third of a circle, round at its ends, turning with no end; the whole circle, still, when it does
/// not turn.
final class SendingRingView: UIView {
    private let ring = CAShapeLayer()
    var turns = true {
        didSet { if turns != oldValue { setNeedsLayout() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        layer.addSublayer(ring)
        ring.fillColor = nil
        ring.lineCap = .round
        // drawn again for the phone's appearance and its contrast
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            (view: SendingRingView, _: UITraitCollection) in view.setNeedsLayout()
        }
    }

    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // A layer that left the window lost its motion.
        if window != nil { setNeedsLayout() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let width = max(1.4, bounds.width * 0.13)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        ring.contentsScale = max(traitCollection.displayScale, 1)
        ring.lineWidth = width
        ring.path = UIBezierPath(ovalIn: bounds.insetBy(dx: width / 2, dy: width / 2)).cgPath
        ring.strokeEnd = turns ? 1.0 / 3.0 : 1
        ring.strokeColor = (UIColor(named: "BrandMuted") ?? .secondaryLabel).resolvedColor(with: traitCollection).cgColor
        CATransaction.commit()
        if turns {
            guard ring.animation(forKey: "turn") == nil else { return }
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = Double.pi * 2
            turn.duration = 0.9
            turn.repeatCount = .infinity
            turn.isRemovedOnCompletion = false
            ring.add(turn, forKey: "turn")
        } else {
            ring.removeAnimation(forKey: "turn")
        }
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
/// always, and stands where he answered it, since 19 November 2026: `ChatRequestPlaces.Answered`.) **The check says what
/// came of his answer** (owner feature `need_marks`; `AnsweredMarkView`): the check, the green mark of work, or the red
/// mark of work that failed, whose words VoiceOver reads as the folded card's value.
private struct NeedAnswered: View {
    let store: MobileStore
    let need: OwnerNeed
    let files: [MessageAttachment]
    /// His answer stands in the chat as his own message: the folded card does not say it a second time.
    var spoken = false
    /// The card is on Needs you: a task that its mark opens opens in Tasks (`open`).
    var onPage = false
    @State private var expanded = false

    private var answer: String { need.answer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    /// What he answered, in the folded card's second line: his words or the option he pressed.
    private var answerWords: String { Self.words(of: need) }
    static func words(of need: OwnerNeed) -> String {
        // owner feature need_run: a press of Run on the Mac, in this phone's words: "Ran on <Mac>"
        if ran(need) {
            let place = need.run_on == NeedRun.ownMac || need.run_on == nil ? String(l10n: "your Mac") : need.run_on!
            return String(l10n: "Ran on \(place)")
        }
        let answer = need.answer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return answer.isEmpty ? String(l10n: "Answered") : answer
    }

    /// The folded card's first line: the question on one line. Its fold draws the same line (`NeedCard`).
    static func titleLine(_ need: OwnerNeed) -> some View {
        Text(verbatim: NeedCard.drawnTitle(need.shownTitle)).font(.headline).lineLimit(1)
            .accessibilityLabel(Text(verbatim: need.shownTitle))
    }

    /// The folded card's first line with `chevron.down` at its end, which the fold draws too, the chevron coming as the
    /// fold goes (`chevron` 0 to 1), so the title's "…" does not move and the chevron does not come in one frame.
    static func titleRow(_ need: OwnerNeed, chevron: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            titleLine(need)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(Brand.muted)
                .opacity(chevron)
                .accessibilityHidden(true)
        }
    }

    /// The folded card has its second line: not where his own words stand in the chat as his message.
    static func saysAnswer(_ need: OwnerNeed, spoken: Bool) -> Bool { !(need.answeredInWords && spoken) }

    /// His answer is a press of Run on the Mac (owner feature `need_run`).
    static func ran(_ need: OwnerNeed) -> Bool { !need.isOpen && need.run_command != nil && need.run_status != nil }

    /// **What came of his answer, in the check's place** (owner feature `need_marks`; `AnsweredMarkView`), or nil where
    /// the line keeps what it drew before, as the Mac's folded card holds the mark back: words that he wrote (no check),
    /// a press of Run (its check or its cross), a request that a saved key answered (its check), and an answer of his
    /// on its way (the plain check).
    static func mark(of need: OwnerNeed, store: MobileStore) -> AnsweredMark? {
        guard !need.answeredInWords, !ran(need), !need.answeredWithKey, store.givenAnswer(to: need.id) == nil else {
            return nil
        }
        return store.answeredMark(of: need)
    }

    /// The folded card's second line: what he answered, an option that he pressed with a check ("✓ Correos"), or the
    /// mark of what came of it (`mark`), and words that he wrote with none. **`opens`: a press of the mark opens its
    /// task** (`MobileStore.taskOpened`); **`pause`: the task's Pause at the end of the line** (`MobileStore.pausable`).
    static func answerLine(_ need: OwnerNeed, mark: AnsweredMark?, opens: (() -> Void)? = nil,
                           pause: (() -> Void)? = nil, pauseGoes: Bool = true) -> some View {
        HStack(spacing: 5) {
            // a cross for a command that he ran on the Mac and that ended with another exit status than 0
            if !need.answeredInWords {
                let drawn = Group {
                    if let mark { AnsweredMarkView(mark: mark) }
                    else { Image(systemName: (need.run_status ?? 0) == 0 ? "checkmark" : "xmark") }
                }
                .font(.caption.weight(.semibold))
                .accessibilityHidden(true)
                if let opens {
                    LinePress(action: opens, leading: true) { drawn }
                        .accessibilityIdentifier("need-mark-opens-\(need.id)")
                } else {
                    drawn
                }
            }
            Text(verbatim: words(of: need)).lineLimit(1)
            if let pause {
                Spacer(minLength: 8)
                // the task panel's Pause, in the colour of the words, at the size of the line, so the card keeps its
                // height when it comes and goes. **Gray while it cannot go, and its press then does nothing**: a
                // disabled button lets the touch through to the card's own tap, which opened the whole request (the
                // review of 21 November 2026)
                LinePress(action: { if pauseGoes { pause() } }, leading: false) {
                    Image(systemName: "pause").font(.caption.weight(.semibold))
                        .foregroundStyle(pauseGoes ? Color.primary : Color.secondary)
                }
                .accessibilityLabel(Text("Pause"))
                .accessibilityIdentifier("need-pause-\(need.id)")
            }
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
                    Text(verbatim: NeedCard.drawnTitle(need.shownTitle)).font(.headline)
                        .accessibilityLabel(Text(verbatim: need.shownTitle))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    // the word stays where it stood: no picture showed him a sign in its place (the readers of 22
                    // November 2026); the folded card's `chevron.down` is his picture 12
                    Text("Answered").font(.caption).foregroundStyle(Brand.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.primary)
            .accessibilityHint("Folds the request")
            .accessibilityIdentifier("need-fold-\(need.id)")
            // the agent's words in the open card's form: no label "Why" or "What it wants", and no line over them
            if !need.why.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                NeedPlainWords(words: need.why)
            }
            if NeedOptions.asksInWords(need) {
                NeedPlainWords(words: need.todo)
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

    /// **The folded card: a tap shows the whole request; a tap on the mark of a task opens that task, and Pause pauses it
    /// while it works** (his "Both (Recommended)", "Yes, open task" and "Gray pause, as the row" of 21 November 2026; the
    /// Mac's folded card). The mark and Pause are presses of their own inside the card's tap, which takes the rest.
    private var folded: some View {
        let says = Self.saysAnswer(need, spoken: spoken)
        let mark = says ? Self.mark(of: need, store: store) : nil
        let opens = MobileStore.taskOpened(by: mark, of: need)
        // (on the line of what he answered: not on the Run card's, nor on a key's, which keep their own)
        let pauses = says && !Self.ran(need) && !need.answeredWithKey ? store.pausable(need) : nil
        return VStack(alignment: .leading, spacing: 4) {
            // **chevron.down at the end of its title line**: a tap opens the whole request (picture 12 of F9; it opened
            // with no sign, the fault that he named on the Mac on 20 November 2026)
            Self.titleRow(need, chevron: 1)
            if says {
                Self.answerLine(need, mark: mark, opens: opens.map { task in { open(task) } },
                                pause: pauses.map { task in { pause(task) } },
                                pauseGoes: pauses.map(store.canPause) ?? false)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { expanded = true }
        .foregroundStyle(Color.primary)
        .accessibilityElement(children: .ignore)
        // Words that stand in the chat as his own message are read there, not here a second time.
        .accessibilityLabel(Self.saysAnswer(need, spoken: spoken) ? Text("\(need.shownTitle), answered: \(answerWords)")
                            : Text("\(need.shownTitle), answered"))
        // owner feature need_marks: the mark's words, as the Mac's folded card gives them (the phone has no hover)
        .accessibilityValue(Text(verbatim: mark?.words ?? ""))
        .accessibilityHint("Shows the whole request")
        .accessibilityAddTraits(.isButton)
        // the press of the element that VoiceOver reads: it had none of its own, so a press there was the system's tap
        // at its middle, which a check cannot give
        .accessibilityAction { expanded = true }
        // the mark's press and Pause, which the element's one press cannot give
        .accessibilityActions {
            if let pauses, store.canPause(pauses) { Button("Pause") { pause(pauses) } }
            if let opens { Button("Open the task") { open(opens) } }
        }
        .accessibilityIdentifier("need-folded-\(need.id)")
    }

    /// **The task opens as a task opens from the page that the card is on**: in a chat over it, as a task that he asked
    /// for there opens, and from Needs you in Tasks, as a task that only he can move opens.
    private func open(_ task: Int) {
        if onPage {
            store.taskRoute = [task]
            store.tab = .tasks
        } else {
            store.chatRoute.append(.task(task))
        }
    }

    /// The task's Pause, as its panel on the Mac sends it (`MobileStore.pause(task:)`).
    private func pause(_ task: Int) {
        Task { await store.pause(task: task) }
    }
}

/// **A press inside the folded card's line**: the mark that opens its task, or Pause. Its touch reaches past the line's
/// small type, into the card's edge at its side and its foot, and 4 points over it, so it takes nothing of the title's
/// line over it; the card's own tap takes the rest.
private struct LinePress<Content: View>: View {
    let action: () -> Void
    /// The press stands at the line's start (the mark), else at its end (Pause).
    let leading: Bool
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: action) {
            content
                .padding(.leading, leading ? 14 : 10).padding(.trailing, leading ? 10 : 14)
                .padding(.top, 4).padding(.bottom, 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, leading ? -14 : -10).padding(.trailing, leading ? -10 : -14)
        .padding(.top, -4).padding(.bottom, -14)
    }
}

/// **The mark of an answered card, in the place of its check** (owner feature `need_marks`; the owner's "Yes, as drawn"
/// of 21 November 2026; the Mac's `AnsweredMarkView`): the check, the green mark of work, the red mark of work that
/// ended with no success, or the orange mark of a task that needs him, where its row is orange (his "Orange mark" of
/// the same day; `OwnerNeed.answeredMark`). They are the phone's own marks of a task's
/// states: work is the green dotted circle, which stands still here as on Tasks and on the row of what he asked for in a
/// chat (the phone has no turning mark of work, so it is the Mac's mark at rest, as under Reduce Motion), and a failure
/// is the red filled exclamation of a failed task. Its words are VoiceOver's, as the folded card's value.
///
/// **Not on Needs you** (the owner's "Yes, same marks there", 21 November 2026, for the Mac's answered step): the
/// phone's page keeps no answered step. An item that he answers there shows the check on its folded line while the
/// answer is on its way, and folds away 0.78 s after the answer went, or at once when the reading that closes it comes
/// later, so a mark could only stand there for the fold's quarter second.
struct AnsweredMarkView: View {
    let mark: AnsweredMark

    /// The look of each mark: its symbol, and the tint of a task's mark that it takes (`MobileStore.color`); nil keeps
    /// the line's own quiet colour, as the check had it.
    nonisolated static func look(of mark: AnsweredMark) -> (symbol: String, tint: FleetTask.MarkTint?) {
        switch mark {
        case .done: ("checkmark", nil)
        case .working: ("circle.dotted", .work)
        case .failed: ("exclamationmark.circle.fill", .failed)
        // the task's own mark, as its row draws it (`FleetTask.mark`, which the phone's rows draw too), in orange
        case .attention(let symbol, _): (symbol, .attention)
        // his own pause: the row's mark of it, in the line's own gray
        case .paused(let symbol, _): (symbol, nil)
        }
    }

    var body: some View {
        let look = Self.look(of: mark)
        if let tint = look.tint {
            Image(systemName: look.symbol).symbolRenderingMode(.hierarchical).foregroundStyle(MobileStore.color(tint))
        } else {
            Image(systemName: look.symbol)
        }
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
/// width of the item and at least 44 points high, in the quiet grey of what is his to press, and a press sends that
/// answer, as the ping's button for it does. The item asked him to press buttons it did not draw ("Press one, or write
/// another time."), so that line of the agent's goes where its options stand.
///
/// **They are never drawn grey for a wait** (fix round 2, item 51; the one grey row is below): a press while the hub
/// cannot take it waits and goes when it can, and the item says "Sending…" under it (`MobileStore.press`). They went
/// grey at 1.71:1 whenever the hub was slow or away or another write waited.
///
/// **An option that only a Mac or a PC can press is not drawn** (`OwnerNeed.phoneRows`): Give, a team card's yes and
/// the door card's Full access, whose place `NeedComputerNote` takes. **The first option of a card that makes a GitHub
/// App or opens the Add device picture is drawn and takes no press** (`OwnerNeed.firstOptionStartsOnTheMac`): grey, as
/// a row that cannot be pressed, because only the Mac starts that step and the phone's press closed the card and
/// started nothing. The others keep their own index, which their press sends.
struct NeedOptions: View {
    let store: MobileStore
    let need: OwnerNeed
    /// The options that he ticked, on an item whose options combine: the card's own (`NeedCard.ticked`).
    @Binding var ticked: Set<Int>
    /// His answer, while it goes: the option that he pressed takes a check that draws itself, and the others dim.
    var given: MobileStore.GivenAnswer? = nil
    /// What an answer that he did not give looks like beside the one that he gave.
    static let dimmed = 0.38
    /// The column of a row's tick, from the words to the row's padding: the badge of the row ends before it.
    @ScaledMetric(relativeTo: .body) private var tickColumn: CGFloat = 32

    /// The option dims beside the answer that he gave: another option, other ticked ones, or his words.
    static func dims(_ index: Int, beside given: MobileStore.GivenAnswer?) -> Bool {
        switch given {
        case nil: false
        case .option(let pressed): pressed != index
        case .options(let went): !went.contains(index)
        case .words: true
        }
    }

    /// The agent's "What it wants" stands only for an item without options: with them, what it wants are the rows.
    /// **Never on a request for a key or a login**: its `todo` is the hub's own sentence about the Mac's secure form,
    /// which the card's line with the key says already, and the Mac's card leaves it out too (the owner, 20 November
    /// 2026: "I need more brevity and clarity"). The phone's key card said where the key is typed twice.
    static func asksInWords(_ need: OwnerNeed) -> Bool {
        !need.asksForSecret && need.choices.isEmpty && !need.todo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    /// **Over and under the words of every row** (the owner, 22 November 2026: "text wrapping of the options does not
    /// look good"): a label that wraps keeps this room over and under it, as the Mac's row and the words under a
    /// picture keep theirs, so one line is 44 points, two about 66 and three about 88, and a recommended row is as high
    /// as a plain row with words of the same length. A first line that wraps stands under the badge. Only the
    /// recommended row had it, and a wrapped label filled its row to the edges. It grows with the badge, which stops
    /// growing at the largest ordinary text size.
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
                case .unavailable(let index):
                    // drawn, grey, and taking no press: only the Mac starts its step (grey once: beside an answer that
                    // he gave, the row dims as every other row does)
                    option(index, recommended: false)
                        .disabled(true)
                        .opacity(Self.dims(index, beside: given) ? 1 : Self.dimmed)
                }
            }
            if need.combines { NeedSendTicked(store: store, need: need, ticked: ticked, given: given) }
        }
        // the options that he had ticked, on a card whose answer he took back (`MobileStore.undo`)
        .onAppear {
            let back = store.restoredTicks(of: need.id)
            if !back.isEmpty { ticked = Set(back) }
        }
    }

    /// One option to press: its press sends its own index. The answer that the agent recommends has its badge on the
    /// row's top edge (`RecommendedBadge`), and **no edge of its own** (the owner, 20 November 2026: "the recommended
    /// options should only have the badge, not the border over the option, otherwise it looks alraedy selected").
    /// **Where options combine, the row has the tick of the picture card at its end, and a press ticks it** (found with
    /// the owner's point of 22 November 2026 on the phone's cards; the picture card's ticks, his "Yes, as shown" of 21
    /// November 2026, and the Mac's tick rows): Send with their count stands under the rows, and the badge ends before
    /// the tick's column. A press sent the one option that he pressed, on a card that asks for several.
    private func option(_ index: Int, recommended marks: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let combines = need.combines
        let isTicked = combines
            && (NeedSendTicked.sent(need, store: store, given: given).map { $0.contains(index) } ?? ticked.contains(index))
        // his press waits 5 seconds with Undo, then goes (`MobileStore.hold`); where options combine it ticks
        return Button { press(index) } label: {
            // The agent's words, drawn as a plain label: they are data, never markup.
            HStack(spacing: 10) {
                if given == .option(index) { DrawnMark(symbol: "checkmark").fontWeight(.semibold) }
                Text(verbatim: need.choices[index])
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: combines ? .infinity : nil, alignment: .leading)
                if combines { NeedTick(ticked: isTicked) }
            }
                .padding(.vertical, clear)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 14)
                .background(Brand.bubble, in: shape)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
        .recommendedBadge(by: marks ? need.by : nil, inset: combines ? 14 + tickColumn : RecommendedBadge.inset)
        // it dims, with its badge, beside the answer that he gave: another option, other ticked ones, or his words
        .opacity(Self.dims(index, beside: given) ? Self.dimmed : 1)
        .accessibilityAddTraits(given?.option == index || isTicked ? .isSelected : [])
        .accessibilityValue(marks ? Text("Recommended") : Text(verbatim: ""))
        .accessibilityIdentifier(combines ? "need-tick-\(need.id)-\(index)" : "need-option-\(need.id)-\(index)")
    }

    /// A press of a row: the answer with that option, or, where options combine, its tick, until his answer went.
    private func press(_ index: Int) {
        guard need.combines else { return store.hold(needID: need.id, choice: index) }
        guard given == nil, NeedSendTicked.waiting(need, store: store) == nil else { return }
        if ticked.contains(index) { ticked.remove(index) } else { ticked.insert(index) }
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
    /// and go as his words go, and a press that waits for the hub says "Sending…", as a press on an option does. It
    /// waits 5 seconds with Undo first (`MobileStore.hold(needID:words:)`), which gives the field its words back.
    private func send(_ words: String) {
        guard given == nil else { return }
        store.hold(needID: need.id, words: words)
    }
}

/// **The options of a request with a picture each** (owner feature `need_pictures`, API 1.285; the owner, 20 November
/// 2026: "the idea would be that Needs You shows multiple options as images too, so I can choose between different ads
/// or designs for example without going to the chat"; the drawing `w3.png` of the design): two pictures in a line, a
/// line more for each two more, and each option's words under its picture. **A press of the picture opens it at full
/// screen** (`AttachmentGallery.place`, as a file of a chat opens) **and answers nothing; a press of the words is the
/// answer**, as a press of an option is (`MobileStore.press(needID:choice:)`): the same wait, the same "Sending…" and
/// the same refusals. On an item whose options combine, a press of the words ticks them, and Send with their count
/// sends the ones that he ticked. The answer that the agent recommends has its badge on its picture's top edge. At the
/// accessibility sizes one picture stands in a line.
///
/// A picture is read with this phone's own read of a file (`MobileStore.load`): only its own file, of the hub's
/// generation. Its square stands from the first frame, with the file's mark and, after a second, "Reading…" in it, so
/// nothing moves when the picture comes; a picture that did not come says "Not loaded", and a press reads it again.
struct NeedPictures: View {
    let store: MobileStore
    let need: OwnerNeed
    /// One for each option, in their order (`drawn`).
    let pictures: [MessageAttachment]
    /// The options that he ticked, on an item whose options combine: the card's own (`NeedCard.ticked`).
    @Binding var ticked: Set<Int>
    /// His answer, while it goes: the option that he pressed, or the ones that he ticked, keep their mark, and the
    /// others dim.
    var given: MobileStore.GivenAnswer? = nil
    /// The picture open at full screen.
    @State private var opened: URL?
    @ScaledMetric(relativeTo: .caption) private var badgeRoom: CGFloat = 10
    @Environment(\.dynamicTypeSize) private var typeSize

    /// From one picture to the next, and from a line to the next (`w3.png`).
    static let gap: CGFloat = 10
    /// A picture's corners and its words' corners: an option row's.
    static let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    /// **The pictures that a request's card draws over its options, or nil for the card of before**: only on a hub that
    /// names the feature, and only when the item has one picture for each of its options, which a phone presses, in
    /// their order. With fewer or more pictures than options no picture stands over an option, because none can be
    /// known to be its picture; and the hub gives all or none. Not on a card whose first option only the Mac starts
    /// (`OwnerNeed.firstOptionStartsOnTheMac`): its rows draw that option grey (`NeedOptions`).
    static func drawn(_ need: OwnerNeed, features: Set<String>) -> [MessageAttachment]? {
        guard features.contains(MobileClient.pictureOptions), !need.asksForSecret, let pictures = need.pictures,
              !pictures.isEmpty, pictures.count == (need.options ?? []).count, need.choices.count == pictures.count,
              need.optionsOnlyOnAComputer.isEmpty, !need.firstOptionStartsOnTheMac,
              pictures.allSatisfy({ $0.isImage && (try? $0.validate()) != nil })
        else { return nil }
        return pictures
    }

    var body: some View {
        let columns = typeSize.isAccessibilitySize ? 1 : 2
        let recommended = need.recommendedRow(features: Array(store.features), replies: [])
        let lines = stride(from: 0, to: pictures.count, by: columns).map { Array($0..<min($0 + columns, pictures.count)) }
        VStack(alignment: .leading, spacing: Self.gap) {
            ForEach(lines, id: \.self) { line in
                // the words of one line take the height of its longest, so its pictures stand at one height
                HStack(alignment: .top, spacing: Self.gap) {
                    ForEach(line, id: \.self) { index in
                        tile(index, recommended: recommended == .option(index))
                    }
                    if line.count < columns { Color.clear.frame(maxWidth: .infinity, maxHeight: 0) }
                }
                .fixedSize(horizontal: false, vertical: true)
                // the room over a line for the badge's upper half, for each picture of that line
                .padding(.top, line.contains { recommended == .option($0) } ? min(badgeRoom, RecommendedBadge.roomMost) : 0)
            }
            if need.combines { NeedSendTicked(store: store, need: need, ticked: ticked, given: given) }
        }
        .quickLookPreview($opened)
        // the options that he had ticked, on a card whose answer he took back (`MobileStore.undo`)
        .onAppear {
            let back = store.restoredTicks(of: need.id)
            if !back.isEmpty { ticked = Set(back) }
        }
        // **The card reads its pictures one after another, in the order of its options**: each read has the client's
        // limit of 15 seconds, and six large pictures read at once could each end "Not loaded" on a slow link. A read
        // that a press of a picture started, or that a new hub or generation must make again, is part of the same
        // order: a picture whose bytes are here costs nothing.
        .task(id: "\(store.filesGeneration) \(pictures.map(\.sha256))") {
            for file in pictures where store.picture(of: file) == nil {
                if Task.isCancelled { return }
                await store.load(file)
            }
        }
    }

    /// One option: its picture, and its words under it.
    private func tile(_ index: Int, recommended marks: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // the picture takes its whole square first; the words take the rest of the line's height
            picture(index)
                .recommendedBadge(by: marks ? need.by : nil, makesRoom: false)
                .layoutPriority(1)
            words(index, recommended: marks)
                .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
        // it dims, with its badge, beside the answer that he gave: other options, or his words
        .opacity(NeedOptions.dims(index, beside: given) ? NeedOptions.dimmed : 1)
    }

    /// The picture: a press opens it at full screen and answers nothing; one that did not come is read again.
    private func picture(_ index: Int) -> some View {
        let file = pictures[index]
        let missing = store.didNotLoad(file)
        return Button {
            if missing { Task { await store.readAgain(file) } } else { open(file) }
        } label: {
            OptionPicture(store: store, file: file)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(missing ? Text("Read \(file.name) again") : Text("\(file.name), \(file.sizeWords)"))
        .accessibilityIdentifier("need-picture-\(need.id)-\(index)")
    }

    /// The option's words: a press answers with that option, or, where options combine, ticks it.
    private func words(_ index: Int, recommended marks: Bool) -> some View {
        let combines = need.combines
        let isTicked = combines
            && (NeedSendTicked.sent(need, store: store, given: given).map { $0.contains(index) } ?? ticked.contains(index))
        return Button { press(index) } label: {
            HStack(spacing: 8) {
                if !combines && given == .option(index) { DrawnMark(symbol: "checkmark").fontWeight(.semibold) }
                // The agent's words, drawn as a plain label: they are data, never markup.
                Text(verbatim: need.choices[index])
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if combines { NeedTick(ticked: isTicked) }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 44, maxHeight: .infinity, alignment: .leading)
            .background(Brand.bubble, in: Self.shape)
            .contentShape(Self.shape)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
        .accessibilityAddTraits(given?.option == index || isTicked ? .isSelected : [])
        .accessibilityValue(marks ? Text("Recommended") : Text(verbatim: ""))
        .accessibilityIdentifier(combines ? "need-tick-\(need.id)-\(index)" : "need-option-\(need.id)-\(index)")
    }

    /// A press of the words: the answer with that option, or, where options combine, its tick, until his answer went.
    private func press(_ index: Int) {
        guard need.combines else { return store.hold(needID: need.id, choice: index) }
        guard given == nil, NeedSendTicked.waiting(need, store: store) == nil else { return }
        if ticked.contains(index) { ticked.remove(index) } else { ticked.insert(index) }
    }

    private func open(_ file: MessageAttachment) {
        Task { if let place = await AttachmentGallery.place(of: file, store: store) { opened = place } }
    }
}

/// **The tick of an option that combines with others** (the picture card's, his "Yes, as shown" of 21 November 2026):
/// an empty circle, and a filled one with a check in the accent colour once he ticked it. VoiceOver reads it as the
/// row's selected state.
struct NeedTick: View {
    let ticked: Bool

    var body: some View {
        Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(ticked ? Brand.accent : Brand.muted)
            .accessibilityHidden(true)
    }
}

/// **Send with the count of the options that he ticked**, at the trailing side under the rows or the pictures of an
/// item whose options combine (`NeedOptions`, `NeedPictures`), as the Mac's card has it; it takes no press while none
/// is ticked, and from his Send on it keeps their count. Its press waits 5 seconds with Undo (`MobileStore.hold`).
struct NeedSendTicked: View {
    let store: MobileStore
    let need: OwnerNeed
    let ticked: Set<Int>
    var given: MobileStore.GivenAnswer? = nil

    /// **The options of his Send that waits for the hub** (a ticked Send behind another answer on its way): they stand
    /// ticked, and the ticks and Send take no press until it went, as once his answer went. A change of the ticks then
    /// changed the card and not the Send that waited, and the old ticks went.
    static func waiting(_ need: OwnerNeed, store: MobileStore) -> [Int]? {
        if case .ticked(let indexes) = store.waitingPresses[need.id] { indexes } else { nil }
    }

    /// The ticks of his answer, from his Send on: on its way, or waiting to go.
    static func sent(_ need: OwnerNeed, store: MobileStore, given: MobileStore.GivenAnswer?) -> [Int]? {
        given?.options ?? waiting(need, store: store)
    }

    var body: some View {
        let went = Self.sent(need, store: store, given: given)
        let can = given == nil && went == nil && !ticked.isEmpty
        HStack {
            Spacer(minLength: 0)
            Button { store.hold(needID: need.id, choices: ticked.sorted()) } label: {
                Text("Send \(went?.count ?? ticked.count)")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
                    .foregroundStyle(can ? Brand.surface : Brand.muted)
                    .background(can ? Brand.accent : Brand.bubble, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!can)
            .accessibilityIdentifier("need-send-ticked-\(need.id)")
        }
    }
}

/// **One option's picture, in its square from the first frame**: the picture whole on the quiet fill of an option, the
/// file's mark and "Reading…" after a second while it comes, and "Not loaded" when it did not. Its card reads it
/// (`NeedPictures`), in the order of the options, and again after a new hub or generation, which empties the store's
/// files (as `PictureTile`).
private struct OptionPicture: View {
    let store: MobileStore
    let file: MessageAttachment

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .background(Brand.bubble)
            .overlay {
                if let picture = store.picture(of: file) {
                    Image(decorative: picture, scale: 1).resizable().aspectRatio(contentMode: .fit)
                } else if store.didNotLoad(file) {
                    VStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise").font(.title3).foregroundStyle(Brand.warning)
                        Text("Not loaded").font(.footnote).foregroundStyle(Brand.warning)
                    }
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: file.symbol).font(.title3).foregroundStyle(.secondary)
                        // the words' room from the first frame, so the mark stands where it will stand
                        ZStack {
                            Text("Reading…").font(.footnote).hidden()
                            Held { Text("Reading…").font(.footnote).foregroundStyle(Brand.muted) }
                        }
                    }
                }
            }
            .clipShape(NeedPictures.shape)
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
    /// From a row's end to the badge's end.
    static let inset: CGFloat = 12

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
    /// The row makes the room over it for the badge's upper half: false where its line of pictures makes it for the
    /// line's every picture (`NeedPictures`), so the pictures of one line stand at one height.
    var makesRoom = true
    /// From the row's end to the badge's: further on a row with a tick, whose column stays clear.
    var inset = RecommendedBadge.inset
    @ScaledMetric(relativeTo: .caption) private var room: CGFloat = 10

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                // the guide stands on a view that is always there, as on the Mac
                ZStack {
                    if let agent { RecommendedBadge(agent: agent).dynamicTypeSize(...RecommendedBadge.largest) }
                }
                .alignmentGuide(.top) { $0[VerticalAlignment.center] }
                .padding(.trailing, inset)
            }
            .padding(.top, agent == nil || !makesRoom ? 0 : min(room, RecommendedBadge.roomMost))
    }
}

extension View {
    /// The badge of the answer that `agent` recommends on this row (`RecommendedBadge`); nothing for nil. `makesRoom`
    /// false: the room over the row is the caller's. `inset`: from the row's end to the badge's.
    func recommendedBadge(by agent: String?, makesRoom: Bool = true, inset: CGFloat = RecommendedBadge.inset) -> some View {
        modifier(RecommendedPlace(agent: agent, makesRoom: makesRoom, inset: inset))
    }
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
    /// **Send found words that look like a key** (`MobileStore.NeedKeyHold`), as the field of Needs clarification and
    /// the chat find them: the line over the field says so, with Keep it (the owner, 22 November 2026: "Yes, the same
    /// in both"), nothing is held or saved, and the words stay. An answer in words goes into the agent's conversation,
    /// where nothing masks a key before it is read, but a normal link can look like one too. It belongs to these words:
    /// an edit ends it, and the next Send asks again.
    @State private var keyHold: MobileStore.NeedKeyHold?

    private static let capsule = RoundedRectangle(cornerRadius: 25, style: .continuous)

    var body: some View {
        // The words that the hub took stay in the field until the item folds with them (`answersTaken`): the field
        // emptied at the receipt, and a longer answer's field shrank one read before the fold. A press on an option
        // wrote nothing in the field, so its field stays as it is.
        let taken = store.answersTaken[need.id]
        let typed = taken.flatMap { $0.request.choice == nil && $0.request.choices == nil ? $0.request.text : nil }
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
            // Over the field: under it, the keyboard stands on the line, as over the field of Needs clarification. Keep
            // it at its end, as in the chat: it holds those exact words for their 5 seconds, and they go.
            if let hold = keyHold, hold.words == text.wrappedValue, store.isCurrent(hold) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    ComposerNote(words: String(l10n: "That looks like a key. Never send a key in a message."), isWarning: true)
                        .accessibilityIdentifier("answer-key-\(need.id)")
                    TextAction(title: String(l10n: "Keep it"), enabled: canSend, font: .caption) {
                        focused = false
                        keyHold = store.holdSend(needID: need.id, keeping: hold)
                    }
                    .accessibilityIdentifier("answer-keep-\(need.id)")
                }
            }
            HStack(alignment: .bottom, spacing: 0) {
                // As in a chat: the round buttons stop growing at the largest ordinary text size.
                if store.supportsAttachments {
                    AttachmentButton(store: store, composer: composer, bare: true)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .frame(height: line + 28)
                }
                ZStack(alignment: .topLeading) {
                    // **The prompt wraps, and is never cut** (picture 13 of F9: at the largest text size the field's
                    // own prompt stood on one line as "Your ans…"): the box draws it while the field is empty, where
                    // the field's words begin, and the field grows to it. VoiceOver reads the field's own label.
                    if text.wrappedValue.isEmpty {
                        Text("Your answer").foregroundStyle(Brand.placeholder)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    TextField(text: text, prompt: Text(verbatim: ""), axis: .vertical) {
                        Text("Your answer")
                    }
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .accessibilityIdentifier("answer-\(need.id)")
                }
                .padding(.vertical, 14)
                .padding(.leading, store.supportsAttachments ? 0 : 15)
                .padding(.trailing, 6)
                // The keyboard goes with the answer, before the item folds (item 95): it does not carry the page.
                // his words wait 5 seconds with Undo, then go (`MobileStore.holdSend`)
                SendButton(enabled: canSend, label: String(l10n: "Send answer"), side: 36) {
                    // Words that look like a key stay here, with the line that says why, and nothing is held: the
                    // store decides it once, at this press (`holdSend`).
                    keyHold = store.holdSend(needID: need.id)
                    if keyHold == nil { focused = false }
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
        // The line about a key and its Keep it go with any change of those words, from this box or from another place
        // (the request's other card, a refusal that empties the drafts), as in the chat: the next Send asks again.
        .onChange(of: store.answerDraft(for: need.id)) { _, words in
            if let keyHold, keyHold.words != words { self.keyHold = nil }
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
    /// The send found words that look like a key (`MobileStore.NeedKeyHold`): the line over the field, with Keep it,
    /// which sends those exact words (the owner, 22 November 2026: "Yes, the same in both"), until they change. On a
    /// key request the line stands alone: such words never go from there, as on the Mac.
    @State private var keyHold: MobileStore.NeedKeyHold?
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
                // Over the field: under it, the keyboard stands on the line (the look check of 20 November 2026). Keep it
                // at its end, as in the chat: those exact words go, once.
                // **Not on a key request**: there, as on the Mac, such words never go from this field (`clarify`), and
                // the line stands alone; the secure form on the Mac takes a key.
                if let hold = keyHold, hold.words == shown.wrappedValue, store.isCurrent(hold) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        ComposerNote(words: String(l10n: "That looks like a key. Never send a key in a message."), isWarning: true)
                            .accessibilityIdentifier("clarify-key-\(need.id)")
                        if talks {
                            TextAction(title: String(l10n: "Keep it"), enabled: canSend, font: .caption) {
                                focused = false
                                Task { keyHold = await store.talk(needID: need.id, words: hold.words, keeping: hold) }
                            }
                            .accessibilityIdentifier("clarify-keep-\(need.id)")
                        }
                    }
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
                        // Words that look like a key stay here, with the line that says why, and nothing is saved: the
                        // store decides it once, at this press. Else the keyboard goes with the message, before the
                        // item folds, as with an answer.
                        if !KeyInText.contains(trimmed) { focused = false }
                        let words = shown.wrappedValue
                        keyHold = talks ? await store.talk(needID: need.id, words: words)
                            : await store.clarify(needID: need.id, words: words)
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
                // The link, a line high with a touch of 44 points (`TextAction`; F9, the card's front): on a key card
                // in the column of the words of the line over it, and under an answer's capsule at the card's edge,
                // where its rows begin.
                TextAction(title: String(l10n: "Needs clarification"), font: .callout) { stands = true; takesCursor = true }
                    .foregroundStyle(Brand.accent)
                    .padding(.leading, talks || typeSize.isAccessibilitySize ? 0 : markWidth + 12)
                    .accessibilityIdentifier("clarify-link-\(need.id)")
            }
        }
        // The hub refused registered login text: the store emptied the words, and the line about a key goes with them.
        .onChange(of: store.secretRefusals) { _, _ in keyHold = nil }
        // The line about a key and its Keep it go with any change of those words, from this field or from another place
        // (the request's other card), as in the chat: the next Send asks again.
        .onChange(of: store.clarifyDraft(for: need.id)) { _, words in
            if let keyHold, keyHold.words != words { self.keyHold = nil }
        }
        // The hub took his message under the card, which now stands in its talk: the field goes back to its link.
        .onChange(of: store.talkReceipts[need.id]) { _, _ in
            stands = false
            focused = false
            keyHold = nil
        }
    }

    /// The field's words changed: the store keeps them, in memory only. Nothing cuts them here: a cut that changed
    /// nothing in the store left the field with words that the store did not have, and Send sent the shorter ones
    /// (review round 2).
    private func changed(_ text: String) {
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

/// **His Pause of an answered card's task that did not go** (`MobileStore.pauseState`; the review of 21 November 2026),
/// under the card, as an answer's lines stand under an open card (`NeedFooter`), whatever the card's mark is now: "Not
/// sent" with Try again, which sends the same request, while every later write of the phone waits behind it; or the
/// hub's refusal in the phone's words of a refused write, with Discard, which gives the card its Pause back where its
/// task works. The refused Pause left the Outbox already, so nothing waits behind it.
private struct NeedPauseLine: View {
    let store: MobileStore
    let need: OwnerNeed
    let task: Int
    let state: MobileStore.PauseState

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            switch state {
            case .notSent:
                ComposerNote(words: String(l10n: "Not sent"), isWarning: true)
                    .accessibilityIdentifier("need-pause-words-\(need.id)")
                // only while it can act, never gray (review B2i), as an answer's Try again
                if store.canRetry {
                    TextAction(title: String(l10n: "Try again"), font: .caption) { Task { await store.retry() } }
                        .accessibilityIdentifier("need-pause-retry-\(need.id)")
                }
            case .refused(let words):
                ComposerNote(words: words, isWarning: true)
                    .accessibilityIdentifier("need-pause-words-\(need.id)")
                TextAction(title: String(l10n: "Discard"), font: .caption) { store.discardPauseRefusal(task) }
                    .accessibilityIdentifier("need-pause-discard-\(need.id)")
            }
        }
        .padding(.top, NeedFooter.above)
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
        } else if store.heldAnswer(to: need.id) != nil {
            // his answer waits with Undo: nothing goes, and nothing waits for it
            EmptyView()
        } else if let stopped = stoppedAhead {
            // **His press waits behind a request that did not go, and says so** (the owner, 22 November 2026: "cards
            // on the phone are left with Sending... and never complete"): another card's answer, a chat message, a
            // message under a card or a Pause, which waits in the Outbox with no refusal and no send. Its Try again
            // sends that request with its own number, and this press goes by itself once it has its answer. While the
            // hub does not answer, or this phone's key is not in hand, the line over the page is the one sign.
            stoppedLine(stopped)
        } else if !need.asksForSecret, taken || answerSends {
            // **His answer on its way says so on its own line, by the ring in the check's place** (F10, B1: the owner's
            // "Yes, as drawn" of 22 November 2026 to "a ring that turns, then the check, with no word";
            // `NeedCard.going`), from the end of its wait with Undo to the fold: so nothing stands under the card,
            // where "Sending…" stood.
            EmptyView()
        } else if taken || sends {
            // **The key card's words about its key, and his message under a card, on their way, are one line, from the
            // press to the fold** (polish pass: the receipt's jump): they have no folded line and no ring. Only a wait
            // that takes a second says so (items 76 and 95), so its words never come once the hub took them; words
            // that came stay, and the item folds them away. They went at the receipt, with their room.
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

    /// The request that this item's press waits behind, when it did not go: another one of this hub and generation in
    /// the Outbox, with no refusal and no send, which Try again can send now (`canRetry`).
    private var stoppedAhead: PendingRequest? {
        guard store.waitingPresses[need.id] != nil, store.canRetry, let pending = store.pending,
              !store.onItsWay(pending), pending.needID != need.id, !store.talks(pending, under: need.id) else { return nil }
        return pending
    }

    /// This item's own answer goes now: a press that waits for the hub, or a request on its way (`onItsWay`).
    private var answerSends: Bool {
        if store.waitingPresses[need.id] != nil { return true }
        guard let pending = store.pending, pending.needID == need.id else { return false }
        return pending.refusal == nil && store.onItsWay(pending)
    }

    /// This item's own answer goes now: a press that waits for the hub, or a send that waits for its receipt; or his
    /// message under the card, on its way.
    private var sends: Bool {
        if store.waitingPresses[need.id] != nil { return true }
        guard let pending = store.pending, pending.needID == need.id || store.talks(pending, under: need.id) else { return false }
        return pending.refusal == nil && store.onItsWay(pending)
    }

    /// This answer did not go, or the one that it waits behind: one line and the one action that fits. It stays until
    /// the hub confirms the answer or the owner discards a refused one.
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
