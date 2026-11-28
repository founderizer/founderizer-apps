import Foundation

/// **The card of one ask of his** (`GET /ui/mobile/asks/<id>`, owner feature `ask_follow_ups`, UI-API.md 1.360; the owner's
/// "Yes, this" of 25 November 2026 to round 2 of `my-asks-tracking-2026-11-25`): his messages of it, the agents'
/// answers to them and the heads of its tasks, each in time order, as the hub reads them. The Mac's window of messages
/// holds about three days, so the card is read from the hub when it opens, and again when its row moves.
public struct AskCard: Decodable, Sendable, Equatable {
    /// One message of his in it.
    public struct Message: Decodable, Sendable, Equatable, Identifiable {
        public let request_id: String
        public let event_id: Int
        public let text: String
        public let created: Double
        public let client: String?
        /// He wrote it in a chat app.
        public let origin: Bool?
        public let recipient: String?
        /// Who wrote it (owner feature `message_hands`): "app", "device" and "chat" are his own hand; "tool" (an AI
        /// session of his), "connected" and "other" are not; nil for a row of before the hub kept it.
        public let hand: String?
        /// The message that it corrects, for a correction (as the chat gives it).
        public let replaces_request_id: String?
        public var id: String { request_id }
        /// The agent that he wrote it to.
        public var to: String { recipient ?? "manager" }
        /// **His own hand wrote it** (the hub's `ask_by_his_hand`): the card shows his own words only (design question
        /// 3, the Mac validator of 26 November 2026), and words that an AI session or a program sent for him would read
        /// as his typed words. A row with no hand goes by a chat app's origin or the label of an app of his.
        public var isHis: Bool {
            if let hand { return ["app", "device", "chat"].contains(hand) }
            return origin == true || ["founderizer-swift/", "founderizer-windows/", "founderizer-ios/"].contains {
                (client ?? "").hasPrefix($0)
            }
        }
    }

    /// One answer of an agent's to a message of it: linked to it (`in_reply_to`), or the words that took its turn.
    public struct Report: Decodable, Sendable, Equatable, Identifiable {
        public let id: Int
        public let text: String
        public let created: Double
        public let agent: String?
        public let in_reply_to: String?
        public let turn: String?
        /// The agent that wrote it.
        public var speaker: String { agent ?? "manager" }
        /// The message of his that it answers.
        public var answers: String? { in_reply_to ?? turn }
    }

    /// The head of one task of it, as the phone reads a task (`GET /ui/mobile`'s heads).
    public struct TaskHead: Decodable, Sendable, Equatable, Identifiable {
        public let id: Int
        public let title: String
        public let state: String
        public let owner: String
        public let created: Double
        public let started: Double?
        public let last_activity: Double?
        public let delivered: Double?
        public let checked_at: Double?
        public let accepted: Int?
        /// The message of his that its work began from.
        public let ask: String?
        public let parent: Int?
        /// The task that it follows: later work that put that task's result right.
        public let follows: Int?
        public let waiting_on: String?
        /// What it came to, in plain words (`tasks.plain`); nil from a hub before owner API 1.363.
        public let plain: String?
        /// Its plain words on one line, or nil for none.
        public var plainWords: String? { Job.words(plain) }

        public var isTerminal: Bool { ["completed", "failed", "rejected", "canceled"].contains(state) }
        /// When it came into the state that its row shows: when it ended, else when it last moved.
        public var time: Double { isTerminal ? delivered ?? checked_at ?? last_activity ?? created : last_activity ?? started ?? created }
    }

    public let db: String
    /// The request id of its first message.
    public let id: String
    /// The agent that he asked first: its chat field writes to it.
    public let agent: String?
    public let name: String?
    public let messages: [Message]
    public let reports: [Report]
    public let tasks: [TaskHead]

    /// The agent of the card's chat field.
    public var asked: String { agent ?? "manager" }

    /// A card of the generation `database`, of the ask that one of its messages, `id`, is a message of.
    func validate(database: String, id asked: String) throws {
        guard db == database, !id.isEmpty,
              id.caseInsensitiveCompare(asked) == .orderedSame
                || messages.contains(where: { $0.request_id.caseInsensitiveCompare(asked) == .orderedSame })
        else { throw HubError.invalidResponse }
    }

    /// **The agents in it**, as its head names them: the agent that he asked first, then each agent that answered or did
    /// a task of it, in the order in which they came in.
    public var agents: [String] {
        var named = [asked]
        let came = reports.map { ($0.created, $0.speaker) } + tasks.map { ($0.created, $0.owner) }
        for (_, agent) in came.sorted(by: { $0.0 < $1.0 }) where !named.contains(agent) { named.append(agent) }
        return named
    }

    /// One line of the card, in order.
    public enum Line: Sendable, Equatable, Identifiable {
        /// The day of the lines under it, by its first time.
        case day(Double)
        /// His message, as a bubble at the right.
        case mine(Message)
        /// An agent's answer, at the left.
        case reply(Report)
        /// **The work that one message of his began**: its tasks, by the message's id, in the order they began.
        case work(String, [TaskHead])
        /// **What a task of it came to**, in its agent's plain words, at the left as an answer (the picture r3).
        case result(TaskHead)

        public var id: String {
            switch self {
            case .day(let start): "day \(start)"
            case .mine(let message): "message \(message.request_id)"
            case .reply(let report): "report \(report.id)"
            case .work(let message, _): "work \(message)"
            case .result(let task): "result \(task.id)"
            }
        }
    }

    /// The tasks whose plain result stands on the card as their agent's words: each task that ended with one that its
    /// requester accepted (a refused result keeps its words: a "Fixed" that its check took back is worse than none, as
    /// `AskedCard` says), that is no part of another task of the card (a subtask's result is its task's), and that no
    /// later task of the card follows, which nobody canceled (that work put its result right). The hub's `answer` and
    /// his list read by the same rule (UI-API.md 1.363, `AskResult`).
    private var results: [TaskHead] {
        let stands = AskResult.stands(tasks.map { AskResult.Facts(id: $0.id, parent: $0.parent, follows: $0.follows,
                                                                    state: $0.state, accepted: $0.accepted,
                                                                    words: $0.plainWords) })
        return tasks.filter { stands.contains($0.id) }
    }

    /// **Its lines in order** (the owner's picture r3): by day, his messages and the answers in time order, his message
    /// first where both came in the same second; **the work that a message began stands under the first answer to that
    /// message**, else under the message itself; work whose message the card does not hold stands at its end. A task's
    /// plain result (`results`) stands in time order with the answers. A day's line stands over the first line of each
    /// day of `calendar`. **A message that his own hand did not write has no line** (`Message.isHis`): its answers and
    /// its work stand as they would, its work under its first answer, else at the card's end.
    public func lines(calendar: Calendar = .current) -> [Line] {
        func key(_ id: String) -> String { id.lowercased() }
        let held = Set(messages.map { key($0.request_id) })
        var work: [String: [TaskHead]] = [:], loose: [TaskHead] = []
        for task in tasks.sorted(by: { $0.id < $1.id }) {
            if let ask = task.ask, held.contains(key(ask)) { work[key(ask), default: []].append(task) } else { loose.append(task) }
        }
        let answered = Set(reports.compactMap(\.answers).map(key))
        enum Entry { case mine(Message), reply(Report), result(TaskHead) }
        let entries: [(time: Double, order: Int, entry: Entry)] =
            messages.filter(\.isHis).map { (time: $0.created, order: $0.event_id, entry: Entry.mine($0)) }
            + reports.map { (time: $0.created, order: Int.max / 2 + $0.id, entry: Entry.reply($0)) }
            + results.map { (time: $0.time, order: Int.max / 4 * 3 + $0.id, entry: Entry.result($0)) }
        var lines: [Line] = [], day: Date?, placed: Set<String> = []
        func place(_ message: String) {
            guard !placed.contains(message), let tasks = work[message] else { return }
            placed.insert(message)
            lines.append(.work(message, tasks))
        }
        for item in entries.sorted(by: { ($0.time, $0.order) < ($1.time, $1.order) }) {
            let start = calendar.startOfDay(for: Date(timeIntervalSince1970: item.time))
            if day != start { lines.append(.day(item.time)); day = start }
            switch item.entry {
            case .mine(let message):
                lines.append(.mine(message))
                if !answered.contains(key(message.request_id)) { place(key(message.request_id)) }
            case .reply(let report):
                lines.append(.reply(report))
                if let message = report.answers { place(key(message)) }
            case .result(let task):
                lines.append(.result(task))
            }
        }
        // a message whose answers the card holds none of that came after it: its work at its end
        for message in messages { place(key(message.request_id)) }
        if !loose.isEmpty { lines.append(.work("", loose)) }
        return lines
    }
}
