import FleetCore
import Foundation

/// **His answer waits 5 seconds on its card, with Undo, before it goes** (the owner, 21 November 2026: "Sometimes I can
/// make a mistake replying to a card... we need a way to be able to UNDO very easily", and his "Yes, 5 seconds
/// (Recommended)" to its picture: "Nothing goes to the hub until the 5 seconds end. A click on Undo opens the card again
/// as it was."). Each answer that a card sends waits here first, whole, and then goes on the path that it took before:
/// an option's press (`AnswerWaits`, with a door call's signature and a Give), the ticked options, and his words with
/// their files. Nothing of it reaches the hub during the hold, so the hub has no part in it. The card of a key or a
/// login keeps its own form (a held secret would stay in memory and in a view), and a message under a card
/// (Needs clarification) is no answer.
///
/// **One hold for each request, for the whole app**, so the card in a chat, on Needs you and in its own window show the
/// same Undo. Meanwhile the card stands folded with his answer, as an answer on its way does (`shown`), with Undo in
/// its mark's place. A hold of another hub or generation, or of a request that closed meanwhile, shows nowhere, and its
/// press finds that when it goes, as a press that waited does. **A quit, an update's restart and the close of the card's
/// own window send what waits at once** (`releaseAll`, `release`): his answer is not lost by an act that is not Undo.
@MainActor @Observable final class AnswerHolds {
    static let shared = AnswerHolds()

    /// How long an answer waits: 5 seconds (his "Yes, 5 seconds"). A test shortens it.
    var wait: Duration = .seconds(5)

    /// One answer that waits.
    struct Held {
        let hub: URL
        let database: String
        /// What the card shows meanwhile: the answer, as an answer on its way shows (never saved, never sent).
        let shown: PendingRequest
        /// The options that he had ticked, which Undo ticks again (`restored`).
        let ticked: Set<Int>
        /// The words of his box before a reply that the app wrote there for him (a quick reply), which Undo puts back;
        /// nil where the box holds his own words, which stay.
        let draft: String?
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

    /// An answer of his waits, or a press is on its way out of a hold.
    var busy: Bool { !held.isEmpty || !going.isEmpty }

    /// **His press waits** `wait`, and then `go` does it. A second press on the same request while one waits takes its
    /// place: the card is folded meanwhile, so only a key can make one.
    func hold(_ need: OwnerNeed, store: FleetStore, shown: PendingRequest, ticked: Set<Int> = [], draft: String? = nil,
              go: @escaping @MainActor () async -> Void) {
        guard let database = store.state?.db else { return }
        waits[need.id]?.cancel()
        let mark = UUID()
        held[need.id] = Held(hub: store.hub, database: database, shown: shown, ticked: ticked, draft: draft, mark: mark,
                             store: store, go: go)
        let wait = wait
        waits[need.id] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: wait) } catch { return }
            guard let self, self.held[need.id]?.mark == mark else { return }
            self.release(need.id)
        }
    }

    /// The answer that waits on `need`, on the hub and generation that the store reads and while the request is open
    /// there; nil where none does.
    func held(_ need: OwnerNeed, in store: FleetStore) -> Held? {
        guard let held = held[need.id], held.hub == store.hub, held.database == store.state?.db,
              store.openNeeds.contains(where: { $0.id == need.id }) else { return nil }
        return held
    }

    /// The answer of `need` whose press runs now, after its wait, as `held` says it: the card shows it as on its way.
    func leaving(_ need: OwnerNeed, in store: FleetStore) -> Held? {
        guard let held = gone[need.id], held.hub == store.hub, held.database == store.state?.db,
              store.openNeeds.contains(where: { $0.id == need.id }) else { return nil }
        return held
    }

    /// **Undo**: the answer goes nowhere, and the card opens as it was: the box's words that a reply took the place of,
    /// and the options that he had ticked (`restoredTicks`). His own words and his files stayed in the box.
    func undo(_ need: OwnerNeed, store: FleetStore) {
        guard let taken = held(need, in: store) else { return }
        waits.removeValue(forKey: need.id)?.cancel()
        held[need.id] = nil
        if let draft = taken.draft { store.answers[String(need.id)] = draft }
        if !taken.ticked.isEmpty { restored[need.id] = taken.ticked }
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
