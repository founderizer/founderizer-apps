import AppKit
import FleetCore
import SwiftUI

/// **Needs you: the requests as one lane of cards at the left, and the request at hand beside it** (the owner's yes of
/// 11 November 2026 to its picture, with the lane at the left). He asked for "one request at a time, but the list on a
/// side, so I can easily move between them or go to a specific one, but I really like the big layout for the decision
/// at hand", and of a list of flat rows at the page's left: "that looks like another sidebar, I prefer something that's
/// similar to the Tasks page". So the list is a lane of the Tasks board (`ActivityBoard`): its heading with its count,
/// and a card for each request with its title and its agent. The request at hand stands beside the lane as a setup
/// step does (`SetupMetrics`): the agent's glyph, the title, the reason, and its answers.
///
/// - A click on a card puts that request at hand; so do the Up and Down keys.
/// - A request that he answers leaves the lane in the frame he answers, and the one that stood under it comes to hand
///   (`NeedsLane.successor`).
/// - A request that an agent's work waits for has an orange hourglass on its card and beside its agent's name.
/// - A task that only he can move is in the lane as its card of the Tasks board, which opens the task.
/// - The requests that ended stand behind one row, "53 answered", by day, as Ended's "110 more" does on Tasks. The page
///   drew each of them as a card under the open ones: 53 cards under 9 on his fleet that day.
///
/// The page stands in the column of every page (`FleetStyle.pageWidth`): the lane takes a third of it, as a lane of
/// the Tasks board takes a third of that board.
struct NeedsBoard: View {
    @Bindable var store: FleetStore
    /// The lane shows the requests that ended, under its row that counts them.
    @State private var showsEnded = false
    /// A request that ended, which stands in the place of the request at hand, with its answer: one that he opened from
    /// the list, or the request at hand itself when it ended and not by his answer here (`settle`).
    @State private var endedAtHand: Int?
    /// His answers as the outbox saved them, by request, kept from the frame each went until the reading says the
    /// request is answered (`WordsOnTheirWay`): the store lets a request go with its receipt, a round trip before that
    /// reading, and the card would come back into the lane for that round trip.
    @State private var sent: [Int: PendingRequest] = [:]
    /// The answers that the hub confirmed, by request, until the reading says the request is answered. The store keeps
    /// one receipt, its last: when he answers the next request at once, as the keys let him, that request's receipt
    /// takes its place, and the card of the request before it would come back into the lane until its reading.
    @State private var confirmed: [Int: PendingRequest] = [:]
    /// The lane as it stood at its last change: the request that takes the place of one that left is the one that stood
    /// under it there (`NeedsLane.atHand`).
    @State private var order: [Int] = []
    /// The choice that the page itself wrote to the store (`choose`): a change of the store's choice to another value
    /// came from outside the page, from a task's orange line on the Tasks board or from a notification.
    @State private var settled: Int?
    /// What he left open in each request, kept while the page shows (`StepMemory`).
    @State private var memory: [Int: StepMemory] = [:]
    /// **His last answer went from the field of Your answer, so he writes**: the field of the request that comes to
    /// hand takes the cursor, and what he types next is words in that field. With no cursor, a number that began his
    /// next words marked an option, and Return sent it (review of 11 November 2026).
    @State private var writes = false
    /// The keys of the request at hand, which its answer box gives the page's one watch.
    @State private var stepKeys = StepKeys()
    /// **The requests that he answered here a moment ago, which stay in the lane and at hand while the answer settles**
    /// (`hold`; the owner's yes of 11 November 2026 to its moving picture: "Yes, build it"): his answer stands with a
    /// check that draws itself, the glyph of the agent that asked makes its one jump and the orange hourglass goes
    /// out, and then the request leaves. Not under Reduce Motion: there the request leaves in the frame he answers.
    @State private var settling: Set<Int> = []
    /// The requests whose agent took the answer, 0.3 s after he gave it: its glyph jumps and its hourglass is out.
    @State private var took: Set<Int> = []
    /// A request leaves by his answer: the one that comes to hand rises 8 points into its place, and the mark of
    /// "Nothing needs you" draws itself when it was the last one.
    @State private var leaves = false
    /// The count of the answers that began to settle, so that a later answer's clock ends only its own.
    @State private var holds = 0
    /// The requests that his answer here sent away: none of them is one that "ended in another way" (`settle`), also
    /// when the reading has its answer before its moment ends.
    @State private var his: Set<Int> = []
    /// The task's card that has the keyboard's focus: Return is that card's, and opens its task.
    @FocusState private var focusedTask: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Between the lane and the request at hand, as between two lanes of the Tasks board.
    private static let spacing: CGFloat = 24
    /// The narrowest lane, and the least room of the request at hand: in a column under their sum the page scrolls
    /// sideways, as the Tasks board does.
    private static let laneWidth: CGFloat = 200, stageWidth: CGFloat = 320
    /// Where the glyph of the request at hand stands under the page's title: 28 points under the top of the lane's
    /// first card.
    private static let stepTop: CGFloat = FormMetrics.headingRow + FleetSpace.inside + 28

    var body: some View {
        let state = store.state
        let needs = state?.needs ?? []
        let now = state?.time ?? Date().timeIntervalSince1970
        let onWay = Dictionary(needs.compactMap { need in onItsWay(need).map { (need.id, $0) } }) { first, _ in first }
        // A request whose answer settles is still in the lane, at hand, until its moment ends (`hold`).
        let lane = NeedsLane(needs, sent: Set(onWay.keys), held: settling, now: now)
        let open = lane.open.map(\.id)
        // The request at hand, by the one rule of this pass and of what `settle` writes back (`NeedsLane.atHand`).
        let hand = NeedsLane.atHand(chosen: store.selectedNeed, order: order, open: open)
        let atHand = lane.open.first { $0.id == hand }
        let ended = endedAtHand.flatMap { id in open.contains(id) ? nil : needs.first { $0.id == id } }
        let shown = ended ?? atHand
        let tasks = state?.ownerTasks ?? []
        FleetPage("Needs you", fills: true) {
            GeometryReader { proxy in
                // The lane takes a third of the column, less the room between three lanes: the width of a lane of the
                // Tasks board in a window of this column's width.
                let fits = proxy.size.width >= Self.laneWidth + Self.spacing + Self.stageWidth
                let width = fits ? max(Self.laneWidth, ((proxy.size.width - 2 * Self.spacing) / 3).rounded(.down)) : Self.laneWidth
                // **One structure at every width**: a column too narrow for both scrolls sideways, and a wider one
                // only stops that scroll. With a branch for each, a drag of the window's edge across the line made the
                // page again, and a key that he was typing went with it.
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: Self.spacing) {
                        cards(lane, tasks: tasks, atHand: ended == nil ? atHand?.id : nil, state: state, now: now)
                            .frame(width: width)
                        stage(shown, onItsWay: shown.flatMap { onWay[$0.id] }, waits: shown.flatMap { state?.needWaits[$0.id] } ?? [],
                              now: now, empty: tasks.isEmpty)
                            .frame(width: fits ? proxy.size.width - width - Self.spacing : Self.stageWidth)
                    }
                    .frame(height: proxy.size.height)
                    // The stop of the sideways scroll is the outer scroll's alone, said outright: where the system hands
                    // it down to the scrolls under it, the lane and the request at hand, which scroll by themselves,
                    // would stand still with it (review of 11 November 2026). On macOS 27 a scroll gives its content
                    // its own value, measured that day; the app also runs on macOS 15.
                    .scrollDisabled(false)
                }.scrollDisabled(fits)
            }
        }
        .onChange(of: open, initial: true) { _, lane in settle(lane, needs: needs) }
        .onChange(of: store.pending?.requestID, initial: true) { _, _ in
            if let pending = store.pending, pending.refusal == nil, let need = pending.needID { sent[need] = pending }
        }
        .onChange(of: store.lastReceipt?.request_id, initial: true) { _, _ in
            guard let receipt = store.lastReceipt else { return }
            for (need, request) in sent where receipt.matches(request) { confirmed[need] = request }
        }
        // The hub refused his answer: the request is his again, and it comes back to hand, where the line of the
        // write that did not go names it. Its card came back into the lane, and the next request stayed at hand.
        .onChange(of: store.pending?.refusal) { _, refusal in
            guard refusal != nil, let need = store.pending?.needID else { return }
            sent[need] = nil
            confirmed[need] = nil
            settling.remove(need)
            took.remove(need)
            his.remove(need)
            // The request waits again: it comes to hand. It ended meanwhile (he answered it on his phone too): it
            // shows with its answer, and the request at hand keeps its place in the lane.
            if open.contains(need) {
                endedAtHand = nil
                choose(need)
            } else if needs.contains(where: { $0.id == need }) {
                endedAtHand = need
            }
        }
        // Another hub, or another generation of this one: its requests have their own numbers, and nothing that the
        // page kept by a number is theirs.
        .onChange(of: "\(store.hub.absoluteString) \(state?.db ?? "")") { _, _ in
            sent = [:]; confirmed = [:]; memory = [:]; order = []; endedAtHand = nil; writes = false
            settling = []; took = []; his = []; leaves = false
        }
        // The choice is the page's while it shows. The next visit starts at the lane's first request, unless
        // something chose one for it; a choice of an earlier visit would count as such a choice.
        .onDisappear { store.selectedNeed = nil }
        // An answer that the reading has is on its way no more, and what he left open in that request goes with it.
        .onChange(of: needs.filter(\.isOpen).map(\.id)) { _, waiting in
            sent = sent.filter { waiting.contains($0.key) }
            confirmed = confirmed.filter { waiting.contains($0.key) }
            memory = memory.filter { waiting.contains($0.key) }
            took = took.filter { waiting.contains($0) || settling.contains($0) }
        }
        // A request that something else chose (a task's orange line on the Tasks board, a notification) comes to hand;
        // one that ended shows with its answer.
        .onChange(of: store.selectedNeed) { _, asked in
            guard asked != settled else { return }
            writes = false
            endedAtHand = asked.flatMap { id in !open.contains(id) && needs.contains { $0.id == id } ? id : nil }
            choose(NeedsLane.atHand(chosen: asked, order: order, open: open))
        }
        .background { PageKeys { keys($0, open: open, hand: atHand?.id, shows: ended == nil) } }
        .accessibilityIdentifier("needs-board")
    }

    /// His answer to `need` on its way: as the store says it (`WordsOnTheirWay`), else the one that the hub confirmed,
    /// on this hub and generation, while the reading still has the request open.
    private func onItsWay(_ need: OwnerNeed) -> PendingRequest? {
        if let request = store.answerOnItsWay(to: need, kept: sent[need.id]) { return request }
        guard need.isOpen, let request = confirmed[need.id], request.hub == store.hub,
              request.database == store.state?.db else { return nil }
        return request
    }

    /// Writes the page's choice to the store, and keeps it, so that the store's change is known as the page's own.
    private func choose(_ need: Int?) {
        settled = need
        if store.selectedNeed != need { store.selectedNeed = need }
    }

    /// **The lane changed: the request at hand is one that waits** (`NeedsLane.atHand`).
    /// - His answer took the request at hand out of the lane: the one that stood under it comes to hand.
    /// - **The request at hand ended in another way** (the manager took it back or replaced it, or he answered it on
    ///   his phone): **it stays at hand, with its answer**, and nothing comes into its place under his pointer and his
    ///   keys. He goes on with a click on a card or with Down. A request for a key is the one exception: its own form
    ///   answers it here, with no saved request to tell it by, so the next request comes.
    private func settle(_ lane: [Int], needs: [OwnerNeed]) {
        let chosen = store.selectedNeed
        let next = NeedsLane.atHand(chosen: chosen, order: order, open: lane)
        if let chosen, order.isEmpty, !lane.contains(chosen), needs.contains(where: { $0.id == chosen }) {
            // The page opens on a request that something chose for it and that ended: a notification that he
            // clicks after he answered on his phone. (The page's own choice goes when the page goes.)
            endedAtHand = chosen
        } else if let chosen, order.contains(chosen), !lane.contains(chosen) {
            // His answer here sent it away, and the reading can have that answer already: it is no request that
            // ended in another way.
            if !his.contains(chosen), let left = needs.first(where: { $0.id == chosen }), !left.isOpen, !left.asksForSecret {
                endedAtHand = chosen
            } else if let next, let title = needs.first(where: { $0.id == next })?.title {
                // VoiceOver's focus was on what he pressed, which left: it hears what stands there now.
                AccessibilityNotification.Announcement(title).post()
            }
        }
        order = lane
        choose(next)
    }

    /// A click on a request's card puts it at hand.
    private func pick(_ need: Int) {
        endedAtHand = nil
        writes = false
        choose(need)
    }

    /// **His answer to `need` goes: the request stays at hand for a moment, and then leaves** (`settling`).
    /// - At once: the answer stands where he gave it, with a check that draws itself (`NeedAnswered`).
    /// - After 0.3 s: the agent took it (`took`).
    /// - After 0.78 s: the request leaves the lane, as it did in the frame of the answer before, and the next one comes.
    /// **An answer that waits for the hub shows no answer yet, so nothing settles** (review of 11 November 2026): a
    /// press while the hub cannot take a write starts no moment, and its request leaves when the answer goes. An
    /// answer that is not on its way after 0.3 s (a door call waits for its signature) gets no jump, and one that is
    /// not on its way when the moment ends is not his answer yet: the request is as it was.
    private func hold(_ need: Int) {
        guard !reduceMotion, store.canWrite else { return }
        settling.insert(need)
        his.insert(need)
        leaves = true
        holds += 1
        let mine = holds
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            if settling.contains(need), went(need) { took.insert(need) }
            try? await Task.sleep(for: .milliseconds(480))
            if !went(need) { his.remove(need); took.remove(need) }
            settling.remove(need)
            // The rise and the drawn mark are for the request that comes now, not for a click on a card after it.
            try? await Task.sleep(for: .milliseconds(600))
            if holds == mine { leaves = false }
        }
    }

    /// His answer to `need` is on its way, or the reading has it.
    private func went(_ need: Int) -> Bool {
        sent[need] != nil || confirmed[need] != nil || store.state?.needs.first { $0.id == need }?.isOpen == false
    }

    /// **The page's keys** (`PageKeys`: while no field has the cursor and no menu is open): Up and Down move through
    /// the lane, and every other key is the answer box's of the request at hand (`StepKeys`). Return on a task's card
    /// that has the keyboard's focus is that card's.
    private func keys(_ event: NSEvent, open: [Int], hand: Int?, shows: Bool) -> Bool {
        if move(event, open: open, hand: hand) { return true }
        if focusedTask != nil, event.keyCode == 36 || event.keyCode == 76 { return false }
        // A request that ended stands in view: the request at hand, which does not show, takes no key.
        guard shows, let hand else { return false }
        // **A key while his answer settles ends that moment** (review of 11 November 2026): the next request comes
        // at once, and the key is not one of the request that he answered, whose box still fades.
        if settling.remove(hand) != nil { return true }
        return stepKeys.take(event, for: hand)
    }

    /// Up and Down move through the lane. From a request that ended, the first press goes back to the request at hand.
    private func move(_ event: NSEvent, open: [Int], hand: Int?) -> Bool {
        guard !event.modifierFlags.contains(.shift) else { return false }
        let by: Int
        switch event.specialKey {
        case .downArrow?: by = 1
        case .upArrow?: by = -1
        default: return false
        }
        guard !open.isEmpty else { return false }
        writes = false
        if endedAtHand != nil { endedAtHand = nil; return true }
        // From the request at hand in the lane: the store's choice can be a request that the lane has no more.
        let at = hand.flatMap(open.firstIndex(of:)) ?? 0
        choose(open[min(max(at + by, 0), open.count - 1)])
        return true
    }

    // MARK: the lane

    /// The lane: its heading with its count, the cards of the requests that wait, the cards of the tasks that only he
    /// can move, and the row that opens the requests that ended. It scrolls by itself, as a lane of the Tasks board.
    private func cards(_ lane: NeedsLane, tasks: [FleetTask], atHand: Int?, state: HubState?, now: Double) -> some View {
        let waits = state?.needWaits ?? [:]
        let owner = state?.ownerWaits ?? [:]
        return VStack(alignment: .leading, spacing: FleetSpace.inside) {
            // The heading of a lane of the Tasks board (`ActivityBoard.lane`): 2 points in, in the 28-point heading row.
            HStack(spacing: 6) {
                Text("Open").font(FormMetrics.heading).foregroundStyle(FleetStyle.text)
                Text("\(lane.open.count + tasks.count)").font(FormMetrics.detail).monospacedDigit().foregroundStyle(FleetStyle.muted)
                    .rolls(lane.open.count + tasks.count)
            }.frame(minHeight: FormMetrics.headingRow).padding(.leading, 2)
                .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        // **Each row of the lane has a key of its own kind** (`LaneKey`): a request's card, a task's card
                        // and a request's row all have a number as their id, and the lane keeps a row's view by its
                        // key. With the numbers alone, a request that he answered while its list was open kept its
                        // card where its row came to stand.
                        ForEach(lane.open, id: \.cardKey) { need in
                            NeedCard(need: need, selected: need.id == atHand, waits: waits[need.id] ?? [],
                                     took: took.contains(need.id)) { pick(need.id) }
                                .transition(.opacity)
                        }
                        // A task that only he can move, as its card of the Tasks board: its orange words say what it
                        // waits for, and a click opens the task.
                        ForEach(tasks, id: \.cardKey) { task in
                            let words = owner[task.id]?.words
                            ActivityCard(task: task, owner: task.owner, ownerLine: words, why: nil,
                                         words: words ?? task.stateWord(in: state), openRequest: nil) {
                                store.destination = .task(task.id)
                            }.opensTask(task.id, store: store).focused($focusedTask, equals: task.id)
                        }
                        if lane.endedCount > 0 { endedRows(lane, now: now) }
                    }
                    .padding(.bottom, FleetSpace.bottom)
                    // A card that leaves fades, and the cards under it move up to its place.
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: lane.open.map(\.id))
                }
                // The card of the request at hand is in view: when the page opens on a request that something chose, and
                // when a key moves it.
                .onChange(of: atHand, initial: true) { _, id in if let id { reader.scrollTo(LaneKey.card(id)) } }
            }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("needs-lane")
    }

    /// **The requests that ended, behind one row** that counts them, by day, as the tasks behind "110 more" on the
    /// Tasks board: a row is the request's title with its agent's glyph, and a click shows the request with its answer.
    @ViewBuilder private func endedRows(_ lane: NeedsLane, now: Double) -> some View {
        Button {
            showsEnded.toggle()
            if !showsEnded { endedAtHand = nil }
        } label: {
            HStack(spacing: 6) {
                Text("\(lane.endedCount) answered").rolls(lane.endedCount)
                Image(systemName: "chevron.right").font(IconMetrics.symbol(9, weight: .semibold))
                    .rotationEffect(.degrees(showsEnded ? 90 : 0))
                Spacer(minLength: 0)
            }
            .font(FormMetrics.text).foregroundStyle(FleetStyle.muted)
            .padding(.horizontal, EndedRow.inset).frame(minHeight: EndedRow.height).contentShape(Rectangle())
        }
        .buttonStyle(FleetRowButtonStyle())
        .accessibilityValue(showsEnded ? "Open" : "Closed").accessibilityIdentifier("needs-ended-more")
        if showsEnded {
            ForEach(lane.ended, id: \.key) { day in
                Text(ActivityBoard.dayWords(day.start, now: now)).font(FormMetrics.detailTitle).foregroundStyle(FleetStyle.muted)
                    .padding(.leading, EndedRow.inset).frame(minHeight: FormMetrics.headingRow, alignment: .bottomLeading)
                    .accessibilityAddTraits(.isHeader)
                ForEach(day.needs, id: \.endedKey) { need in
                    EndedRow(title: need.title, owner: need.by, selected: endedAtHand == need.id) { endedAtHand = need.id }
                        .accessibilityIdentifier("needs-ended-\(need.id)")
                }
            }
        }
    }

    // MARK: the request at hand

    private static let rise = AnyTransition.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)),
                                                       removal: .opacity.combined(with: .offset(y: -8)))

    /// The request at hand, beside the lane: it scrolls by itself when it is higher than the window, and a request
    /// that takes its place fades in where it stood. `empty`: the lane has no card at all, so the page says so.
    private func stage(_ need: OwnerNeed?, onItsWay: PendingRequest?, waits: [String], now: Double, empty: Bool) -> some View {
        ZStack(alignment: .top) {
            if let need {
                ScrollView {
                    NeedStep(store: store, need: need, onItsWay: onItsWay, waits: waits, now: now,
                             memory: Binding(get: { memory[need.id] ?? StepMemory() }, set: { memory[need.id] = $0 }),
                             keys: stepKeys, takesCursor: writes,
                             settles: settling.contains(need.id) && (onItsWay != nil || !need.isOpen),
                             took: took.contains(need.id)) { typed in
                        writes = typed
                        hold(need.id)
                    }
                        .padding(.top, Self.stepTop).padding(.bottom, 56).frame(maxWidth: .infinity)
                }
                // A request that his answer sent away goes 8 points up as it fades, and the next one comes from 8
                // points under its place. A click on a card and the arrows only fade, as before.
                .id(need.id).transition(leaves ? Self.rise : .opacity)
            } else if empty {
                // The page's own words for a day with no request, where a request stands; not beside a task's card,
                // which needs him too. **Its mark draws itself when his answer sent the last request away.**
                FormEmpty("Nothing needs you", symbol: "checkmark.circle", draws: leaves).padding(.top, Self.stepTop)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: need?.id)
    }
}

/// **What he left open in one request, while the page shows**: Details, Discuss, and the words of his next message in
/// it. They were the step's own, so a look at another request and back closed Details and lost a question that he was
/// writing.
struct StepMemory: Equatable {
    /// Details, or the whole of a long reason, shows.
    var expanded = false
    /// Owner feature `need_talk` (API 1.106): Discuss is open.
    var discussing = false
    /// The words of his next message in the discussion.
    var talk = ""
}

/// **The keys of the request at hand, which its answer box gives the page.** The page has one watch on the window's
/// keys (`PageKeys`), and it passes a number, Return or Escape to the box of the request that is at hand, by the
/// request's number. During the fade from one request to the next both boxes stand in the window: with a watch each,
/// the box of the request that he had just answered could take his next keys (review of 11 November 2026).
@MainActor final class StepKeys {
    private var boxes: [Int: (owner: ObjectIdentifier, take: (NSEvent) -> Bool)] = [:]

    func set(_ need: Int, owner: AnyObject, take: @escaping (NSEvent) -> Bool) { boxes[need] = (ObjectIdentifier(owner), take) }

    /// The box of `need` went: its keys go with it, unless a newer box of the same request has them.
    func clear(_ need: Int, owner: AnyObject) {
        if boxes[need]?.owner == ObjectIdentifier(owner) { boxes[need] = nil }
    }

    func take(_ event: NSEvent, for need: Int) -> Bool { boxes[need]?.take(event) ?? false }
}

/// The place where an answer box gives its keys to the page (`StepKeys`): with each change of what the box shows, so
/// that the keys act on the request and the marks as they are now. It draws nothing and takes no click.
struct StepKeysBox: NSViewRepresentable {
    let keys: StepKeys
    let need: Int
    let take: (NSEvent) -> Bool

    /// What the box registered, to take it away when the box goes.
    final class Coordinator {
        var keys: StepKeys?
        var need: Int?
    }

    private final class Quiet: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var acceptsFirstResponder: Bool { false }
        override var canBecomeKeyView: Bool { false }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { Quiet() }

    func updateNSView(_ view: NSView, context: Context) {
        if let old = context.coordinator.need, old != need { context.coordinator.keys?.clear(old, owner: context.coordinator) }
        context.coordinator.keys = keys
        context.coordinator.need = need
        keys.set(need, owner: context.coordinator, take: take)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let need = coordinator.need { coordinator.keys?.clear(need, owner: coordinator) }
    }
}

/// The key of one row of the lane: its kind and its number. A request's card, a task's card, a day's heading and a
/// request's row each have a number of their own, and two of them can be the same number.
private enum LaneKey: Hashable {
    case card(Int), task(Int), day(Double), ended(Int)
}

private extension OwnerNeed {
    /// Its card in the lane, while it waits.
    var cardKey: LaneKey { .card(id) }
    /// Its row under the day it ended.
    var endedKey: LaneKey { .ended(id) }
}

private extension FleetTask {
    var cardKey: LaneKey { .task(id) }
}

private extension NeedsLane.Day {
    var key: LaneKey { .day(start) }
}

/// **One request that waits, in the lane of Needs you**: its title, and under it the agent that asks, as a task's card
/// on the Tasks board is its title and its agent (the owner, 11 November 2026: "I like simple things! not too much
/// information!"). **An orange hourglass at the end of the agent's line where an agent's work waits for the answer**
/// (`HubState.needWaits`): a mark only where there is something to tell, with the agent's name behind it on hover. The
/// card of the request at hand is a little lighter.
private struct NeedCard: View {
    let need: OwnerNeed
    /// The request at hand.
    let selected: Bool
    /// The agents whose work waits for its answer.
    let waits: [String]
    /// The agent took his answer a moment ago: the hourglass is out (`NeedsBoard.took`).
    var took = false
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        let waiting = NeedsLane.waitWords(waits)
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                Text(need.title).font(FormMetrics.title).foregroundStyle(FleetStyle.text).lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    // The glyph with its dot, as everywhere it stands for the agent (D-8 item 2).
                    AgentGlyph(name: need.by, size: GlyphSize.inline, ground: selected ? FleetStyle.bubble : FleetStyle.surface)
                    Text(need.by.agentLabel).lineLimit(1)
                    Spacer(minLength: 4)
                    if !waits.isEmpty && !took {
                        // Orange is what needs him (D-8): here, the answer that stops work.
                        Image(systemName: "hourglass").font(IconMetrics.symbol(11, weight: .medium)).foregroundStyle(.orange)
                            .help(waiting).accessibilityHidden(true).transition(.goesOut)
                    }
                }
                .animation(.easeOut(duration: 0.25), value: took)
            }
            .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
            .modifier(BoardCardLook(selected: selected, hovered: hovered))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(waits.isEmpty ? need.title : "\(need.title)\n\(waiting)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([need.title, need.by.agentLabel, waits.isEmpty ? nil : waiting].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        // The element stands for the button, so it has the button's press (`ActivityCard`).
        .accessibilityAction(.default, open)
        .accessibilityIdentifier("need-card-\(need.id)")
    }
}

/// **The request at hand, in the big layout of a setup step** (the owner, 11 November 2026: "I really like the big
/// layout for the decision at hand"): the glyph of the agent that asks, its name and when it asked, the request's title
/// at the step's 22 points, the reason at its 15, and under them what he answers with — the agent's options, Your
/// answer, or the secure form of a key or a login. Details opens the long part. Discuss, a quiet link under the
/// answers, opens his discussion of the request with the manager.
///
/// **Its words are drawn as a message's are** (`MessageText`): a link is a link and code is code. They were plain
/// text, so a request showed its backticks and an address that he could not press.
///
/// A request that ended shows the same head, and his answer in the place of the answers.
private struct NeedStep: View {
    @Bindable var store: FleetStore
    let need: OwnerNeed
    /// His answer on its way, for a request that the reading still has open: it shows as answered, with his words.
    let onItsWay: PendingRequest?
    /// The agents whose work waits for the answer.
    let waits: [String]
    /// The hub's time, for the words of when it asked.
    let now: Double
    /// What he left open in this request (`StepMemory`): the page keeps it while he looks at another request.
    @Binding var memory: StepMemory
    /// The page's keys for the answer box (`StepKeys`).
    let keys: StepKeys
    /// He writes: the field of Your answer takes the cursor as the request comes to hand (`NeedsBoard.writes`).
    let takesCursor: Bool
    /// His answer went from here a moment ago and settles: it stands with a check that draws itself (`NeedsBoard.hold`).
    var settles = false
    /// The agent took that answer: its glyph makes its one jump, and the hourglass is out.
    var took = false
    /// An answer went: true when it went from the field.
    let answered: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where the answer that he gave stood under the top of the answers: his answer moves from there to the top, as
    /// the other answers go.
    @State private var answerTop: CGFloat = 0

    private var expanded: Bool { memory.expanded }

    private var ended: Bool { !need.isOpen || onItsWay != nil }
    /// What it needs from him. A secret request's is the hub's one sentence about its form, which is right below it.
    private var todo: String { need.asksForSecret ? "" : need.todo }
    /// A reason of one or two sentences, shown whole (`NeedTalk.why`); a longer one, of a request for a key or of an
    /// item from before the rule, shows its first three lines until Show all.
    private var short: Bool { need.details != nil || need.why.count <= NeedTalk.why }
    private var hasMore: Bool { need.details != nil || !short || !todo.isEmpty }
    /// Discuss, apart from his answer: an open item that is no conversation's question, on a hub that takes it.
    private var discussable: Bool {
        !ended && need.conversation == nil && store.state?.ui_features?.contains(NeedTalk.feature) == true
    }
    /// A reason of one paragraph stands in the middle, as a step's line does; a list or several paragraphs read from
    /// their leading edge.
    private var centred: Bool {
        guard need.why.count <= NeedTalk.why else { return false }
        let blocks = MessageBlock.parse(need.why)
        return blocks.count == 1 && blocks[0].kind == .paragraph
    }

    var body: some View {
        VStack(spacing: 0) {
            // The step's mark is its subject, not a status: the glyph draws no dot here (`SetupStep`).
            AgentGlyph(name: need.by, size: SetupMetrics.mark, jumps: took).environment(\.glyphDots, false)
            from.padding(.top, 14)
            Text(need.title).font(SetupMetrics.titleFont).foregroundStyle(FleetStyle.text)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .accessibilityAddTraits(.isHeader).padding(.top, 14)
            why.padding(.top, 12)
            if hasMore { moreLink.padding(.top, 10) }
            if expanded, need.details != nil || !todo.isEmpty { more.padding(.top, 14) }
            answers.padding(.top, 24)
        }
        .frame(maxWidth: SetupMetrics.cardsWidth)
        // What stands under the title takes the step's one size (`stepText`): the options, the form, the buttons.
        .environment(\.stepText, SetupMetrics.text)
        .environment(\.fleetButtonText, SetupMetrics.text)
        .accessibilityElement(children: .contain).accessibilityIdentifier("need-step-\(need.id)")
    }

    /// Who asks, by the name the sidebar gives it, and when; and the hourglass of a request that stops work.
    private var from: some View {
        HStack(spacing: 6) {
            Text("\(need.by.agentLabel) · \(activityAge(need.raised, now: now))")
            if !waits.isEmpty && !took {
                let waiting = NeedsLane.waitWords(waits)
                Image(systemName: "hourglass").font(IconMetrics.symbol(11, weight: .medium)).foregroundStyle(.orange)
                    .help(waiting).accessibilityLabel(waiting).transition(.goesOut)
            }
        }.font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
            .animation(.easeOut(duration: 0.25), value: took)
    }

    @ViewBuilder private var why: some View {
        if short || expanded {
            MessageText(text: need.why, step: true).foregroundStyle(FleetStyle.text)
                .multilineTextAlignment(centred ? .center : .leading)
                .frame(maxWidth: .infinity, alignment: centred ? .center : .leading)
        } else {
            // The start of a long reason, on three lines, until Show all.
            Text(MessageBlock.inline(need.why.components(separatedBy: .newlines).joined(separator: " ")))
                .font(SetupMetrics.textFont).foregroundStyle(FleetStyle.text).lineSpacing(5).tint(FleetStyle.link)
                .lineLimit(3).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Details, with its chevron, where the reason shows whole and the link opens what stands under it; Show all and
    /// Show less on a long reason, which the link itself opens.
    private var moreLink: some View {
        Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) { memory.expanded.toggle() } } label: {
            HStack(spacing: 3) {
                // the door's card shows its script there, as the owner approved it ("Yes, as shown")
                Text(short ? (need.door_host != nil && need.details != nil ? "Script" : "Details")
                     : expanded ? "Show less" : "Show all")
                if short {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(IconMetrics.symbol(10, weight: .semibold))
                }
            }.padding(.vertical, IconMetrics.reach).contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.vertical, -IconMetrics.reach).font(SetupMetrics.textFont).foregroundStyle(FleetStyle.link)
            .accessibilityValue(expanded ? "Open" : "Closed").accessibilityIdentifier("need-more-\(need.id)")
    }

    /// The long part of the request and what it needs from him: read from their leading edge, as a text is.
    private var more: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The door's card wraps its script (API 1.125): no end of a line is off the screen when Script is open.
            if let details = need.details {
                MessageText(text: details, step: true, script: need.door_script != nil).foregroundStyle(FleetStyle.text)
            }
            if !todo.isEmpty {
                Text("What it needs from you").font(.system(size: SetupMetrics.text, weight: .medium)).foregroundStyle(FleetStyle.muted)
                MessageText(text: todo, step: true).foregroundStyle(FleetStyle.text)
            }
        }
        .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What he answers with, and Discuss under it; for a request that ended, what he answered.
    private var answers: some View {
        VStack(spacing: 18) {
            if ended {
                NeedAnswered(store: store, need: need, words: onItsWay?.text, draws: settles)
                    // His answer moves up from where he gave it, as the other answers go.
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: answerTop)), removal: .opacity))
            } else {
                Group {
                    if need.asksForSecret { SecretRequestForm(store: store, need: need) }
                    else {
                        NeedAnswerBox(store: store, need: need, keys: keys, takesCursor: takesCursor) { typed, top in
                            answerTop = top
                            answered(typed)
                        }
                    }
                }
                .transition(.opacity)
                // Owner feature attachments: a file dropped on an open request is staged in its answer.
                .stageDroppedFiles(store: store, composer: need.takesFiles ? FleetStore.stageKey(need: need.id) : nil, mark: true)
                if discussable {
                    if memory.discussing || !(need.talk ?? []).isEmpty {
                        NeedDiscussion(store: store, need: need, draft: $memory.talk)
                    } else {
                        SetupLink("Discuss") { memory.discussing = true }.accessibilityIdentifier("need-discuss-\(need.id)")
                            .transition(.opacity)
                    }
                }
            }
        }
        // Only the answer that settles moves: a request that ended in another way changes in one step, as before.
        .animation(settles ? .easeOut(duration: 0.22) : nil, value: ended)
    }
}

/// What he answered, under a request that ended: a check and his words, or the option he pressed, whole, as the folded
/// card of an answered request says it on one line (`NeedRequestCard`); and the files that went with them.
private struct NeedAnswered: View {
    @Bindable var store: FleetStore
    let need: OwnerNeed
    /// His words on their way, before the reading has them.
    let words: String?
    /// He answered a moment ago, here: the check draws itself, white, and then goes quiet (`NeedsBoard.hold`).
    var draws = false
    @Environment(\.colorSchemeContrast) private var contrast
    /// The check shows: at once, or 0.11 s after the answer began to move, when it draws.
    @State private var drawn = false
    /// The check went quiet: it begins 0.42 s after his answer, when it is drawn.
    @State private var quiet = false

    private var files: [MessageAttachment] {
        store.state?.messages.last { $0.need_id == need.id }?.attachments ?? []
    }

    var body: some View {
        let answer = (words ?? need.answer)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                check
                Text(answer.isEmpty ? "Answered" : answer).font(SetupMetrics.textFont).foregroundStyle(FleetStyle.text)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            .accessibilityElement(children: .combine).accessibilityLabel("Answered: \(answer.isEmpty ? "Answered" : answer)")
            if !files.isEmpty { MessageFilesView(store: store, files: files, alignment: .leading) }
        }
        .padding(.horizontal, 14).padding(.vertical, 11).frame(maxWidth: .infinity, minHeight: FormMetrics.row, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: FormMetrics.inner)
            .strokeBorder(FleetStyle.hairline(0.10), lineWidth: FleetStyle.edgeWidth(contrast)))
        .accessibilityElement(children: .contain).accessibilityIdentifier("need-answered-\(need.id)")
        .task {
            guard draws, !drawn else { drawn = true; quiet = true; return }
            try? await Task.sleep(for: .milliseconds(110))
            withAnimation(.easeOut(duration: 0.26)) { drawn = true }
            // Muted before the request leaves, 0.78 s after his answer.
            try? await Task.sleep(for: .milliseconds(310))
            withAnimation(.easeOut(duration: 0.3)) { quiet = true }
        }
    }

    /// The check before his answer. It keeps its place while it is not drawn yet, so the words do not move.
    @ViewBuilder private var check: some View {
        let mark = Image(systemName: "checkmark").font(IconMetrics.symbol(12, weight: .semibold))
            .foregroundStyle(draws && !quiet ? Color.white : FleetStyle.muted).accessibilityHidden(true)
        if !draws {
            mark
        } else {
            mark.hidden().overlay { if drawn { mark.transition(.drawsOn) } }
        }
    }
}

extension AnyTransition {
    /// A symbol draws itself, stroke by stroke, where the system can (macOS 26); before that it fades in.
    static var drawsOn: AnyTransition {
        if #available(macOS 26, *) { AnyTransition(.symbolEffect(.drawOn)) } else { .opacity }
    }

    /// The hourglass of a request that he answered: it goes out, a little smaller.
    static var goesOut: AnyTransition { .asymmetric(insertion: .identity, removal: .opacity.combined(with: .scale(scale: 0.6))) }
}

extension View {
    /// A count that changes rolls to its new number, as the system's counters do; not under Reduce Motion.
    func rolls(_ count: Int) -> some View { modifier(Rolls(count: count)) }
}

private struct Rolls: ViewModifier {
    let count: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.contentTransition(.numericText(value: Double(count)))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: count)
    }
}

/// **A page's own keys**: a watch on its window's keys while the page shows, with no view he can reach and no menu
/// item, as the agents' keys are (`AgentKeys`). It gives the page a key only when the key is the page's to take: with
/// no Command, Option or Control, in this window while it is the key window, with no sheet over it and none of the
/// app's own menus open (a `FleetMenu` reads its arrows and its Return while this window stays the key window), **and
/// while no field has the cursor**, so a number or an arrow that he types into a field stays that field's.
/// **Escape in a field gives the keys back to the page**: the cursor leaves the field, and nothing else did that — a
/// click on a card does not take the cursor, so after one Return into Your answer the arrows moved nothing.
struct PageKeys: NSViewRepresentable {
    /// Takes a key that is the page's: true when it did, and the key then goes no further.
    let take: (NSEvent) -> Bool

    func makeNSView(context: Context) -> Watch { Watch() }

    func updateNSView(_ view: Watch, context: Context) { view.take = take }

    static func dismantleNSView(_ view: Watch, coordinator: ()) { view.stop() }

    final class Watch: NSView {
        var take: (NSEvent) -> Bool = { _ in false }
        private var monitor: Any?

        // Nothing here takes a click, the keyboard's focus or a Tab stop.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var acceptsFirstResponder: Bool { false }
        override var canBecomeKeyView: Bool { false }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let watch = self else { return event }
                // The monitor runs on the main thread, before the window's own key equivalents.
                let taken = MainActor.assumeIsolated { watch.leavesField(event) || (watch.mine(event) && watch.take(event)) }
                return taken ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// Escape in a field of this window, with no text of an input method in the making: the cursor leaves the field.
        private func leavesField(_ event: NSEvent) -> Bool {
            guard event.keyCode == 53, let window, event.window === window, window.isKeyWindow, window.attachedSheet == nil,
                  !FleetMenu.isOpen, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  let field = window.firstResponder as? NSTextView, !field.hasMarkedText() else { return false }
            window.makeFirstResponder(nil)
            return true
        }

        /// The key is one that a page may take.
        private func mine(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, window.isKeyWindow, window.attachedSheet == nil, !FleetMenu.isOpen,
                  event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
            // A field has the cursor (its editor is the first responder): the key is its.
            return !(window.firstResponder is NSText)
        }
    }
}
