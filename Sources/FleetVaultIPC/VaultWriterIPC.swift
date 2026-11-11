import Foundation

/// One submission of a new login, as the writer keeps it in its journal. A record has no secret: the value is only in
/// the create call. `title` is the item's name; `login` is `bws://<uuid>` when the item is known. `hub` and `db` are
/// the hub address and the database generation of the submission: the login is registered there and nowhere else.
/// `binding` and `mark` are only in a record of a worker's save (`create`): the hash of what the hub confirmed for the
/// job, and the note of the item, by which the vault finds it again.
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
