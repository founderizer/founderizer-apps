import Foundation

extension FleetTask {
    /// **Until when its agent parked it, while nothing else holds it**: it waits on nothing else (`parkedOnly`: parked,
    /// `working`, no question or thing that it waits on), no hold of the owner's that is not released, and no usage
    /// limit (`HubState.limit(of:)`); nil for every other task, which says its own wait. The rule of the row of an ask in a chat
    /// (`ChatAskRow`) and of the task's own panel (`TaskPanel`), which say "Resumes at 02:30"; the Tasks board's words
    /// (`ActivityBoard.why`) keep the same rule on their own list of the holds that are not released.
    public func parkedUntil(in state: HubState?) -> Double? {
        guard parkedOnly, let until = parked_until,
              state?.holds?.contains(where: { $0.task == id && $0.state != "released" }) != true,
              state?.limit(of: self) == nil else { return nil }
        return until
    }

    /// **The words of its result at rest, on its page**: what came of it in plain words for him (`plain`, owner API
    /// 1.226), when its agent or the hub wrote a line that is not its whole result again, else the whole result
    /// (`what`). Show more opens the whole result in their place (the owner's "Yes, for every agent" of 19 November
    /// 2026: the page showed the result that the agent wrote for its requester, with host names, versions and codes).
    /// nil: no result.
    public var resultAtRest: String? {
        guard let plain = Job.words(plain), plain != Job.words(what) else { return what }
        return plain
    }

    /// **Its guidance takes files** (owner API 1.223 and 1.231; the owner's "Yes, build it" of 19 November 2026 to the
    /// pictures of the plus on the guidance box): a hub that says so (`steer_files`, with `attachments`; an older one
    /// dropped a steer's files in silence) and a task that no person's conversation drives (`from_conversation`), whose
    /// person could get what the file says. A hub that does not say which task that is gives none.
    public func guidanceTakesFiles(in state: HubState?) -> Bool {
        state?.ui_features?.contains("attachments") == true && state?.ui_features?.contains("steer_files") == true &&
            from_conversation == false
    }

    /// **Which files its guidance takes**: the files that its session can open. A worker's or a lead's session whose
    /// Shell box is off (the hub's `shell_off`; the manager always has a shell) opens only what the hub gives in a tool's
    /// answer: a picture or a text, and only a text where its AI program shows no picture of a tool's answer.
    public func guidanceFiles(in state: HubState?) -> GuidanceFiles {
        guard let agent = state?.agents.first(where: { $0.name == owner }), ["worker", "lead"].contains(agent.role),
              !agent.can.contains("shell") else { return .any }
        return GuidanceFiles.pictureRuntimes.contains(agent.runtime) ? .shown : .texts
    }

    /// **His own words, when the task is what he asked an agent for in that agent's chat** (`start_task`), or nil. The
    /// hub opens such a task for the agent's line (the manager or a lead is its requester) and writes his message as its
    /// details after a fixed sentence (`hub.py` `HISTORY_OWNER_TASK`, and `HISTORY_OWNER_TASK_BEFORE` before 3
    /// November 2026), which its own history reads in the same way. The task's thread shows them as his message, not as
    /// the words of its requester.
    public var ownersWords: String? {
        for opening in Self.ownersOpenings where details.hasPrefix(opening) {
            guard let chat = details.range(of: "'s chat: ", range: details.index(details.startIndex, offsetBy: opening.count)..<details.endIndex)
            else { return nil }
            let words = details[chat.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            return words.isEmpty ? nil : words
        }
        return nil
    }

    /// The hub's openings of a task that the owner asked for in an agent's chat: hub data, never shown.
    static let ownersOpenings = ["The owner asked for this in their own words, in ", "The owner asked for this in his own words, in "]
}


/// **Whether a usage limit holds a task: one rule for every screen of both apps** (owner API 1.330; the owner, 24 November
/// 2026: an agent's usage was wrong, and the fleet had wrong data about that agent). An agent can run its screen tasks
/// on another account. A hold of that route now keeps only those tasks, and the agent's `limit` is the hold of its own
/// route only. So a task's wait comes from its own `limit` on a hub that sends it (`feature`): nil there is no wait,
/// also while its agent's `limit` is set. A hub before it sends no task `limit`, and its agent's `limit` decides, as
/// before. The agent's own row and chat read the agent's `limit` alone, on every hub.
public enum TaskLimit {
    /// `ui_features` of a hub that gives each task its own `limit` (`GET /ui/state`, `GET /ui/mobile` and the phone's
    /// task page).
    public static let feature = "task_limit"

    /// Whether the hub of these feature names gives each task its own `limit`.
    public static func served(_ features: [String]?) -> Bool { features?.contains(feature) == true }

    /// The hold that keeps a task waiting now: `task`, its own `limit`, on a hub that serves it; else `agent`, the
    /// `limit` of the task's agent.
    public static func holding(task: RuntimeLimit?, agent: RuntimeLimit?, served: Bool) -> RuntimeLimit? {
        served ? task : agent
    }
}

extension HubState {
    /// **The usage limit that holds `task` now**, or nil (`TaskLimit`): the reading of every task's "Usage limit", its
    /// mark, its column on the board and the limit line of its thread.
    public func limit(of task: FleetTask) -> RuntimeLimit? {
        TaskLimit.holding(task: task.limit, agent: agents.first { $0.name == task.owner }?.limit,
                          served: TaskLimit.served(ui_features))
    }

    /// **The tasks that a usage limit holds now**, by id: `limit(of:)` for each task of this reading, with one look at
    /// the features and the agents, for a list that reads many tasks (the board, the jobs).
    public var limitedTasks: Set<Int> {
        let served = TaskLimit.served(ui_features)
        let agents = Dictionary(self.agents.compactMap { agent in agent.limit.map { (agent.name, $0) } }) { first, _ in first }
        return Set(tasks.lazy.filter { TaskLimit.holding(task: $0.limit, agent: agents[$0.owner], served: served) != nil }.map(\.id))
    }
}

/// **The files that a task's guidance takes** (`FleetTask.guidanceFiles`).
public enum GuidanceFiles: Equatable, Sendable {
    /// Every file that a message takes.
    case any
    /// Pictures and texts, each picture made small enough for a tool's answer (`MessageAttachment.shownPictureBytes`).
    case shown
    /// Texts only.
    case texts

    /// The AI programs that show a tool's picture to their model (`lifecycle.py` `RUNTIMES`, `tool_pictures`). A
    /// program that is not here gets no picture, so this list going stale only makes a box take fewer files.
    public static let pictureRuntimes: Set<String> = ["claude", "codex"]

    /// Whether a box of this kind takes a file of this type. `.any` takes Word, Excel and PowerPoint too: the store
    /// stages them only for a hub that takes them (`MessageAttachment.sendable`), and a session with a shell opens them.
    public func takes(_ mime: String) -> Bool {
        switch self {
        case .any: MessageAttachment.sendable(mime, office: true)
        case .shown: MessageAttachment.opensWithoutShell(mime)
        case .texts: MessageAttachment.isText(mime)
        }
    }
}
