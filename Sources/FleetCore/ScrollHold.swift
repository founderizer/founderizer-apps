import Foundation

/// **A new reading of the fleet waits while a chat or a thread scrolls** (the Mac app; the owner, 17 November 2026:
/// "scrolling up and down the fleet manager conversation does not feel smooth"). A reading draws the window again, and
/// a scroll at 120 Hz lost two to four frames to it every three seconds. The read itself goes on; its reading comes in
/// when the views that scroll rest, and at the latest when `StateReading.waitWhileScrolling` says, so the page never
/// says that its reading is old while the hub answers.
@MainActor public final class ScrollHold {
    /// The scroll views that move now.
    public private(set) var moving: Set<ObjectIdentifier> = []
    private var waits: [Wait] = []
    private let sleep: @MainActor (TimeInterval) async -> Void

    /// `sleep` waits that many seconds; a test gives its own.
    public init(sleep: @escaping @MainActor (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) {
        self.sleep = sleep
    }

    /// A scroll view began to move, or came to rest. When none moves, every reading that waits comes in.
    public func scroll(_ view: ObjectIdentifier, moving now: Bool) {
        if now { moving.insert(view) } else { moving.remove(view) }
        if moving.isEmpty { endWaits() }
    }

    /// Returns at once when no view scrolls; else when they rest, and at the latest after
    /// `StateReading.waitWhileScrolling(sinceAnswer:)`. **A wait that its deadline ends forgets the views that it waited
    /// for**: a view that never told that it rests holds no later reading, and one that still moves says so again at
    /// its next phase.
    public func rest(sinceAnswer: TimeInterval?) async {
        guard !moving.isEmpty else { return }
        let left = StateReading.waitWhileScrolling(sinceAnswer: sinceAnswer)
        guard left > 0 else { return }
        let wait = Wait()
        waits.append(wait)
        let sleep = self.sleep
        Task { @MainActor [weak self] in
            await sleep(left)
            guard let self, !wait.done else { return }
            self.moving.removeAll()
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
