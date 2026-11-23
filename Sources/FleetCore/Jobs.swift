import Foundation

/// **Where one piece of work stands, read from its tasks with the board's own rules** (`HubState.taskColumns`): the
/// tasks of one thing that he asked for (`Ask`) or of one job (`Job`). The hub keeps only the links between tasks, so
/// a card of several tasks stands where its tasks stood.
struct JobStanding {
    /// Every task of it, the one that moved last first.
    let tasks: [FleetTask]
    /// The tasks of it that are not over, the one that moved last first; also one that ended and that only he can move.
    let open: [FleetTask]
    /// The task of it that waits for him, when a task does.
    let waitTask: FleetTask?
    /// What it waits for from him, or nil: what a task of it waits for, else the open request that names it.
    let wait: OwnerWait?
    /// The task of it that is in work and moved last, or nil.
    let working: FleetTask?
    /// Waiting while something of it waits for him, else In progress while a task of it is in work, else Waiting while
    /// a task of it is open, else Ended.
    let column: ActivityColumn
    /// **For one that ended: the tasks that have its last word.** The last word is a task's that is no subtask of
    /// another task of it (a subtask's result is its requester's to check, and that task's own result says what came
    /// of it), that nobody canceled, and that no later task put right: a task is put right when a task that nobody
    /// canceled follows it or a subtask of it. 80 of 98 follow-ups on the first fleet came after such a result. A
    /// follow-up that somebody canceled put nothing right. Empty while it is open, and when somebody canceled each task
    /// that could have the last word.
    let ends: [FleetTask]
    /// When its last word was said: the latest activity, delivery or check of its tasks; nil for no task.
    let said: Double?
    /// **Since when it stands in its column, while it is open** (`Job.columnSince`): in In progress since its open work
    /// first started, so a stall, a nudge or a lost session moves nothing, nor the return of a lead's task after its
    /// subtask; in Waiting since the oldest of what waits for him (a task's wait, or the request that names it), else
    /// since the open task that has waited longest, so a task that joins it later sets nothing back. nil once it ended.
    let openSince: Double?
    /// **The tasks of it that later work took over**: a task that a task follows (through tasks that somebody
    /// canceled), each task under a top task that is put right, a rejection that its requester accepted while a task
    /// of it made after the rejection went on, which nobody canceled, and, on the board of one agent, each task of its
    /// part that the whole job's later work took over (`elsewhere`). One of them that ended badly is no failure of its
    /// job: its card counts it in no group, and its row's mark is muted (the owner, 19 November 2026, of red words on
    /// cards whose work was done: "Can you investigate why some tasks show "failed" or "rejected" and what actually
    /// happens to them", then "Yes, fix it" to red only while a failure still needs something).
    let replaced: Set<Int>
    /// The earliest time until which an open task of it is parked, or nil.
    let until: Double?

    /// The task of `ends` whose result did not succeed, or nil.
    var failed: FleetTask? { ends.first(where: \.endedBadly) }
    /// A result that has its last word still waits for its requester's check.
    var unchecked: Bool { ends.contains { $0.state == "completed" && $0.accepted == nil } }
    /// Somebody canceled each task that could have its last word: neither done nor failed.
    var canceled: Bool { column == .done && ends.isEmpty }

    /// `request`: the open request that names this work, when one does (`OwnerNeed.ask`). `elsewhere`: for one agent's
    /// part of a job, the tasks that the whole job's later work took over (`replaced` of the whole job): the work of
    /// another agent that took a failure over is not in the part.
    init(_ unsorted: [FleetTask], columns: [Int: ActivityColumn], waits: [Int: OwnerWait], request: OwnerNeed? = nil,
         elsewhere: Set<Int> = []) {
        let tasks = unsorted.sorted { ($0.activityTime, $0.id) > ($1.activityTime, $1.id) }
        let open = tasks.filter { columns[$0.id] != .done }
        let waitTask = tasks.first { waits[$0.id] != nil }
        let wait = waitTask.flatMap { waits[$0.id] } ?? request.map { OwnerWait.request(id: $0.id, title: $0.title) }
        let working = open.first { columns[$0.id] == .inProgress }
        let column: ActivityColumn = wait != nil ? .waiting : working != nil ? .inProgress : open.isEmpty ? .done : .waiting
        // Each task belongs to its top task: the task of this work that it is, in the end, a subtask of.
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
        // Put right: a task that nobody canceled, under another top task, follows a task under this one. A canceled
        // task put nothing right itself, so the task that follows it puts right what it followed too.
        var putRight: Set<Int> = [], followed: Set<Int> = []
        for task in tasks where task.state != "canceled" {
            var earlier = task.follows.flatMap { byID[$0] }, steps = 0
            while let before = earlier, steps < tasks.count {
                followed.insert(before.id)
                if let under = top[before.id], under != top[task.id] { putRight.insert(under) }
                earlier = before.state == "canceled" ? before.follows.flatMap { byID[$0] } : nil
                steps += 1
            }
        }
        // **A rejection that its requester accepted, with later work of it, put nothing wrong**: its agent said that
        // the task was not its own to do, its requester agreed, and the work went on in another task, which may follow
        // another task of it (on the owner's fleet, 19 November 2026, the release of a fix followed the fix and not
        // the rejected hand-over, and the job's card in Done said "Rejected" over work that was done).
        // Later work is a task made after the rejection: not its own subtask, nor another part of the same step, which
        // its requester made beside it and which redid none of it (the second review, 19 November 2026).
        for task in tasks where task.state == "rejected" && task.accepted == 1 {
            let after = task.delivered ?? task.activityTime
            guard tasks.contains(where: { $0.id != task.id && $0.state != "canceled" && $0.created >= after }) else { continue }
            followed.insert(task.id)
            if top[task.id] == task.id { putRight.insert(task.id) }
        }
        for id in elsewhere where byID[id] != nil {
            followed.insert(id)
            if top[id] == id { putRight.insert(id) }
        }
        self.tasks = tasks
        self.open = open
        self.waitTask = waitTask
        self.wait = wait
        self.working = working
        self.column = column
        ends = column == .done
            ? tasks.filter { top[$0.id] == $0.id && $0.state != "canceled" && !putRight.contains($0.id) } : []
        said = tasks.map { max($0.activityTime, $0.delivered ?? 0, $0.checked_at ?? 0) }.max()
        switch column {
        case .inProgress:
            openSince = open.compactMap(\.started).min() ?? open.map(\.created).min()
        case .waiting:
            let owner = tasks.filter { waits[$0.id] != nil }.map(\.stateSince) + (request.map { [$0.raised] } ?? [])
            openSince = owner.min() ?? open.map(\.stateSince).min()
        default:
            openSince = nil
        }
        until = open.compactMap(\.parked_until).min()
        replaced = followed.union(tasks.filter { top[$0.id].map(putRight.contains) == true }.map(\.id))
    }
}

/// **One job: one piece of work with a start, an end and a result, which the Tasks page shows as one card with its
/// tasks inside** (owner feature `jobs`; the owner, 18 November 2026, of that page: "I dont really want to see the
/// detailed tasks being performed by each agent. I want to see what each agent is doing ... a higher level that shows
/// the task eli5 title, and then for example a subheader with 4 tasks working - 1 waiting - 3 done that can be expanded
/// ... Cards can be created by my questions OR by the agent itself, like when checking ticket XXXX ... do not confuse
/// this with DUTIES", "Job" for its name, and "Yes, build it" to its picture). A duty is standing work, which makes
/// jobs; a task is one step of one agent in a job.
///
/// The hub keeps no record of a job: it is the tasks that their links make one piece of work (`HubState.jobs`). Where
/// it stands is read here, from those tasks, with the board's own rules (`JobStanding`).
public struct Job: Identifiable, Sendable {
    /// What makes its tasks one piece of work: a message of his own, a case of a duty, or the task that begins it.
    public enum Key: Hashable, Sendable {
        case ask(String)
        case dutyCase(Int)
        case task(Int)
    }

    /// How many of its tasks stand where. A task that somebody canceled is in none.
    public struct Counts: Sendable, Equatable {
        public let working: Int, waiting: Int, done: Int, failed: Int
        public var total: Int { working + waiting + done + failed }
    }

    public let key: Key
    /// Its card's id on a board: "ask <message>", "case <id>", "task <id>", as the cards of that board always were;
    /// and with the agent's name after it for an agent's part of another agent's job (`HubState.board`).
    public let id: String
    /// Its name: the few words of his message (`asked`), the title of its case, or the `job_name` of the task that
    /// begins it, else that task's title.
    public let title: String
    /// The agent whose job it is: the one that he asked; for every other job, the agent of the task that matters now
    /// (`lead`). Work that passed from one agent to another is on the card of the agent that has it, and not of the
    /// one that began it or that holds its duty (the first real pictures of the board, 18 November 2026, named an
    /// agent that had left the fleet on a job that another agent worked, and the agent that had closed a case on the
    /// follow-up that another agent held).
    public let agent: String
    /// **He asked for it himself**, and this is the whole of it. An agent's part of what he asked another agent for is
    /// not: on that agent's board it is that agent's work, which shows by its period, folds behind "later" and ends
    /// behind "more" as its other work does (`HubState.board`).
    public let asked: Bool
    /// Every task of it, the one that moved last first.
    public let tasks: [FleetTask]
    /// The tasks of it that are not over, the one that moved last first; also one that ended and that only he can move.
    public let open: [FleetTask]
    /// Where its card stands. **What he asked for is not done until its result is checked** (his words of 18 November
    /// 2026: "Instead of DONE, it might require more information or to do further checks...that is fine, it can move
    /// through the board but can't be missed"): while the result that has its last word waits for its requester's
    /// check, it stands in Waiting and says so, and not behind "more" of Done.
    public let column: ActivityColumn
    /// What it waits for from him, or nil.
    public let wait: OwnerWait?
    /// The task of it that waits for him, when a task does: its card opens that one.
    public let waitTask: FleetTask?
    /// The task of it that is in work and moved last, or nil.
    public let working: FleetTask?
    /// The earliest time until which an open task of it is parked, or nil.
    public let until: Double?
    /// For one whose tasks all ended: the task that has its last word and whose result did not succeed, or nil.
    public let failed: FleetTask?
    /// For one whose tasks all ended: the result that has its last word and still waits for its requester's check.
    public let unchecked: FleetTask?
    /// For one whose tasks all ended: somebody canceled each task that could have its last word.
    public let canceled: Bool
    /// When its last word was said: the latest activity, delivery or check of its tasks.
    public let endedAt: Double
    /// **When it began**: his message, for what he asked for; else when its first task was made. Its card stands by
    /// it in Working and Waiting (the owner, 19 November 2026: "do not reorder the tasks
    /// in the same column, keep them in their position", and "show how long they've been sitting in a column since
    /// they started ... the card is still not done so it should show 34 minutes").
    public let began: Double
    /// **Since when it stands in its column**, for its card while it is open (the owner, 19 November 2026: "here the
    /// time should be something like "for X hours" or "for Y minutes", in the sense of "working for x hours on this
    /// task""): `JobStanding.openSince`, and in Done its last word. `began` keeps its place in the column.
    public let columnSince: Double
    /// The tasks of it that later work took over (`JobStanding.replaced`): one of them that ended badly is in no count,
    /// and its row's mark is muted; one that succeeded counts as done, with its own mark.
    public let replaced: Set<Int>
    /// **For one whose tasks all ended: what came of it, in plain words** (`FleetTask.plain` of the task that has its
    /// last word, the one that moved last), else the first words of that task's own result (`what`), which its agent
    /// wrote for its requester; nil while a task of it is open, and for one with no such words.
    public var result: String? { Self.words(resultPlain) ?? Self.words(resultDetails) }
    private let resultPlain: String?
    private let resultDetails: String?
    public let counts: Counts
    /// **Nothing but a time holds it**: each open task of it is parked and waits on nothing else, no hold and no usage
    /// limit holds one, and it waits for nothing of his. Such a job is behind the row "later" of Waiting
    /// (`WaitingTasks`), unless he asked for it.
    public let onlyLater: Bool

    /// The task that its card opens: the one that waits for him, else the one in work, else the open one that moved
    /// last, else the one that failed, else the one whose result waits for its check, else the one that moved last.
    public var lead: FleetTask? { waitTask ?? working ?? open.first ?? failed ?? unchecked ?? tasks.first }
    /// When a task of it moved last.
    public var activityTime: Double { tasks.first?.activityTime ?? endedAt }
    /// Whether its card stands in Done.
    public var isOver: Bool { column == .done }
    /// **For what he asked for, while only the check of its result holds it: who checks it** ("Waiting for Fleet
    /// Manager's check", the words of that task's own card: `FleetTask.checkStatus`); nil for every other job. Its
    /// card in Waiting says it at the end of its agent's line.
    public var checkWords: String? { column == .waiting && open.isEmpty && wait == nil ? unchecked?.checkStatus : nil }
    /// **Its card in Done says its result**: he asked for it, its last word is a result that its requester checked,
    /// and it did not fail (a failed one says so in red; `EndedTasks`). Routine work that ended is behind "more".
    public var showsResult: Bool { asked && isOver && failed == nil && !canceled && unchecked == nil }
    /// Its tasks as its card lists them when he opens it: in the order that they began, with none that somebody canceled.
    public var lines: [FleetTask] { tasks.filter { $0.state != "canceled" }.sorted { $0.id < $1.id } }
    /// The order's last word, as the board's is: its newest task.
    var order: Int { tasks.first?.id ?? 0 }
    /// Its first task, which no later task changes: the last word of the order of a lane that keeps its cards' places.
    var firstTask: Int { tasks.map(\.id).min() ?? 0 }

    init(key: Key, id: String, title: String, agent: String, asked: Bool, standing: JobStanding,
         columns: [Int: ActivityColumn], held: Set<Int>, limited: Set<String>, created: Double) {
        self.key = key
        self.id = id
        self.title = title
        self.agent = agent
        self.asked = asked
        tasks = standing.tasks
        open = standing.open
        let waitsForCheck = standing.failed == nil
            ? standing.ends.first { $0.state == "completed" && $0.accepted == nil } : nil
        column = standing.column == .done && asked && waitsForCheck != nil ? .waiting : standing.column
        wait = standing.wait
        waitTask = standing.waitTask
        working = standing.working
        until = standing.until
        failed = standing.failed
        unchecked = waitsForCheck
        canceled = standing.canceled
        endedAt = standing.said ?? created
        began = created
        // a Done job that waits only for the check of his ask's result stands in Waiting since its last word
        columnSince = column == .done ? endedAt : standing.openSince ?? endedAt
        replaced = standing.replaced
        // The ends are already in descending activity and id order.
        let last = standing.failed ?? standing.ends.first
        resultPlain = last?.plain
        resultDetails = last?.what
        var working = 0, waiting = 0, done = 0, failed = 0
        for task in standing.tasks where task.state != "canceled" {
            switch columns[task.id] ?? .waiting {
            case .inProgress: working += 1
            case .waiting: waiting += 1
            case .done:
                if !task.endedBadly { done += 1 } else if !standing.replaced.contains(task.id) { failed += 1 }
            }
        }
        counts = Counts(working: working, waiting: waiting, done: done, failed: failed)
        onlyLater = standing.column == .waiting && standing.wait == nil && !standing.open.isEmpty
            && standing.open.allSatisfy { $0.parkedOnly && !held.contains($0.id) && !limited.contains($0.owner) }
    }

    /// **One ended task as a job of its own**, for a column of tasks alone (`EndedTasks.init(_:calendar:)`).
    init(ended task: FleetTask) {
        key = .task(task.id)
        id = "task \(task.id)"
        title = task.title
        agent = task.owner
        asked = false
        tasks = [task]
        open = []
        column = .done
        wait = nil
        waitTask = nil
        working = nil
        until = nil
        failed = task.endedBadly ? task : nil
        unchecked = task.state == "completed" && task.accepted == nil ? task : nil
        canceled = task.state == "canceled"
        endedAt = max(task.activityTime, task.delivered ?? 0, task.checked_at ?? 0)
        began = task.created
        columnSince = endedAt
        replaced = []
        resultPlain = task.plain
        resultDetails = task.what
        counts = Counts(working: 0, waiting: 0, done: task.state == "canceled" || task.endedBadly ? 0 : 1,
                        failed: task.endedBadly ? 1 : 0)
        onlyLater = false
    }

    /// Words on one line, or nil for none.
    static func words(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.isEmpty ? nil : line
    }

    /// **The words of its counts line** ("1 working · 1 waiting · 3 done"), each part only for a count that is not 0,
    /// and the part of the tasks that did not succeed apart: the card writes it in red while the job is open or did not
    /// succeed, and not on a job that succeeded in the end. A task that ended badly and that later work took over is in
    /// no part. A job of one task has no such line: its card says where that task stands already. One of two tasks or
    /// more that its card lists has it, also when a task of it is in no part, because the line opens them.
    public var countWords: (plain: String, failed: String?)? {
        guard lines.count > 1 else { return nil }
        var parts: [String] = []
        if counts.working > 0 { parts.append(String(l10n: "\(counts.working) working")) }
        if counts.waiting > 0 { parts.append(String(l10n: "\(counts.waiting) waiting")) }
        // One and several are words of their own, because in Spanish they differ ("1 hecha", "3 hechas").
        if counts.done > 0 { parts.append(counts.done == 1 ? String(l10n: "1 done") : String(l10n: "\(counts.done) done")) }
        let failed = counts.failed == 0 ? nil
            : counts.failed == 1 ? String(l10n: "1 failed") : String(l10n: "\(counts.failed) failed")
        return (parts.joined(separator: " · "), failed)
    }
}

extension FleetTask {
    /// **Since when the task is in the state that its mark shows** (a task's row in the card of its job, `JobCard`; the
    /// owner, 19 November 2026: "show its name too and the time it's been in that state"): a result that its
    /// requester checked since the check, whose mark it wears ("Accepted by …", "Not accepted"); another task that
    /// ended since it ended; an open one since the hub's own time of its state (`since`, owner API 1.237: a hold, a
    /// usage limit, a stall or a lost session since it began, the start of what it waits on, its park, its creation
    /// while it is queued, else its return to work); from an older hub, its start, or its creation while it has none.
    public var stateSince: Double {
        if state == "completed", accepted != nil, let checked = checked_at { return checked }
        if isTerminal { return delivered ?? last_activity ?? created }
        return since ?? (state == "submitted" ? created : started ?? created)
    }
}

extension HubState {
    /// **The job that each task of the reading belongs to**, by the task's id. His own message first: a task with an
    /// `ask` is in that ask's job, as it is in `asks`. Else a case of a duty: the task's own, or the one that its
    /// links reach, as the case that stands for its duty and key (`DutyCaseLists.thing`). Else the task that begins
    /// the work: the last one that the links `job` and `follows` reach, `job` first, because the agent or the hub
    /// wrote it to say "one piece of work".
    ///
    /// **`parent` alone joins no job**: the hub files the wake-ups, the reviews and the chat work of a whole team under
    /// the lead's one task for its team's results, and those are not one piece of work. The hub writes `job` for a
    /// lead's own subtask (hub 1.226). A task of before that, under a case's task, still reaches its case: where the
    /// links end at a task that has a `parent`, `workKey` reads the case over it.
    ///
    /// Each task's links are read once: a task that the walk of another task passed has its answer already. A link to a
    /// task that the reading does not hold names that task's job all the same, so the tasks that name it stay one job.
    /// Links that go in a circle, which the hub cannot write, end at the smallest id of the tasks that the walk passed.
    func jobKeys(byID: [Int: FleetTask]) -> [Int: Job.Key] {
        // Where the links of a task end, whatever its own ask.
        var ends: [Int: Job.Key] = [:]
        for task in tasks where ends[task.id] == nil {
            var path: [Int] = [], seen: Set<Int> = []
            var current = task
            var end: Job.Key?
            while end == nil {
                if let known = ends[current.id] { end = known; break }
                path.append(current.id)
                seen.insert(current.id)
                if let id = current.duty_case { end = .dutyCase(responsibilities?.thing[id] ?? id); break }
                guard let link = [current.job, current.follows].compactMap({ $0 }).first(where: { $0 != current.id }) else {
                    // The links end here. A task of before the hub wrote `job`, under a case's task, is in that case.
                    if current.parent != nil, case .dutyCase(let id) = workKey(of: current, byID: byID) { end = .dutyCase(id) }
                    else { end = .task(current.id) }
                    break
                }
                if seen.contains(link) { end = .task(seen.min() ?? link); break }
                guard let next = byID[link] else { end = .task(link); break }
                current = next
            }
            for id in path { ends[id] = end }
        }
        var keys: [Int: Job.Key] = [:]
        for task in tasks {
            if let ask = task.ask, !ask.isEmpty { keys[task.id] = .ask(ask) } else { keys[task.id] = ends[task.id] }
        }
        return keys
    }

    /// **The jobs of the reading**, in no order: every task is in one, and a task that nothing joins to another is a
    /// job of its own.
    public var jobs: [Job] { jobs(of: nil) }

    /// The jobs, or for `agent` the board of one agent: a job of that agent whole, and of another agent's job the tasks
    /// that this agent does, under the job's name (`board`).
    /// For column times, include the named agents' parts beside the whole jobs in the same pass.
    func jobs(of agent: String?, includingPartsFor tracked: Set<String> = []) -> [Job] {
        let byID = Dictionary(tasks.map { ($0.id, $0) }) { first, _ in first }
        let keys = jobKeys(byID: byID)
        var members: [Job.Key: [FleetTask]] = [:], order: [Job.Key] = []
        for task in tasks {
            guard let key = keys[task.id] else { continue }
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(task)
        }
        guard !order.isEmpty else { return [] }
        let asked = Dictionary(messages.map { ($0.request_id, $0) }) { first, _ in first }
        let requests = Dictionary(needs.filter(\.isOpen).compactMap { need in need.ask.map { ($0, need) } }) { first, _ in first }
        let columns = taskColumns, waits = ownerWaits
        let held = Set((holds ?? []).filter { $0.state != "released" }.map(\.task))
        let limited = Set(agents.filter { $0.limit != nil }.map(\.name))
        var jobs: [Job] = []
        for key in order {
            let unsorted = members[key] ?? []
            let oldest = unsorted.min { $0.id < $1.id } ?? unsorted[0]
            var title = oldest.title, owner = oldest.owner, created = oldest.created, id: String
            var request: OwnerNeed?, whole = false
            switch key {
            case .ask(let message):
                id = "ask \(message)"
                whole = true
                request = requests[message]
                if let said = asked[message] {
                    title = said.asked ?? oldest.title
                    owner = said.chatRecipient
                    created = said.created
                }
            case .dutyCase(let caseID):
                id = "case \(caseID)"
                if let head = responsibilities?.byID[caseID] { title = head.title }
            case .task(let first):
                id = "task \(first)"
                // The task that begins it, also when this reading's tasks of it are only later ones.
                let begins = byID[first] ?? oldest
                title = Job.words(begins.job_name) ?? begins.title
            }
            let standing = JobStanding(unsorted, columns: columns, waits: waits, request: request)
            // A job that he asked for is the job of the agent that he asked, whoever does its tasks. Every other job is
            // the job of the agent that has it now.
            if !whole, let now = standing.waitTask ?? standing.working ?? standing.open.first
                ?? standing.failed ?? standing.tasks.first {
                owner = now.owner
            }
            if agent == nil || agent == owner {
                jobs.append(Job(key: key, id: id, title: title, agent: owner, asked: whole, standing: standing,
                                columns: columns, held: held, limited: limited, created: created))
            }
            // A part has its own id and standing, including work that the whole job has taken over.
            // For a single board only its agent's part is needed.
            if tracked.isEmpty && (agent == nil || agent == owner) { continue }
            let parts = Dictionary(grouping: unsorted.filter {
                $0.owner != owner && ($0.owner == agent || tracked.contains($0.owner))
            }, by: \.owner)
            for (name, tasks) in parts {
                let part = JobStanding(tasks, columns: columns, waits: waits, elsewhere: standing.replaced)
                jobs.append(Job(key: key, id: id + " of " + name, title: title, agent: name, asked: false, standing: part,
                                columns: columns, held: held, limited: limited, created: created))
            }
        }
        return jobs
    }

    /// **The Tasks board, with one card for each job** (his "Yes, build it" of 18 November 2026 to its picture). A task
    /// is on no card of its own: it is inside the card of its job, which stands in the column of the job. **In Working
    /// and Waiting a card keeps its place**: the job that began last first, and in Waiting what waits for him before the
    /// rest (the owner, 19 November 2026: "do not reorder the tasks in the same column, keep them in their position";
    /// the cards stood by the task that moved last, and the board's reading every three seconds moved them while he
    /// looked). Done is by when each job's last word was said, the newest first, as its days of "more" are
    /// (`EndedTasks`). **A job that he asked for and that is not done shows whatever the period**: it is work that he
    /// asked for. Any other job shows when one task of it is in the period, waits for him, or is open and parked by its
    /// agent (the review of 18 November 2026: a parked task gets no new activity, so with "Last 7 days" one that was
    /// parked for ten days left the board, and the row "later", before it started again).
    ///
    /// **`agent`: the board of one agent** (his "Yes, build it" of 17 November 2026 to the picture of Tasks with the
    /// Fleet Manager chosen, which View all of the card Asked opens): the jobs of that agent, whoever does their
    /// tasks, and its tasks of another agent's job, under that job's name. The Fleet Manager owns no task of its own,
    /// so its board showed nothing. nil: every agent's.
    public func board(period: ActivityPeriod, agent: String? = nil, calendar: Calendar = .current) -> [ActivityColumn: [Job]] {
        let start = period.start(now: Date(timeIntervalSince1970: time), calendar: calendar)?.timeIntervalSince1970 ?? -.infinity
        var columns: [ActivityColumn: [Job]] = [:]
        for job in jobs(of: agent) {
            let shows = (job.asked && !job.isOver) || job.wait != nil || job.tasks.contains {
                $0.activityTime >= start || ($0.parked_until != nil && !$0.isTerminal)
            }
            if shows { columns[job.column, default: []].append(job) }
        }
        var sorted: [ActivityColumn: [Job]] = [:]
        for (column, jobs) in columns {
            sorted[column] = column == .done ? jobs.sorted { ($0.activityTime, $0.order) > ($1.activityTime, $1.order) }
                : jobs.sorted { ($0.began, $0.firstTask) > ($1.began, $1.firstTask) }
        }
        if let lane = sorted[.waiting] {
            sorted[.waiting] = lane.filter { $0.wait != nil } + lane.filter { $0.wait == nil }
        }
        return sorted
    }
}

/// **How long each card has stood in its column, kept while it stays there** (a job card's "for 2 h"; the reviews of 20
/// November 2026): the hub's times of a task move when its session starts again or a wait of it ends inside one
/// attempt, while the card does not move. So this Mac notes every job at each reading of the hub, whatever page is
/// open, and a card keeps its time while its column stays the same: the guess from its tasks (`Job.columnSince`) when
/// a reading first has it, and after a change of column the later of that guess and the last reading that saw it in
/// its old column, so a gap in the readings (another hub, sleep) takes the hub's own facts. A job that a reading no
/// longer has is forgotten, and so is all of it at a quit.
public struct ColumnTimes: Sendable {
    private struct Kept: Sendable { let column: ActivityColumn; let since: Double; var seen: Double }
    private var kept: [String: Kept] = [:]

    public init() {}

    /// Every job of one reading of the hub `hub` (its database), at the hub's time `now`.
    public mutating func note(_ jobs: [Job], hub: String, now: Double) {
        var next: [String: Kept] = [:]
        for job in jobs {
            let key = hub + "/" + job.id
            if let old = kept[key], old.column == job.column {
                next[key] = Kept(column: old.column, since: old.since, seen: now)
            } else if let old = kept[key] {
                next[key] = Kept(column: job.column, since: max(job.columnSince, old.seen), seen: now)
            } else {
                next[key] = Kept(column: job.column, since: job.columnSince, seen: now)
            }
        }
        kept = next
    }

    /// Every card of one reading: the board of all agents, and each agent's own board with its parts of other agents'
    /// jobs (`HubState.jobs(of:)` names such a part apart), for each agent with an open task (the fourth review of 20
    /// November 2026: the parts were never noted, so an agent's own board lost their kept times).
    public mutating func note(_ state: HubState) {
        let active = Set(state.tasks.lazy.filter { !$0.isTerminal }.map(\.owner))
        note(state.jobs(of: nil, includingPartsFor: active), hub: state.db, now: state.time)
    }

    /// Since when this job of hub `hub` stands in its column: the kept time while its column is the one kept, else its
    /// own guess.
    public func since(_ job: Job, hub: String) -> Double {
        guard let old = kept[hub + "/" + job.id], old.column == job.column else { return job.columnSince }
        return old.since
    }
}
