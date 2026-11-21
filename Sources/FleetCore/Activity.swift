import Foundation

/// The three columns of the Tasks board (the owner's yes of 11 November 2026 to its picture), which shows them as the
/// lanes Working, Waiting and Done (`title`). An open task is in progress while the hub reports it in work. It waits when it is queued for its agent, when the hub reports that it
/// needs an answer or a sign-in, when it waits on something (`waiting_on`), when its agent parked it until a time
/// (`parked_until`), when its session does no work now while subtasks of it are open (`subtaskWaits`), when a hold or
/// its agent's usage limit holds it, and when only the owner can move it: an outcome that is not known after a stop or a
/// pause, or a stop that was not confirmed, also on a task that ended. Every other task that ended is in Done.
///
/// The board had a fourth column, Needs you, with the manager's open requests in it: the Needs you page shows them,
/// one row above Tasks in the sidebar, so the column said them twice.
public enum ActivityColumn: String, CaseIterable, Identifiable, Sendable {
    case inProgress, waiting, done
    public var id: String { rawValue }
    /// **The lane's heading, in his words** (the owner, 18 November 2026: "4 tasks working - 1 waiting - 3 done", and
    /// "Yes, build it" to the picture with the lanes Working, Waiting and Done). They were In progress, Waiting and
    /// Ended. A job in Done that did not succeed says so in red.
    public var title: String {
        switch self {
        // A key of its own: in Spanish the lane is "En curso", and "Working", a task's state word, is "Trabajando".
        case .inProgress: String(localized: "Working (a lane)", defaultValue: "Working", bundle: Localized.bundle, locale: Localized.digits)
        case .waiting: String(l10n: "Waiting")
        case .done: String(l10n: "Done")
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

    /// **The words of an agent's status dot while a task of it waits for him** (the owner, 16 November 2026, of two
    /// orange dots whose words said "Waiting for Lead" and "Waiting for Manager": "these orange badges are
    /// confusing", then "on hover on the side and also on the right hand side panel, so its easier to understand!"): the
    /// request that it waits on, by its title, says that it is his; the other waits say what he does already.
    public var statusWords: String {
        if case .request(_, let title) = self { return String(l10n: "Waits for you: \(title)") }
        return words
    }
}

extension FleetTask {
    /// The time of the task's last activity, or its created time while it has not started.
    public var activityTime: Double { started == nil ? created : last_activity ?? started ?? created }

    /// The task's column. `held`: a hold that is not released, or a usage limit of the task's agent. `needsOwner`: an
    /// outcome that the owner must record, or a stop that was not confirmed; also for a task that ended.
    /// `waitsForSubtasks`: its session does no work now and subtasks of it are open (`HubState.subtaskWaits`).
    public func activityColumn(held: Bool, needsOwner: Bool = false, waitsForSubtasks: Bool = false) -> ActivityColumn {
        if needsOwner { return .waiting }
        if isTerminal { return .done }
        if held || state == "input-required" || state == "auth-required" || !(waiting_on ?? "").isEmpty { return .waiting }
        // Its agent parked it until a time: it does no work until then, whatever its state says.
        if parked_until != nil { return .waiting }
        // **A lead's task whose subtasks are still open waits for them** (the owner's "Yes, build it" of 14 November
        // 2026): the hub keeps its state `working` while nothing of its session runs (`works` false), and the board
        // showed three such tasks In progress for hours. When its session works again, to check a result, it is back.
        if waitsForSubtasks && state == "working" && works == false { return .waiting }
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

    /// **Its agent parked it, and the task waits on nothing else**: it is `working` and waits on nothing
    /// (`waiting_on`). The hub also parks a task that asked a question or waits on something, and such a task's card
    /// says that wait, not its time (`WaitingTasks`). A hold, a usage limit and a wait for the owner are records of
    /// their own, which the caller reads.
    public var parkedOnly: Bool { parked_until != nil && state == "working" && (waiting_on ?? "").isEmpty }

    /// **A result that he must see**: it failed, its requester rejected the task, or its requester did not accept the
    /// result. A canceled task is not one: somebody chose to end it.
    public var endedBadly: Bool { state == "failed" || state == "rejected" || (state == "completed" && accepted == 0) }
}

extension HubState {
    /// The tasks of one agent (nil: all agents) in one period, one by one, newest activity first in each column (the
    /// Tasks page reads `HubState.board`, which keeps these rules and shows each thing that he asked for as one card), **and in Waiting the tasks that wait for the owner before the others** (`ownerWaits`). The hub's time is
    /// the present; the period starts at a calendar day of this Mac. **A task that waits for the owner shows whatever
    /// the period** (review of 11 November 2026): a task that waits gets no new activity, so with "Last 7 days" one
    /// that waited for his answer for 8 days left the board.
    public func activity(agent: String?, period: ActivityPeriod, calendar: Calendar = .current) -> [ActivityColumn: [FleetTask]] {
        let start = period.start(now: Date(timeIntervalSince1970: time), calendar: calendar)?.timeIntervalSince1970 ?? -.infinity
        let waits = ownerWaits, column = taskColumns
        var columns: [ActivityColumn: [FleetTask]] = [:]
        for task in tasks where (agent == nil || task.owner == agent) && (task.activityTime >= start || waits[task.id] != nil) {
            columns[column[task.id] ?? .waiting, default: []].append(task)
        }
        var sorted = columns.mapValues { $0.sorted { ($0.activityTime, $0.id) > ($1.activityTime, $1.id) } }
        if let waiting = sorted[.waiting] {
            sorted[.waiting] = waiting.filter { waits[$0.id] != nil } + waiting.filter { waits[$0.id] == nil }
        }
        return sorted
    }

    /// **Each task's column on the board**, by task: one reading of the holds, the usage limits, what only the owner
    /// can move and the open subtasks, for the board's tasks and for the things that he asked for (`asks`), so that a
    /// card of several tasks stands where its tasks stood.
    var taskColumns: [Int: ActivityColumn] {
        let held = Set((holds ?? []).filter { $0.state != "released" }.map(\.task))
        let limited = Set(agents.filter { $0.limit != nil }.map(\.name))
        let owner = ownerOnly, subtasks = subtaskWaits
        return Dictionary(tasks.map { task in
            (task.id, task.activityColumn(held: held.contains(task.id) || limited.contains(task.owner), needsOwner: owner.contains(task.id),
                                          waitsForSubtasks: subtasks[task.id] != nil))
        }) { first, _ in first }
    }

    /// The tasks that only the owner can move, by id: an outcome that is not known and that its agent does not check
    /// first (`TaskOutcome.waitsOnOwner`), a stop that was not confirmed.
    private var ownerOnly: Set<Int> {
        Set(ownerOutcomes.map(\.task) + (holds ?? []).filter { $0.state == "not_confirmed" }.map(\.task))
    }

    /// **What each task waits for from the owner**, by task: an outcome that is not known first, then a stop that was
    /// not confirmed, and for an open task the request it waits on — `waiting_on` names the request itself ("N-53") or
    /// the question that the request carries to him ("Q-68", the request's `question`) — or its agent's sign-in. A
    /// task that waits for an agent's answer is not in it.
    public var ownerWaits: [Int: OwnerWait] { ownerWaits(of: tasks) }

    /// The same for some tasks only, such as one agent's open tasks (`FleetAgent.presence`): each row of the sidebar
    /// reads its own agent's, not the fleet's hundreds.
    public func ownerWaits(of some: [FleetTask]) -> [Int: OwnerWait] {
        let unknown = Set((outcomes ?? []).filter { $0.state == "unknown" }.map(\.task))
        let unconfirmed = Set((holds ?? []).filter { $0.state == "not_confirmed" }.map(\.task))
        let open = needs.filter(\.isOpen)
        let byID = Dictionary(open.map { ($0.id, $0) }) { first, _ in first }
        let byQuestion = Dictionary(open.compactMap { need in need.question.map { ($0, need) } }) { first, _ in first }
        var waits: [Int: OwnerWait] = [:]
        for task in some {
            // only one that its agent does not check first (`TaskOutcome.waitsOnOwner`), from the task's own row
            if unknown.contains(task.id) && outcomeUnknown(of: task) { waits[task.id] = .outcome; continue }
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

    /// **The agents whose open subtasks a task waits for**, by task: only for an open task in state `working` whose
    /// session does no work now (`works` false; nothing for a hub that does not say), each agent once, the one whose
    /// subtask moved last first. A task whose session works, to check a result, is not in it.
    public var subtaskWaits: [Int: [String]] {
        let idle = Set(tasks.filter { $0.state == "working" && $0.works == false }.map(\.id))
        guard !idle.isEmpty else { return [:] }
        var open: [Int: [FleetTask]] = [:]
        for task in tasks where !task.isTerminal {
            if let parent = task.parent, idle.contains(parent) { open[parent, default: []].append(task) }
        }
        return open.mapValues { subtasks in
            var agents: [String] = []
            for task in subtasks.sorted(by: { ($0.activityTime, $0.id) > ($1.activityTime, $1.id) }) where !agents.contains(task.owner) {
                agents.append(task.owner)
            }
            return agents
        }
    }

    /// The words of a task that waits for its subtasks, at the end of its agent's line on the board: "Waiting for
    /// Web-Dev", the words of a task that waits for an agent.
    public static func subtaskWords(_ agents: [String]) -> String {
        String(l10n: "Waiting for \(agents.map(\.agentLabel).joined(separator: ", "))")
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
    /// can move (an outcome that is not known and that no session of its agent checks first, a stop that was not
    /// confirmed). The count of the sidebar's Needs you row, and what the Needs you page lists.
    public var needsYouCount: Int { needs.filter(\.isOpen).count + ownerTasks.count }

    /// The tasks that only the owner can move, newest first: an outcome that is not known and that no session of its
    /// agent checks first (`TaskOutcome.waitsOnOwner`), a stop that was not confirmed. The Needs you page lists them
    /// under the open requests, so its row's count is what the page shows.
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

/// **The Waiting column, as it shows** (the owner's "Yes, build it" of 18 November 2026 to its picture, after "would you
/// still show them here as tasks?" of the cards that said "Until Thu 12:12", "Until 26 Nov"): a card for each thing that
/// waits for something now, and **every task that only a time holds behind one row, "9 later"**, which opens them by
/// the day that they start again. On his fleet that day 11 of 14 open tasks were parked, six of them until 21 to 28
/// November, so Waiting was mostly a calendar, and a question or a hold was hard to find in it. A thing that he asked
/// for keeps its card, with the earliest time of its tasks: it is his, and he looks for it.
public struct WaitingTasks: Sendable {
    /// One calendar day of this Mac, by its first moment, with the jobs that start again on it, the soonest first.
    public struct Day: Identifiable, Sendable {
        public let start: Double
        public let jobs: [Job]
        public var id: Double { start }
    }

    /// The cards, in the board's order: what waits for him first.
    public let cards: [Job]
    /// The jobs behind the row, by day, the soonest day first.
    public let later: [Day]
    /// How many jobs `later` holds.
    public let laterCount: Int

    /// `items`: the Waiting column of the board (`HubState.board`). **A job folds when nothing but a time holds it**
    /// (`Job.onlyLater`): each open task of it is parked by its agent and waits on nothing else (`parkedOnly`), no hold
    /// that is not released and no usage limit of its agent holds one, and it waits for nothing of the owner's. Each of
    /// those is a wait of its own, which its card says ("Paused", "Usage limit", "Waiting for Fleet Manager", the
    /// orange line), so such a job stays a card. So does a job that he asked for.
    public init(items: [Job], calendar: Calendar = .current) {
        var cards: [Job] = [], parked: [Job] = []
        for job in items {
            if job.onlyLater && !job.asked { parked.append(job) } else { cards.append(job) }
        }
        self.cards = cards
        laterCount = parked.count
        var days: [Day] = []
        for job in parked.sorted(by: { ($0.until ?? 0, $0.order) < ($1.until ?? 0, $1.order) }) {
            let start = calendar.startOfDay(for: Date(timeIntervalSince1970: job.until ?? 0)).timeIntervalSince1970
            if days.last?.start == start {
                days[days.count - 1] = Day(start: start, jobs: days[days.count - 1].jobs + [job])
            } else {
                days.append(Day(start: start, jobs: [job]))
            }
        }
        later = days
    }
}

/// **The Done column, as it shows** (the owner's yes of 11 November 2026: "Ended shows only what did not succeed",
/// and his answer of 18 November 2026: the results of what he asked for too): the results that he must see, a card
/// each (`cards`), and every other ended job behind one row that opens them by day. A
/// fleet ends more than a hundred tasks a week, and nine of ten are a checked result: as one card each they hid the
/// ones that failed.
public struct EndedTasks: Sendable {
    /// One or more tasks of one day that are one row: one task, or the runs of one schedule, or tasks of one agent
    /// with the same title, newest first.
    public struct Group: Identifiable, Sendable {
        public let title: String
        public let tasks: [FleetTask]
        /// For the row of one thing that he asked for: the agent that he asked. nil for every other row.
        public let agent: String?
        /// Its oldest task: a run that ends later joins the row at its head, and the row he opened stays open.
        public var id: Int { tasks[tasks.count - 1].id }
        public var owner: String { agent ?? tasks[0].owner }

        init(title: String, tasks: [FleetTask], agent: String? = nil) {
            self.title = title
            self.tasks = tasks
            self.agent = agent
        }
    }

    /// One result that he must see: a task, under its own title and agent, or one thing that he asked for, under its
    /// name and the agent that he asked, with the task of it whose result did not succeed.
    public struct Failed: Identifiable, Sendable {
        public let title: String
        public let owner: String
        public let task: FleetTask
        public var id: Int { task.id }
    }

    /// One calendar day of this Mac, by its first moment, with its rows, newest first.
    public struct Day: Identifiable, Sendable {
        public let start: Double
        public let groups: [Group]
        public var id: Double { start }
    }

    /// The results that are not a success, newest first: failed, rejected, not accepted.
    public let failed: [FleetTask]
    /// The same results as rows: a job under its own name and agent, with the task of it that did not succeed (`Failed`).
    public let failedRows: [Failed]
    /// **The jobs that are a card in Done**: a job that he asked for with the result that its requester checked
    /// (`Job.showsResult`), and a job whose last word did not succeed (his answer of 18 November 2026 to "Where does a
    /// routine one go when it is done?": "Behind 'more'", with the results of what he asked for and what failed as
    /// cards). **What he asked for stands first**, the one that ended last first, then the other jobs that did not
    /// succeed: on the first fleet 17 jobs of a week had failed, most of them routine work, and as one list by time
    /// they stood over the answers that he looks for.
    public let cards: [Job]
    /// Every other ended job, newest day first.
    public let days: [Day]
    /// How many jobs `days` holds.
    public let rest: Int

    /// `tasks`: ended tasks, newest first, each as a job of its own.
    public init(_ tasks: [FleetTask], calendar: Calendar = .current) {
        self.init(items: tasks.map(Job.init(ended:)), calendar: calendar)
    }

    /// `items`: the Done column of the board, of all agents or of one, newest first (`HubState.board`). **One job is
    /// one row or one card**: a card when its last word did not succeed (`Job.failed`) or when he asked for it and its
    /// result is checked; else behind "more" on the day that it ended, where the row of a job of several tasks opens
    /// them, as the row of a schedule's runs does. It counts as one in `rest`.
    public init(items: [Job], calendar: Calendar = .current) {
        var failedRows: [Failed] = [], cards: [Job] = [], others: [Job] = []
        for job in items {
            if let task = job.failed {
                failedRows.append(Failed(title: job.title, owner: job.agent, task: task))
                cards.append(job)
            } else if job.showsResult {
                cards.append(job)
            } else {
                others.append(job)
            }
        }
        self.failedRows = failedRows
        failed = failedRows.map(\.task)
        self.cards = cards.sorted { ($0.asked ? 1 : 0, $0.endedAt, $0.order) > ($1.asked ? 1 : 0, $1.endedAt, $1.order) }
        rest = others.count
        var days: [Day] = []
        var day: (start: Double, items: [Job])?
        func close() {
            guard let day else { return }
            var tasks: [FleetTask] = [], groups: [Group] = []
            for job in day.items {
                // A task that nothing joins to another is a row of the day's own, where the runs of one schedule are
                // one row, as before. A job with a name of its own (an ask, a case) or with several tasks is one row.
                if case .task = job.key, job.tasks.count == 1 {
                    tasks.append(job.tasks[0])
                } else {
                    groups.append(Group(title: job.title, tasks: job.tasks, agent: job.agent))
                }
            }
            let rows = groups.isEmpty ? Self.groups(tasks) : (Self.groups(tasks) + groups).sorted {
                ($0.tasks[0].activityTime, $0.tasks[0].id) > ($1.tasks[0].activityTime, $1.tasks[0].id)
            }
            days.append(Day(start: day.start, groups: rows))
        }
        for job in others {
            let start = calendar.startOfDay(for: Date(timeIntervalSince1970: job.activityTime)).timeIntervalSince1970
            if day?.start != start { close(); day = (start, []) }
            day?.items.append(job)
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

/// **How long something has stood where it stands**, in a few words: "Just now", "for 5 min", "for 3 h", "for 2 days"
/// (the owner, 19 November 2026, of a job card's time: "something like "for X hours" or "for Y minutes"").
public func activityFor(_ since: Double, now: Double) -> String {
    let seconds = max(0, now - since)
    switch seconds {
    case ..<60: return String(l10n: "Just now")
    case ..<3600: return String(l10n: "for \(Int(seconds / 60)) min")
    case ..<86_400: return String(l10n: "for \(Int(seconds / 3600)) h")
    default: return Int(seconds / 86_400) == 1 ? String(l10n: "for 1 day") : String(l10n: "for \(Int(seconds / 86_400)) days")
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
