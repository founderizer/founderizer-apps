import Foundation

/// **The card Work of an agent's chat panel** (the owner, 16 November 2026: "no indication of what it is doing, what's
/// done etc on the right side panel ... I though we added something there to see what the agent was doing right? at
/// high level?", and his pick of the picture "A: counts"). The card Asked shows only what he asked that agent for, and
/// an agent whose work comes from its duties or from its lead showed nothing there. This card is the agent's own tasks,
/// whoever gave them, in a few rows **only while a row has news**: one row for each open task that waits for him, by
/// what it waits for (the title of his request in Needs you); one row while a turn of a task works now; then the
/// number of its other open tasks, and the number of its tasks that ended done today. **The tasks of what he asked
/// this agent for are the card Asked's** (its rows and its "N waiting"), so this card leaves them out, and no task is
/// in both cards. With nothing to say there is no card.
public struct WorkCard: Sendable {
    /// One open task of the agent that waits for him.
    public struct Wait: Identifiable, Sendable, Equatable {
        /// The task.
        public let id: Int
        /// What it waits for: the title of his request, else the task's own title.
        public let title: String
        /// Under it: "Waits for you" for a request, else what he does (`OwnerWait.words`).
        public let line: String
        /// The request that it waits on, which its row opens on Needs you; nil: its row opens the task.
        public let request: Int?
    }

    /// The card's name over its rows.
    public static var title: String { String(l10n: "Work") }
    /// The row of the tasks that ended done today, with their number.
    public static func doneWords(_ count: Int) -> String { String(l10n: "\(count) done today") }

    /// Its open tasks that wait for him, the one that moved last first.
    public let waits: [Wait]
    /// Its tasks that a turn works on now (`FleetTask.mark(in:)`'s `inWork`), the one that moved last first: each
    /// one is news, and seldom more than one.
    public let working: [FleetTask]
    /// Its other open tasks, the one that moved last first: they wait for a time, for another agent, or for their turn.
    public let waiting: [FleetTask]
    /// Its tasks that ended done today by this Mac's calendar, the newest first: completed, and accepted by their
    /// requester's check, as the card Asked says "Done" (a "Done" that a refused result takes back is worse than none).
    public let done: [FleetTask]

    public var isEmpty: Bool { waits.isEmpty && working.isEmpty && waiting.isEmpty && done.isEmpty }

    /// `asks`: `HubState.asks`, whose tasks of what he asked this agent for this card leaves to the card Asked.
    public init(_ state: HubState, agent: String, asks: [Ask], calendar: Calendar = .current) {
        let asked = Set(asks.filter { $0.agent == agent }.flatMap { $0.tasks.map(\.id) })
        let mine = state.tasks.filter { $0.owner == agent && !asked.contains($0.id) }
        let open = mine.filter { !$0.isTerminal }.sorted { ($0.activityTime, $0.id) > ($1.activityTime, $1.id) }
        let owner = state.ownerWaits(of: open)
        var waits: [Wait] = []
        for task in open {
            guard let wait = owner[task.id] else { continue }
            if case .request(let id, let title) = wait {
                waits.append(Wait(id: task.id, title: title, line: String(l10n: "Waits for you"), request: id))
            } else {
                waits.append(Wait(id: task.id, title: task.title, line: wait.words, request: nil))
            }
        }
        self.waits = waits
        working = open.filter { owner[$0.id] == nil && $0.mark(in: state).inWork }
        let rowed = Set(waits.map(\.id)).union(working.map(\.id))
        waiting = open.filter { !rowed.contains($0.id) }
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: state.time)).timeIntervalSince1970
        done = mine.filter { $0.state == "completed" && $0.accepted == 1 && ($0.delivered ?? $0.checked_at ?? 0) >= start }
            .sorted { ($0.delivered ?? $0.checked_at ?? 0, $0.id) > ($1.delivered ?? $1.checked_at ?? 0, $1.id) }
    }
}
