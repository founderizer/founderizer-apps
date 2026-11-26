import Foundation

/// **A new reading of the fleet waits while a chat or a thread scrolls** (the Mac app; the owner, 17 November 2026:
/// "scrolling up and down the fleet manager conversation does not feel smooth"). A reading draws the window again, and
/// a scroll at 120 Hz lost two to four frames to it every three seconds. The read itself goes on; its reading comes in
/// when the views that scroll rest, and at the latest when `StateReading.waitWhileScrolling` says, so the page never
/// says that its reading is old while the hub answers.
///
/// **It comes in only once the scroll has rested for `settle`** (the owner, 25 November 2026: "scrolling Fleet Manager
/// chat is SO slow"): a scroll in flicks rests for a moment between two of them, and a reading that came in then stopped
/// the main thread for 90 to 113 ms (the manager's chat on his fleet's reading, measured in a hidden copy of the app),
/// at the start of the next flick.
@MainActor public final class ScrollHold {
    /// How long the scroll views must rest before a reading that waits comes in.
    public static let settle: TimeInterval = 1
    /// The scroll views that move now.
    public private(set) var moving: Set<ObjectIdentifier> = []
    /// No view moves, and none moved in the last `settle` seconds (or a deadline ended the wait).
    private var settled = true
    private var settling: Task<Void, Never>?
    private var waits: [Wait] = []
    private let sleep: @MainActor (TimeInterval) async -> Void

    /// `sleep` waits that many seconds; a test gives its own.
    public init(sleep: @escaping @MainActor (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) {
        self.sleep = sleep
    }

    /// A scroll view began to move, or came to rest. When none has moved for `settle` seconds, every reading that waits
    /// comes in; a view that moves again in that time keeps them waiting.
    public func scroll(_ view: ObjectIdentifier, moving now: Bool) {
        if now { moving.insert(view) } else { moving.remove(view) }
        settling?.cancel()
        settling = nil
        if now {
            settled = false
            return
        }
        guard moving.isEmpty, !settled else { return }
        let sleep = self.sleep
        settling = Task { @MainActor [weak self] in
            await sleep(Self.settle)
            guard !Task.isCancelled, let self, self.moving.isEmpty else { return }
            self.settling = nil
            self.settled = true
            self.endWaits()
        }
    }

    /// Returns at once when no view scrolls or rests for less than `settle`; else when they have rested that long, and at
    /// the latest after
    /// `StateReading.waitWhileScrolling(sinceAnswer:)`. **A wait that its deadline ends forgets the views that it waited
    /// for**: a view that never told that it rests holds no later reading, and one that still moves says so again at
    /// its next phase.
    public func rest(sinceAnswer: TimeInterval?) async {
        guard !settled else { return }
        let left = StateReading.waitWhileScrolling(sinceAnswer: sinceAnswer)
        guard left > 0 else { return }
        let wait = Wait()
        waits.append(wait)
        let sleep = self.sleep
        Task { @MainActor [weak self] in
            await sleep(left)
            guard let self, !wait.done else { return }
            self.moving.removeAll()
            self.settling?.cancel()
            self.settling = nil
            self.settled = true
            self.endWaits()
        }
        await wait.ended()
    }

    private func endWaits() {
        let ending = waits
        waits = []
        for wait in ending { wait.end() }
    }

    /// One reading that waits: it ends once, by the rest or by its deadline, whichever comes first.
    @MainActor private final class Wait {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var done = false

        func ended() async {
            guard !done else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func end() {
            done = true
            continuation?.resume()
            continuation = nil
        }
    }
}
