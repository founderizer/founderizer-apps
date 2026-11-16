import Foundation

/// A request is written before transmission and keeps its identity across launches.
public struct PendingRequest: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let hub: URL
    public let database: String
    public let needID: Int?
    /// A Needs-you item answered by pressing one of its own options: the 0-based index into them (API 1.18). The
    /// hub writes that option's own words as the answer, so `text` holds them for this app to show and is not
    /// sent: `choice` and `answer` are exclusive.
    public let choice: Int?
    /// Owner feature `need_talk` (API 1.106): the options he ticked on an item whose options combine, their indexes in
    /// order. The hub joins their words as the answer, so `text` holds them for this app to show and is not sent.
    public let choices: [Int]?
    public let recipient: String?
    public let command: OwnerCommand?
    public let replacesRequestID: String?
    /// Owner feature `attachments`: the files that the hub already holds and that this message carries. They are
    /// sent up before the message, so only their numbers travel here.
    public let attachments: [Int]
    /// Owner feature `door_calls` (API 1.79): the owner's signed yes to the door call of the item it answers, sent
    /// beside the answer. nil on every other request.
    public let statement: String?
    public let signature: String?
    /// Owner feature `need_run` (API 1.197): his press of Run on the item's command, with what this Mac read of the run:
    /// its exit status and the end of its output. The hub writes the answer itself, so `text` holds its words
    /// (`NeedRun.answerWords`) and is not sent. nil on every other request.
    public let ran: NeedRunResult?
    public fileprivate(set) var text: String
    public let createdAt: Date
    public let client: String
    /// Set when the request was refused: **the mark that it waits for the owner's Discard or Try again**, and the words
    /// that an older version of the app kept for it, "Hub refused the request (409): ..." in English, which
    /// `HubError.refusalStatus(in:)` reads back. A version that has `hubRefusal` writes both (`refuse(_:)`), so that
    /// every reader of the mark, the iPhone's among them, stands as it did. Read the refusal through `refusedByHub`.
    public var refusal: String?
    /// **The hub's refusal of this request as fields** (the design `hub-refusal-words-design.md`): its status, its English
    /// line, its code and its names, as `HubRefusal` has them. The app's words for it are made when the owner reads
    /// them, in the language of that day, and never kept: a refusal that was written in Spanish could not be read
    /// back by its prefix, and a hub's English line must stay the hub's. nil for a request that was never refused and
    /// for one that an older version refused (its words are in `refusal`).
    public var hubRefusal: HubRefusal?

    public init(hub: URL, database: String, client: String, needID: Int? = nil, choice: Int? = nil, choices: [Int]? = nil, recipient: String? = nil, replacesRequestID: String? = nil, command: OwnerCommand? = nil, attachments: [Int] = [], approval: (statement: String, signature: String)? = nil, ran: NeedRunResult? = nil, text: String) {
        requestID = UUID()
        self.attachments = attachments
        statement = needID == nil ? nil : approval?.statement
        signature = needID == nil ? nil : approval?.signature
        self.ran = needID == nil || choice != nil || choices != nil ? nil : ran
        self.hub = hub
        self.database = database
        self.needID = needID
        self.choice = needID == nil ? nil : choice
        self.choices = needID == nil || choice != nil ? nil : choices.map { Array(Set($0)).sorted() }
        self.recipient = recipient
        self.command = command
        self.replacesRequestID = replacesRequestID
        self.text = text
        self.client = client
        createdAt = Date()
    }

    public init(from decoder: Decoder) throws {
        let saved = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try saved.decode(UUID.self, forKey: .requestID)
        hub = try saved.decode(URL.self, forKey: .hub)
        database = try saved.decode(String.self, forKey: .database)
        needID = try saved.decodeIfPresent(Int.self, forKey: .needID)
        choice = try saved.decodeIfPresent(Int.self, forKey: .choice)
        choices = try saved.decodeIfPresent([Int].self, forKey: .choices)
        recipient = try saved.decodeIfPresent(String.self, forKey: .recipient)
        command = try saved.decodeIfPresent(OwnerCommand.self, forKey: .command)
        replacesRequestID = try saved.decodeIfPresent(String.self, forKey: .replacesRequestID)
        // A request that an older version of the app saved carries no files.
        attachments = try saved.decodeIfPresent([Int].self, forKey: .attachments) ?? []
        statement = try saved.decodeIfPresent(String.self, forKey: .statement)
        signature = try saved.decodeIfPresent(String.self, forKey: .signature)
        // A request that a version before Run saved carries no run.
        ran = try saved.decodeIfPresent(NeedRunResult.self, forKey: .ran)
        text = try saved.decode(String.self, forKey: .text)
        createdAt = try saved.decode(Date.self, forKey: .createdAt)
        client = try saved.decode(String.self, forKey: .client)
        refusal = try saved.decodeIfPresent(String.self, forKey: .refusal)
        // A request that an older version of the app saved has its refusal in `refusal`, as text.
        hubRefusal = try saved.decodeIfPresent(HubRefusal.self, forKey: .hubRefusal)
    }

    /// The hub refused this request: its fields, and the English text that older readers and the mark `refusal` stand on.
    public mutating func refuse(_ refusal: HubRefusal) {
        hubRefusal = refusal
        self.refusal = HubError.refusalText(refusal)
    }

    /// **The hub's refusal of this request, as the apps read it**: the fields where this version wrote them, else the
    /// text that an older version kept, read back by its English prefix (`HubError.refusalStatus(in:)`); nil for a
    /// request that was never refused and for words that are the app's own (a door card's refusal, registered login
    /// text), which no status stands in front of.
    public var refusedByHub: HubRefusal? {
        if let hubRefusal { return hubRefusal }
        guard let refusal, let status = HubError.refusalStatus(in: refusal) else { return nil }
        return HubRefusal(status: status, hubWords: HubError.refusalWords(in: refusal) ?? refusal)
    }

    /// The refusal as one line for a screen, "Hub refused the request (409): ..." in the language of the device, with the
    /// app's words for the hub's code where it has them; for words that no status stands in front of, those words.
    public var refusalLine: String? {
        refusedByHub.map { HubError.refusal($0).localizedDescription } ?? refusal
    }

    public var route: String { command?.route ?? needID.map { "ui/needs/\($0)" } ?? "ui/messages" }

    /// **Its name in the window's request line**: its item's own title (`OwnerCommand.label(in:schedules:)`) only from a
    /// reading of the hub and the generation it belongs to. A write left from another hub, or from this hub before it was
    /// installed again, has numbers that this reading gives to other items: the line named it "Pause “<this hub's task
    /// 7>”" (the review of 30 October 2026). Then it has its plain name, "Pause T-7", "Run schedule".
    public func name(hub current: URL, state: HubState?, schedules: [FleetTrigger]) -> String {
        guard let command else { return text }
        guard hub == current, let state, database == state.db else { return command.label }
        return command.label(in: state, schedules: schedules)
    }

    public func body() throws -> Data {
        if let command {
            let fields = try command.bodyFields(text: text).merging(["request_id": requestID.uuidString.lowercased(), "db": database]) { _, new in new }
            return try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        }
        var fields: [String: Any] = ["request_id": requestID.uuidString.lowercased(), "db": database]
        if let choice, needID != nil { fields["choice"] = choice }
        else if let choices, needID != nil { fields["choices"] = choices }
        else if let ran, needID != nil { fields["ran"] = ["status": ran.status, "output": ran.output] }
        else { fields[needID == nil ? "text" : "answer"] = text }
        if let recipient { fields["recipient"] = recipient }
        if let replacesRequestID { fields["replaces_request_id"] = replacesRequestID }
        if !attachments.isEmpty { fields["attachments"] = attachments }
        if let statement, let signature, needID != nil { fields["statement"] = statement; fields["signature"] = signature }
        return try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    }
}

/// What this Mac read of one press of Run (owner feature `need_run`): the command's exit status, 0 to 255, and the end
/// of its output, at most `NeedRun.outputCharacters`.
public struct NeedRunResult: Codable, Equatable, Sendable {
    public let status: Int
    public let output: String
    public init(status: Int, output: String) {
        self.status = min(max(status, 0), 255)
        self.output = NeedRun.tail(output)
    }
}

public struct Outbox: Sendable {
    public let file: URL

    public init(file: URL) { self.file = file }

    public func load() throws -> PendingRequest? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try Data(contentsOf: file)
        guard data.count <= 262_144 else { throw OutboxError.invalidRecord }
        return try JSONDecoder().decode(PendingRequest.self, from: data)
    }

    public func save(_ request: PendingRequest) throws {
        let encoded = try JSONEncoder().encode(request)
        guard encoded.count <= 262_144, try request.body().count <= 65_536 else { throw OutboxError.invalidRecord }
        if let existing = try load(),
           existing.requestID != request.requestID || existing.hub != request.hub ||
            existing.database != request.database || existing.needID != request.needID ||
            existing.choice != request.choice ||
            existing.command != request.command || existing.recipient != request.recipient || existing.replacesRequestID != request.replacesRequestID ||
            existing.attachments != request.attachments ||
            existing.statement != request.statement || existing.signature != request.signature ||
            existing.ran != request.ran ||
            existing.text != request.text || existing.client != request.client {
            throw OutboxError.pendingRequest
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try encoded.write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    public func clear(matching id: UUID) throws {
        guard let request = try load() else { return }
        guard request.requestID == id else { throw OutboxError.pendingRequest }
        try FileManager.default.removeItem(at: file)
    }

    public func rejectSecret(matching id: UUID, drafts: UserDefaults) throws -> PendingRequest {
        // The hub does not identify which substring is secret. Clear all local drafts.
        drafts.removeObject(forKey: "managerDraft")
        drafts.removeObject(forKey: "answerDrafts")
        drafts.removeObject(forKey: "agentDrafts")
        drafts.synchronize()
        guard var request = try load(), request.requestID == id else { throw OutboxError.invalidRecord }
        request.text = ""
        request.refusal = "The hub refused registered login text (422). Saved text and drafts were removed."
        do {
            try JSONEncoder().encode(request).write(to: file, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            // The refusal is definitive: deleting this rejected record cannot replay work.
            try FileManager.default.removeItem(at: file)
        }
        return request
    }
}

public enum OutboxError: LocalizedError {
    case pendingRequest, invalidRecord
    public var errorDescription: String? {
        switch self {
        case .pendingRequest: String(l10n: "Another saved request is waiting for a receipt.")
        case .invalidRecord: String(l10n: "The saved request cannot be read. Sending is blocked to prevent a duplicate.")
        }
    }
}
