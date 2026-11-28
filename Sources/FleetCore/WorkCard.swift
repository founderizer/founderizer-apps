import Foundation

/// **The card Work of an agent's chat panel** (the owner, 16 November 2026: "no indication of what it is doing, what's
/// done etc on the right side panel ... at high level?"; and 17 November 2026: "not the specific tasks but at a higher
/// level. For example: 'resolved ticket TCK-xxxxx' instead of the specific tasks performed to resolve it ... Just show
/// the most recent ones on the sidebar, and let me go to the detail page if clicked", with his "Yes, as drawn" to its
/// pictures). The card Asked shows only what he asked that agent for; this card is the rest of its work, whoever gave
/// it, **by the things that it works on and not by their tasks** (`WorkItem`: a case of a duty, such as a ticket, or a
/// task with its subtasks and follow-ups). In a few rows, only while a row has news: one row for each open task that
/// waits for him, by what it waits for (the title of his request in Needs you); one row for each thing that a turn
/// works on now, by that thing's name; then the newest things that ended in the last 72 hours, at most three, each
/// with how it ended ("Drafted", "Done"), a result that succeeded or one that did not (a result that waits for its
/// check, and work that somebody canceled, have no row, as on Asked). A row of a thing opens it in the detail card.
/// The counts of what waits and of what ended went (his pick, "Remove the counts"): the agent's Tasks has the rest.
/// **The tasks of what he asked this agent for are the card Asked's**, so this card leaves them out, and no task is in
/// both cards. With nothing to say there is no card.
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

    /// One thing of its work: its name, and under it what it does now, or how it ended and when.
    public struct Row: Identifiable, Sendable, Equatable {
        /// The thing, whose page the row opens.
        public let id: WorkItem.Key
        public let title: String
        /// In work: what its turn does now, or "". Ended: how it ended ("Drafted", "Done").
        public let words: String
        /// When it ended, or nil for work that goes on now.
        public let endedAt: Double?
        /// The look of the mark of a thing that ended, or nil for work that goes on now.
        public let end: WorkItem.End?
    }

    /// The card's name over its rows.
    public static var title: String { String(l10n: "Work") }
    /// How many of the things that ended the card shows.
    public static let newest = 3
    /// How long ago a thing may have ended and still be news: the hub's own window of the cases that closed lately.
    public static let window: Double = 72 * 3600

    /// Its open tasks that wait for him, the one that moved last first.
    public let waits: [Wait]
    /// The things that a turn of its tasks works on now (`FleetTask.mark(in:)`'s `inWork`), the one that moved last
    /// first: each one is news, and seldom more than one.
    public let working: [Row]
    /// The newest things that ended in the last 72 hours, at most three, the newest first.
    public let ended: [Row]

    public var isEmpty: Bool { waits.isEmpty && working.isEmpty && ended.isEmpty }

    /// `asks`: `HubState.asks`, whose tasks of what he asked this agent for this card leaves to the card Asked.
    public init(_ state: HubState, agent: String, asks: [Ask]) {
        // each ask that this agent's chat holds a message of (`Ask.isIn(chatOf:)`): a follow-up's task that it does
        // is on its card Asked, and not a second time here (the Mac validator, 26 November 2026)
        let asked = Set(asks.filter { $0.isIn(chatOf: agent) }.flatMap { $0.tasks.map(\.id) })
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
        let items = state.workItems(of: agent, asked: asked)
        let byKey = Dictionary(items.map { ($0.id, $0) }) { first, _ in first }
        let byID = Dictionary(state.tasks.map { ($0.id, $0) }) { first, _ in first }
        var working: [Row] = [], seen: Set<WorkItem.Key> = []
        for task in open where owner[task.id] == nil && task.mark(in: state).inWork {
            let key = state.workKey(of: task, byID: byID)
            guard seen.insert(key).inserted, let item = byKey[key] else { continue }
            working.append(Row(id: key, title: item.title, words: task.doing ?? "", endedAt: nil, end: nil))
        }
        self.working = working
        // A case that the reading does not have closed before the hub's window, when the hub sends that window: a
        // check of one of its tasks today is no news of it.
        let closedBefore = state.responsibilities?.knowsRecent == true
        ended = items.compactMap { item -> (WorkItem, Double)? in
            if case .dutyCase = item.id, item.dutyCase == nil, closedBefore { return nil }
            // A case closes while the task that closed it still delivers: it is the row of work now until then.
            guard !seen.contains(item.id) else { return nil }
            // Only a result that succeeded and one that did not, as the card Asked says them: a result that waits for
            // its check is no "Done" yet, and work that somebody canceled has no row.
            guard let at = item.endedAt, at >= state.time - Self.window, let end = item.result?.end, end != .quiet
            else { return nil }
            return (item, at)
        }
        .sorted { ($0.1, $0.0.tasks.last?.id ?? 0) > ($1.1, $1.0.tasks.last?.id ?? 0) }
        .prefix(Self.newest)
        .map { item, at in
            let result = item.result!
            return Row(id: item.id, title: item.title, words: result.words, endedAt: at, end: result.end)
        }
    }
}
