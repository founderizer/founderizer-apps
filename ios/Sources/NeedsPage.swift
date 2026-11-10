import FleetCore
import SwiftUI

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
    /// The column of a task's mark, as on a task's row: it grows with the mark.
    @ScaledMetric(relativeTo: .title3) private var markWidth: CGFloat = 22
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if store.readsTheHub {
                    LoadingLine("Reading the hub…")
                        .padding(.horizontal, 16).padding(.vertical, 12)
                }
                ForEach(shown ?? store.openNeeds) { need in
                    let folds = folding.contains(need.id)
                    // **An answered item folds away** (items 76 and 95): its height goes to nothing over 250 ms, easing
                    // out, its content clipped to what is left of it and fading, and the items under it rise into the
                    // room it frees, never over it.
                    Fold(shown: folds ? 0 : 1) {
                        NeedCard(store: store, need: need, header: true)
                            .padding(.bottom, NeedCard.gap)
                    }
                    .clipped()
                    .opacity(folds ? 0 : 1)
                    .allowsHitTesting(!folds)
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
        .onChange(of: store.openNeeds.map(\.id)) { _, ids in fold(to: ids) }
        .background(Brand.canvas)
        .overlay {
            // One title and no second line (D-2); a hub that does not answer says so once, over the page. It comes
            // when the last item has folded, not over it.
            if (shown ?? store.openNeeds).isEmpty && store.ownerTasks.isEmpty && store.snapshot != nil
                && store.showsCurrent {
                ContentUnavailableView("Nothing needs you", systemImage: "checkmark.circle")
            }
        }
        .refreshable { await store.refresh() }
        .tabRootPage()
        .hubBanner(store)
    }

    /// The page follows the hub's list: a new item comes in at once, in its place, and an item that left folds away
    /// where it stood and then goes. Under Reduce Motion it fades where it stands, and then goes.
    private func fold(to ids: [Int]) {
        let open = store.openNeeds
        let gone = (shown ?? []).filter { !ids.contains($0.id) }
        // The ones that fold keep their place among the open ones, in the hub's order (the newest first).
        shown = (open + gone.filter { need in !open.contains { $0.id == need.id } })
            .sorted { ($0.raised, $0.id) > ($1.raised, $1.id) }
        guard !gone.isEmpty else { return }
        let goneIDs = Set(gone.map(\.id))
        withAnimation(.easeOut(duration: reduceMotion ? 0.2 : 0.25)) { folding.formUnion(goneIDs) }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 210 : 260))
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) {
                // One that came back while it folded stays, open again.
                let open = Set(store.openNeeds.map(\.id))
                shown = shown?.filter { !goneIDs.contains($0.id) || open.contains($0.id) }
                folding.subtract(goneIDs)
            }
        }
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
/// margins pass, fault 18). **In the chat an answered one stays, folded to two lines** (item 103; `NeedAnswered`).
struct NeedCard: View {
    let store: MobileStore
    let need: OwnerNeed
    /// The card was open when it was last drawn, and how far its fold has gone (fix round 3, item 40).
    @State private var wasOpen = false
    @State private var foldShare: CGFloat = 0
    /// Who asks and when, over the card: on Needs you.
    var header = false
    /// The files of the message that answered it, which its answer shows.
    var answerFiles: [MessageAttachment] = []

    /// The card's shape: 26 on Needs you, as a card of the system's lists, and 18 in a chat, as a bubble.
    static func shape(onPage: Bool) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: onPage ? 26 : 18, style: .continuous)
    }
    /// From one item's foot to the next item's head, and from a head to its card: the grouped list's measures.
    static let gap: CGFloat = 20
    static let head: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if header { NeedHead(store: store, need: need) }
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
                    NeedAnswered(store: store, need: need, files: answerFiles)
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
        .onAppear { wasOpen = need.isOpen }
        .onChange(of: need.isOpen) { was, now in
            if now { wasOpen = true; foldShare = 0; return }
            guard was else { return }
            withAnimation(.easeOut(duration: 0.25)) { foldShare = 1 } completion: { wasOpen = false }
        }
    }

    private var open: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(need.title).font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            openRows
        }
    }

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
                Text(need.title).font(.headline).fixedSize(horizontal: false, vertical: true)
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
            // Under it: the open rows go, and the answer's line comes in its place under the question.
            CrossFold(shown: share) {
                openRows.padding(.top, 12)
                    .opacity(1 - share).allowsHitTesting(false).accessibilityHidden(true)
                NeedAnswered.answerLine(need).padding(.top, 4).opacity(share)
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
                FieldRow(title: "Why", value: need.why)
            }
            if NeedOptions.asksInWords(need) {
                RowLine()
                FieldRow(title: "What it wants", value: need.todo)
            }
            RowLine()
            if need.asksForSecret {
                NeedSecretNote(need: need)
            } else {
                if !need.choices.isEmpty { NeedOptions(store: store, need: need) }
                NeedAnswerBox(store: store, need: need)
            }
        }
    }
}

/// **An answered request folds to two lines in the chat** (fix round 2, item 103; D-7 item 2, as the Mac's
/// `NeedRequestCard` folds it): its title, as the open card's, and what he answered with a check ("✓ Correos"), in the
/// card's small type and its quiet colour; the rest on a tap — the request, "Answered", and his answer with its files —
/// and a tap on its title folds it again. It was gone from the chat once answered, and his answer stood as a bubble
/// with nothing to say what it answered.
private struct NeedAnswered: View {
    let store: MobileStore
    let need: OwnerNeed
    let files: [MessageAttachment]
    @State private var expanded = false

    private var answer: String { need.answer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    /// What he answered, in the folded card's second line: his words or the option he pressed.
    private var answerWords: String { Self.words(of: need) }
    static func words(of need: OwnerNeed) -> String {
        let answer = need.answer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return answer.isEmpty ? "Answered" : answer
    }

    /// The folded card's first line: the question on one line. Its fold draws the same line (`NeedCard`).
    static func titleLine(_ need: OwnerNeed) -> some View { Text(need.title).font(.headline).lineLimit(1) }

    /// The folded card's second line: what he answered, with a check ("✓ Correos").
    static func answerLine(_ need: OwnerNeed) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark").font(.caption.weight(.semibold))
            Text(verbatim: words(of: need)).lineLimit(1)
        }
        .font(.caption).foregroundStyle(Brand.muted)
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
                    Text(need.title).font(.headline)
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
                FieldRow(title: "Why", value: need.why)
            }
            if NeedOptions.asksInWords(need) {
                RowLine()
                FieldRow(title: "What it wants", value: need.todo)
            }
            if !answer.isEmpty || !files.isEmpty {
                RowLine()
                if answer.isEmpty {
                    Text("Your answer").font(.caption).foregroundStyle(Brand.muted)
                } else {
                    FieldRow(title: "Your answer", value: answer)
                }
                if !files.isEmpty { AttachmentGallery(store: store, files: files, alignment: .leading) }
            }
        }
    }

    private var folded: some View {
        Button { expanded = true } label: {
            VStack(alignment: .leading, spacing: 4) {
                Self.titleLine(need)
                Self.answerLine(need)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(need.title), answered: \(answerWords)")
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
    /// Half the height of the headline's capitals: the mark's centre stands this far over the first line's baseline.
    @ScaledMetric(relativeTo: .headline) private var capHalf: CGFloat = 6

    var body: some View {
        // **The mark stands on the head's first line** (margins pass, fault 15), as on the row of a task that only he
        // can move: at the largest text sizes the head takes two lines, and the mark stood on their middle.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            AgentAvatar(name: need.by, state: store.state(of: need.by), base: 20, moves: false)
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
struct NeedOptions: View {
    let store: MobileStore
    let need: OwnerNeed

    /// The agent's "What it wants" stands only for an item without options: with them, what it wants are the rows.
    static func asksInWords(_ need: OwnerNeed) -> Bool {
        need.choices.isEmpty && !need.todo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(need.choices.enumerated()), id: \.offset) { index, option in
                let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                Button { store.press(needID: need.id, choice: index) } label: {
                    // The agent's words, drawn as a plain label: they are data, never markup.
                    Text(verbatim: option)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, 14)
                        .background(Brand.bubble, in: shape)
                        .contentShape(shape)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.primary)
                .accessibilityIdentifier("need-option-\(need.id)-\(index)")
            }
        }
    }
}

/// **The answer of one item in words or files, in the chat composer's look** (fix round 2, item 78): one capsule with
/// the plain "+" at its left, the field, and the round Send at its right, "+" and Send on the field's one line. It was a
/// filled grey "+" circle beside a field of its own shape, a second composer look on a chat that already has one. Send
/// is the accent's violet, as every Send that is not a chat's (item 68). The whole capsule takes a tap (item 53).
struct NeedAnswerBox: View {
    let store: MobileStore
    let need: OwnerNeed
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
        let text = Binding(get: { typed ?? store.answerDraft(for: need.id) },
                           set: { store.setAnswerDraft($0, for: need.id) })
        let trimmed = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let composer = MobileStore.stageKey(need: need.id)
        let files = store.readyFiles(for: composer)
        let waiting = store.filesAreWaiting(for: composer)
        let canSend = taken == nil && store.canWrite && !waiting && trimmed.count <= MobileStore.textLimit
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
                SendButton(enabled: canSend, label: "Send answer", side: 36) {
                    focused = false
                    await store.send(needID: need.id)
                }
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .frame(height: line + 28)
                .accessibilityIdentifier("send-answer-\(need.id)")
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

/// A request for a key or a login takes no answer here. A key typed on this phone would go out as words, into the
/// agent's conversation, before anything could mask it, and the hub refuses an answer in words. Founderizer on the
/// Mac answers it with its secure form, which puts the value straight into the vault.
struct NeedSecretNote: View {
    let need: OwnerNeed

    var body: some View {
        // The key in the column of a task's mark (margins pass, fault 11).
        MarkedLine(symbol: "key.horizontal",
                   words: "Type it in Founderizer on your Mac: it goes straight into the vault, and no agent sees it.")
            .font(.callout)
            .padding(.vertical, 4)
            .accessibilityIdentifier("secret-need-\(need.id)")
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
        let trimmed = store.answerDraft(for: need.id).trimmingCharacters(in: .whitespacesAndNewlines)
        let taken = store.answersTaken[need.id] != nil
        if need.asksForSecret {
            EmptyView()
        } else if taken || sends {
            // **This answer on its way is one line, from the press to the fold** (polish pass: the receipt's jump): a
            // press that waits for the hub (item 51), the send, and the answer that the hub took until its item folds.
            // Only a wait that takes a second says so (items 76 and 95), so its words never come once the hub took
            // the answer; words that came stay, and the item folds them away. They went at the receipt, with their
            // room, one read before the fold.
            Held(comes: !taken) { ComposerNote(words: "Sending…").padding(.top, Self.above) }
                .accessibilityIdentifier("waiting-answer")
        } else if let pending = store.pending, pending.needID == need.id {
            stoppedLine(pending)
        } else if let note = note(count: trimmed.count, files: store.filesAreWaiting(for: composer)) {
            ComposerNote(words: note.words, isWarning: note.isWarning,
                         detail: store.storageError != nil ? store.storageErrorDetail
                             : store.fileError != nil ? store.fileErrorDetail : nil)
                .padding(.top, Self.above)
        } else if let other = store.pending, store.sending {
            // **Why this answer waits, in his words, and only for a wait that lasts** (fix round 2, item 42): "Another
            // request waits for its receipt." stood under every other item for each send, the hub's books in words.
            // A send that answers inside a second shows nothing that blinks away.
            Held {
                ComposerNote(words: other.needID == nil ? "Sending your message…" : "Sending your other answer…")
                    .padding(.top, Self.above)
            }
        }
    }

    /// This item's own answer goes now: a press that waits for the hub, or a send that waits for its receipt.
    private var sends: Bool {
        if store.waitingPresses[need.id] != nil { return true }
        guard let pending = store.pending, pending.needID == need.id else { return false }
        return pending.refusal == nil && store.sending
    }

    /// This answer did not go: one line and the one action that fits. It stays until the hub confirms the answer or the
    /// owner discards a refused one.
    private func stoppedLine(_ request: PendingRequest) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let refusal = request.refusal {
                ComposerNote(words: refusal, isWarning: true)
                // Each action only while it can act, never grey (review B2i).
                TextAction(title: "Discard", font: .caption) { store.discardRefused() }
            } else {
                ComposerNote(words: "Not sent", isWarning: true)
                if store.canRetry {
                    TextAction(title: "Try again", font: .caption) { Task { await store.retry() } }
                }
            }
        }
        .padding(.top, Self.above)
        .accessibilityIdentifier("waiting-answer")
    }

    /// At most one line under an answer: how near the hub's limit it is, or why nothing can go now.
    private func note(count: Int, files waiting: Bool) -> (words: String, isWarning: Bool)? {
        if let words = store.storageError { return (words, true) }
        if let words = store.fileError { return (words, true) }
        if waiting {
            return (store.uploading.isEmpty ? "A file did not go up. Send it again, or take it out." : "Sending a file…",
                    store.uploading.isEmpty)
        }
        // The Mac's words over the limit, and one number format near it, as the chat's composer says them.
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
