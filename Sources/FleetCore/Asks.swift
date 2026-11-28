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
    /// **The later messages of his that go on with it** (owner feature `ask_follow_ups`, `HubState.askFirsts`), by their
    /// `request_id`, in the order he wrote them: their tasks are its tasks, and its row in a chat stands at the newest
    /// turn of any of them (`ChatAskPlaces`). Empty for an ask that nothing followed, and on a hub before the feature.
    public var followUps: [String] = []
    /// Its name in his lists: the message's `asked`, which the first task of the message wrote.
    public let title: String
    /// The agent that he asked: the message's recipient.
    public let agent: String
    /// **The other agents whose chats hold a message of it**: each agent that a follow-up of his went to, in the order
    /// he wrote them (the Mac validator, 26 November 2026: a follow-up sent to a second agent left that agent's chat
    /// and its card Asked). Its row stands in each of those chats too (`isIn(chatOf:)`).
    public var alsoIn: [String] = []
    /// Whether a chat of this agent holds a message of it: its row and its card Asked show it there.
    public func isIn(chatOf name: String) -> Bool { agent == name || alsoIn.contains(name) }
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

extension HubState {
    /// **The first message of the ask that each message goes on with** (owner feature `ask_follow_ups`; the owner, 25
    /// November 2026: "Sometimes I will be asking about related tasks repeatedly, so the system should catch that",
    /// and "Yes, this" to its pictures): by request id, for each message whose `ask` names another, built once for a
    /// pass over the reading (the board's jobs, the asks) and never once for each task. It follows `ask` at most
    /// `askHops` times, as the hub does; an `ask` that names no message of this reading is no ask (a restored older
    /// copy, a sweep), and a loop ends where it began. A message that goes on with nothing is not in it. **His list
    /// (`owner_asks`) comes first**: the hub names each message of an ask with its first one, also a first message that
    /// is older than this reading (the Mac validator, 26 November 2026: a follow-up to an ask older than the reading's
    /// messages was a second card on the board and one row on his list).
    public var askFirsts: [String: String] { keptAskFirsts ?? Self.askFirsts(of: messages, asks: owner_asks) }

    /// The map of `askFirsts` for these messages and his list.
    static func askFirsts(of messages: [OwnerMessage], asks list: [OwnerAsk]?) -> [String: String] {
        var firsts: [String: String] = [:]
        for ask in list ?? [] { for message in ask.messages.dropFirst() where firsts[message] == nil { firsts[message] = ask.id } }
        let next = Dictionary(messages.compactMap { m in m.ask.map { (m.request_id, $0) } }) { first, _ in first }
        guard !next.isEmpty else { return firsts }
        let known = Set(messages.lazy.filter { $0.kind == "message" }.map(\.request_id)).union((list ?? []).map(\.id))
        let listed = firsts
        for start in next.keys where listed[start] == nil {
            var at = start, seen: Set<String> = [start]
            for _ in 0..<Self.askHops {
                guard let later = next[at], !seen.contains(later) else { break }
                if let first = listed[later] { at = first; break }      // a message of an ask on his list: its first
                guard known.contains(later) else { break }
                seen.insert(later)
                at = later
            }
            if at != start { firsts[start] = at }
        }
        return firsts
    }

    /// The links of `ask` that `askFirsts` follows: a join writes the first message, so one is usual (hub.ASK_HOPS).
    static let askHops = 4

    /// **The things that he asked for**, the newest first. A task with an `ask` whose message this reading does not
    /// hold still makes one, under its oldest task's title and agent, so that no work of his is left out. **A follow-up
    /// is no ask of its own** (owner feature `ask_follow_ups`): its tasks name its own message, which goes on with an
    /// earlier ask (`askFirsts`), so they are that ask's tasks, under the first message's name and agent, and so is an
    /// open request that names the follow-up.
    public var asks: [Ask] {
        let firsts = askFirsts
        var members: [String: [FleetTask]] = [:]
        for task in tasks {
            if let ask = task.ask, !ask.isEmpty { members[firsts[ask] ?? ask, default: []].append(task) }
        }
        guard !members.isEmpty else { return [] }
        let asked = Dictionary(messages.map { ($0.request_id, $0) }) { first, _ in first }
        // his list's rows, for an ask whose first message is older than this reading's messages: its name, agent and
        // time, as the board's job has them (`jobs(of:)`), not those of its oldest task that the reading holds
        let listed = Dictionary((owner_asks ?? []).map { ($0.id, $0) }) { first, _ in first }
        var followUps: [String: [OwnerMessage]] = [:]
        for message in messages where message.kind == "message" {
            if let first = firsts[message.request_id] { followUps[first, default: []].append(message) }
        }
        let columns = taskColumns, waits = ownerWaits
        let requests = Dictionary(needs.filter(\.isOpen).compactMap { need in need.ask.map { (firsts[$0] ?? $0, need) } }) { first, _ in first }
        return members.map { id, unsorted in
            // Where it stands, with the rules that a job's card has too (`JobStanding`).
            let standing = JobStanding(unsorted, columns: columns, waits: waits, request: requests[id])
            let oldest = unsorted.min { $0.id < $1.id } ?? unsorted[0]
            let message = asked[id], row = message == nil ? listed[id] : nil
            var ask = Ask(id: id, title: message?.asked ?? row?.name ?? oldest.title,
                          agent: message?.chatRecipient ?? row?.agent ?? oldest.owner,
                          created: message?.created ?? row?.created ?? oldest.created, tasks: standing.tasks, open: standing.open,
                          column: standing.column, wait: standing.wait, waitTask: standing.waitTask,
                          working: standing.working, until: standing.until, failed: standing.failed,
                          unchecked: standing.unchecked, canceled: standing.canceled,
                          endedAt: standing.said ?? message?.created ?? row?.created ?? oldest.created)
            let later = (followUps[id] ?? []).sorted { ($0.created, $0.event_id) < ($1.created, $1.event_id) }
            ask.followUps = later.map(\.request_id)
            var seen: Set<String> = [ask.agent]
            ask.alsoIn = later.map(\.chatRecipient).filter { seen.insert($0).inserted }
            return ask
        }.sorted { ($0.created, $0.id) > ($1.created, $1.id) }
    }
}


/// **The card Asked of an agent's chat panel, as it shows** (his "Both places" of 15 November 2026 to its picture):
/// the things that he asked that agent for, the newest first, one row each **while the row has news** — it waits for
/// him, an agent works on it now, or it ended and he has not seen that yet — then **every other open one, which only
/// waits, as a row of its own too** (`waits`; the owner, 17 November 2026, of the row "2 waiting", which opened the
/// whole Tasks board: "if it's only 3 elements you could have shown them there directly!"), **while they are three or
/// fewer**; more are one row with their number, which opens them in place (`ownRows`). An ask that ended and that he
/// has seen is on the Tasks page, as a card of Done with its result.
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
        /// does ("Resumes at 15:00") in place of its line; nil when a hold or a usage limit stops it, or no time does.
        public let until: Double?

        /// **The row's one muted line**: that it waits for him; the agent that works on it now, by its name, and what
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
    /// muted, in the Tasks board's words ("Resumes at 15:00", "Waiting for Shop Developer", "Queued"), and its click opens
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
        for ask in asks where ask.isIn(chatOf: agent) {
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

/// **One row of his list "Asked by me"** (owner feature `ask_follow_ups`; the owner, 25 November 2026: "If i asked for
/// something this morning, there should be a way to easily see 4 hours later ... what is the response/status of the one
/// thing I asked", then "Yes, this" to round 2 of its pictures): one ask of his list (`OwnerAsk`), whatever the number
/// of his messages in it, with where it stands by the board's own rules (`JobStanding`), what waits for him in orange,
/// its newest answer and the agent that has it now.
public struct AskedRow: Identifiable, Sendable {
    /// Its state mark, in the board's marks: the orange hand, the turning mark of work, the clock of what waits, the
    /// green check, the red mark of a result that did not succeed, and the muted circle of one that somebody canceled.
    public enum Mark: Sendable, Equatable { case needsYou, working, waiting, done, failed, canceled }

    /// The request id of its first message.
    public let id: String
    public let name: String
    /// The agent that he asked.
    public let agent: String
    public let mark: Mark
    /// For a row in work: its task in work is work now (`FleetTask.mark`), so its mark turns.
    public let moves: Bool
    /// **What waits for him**, or nil: a task of it that waits for him, else his open request that names a message of it.
    /// A request's line opens that request on Needs you.
    public let wait: OwnerWait?
    /// **Its newest answer**: the newer of the hub's (`OwnerAsk.answer`, an agent's words to a message of it) and the
    /// plain result of its task that ended last (`FleetTask.plain`), on one line; nil for none yet.
    public let answer: String?
    /// When that answer came, or nil.
    public let answered: Double?
    /// **The agent that has it now**: the one whose task waits for him, else the one whose task is in work, else the one
    /// whose open task moved last; for one that is over, the agent that he asked.
    public let holder: String
    /// For a row that only waits: the earliest time until which an open task of it is parked, or nil.
    public let until: Double?
    /// The red word of a result that did not succeed, for a row that failed.
    public let failedWord: String?
    /// When he asked: an open row keeps its place by it.
    public let created: Double
    /// The time at its right: for an open row its newest move, and for one that is over when it ended.
    public let time: Double
    /// For a row that is over: when it ended; nil while it is open.
    public let ended: Double?
    /// Its tasks in this reading, the one that moved last first.
    public let tasks: [FleetTask]
    /// The request ids of his messages in it, its first one first.
    public let messages: [String]
    /// The row's newest move, by the hub's word (`OwnerAsk.moved`): its card reads again when it changes.
    public let moved: Double

    public var isOpen: Bool { [Mark.needsYou, .working, .waiting].contains(mark) }
    /// The request that a click on its orange line opens, or nil.
    public var request: Int? { if case .request(let id, _) = wait { id } else { nil } }
    /// **Its orange words**: "Needs you: " and the request's title, or the words of an outcome, a stop or a sign-in, as
    /// a job's card on the board says them (`JobCard`); nil when nothing waits for him.
    public var waitWords: String? {
        guard let wait else { return nil }
        if case .request(_, let title) = wait { return String(l10n: "Needs you: \(title)") }
        return wait.words
    }
    /// The task that the pointer on its row reads first, as a card of the board does: the one that waits for him, in
    /// work, or open, else the one that moved last; nil for a question with no task.
    public var lead: FleetTask? { tasks.first { !$0.isTerminal } ?? tasks.first }
}

/// **His list "Asked by me", as the Tasks page shows it** (round 2 of `my-asks-tracking-2026-11-25`): Open, what needs
/// him first and then by when he asked, the newest first, so a row keeps its place while its work moves (the owner, 19
/// November 2026: "keep them in their position"); Done, what ended in the last `doneDays` days, the newest end first;
/// and the rest of the hub's list, which "N earlier" opens, by day.
/// **Which results of an ask's tasks stand as an answer to it** (UI-API.md 1.363; the validators' reads of 26 November
/// 2026), one rule for his list, the open card and the hub's `answer`: a task that ended with plain words that its
/// requester accepted (a refused result keeps its words and its state: a "Fixed" that its check took back is worse than
/// none), that is no part of another task of the ask (its result is that task's to check, and says what came of it),
/// and that no later task of the ask follows, which nobody canceled (that work put its result right).
enum AskResult {
    struct Facts {
        let id: Int
        let parent: Int?
        let follows: Int?
        let state: String
        let accepted: Int?
        let words: String?
    }

    static func stands(_ tasks: [Facts]) -> Set<Int> {
        let ids = Set(tasks.map(\.id))
        let followed = Set(tasks.filter { $0.state != "canceled" }.compactMap(\.follows))
        let ended: Set<String> = ["completed", "failed", "rejected", "canceled"]
        return Set(tasks.filter {
            ended.contains($0.state) && $0.accepted == 1 && $0.words != nil && !($0.parent.map(ids.contains) ?? false)
                && !followed.contains($0.id)
        }.map(\.id))
    }
}

public struct AskedByMe: Sendable {
    public let open: [AskedRow]
    public let done: [AskedRow]
    public let earlier: [AskedRow]
    /// How long a row that ended stays in Done.
    public static let doneDays: Double = 7

    public var isEmpty: Bool { open.isEmpty && done.isEmpty && earlier.isEmpty }
    public var rows: [AskedRow] { open + done + earlier }

    /// `state`: the reading, whose `owner_asks` is his list; nil on a hub that sends none.
    public init?(_ state: HubState) {
        guard let list = state.owner_asks else { return nil }
        let firsts = state.askFirsts
        // Each of his messages, by its request id, to the row that holds it; a follow-up that the hub's list does not
        // name yet goes with the first message that it names, also when that message is older than this reading's
        // messages, as on the board.
        var rowOf: [String: String] = [:]
        for ask in list { for message in ask.messages where rowOf[message] == nil { rowOf[message] = ask.id } }
        let named = Dictionary(state.messages.compactMap { m in m.ask.map { (m.request_id, $0) } }) { first, _ in first }
        func row(of message: String) -> String? {
            rowOf[message] ?? firsts[message].flatMap { rowOf[$0] } ?? named[message].flatMap { rowOf[$0] }
        }
        var members: [String: [FleetTask]] = [:]
        for task in state.tasks {
            if let ask = task.ask, !ask.isEmpty, let id = row(of: ask) { members[id, default: []].append(task) }
        }
        var requests: [String: OwnerNeed] = [:]
        for need in state.needs.filter(\.isOpen).sorted(by: { $0.id < $1.id }) {
            if let ask = need.ask, let id = row(of: ask), requests[id] == nil { requests[id] = need }
        }
        // When he wrote each message of his, for a question that waits for its answer.
        var said: [String: Double] = [:]
        for message in state.messages where message.kind == "message" { said[message.request_id] = message.created }
        let columns = state.taskColumns, waits = state.ownerWaits
        let rows = list.map { ask in
            Self.row(ask, tasks: members[ask.id] ?? [], request: requests[ask.id], said: said, columns: columns,
                     waits: waits, state: state)
        }
        let since = state.time - Self.doneDays * 86_400
        open = rows.filter(\.isOpen).sorted {
            ($0.mark == .needsYou ? 1 : 0, $0.created, $0.id) > ($1.mark == .needsYou ? 1 : 0, $1.created, $1.id)
        }
        let over = rows.filter { !$0.isOpen }.sorted { ($0.time, $0.id) > ($1.time, $1.id) }
        done = over.filter { $0.time >= since }
        earlier = over.filter { $0.time < since }
    }

    private static func row(_ ask: OwnerAsk, tasks unsorted: [FleetTask], request: OwnerNeed?, said: [String: Double],
                            columns: [Int: ActivityColumn], waits: [Int: OwnerWait], state: HubState) -> AskedRow {
        // its tasks, the one that moved last first (`AskedRow.tasks`): the row's time and the pointer read that one
        let tasks = unsorted.sorted { ($0.activityTime, $0.id) > ($1.activityTime, $1.id) }
        // His newest message of it that this reading holds, or the first one.
        let lastSaid = ask.messages.compactMap { said[$0] }.max() ?? ask.created
        // Its newest answer: the hub's words to a message of it, or the plain result of its task that ended last, of
        // those that stand as an answer by the rule of the hub's `answer` and of the card (`AskResult`).
        let stands = AskResult.stands(tasks.map { AskResult.Facts(id: $0.id, parent: $0.parent, follows: $0.follows,
                                                                    state: $0.state, accepted: $0.accepted,
                                                                    words: Job.words($0.plain)) })
        let result = tasks.filter { stands.contains($0.id) }
            .max { ($0.delivered ?? $0.activityTime, $0.id) < ($1.delivered ?? $1.activityTime, $1.id) }
        var answer = ask.answer.flatMap { Job.words($0.text) }, answered = ask.answer?.at
        if let result, let words = Job.words(result.plain), (result.delivered ?? result.activityTime) > (answered ?? -.infinity) {
            answer = words
            answered = result.delivered ?? result.activityTime
        }
        // **A message of his that nothing answered yet and that no task took keeps it open**: a question, or a
        // follow-up question on work that ended. A task made since it, or an answer since it, is its answer.
        let waitsForReply = lastSaid > (answered ?? -.infinity) && !tasks.contains { $0.created >= lastSaid }
        var mark: AskedRow.Mark, moves = false, failedWord: String?
        var wait: OwnerWait?, until: Double?, holder = ask.agent, ended: Double?
        if tasks.isEmpty {
            wait = request.map { .request(id: $0.id, title: $0.title) }
            if let request { holder = request.by }
            mark = wait != nil ? .needsYou : answered != nil && !waitsForReply && !ask.open ? .done : .waiting
            if mark == .done { ended = answered }
        } else {
            let standing = JobStanding(tasks, columns: columns, waits: waits, request: request)
            wait = standing.wait
            until = standing.until
            switch standing.column {
            case .waiting: mark = wait != nil ? .needsYou : .waiting
            case .inProgress:
                mark = .working
                moves = standing.working?.mark(in: state).inWork == true
            case .done:
                if let failed = standing.failed { mark = .failed; failedWord = failed.failedResult }
                else if standing.canceled { mark = .canceled }
                // what he asked for is not done until its result is checked, as on the board (`Job.column`)
                else if standing.unchecked { mark = .waiting }
                else { mark = .done }
                if mark != .waiting, waitsForReply { mark = .waiting; failedWord = nil }
                if mark != .waiting { ended = max(standing.said ?? ask.created, answered ?? -.infinity) }
            }
            if let now = standing.waitTask ?? standing.working ?? standing.open.first {
                holder = now.owner
            } else if case .request = wait, let request {
                holder = request.by
            }
        }
        let newest = max(ask.moved, answered ?? -.infinity, tasks.first?.activityTime ?? -.infinity)
        return AskedRow(id: ask.id, name: ask.name, agent: ask.agent, mark: mark, moves: moves, wait: wait, answer: answer,
                        answered: answered, holder: [AskedRow.Mark.needsYou, .working, .waiting].contains(mark) ? holder : ask.agent,
                        until: mark == .waiting ? until : nil, failedWord: failedWord, created: ask.created,
                        time: ended ?? newest, ended: ended, tasks: tasks, messages: ask.messages, moved: ask.moved)
    }
}

extension HubState {
    /// **His list "Asked by me"** (`AskedByMe`), or nil on a hub that does not keep it: then the Tasks page shows no switch.
    public var askedByMe: AskedByMe? {
        guard ui_features?.contains(AskedByMe.feature) == true else { return nil }
        return AskedByMe(self)
    }
}

extension AskedByMe {
    /// The hub keeps his list and joins his follow-ups (UI-API.md 1.360).
    public static let feature = "ask_follow_ups"
}

/// **What he has seen of each ask of his list, on this Mac** (`AskedRow`'s name is semibold until he opens its card
/// after its newest answer): for each fleet (its database), the time of the newest answer that he saw on each ask's
/// card, and the time from which this Mac draws the list, so that a Mac that reads a fleet for the first time does not
/// show its whole past as new, as the card Asked of a chat's panel keeps it (`askedSeen`). It keeps only the asks that
/// the list still has. It is JSON in one kept value (`key`), which a view reads and writes as `words`.
public struct AskSeen: Equatable, Sendable {
    /// The kept value's name in the app's defaults (`AppDefaults.store`).
    public static let key = "askedByMeSeen"

    private struct Fleet: Codable, Equatable, Sendable {
        var since: Double?
        var asks: [String: Double] = [:]
    }
    private var fleets: [String: Fleet]

    /// The kept words, or nothing: no value, or words of another shape, is nothing seen.
    public init(words: String) {
        fleets = (try? JSONDecoder().decode([String: Fleet].self, from: Data(words.utf8))) ?? [:]
    }

    /// The words to keep.
    public var words: String {
        (try? JSONEncoder().encode(fleets)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// From when this Mac draws the list of the fleet `db`, or nil before it drew it.
    public func since(db: String) -> Double? { fleets[db]?.since }

    /// **This Mac draws the list of the fleet `db` for the first time at the hub's time `time`**: an answer from before
    /// it is no news. A second call keeps the first time.
    public mutating func begin(db: String, at time: Double) {
        if fleets[db]?.since == nil { fleets[db, default: Fleet()].since = time }
    }

    /// **He opened the card of the ask `id`, whose newest answer came at `answered`**: that answer is seen. Only the asks
    /// in `keep` (his list now) stay kept, so the value does not grow with his asks.
    public mutating func note(_ id: String, answered: Double, db: String, keep: Set<String>) {
        var fleet = fleets[db] ?? Fleet()
        fleet.asks = fleet.asks.filter { keep.contains($0.key) }
        fleet.asks[id] = max(fleet.asks[id] ?? -.infinity, answered)
        fleets[db] = fleet
    }

    /// **The row has an answer that he has not seen**: newer than what he saw on its card, and than the time from which
    /// this Mac draws the list. Before this Mac drew the list of the fleet, nothing is new.
    public func unread(_ row: AskedRow, db: String) -> Bool {
        guard let answered = row.answered, let fleet = fleets[db], let since = fleet.since else { return false }
        return answered > max(since, fleet.asks[row.id] ?? -.infinity)
    }
}
