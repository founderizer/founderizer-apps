import Foundation

/// The four columns of the Activity board. Needs you holds what only the owner can move: the manager's open requests
/// (`needs`, not tasks) and a task whose outcome is not known after a stop or a pause, or whose stop was not confirmed.
/// A task that ended is done. An open task is in progress while the hub reports it in work; it waits when it is queued
/// for its agent, when the hub reports that it needs an answer or a sign-in, when it waits on something (`waiting_on`),
/// or when a hold or its agent's usage limit holds it.
public enum ActivityColumn: String, CaseIterable, Identifiable, Sendable {
    case needsYou, inProgress, waiting, done
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .needsYou: "Needs you"
        case .inProgress: "In progress"
        case .waiting: "Waiting"
        // "Ended", the iPhone's word (T-33, fix round 2): it holds canceled, failed and rejected tasks too.
        case .done: "Ended"
        }
    }
}

/// The date filter of the Activity board: whole calendar days of this Mac that end today.
public enum ActivityPeriod: String, CaseIterable, Identifiable, Sendable {
    case today, week, month, all
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .today: "Today"
        case .week: "Last 7 days"
        case .month: "Last 30 days"
        case .all: "All"
        }
    }
    /// The first moment of the period, or nil for all time.
    public func start(now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .today: return today
        case .week: return calendar.date(byAdding: .day, value: -6, to: today)
        case .month: return calendar.date(byAdding: .day, value: -29, to: today)
        case .all: return nil
        }
    }
}

extension FleetTask {
    /// The time of the task's last activity, or its created time while it has not started.
    public var activityTime: Double { started == nil ? created : last_activity ?? started ?? created }

    /// The task's column. `held`: a hold that is not released, or a usage limit of the task's agent. `needsOwner`: an
    /// outcome that the owner must record, or a stop that was not confirmed; also for a task that ended.
    public func activityColumn(held: Bool, needsOwner: Bool = false) -> ActivityColumn {
        if needsOwner { return .needsYou }
        if isTerminal { return .done }
        if held || state == "input-required" || state == "auth-required" || !(waiting_on ?? "").isEmpty { return .waiting }
        // A queued task (`submitted`) waits for its agent; a state that this app does not know is never shown as work,
        // and never hidden.
        return state == "working" ? .inProgress : .waiting
    }

    /// The word for a result that is not a success, or nil: a success, a result that waits for its check, or open work.
    public var failedResult: String? {
        switch state {
        case "failed": "Failed"
        case "rejected": "Rejected"
        case "canceled": "Canceled"
        case "completed": accepted == 0 ? "Not accepted" : nil
        default: nil
        }
    }
}

extension HubState {
    /// The tasks of the Activity board for one agent (nil: all agents) and one period, newest activity first in each
    /// column. The hub's time is the present; the period starts at a calendar day of this Mac.
    public func activity(agent: String?, period: ActivityPeriod, calendar: Calendar = .current) -> [ActivityColumn: [FleetTask]] {
        let start = period.start(now: Date(timeIntervalSince1970: time), calendar: calendar)?.timeIntervalSince1970 ?? -.infinity
        let held = Set((holds ?? []).filter { $0.state != "released" }.map(\.task))
        let limited = Set(agents.filter { $0.limit != nil }.map(\.name))
        let owner = Set((outcomes ?? []).filter { $0.state == "unknown" }.map(\.task) +
                        (holds ?? []).filter { $0.state == "not_confirmed" }.map(\.task))
        var columns: [ActivityColumn: [FleetTask]] = [:]
        for task in tasks where (agent == nil || task.owner == agent) && (task.activityTime >= start || owner.contains(task.id)) {
            let column = task.activityColumn(held: held.contains(task.id) || limited.contains(task.owner), needsOwner: owner.contains(task.id))
            columns[column, default: []].append(task)
        }
        return columns.mapValues { $0.sorted { ($0.activityTime, $0.id) > ($1.activityTime, $1.id) } }
    }

    /// The tasks this agent is working on right now — the work that an update of its helper would end, because
    /// restarting that service ends the whole group its session runs in. A task that waits for something is not
    /// work in flight, and a state this app does not know is never counted as work (`activityColumn`).
    public func working(_ agent: String) -> [FleetTask] {
        tasks.filter { $0.owner == agent && $0.state == "working" }
    }

    /// The manager's open requests for the Needs you column, newest first: all of them for all agents, else those that
    /// the chosen agent raised. A request never leaves the column by its age.
    public func activityNeeds(agent: String?) -> [OwnerNeed] {
        needs.filter { $0.isOpen && (agent == nil || $0.by == agent) }.sorted { ($0.raised, $0.id) > ($1.raised, $1.id) }
    }

    /// How many items stand in the Needs you column, for every agent: the manager's open requests and the tasks
    /// that only the owner can move (an outcome that is not known, a stop that was not confirmed). The count of the
    /// sidebar's Activity row, and the same number the column's own heading shows with no filter, because a task
    /// that needs the owner never leaves the board by its age.
    public var needsYouCount: Int { needs.filter(\.isOpen).count + ownerTasks.count }

    /// The tasks that only the owner can move, newest first: an outcome that is not known, a stop that was not
    /// confirmed. The Needs you page lists them under the open requests, so its row's count is what the page shows.
    public var ownerTasks: [FleetTask] {
        let owner = Set((outcomes ?? []).filter { $0.state == "unknown" }.map(\.task) +
                        (holds ?? []).filter { $0.state == "not_confirmed" }.map(\.task))
        return tasks.filter { owner.contains($0.id) }.sorted { $0.id > $1.id }
    }

    /// The choices of the agent filter: the hub's agents in its order, then other owners of tasks, then the saved
    /// choice when the hub no longer has it.
    public func activityAgents(saved: String) -> [String] {
        var names = agents.map(\.name)
        names += Set(tasks.map(\.owner)).subtracting(names).sorted()
        if !saved.isEmpty && !names.contains(saved) { names.append(saved) }
        return names
    }
}

/// How long ago, in a few words: "Just now", "5 min ago", "3 h ago", "2 days ago", and from seven days the date.
public func activityAge(_ time: Double, now: Double, calendar: Calendar = .current, locale: Locale = .current) -> String {
    let seconds = max(0, now - time)
    switch seconds {
    case ..<60: return "Just now"
    case ..<3600: return "\(Int(seconds / 60)) min ago"
    case ..<86_400: return "\(Int(seconds / 3600)) h ago"
    case ..<(7 * 86_400): return Int(seconds / 86_400) == 1 ? "1 day ago" : "\(Int(seconds / 86_400)) days ago"
    default:
        let date = Date(timeIntervalSince1970: time)
        var style = Date.FormatStyle.dateTime.day().month(.abbreviated)
        if calendar.component(.year, from: date) != calendar.component(.year, from: Date(timeIntervalSince1970: now)) { style = style.year() }
        style.calendar = calendar; style.timeZone = calendar.timeZone; style.locale = locale
        return date.formatted(style)
    }
}
