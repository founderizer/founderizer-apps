import Foundation

/// **One thing that the owner asked for** (owner feature `asks`; his words of 15 November 2026: "I am not interested in
/// the specific individual tasks to be done but in the thing I asked for to be done", and to the two pictures of it,
/// "Both places"). It is one message of his own, by its `request_id`, with every task that carries that value in its
/// `ask`: the first task that an agent made from the message, its subtasks and every task that followed one of them.
/// The hub keeps only those links. Where the ask stands is read here, from its tasks, **with the board's own rules**
/// (`HubState.taskColumns`), so a card of several tasks stands where its tasks stood.
public struct Ask: Identifiable, Sendable {
    /// The `request_id` of his message.
    public let id: String
    /// Its name in his lists: the message's `asked`, which the first task of the message wrote.
    public let title: String
    /// The agent that he asked: the message's recipient.
    public let agent: String
    /// When he asked.
    public let created: Double
    /// Every task of it, the one that moved last first.
    public let tasks: [FleetTask]
    /// The tasks of it that are not over, the one that moved last first; also one that ended and that only he can move.
    public let open: [FleetTask]
    /// The task that its card opens: the one that waits for him, else the one in work, else the open one that moved
    /// last, else the one that moved last. An ask has one task or more, so it is nil for none.
    public var lead: FleetTask? { waitTask ?? working ?? open.first ?? tasks.first }
    /// Where it stands: Waiting while something of it waits for him, else In progress while a task of it is in work,
    /// else Waiting while a task of it is open, else Ended.
    public let column: ActivityColumn
    /// What it waits for from him, or nil: what a task of it waits for (`HubState.ownerWaits`), else an open request
    /// that names it (`OwnerNeed.ask`).
    public let wait: OwnerWait?
    /// The task of it that waits for him, when a task does: the one that its card opens then, because an outcome that
    /// is not known, or a stop that was not confirmed, is settled in that task.
    public let waitTask: FleetTask?
    /// The task of it that is in work and moved last, or nil.
    public let working: FleetTask?
    /// The earliest time until which an open task of it is parked, or nil.
    public let until: Double?
    /// **For an ask that ended: the task that has its last word and whose result did not succeed**, or nil. The last
    /// word is a task's that is no subtask of another task of the ask (a subtask's result is its requester's to check,
    /// and that task's own result says what came of it), that nobody canceled, and that no later task put right: a
    /// task is put right when a task that nobody canceled follows it or a subtask of it. 80 of 98 follow-ups on the
    /// first fleet came after such a result. A follow-up that somebody canceled put nothing right.
    public let failed: FleetTask?
    /// For an ask that ended: a result that has its last word still waits for its requester's check, so the card of a
    /// chat does not call it done yet.
    public let unchecked: Bool
    /// For an ask that ended: no task has a last word, because somebody canceled each one that could. Somebody chose
    /// to end it, so the card of a chat says nothing of it: neither done nor failed.
    public let canceled: Bool
    /// When its last word was said: the latest activity, delivery or check of its tasks.
    public let endedAt: Double

    /// When a task of it moved last.
    public var activityTime: Double { tasks.first?.activityTime ?? created }
    /// Whether nothing of it is open.
    public var isOver: Bool { column == .done }
}

/// **One card of the board for all agents**: a task that no message of his began, as before, or one thing that he
/// asked for, with its tasks behind it.
public enum BoardItem: Identifiable, Sendable {
    case task(FleetTask)
    case ask(Ask)

    public var id: String {
        switch self {
        case .task(let task): "task \(task.id)"
        case .ask(let ask): "ask \(ask.id)"
        }
    }

    /// When it moved last.
    public var activityTime: Double {
        switch self {
        case .task(let task): task.activityTime
        case .ask(let ask): ask.activityTime
        }
    }

    /// The task of a card of one task, and the newest task of an ask: the order's last word, as the board's is.
    var order: Int {
        switch self {
        case .task(let task): task.id
        case .ask(let ask): ask.tasks.first?.id ?? 0
        }
    }
}

extension HubState {
    /// **The things that he asked for**, the newest first. A task with an `ask` whose message this reading does not
    /// hold still makes one, under its oldest task's title and agent, so that no work of his is left out.
    public var asks: [Ask] {
        var members: [String: [FleetTask]] = [:]
        for task in tasks {
            if let ask = task.ask, !ask.isEmpty { members[ask, default: []].append(task) }
        }
        guard !members.isEmpty else { return [] }
        let asked = Dictionary(messages.map { ($0.request_id, $0) }) { first, _ in first }
        let columns = taskColumns, waits = ownerWaits
        let requests = Dictionary(needs.filter(\.isOpen).compactMap { need in need.ask.map { ($0, need) } }) { first, _ in first }
        return members.map { id, unsorted in
            let tasks = unsorted.sorted { ($0.activityTime, $0.id) > ($1.activityTime, $1.id) }
            let oldest = unsorted.min { $0.id < $1.id } ?? tasks[0]
            let message = asked[id]
            let open = tasks.filter { columns[$0.id] != .done }
            let waitTask = tasks.first { waits[$0.id] != nil }
            let wait = waitTask.flatMap { waits[$0.id] } ?? requests[id].map { OwnerWait.request(id: $0.id, title: $0.title) }
            let working = open.first { columns[$0.id] == .inProgress }
            let column: ActivityColumn = wait != nil ? .waiting : working != nil ? .inProgress : open.isEmpty ? .done : .waiting
            // The tasks that have its last word (`Ask.failed`). Each task belongs to its top task: the task of the
            // ask that it is, in the end, a subtask of.
            let byID = Dictionary(tasks.map { ($0.id, $0) }) { first, _ in first }
            var top: [Int: Int] = [:]
            for task in tasks {
                var above = task, steps = 0
                while steps < tasks.count, let parent = above.parent.flatMap({ byID[$0] }) {
                    above = parent
                    steps += 1
                }
                top[task.id] = above.id
            }
            // Put right: a task that nobody canceled, under another top task, follows a task under this one. A
            // canceled task put nothing right itself, so the task that follows it puts right what it followed too.
            var putRight: Set<Int> = []
            for task in tasks where task.state != "canceled" {
                var earlier = task.follows.flatMap { byID[$0] }, steps = 0
                while let followed = earlier, steps < tasks.count {
                    if let under = top[followed.id], under != top[task.id] { putRight.insert(under) }
                    earlier = followed.state == "canceled" ? followed.follows.flatMap { byID[$0] } : nil
                    steps += 1
                }
            }
            let ends = column == .done
                ? tasks.filter { top[$0.id] == $0.id && $0.state != "canceled" && !putRight.contains($0.id) } : []
            let said = tasks.map { max($0.activityTime, $0.delivered ?? 0, $0.checked_at ?? 0) }.max()
            return Ask(id: id, title: message?.asked ?? oldest.title, agent: message?.chatRecipient ?? oldest.owner,
                       created: message?.created ?? oldest.created, tasks: tasks, open: open, column: column, wait: wait,
                       waitTask: waitTask, working: working, until: open.compactMap(\.parked_until).min(),
                       failed: ends.first(where: \.endedBadly),
                       unchecked: ends.contains { $0.state == "completed" && $0.accepted == nil },
                       canceled: column == .done && ends.isEmpty,
                       endedAt: said ?? message?.created ?? oldest.created)
        }.sorted { ($0.created, $0.id) > ($1.created, $1.id) }
    }

    /// **The Tasks board, with one card for each thing that he asked for** (his "Both places" of 15 November 2026 to its
    /// picture). A task of an ask is on no card of its own: it is behind the card of its ask, which stands in the column
    /// of the ask. Every other task is a card as before. The order is the board's: the one that moved last first, and in
    /// Waiting what waits for him before the rest. **An ask that is open shows whatever the period**: it is work that he
    /// asked for and that is not done. An ask that ended shows when one task of it is in the period.
    ///
    /// **`agent`: the board of one agent** (his "Yes, build it" of 17 November 2026 to the picture of Tasks with the
    /// Fleet Manager chosen, which View all of the card Asked opens): the things that he asked that agent for, whoever
    /// does their tasks, and that agent's other tasks, its work on what he asked another agent too. The Fleet Manager
    /// owns no task of its own, so its board showed nothing. nil: every agent's.
    public func board(period: ActivityPeriod, agent: String? = nil, calendar: Calendar = .current) -> [ActivityColumn: [BoardItem]] {
        let start = period.start(now: Date(timeIntervalSince1970: time), calendar: calendar)?.timeIntervalSince1970 ?? -.infinity
        let waits = ownerWaits, column = taskColumns
        var columns: [ActivityColumn: [BoardItem]] = [:]
        var waiting: Set<String> = []
        // The asks of this board: their tasks are behind their cards, also when their period leaves the card out.
        var carded: Set<String> = []
        for ask in asks where agent == nil || ask.agent == agent {
            carded.insert(ask.id)
            guard !ask.isOver || ask.tasks.contains(where: { $0.activityTime >= start }) else { continue }
            columns[ask.column, default: []].append(.ask(ask))
            if ask.wait != nil { waiting.insert(BoardItem.ask(ask).id) }
        }
        for task in tasks where (agent == nil || task.owner == agent) && !carded.contains(task.ask ?? "")
            && (task.activityTime >= start || waits[task.id] != nil) {
            columns[column[task.id] ?? .waiting, default: []].append(.task(task))
            if waits[task.id] != nil { waiting.insert(BoardItem.task(task).id) }
        }
        var sorted = columns.mapValues { $0.sorted { ($0.activityTime, $0.order) > ($1.activityTime, $1.order) } }
        if let lane = sorted[.waiting] {
            sorted[.waiting] = lane.filter { waiting.contains($0.id) } + lane.filter { !waiting.contains($0.id) }
        }
        return sorted
    }
}

/// **The card Asked of an agent's chat panel, as it shows** (his "Both places" of 15 November 2026 to its picture):
/// the things that he asked that agent for, the newest first, one row each **while the row has news** — it waits for
/// him, an agent works on it now, or it ended and he has not seen that yet — then **every other open one, which only
/// waits, as a row of its own too** (`waits`; the owner, 17 November 2026, of the row "2 waiting", which opened the
/// whole Tasks board: "if it's only 3 elements you could have shown them there directly!"), **while they are three or
/// fewer**; more are one row with their number, which opens them in place (`ownRows`). An ask that ended and that he
/// has seen is on the Tasks page, with everything that ended.
/// **A result shows when its requester has checked it**, and until then the card says nothing of the ask: a "Done"
/// that a refused result takes back is worse than none. An ask that somebody canceled has no row. **A result shows
/// again when a later task of the ask ends**: what he has seen of an agent's asks is a time (`after`), and an ask
/// whose last word came later than it shows.
public struct AskedCard: Sendable, Equatable {
    /// What a row's mark says. `quiet`: it only waits, and not for him: the mark of the task whose wait it says
    /// (`FleetTask.mark`), muted, and that task's state word, as its row in the chat draws it (`ChatAskRow`).
    public enum Mark: Sendable, Equatable { case waitsForOwner, working, done, failed, quiet(symbol: String, word: String) }

    public struct Row: Identifiable, Sendable, Equatable {
        public let id: String
        public let title: String
        public let mark: Mark
        /// The agent that works on it now, for a row in work; nil when that is the agent of the chat, whose card
        /// stands over this one.
        public let worker: String?
        /// For a row in work: that task is work now by its own mark (`FleetTask.mark`: a turn of it runs, and it
        /// neither stalled nor lost its session), so its mark turns. A task between two turns is still in progress on
        /// the board, and its mark stands still: a mark that turns says work now.
        public let moves: Bool
        /// What that agent's running turn does, in the hub's words, or nil.
        public let doing: String?
        /// The request that it waits on, for a row that waits for his answer to one.
        public let request: Int?
        /// What it waits for from him, in words: a request's title, or the words of an outcome, a stop or a sign-in.
        public let waits: String?
        /// The red word of a result that did not succeed.
        public let failedWord: String?
        /// The task that a click opens: the one in work, the one that failed, else the one that moved last.
        public let task: Int?
        /// For a row of an ask that ended: when its last word was said (`Ask.endedAt`). nil for an open ask.
        public let end: Double?
        /// For a row that only waits: until when its agent parked the work, which the app writes as the Tasks board
        /// does ("Until 15:00") in place of its line; nil when a hold or a usage limit stops it, or no time does.
        public let until: Double?

        /// **The row's one muted line**: that it waits for him; the agent that works on it now, by its role, and what
        /// its running turn does; that it is done; the word of a result that did not succeed; or for one that only
        /// waits, why, in the board's words ("Waiting for Shop Developer", "Queued").
        public var line: String {
            switch mark {
            case .waitsForOwner: String(l10n: "Waits for you")
            case .working: [worker?.agentLabel, doing].compactMap { $0 }.joined(separator: " · ")
            case .done: String(l10n: "Done")
            case .failed: failedWord ?? String(l10n: "Failed")
            case .quiet(_, let word): word
            }
        }
        /// What the row says to the pointer and to VoiceOver under its title: what it waits for, else its line.
        public var words: String { waits ?? line }
    }

    /// The card's name over its rows.
    public static var title: String { String(l10n: "Asked") }
    /// The row of the things that only wait, with their number.
    public static func waitingWords(_ count: Int) -> String { String(l10n: "\(count) waiting") }
    /// **The most things that only wait that stand as rows of their own**; more are one row with their number, which
    /// opens them in place and closes them again (his "Yes, fold them" of 17 November 2026, to the pictures of four
    /// that wait, closed and open).
    public static let ownRows = 3

    public let rows: [Row]
    /// **The open things of this agent that only wait** — for a time, for another agent, for their turn — in the order
    /// in which he asked, the newest first, each with the mark and the words of its row in the chat (`ChatAskRow`):
    /// muted, in the Tasks board's words ("Until 15:00", "Waiting for Shop Developer", "Queued"), and its click opens
    /// the task whose wait the line says.
    public let waits: [Row]
    /// How many open things of this agent only wait.
    public var waiting: Int { waits.count }

    public var isEmpty: Bool { rows.isEmpty && waits.isEmpty }
    /// The things that only wait stand as rows of their own (`ownRows`), and need no row with their number.
    public var waitsInRows: Bool { waits.count <= Self.ownRows }

    /// `asks`: `HubState.asks`. `agent`: the agent of the chat. `after`: an ask that ended shows when its last word
    /// came after this time: the newest end that he has seen in this agent's card, and for a Mac that reads a fleet
    /// for the first time, that first reading's time, so that it does not show the fleet's whole past. `state`: the
    /// reading that `asks` came from, for the marks and the words of the things that only wait (the holds, the usage
    /// limits and the subtasks that a task's wait reads).
    public init(_ asks: [Ask], agent: String, after: Double, state: HubState? = nil) {
        var rows: [Row] = [], waits: [Row] = []
        for ask in asks where ask.agent == agent {
            if let wait = ask.wait {
                var request: Int?
                if case .request(let id, _) = wait { request = id }
                rows.append(Row(id: ask.id, title: ask.title, mark: .waitsForOwner, worker: nil, moves: false, doing: nil,
                                request: request, waits: wait.words, failedWord: nil, task: ask.lead?.id, end: nil, until: nil))
            } else if let task = ask.working {
                rows.append(Row(id: ask.id, title: ask.title, mark: .working, worker: task.owner == agent ? nil : task.owner,
                                moves: task.mark(holds: [], limited: false).inWork, doing: task.doing, request: nil,
                                waits: nil, failedWord: nil,
                                task: task.id, end: nil, until: nil))
            } else if !ask.isOver {
                // Why it waits, and the task that a click opens, as its row in the chat says them.
                let quiet = ChatAskRow(ask, agent: agent, state: state)
                waits.append(Row(id: ask.id, title: ask.title, mark: .quiet(symbol: quiet.symbol, word: quiet.line), worker: nil,
                                 moves: quiet.moves, doing: nil, request: nil, waits: nil, failedWord: nil, task: quiet.task,
                                 end: nil, until: quiet.until))
            } else {
                let failed = ask.failed
                // Nothing to say yet, or nothing new: somebody canceled it, a result of it waits for its check, or he
                // has seen this end.
                if (failed == nil && (ask.canceled || ask.unchecked)) || ask.endedAt <= after { continue }
                rows.append(Row(id: ask.id, title: ask.title, mark: failed == nil ? .done : .failed, worker: nil, moves: false,
                                doing: nil, request: nil, waits: nil, failedWord: failed?.failedResult,
                                task: failed?.id ?? ask.tasks.first?.id, end: ask.endedAt, until: nil))
            }
        }
        self.rows = rows
        self.waits = waits
    }

    /// The newest end that this card shows, or nil: what he has seen of this agent's asks once he leaves the chat.
    public var endedAt: Double? { rows.compactMap(\.end).max() }
}
