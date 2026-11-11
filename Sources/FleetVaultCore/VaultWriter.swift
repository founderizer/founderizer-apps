import Darwin
import FleetVaultIPC
import Foundation

/// Why the writer did not do a step. No text repeats a value. `setup`, `provider` and `check` are the words that the
/// broker of a Mac with the fleet's own store gave already, so its answers stay the same.
public enum VaultWriteRefusal: String, Error, Sendable, CaseIterable {
    case request = "The request is not valid."
    case login = "The secret is not valid: a login needs a name, a user name, a password and an http or https address, and an API key needs a name and its key."
    case tooLong = "The login is too long for the vault store."
    case unresolved = "An earlier save has no known outcome. Check it or discard it first."
    case setup = "This machine's vault has no store of its own yet."
    case provider = "The vault store could not be opened for a save. Nothing was made."
    case state = "This save is not at that step."
    case journal = "Founderizer Vault could not keep its record of this save, so it made nothing."
    case check = "The vault store did not answer the check. Nothing changed."
    case changed = "This save was made with other values. It is not made again."
}

/// What one create call gave. `refused`: the store said that it made nothing. `unknown`: no answer proves the outcome,
/// so the item can exist.
enum VaultCreateOutcome: Equatable, Sendable { case created(String), refused, unknown }

/// What the writer asks of a store. The fleet's own store gives it (`VaultLocalStore`); tests use a stand-in that
/// counts the create calls, so no test makes an item in a real store.
protocol VaultItems {
    /// The organization of the place, which also proves that the store opens there.
    func organization(ofProject project: String) throws -> String
    /// The IDs of the project's items with exactly this name.
    func items(named name: String, project: String, organization: String) throws -> [String]
    func notes(of ids: [String]) throws -> [String: String]
    /// Sends exactly one create call.
    func create(name: String, value: String, note: String, project: String, organization: String) -> VaultCreateOutcome
    /// The secret values of one item: a login's, or an API key's without an address.
    func secret(id: String) throws -> VaultSecret
}

/// Where a writer keeps its journal: the bytes of all its records. A store that cannot be read or kept throws.
protocol VaultJournalStore: Sendable {
    /// The journal, or nil when there is none yet.
    func load(limit: Int) throws -> Data?
    func save(_ data: Data) throws
}

/// A journal in one file of mode 600. One exclusive lock on a file beside it, held for the life of the store, gives the
/// journal to one writer process: a second process, or a second writer in this process, gets a refusal and reads or
/// writes nothing. It was the journal of the owner's writer, and no program of the vault uses it now: the tests of the
/// journal do (`init(journal:)`).
final class VaultJournalFile: VaultJournalStore, @unchecked Sendable {
    private let file: URL
    private let lock: Int32

    init(_ file: URL) throws {
        self.file = file
        let folder = file.deletingLastPathComponent()
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil
        else { throw VaultWriteRefusal.journal }
        let fd = Darwin.open(folder.appendingPathComponent(file.lastPathComponent + ".lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw VaultWriteRefusal.journal }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw VaultWriteRefusal.journal }
        lock = fd
    }

    deinit { Darwin.close(lock) }

    func load(limit: Int) throws -> Data? {
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            guard errno == ENOENT else { throw VaultWriteRefusal.journal }
            return nil
        }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_size <= limit,
              let data = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data() else { throw VaultWriteRefusal.journal }
        return data
    }

    /// The whole journal in a new file of mode 600, flushed and then renamed over the old one.
    func save(_ data: Data) throws {
        let folder = file.deletingLastPathComponent()
        let temporary = folder.appendingPathComponent("." + file.lastPathComponent + "." + UUID().uuidString)
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw VaultWriteRefusal.journal }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) == $0.count } && fsync(fd) == 0
        Darwin.close(fd)
        guard written, rename(temporary.path, file.path) == 0 else { unlink(temporary.path); throw VaultWriteRefusal.journal }
        let directory = Darwin.open(folder.path, O_RDONLY | O_CLOEXEC)     // the new name must also be on disk
        if directory >= 0 { fsync(directory); Darwin.close(directory) }
    }
}

/// The journal of a worker's vault: one item in the helper's Keychain group. On a worker Mac the agents run as the
/// vault's own user, so they could change a file; only the signed helper reads and writes this item. One helper
/// process serves the machine, and it handles one request at a time.
struct VaultJournalKeychain: VaultJournalStore {
    let keychain: VaultKeychain
    /// `writes`: the logins that this vault made. `calls`: the requests that it started (`VaultCalls`).
    var item = "writes"
    func load(limit: Int) throws -> Data? {
        guard let data = try keychain.readIfPresent(item) else { return nil }
        guard data.count <= limit else { throw VaultWriteRefusal.journal }
        return data
    }
    func save(_ data: Data) throws { try keychain.save(data, item: item) }
}

/// The writer of new logins: it makes one item of the store for one submission. The journal decides, not a look-up: a
/// `request_id` gets a create call only while it has no record, the record is kept before the call, and a submission
/// with an unknown outcome (a process that ended during its call) is only reconciled (looked for by its mark), never
/// sent again. The actor handles one call at a time. The journal keeps the record of every `request_id` that it ever
/// used.
///
/// A worker's vault uses `create`: the hub's confirmed job gives the input, the vault makes the password itself, and
/// the record is bound to that job's generation, agent, task, project and input. `add` takes a value from outside the
/// vault, and no new submission starts while another one is open. It was the owner's writer's, and it has no caller
/// now: the owner's Add secret seals each value into the hub's central vault. Its tests still prove the journal rules
/// that `create` shares.
public actor VaultWriter {
    /// The limits of one save: a name of 1 to 500 characters and a value of at most 25000.
    static let maxName = 500, maxValue = 25_000
    /// No record is ever dropped, so the journal has a size limit. A new submission that does not fit is refused
    /// before any create call; the reserve keeps room for the later states of the records that are in it.
    static let maxJournalBytes = 4_194_304, reserve = 256

    private let store: any VaultJournalStore
    private let limit: Int
    private let session: @Sendable () throws -> (items: any VaultItems, project: String)
    private let clock: @Sendable () -> Double
    private var records: [VaultWriteRecord]

    /// `session`: opens the store and gives its calls and its place. It throws `setup` when the store does not open;
    /// any other failure counts as a refusal of the store.
    init(store: any VaultJournalStore, limit: Int = VaultWriter.maxJournalBytes,
         clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
         session: @escaping @Sendable () throws -> (items: any VaultItems, project: String)) throws {
        self.store = store; self.limit = limit; self.clock = clock; self.session = session
        do {
            var loaded = try Self.read(store, limit: limit)
            // A record that is still `creating` is from a process that ended during its create call.
            if loaded.contains(where: { $0.state == .creating }) {
                let time = clock()
                loaded = loaded.map { old in
                    guard old.state == .creating else { return old }
                    var record = old; record.state = .unknown; record.updated_at = time
                    return record
                }
                try Self.save(loaded, to: store, limit: limit)
            }
            records = loaded
        } catch { throw VaultWriteRefusal.journal }
    }

    /// A writer with its journal in a file (`VaultJournalFile`), for the tests of the journal.
    init(journal: URL, limit: Int = VaultWriter.maxJournalBytes, clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
         session: @escaping @Sendable () throws -> (items: any VaultItems, project: String)) throws {
        try self.init(store: VaultJournalFile(journal), limit: limit, clock: clock, session: session)
    }

    /// The mark in the note of an item of `add`: the item can be found again without its value. A worker's save has
    /// its own mark, which its record keeps.
    static func mark(_ requestID: String) -> String { "fleet-add:" + requestID }

    static func canonical(_ requestID: String) -> String? { UUID(uuidString: requestID)?.uuidString.lowercased() }

    /// The submissions that are not finished: open ones, and items that Fleet has not registered yet.
    public func pending() -> [VaultWriteRecord] { records.filter { $0.isOpen || $0.state == .created } }

    /// One submission. A `request_id` that has a record gets that record back and never a second create call.
    /// `hub` and `db`: where Fleet registers the login afterwards; the record keeps them, and the writer does not use them.
    public func add(requestID: String, label: String, hub: String, db: String, value: Data) throws -> VaultWriteRecord {
        guard let id = Self.canonical(requestID) else { throw VaultWriteRefusal.request }
        if let known = records.first(where: { $0.request_id == id }) { return known }
        guard let address = URLComponents(string: hub), ["https", "http"].contains(address.scheme ?? ""), address.host?.isEmpty == false,
              hub.utf8.count <= 512, db.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$", options: .regularExpression) != nil else {
            throw VaultWriteRefusal.request
        }
        guard !records.contains(where: \.isOpen) else { throw VaultWriteRefusal.unresolved }
        return try send(id: id, title: label, hub: hub, db: db, binding: nil, mark: nil, value: value, reached: nil)
    }

    /// A save for a confirmed job of an agent on this machine. The `request_id` is the identity of the save: the same
    /// one again is a retry and gets the first record, and another one is another save. `binding`: the hash of what
    /// the hub confirmed for the job (its generation, agent, task, attempt, project and input). A record with this
    /// `request_id` and another binding is a changed request: it is refused. `mark`: the note of the item, in the
    /// form of a worker's save (`fleet-create:<agent>:<request_id>`). `value` runs only when a create call is really
    /// sent, so a retry makes no new password. An unknown outcome is looked for by its mark and never sent again.
    public func create(requestID: String, binding: String, title: String, hub: String, db: String, mark: String,
                       value: () throws -> Data) throws -> VaultWriteRecord {
        guard let id = Self.canonical(requestID), binding.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              mark.range(of: "^fleet-create:[a-z][a-z0-9-]{1,30}:" + id + "$", options: .regularExpression) != nil else {
            throw VaultWriteRefusal.request
        }
        if let index = records.firstIndex(where: { $0.request_id == id }) {
            guard records[index].binding == binding else { throw VaultWriteRefusal.changed }
            return records[index].state == .unknown ? try check(requestID: id) : records[index]
        }
        guard let address = URLComponents(string: hub), ["https", "http"].contains(address.scheme ?? ""), address.host?.isEmpty == false,
              hub.utf8.count <= 512, db.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$", options: .regularExpression) != nil else {
            throw VaultWriteRefusal.request
        }
        // The store opens before the password is made: a machine without its store makes nothing.
        let reached = try reach()
        return try send(id: id, title: title, hub: hub, db: db, binding: binding, mark: mark, value: try value(), reached: reached)
    }

    /// The record of a request, when the journal has one. A capture asks before it reads a page: a known request
    /// never reads again.
    public func record(requestID: String) -> VaultWriteRecord? {
        guard let id = Self.canonical(requestID) else { return nil }
        return records.first { $0.request_id == id }
    }

    /// True when this vault made this login for this request: its own journal has the request with this binding and
    /// this reference. The hub's word that an agent's job made a login is not enough to use it.
    public func made(requestID: String, binding: String, login: String) -> Bool {
        guard let id = Self.canonical(requestID) else { return false }
        return records.contains {
            $0.request_id == id && $0.binding == binding && $0.login == login.lowercased() && ($0.state == .created || $0.state == .registered)
        }
    }

    /// The one create call of a new submission, with its record kept first.
    private func send(id: String, title label: String, hub: String, db: String, binding: String?, mark: String?, value: Data,
                      reached: (any VaultItems, String, String)?) throws -> VaultWriteRecord {
        let title = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...Self.maxName).contains(title.unicodeScalars.count), Self.isAddable(value, label: title),
              let text = String(data: value, encoding: .utf8) else { throw VaultWriteRefusal.login }
        guard text.unicodeScalars.count <= Self.maxValue else { throw VaultWriteRefusal.tooLong }
        // The store opens first: a failure here made nothing and leaves no record.
        let (items, project, organization) = try reached ?? reach()
        let time = clock()
        var record = VaultWriteRecord(request_id: id, title: title, hub: hub, db: db, state: .creating, login: nil, started_at: time,
                                      updated_at: time, binding: binding, mark: mark)
        // Kept before the call. A journal without room for a new record refuses here, and nothing is sent.
        do { try Self.save(records + [record], to: store, limit: limit - Self.reserve) } catch { throw VaultWriteRefusal.journal }
        switch items.create(name: title, value: text, note: mark ?? Self.mark(id), project: project, organization: organization) {
        case .created(let item): record.state = .created; record.login = "bws://" + item.lowercased()
        case .refused: record.state = .failed
        case .unknown: record.state = .unknown
        }
        record.updated_at = clock()
        records.append(record)
        // A record that stays `creating` in the journal becomes `unknown` at the next start, and a check then finds its item.
        try? Self.save(records, to: store, limit: limit)
        return record
    }

    /// A value that the vaults read: a login, also an API key with an empty user name and its service's address, or an
    /// API key without an address (owner feature secrets), which a session only reads.
    static func isAddable(_ value: Data, label: String) -> Bool {
        if (try? VaultLogin(data: value, label: label)) != nil { return true }
        guard let object = try? JSONSerialization.jsonObject(with: value) as? [String: Any], (try? VaultSecret(data: value)) != nil,
              Set(object.keys).isSubset(of: ["username", "password"]) else { return false }
        return (object["username"] as? String ?? "") == "" && (object["username"] == nil || object["username"] is String)
    }

    /// Reconciles a submission with an unknown outcome: it looks for the item with the mark and makes nothing. An
    /// item that is not found leaves the record `unknown`, because the first call can still arrive.
    public func check(requestID: String) throws -> VaultWriteRecord {
        let index = try index(of: requestID)
        guard records[index].state == .unknown else { return records[index] }
        let (items, project, organization) = try reach()
        let found: String?
        do {
            let ids = try items.items(named: records[index].title, project: project, organization: organization)
            let notes = ids.isEmpty ? [:] : try items.notes(of: ids)
            let mark = records[index].mark ?? Self.mark(records[index].request_id)
            found = ids.sorted().first { notes[$0] == mark }
        } catch { throw VaultWriteRefusal.check }
        records[index].updated_at = clock()
        if let found { records[index].state = .created; records[index].login = "bws://" + found.lowercased() }
        try? Self.save(records, to: store, limit: limit)      // without it, the next check finds the same item again
        return records[index]
    }

    /// Ends a submission. `registered`: Fleet made its hub steps for a `created` item. Else it is the owner's decision
    /// to discard: an `unknown` submission, or a made item that Fleet does not register (its reference stays in the
    /// record). The record stays: a finished submission never gets a create call again.
    public func close(requestID: String, registered: Bool) throws -> VaultWriteRecord {
        let index = try index(of: requestID)
        var record = records[index]
        switch (record.state, registered) {
        case (.created, true): record.state = .registered
        case (.created, false), (.unknown, false): record.state = .discarded
        case (.registered, true), (.discarded, false), (.failed, false): return record
        default: throw VaultWriteRefusal.state
        }
        record.updated_at = clock()
        var next = records; next[index] = record
        do { try Self.save(next, to: store, limit: limit) } catch { throw VaultWriteRefusal.journal }
        records = next
        return record
    }

    /// The salted fingerprints of a made item's own values, for the hub's message filter. The writer reads its own
    /// item again, so this also works after a restart, when no value is in memory. The answer has no value.
    public func fingerprints(requestID: String, salts: [String: String]) throws -> (login: String, items: [VaultFingerprint]) {
        let record = records[try index(of: requestID)]
        guard record.state == .created, let login = record.login, Set(salts.keys) == ["password", "totp"],
              salts.values.allSatisfy({ $0.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil }) else {
            throw VaultWriteRefusal.state
        }
        let (items, _, _) = try reach()
        guard let item = try? items.secret(id: String(login.dropFirst(6))) else { throw VaultWriteRefusal.check }
        let prints = VaultHub.fingerprints(item, salts: salts).compactMap { one -> VaultFingerprint? in
            guard let kind = one["kind"] as? String, let hash = one["hash"] as? String, let len = one["len"] as? Int else { return nil }
            return VaultFingerprint(kind: kind, hash: hash, len: len)
        }
        return (login, prints)
    }

    private func index(of requestID: String) throws -> Int {
        guard let id = Self.canonical(requestID), let index = records.firstIndex(where: { $0.request_id == id }) else {
            throw VaultWriteRefusal.request
        }
        return index
    }

    private func reach() throws -> (any VaultItems, String, String) {
        let reached: (items: any VaultItems, project: String)
        do { reached = try session() } catch VaultWriteRefusal.setup { throw VaultWriteRefusal.setup } catch { throw VaultWriteRefusal.provider }
        guard let organization = try? reached.items.organization(ofProject: reached.project) else { throw VaultWriteRefusal.provider }
        return (reached.items, reached.project, organization)
    }

    // MARK: the journal

    /// A journal that cannot be read stops the writer: it can hold a submission with an unknown outcome.
    private static func read(_ store: any VaultJournalStore, limit: Int) throws -> [VaultWriteRecord] {
        guard let data = try store.load(limit: limit) else { return [] }
        guard data.count <= limit, let records = try? JSONDecoder().decode([VaultWriteRecord].self, from: data),
              Set(records.map(\.request_id)).count == records.count,
              records.allSatisfy({ canonical($0.request_id) == $0.request_id }) else { throw VaultWriteRefusal.journal }
        return records
    }

    private static func save(_ records: [VaultWriteRecord], to store: any VaultJournalStore, limit: Int) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(records)
        guard data.count <= limit else { throw VaultWriteRefusal.journal }
        try store.save(data)
    }
}
