import Darwin
import Foundation

/// What the broker's own operations ask of the store (`vault.py`'s `opened_store`): one login, one value, and which
/// logins of a probe job it can open.
/// One store is opened for one request and used by that request alone — the broker serves one job at a time — so a
/// store crosses a task boundary (`request` reads its login inside the call) and is `Sendable` by that use.
protocol VaultStore: Sendable {
    func login(secretID: String) throws -> VaultLogin
    func secret(id: String) throws -> VaultSecret
    func probe(job: VaultProbeJob) -> [VaultProbeResult]
}

/// The fleet's own store on a Mac: the owner's logins and keys in one `age` file of this helper, with no account, no
/// organization and no network. It is the only store of this vault. It is the Mac half of `vault.py`'s `LocalStore`,
/// with the same format and the same surface, so `read`, `signin`, `handover`, `probe` and `create` work against it.
///
/// The file holds `{"v": 1, "items": {id: {key, value, note, made_at}}}` — an item of the shape that the rest of the
/// helper already reads — encrypted to the public half of the store key with the bundled `age`, and opened with that
/// key. Values travel to `age` on a pipe, never in an argument, the environment or a file, and a locked store that
/// still holds a value in plain is not written.
///
/// **The key, and why the file itself may be readable.** On a worker Mac the agents run as the vault's own user, so
/// file permissions keep nothing from them: what keeps the store shut is that its key is one item of this helper's
/// Keychain group, which the OS gives only to code that satisfies the helper's own signature. The ciphertext alone
/// opens nothing. The store key is not the handover key, on purpose: rotating a handover key must not leave every
/// saved value unreadable.
///
/// The store is read again for every request, so a replaced file counts at once, and a save takes the store's lock,
/// because the broker and the helper's own `store-put` each write this one file.
final class VaultLocalStore: VaultItems, VaultStore, @unchecked Sendable {
    /// The format of the store, as `vault.py`'s `STORE`.
    static let version = 1
    /// Where an item of this store is: it holds one place and names no project (`vault.py`'s `LOCAL`).
    static let place = "local"
    /// The most bytes of the opened store and of the locked one. It is the limit of the bundled programs' answers, so
    /// a store that outgrows it could not be opened; the writer's journal has the same one.
    static let limit = 1_048_576
    /// The Keychain item that holds the store key: one age identity, made at the first use and never shown.
    static let keyItem = "store"
    static let armour = "-----BEGIN AGE ENCRYPTED FILE-----"
    /// The note of an item that a delivery saved (`deposit`): only an item with it is removed (`withdraw`), as
    /// `vault.py`'s `DELIVERED`.
    static let delivered = "delivered from the owner's vault"

    /// This helper's store file. One path, because a configuration names one agent and one store, so two stores never
    /// meet in one home.
    static var file: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Fleet Vault/store.age")
    }

    private let file: URL
    private let programs: VaultPrograms
    private let identity: Data
    private let recipient: String

    /// Opens this machine's store, and makes its key and an empty store when there is none. A store that does not
    /// open throws here, before a one-use job of the hub is spent.
    convenience init(keychain: VaultKeychain, programs: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers"),
                     file: URL = VaultLocalStore.file) throws {
        try self.init(identity: Self.key(keychain: keychain, programs: VaultPrograms(directory: programs)),
                      programs: programs, file: file)
    }

    /// The store of one key. The vault takes that key from its Keychain group, so it never leaves the helper; a test
    /// gives a key of its own and needs no Keychain.
    init(identity: Data, programs: URL, file: URL) throws {
        self.file = file
        self.programs = VaultPrograms(directory: programs)
        self.identity = identity
        recipient = (try? VaultIdentity.recipient(identity)) ?? ""
        guard !recipient.isEmpty else { throw VaultFailure.store }
        if try read() == nil { try empty() }
        _ = try opened()
    }

    /// The store key, made once. A key that is there is kept: a new one would leave every saved value unreadable. So
    /// only "item not found" makes one, never another answer of the Keychain, and a new key is only added, never saved
    /// in the place of one (package 7).
    private static func key(keychain: VaultKeychain, programs: VaultPrograms) throws -> Data {
        if let kept = try keychain.readIfPresent(keyItem) { return kept }
        guard let made = try? programs.run("age-keygen", arguments: []), (try? VaultIdentity.recipient(made)) != nil else {
            throw VaultFailure.store
        }
        try keychain.create(made, item: keyItem)
        return try keychain.read(keyItem)
    }

    /// The public half of the store key. It is not the handover key that `status` answers, and it opens nothing.
    var storeRecipient: String { recipient }

    // MARK: reading

    /// The store's items, inside this helper only.
    func opened() throws -> [String: Item] {
        guard let text = try read() else { throw VaultFailure.store }
        guard let armour = String(data: text, encoding: .utf8), armour.hasPrefix(Self.armour) else { throw VaultFailure.store }
        guard let plain = try? programs.run("age", arguments: ["--decrypt", "--identity", "/dev/fd/3"], input: text, identity: identity),
              plain.count <= Self.limit, let object = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
              VaultRequest.integer(object["v"]) == Self.version, let items = object["items"] as? [String: Any] else {
            throw VaultFailure.store
        }
        var found: [String: Item] = [:]
        for (id, value) in items {
            guard Self.canonical(id) == id, let item = Item(id: id, value) else { throw VaultFailure.store }
            found[id] = item
        }
        return found
    }

    /// One item of the store: its id, its name and its value.
    func item(id: String) throws -> Item {
        guard let id = Self.canonical(id) else { throw VaultFailure.storeMissing }
        guard let found = try opened()[id] else { throw VaultFailure.storeMissing }
        return found
    }

    /// The login of one reference, for `signin`, `handover` and `request`.
    func login(secretID: String) throws -> VaultLogin {
        let found = try item(id: secretID)
        return try VaultLogin(data: Data(found.value.utf8), label: found.key)
    }

    /// Which logins of a probe job this store can open, in the fixed codes of a probe: no part of a login leaves the
    /// helper.
    func probe(job: VaultProbeJob) -> [VaultProbeResult] {
        let items: [String: Item]
        do { items = try opened() } catch { return job.logins.map { VaultProbeResult(login: $0, reason: .error) } }
        return job.logins.map { login in
            guard let found = Self.canonical(String(login.dropFirst(6))).flatMap({ items[$0] }) else {
                return VaultProbeResult(login: login, reason: .not_found)
            }
            return VaultProbeResult.inspect(login: login, value: Data(found.value.utf8))
        }
    }

    /// The references, names and dates of this store, for the owner. Never a value.
    func listing() throws -> [(login: String, title: String, savedAt: Double)] {
        try opened().values.sorted { $0.made_at < $1.made_at }.map { ("bws://" + $0.id, $0.key, $0.made_at) }
    }

    // MARK: writing

    /// Saves one item and gives its id. The store is read and written under its lock.
    func add(name: String, value: String, note: String) throws -> String {
        guard Self.isPlainLine(name, 200), Self.isPlainLine(note, 200) || note.isEmpty else { throw VaultFailure.store }
        let lock = try locked()
        defer { Darwin.close(lock) }
        var items = try opened()
        var id = UUID().uuidString.lowercased()
        while items[id] != nil { id = UUID().uuidString.lowercased() }
        items[id] = Item(id: id, key: name, value: value, note: note, made_at: Date().timeIntervalSince1970)
        try keep(items)
        return id
    }

    /// Saves one item under the id that it has in the owner's vault (a delivery, `deposit`): "new", or "same" when the
    /// store holds that value under that id already. Another value under that id is refused, because one reference
    /// names one value in every vault of the fleet: a delivery never changes what a name already means here
    /// (`vault.py`'s `put`).
    ///
    /// `replace`: the owner replaced the value of this reference (the central vault's signed replace, and the hub's
    /// word with a delivery of it). Then another value goes into the place of the stored one, "replaced", but only
    /// over an item with this same note: a delivery replaces what a delivery saved, never a login that this vault made
    /// or that the owner saved here himself. The store is one file that is written whole and then takes the place of
    /// the old one (`keep`), so a replace that fails leaves the old value whole.
    func put(id: String, name: String, value: String, note: String, replace: Bool = false) throws -> String {
        guard let id = Self.canonical(id), Self.isPlainLine(name, 200), Self.isPlainLine(note, 200) || note.isEmpty else {
            throw VaultFailure.store
        }
        let lock = try locked()
        defer { Darwin.close(lock) }
        var items = try opened()
        let held = items[id]
        if let held {
            if Self.same(held.value, value) { return "same" }
            guard replace else { throw VaultFailure.storeOther }
            guard held.note == note else { throw VaultFailure.storeNotDelivered }
        }
        items[id] = Item(id: id, key: name, value: value, note: note, made_at: Date().timeIntervalSince1970)
        try keep(items)
        return held == nil ? "new" : "replaced"
    }

    /// Removes the item with this id when its note is exactly `note` (`withdraw`): "removed", or "absent" when the store
    /// holds no such item. An item with another note is refused and stays: a login that the owner saved here himself,
    /// or that this vault made, never leaves by a withdrawal. The note is read and the item removed under the store's
    /// lock, so no save comes between them (`vault.py`'s `remove`).
    func remove(id: String, note: String) throws -> String {
        guard let id = Self.canonical(id) else { throw VaultFailure.store }
        let lock = try locked()
        defer { Darwin.close(lock) }
        var items = try opened()
        guard let held = items[id] else { return "absent" }
        guard held.note == note else { throw VaultFailure.withdrawNotDelivered }
        items[id] = nil
        try keep(items)
        return "removed"
    }

    /// Two values of an item that say the same thing: equal as JSON objects, or as text when either is no object.
    static func same(_ one: String, _ other: String) -> Bool {
        guard let first = try? JSONSerialization.jsonObject(with: Data(one.utf8)) as? NSDictionary,
              let second = try? JSONSerialization.jsonObject(with: Data(other.utf8)) as? NSDictionary else { return one == other }
        return first.isEqual(second)
    }

    /// An empty store, for a machine that has none. It is written under the lock, and only when there is no file:
    /// a store that is there is never replaced.
    private func empty() throws {
        let lock = try locked()
        defer { Darwin.close(lock) }
        guard try read() == nil else { return }
        try keep([:])
    }

    /// Locks the store and puts it in the place of the old one: a new file of mode 600, made complete beside it.
    private func keep(_ items: [String: Item]) throws {
        let object: [String: Any] = ["v": Self.version, "items": items.mapValues(\.stored)]
        guard let encoded = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              encoded.count <= Self.limit else { throw VaultFailure.store }
        guard let locked = try? programs.run("age", arguments: ["--armor", "--recipient", recipient], input: encoded),
              let armour = String(data: locked, encoding: .utf8), armour.hasPrefix(Self.armour) else { throw VaultFailure.store }
        // A store that is not locked is not written, as a copy that is not locked is not sent (`handover`).
        for item in items.values {
            for value in item.plainValues where armour.contains(value) { throw VaultFailure.store }
        }
        try write(locked)
    }

    // MARK: the file

    /// The locked store, or nil when this machine has none yet. A file that is not this user's own regular file, or
    /// that another user can write, is refused: this helper keeps its own store.
    private func read() throws -> Data? {
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            guard errno == ENOENT else { throw VaultFailure.store }
            return nil
        }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o022 == 0,
              info.st_size > 0, info.st_size <= Self.limit,
              let data = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() else { throw VaultFailure.store }
        return data
    }

    private func write(_ data: Data) throws {
        let folder = try self.folder()
        let temporary = folder.appendingPathComponent("." + file.lastPathComponent + "." + UUID().uuidString)
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw VaultFailure.store }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) == $0.count } && fsync(fd) == 0
        Darwin.close(fd)
        guard written, rename(temporary.path, file.path) == 0 else { unlink(temporary.path); throw VaultFailure.store }
        // The save stays also after a loss of power: the file's own sync does not keep its name.
        let directory = Darwin.open(folder.path, O_RDONLY | O_CLOEXEC)
        if directory >= 0 { fsync(directory); Darwin.close(directory) }
    }

    /// The store's lock, as a file descriptor: one writer at a time. Closing it gives the lock back.
    private func locked() throws -> Int32 {
        let folder = try self.folder()
        let fd = Darwin.open(folder.appendingPathComponent(file.lastPathComponent + ".lock").path,
                             O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw VaultFailure.store }
        guard flock(fd, LOCK_EX) == 0 else { Darwin.close(fd); throw VaultFailure.storeBusy }
        return fd
    }

    private func folder() throws -> URL {
        let folder = file.deletingLastPathComponent()
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])) != nil else { throw VaultFailure.store }
        return folder
    }

    // MARK: what a writer asks of a store (`VaultItems`)

    /// This store is one place, so it takes its own place and names no organization.
    func organization(ofProject project: String) throws -> String {
        guard project == Self.place else { throw VaultFailure.store }
        return Self.place
    }

    func items(named name: String, project: String, organization: String) throws -> [String] {
        try opened().filter { $0.value.key == name }.keys.sorted()
    }

    func notes(of ids: [String]) throws -> [String: String] {
        let items = try opened()
        return ids.reduce(into: [:]) { result, id in
            if let found = Self.canonical(id).flatMap({ items[$0] }) { result[id] = found.note }
        }
    }

    /// Exactly one save: `created`, or `refused` when nothing was made. The store is one file on this machine, which
    /// is made complete beside the old one and then takes its place, so a save that fails leaves the store as it was
    /// and no outcome is unknown.
    func create(name: String, value: String, note: String, project: String, organization: String) -> VaultCreateOutcome {
        guard project == Self.place, let id = try? add(name: name, value: value, note: note) else { return .refused }
        return .created(id)
    }

    /// The values of one item, read from the store again and not from memory.
    func secret(id: String) throws -> VaultSecret {
        try VaultSecret(data: Data(item(id: id).value.utf8))
    }

    // MARK: one item

    /// One item of the store. `value` is its text, a login or an API key; nothing here reads inside it.
    struct Item {
        let id: String
        let key: String
        let value: String
        let note: String
        let made_at: Double

        init(id: String, key: String, value: String, note: String, made_at: Double) {
            self.id = id; self.key = key; self.value = value; self.note = note; self.made_at = made_at
        }

        /// One item as the store holds it. Every field is required and of its own kind, as `vault.py` reads it.
        init?(id: String, _ raw: Any) {
            guard let object = raw as? [String: Any], Set(object.keys) == ["key", "value", "note", "made_at"],
                  let key = object["key"] as? String, VaultLocalStore.isPlainLine(key, 200),
                  let value = object["value"] as? String, let note = object["note"] as? String,
                  let made = object["made_at"] as? NSNumber, CFGetTypeID(made) != CFBooleanGetTypeID(),
                  made.doubleValue.isFinite else { return nil }
            self.init(id: id, key: key, value: value, note: note, made_at: made.doubleValue)
        }

        var stored: [String: Any] { ["key": key, "value": value, "note": note, "made_at": made_at] }

        /// The secret values inside this item, for the check that the locked store holds none of them in plain: the
        /// password and the seed of an item of ours, else the text itself. A value under 8 characters is left out,
        /// because such a text can stand in any file by chance (as a handover leaves it out).
        var plainValues: [String] {
            var found: [String] = []
            if let object = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] {
                found = ["password", "totp"].compactMap { object[$0] as? String }
            }
            return (found.isEmpty ? [value] : found).filter { $0.unicodeScalars.count >= 8 }
        }
    }

    /// The lower-case form of a UUID, or nil.
    static func canonical(_ id: String) -> String? {
        guard id.count == 36, let uuid = UUID(uuidString: id) else { return nil }
        return uuid.uuidString.lowercased()
    }

    /// One line of 1 to `most` characters with no space at either end and no control character, as `vault.py`'s
    /// `plain_line`: the name or the note of an item, never a value.
    static func isPlainLine(_ text: String, _ most: Int) -> Bool {
        guard (1...most).contains(text.unicodeScalars.count), text == text.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !text.unicodeScalars.contains { $0.value <= 0x1f || (0x7f...0x9f).contains($0.value) || $0.value == 0x2028 || $0.value == 0x2029 }
    }
}

/// The fleet's own store, as the helper's own window asks about it. Nothing here shows a value or the store key.
public enum VaultStoreSetup {
    /// Whether this machine's own store is open: its key is in the Keychain and the file reads.
    public static func isOpen(agent: String, bundle: Bundle = .main) -> Bool {
        store(agent: agent, bundle: bundle) != nil
    }

    /// Makes the handover key and an empty store, and keeps both when they are there. The broker does the same at
    /// its first request, so this is only for an owner who opens the window first.
    public static func open(agent: String, bundle: Bundle = .main) throws {
        let keychain = VaultKeychain(agent: agent), helpers = bundle.bundleURL.appendingPathComponent("Contents/Helpers")
        try VaultIdentity(keychain: keychain, programs: helpers).createIfMissing()
        _ = try VaultLocalStore(keychain: keychain, programs: helpers)
    }

    private static func store(agent: String, bundle: Bundle) -> VaultLocalStore? {
        try? VaultLocalStore(keychain: VaultKeychain(agent: agent),
                             programs: bundle.bundleURL.appendingPathComponent("Contents/Helpers"))
    }
}

/// The two commands of the fleet's own store on a Mac, as `vault.py`'s `store-put` and `store-list` are on Linux:
/// the owner saves one login or key, and reads the names that are in the store. The value comes on **standard
/// input**, so it never stands in an argument, and no answer repeats it.
///
/// Only the signed helper can open the store key, so only this program can write that store. On a Mac the agents of
/// the machine run as the vault's own user, which is the Mac vault's standing shape (an agent can run this program,
/// as it can ask the broker on its socket): so an agent of that machine can add an item and read the names of the
/// store, and it can read **no value** and no other machine's store. On Linux the vault user is its own user and an
/// agent is not it.
public enum VaultStoreCommand {
    /// `store-put`: one login or key of the owner's, and its reference comes back. Never a value.
    public static func put(title: String, note: String, item: Data, bundle: Bundle = .main) throws -> [String: Any] {
        let configuration = try VaultBroker.loadConfiguration()
        guard VaultLocalStore.isPlainLine(title, 60) else { throw VaultFailure.login }
        guard note.isEmpty || VaultLocalStore.isPlainLine(note, 200) else { throw VaultFailure.login }
        let value = try canonical(item, label: title)
        let store = try VaultLocalStore(keychain: VaultKeychain(agent: configuration.agent),
                                        programs: bundle.bundleURL.appendingPathComponent("Contents/Helpers"))
        let id = try store.add(name: title, value: value, note: note)
        return ["ok": true, "login": "bws://" + id, "title": title,
                "next": "register it with the hub: python3 fleet.py register bws://" + id]
    }

    /// `store-list`: the references, names and dates of this store. Never a value.
    public static func list(bundle: Bundle = .main) throws -> [[String: Any]] {
        let configuration = try VaultBroker.loadConfiguration()
        let store = try VaultLocalStore(keychain: VaultKeychain(agent: configuration.agent),
                                        programs: bundle.bundleURL.appendingPathComponent("Contents/Helpers"))
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        stamp.timeZone = TimeZone(identifier: "UTC")
        return try store.listing().map { ["login": $0.login, "title": $0.title,
                                          "saved_at": stamp.string(from: Date(timeIntervalSince1970: $0.savedAt))] }
    }

    /// The item as the store holds it: a login (`{username, password, url[, totp]}`) or a key that a session reads
    /// (`{password[, totp]}`), with its known fields only and nothing else of the text that came in. The text is read
    /// once and is in no answer.
    static func canonical(_ item: Data, label: String) throws -> String {
        guard item.count <= 65_536, let object = try? JSONSerialization.jsonObject(with: item) as? [String: Any],
              VaultWriter.isAddable(item, label: label) else { throw VaultFailure.login }
        var kept: [String: Any] = [:]
        for key in ["username", "password", "url", "totp"] where object[key] is String {
            kept[key] = object[key]
        }
        if object["url"] != nil { kept["username"] = object["username"] as? String ?? "" }
        guard let encoded = try? JSONSerialization.data(withJSONObject: kept, options: [.sortedKeys]),
              let text = String(data: encoded, encoding: .utf8) else { throw VaultFailure.login }
        return text
    }
}
