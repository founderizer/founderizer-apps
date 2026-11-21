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
    /// when the agent has no chat or no such task.
    public func feedback(onJob level: JobLevel) -> Feedback? {
        guard hasChat(level.agent) else { return nil }
        let readable = level.lines.map(\.task).filter { $0.scope_person == nil }.sorted { $0.id < $1.id }
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
