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
    public fileprivate(set) var text: String
    public let createdAt: Date
    public let client: String
    public var refusal: String?

    public init(hub: URL, database: String, client: String, needID: Int? = nil, choice: Int? = nil, choices: [Int]? = nil, recipient: String? = nil, replacesRequestID: String? = nil, command: OwnerCommand? = nil, attachments: [Int] = [], approval: (statement: String, signature: String)? = nil, text: String) {
        requestID = UUID()
        self.attachments = attachments
        statement = needID == nil ? nil : approval?.statement
        signature = needID == nil ? nil : approval?.signature
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
        text = try saved.decode(String.self, forKey: .text)
        createdAt = try saved.decode(Date.self, forKey: .createdAt)
        client = try saved.decode(String.self, forKey: .client)
        refusal = try saved.decodeIfPresent(String.self, forKey: .refusal)
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
        else { fields[needID == nil ? "text" : "answer"] = text }
        if let recipient { fields["recipient"] = recipient }
        if let replacesRequestID { fields["replaces_request_id"] = replacesRequestID }
        if !attachments.isEmpty { fields["attachments"] = attachments }
        if let statement, let signature, needID != nil { fields["statement"] = statement; fields["signature"] = signature }
        return try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
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
        case .pendingRequest: "Another saved request is waiting for a receipt."
        case .invalidRecord: "The saved request cannot be read. Sending is blocked to prevent a duplicate."
        }
    }
}
