import Foundation

/// **The move of a Mac's keys to this build's key generation** (package 7, C23; the design note
/// `package-7-design.md` and the manager's two changes to it).
///
/// The four items of a Mac's store move from the newest lower generation that has one of them: copy, prove, mark, remove,
/// all under a lock of the vault's own folder, so that two processes never move at once.
/// - **Copy:** each item's bytes go under this build's service, and an item that the source lacks is not there either.
/// - **Prove:** each copy is read back and compared with its source, byte for byte. Equal bytes open what the old key
///   opens, and the handover key keeps its public half, so the hub's pinned key does not change. The proof never opens
///   the store file: that file belongs to the agents' user, who could damage it and so stop the move at each start.
/// - **Mark:** the marker is written under this build's service. From then on no lower generation is read again, so a
///   new key that an older build makes under its own name is never copied over the real one.
/// - **Remove:** the items of each lower generation go, with deletes that read no value.
///
/// Only "item not found" is no item. Each other answer of the Keychain, for example before the first unlock after a
/// restart, stops the move for this time: no copy, no marker and no new key. The vault then reads and writes no key of
/// its own generation (`VaultKeychain.ready`), and the next start or request goes on. A Mac with no item at all, a new
/// one, only gets the marker. Its keys are made under this build's service at their first use.
public enum VaultKeyMove {
    /// The store key, the handover key, the journal of made logins and the journal of requests.
    static let items = [VaultLocalStore.keyItem, "age", "writes", "calls"]
    /// The two keys among them: a move never deletes one or writes other bytes over one.
    static let keys: Set<String> = [VaultLocalStore.keyItem, "age"]
    /// Under this build's service, once the copies are proved.
    static let marker = "moved"

    private static let lock = NSLock()
    /// The agents whose move this process has seen done, so that each later use of a key costs nothing more.
    nonisolated(unsafe) private static var done: Set<String> = []

    /// Moves the keys of `agent` once in this process, or throws: until it is done, no item of `generation` is used.
    static func ensure(agent: String, backend: any VaultKeychainBackend, generation: Int) throws {
        try lock.withLock {
            if done.contains("\(generation)/\(agent)") { return }
            try move(agent: agent, backend: backend, generation: generation)
            done.insert("\(generation)/\(agent)")
        }
    }

    /// One move, as at a start, under the lock of the vault's folder: each worker process, `store-put` and `store-list`
    /// move under it, so two processes never move at once, and each reads the marker again inside it. A process that
    /// does not get the lock now moves nothing and uses no key this time. Each step goes on where an earlier start
    /// stopped, and none loses a key.
    static func move(agent: String, backend: any VaultKeychainBackend, generation: Int) throws {
        try locked(backend.lockFile) {
            let new = VaultKeychain(agent: agent, generation: generation, backend: backend, guarded: false)
            if try new.raw(marker) != nil {
                // Done before: what an older build wrote since then under its own name is never read, and it goes.
                removeLower(agent: agent, backend: backend, below: generation)
                return
            }
            var source: [String: Data]?
            for lower in stride(from: generation - 1, through: 1, by: -1) {
                let old = VaultKeychain(agent: agent, generation: lower, backend: backend, guarded: false)
                var found: [String: Data] = [:]
                for item in items { found[item] = try old.raw(item) }
                if !found.isEmpty { source = found; break }
            }
            guard let source else {
                // A new Mac: nothing to move, and so nothing to delete. The marker alone.
                try new.rawSave(Data("\(generation)\n".utf8), item: marker)
                return
            }
            var added: [String] = []        // the items that this process put there, and the only ones it takes back
            do {
                for item in items {
                    // A key of this generation is never deleted and never written over with other bytes, also by a
                    // second process that got past the lock: the move stops instead. Only a journal is updated.
                    let current = try new.raw(item), isKey = Self.keys.contains(item)
                    if let data = source[item] {
                        if current == data { continue }
                        if current == nil {
                            try new.rawCreate(data, item: item)
                            added.append(item)
                        } else {
                            guard !isKey else { throw VaultFailure.keyMoveStopped }
                            try new.rawSave(data, item: item)
                        }
                    } else if current != nil {
                        guard !isKey else { throw VaultFailure.keyMoveStopped }
                        try new.rawRemove(item)
                    }
                }
                for item in items {
                    guard try new.raw(item) == source[item] else { throw VaultFailure.keychain }
                }
            } catch {
                // A key is never taken back: a key that this move added has the source's bytes, which harm nothing
                // before the marker, and the next start finds them equal and goes on. Only a journal that it added
                // goes, and only when the Keychain says that the marker is not there: with the marker there, another
                // process finished this move, and after a failed read nobody knows. (`try?` would make a failed read
                // look like "not there", so the read is caught here.)
                let marked: Bool? = { do { return try new.raw(marker) != nil } catch { return nil } }()
                if marked == false {
                    for item in added where !Self.keys.contains(item) { try? new.rawRemove(item) }
                }
                throw error
            }
            try new.rawSave(Data("\(generation)\n".utf8), item: marker)
            removeLower(agent: agent, backend: backend, below: generation)
        }
    }

    /// Runs `body` while this process holds the lock of `file`, and throws when another process holds it now: a move
    /// does not wait, so a vault whose lock an agent holds only stops moving, which that agent can do in any case.
    static func locked(_ file: URL, _ body: () throws -> Void) throws {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(file.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw VaultFailure.keychain }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw VaultFailure.keychain }
        defer { flock(fd, LOCK_UN) }
        // The lock counts only while the open file is still the file at the path: one that an agent deleted or renamed
        // could be locked by another process at the same time.
        var opened = stat(), named = stat()
        guard fstat(fd, &opened) == 0, lstat(file.path, &named) == 0, opened.st_dev == named.st_dev,
              opened.st_ino == named.st_ino else { throw VaultFailure.keychain }
        try body()
    }

    /// Deletes the four items and the marker of each lower generation. A delete that fails is done again at the next
    /// start: after the marker, nothing of a lower generation is read.
    static func removeLower(agent: String, backend: any VaultKeychainBackend, below generation: Int) {
        for lower in 1..<max(generation, 1) {
            let old = VaultKeychain(agent: agent, generation: lower, backend: backend, guarded: false)
            for item in items + [marker] { try? old.rawRemove(item) }
        }
    }

    /// At the start of a worker's vault, before its socket takes a request: the move, when the Keychain answers now.
    /// A move that cannot be done now is done at the first use of a key, and until then no key is used.
    public static func atStart(agent: String) {
        try? ensure(agent: agent, backend: VaultSystemKeychain(), generation: VaultKeychain.generation)
    }

    /// For the tests: this process forgets the moves that it saw done.
    static func forget() { lock.withLock { done = [] } }
}
