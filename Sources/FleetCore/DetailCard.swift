import Foundation

/// **What the detail card over the window shows** (the owner, 20 November 2026, of the Tasks board: "we should probably
/// consider showing the cards here as modals once clicked instead of moving pages", and 21 November 2026: "task details
/// to open as a modal, as I already mentioned yesterday and hasn't been done yet, even for the tasks page!"). A task and
/// a job are no pages of their own: each place that opened their page opens this card over the page that shows, and
/// the page under it stays as it is.
///
/// - `task`: the task level, its thread and its facts.
/// - `job`: the job level of a card of the Tasks board, by its card's id on that board (`Job.id`) and the agent whose
///   board it is (nil for every agent's): an agent's part of another agent's job has an id of its own on that agent's
///   board only.
/// - `work`: the job level of a thing of an agent's work (`WorkItem`), from a row of the card Work of that agent's chat
///   panel.
///
/// A place holds keys and no values: each reading of the hub draws the card from its own tasks, so a task that opens a
/// case leads to that case as its row in the panel does (`HubState.workItem`).
public enum DetailPlace: Hashable, Sendable {
    case task(Int)
    case job(String, board: String?)
    case work(String, WorkItem.Key)

    /// The task of the task level, or nil for a job level.
    public var task: Int? { if case .task(let id) = self { id } else { nil } }
}

/// **The card's two levels** (design "Task details as a card over the page", 21 November 2026): the level that
/// shows, and the job level that a task level came from, for its back link and for Esc. At most two levels and no
/// stack: a task that a row of the facts opens takes the place of the task that shows, and keeps the job under it.
public struct DetailCard: Identifiable, Equatable, Sendable {
    /// The job level that the task level came from, or nil.
    public let under: DetailPlace?
    public let shown: DetailPlace
    /// One card: a change of its level keeps the card, which then changes its size and does not come again.
    public var id: String { "detail" }

    public init(_ shown: DetailPlace) { self.init(under: nil, shown: shown) }

    init(under: DetailPlace?, shown: DetailPlace) {
        self.under = under?.task == nil ? under : nil
        self.shown = shown
    }

    /// **The card after a press that opens `place`.** Only a row of the card itself is a press inside it (`inCard`: a
    /// task's row of the job level, and Follow-up to, Parent task and a subtask of the task's facts): a task from the
    /// job level opens the task level over that job, and a task from the task level takes the place of the one that
    /// shows with the same job under it. Every other opener opens the card fresh, also while a card shows (the search
    /// card's result, `setup_show`, the task that the app kept at its start): that task is no row of the job that
    /// shows, and its back link would name a job that is not its own. A job always takes the whole card.
    public static func showing(_ place: DetailPlace, over card: DetailCard?, inCard: Bool) -> DetailCard {
        guard inCard, let card, place.task != nil else { return DetailCard(place) }
        return DetailCard(under: card.shown.task == nil ? card.shown : card.under, shown: place)
    }

    /// **One level back**, for the back link and for Esc: the job that the task level came from, else nothing, and the
    /// card closes (the app's pages go back on Esc the same way).
    public var back: DetailCard? { under.map(DetailCard.init) }

    /// **The card as a new reading of the hub has it, with its job levels as that reading gives them** (`levels`,
    /// worked out once for the reading and read by the card and its back link). A task or a job that the hub lists no
    /// more closes the card, and so does a reading of another hub or of another generation of it, whose tasks are
    /// other tasks under the same numbers, and a moment with no reading: a card that only Esc ends would show nothing.
    /// A job under a task that the hub lists no more goes, with its back link. `before`: the reading that this one
    /// takes the place of, or nil for the first one.
    public func kept(in state: HubState?, before: HubState?) -> (card: DetailCard, levels: DetailLevels)? {
        guard let state, before.map({ $0.db == state.db }) ?? true else { return nil }
        let levels = state.levels(of: self)
        guard levels.listed else { return nil }
        guard under != nil, levels.under == nil else { return (self, levels) }
        return (DetailCard(shown), DetailLevels(shown: levels.shown, under: nil, listed: true))
    }
}

/// **The job levels of one card, as one reading gives them**: the level that shows (nil for a task level), the job
/// under a task level (for its back link), and whether the reading lists what shows. A job of the board is found by
/// working out that board over every task of the reading (`HubState.jobs(of:)`), so a card works its levels out once
/// for each reading and each change of the card, and not at each draw (`FleetStore.detailLevels`).
public struct DetailLevels: Sendable {
    public let shown: JobLevel?
    public let under: JobLevel?
    public let listed: Bool
}

/// **The job level, from either model of a job** (`JobDetail`): a card of the Tasks board (`Job`) and a thing of an
/// agent's work (`WorkItem`) give the same few facts, so one view draws both.
public struct JobLevel: Sendable {
    /// Its name: the card's, or the thing's.
    public let title: String
    /// The agent whose job it is: the card's, or the agent of the chat panel that opened it.
    public let agent: String
    /// The open request that it waits on, whose own card stands first (`NeedRequestCard`), or nil.
    public let request: Int?
    /// Its tasks as the card lists them: in the order they began, each subtask under the task that gave it.
    public let lines: [WorkItem.Line]
    /// The tasks of it that are not over, for the status row of one that goes on; empty once it ended.
    public let open: [FleetTask]
    /// How it ended (`WorkItem.result`), or nil while it goes on.
    public let result: (words: String, end: WorkItem.End)?
    /// What its agent recorded when it closed its case (`WorkItem.recorded`), or nil.
    public let recorded: String?
    /// When it ended, or nil while it goes on.
    public let endedAt: Double?
}

extension WorkItem {
    /// **What its agent recorded when it closed its case**: a ticket's symptom and the part of the system, in the words
    /// of the owner's lists ("Listing data wrong · Listing sync"), else the agent's own note; nil for work of no case.
    public var recorded: String? {
        guard let c = dutyCase, !c.isOpen else { return nil }
        if let facts = c.facts { return ["symptom", "component"].compactMap { facts[$0] }.joined(separator: " · ") }
        return c.note
    }
}

extension Job {
    /// **The level that a press on its card opens** (design 1.1, "Which level opens"): the job level for a job of more
    /// than one task line and for one that waits on an open request, else the task level of its one task. A list of
    /// one row says nothing that the task's own card does not say. A job whose lines somebody canceled all opens the
    /// task that its card stands for (`lead`).
    public func detail(board: String?) -> DetailPlace? {
        let lines = self.lines
        if case .request = wait { return .job(id, board: board) }
        if lines.count > 1 { return .job(id, board: board) }
        return (lines.first ?? lead).map { .task($0.id) }
    }
}

extension HubState {
    /// **The level that a row of the card Work of `agent`'s chat panel opens** (design 1.1): the job level for a thing
    /// that has a case or more than one task, else the task level of its one task; nil for a thing that the reading
    /// has no more.
    public func detail(of key: WorkItem.Key, agent: String) -> DetailPlace? {
        guard let item = workItem(key) else { return nil }
        let lines = item.lines
        if case .dutyCase = item.id { return .work(agent, item.id) }
        if lines.count == 1 { return .task(lines[0].task.id) }
        return .work(agent, item.id)
    }

    /// **The card of the board of `board` (nil: of every agent) whose id is `id`**, whatever its period, or nil when
    /// that board has it no more: a job that a task of it moved to a case is the case's card now.
    public func job(_ id: String, board: String?) -> Job? { jobs(of: board).first { $0.id == id } }

    /// Whether this reading lists what a place shows.
    public func has(_ place: DetailPlace) -> Bool { levels(of: DetailCard(place)).listed }

    /// **The job levels of a card, as this reading has them** (`DetailLevels`): each board that a level of it names is
    /// worked out once. They are read again at each reading, never kept from the press that opened the card.
    public func levels(of card: DetailCard) -> DetailLevels {
        var boards: [String?: [Job]] = [:]
        func level(_ place: DetailPlace) -> JobLevel? {
            switch place {
            case .task: return nil
            case .job(let id, let board):
                let jobs = boards[board] ?? jobs(of: board)
                boards[board] = jobs
                return jobs.first { $0.id == id }.map(jobLevel)
            case .work(let agent, let key):
                guard let item = workItem(key) else { return nil }
                let open = item.isOver ? [] : item.tasks.filter { !$0.isTerminal }
                let waits = ownerWaits(of: open).sorted { $0.key < $1.key }.map(\.value)
                return JobLevel(title: item.title, agent: agent, request: request(of: waits),
                                lines: item.lines, open: open, result: item.result, recorded: item.recorded,
                                endedAt: item.endedAt)
            }
        }
        let shown = level(card.shown)
        let listed = card.shown.task.map { id in tasks.contains { $0.id == id } } ?? (shown != nil)
        return DetailLevels(shown: shown, under: card.under.flatMap(level), listed: listed)
    }

    /// A card of the board as the same facts: its own tasks with none that somebody canceled, as its card lists them,
    /// each subtask under the task that gave it, and how it ended by the rules of a thing of the work.
    private func jobLevel(_ job: Job) -> JobLevel {
        let shown = job.lines
        let head: CaseHead? = if case .dutyCase(let id) = job.key { responsibilities?.byID[id] } else { nil }
        let key: WorkItem.Key = if case .dutyCase(let id) = job.key { .dutyCase(id) } else { .task(job.firstTask) }
        let item = WorkItem(id: key, title: job.title, tasks: job.tasks.sorted { $0.id < $1.id }, shown: shown,
                            dutyCase: head, endedAt: job.open.isEmpty && !job.tasks.isEmpty ? job.endedAt : nil)
        return JobLevel(title: job.title, agent: job.agent, request: request(of: job.wait.map { [$0] } ?? []),
                        lines: item.lines, open: job.open, result: item.result, recorded: item.recorded,
                        endedAt: item.endedAt)
    }

    /// The first of these waits that is an open request of his.
    private func request(of waits: some Sequence<OwnerWait>) -> Int? {
        for wait in waits {
            if case .request(let id, _) = wait, needs.contains(where: { $0.id == id && $0.isOpen }) { return id }
        }
        return nil
    }
}
