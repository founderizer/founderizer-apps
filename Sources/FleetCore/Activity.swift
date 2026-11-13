import Foundation

/// The three columns of the Tasks board (the owner's yes of 11 November 2026 to its picture). An open task is in
/// progress while the hub reports it in work. It waits when it is queued for its agent, when the hub reports that it
/// needs an answer or a sign-in, when it waits on something (`waiting_on`), when its agent parked it until a time
/// (`parked_until`), when a hold or its agent's usage limit holds it, and when only the owner can move it: an outcome
/// that is not known after a stop or a pause, or a stop that was not confirmed, also on a task that ended. Every other
/// task that ended is in Ended.
///
/// The board had a fourth column, Needs you, with the manager's open requests in it: the Needs you page shows them,
/// one row above Tasks in the sidebar, so the column said them twice.
public enum ActivityColumn: String, CaseIterable, Identifiable, Sendable {
    case inProgress, waiting, done
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .inProgress: String(l10n: "In progress")
        case .waiting: String(l10n: "Waiting")
        // "Ended", the iPhone's word (T-33, fix round 2): it holds canceled, failed and rejected tasks too.
        case .done: String(l10n: "Ended")
        }
    }
}

/// The date filter of the Activity board: whole calendar days of this Mac that end today.
public enum ActivityPeriod: String, CaseIterable, Identifiable, Sendable {
    case today, week, month, all
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .today: String(l10n: "Today")
        case .week: String(l10n: "Last 7 days")
        case .month: String(l10n: "Last 30 days")
        case .all: String(l10n: "All")
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

/// **What a task waits for from the owner**, which its card on the board says in orange: the request that it waits
/// on, by its title; an outcome that nobody knows, which he records in the task; a stop that its helper did not
/// confirm; a sign-in of its agent's AI provider.
public enum OwnerWait: Equatable, Sendable {
    case request(id: Int, title: String)
    case outcome
    case stop
    case signIn

    /// The card's orange line.
    public var words: String {
        switch self {
        case .request(_, let title): title
        case .outcome: String(l10n: "Outcome not known: check it")
        case .stop: String(l10n: "Stop not confirmed")
        case .signIn: String(l10n: "Sign-in needed")
        }
    }
}

extension FleetTask {
    /// The time of the task's last activity, or its created time while it has not started.
    public var activityTime: Double { started == nil ? created : last_activity ?? started ?? created }

    /// The task's column. `held`: a hold that is not released, or a usage limit of the task's agent. `needsOwner`: an
    /// outcome that the owner must record, or a stop that was not confirmed; also for a task that ended.
    public func activityColumn(held: Bool, needsOwner: Bool = false) -> ActivityColumn {
        if needsOwner { return .waiting }
        if isTerminal { return .done }
        if held || state == "input-required" || state == "auth-required" || !(waiting_on ?? "").isEmpty { return .waiting }
        // Its agent parked it until a time: it does no work until then, whatever its state says.
        if parked_until != nil { return .waiting }
        // A queued task (`submitted`) waits for its agent; a state that this app does not know is never shown as work,
        // and never hidden.
        return state == "working" ? .inProgress : .waiting
    }

    /// The word for a result that is not a success, or nil: a success, a result that waits for its check, or open work.
    public var failedResult: String? {
        switch state {
        case "failed": String(l10n: "Failed")
        case "rejected": String(l10n: "Rejected")
        case "canceled": String(l10n: "Canceled")
        case "completed": accepted == 0 ? String(l10n: "Not accepted") : nil
        default: nil
        }
    }

    /// **A result that he must see**: it failed, its requester rejected the task, or its requester did not accept the
    /// result. A canceled task is not one: somebody chose to end it.
    public var endedBadly: Bool { state == "failed" || state == "rejected" || (state == "completed" && accepted == 0) }
}

extension HubState {
    /// The tasks of the Tasks board for one agent (nil: all agents) and one period, newest activity first in each
    /// column, **and in Waiting the tasks that wait for the owner before the others** (`ownerWaits`). The hub's time is
    /// the present; the period starts at a calendar day of this Mac. **A task that waits for the owner shows whatever
    /// the period** (review of 11 November 2026): a task that waits gets no new activity, so with "Last 7 days" one
    /// that waited for his answer for 8 days left the board.
    public func activity(agent: String?, period: ActivityPeriod, calendar: Calendar = .current) -> [ActivityColumn: [FleetTask]] {
        let start = period.start(now: Date(timeIntervalSince1970: time), calendar: calendar)?.timeIntervalSince1970 ?? -.infinity
        let held = Set((holds ?? []).filter { $0.state != "released" }.map(\.task))
        let limited = Set(agents.filter { $0.limit != nil }.map(\.name))
        let owner = ownerOnly, waits = ownerWaits
        var columns: [ActivityColumn: [FleetTask]] = [:]
        for task in tasks where (agent == nil || task.owner == agent) && (task.activityTime >= start || waits[task.id] != nil) {
            let column = task.activityColumn(held: held.contains(task.id) || limited.contains(task.owner), needsOwner: owner.contains(task.id))
            columns[column, default: []].append(task)
        }
        var sorted = columns.mapValues { $0.sorted { ($0.activityTime, $0.id) > ($1.activityTime, $1.id) } }
        if let waiting = sorted[.waiting] {
            sorted[.waiting] = waiting.filter { waits[$0.id] != nil } + waiting.filter { waits[$0.id] == nil }
        }
        return sorted
    }

    /// The tasks that only the owner can move, by id: an outcome that is not known, a stop that was not confirmed.
    private var ownerOnly: Set<Int> {
        Set((outcomes ?? []).filter { $0.state == "unknown" }.map(\.task) +
            (holds ?? []).filter { $0.state == "not_confirmed" }.map(\.task))
    }

    /// **What each task waits for from the owner**, by task: an outcome that is not known first, then a stop that was
    /// not confirmed, and for an open task the request it waits on — `waiting_on` names the request itself ("N-53") or
    /// the question that the request carries to him ("Q-68", the request's `question`) — or its agent's sign-in. A
    /// task that waits for an agent's answer is not in it.
    public var ownerWaits: [Int: OwnerWait] {
        let unknown = Set((outcomes ?? []).filter { $0.state == "unknown" }.map(\.task))
        let unconfirmed = Set((holds ?? []).filter { $0.state == "not_confirmed" }.map(\.task))
        let open = needs.filter(\.isOpen)
        let byID = Dictionary(open.map { ($0.id, $0) }) { first, _ in first }
        let byQuestion = Dictionary(open.compactMap { need in need.question.map { ($0, need) } }) { first, _ in first }
        var waits: [Int: OwnerWait] = [:]
        for task in tasks {
            if unknown.contains(task.id) { waits[task.id] = .outcome; continue }
            if unconfirmed.contains(task.id) { waits[task.id] = .stop; continue }
            guard !task.isTerminal else { continue }
            if let need = Self.reference(task.waiting_on, "N").flatMap({ byID[$0] })
                ?? Self.reference(task.waiting_on, "Q").flatMap({ byQuestion[$0] }) {
                waits[task.id] = .request(id: need.id, title: need.title)
            } else if task.state == "auth-required" {
                waits[task.id] = .signIn
            }
        }
        return waits
    }

    /// The number of the hub's reference `<letter>-<number>` ("N-53" with "N" is 53), or nil.
    private static func reference(_ text: String?, _ letter: String) -> Int? {
        guard let text, text.hasPrefix(letter + "-") else { return nil }
        let digits = text.dropFirst(letter.count + 1)
        return !digits.isEmpty && digits.allSatisfy(\.isASCII) && digits.allSatisfy(\.isNumber) ? Int(digits) : nil
    }

    /// The tasks this agent is working on right now — the work that an update of its helper would end, because
    /// restarting that service ends the whole group its session runs in. A task that waits for something is not
    /// work in flight, and a state this app does not know is never counted as work (`activityColumn`).
    public func working(_ agent: String) -> [FleetTask] {
        tasks.filter { $0.owner == agent && $0.state == "working" }
    }

    /// How many items need the owner, for every agent: the manager's open requests and the tasks that only the owner
    /// can move (an outcome that is not known, a stop that was not confirmed). The count of the sidebar's Needs you row,
    /// and what the Needs you page lists.
    public var needsYouCount: Int { needs.filter(\.isOpen).count + ownerTasks.count }

    /// The tasks that only the owner can move, newest first: an outcome that is not known, a stop that was not
    /// confirmed. The Needs you page lists them under the open requests, so its row's count is what the page shows.
    public var ownerTasks: [FleetTask] {
        let owner = ownerOnly
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

/// **The Ended column, as it shows** (the owner's yes of 11 November 2026: "Ended shows only what did not succeed"):
/// the results that he must see, one row each, and every other ended task behind one row that opens them by day. A
/// fleet ends more than a hundred tasks a week, and nine of ten are a checked result: as one card each they hid the
/// ones that failed.
public struct EndedTasks: Sendable {
    /// One or more tasks of one day that are one row: one task, or the runs of one schedule, or tasks of one agent
    /// with the same title, newest first.
    public struct Group: Identifiable, Sendable {
        public let title: String
        public let tasks: [FleetTask]
        /// Its oldest task: a run that ends later joins the row at its head, and the row he opened stays open.
        public var id: Int { tasks[tasks.count - 1].id }
        public var owner: String { tasks[0].owner }
    }

    /// One calendar day of this Mac, by its first moment, with its rows, newest first.
    public struct Day: Identifiable, Sendable {
        public let start: Double
        public let groups: [Group]
        public var id: Double { start }
    }

    /// The results that are not a success, newest first: failed, rejected, not accepted.
    public let failed: [FleetTask]
    /// Every other ended task, newest day first.
    public let days: [Day]
    /// How many tasks `days` holds.
    public let rest: Int

    /// `tasks`: the Ended column, newest first.
    public init(_ tasks: [FleetTask], calendar: Calendar = .current) {
        failed = tasks.filter(\.endedBadly)
        let others = tasks.filter { !$0.endedBadly }
        rest = others.count
        var days: [Day] = []
        var day: (start: Double, tasks: [FleetTask])?
        func close() { if let day { days.append(Day(start: day.start, groups: Self.groups(day.tasks))) } }
        for task in others {
            let start = calendar.startOfDay(for: Date(timeIntervalSince1970: task.activityTime)).timeIntervalSince1970
            if day?.start != start { close(); day = (start, []) }
            day?.tasks.append(task)
        }
        close()
        self.days = days
    }

    /// The rows of one day, in the order of their newest task: the runs of one schedule of one agent are one row, and so
    /// are tasks of one agent with the same title.
    static func groups(_ tasks: [FleetTask]) -> [Group] {
        var order: [String] = [], members: [String: [FleetTask]] = [:]
        for task in tasks {
            let key = task.owner + "\u{1F}" + (task.trigger_id.map { "schedule \($0)" } ?? "title " + task.title)
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(task)
        }
        return order.compactMap { members[$0] }.map { Group(title: title(of: $0), tasks: $0) }
    }

    /// The words of a row of several tasks: their title, or what the titles of a schedule's runs begin with, cut at a
    /// whole word ("CRM tickets waiting for iris" for "CRM tickets waiting for iris: TCK-1" and "… TCK-2"); the newest
    /// task's title when they share less than two words.
    static func title(of tasks: [FleetTask]) -> String {
        let first = tasks[0].title
        guard tasks.contains(where: { $0.title != first }) else { return first }
        var shared = first.split(separator: " ", omittingEmptySubsequences: true)
        for task in tasks.dropFirst() {
            let words = task.title.split(separator: " ", omittingEmptySubsequences: true)
            var same = 0
            while same < min(shared.count, words.count), shared[same] == words[same] { same += 1 }
            shared = Array(shared.prefix(same))
        }
        guard shared.count >= 2 else { return first }
        return shared.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " :;,.-–—"))
    }
}

/// How long ago, in a few words: "Just now", "5 min ago", "3 h ago", "2 days ago", and from seven days the date.
public func activityAge(_ time: Double, now: Double, calendar: Calendar = .current, locale: Locale = .current) -> String {
    let seconds = max(0, now - time)
    switch seconds {
    case ..<60: return String(l10n: "Just now")
    case ..<3600: return String(l10n: "\(Int(seconds / 60)) min ago")
    case ..<86_400: return String(l10n: "\(Int(seconds / 3600)) h ago")
    case ..<(7 * 86_400): return Int(seconds / 86_400) == 1 ? String(l10n: "1 day ago") : String(l10n: "\(Int(seconds / 86_400)) days ago")
    default:
        let date = Date(timeIntervalSince1970: time)
        var style = Date.FormatStyle.dateTime.day().month(.abbreviated)
        if calendar.component(.year, from: date) != calendar.component(.year, from: Date(timeIntervalSince1970: now)) { style = style.year() }
        style.calendar = calendar; style.timeZone = calendar.timeZone; style.locale = locale
        return date.formatted(style)
    }
}
