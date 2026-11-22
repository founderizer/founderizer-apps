import Foundation

/// **A task or a job that a message of the owner's names** (owner feature `message_about`, API 1.279): `{"task": id}`,
/// or `{"job": id}` with one task of the job, as `create_task`'s `job` names a job.
public enum MessagePlace: Hashable, Sendable, Codable {
    case task(Int)
    case job(Int)

    /// The field of `POST /ui/messages`.
    public var fields: [String: Int] {
        switch self {
        case .task(let id): ["task": id]
        case .job(let id): ["job": id]
        }
    }
}

/// **What a message of his is about, as the hub gives it** (`messages[].about`): the task or the job, and its title as
/// the Tasks board names it, null for a task that the hub has no more. Never strict: an object of another shape, or a
/// value that is no object, reads as a place of nothing, and the message and the rest of the reading stay.
public struct MessageAbout: Decodable, Sendable, Equatable {
    public let place: MessagePlace?
    public let title: String?

    public init(place: MessagePlace?, title: String?) {
        self.place = place
        self.title = title
    }

    private enum Keys: String, CodingKey { case task, job, title }

    public init(from decoder: Decoder) throws {
        let fields = try? decoder.container(keyedBy: Keys.self)
        let task = (try? fields?.decodeIfPresent(Int.self, forKey: .task)) ?? nil
        let job = (try? fields?.decodeIfPresent(Int.self, forKey: .job)) ?? nil
        place = switch (task, job) {
        case (let task?, nil): .task(task)
        case (nil, let job?): .job(job)
        default: nil
        }
        title = (try? fields?.decodeIfPresent(String.self, forKey: .title)) ?? nil
    }
}

/// **His feedback on a card: who gets it, and what it names** (design "Task details as a card over the page", part 2;
/// the owner, 21 November 2026: "Be able to give feedback on a task, probably reference it somehow (see the tagging
/// thread) from that same detail page!", and "Yes, build it" to its drawing). The hub takes a message about a task only
/// from a chat that can read that task: the task's own agent or its requester, and never for a task of a narrowed pair
/// (`about_unreadable`, 409). So the card names a recipient whose chat the hub lets read it, and with none it has no
/// feedback box.
public struct Feedback: Equatable, Sendable {
    /// The agent whose chat gets the message.
    public let recipient: String
    public let about: MessagePlace
}

extension HubState {
    /// **An agent whose chat takes a message from him**: the hub lists it, and its chat takes messages
    /// (`supportsChat(with:)`, the app's one rule for a chat's Send). The owner is no agent.
    public func hasChat(_ agent: String) -> Bool {
        agents.contains { $0.name == agent } && supportsChat(with: agent)
    }

    /// **The feedback on a task's card**: to the task's agent when its chat takes messages, else to the task's requester
    /// when that is an agent whose chat does; nil with neither, for a task of a narrowed pair (`scope_person`), and for
    /// a task that the reading lists no more.
    public func feedback(onTask id: Int) -> Feedback? {
        guard let task = tasks.first(where: { $0.id == id }), task.scope_person == nil else { return nil }
        guard let recipient = [task.owner, task.requester].first(where: hasChat) else { return nil }
        return Feedback(recipient: recipient, about: .task(id))
    }

    /// **The feedback on a job's card**: to the job's agent when its chat takes messages, naming the job by a task of
    /// it that this agent does, else by one that it asked for, the oldest first, never a task of a narrowed pair; nil
    /// when the agent has no chat or no such task. **Only a task that is the job's own** (`JobLevel.taskIDs`): the card
    /// of a case also lists the session that opened it, and a session that opened several cases is the work of none of
    /// them, so his feedback on one ticket named that session, and his message stood on the card of each of its cases.
    public func feedback(onJob level: JobLevel) -> Feedback? {
        guard hasChat(level.agent) else { return nil }
        let readable = level.lines.map(\.task).filter { $0.scope_person == nil && level.taskIDs.contains($0.id) }
            .sorted { $0.id < $1.id }
        guard let named = readable.first(where: { $0.owner == level.agent })
                ?? readable.first(where: { $0.requester == level.agent }) else { return nil }
        return Feedback(recipient: level.agent, about: .job(named.id))
    }

    /// **His messages about a task**, oldest first: the feedback rows of its card.
    public func messages(aboutTask id: Int) -> [OwnerMessage] {
        messages.filter { $0.about?.place == .task(id) }.sorted { $0.created < $1.created }
    }

    /// **His messages about a job**, by any task of it, oldest first: the feedback rows of the job's card. Also by a task
    /// that somebody canceled after he wrote, which the card's list no longer shows (`JobLevel.taskIDs`).
    public func messages(aboutJob level: JobLevel) -> [OwnerMessage] {
        messages.filter {
            if case .job(let id)? = $0.about?.place { level.taskIDs.contains(id) } else { false }
        }.sorted { $0.created < $1.created }
    }

    /// **The agent's words that answer one message of his**, oldest first: its replies (`in_reply_to`) and the reports
    /// of the turn that it began (`turn`), as his chat shows them under it.
    public func replies(to message: OwnerMessage) -> [ManagerReport] {
        reports.filter { report in
            [report.in_reply_to, report.turn].contains { $0?.caseInsensitiveCompare(message.request_id) == .orderedSame }
        }.sorted { ($0.created, $0.id) < ($1.created, $1.id) }
    }
}

/// **The mark of where a task or a job stands, as the Tasks board and the detail card draw it**: the badge of his
/// message about a task or a job (`AboutBadge`) and the state row of the job level (`JobDetail`) draw it with one view
/// (`StandingMarkView`). A state is never violet (D-8).
public enum StandingMark: Equatable, Sendable {
    /// A task's own mark (`FleetTask.mark`): its symbol in its colour (`FleetTask.tint`); `inWork`: it is work now, and
    /// its mark turns.
    case task(symbol: String, tint: FleetTask.MarkTint, inWork: Bool)
    /// The orange raised hand: it waits for him (`HubState.ownerWaits`).
    case waits
    /// How a job ended (`JobLevel.result`): the board's green check, its red mark, or a muted circle.
    case ended(WorkItem.End)
    /// A job that goes on with no task that says where it stands: the muted dotted circle.
    case open

    /// It is work now: its mark turns.
    public var inWork: Bool { if case .task(_, _, true) = self { true } else { false } }
}

/// **The badge of what his message is about, over his words in the agent's chat** (design "Task details as a card over
/// the page", part 2; the owner, 21 November 2026, "Yes, build it" to its drawing): the mark of where the task or the
/// job stands and its title on one line; a press opens the card at it (`HubState.badge(about:jobs:)`).
public struct AboutBadge: Equatable, Sendable {
    public let title: String
    /// Where it stands and the card that a press opens, for a task or a job that the reading has; nil for one that it
    /// has no more: then the badge is its title alone, and it does not press.
    public let standing: Standing?

    public struct Standing: Equatable, Sendable {
        public let mark: StandingMark
        /// The words of where it stands, which VoiceOver reads after the title.
        public let words: String
        /// The level of the detail card that a press opens.
        public let opens: DetailPlace
    }
}

extension FleetTask {
    /// **Its mark and the words of where it stands, as a task's row of a job on the Tasks board draws them** (`JobCard`):
    /// the orange hand while it waits for him, with "Waits for you" for his request and the words of any other wait (as
    /// the job level's rows say them, `JobDetail`); else its own mark, in its colour of a row of its job
    /// (`tint(in:replaced:)`), with the word of its state. `replaced`: later work of its job took it over (`Job.replaced`).
    public func standing(in state: HubState, replaced: Bool = false) -> (mark: StandingMark, words: String) {
        if let wait = state.ownerWaits(of: [self])[id] {
            let words: String = if case .request = wait { String(l10n: "Waits for you") } else { wait.words }
            return (.waits, words)
        }
        let mark = self.mark(in: state)
        return (.task(symbol: mark.symbol, tint: tint(in: state, replaced: replaced), inWork: mark.inWork), mark.words)
    }

    /// **Its mark's colour in a row of its job**: muted for a result that did not succeed when later work of the job took
    /// it over (`Job.replaced`, `JobLevel.replaced`), as the board's row mutes it (`JobCard`): it is no news; else its own
    /// (`tint(in:)`).
    public func tint(in state: HubState?, replaced: Bool) -> MarkTint {
        endedBadly && replaced ? .quiet : tint(in: state)
    }
}

extension JobLevel {
    /// **Where the job stands, as the state row of the job level says it** (`JobDetail`), and as the badge of his message
    /// about the job marks it (`AboutBadge`): how it ended, by its result; while it goes on, the task that speaks for it
    /// (`lead`), in the mark and the words of that task: one that waits for him, else one in work now, else the open one
    /// that moved last; with no open task, the muted dotted circle and "Waiting".
    public func standing(in state: HubState) -> (mark: StandingMark, words: String, lead: FleetTask?) {
        let waits = state.ownerWaits(of: open)
        let lead = open.first { waits[$0.id] != nil } ?? open.first { $0.mark(in: state).inWork }
            ?? open.max { ($0.activityTime, $0.id) < ($1.activityTime, $1.id) }
        let wait = lead.flatMap { waits[$0.id] }
        let mark = lead?.mark(in: state)
        let words: String = if let result { result.words }
            else if case .request? = wait { String(l10n: "Waits for you") }
            else if let wait { wait.words }
            else { mark?.words ?? String(l10n: "Waiting") }
        let shown: StandingMark = if let end = result?.end { .ended(end) }
            else if wait != nil { .waits }
            else if let lead, let mark { .task(symbol: mark.symbol, tint: lead.tint(in: state), inWork: mark.inWork) }
            else { .open }
        return (shown, words, lead)
    }
}

extension HubState {
    /// **The jobs of the board of every agent, by the id of each of their tasks** (`jobs`), also of a task that somebody
    /// canceled, for the badges of his messages about a task or a job (`badge(about:jobs:)`). It works the whole board
    /// out, so a reading works it out once (`FleetStore.aboutBadge`).
    public var jobsByTask: [Int: Job] {
        var byTask: [Int: Job] = [:]
        for job in jobs(of: nil) {
            for task in job.tasks { byTask[task.id] = job }
        }
        return byTask
    }

    /// **The badge of what his message is about** (`AboutBadge`), over his words in the agent's chat. A task that the
    /// reading has: its title, and its mark as a task's row of its job on the board draws it (`FleetTask.standing`, with
    /// the job's `replaced`); a press opens its task level. A job, which the message names by one of its tasks, also one
    /// that somebody canceled since (`MessagePlace.job`): the name of the job of the
    /// board of every agent that holds that task, as the board names it, and the mark of the job level's state row
    /// (`JobLevel.standing`); a press opens the level of that whole job, of no one agent's board. A task or a job that
    /// the reading has no more: the title that the hub gave, alone, with no mark and no press; with no title either (a
    /// task that the hub has no more, or his message on its way, `OwnerMessage(onItsWay:)`), and for a message about
    /// nothing that this app reads, nil: no badge. `jobs`: the reading's `jobsByTask`, read only for a task or a job
    /// that the reading has.
    public func badge(about: MessageAbout, jobs: @autoclosure () -> [Int: Job]) -> AboutBadge? {
        switch about.place {
        case .task(let id)?:
            if let task = tasks.first(where: { $0.id == id }) {
                let standing = task.standing(in: self, replaced: jobs()[id]?.replaced.contains(id) == true)
                return AboutBadge(title: task.title, standing: .init(mark: standing.mark, words: standing.words,
                                                                     opens: .task(id)))
            }
        case .job(let id)?:
            if let job = jobs()[id] {
                let standing = jobLevel(job).standing(in: self)
                return AboutBadge(title: job.title, standing: .init(mark: standing.mark, words: standing.words,
                                                                    opens: .job(job.id, board: nil)))
            }
        case nil:
            return nil
        }
        guard let title = about.title, !title.isEmpty else { return nil }
        return AboutBadge(title: title, standing: nil)
    }

    /// **What a correction of his message is about**: the message's own `about`, so the corrected words keep its badge
    /// and stand on its card, as the hub keeps it for an edit in place. Left out only where the reading shows that the
    /// chat cannot read the named task (its agent is neither the task's agent nor its requester, or the task is a
    /// narrowed pair's): the hub refuses such a message whole (409 `about_unreadable`), and a correction must go. A task
    /// that the reading does not have keeps it: the hub leaves out a task that it has no more, and the message goes; one
    /// in a block of older tasks passed the same check when the first message went.
    public func correctionAbout(of message: OwnerMessage) -> MessagePlace? {
        guard let place = message.about?.place else { return nil }
        let id = switch place { case .task(let id), .job(let id): id }
        guard let task = tasks.first(where: { $0.id == id }) else { return place }
        let readable = [task.owner, task.requester].contains(message.chatRecipient) && task.scope_person == nil
        return readable ? place : nil
    }
}
