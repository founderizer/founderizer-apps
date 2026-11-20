import Foundation

/// **What one agent does now and did on each of the last days** (the owner, 19 November 2026: "show the number of
/// tasks each one is currently working on ... the idea is to know how the fleet is and has been performing", and his
/// "A: table" and "Counts and chart" to the two pictures of the Agents page that day). It counts tasks, as he asked,
/// where the Tasks board shows jobs, by the board's rules for one task (`HubState.work`).
public struct AgentWork: Sendable, Equatable {
    /// Its tasks that the board's rules put in work (`HubState.taskColumns`).
    public var inWork = 0
    /// **Its part of what needs the owner** (`HubState.needsYouCount`): each open request that a task of its waits on,
    /// or that it raised where no task waits on it, and each task of its that only he can move (an outcome, a stop);
    /// the fleet manager's row also takes what belongs to no agent of the team. So the rows add up to the sidebar's
    /// Needs you count, which the strip shows.
    public var needsYou = 0
    /// Its tasks done on each day, the oldest day first and today last (`FleetWork.days` of them).
    public var done = Array(repeating: 0, count: FleetWork.days)
    /// Its tasks done in all those days.
    public var doneInDays: Int { done.reduce(0, +) }
}

/// **The fleet's counts over the Agents table** and the done tasks of each agent on each day, for the chart beside
/// them and for each row's own small chart.
public struct FleetWork: Sendable, Equatable {
    /// The days of the charts: two weeks, so that the last 7 days stand beside the 7 before them.
    public static let days = 14
    /// The first moment of each day of this Mac's calendar, the oldest first and today last.
    public let dayStarts: [Double]
    /// Each agent of the team, by name.
    public let agents: [String: AgentWork]
    /// The done tasks of each day of the agents that are no longer in the team: their part of the fleet's chart.
    public let others: [Int]
    /// The tasks in work, of every agent.
    public let inWork: Int
    /// What needs the owner: the count of the sidebar's Needs you row (`HubState.needsYouCount`), so that the two
    /// numbers on his screen are one.
    public let needsYou: Int
    /// The tasks done in the last 7 days, today included, and in the 7 days before them.
    public let doneWeek: Int
    public let doneWeekBefore: Int
    /// The results of the last 7 days that did not succeed (`FleetTask.endedBadly`): failed, rejected, not accepted.
    /// Tasks, as the done ones: a task that failed counts here also when a later task did the work again.
    public let failedWeek: Int

    /// The share of the last 7 days' results that did not succeed, in whole percent; nil with no result.
    public var failedPercent: Int? {
        let results = doneWeek + failedWeek
        return results == 0 ? nil : Int((Double(failedWeek) * 100 / Double(results)).rounded())
    }

    /// The done tasks of every agent on each day, the agents that left included.
    public var dayTotals: [Int] {
        agents.values.reduce(others) { totals, work in zip(totals, work.done).map(+) }
    }

    /// The most tasks that one agent did on one day: the one scale of every row's small chart, so that two rows
    /// compare by their height.
    public var dayMost: Int { agents.values.flatMap(\.done).max() ?? 0 }
}

extension FleetTask {
    /// **A result that counts as done**: the task completed and its requester did not refuse it. A result that waits
    /// for its check counts, as its agent's work is over.
    public var isDone: Bool { state == "completed" && accepted != 0 }

    /// The time of its result: when it was delivered, else when it was checked, else its last activity.
    public var resultTime: Double { delivered ?? checked_at ?? last_activity ?? started ?? created }
}

extension HubState {
    /// **The fleet's work now and on each of the last `FleetWork.days` days** of this Mac's calendar. A task in work
    /// is one that the board's rules put in work (`taskColumns`), what needs the owner is shared out to the agents as
    /// `AgentWork.needsYou` says, and a done task is one that `FleetTask.isDone` counts, on the day of its result
    /// (`resultTime`). The hub's time is the present.
    public func work(calendar: Calendar = .current) -> FleetWork {
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: time))
        let starts = (0..<FleetWork.days).map { offset in
            calendar.date(byAdding: .day, value: offset - (FleetWork.days - 1), to: today)!.timeIntervalSince1970
        }
        let end = calendar.date(byAdding: .day, value: 1, to: today)!.timeIntervalSince1970
        func day(_ at: Double) -> Int? {
            guard let first = starts.first, at >= first, at < end else { return nil }
            return starts.lastIndex { $0 <= at }
        }
        let team = Set(agents.map(\.name))
        var work = Dictionary(uniqueKeysWithValues: agents.map { ($0.name, AgentWork()) })
        var others = Array(repeating: 0, count: FleetWork.days)
        let columns = taskColumns
        // Each open request to the agent whose task waits on it (the first task, by its number), else to the agent
        // that raised it; then each task that only the owner can move to its own agent.
        var waitedOn: [Int: String] = [:]
        for (id, wait) in ownerWaits.sorted(by: { $0.key < $1.key }) {
            if case .request(let need, _) = wait, waitedOn[need] == nil, let task = tasks.first(where: { $0.id == id }) {
                waitedOn[need] = task.owner
            }
        }
        // What belongs to no agent of the team (an agent that left, the hub itself) goes to the fleet manager's row,
        // which raises the requests: so the rows always add up to the count.
        let manager = agents.first { $0.role == "manager" }?.name
        func row(_ name: String) -> String? { team.contains(name) ? name : manager }
        for need in needs where need.isOpen {
            if let name = row(waitedOn[need.id] ?? need.by) { work[name]?.needsYou += 1 }
        }
        for task in ownerTasks { if let name = row(task.owner) { work[name]?.needsYou += 1 } }
        let week = starts[FleetWork.days - 7]
        var doneWeek = 0, doneWeekBefore = 0, failedWeek = 0
        for task in tasks {
            if team.contains(task.owner), columns[task.id] == .inProgress { work[task.owner]?.inWork += 1 }
            guard task.isDone || task.endedBadly, let index = day(task.resultTime) else { continue }
            let inWeek = task.resultTime >= week
            if task.endedBadly {
                if inWeek { failedWeek += 1 }
                continue
            }
            if inWeek { doneWeek += 1 } else { doneWeekBefore += 1 }
            if team.contains(task.owner) { work[task.owner]?.done[index] += 1 } else { others[index] += 1 }
        }
        return FleetWork(dayStarts: starts, agents: work, others: others, inWork: work.values.reduce(0) { $0 + $1.inWork },
                         needsYou: needsYouCount, doneWeek: doneWeek, doneWeekBefore: doneWeekBefore, failedWeek: failedWeek)
    }
}

/// **Each agent's part of its account's main window** (`GET /ui/costs`, its `accounts`; the owner's yes of 19
/// November 2026 to the picture of the Agents page, whose week bar shows an agent's own part brighter than what the
/// other agents of its account used): the points of the window that each agent's own sessions used since the window
/// began, which the hub sums from its sessions' `window_share`. The main window is the one that the hub marks `main`.
public struct AccountShares: Decodable, Sendable, Equatable {
    public struct Account: Decodable, Sendable, Equatable {
        public struct Window: Decodable, Sendable, Equatable {
            public let label: String
            public let main: Bool?
        }

        /// The account's key (`AccountLimits.account_key`).
        public let account: String
        /// Each agent's points of the main window.
        public let shares: [String: Double]
        public let windows: [Window]

        /// The label of the window that the shares are of.
        public var mainLabel: String? { windows.first { $0.main == true }?.label }
    }

    public let db: String
    public let accounts: [Account]

    /// The part of `agent` in the window `label` of `account`, in points of that window; nil where the hub gave none,
    /// where the window is not the account's main one, and where the agent shares the account with no other agent,
    /// whose part is the whole use.
    public func share(of agent: String, account: String?, window label: String) -> Double? {
        guard let account, let found = accounts.first(where: { $0.account == account }), found.mainLabel == label,
              found.shares.count > 1, let share = found.shares[agent], share.isFinite, share >= 0 else { return nil }
        return share
    }
}

extension HubState {
    /// **The open key request that an agent raised itself, where no open task waits on it** (the owner's "Yes" of 19
    /// November 2026 to "Do I also show the orange status dot for an agent's own key requests?"): its status dot is
    /// orange for it, with the request on hover, as for a task that waits for him. A key request is an item with its
    /// `secret` part (`request_secret`); the fleet manager's other items are not. A request that an open task waits on
    /// (`waiting_on` names it, or its question) is that task's agent's already (`ownerWaits`). The oldest first.
    public func ownKeyRequest(of agent: String) -> OwnerNeed? {
        let own = needs.filter { $0.isOpen && $0.secret != nil && $0.by == agent }
        guard !own.isEmpty else { return nil }
        let waited = Set(tasks.lazy.filter { !$0.isTerminal }.compactMap(\.waiting_on))
        return own.first { need in
            !waited.contains("N-\(need.id)") && !(need.question.map { waited.contains("Q-\($0)") } ?? false)
        }
    }
}
