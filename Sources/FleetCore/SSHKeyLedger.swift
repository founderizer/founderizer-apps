import Foundation

/// **The ledger of the accounts that the app reaches with its own SSH key** (the build spec of the app's SSH key,
/// "Ledger"): one row for each account, by its address, user and port, and what is true of it.
///
/// This build writes one state, `plain`: a run with the app's key file alone and `-F /dev/null` got in to that account
/// (`SSHRun.prove`). From then on each call to it is in app mode (`SSHCall.key`). A run of the gate that did not get in
/// is noted as a try (`tried`): the account keeps today's arguments, and the gate tries it again a day later; after
/// three that the server refused (`refused`), never again until the app puts its key there again. Later
/// steps write `added`, `proved`, `removed` and `gone`, and the row's hub and machine; any state counts as a run that
/// got in.
///
/// The file is `~/Library/Application Support/Founderizer/ssh/accounts.json`, of mode 600 in a folder of mode 700. Each
/// change holds `flock` on `accounts.lock` beside it, reads the file again under the lock, and renames a whole new file
/// in: two writers at once (two rounds of this app) lose no row, and a reader never reads half a file. A field of a row
/// that this build does not know is written back as it was.
///
/// Until a process opens it (`open`), the ledger has no file: each account keeps today's arguments, and nothing is
/// written. The app opens it at its start; a test makes one of its own in a folder of its own. Safe from any thread.
public final class SSHKeyLedger: @unchecked Sendable {
    /// The app's own ledger, which the app opens at its start.
    public static let shared = SSHKeyLedger()

    /// The folder of the app's ledger.
    public static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Founderizer").appendingPathComponent("ssh")
    }

    /// One account on one server: as whom, at which address and port the app logs in.
    public struct Account: Hashable, Sendable {
        public var address: String
        public var user: String
        public var port: Int

        public init(address: String, user: String, port: Int) {
            self.address = address.lowercased(); self.user = user; self.port = port
        }
    }

    /// What the ledger holds of one account.
    public struct Row: Equatable, Sendable {
        public var account: Account
        /// `plain` once a run with the app's key alone got in; nil while none did.
        public var state: String?
        /// When the state was written, in seconds since 1970.
        public var at: Double?
        /// The last run of the gate that did not get in, in seconds since 1970.
        public var tried: Double?
        /// The runs of the gate that the server refused (`SSHRun.refusedLogin`) since the app last put its key there.
        public var refused: Int = 0

        /// Whether the gate runs for this account now: no run got in yet, the server refused fewer than `refusals`, and
        /// no run of the gate was tried in the last day. A try in the future (a clock that went back) does not hold it.
        public func provable(now: Double) -> Bool {
            guard state == nil, refused < SSHKeyLedger.refusals else { return false }
            guard let tried else { return true }
            return now - tried >= SSHKeyLedger.again || now < tried
        }
    }

    /// The state that a run of the gate that got in writes.
    public static let plain = "plain"
    /// How long the gate waits after a try that did not get in: a day.
    public static let again: Double = 86_400
    /// The refused runs of the gate after which it runs no more, until the app puts its key there again.
    public static let refusals = 3

    private let lock = NSLock()
    private var place: URL?

    /// A ledger in `folder`, or with no file.
    public init(folder: URL? = nil) { place = folder }

    /// Gives the ledger its file: the app's own folder, or a test's.
    public func open(_ folder: URL = SSHKeyLedger.folder) { lock.withLock { place = folder } }

    public var isOpen: Bool { lock.withLock { place != nil } }

    private var file: URL? { lock.withLock { place?.appendingPathComponent("accounts.json") } }

    /// Every row, as the file holds it.
    public func rows() -> [Row] { entries().compactMap(Self.row) }

    /// The row of one account, or nil.
    public func row(_ account: Account) -> Row? { rows().first { $0.account == account } }

    /// Whether calls to this account are in app mode: a run with the app's key alone got in.
    public func confined(_ account: Account) -> Bool { row(account)?.state != nil }

    /// Whether the gate runs for this account now (`Row.provable`). A ledger with no file runs none.
    public func provable(_ account: Account, now: Double) -> Bool {
        guard isOpen else { return false }
        return row(account)?.provable(now: now) ?? true
    }

    /// A run with the app's key alone got in: the account is `plain`. A later state of a later step stays.
    @discardableResult
    public func recordPlain(_ account: Account, now: Double) -> Bool {
        change(account) { entry in
            guard entry["state"] as? String == nil else { return }
            entry["state"] = Self.plain
            entry["at"] = now
            entry["tried"] = nil
            entry["refused"] = nil
        }
    }

    /// A run of the gate did not get in: the account keeps today's arguments for a day. `refused`: the server refused
    /// the login, which counts (`refusals`).
    @discardableResult
    public func recordTried(_ account: Account, now: Double, refused: Bool = false) -> Bool {
        change(account) { entry in
            guard entry["state"] as? String == nil else { return }
            entry["tried"] = now
            if refused { entry["refused"] = ((entry["refused"] as? NSNumber)?.intValue ?? 0) + 1 }
        }
    }

    /// The app put its key in that account again (`PasswordOnce`): the gate's tries and refusals start again.
    @discardableResult
    public func recordAdded(_ account: Account) -> Bool {
        guard let row = row(account), row.state == nil, row.tried != nil || row.refused > 0 else { return false }
        return change(account) { entry in
            guard entry["state"] as? String == nil else { return }
            entry["tried"] = nil
            entry["refused"] = nil
        }
    }

    /// An app-mode run of a `plain` account was refused: it goes back to today's arguments, and the gate tries it again
    /// a day later. true only when it was `plain`; a later state belongs to its own step's rule.
    public func recordBack(_ account: Account, now: Double) -> Bool {
        guard row(account)?.state == Self.plain else { return false }
        var back = false
        let written = change(account) { entry in
            guard entry["state"] as? String == Self.plain else { return }
            entry["state"] = nil
            entry["at"] = nil
            entry["tried"] = now
            back = true
        }
        return written && back
    }

    // MARK: the file

    /// The rows of the file as they are written, with the fields that this build does not know.
    private func entries() -> [[String: Any]] {
        guard let file, let data = try? Data(contentsOf: file), data.count <= 4 << 20,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = object["accounts"] as? [[String: Any]] else { return [] }
        return accounts
    }

    static func row(_ entry: [String: Any]) -> Row? {
        guard let address = entry["address"] as? String, let user = entry["user"] as? String,
              let port = (entry["port"] as? NSNumber)?.intValue else { return nil }
        return Row(account: Account(address: address, user: user, port: port), state: entry["state"] as? String,
                   at: (entry["at"] as? NSNumber)?.doubleValue, tried: (entry["tried"] as? NSNumber)?.doubleValue,
                   refused: (entry["refused"] as? NSNumber)?.intValue ?? 0)
    }

    /// **One change of one account's row**, under the lock: the file read again, the row changed or made, and a new
    /// file of mode 600 renamed in. false when the ledger has no file or the change could not be written.
    private func change(_ account: Account, _ body: (inout [String: Any]) -> Void) -> Bool {
        guard let folder = lock.withLock({ place }) else { return false }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        if mkdir(folder.path, 0o700) != 0 && errno != EEXIST { return false }
        var status = stat()
        guard lstat(folder.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR, status.st_uid == getuid() else {
            return false
        }
        if status.st_mode & 0o777 != 0o700 { _ = chmod(folder.path, 0o700) }
        let held = Darwin.open(folder.appendingPathComponent("accounts.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard held >= 0 else { return false }
        defer { close(held) }
        guard flock(held, LOCK_EX) == 0 else { return false }
        defer { _ = flock(held, LOCK_UN) }
        var accounts = entries()
        let index = accounts.firstIndex { Self.row($0)?.account == account }
        var entry = index.map { accounts[$0] }
            ?? ["address": account.address, "user": account.user, "port": account.port]
        body(&entry)
        if let index { accounts[index] = entry } else { accounts.append(entry) }
        guard let data = try? JSONSerialization.data(withJSONObject: ["accounts": accounts],
                                                     options: [.prettyPrinted, .sortedKeys]) else { return false }
        let file = folder.appendingPathComponent("accounts.json")
        let temporary = folder.appendingPathComponent(".accounts-\(UUID().uuidString).json")
        let out = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard out >= 0 else { return false }
        let written = data.withUnsafeBytes { write(out, $0.baseAddress, $0.count) }
        let synced = fsync(out) == 0
        close(out)
        guard written == data.count, synced, rename(temporary.path, file.path) == 0 else {
            unlink(temporary.path)
            return false
        }
        return true
    }
}
