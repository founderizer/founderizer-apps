import FleetCore
import Foundation

// The phone's own reads (UI-API.md, "The owner's phone (owner feature `mobile`)"). `GET /ui/state` is 671 KiB on the
// live hub; these three answers are the heads that each page needs, one page at a time. The models reuse FleetCore's
// where the hub sends the same rows (`OwnerNeed`, `TaskHold`, `TaskOutcome`, `ProgressNote`, `FleetTask`,
// `RuntimeLimit`, `ManagerWarning`) and name their own where the hub sends less.

/// `GET /ui/mobile`: the heads of the whole fleet, with an `ETag`.
struct MobileSnapshot: Decodable, Sendable {
    let schema_version: Int
    let db: String
    /// The hub's own clock when it made this answer.
    let time: Double
    let manager_warning: ManagerWarning?
    /// The hub's own feature names, the same list that `/ui/state` gives, so the phone never reads that snapshot.
    let ui_features: [String]?
    let agents: [MobileAgent]
    /// The open items, in full: they are short and they are the point of the app.
    let needs: [OwnerNeed]
    /// **The newest answered items, at most 50, oldest first** (fix round 2, item 103): a chat folds the ones its agent
    /// raised to two lines where they stood, as the Mac's chat does. A hub from before them sends none, and a chat then
    /// shows the open ones only.
    let answered_needs: [OwnerNeed]?
    /// The heads of the open tasks, and `recent` the heads of the last 20 that ended.
    let tasks: [MobileTaskHead]
    let recent: [MobileTaskHead]
    /// The holds that are not released and the outcomes that nobody resolved: both stop work.
    let holds: [TaskHold]
    let outcomes: [TaskOutcome]
    let counts: MobileCounts?
    /// The hub's change token (`live_changes`, UI-API.md 1.47), which the wait on `GET /ui/wait` asks from. A hub that
    /// does not send it is read on the clock alone.
    let token: String?

    static func decode(_ data: Data) throws -> MobileSnapshot {
        guard data.count <= 2_000_000 else { throw MobileError.invalidResponse }
        let read = try JSONDecoder().decode(Self.self, from: data)
        guard read.schema_version == 1, !read.db.isEmpty, read.time.isFinite,
              Set(read.agents.map(\.id)).count == read.agents.count,
              Set(read.needs.map(\.id)).count == read.needs.count,
              Set((read.answered_needs ?? []).map(\.id)).count == (read.answered_needs ?? []).count,
              Set(read.tasks.map(\.id)).count == read.tasks.count,
              Set(read.recent.map(\.id)).count == read.recent.count
        else { throw MobileError.invalidResponse }
        return read
    }
}

struct MobileCounts: Decodable, Sendable {
    let tasks_open: Int
    let needs_open: Int
    let messages: Int
    let reports: Int
}

/// One agent's row: what the Chats list, the Fleet page and a chat header show, without the whole usage record.
struct MobileAgent: Decodable, Identifiable, Sendable {
    let name: String
    let role: String
    /// **Its role in the team** (team.json `title`, hub 1.112), which the phone shows as its name, with the name
    /// under it on its page. nil: none set, or an older hub.
    let title: String?
    let runtime: String
    let active: Bool?
    let direct_chat: Bool?
    let last_seen: Double?
    /// The agent's open tasks, counted by the hub.
    let open_tasks: Int
    /// The hub holds this agent's work until its usage limit resets.
    let limit: RuntimeLimit?
    /// At most four windows of the newest reading, highest share first on screen.
    let usage: [MobileUsageWindow]
    /// The newest line of the conversation with this agent, for its row.
    let last: MobilePreview?
    /// The server it runs on, for its page (Runs on). A hub that does not send it leaves it out, and the page then
    /// names the provider alone.
    let machine: String?
    /// When he sent the newest chat message that it had read at its last turn end (hub 1.110), as on the Mac
    /// (`FleetAgent.turn_ended_after`): its turn that took a message sent up to then is over. nil for every agent but
    /// the manager, before the first such message, and from an older hub.
    let turn_ended_after: Double?

    var id: String { name }

    /// The helper answered in the last minute of the hub's own clock. It says only that: the hub reports no other
    /// activity, so this is never "idle".
    func helperIsRecent(serverTime: Double) -> Bool {
        guard let last_seen else { return false }
        return serverTime - last_seen >= -5 && serverTime - last_seen < 60
    }

    /// The hub's clock that this helper's age counts at. The tag of `GET /ui/mobile` holds whether each helper
    /// answered in the last minute, not when (UI-API.md 1.47), so a 304 keeps the times of the answer: a helper that
    /// was recent in it is recent still and its age is the one it had then, and any other has not answered since, so
    /// its age moves on with the hub's clock now.
    func helperClock(serverTime: Double, hubNow: Double) -> Double {
        helperIsRecent(serverTime: serverTime) ? serverTime : hubNow
    }

    /// The window with the highest used share, which is the one the row shows.
    var busiestWindow: MobileUsageWindow? {
        usage.filter { $0.used_percent != nil }.max { ($0.used_percent ?? 0) < ($1.used_percent ?? 0) }
    }
}

struct MobileUsageWindow: Decodable, Sendable {
    let label: String?
    let used_percent: Double?
    let resets_at: Double?
    /// The used share in whole percent, as the words show it.
    var percent: Int? { used_percent.map { Int($0.rounded()) } }

    /// The window's length in few characters, as the Mac writes it ("5 h", "7 d", "45 min"): the hub's label without
    /// the provider's bucket before it ("codex / 7 days") or the model it is scoped to after it ("5 hours (Fable)").
    /// A label with no length stays as the hub wrote it. The phone's read carries the label only, not the minutes the
    /// Mac counts from.
    var shortLabel: String {
        guard var words = label?.trimmingCharacters(in: .whitespaces), !words.isEmpty else { return "Window" }
        if let bucket = words.range(of: " / ", options: .backwards) { words = String(words[bucket.upperBound...]) }
        if let scope = words.range(of: " (") { words = String(words[..<scope.lowerBound]) }
        let parts = words.split(separator: " ")
        guard parts.count == 2, let length = Int(parts[0]), length > 0 else { return words }
        let minutes: Int
        switch parts[1].lowercased() {
        case "minute", "minutes": minutes = length
        case "hour", "hours": minutes = length * 60
        case "day", "days": minutes = length * 1440
        default: return words
        }
        // The Mac's own rule (`UsageWindow.shortLabel`), from the minutes.
        if minutes % 1440 == 0 { return "\(minutes / 1440) d" }
        if minutes % 60 == 0 { return "\(minutes / 60) h" }
        return "\(minutes) min"
    }
}

/// The newest line of one conversation: who wrote it, when, and its first 120 characters.
struct MobilePreview: Decodable, Sendable {
    let ts: Double
    /// `owner` or `agent`.
    let side: String
    let preview: String
    var isFromAgent: Bool { side == "agent" }
}

/// A task's head. It has no `details`, `done_when`, `what`, `where_`, `how` or `check_note`: those come with the task
/// itself, from `GET /ui/mobile/task/<id>`.
struct MobileTaskHead: Decodable, Identifiable, Sendable {
    let id: Int
    let title: String
    let state: String
    let owner: String
    let requester: String
    let goal: String?
    let needs: String?
    let attempt: Int
    let accepted: Int?
    let created: Double
    let started: Double?
    let last_activity: Double?
    let delivered: Double?
    let checked_at: Double?
    let waiting_on: String?
    let follows: Int?
    /// A stall and a lost session, as the task itself carries them. A hub from before they were in the head sends
    /// neither, and the head then says what its other fields know.
    let stalled_since: Double?
    let nudge_level: Int?
    let missing_since: Double?

    var isTerminal: Bool { ["completed", "failed", "rejected", "canceled"].contains(state) }
    /// The time of the task's last activity, or its created time while it has not started.
    var activityTime: Double { started == nil ? created : last_activity ?? started ?? created }

    /// The word for a result that is not a success, or nil: a success, a result that waits for its check, or open
    /// work.
    var failedResult: String? {
        switch state {
        case "failed": "Failed"
        case "rejected": "Rejected"
        case "canceled": "Canceled"
        case "completed": accepted == 0 ? "Not accepted" : nil
        default: nil
        }
    }
}

/// `GET /ui/mobile/chat/<agent>`: one page of a conversation, oldest first, at most 30 items.
struct MobileChatPage: Decodable, Sendable {
    let db: String
    let agent: String
    let items: [MobileChatItem]
    /// The time of the last item, which asks for the page after it.
    let cursor: Double
}

/// One line of a conversation: a message of the owner, or a report of the agent.
struct MobileChatItem: Decodable, Identifiable, Sendable, Equatable {
    enum Kind: String, Decodable, Sendable { case message, report }
    let kind: Kind
    let ts: Double
    /// A message's request UUID, or a report's number.
    let key: String
    /// The words. A message that nothing read yet changes them where it stands when he corrects it (owner feature
    /// `edit_in_place`; review A2), so they are the one field that changes in place.
    var text: String
    /// A message: the client that sent it, when the agent read it, and the request that it replaces.
    let client: String?
    let read_at: Double?
    let replaces: String?
    /// A report: what it is about, the message that it answers, and whether the agent wrote it to the owner first
    /// (`message_owner`). A hub from before that change sends no `pushed`, and the mark then stays off rather than
    /// resting on a guess.
    let about: String?
    let in_reply_to: String?
    /// Owner feature `attachments`: the files that went with the owner's message.
    let attachments: [MessageAttachment]
    let pushed: Bool?
    /// A message: the request that it answers (fix round 2, item 103), whose folded card shows the answer in the chat,
    /// so the message is no second bubble. nil for every other message, and on a hub from before the field.
    let answer_to: Int?

    var id: String { "\(kind.rawValue)-\(key)" }
    /// The agent wrote this to the owner first: it answers no message.
    var isPushed: Bool { pushed == true }

    /// **A message of his that is on its way, as the item it will be when the hub's read brings it** (fix round 2,
    /// item 74): the same id (the request's number, as the hub keeps it), his client and his words, so the
    /// conversation draws it in its place from the send's first frame — in its run, under its stamp, with the time's
    /// slot under it — and the read that brings the message itself changes nothing around it.
    init(waiting request: PendingRequest) {
        kind = .message
        ts = request.createdAt.timeIntervalSince1970
        key = request.requestID.uuidString.lowercased()
        text = request.text
        client = request.client
        read_at = nil
        replaces = request.replacesRequestID
        about = nil
        in_reply_to = nil
        attachments = []
        pushed = nil
        answer_to = nil
    }

    private enum CodingKeys: String, CodingKey {
        case kind, ts, id, text, client, read_at, replaces, about, in_reply_to, attachments, pushed, answer_to
    }

    init(from decoder: Decoder) throws {
        let data = try decoder.container(keyedBy: CodingKeys.self)
        kind = try data.decode(Kind.self, forKey: .kind)
        ts = try data.decode(Double.self, forKey: .ts)
        // A message is known by its request UUID, a report by its number.
        if let number = try? data.decode(Int.self, forKey: .id) { key = String(number) }
        else { key = try data.decode(String.self, forKey: .id) }
        text = try data.decode(String.self, forKey: .text)
        attachments = try data.decodeIfPresent([MessageAttachment].self, forKey: .attachments) ?? []
        client = try data.decodeIfPresent(String.self, forKey: .client)
        read_at = try data.decodeIfPresent(Double.self, forKey: .read_at)
        replaces = try data.decodeIfPresent(String.self, forKey: .replaces)
        about = try data.decodeIfPresent(String.self, forKey: .about)
        in_reply_to = try data.decodeIfPresent(String.self, forKey: .in_reply_to)
        pushed = try data.decodeIfPresent(Bool.self, forKey: .pushed)
        answer_to = try data.decodeIfPresent(Int.self, forKey: .answer_to)
    }

    /// This item in the hub's own words, so that the phone keeps a chat between launches and reads it back with the
    /// decoder above, and with nothing of its own. A report's number goes as text, which that decoder takes too.
    var wire: [String: Any] {
        var fields: [String: Any] = ["kind": kind.rawValue, "ts": ts, "id": key, "text": text,
                                     "attachments": attachments.map(\.wire)]
        if let client { fields["client"] = client }
        if let read_at { fields["read_at"] = read_at }
        if let replaces { fields["replaces"] = replaces }
        if let about { fields["about"] = about }
        if let in_reply_to { fields["in_reply_to"] = in_reply_to }
        if let pushed { fields["pushed"] = pushed }
        if let answer_to { fields["answer_to"] = answer_to }
        return fields
    }
}

extension MessageAttachment {
    /// The file in the hub's own words, for a chat that the phone keeps (`MobileChatItem.wire`).
    var wire: [String: Any] {
        var fields: [String: Any] = ["id": id, "name": name, "mime": mime, "size": size, "sha256": sha256,
                                     "created": created]
        if let kept {
            var keep: [String: Any] = ["at": kept.at]
            if let knowledge = kept.knowledge { keep["knowledge"] = knowledge }
            fields["kept"] = keep
        }
        return fields
    }
}

/// `GET /ui/mobile/task/<id>`: the task itself, with its notes after the cursor, its holds and its outcomes.
struct MobileTaskPage: Decodable, Sendable {
    let db: String
    let task: FleetTask
    let notes: [ProgressNote]
    let holds: [TaskHold]
    let outcomes: [TaskOutcome]
    /// The number of the last note, which asks for the notes after it.
    let cursor: Int
}

/// `POST /ui/owner/enroll`: the key of this phone, given once and never again.
struct MobileEnrollment: Decodable, Sendable {
    let device: String
    let label: String
    let key: String
    let since: Double?
}

/// `GET /ui/owner/devices`: the owner's devices. `key` says that the hub has one, and is never a key itself.
struct MobileDeviceList: Decodable, Sendable {
    let db: String
    let devices: [MobileDevice]
    var thisDevice: MobileDevice? { devices.first { $0.this_device == true } }
}

struct MobileDevice: Decodable, Identifiable, Sendable {
    let device: String
    let label: String
    let address: String
    let key: Bool?
    let since: Double?
    let last_seen: Double?
    let this_device: Bool?
    var id: String { device }
}
