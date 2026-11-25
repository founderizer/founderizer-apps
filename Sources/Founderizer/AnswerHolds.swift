import AppKit
import FleetCore
import Foundation
import SwiftUI

/// **His answer waits 5 seconds on its card, with Undo, before it goes** (the owner, 21 November 2026: "Sometimes I can
/// make a mistake replying to a card... we need a way to be able to UNDO very easily", and his "Yes, 5 seconds
/// (Recommended)" to its picture: "Nothing goes to the hub until the 5 seconds end. A click on Undo opens the card again
/// as it was."). Each answer that a card sends waits here first, whole, and then goes on the path that it took before:
/// an option's press (`AnswerWaits`, with a door call's signature and a Give), the ticked options, a reply that he
/// pressed (its words, which never stand in his box), and his words with their files. Nothing of it reaches the hub
/// during the hold, so the hub has no part in it. The card of a key or a login keeps its own form (a held secret would
/// stay in memory and in a view), and a message under a card (Needs clarification) is no answer.
///
/// **One held answer for the whole app** (the owner's F12 of 22 November 2026: "complete it immediately ... and include
/// a button link to undo"): his next answer, on any card, sends the one before it at once (`hold`), so Undo is for his
/// last answer only, and a quit has at most one held answer to send. An answer whose press still waits behind another
/// request of the outbox at a quit is not sent, as a press that waits for the hub is not (`settle`): its request stays
/// open on the hub. The card in a chat, on Needs you and in its own window read the same hold. Meanwhile the card
/// stands folded with his answer, as an answer on its way does (`shown`). A hold of another hub or generation, or of a
/// request that closed meanwhile, shows nowhere, and its press finds that when it goes, as a press that waited does.
///
/// **A hold knows its place** (`Place`): the page of the main window where he gave it, the card's own window, which
/// becomes its badge, or a card that is on neither (the job's detail card). **A hold whose place is a page keeps its 5 seconds on every page of
/// the main window**, where its badge stands at the foot of the sidebar and its Undo brings the card back (`AnswerBadge`;
/// the owner's F22-1 (a), 23 November 2026), **and goes at once when the main window closes** (`watchMainWindow`). **A
/// quit, an update's restart and the close of the card's own window send what waits at once** (`releaseAll`,
/// `release`): his answer is not lost by an act that is not Undo.
@MainActor @Observable final class AnswerHolds {
    static let shared: AnswerHolds = {
        let holds = AnswerHolds()
        holds.watchMainWindow()
        return holds
    }()

    /// **Where a held answer stands**: a page of the main window (`Destination.page` at his press), the card's own
    /// window (`NeedWindows`, which becomes the badge of it: the owner's F22-2 (a), 23 November 2026), or a card that is
    /// on no page and in no window of its own (the job's detail card).
    enum Place: Equatable, Sendable {
        case page(String)
        case window
        case card
    }

    /// How long an answer waits: 5 seconds (his "Yes, 5 seconds"). A test shortens it.
    var wait: Duration = .seconds(5)

    /// One answer that waits.
    struct Held {
        let hub: URL
        let database: String
        /// Where he gave it (`Place`).
        let place: Place
        /// What the card shows meanwhile: the answer, as an answer on its way shows (never saved, never sent).
        let shown: PendingRequest
        /// The options that he had ticked, which Undo ticks again (`restored`).
        let ticked: Set<Int>
        fileprivate let mark: UUID
        fileprivate weak var store: FleetStore?
        fileprivate let go: @MainActor () async -> Void
    }

    /// A press that the end of a hold started, until it ends.
    private struct Going {
        let task: Task<Void, Never>
        weak var store: FleetStore?
    }

    private(set) var held: [Int: Held] = [:]
    /// **The answers whose wait ended and whose press runs now**: the card shows them as on their way until the press
    /// has ended (`leaving`), so it does not open for a moment between the end of the wait and the outbox (review).
    private var gone: [Int: Held] = [:]
    private var waits: [Int: Task<Void, Never>] = [:]
    /// The presses that the end of a hold started and that have not ended: a quit waits for them (`settle`).
    private var going: [UUID: Going] = [:]
    /// The options to tick again on a card whose answer he took back, until its box has taken them (`restoredTicks`).
    private var restored: [Int: Set<Int>] = [:]
    /// **His last Undo**: the request whose answer he took back, and a mark of that press, so that Needs you puts that
    /// request at hand again with none of the marks of its leave (`NeedsBoard`).
    private(set) var undone: Undone?

    struct Undone: Equatable {
        let need: Int
        /// Where the answer that he took back waited: Needs you puts its request at hand only for its own.
        let place: Place
        let mark: UUID
    }

    /// An answer of his waits, or a press is on its way out of a hold.
    var busy: Bool { !held.isEmpty || !going.isEmpty }

    /// **His press waits** `wait`, and then `go` does it. **The answer that waited on another request goes at once**:
    /// one held answer for the whole app. A second press on the same request while one waits takes its place: the card
    /// is folded meanwhile, so only a key can make one. `place`: where he gave it (`Place`).
    func hold(_ need: OwnerNeed, store: FleetStore, place: Place = .card, shown: PendingRequest, ticked: Set<Int> = [],
              go: @escaping @MainActor () async -> Void) {
        guard let database = store.state?.db else { return }
        for other in held.keys.sorted() where other != need.id { release(other) }
        waits[need.id]?.cancel()
        let mark = UUID()
        held[need.id] = Held(hub: store.hub, database: database, place: place, shown: shown, ticked: ticked, mark: mark,
                             store: store, go: go)
        let wait = wait
        waits[need.id] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: wait) } catch { return }
            guard let self, self.held[need.id]?.mark == mark else { return }
            self.release(need.id)
        }
    }

    /// **The main window closed: an answer held on one of its pages goes at once.** The card's own window and a quit have
    /// their own sends (`release`, `releaseAll`).
    private func watchMainWindow() {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            // the window that closes, read on the main queue that this watch runs on
            nonisolated(unsafe) let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard window?.identifier?.rawValue == SetupChannel.fleetWindow else { return }
                for (need, taken) in AnswerHolds.shared.held {
                    if case .page = taken.place { AnswerHolds.shared.release(need) }
                }
            }
        }
    }

    /// The answer that waits on `need`, on the hub and generation that the store reads and while the request is open
    /// there; nil where none does.
    func held(_ need: OwnerNeed, in store: FleetStore) -> Held? {
        guard let held = held[need.id], held.hub == store.hub, held.database == store.state?.db,
              store.openNeeds.contains(where: { $0.id == need.id }) else { return nil }
        return held
    }

    /// **The held answer of a page of the main window** (`AnswerBadge`, at the foot of the sidebar on every page): the
    /// one whose place is a page, with its request, on the hub and generation that the store reads, while that request
    /// is open there; nil where none is.
    func onAnyPage(in store: FleetStore) -> (need: OwnerNeed, held: Held)? {
        for (id, taken) in held {
            guard case .page = taken.place else { continue }
            if let need = store.openNeeds.first(where: { $0.id == id }), held(need, in: store) != nil { return (need, taken) }
        }
        return nil
    }

    /// The page where he gave the answer that waits on `need`, for the badge's Undo, which brings the card back there.
    func pageOf(_ need: OwnerNeed) -> String? {
        if case .page(let page)? = held[need.id]?.place { return page }
        return nil
    }

    /// The answer of `need` whose press runs now, after its wait, as `held` says it: the card shows it as on its way.
    func leaving(_ need: OwnerNeed, in store: FleetStore) -> Held? {
        guard let held = gone[need.id], held.hub == store.hub, held.database == store.state?.db,
              store.openNeeds.contains(where: { $0.id == need.id }) else { return nil }
        return held
    }

    /// **Undo**: the answer goes nowhere, and the card opens as it was, with the options that he had ticked
    /// (`restoredTicks`). His own words and his files stayed in the box: no answer writes there.
    func undo(_ need: OwnerNeed, store: FleetStore) {
        guard let taken = held(need, in: store) else { return }
        waits.removeValue(forKey: need.id)?.cancel()
        held[need.id] = nil
        if !taken.ticked.isEmpty { restored[need.id] = taken.ticked }
        undone = Undone(need: need.id, place: taken.place, mark: UUID())
    }

    /// The options that a box ticks again as it comes, once: those of an answer that he took back.
    func restoredTicks(of need: Int) -> Set<Int> { restored.removeValue(forKey: need) ?? [] }

    /// The answer that waits on this request goes now.
    func release(_ need: Int) {
        waits.removeValue(forKey: need)?.cancel()
        guard let taken = held.removeValue(forKey: need) else { return }
        gone[need] = taken
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            await taken.go()
            self?.going[id] = nil
            if self?.gone[need]?.mark == taken.mark { self?.gone[need] = nil }
        }
        going[id] = Going(task: task, store: taken.store)
    }

    /// Every answer that waits goes now: at a quit, and before an update's restart.
    func releaseAll() {
        for need in Array(held.keys) { release(need) }
    }

    /// **A quit waits until each press that a hold let go has gone into the outbox** (`FleetAppDelegate`), or can go no
    /// further in this run: its store cannot write now (no answer of the hub, or another request on its way), and the
    /// press would wait for a moment that a quit never gives, as a press that waits for the hub is forgotten at a quit
    /// (`AnswerWaits`). The request then stays open on the hub, and he answers it again. A press waits for his own
    /// signature where it asks one (a door's Run it once), and for a file of his answer that goes up again: that is his
    /// step and its upload, not a clock's.
    func settle() async {
        while going.values.contains(where: { $0.store?.canWrite == true }) {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

extension EnvironmentValues {
    /// **A request's card stands on a page of the main window** (an agent's chat sets it): the place of a held answer is
    /// that page (`AnswerHolds.Place`). False in the card's own window and in the job's detail card, which are no page.
    @Entry var cardOnPage = false
}
