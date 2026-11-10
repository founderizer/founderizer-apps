import Foundation

/// Fleet's one connection to the writer of Add secret: the signed Fleet Vault of the owner's Mac, which launchd starts
/// for this Mach service. Each side sets a code-signing requirement on the connection, as the setup service does.
public enum VaultWriterID {
    public static let service = "local.agent-fleet.vault.writer"
    /// Fleet sends a value only to code that satisfies this requirement: Fleet Vault, signed by this team.
    public static let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"6EBZ756H9Q\" and identifier \"local.agent-fleet.vault\""
}

/// Fleet sends typed requests only. `add` alone carries a value. No call gives back a token or a value. Each answer
/// is a `VaultWriterReply`.
@objc public protocol FleetVaultWriterProtocol {
    /// If the writer's one-time setup is done, and its submissions that are not finished.
    func state(reply: @escaping (Data) -> Void)
    /// One submission (`VaultAddRequest`). A `request_id` that has a record gets that record and no create call.
    func add(request: Data, reply: @escaping (Data) -> Void)
    /// Looks for the item of a submission with an unknown outcome. It makes nothing.
    func check(requestID: String, reply: @escaping (Data) -> Void)
    /// The salted fingerprints of a made item, for the hub's salts `{"password", "totp"}`.
    func fingerprints(requestID: String, salts: Data, reply: @escaping (Data) -> Void)
    /// Ends a submission: `registered` after Fleet's hub steps, else discarded by the owner's decision.
    func close(requestID: String, registered: Bool, reply: @escaping (Data) -> Void)
}

/// One submission of a new login, as the writer keeps it. A record has no secret: the value is only in the create
/// call. `title` is the item's name; `login` is `bws://<uuid>` when the item is known. `hub` and `db` are the hub
/// address and the database generation of the submission: the login is registered there and nowhere else.
/// `binding` and `mark` are only in a record of a worker's vault: the hash of what the hub confirmed for the job, and
/// the note of the item, by which the vault finds it again.
public struct VaultWriteRecord: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case creating, created, registered, unknown, failed, discarded }
    public let request_id: String
    public let title: String
    public let hub: String
    public let db: String
    public var state: State
    public var login: String?
    public let started_at: Double
    public var updated_at: Double
    public let binding: String?
    public let mark: String?
    /// A create call was sent, or can have been sent, and no answer proves its outcome.
    public var isOpen: Bool { state == .creating || state == .unknown }

    public init(request_id: String, title: String, hub: String, db: String, state: State, login: String?, started_at: Double,
                updated_at: Double, binding: String? = nil, mark: String? = nil) {
        self.request_id = request_id; self.title = title; self.hub = hub; self.db = db
        self.state = state; self.login = login; self.started_at = started_at; self.updated_at = updated_at
        self.binding = binding; self.mark = mark
    }
}

/// One salted fingerprint of a login's value. It is not the value.
public struct VaultFingerprint: Codable, Equatable, Sendable {
    public let kind: String
    public let hash: String
    public let len: Int
    public init(kind: String, hash: String, len: Int) { self.kind = kind; self.hash = hash; self.len = len }
}

/// Every answer of the writer. `error` is one of the writer's fixed texts and repeats no value.
public struct VaultWriterReply: Codable, Equatable, Sendable {
    public var ok: Bool
    public var error: String?
    public var ready: Bool?
    public var record: VaultWriteRecord?
    public var records: [VaultWriteRecord]?
    public var login: String?
    public var fingerprints: [VaultFingerprint]?

    public init(ok: Bool = true, error: String? = nil, ready: Bool? = nil, record: VaultWriteRecord? = nil, records: [VaultWriteRecord]? = nil,
                login: String? = nil, fingerprints: [VaultFingerprint]? = nil) {
        self.ok = ok; self.error = error; self.ready = ready; self.record = record; self.records = records
        self.login = login; self.fingerprints = fingerprints
    }

    public static let maxBytes = 4_194_304
    public static func decode(_ data: Data) -> VaultWriterReply? {
        data.count <= maxBytes ? try? JSONDecoder().decode(VaultWriterReply.self, from: data) : nil
    }
    public func data() -> Data { (try? JSONEncoder().encode(self)) ?? Data(#"{"ok":false}"#.utf8) }
}

/// The one message that carries a value. It is built for the send only: no type keeps the value, so no general
/// encoder can put it into a draft, the outbox or a log.
public enum VaultAddRequest {
    public static let maxBytes = 262_144

    /// `value`: the item value, the JSON object `{username, password, url[, totp]}`.
    public static func data(requestID: String, label: String, hub: String, db: String, value: Data) throws -> Data {
        guard let text = String(data: value, encoding: .utf8) else { throw CocoaError(.coderInvalidValue) }
        let message = try JSONSerialization.data(withJSONObject: ["request_id": requestID, "label": label, "hub": hub, "db": db, "value": text])
        guard message.count <= maxBytes else { throw CocoaError(.coderInvalidValue) }
        return message
    }

    public static func read(_ data: Data) -> (requestID: String, label: String, hub: String, db: String, value: Data)? {
        guard data.count <= maxBytes, let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              Set(object.keys) == ["request_id", "label", "hub", "db", "value"] else { return nil }
        return (object["request_id"]!, object["label"]!, object["hub"]!, object["db"]!, Data(object["value"]!.utf8))
    }
}
