import Foundation

/// **One case of a duty, as the fleet's state gives it** (UI-API.md, newest finished work): an open one of a duty's
/// `cases` or `joined`, or one of its `recent`, which closed in the last 72 hours. `facts` are the typed values of a
/// case that a session whose Shell box is off closed, in words (`"resolution": "Drafted"`), and nil for a note in an
/// agent's own words.
public struct CaseHead: Decodable, Sendable, Equatable {
    public let id: Int
    /// Its duty and its key: the cases of one duty with one key are one thing (`DutyCaseLists.thing`).
    public let responsibility: Int?
    public let key: String?
    public let title: String
    public let state: String
    /// The task that opened it: a session that opened several cases names none of them in its own `duty_case`.
    public let opened_in: Int?
    public let closed: Double?
    public let closed_by: String?
    public let outcome: String?
    public let note: String?
    public let facts: [String: String]?
    /// The event of its key came back after an earlier case of it had closed: a thing of its own, as a check's
    /// condition that fires again is another incident.
    public let repeated: Bool?

    public var isOpen: Bool { state == "open" }
}

/// **The cases of the fleet's duties in its state** (`GET /ui/state` `responsibilities`): each duty's open cases, the
/// open cases of other duties that it joined, and the cases that closed in its last 72 hours, with the agent whose work
/// each one is. A reading whose duties do not have this shape reads as none: the card Work then names the work that has
/// no case, and nothing else of the state is lost (one strict field once made every read of the state fail:
/// `FleetTask.goal`).
public struct DutyCaseLists: Decodable, Sendable {
    private struct Duty: Decodable {
        let agent: String?
        let cases: [CaseHead]?
        let joined: [CaseHead]?
        let recent: [CaseHead]?
    }

    /// Every case of the reading, by its id.
    public let byID: [Int: CaseHead]
    /// The agent whose work each case is, by the case's id: the holder of its duty while it is open, and the agent
    /// that closed it once it closed, so a duty that moved to another agent takes none of the old one's work along.
    public let holder: [Int: String]
    /// **The thing that each case is a part of**, by the case's id: the case of its duty and key that stands for all
    /// of them, an open one first, else the one that closed last. One ticket can be several cases: a session drafted
    /// the reply, a later one reported the defect, and the session that the fix started told the customer. To the
    /// owner that is one ticket (the owner, 17 November 2026: "resolved ticket xxxx and then inside, the specific tasks
    /// performed"), so the card has one row for it, and its page lists the tasks of every case of it.
    public let thing: [Int: Int]
    /// The cases of each thing, by the id of the case that stands for it.
    public let cases: [Int: [CaseHead]]
    /// The hub sends the cases that closed in its last 72 hours (UI-API.md, newest finished work): a case that the
    /// reading does not have then closed before them.
    public let knowsRecent: Bool

    public init(from decoder: Decoder) throws {
        let duties = (try? decoder.singleValueContainer().decode([Duty].self)) ?? []
        knowsRecent = duties.contains { $0.recent != nil }
        var byID: [Int: CaseHead] = [:], holder: [Int: String] = [:]
        for duty in duties {
            for c in duty.joined ?? [] { byID[c.id] = c }
            for c in (duty.cases ?? []) + (duty.recent ?? []) {
                byID[c.id] = c
                if let agent = c.isOpen ? duty.agent : c.closed_by ?? duty.agent { holder[c.id] = agent }
            }
        }
        // The cases of one duty and key, oldest first, are one thing until a case that the hub or its agent marked as
        // the event come back (`repeated`): that one begins the next thing.
        var keyed: [String: [CaseHead]] = [:]
        for c in byID.values {
            keyed[c.responsibility.flatMap { duty in c.key.map { "\(duty) \($0)" } } ?? "case \(c.id)", default: []]
                .append(c)
        }
        var groups: [[CaseHead]] = []
        for same in keyed.values {
            var current: [CaseHead] = []
            for c in same.sorted(by: { $0.id < $1.id }) {
                if c.repeated == true, !current.isEmpty {
                    groups.append(current)
                    current = []
                }
                current.append(c)
            }
            groups.append(current)
        }
        var thing: [Int: Int] = [:], cases: [Int: [CaseHead]] = [:]
        for members in groups {
            let first = members.max { a, b in
                (a.isOpen ? 1 : 0, a.closed ?? 0, a.id) < (b.isOpen ? 1 : 0, b.closed ?? 0, b.id)
            }!
            for c in members { thing[c.id] = first.id }
            cases[first.id] = members.sorted { $0.id < $1.id }
        }
        self.byID = byID
        self.holder = holder
        self.thing = thing
        self.cases = cases
    }
}

/// **One thing that an agent works on or finished, at the level he reads it** (the owner, 17 November 2026: "not the
/// specific tasks but at a higher level. For example: 'resolved ticket TCK-xxxxx' instead of the specific tasks
/// performed to resolve it", and his "Yes, as drawn" to its three pictures). It is a case of a duty, a ticket or an
/// incident, with every task that worked it; or, for work that came from no case, the agent's own first task of it with
/// the tasks that followed it. What he asked an agent for himself is that agent's card Asked (`Ask`).
public struct WorkItem: Identifiable, Sendable {
    public enum Key: Hashable, Sendable {
        /// A case of a duty, by the id of the case that stands for its duty and key.
        case dutyCase(Int)
        /// Work that came from no case, by its first task.
        case task(Int)
    }

    /// How its mark looks once it ended: a result that succeeded, one that did not, or neither (it waits for its check,
    /// or somebody canceled it).
    public enum End: Sendable, Equatable { case done, failed, quiet }

    /// One row of its page: a task, and how many steps in it stands under the task that gave it.
    public struct Line: Identifiable, Sendable {
        public let task: FleetTask
        public let depth: Int
        public var id: Int { task.id }
    }

    public let id: Key
    /// Its name: its case's title, else the title of its first task.
    public let title: String
    /// The tasks that are it, oldest first: the tasks of its cases with their subtasks and follow-ups, or the agent's
    /// own first task with the tasks that followed it. They say whether it is over and how it ended.
    public let tasks: [FleetTask]
    /// The tasks that its page lists, oldest first: its own, every subtask under them, also another agent's, and the
    /// task that opened a case of it.
    public let shown: [FleetTask]
    /// Its case, while the reading has it: the open case of its key, or the one that closed last.
    public let dutyCase: CaseHead?
    /// When it ended, or nil while something of it is open: the close of its case or the last move of its tasks,
    /// whichever came later.
    public let endedAt: Double?

    public var isOver: Bool { endedAt != nil }

    /// **How it ended, in a few words, and the look of its mark**; nil while it is open. A result that its check did
    /// not accept, that failed or that was rejected says so in red, as the card Asked does, also for a case; one that
    /// waits for its check is not done yet. Else a case says what its agent recorded when it closed it: the resolution
    /// that a session whose Shell box is off chose from the owner's lists ("Drafted", "Reassigned to Ana"; his pick
    /// of 17 November 2026, "What it did", over "Resolved" for each one), else its outcome; other work says "Done", as
    /// the card Asked says it.
    public var result: (words: String, end: End)? {
        guard endedAt != nil else { return nil }
        if let last = lastWord {
            if last.endedBadly, let words = last.failedResult { return (words, .failed) }
            if last.state == "completed" && last.accepted == nil {
                return (TaskWords.state(last.state, accepted: nil, requester: last.requester), .quiet)
            }
            if last.state == "canceled", dutyCase?.isOpen != false { return (last.failedResult ?? "", .quiet) }
        }
        if let c = dutyCase, !c.isOpen {
            return (c.facts?["resolution"] ?? Self.outcomeWords(c.outcome), c.outcome == "failed" ? .failed : .done)
        }
        return lastWord == nil ? nil : (String(l10n: "Done"), .done)
    }

    /// The words of a case's outcome.
    public static func outcomeWords(_ outcome: String?) -> String {
        switch outcome {
        case "handled": String(l10n: "Handled")
        case "no_action": String(l10n: "No action")
        case "failed": String(l10n: "Failed")
        default: String(l10n: "Closed")
        }
    }

    /// The task whose result says how it ended: of its tasks that are no subtask of another of them, the newest that
    /// nobody canceled, else the newest.
    var lastWord: FleetTask? {
        let ids = Set(tasks.map(\.id))
        let top = tasks.filter { task in task.parent.map { !ids.contains($0) } ?? true }
        return top.last { $0.state != "canceled" } ?? top.last
    }

    /// **Its tasks as its page lists them** (the owner: "and then inside, the specific tasks performed"): in the order
    /// they began, each subtask right under the task that gave it, one step further in. A task whose parent is not on
    /// the page stands at the first step.
    public var lines: [Line] {
        let ids = Set(shown.map(\.id))
        var children: [Int: [FleetTask]] = [:]
        for task in shown { if let parent = task.parent, ids.contains(parent) { children[parent, default: []].append(task) } }
        var out: [Line] = [], placed: Set<Int> = []
        func place(_ task: FleetTask, _ depth: Int) {
            guard placed.insert(task.id).inserted else { return }
            out.append(Line(task: task, depth: depth))
            for child in children[task.id] ?? [] { place(child, depth + 1) }
        }
        for task in shown where task.parent.map({ !ids.contains($0) }) ?? true { place(task, 0) }
        for task in shown where !placed.contains(task.id) { place(task, 0) }      // a loop of parents
        return out
    }
}

/// The tasks of a reading, read once for all the things of its work.
struct WorkReading {
    let byID: [Int: FleetTask]
    /// The subtasks of each task.
    let children: [Int: [FleetTask]]
    /// The thing of each task.
    let keys: [Int: WorkItem.Key]
    /// The tasks of each thing.
    let members: [WorkItem.Key: [FleetTask]]
}

extension HubState {
    /// **The thing that a task belongs to**: the case of the task, else of the task that it follows or that gave it,
    /// on up the chain, as the case that stands for its duty and key (`DutyCaseLists.thing`). Work of no case is the
    /// agent's own: the first task of its own in that chain, so a review or a wake-up that the hub filed under its
    /// lead's task for the team ("Your team's wake-up and case results") is its own thing, and not the lead's task. A
    /// chain that loops ends where it loops.
    func workKey(of task: FleetTask, byID: [Int: FleetTask]) -> WorkItem.Key {
        var current = task, own = task, seen: Set<Int> = [task.id]
        while true {
            if let id = current.duty_case { return .dutyCase(responsibilities?.thing[id] ?? id) }
            let next = [current.follows, current.parent, current.job].compactMap { $0.flatMap { byID[$0] } }.first
            guard let next, seen.insert(next.id).inserted else { return .task(own.id) }
            current = next
            if current.owner == task.owner { own = current }
        }
    }

    /// Every task of the reading by the thing that it belongs to.
    func workReading() -> WorkReading {
        let byID = Dictionary(tasks.map { ($0.id, $0) }) { first, _ in first }
        var keys: [Int: WorkItem.Key] = [:], members: [WorkItem.Key: [FleetTask]] = [:], children: [Int: [FleetTask]] = [:]
        for task in tasks {
            let key = workKey(of: task, byID: byID)
            keys[task.id] = key
            members[key, default: []].append(task)
            if let parent = task.parent { children[parent, default: []].append(task) }
        }
        return WorkReading(byID: byID, children: children, keys: keys, members: members)
    }

    /// One thing of the work from its tasks and its case.
    /// leaving: tasks that are no part of the thing here (the card Work leaves out the tasks of what the owner asked,
    /// which are the card Asked's): its end and its result are those of its other tasks.
    func workItem(_ key: WorkItem.Key, in reading: WorkReading, leaving: Set<Int> = []) -> WorkItem {
        let own = (reading.members[key] ?? []).filter { !leaving.contains($0.id) }.sorted { $0.id < $1.id }
        let lastMove = own.map { max($0.activityTime, $0.delivered ?? 0, $0.checked_at ?? 0) }.max()
        let allOver = own.allSatisfy(\.isTerminal)
        // The page: its own tasks, every subtask under them, and the task that opened a case of it.
        var shown: [Int: FleetTask] = [:], next = own
        while let task = next.popLast() {
            guard shown.updateValue(task, forKey: task.id) == nil else { continue }
            next += reading.children[task.id] ?? []
        }
        switch key {
        case .dutyCase(let id):
            let head = responsibilities?.byID[id]
            for c in responsibilities?.cases[id] ?? [] {
                if let opener = c.opened_in.flatMap({ reading.byID[$0] }) { shown[opener.id] = opener }
            }
            // A case closes while the task that closed it still delivers, and a fix that follows a result that its
            // check refused works in the case after its close: the thing is over when both are.
            let closed: Double? = if let head { head.isOpen ? nil : head.closed ?? 0 } else { own.isEmpty ? nil : 0 }
            let ended = closed.flatMap { at in allOver ? max(at, lastMove ?? 0) : nil }
            return WorkItem(id: key, title: head?.title ?? own.first?.title ?? "", tasks: own,
                            shown: shown.values.sorted { $0.id < $1.id }, dutyCase: head, endedAt: ended)
        case .task(let id):
            return WorkItem(id: key, title: reading.byID[id]?.title ?? own.first?.title ?? "", tasks: own,
                            shown: shown.values.sorted { $0.id < $1.id }, dutyCase: nil,
                            endedAt: !own.isEmpty && allOver ? lastMove : nil)
        }
    }

    /// **One thing of the work, by its key**, or nil when the reading has neither a task of it nor its case. A key
    /// stands for its thing as the thing is now: a case that a newer case of its thing has taken the place of (a ticket
    /// that is worked again), and a task that has opened a case since (a wake-up of the agent's own rule), lead to
    /// that thing, so a page that shows it follows it.
    public func workItem(_ key: WorkItem.Key) -> WorkItem? {
        let reading = workReading()
        var key = key
        if case .dutyCase(let id) = key, let first = responsibilities?.thing[id] { key = .dutyCase(first) }
        if case .task(let id) = key, reading.members[key] == nil, let now = reading.keys[id] { key = now }
        switch key {
        case .dutyCase(let id) where reading.members[key] == nil && responsibilities?.byID[id] == nil: return nil
        case .task where reading.members[key] == nil: return nil
        default: return workItem(key, in: reading)
        }
    }

    /// **The things that an agent works on or finished**: each one that a task of the agent belongs to, and each case
    /// that is its work (`DutyCaseLists.holder`), also one with no task (a duty of the Fleet Manager's closes its cases
    /// with no task). `asked`: the tasks of what he asked this agent for, the card Asked's, which no thing of it takes
    /// in.
    public func workItems(of agent: String, asked: Set<Int>) -> [WorkItem] {
        let reading = workReading()
        var mine: [WorkItem.Key] = [], seen: Set<WorkItem.Key> = []
        for task in tasks where task.owner == agent && !asked.contains(task.id) {
            if let key = reading.keys[task.id], seen.insert(key).inserted { mine.append(key) }
        }
        for (id, holder) in responsibilities?.holder ?? [:] where holder == agent {
            let key = WorkItem.Key.dutyCase(responsibilities?.thing[id] ?? id)
            if seen.insert(key).inserted { mine.append(key) }
        }
        // A task of what he asked that follows one of these (feedback on a task, owner API 1.279) is Asked's: the thing
        // here ends and reads as its own tasks did, and never again as the asked task ends (no task in both cards). The
        // card that a row opens (`detail(of:)`, `workItem(_:)`) is the whole thing, the asked task too, on purpose: the
        // row is Work's part of the thing, and the card is where he sees what came after it.
        return mine.map { workItem($0, in: reading, leaving: asked) }
    }
}
