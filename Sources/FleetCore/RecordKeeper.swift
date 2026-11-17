import Foundation

/// What a round's read of a record file did to the file, when it did something that a person may want to know later.
public enum RecordFileEvent: Equatable, Sendable {
    /// The file gave no record at `RecordKeeper.mostUnread` round reads in a row: it is now at the name `aside`, beside
    /// it, and this Mac's copy took its place.
    case movedAside(file: String, aside: String)
    /// The same, and the move failed for `cause`: this Mac goes on with its copy, and the file stays as it is.
    case notMoved(file: String, cause: String)
}

/// **One small record of the app in one JSON file, read at each round and changed one change at a time**: the servers
/// that the owner removed on this Mac (`VaultRemovals`) and the key swap's records (`KeySwapState`). The app keeps one
/// keeper for each file, and the model of each hub address uses it, on the main actor.
///
/// A read finds no file, the file's record, or a file that gives no record: a file that `KeptFile` does not read (a
/// named pipe, a folder, a file that is too large, a read that failed) or whose bytes do not decode. A read can fail
/// for a moment, so that last case is never the record of a new Mac:
///
/// - **This Mac keeps its last good copy.** A read that gives no record changes nothing that the app knows.
/// - **A change is never written over a file that gave no record.** It goes into the copy and waits there, and so does
///   a change whose save failed. At the next good read each change that waits goes onto the file's record in its
///   order, and the record is written in one step. A change that changes nothing writes nothing.
/// - **No file is the record of a new Mac while the record is not known.** After a good read, no file means that the
///   file went away, because no code of the app removes it: this Mac's copy is written again.
/// - **Until a good read, the record is not known** (`known` is false), and the steps that it guards wait
///   (`VaultFacts.removedKnown` and `updateKnown`, `KeySwapFacts.removedKnown` and `recordsKnown`).
/// - **A file that gives no record at `mostUnread` round reads in a row goes to a new name beside it**,
///   `<name>.unread-<seconds>`, and this Mac's copy, with each change that waits, takes its place in one step. Nothing
///   is deleted. From then on the record is known, also when the move fails: this Mac then goes on with its copy, its
///   changes wait, and the move is tried again after each `mostUnread` more. After a move, the next one needs a good
///   read first, so a copy that cannot be read either is never moved again and again. Only `reread`, a round's read,
///   counts: the first read and a change's read do not. It is a count, never a time (the owner's rule of 26 October
///   2026: a wait ends on its own event or on a count).
public struct RecordKeeper<Record: Codable & Equatable> {
    /// The round reads in a row that give no record before the file goes to a new name. The vault's model reads at
    /// most once a minute when nothing wakes it, so that is about an hour then.
    public static var mostUnread: Int { 60 }

    public let file: URL
    private let empty: Record
    /// The record that the last good read gave, or the one this keeper wrote.
    private var base: Record
    /// The changes that are not in the file yet, in their order.
    private var waiting: [(inout Record) -> Void] = []
    /// **The record as this Mac knows it**: `base` with each change that waits.
    public private(set) var record: Record
    /// A read gave the file's record or found no file, this keeper wrote the file, or the file gave no record at
    /// `mostUnread` round reads in a row.
    public private(set) var known = false
    /// The round reads in a row that found a file and gave no record.
    public private(set) var unread = 0
    /// This keeper moved the file to a new name, and no read gave a record since.
    private var movedSinceGoodRead = false
    /// The move in two steps also on a volume that can swap two names: for a test of that way.
    var swapsNames = true

    /// The keeper of `file`, with its first read, which is no round's read. `empty` is the record of a new Mac.
    public init(file: URL, empty: Record) {
        self.file = file
        self.empty = empty
        base = empty
        record = empty
        settle(read(), round: false)
    }

    /// The changes that wait for the file.
    public var waits: Int { waiting.count }

    /// **A round's read of the file**, and what it did to the file when that is worth a line in the app's log.
    @discardableResult
    public mutating func reread() -> RecordFileEvent? {
        settle(read(), round: true)
    }

    /// **One change, made to the record as the file holds it now and written back at once.** When the file gives no
    /// record, or the save fails, the change goes into the copy and waits for a good read. A change whose value
    /// depends on the record (a step's answer onto the record of its server, a count of tries) computes that value
    /// inside the closure, from the record that it is made to.
    public mutating func change(_ change: @escaping (inout Record) -> Void) {
        waiting.append(change)
        settle(read(), round: false)
    }

    private enum Found {
        case none
        case record(Record)
        case unread
    }

    private func read() -> Found {
        switch KeptFile.read(file, atMost: KeptFile.largestRecord) {
        case .missing: return .none
        case .refused: return .unread
        case .bytes(let data):
            guard let record = try? JSONDecoder().decode(Record.self, from: data) else { return .unread }
            return .record(record)
        }
    }

    @discardableResult
    private mutating func settle(_ found: Found, round: Bool) -> RecordFileEvent? {
        var missing = false
        switch found {
        case .record(let read):
            base = read
        case .none:
            missing = true
            if !known { base = empty }
        case .unread:
            if round { unread += 1 }
            record = applied(to: base)
            guard round, unread % Self.mostUnread == 0 else { return nil }
            known = true
            if movedSinceGoodRead {
                return .notMoved(file: file.lastPathComponent, cause: "this Mac's copy at its name gave no record either")
            }
            switch replace(with: record) {
            case .moved(let aside):
                base = record
                waiting = []
                unread = 0
                movedSinceGoodRead = true
                return .movedAside(file: file.lastPathComponent, aside: aside)
            case .failed(let cause):
                return .notMoved(file: file.lastPathComponent, cause: cause)
            }
        }
        known = true
        unread = 0
        movedSinceGoodRead = false
        record = applied(to: base)
        // What the file's name holds now, as a record: when the copy is the same, there is nothing to write.
        if record == (missing ? empty : base) {
            base = record
            waiting = []
        } else if (try? save(record)) != nil {
            base = record
            waiting = []
        }
        return nil
    }

    private func applied(to record: Record) -> Record {
        var record = record
        for change in waiting { change(&record) }
        return record
    }

    private struct TooLarge: Error {}

    /// Writes `record` to the file in one step, so a stop in the middle leaves the record before or after. A record
    /// larger than a read takes (`KeptFile.largestRecord`) is not written: the file keeps its last record, which the
    /// next start reads, and the changes wait.
    private func save(_ record: Record) throws {
        let data = try JSONEncoder().encode(record)
        guard data.count <= KeptFile.largestRecord else { throw TooLarge() }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    private enum Moved {
        case moved(String)
        case failed(String)
    }

    /// **The file goes to a new name beside it, and `record` takes its place.** This Mac's copy is first written as a
    /// new file at the new name, and synced: a name that is there already is never written or removed, and a copy
    /// that is larger than `KeptFile.largestRecord`, which no read would take, is not written. Then the two names
    /// change places at once (`renamex_np` with `RENAME_SWAP`): the file's name holds this Mac's copy, and the new name
    /// holds what was at the file's name, whatever it is (a file, a folder, a named pipe, a link). A stop before the
    /// swap leaves the file as it was, and maybe the copy at the new name; a stop after it leaves the move done. A step
    /// that fails removes only the new file that this keeper made. A volume that cannot swap two names (`ENOTSUP`)
    /// gets the move in two steps (`moveInTwoSteps`).
    private func replace(with record: Record) -> Moved {
        guard let data = try? JSONEncoder().encode(record) else { return .failed("the record does not encode") }
        guard data.count <= KeptFile.largestRecord else { return .failed("this Mac's copy is larger than a read takes") }
        let name = "\(file.lastPathComponent).unread-\(Int(Date().timeIntervalSince1970))"
        let aside = file.deletingLastPathComponent().appendingPathComponent(name)
        var cause: Int32 = 0
        let made = aside.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else {
                cause = ENOENT
                return false
            }
            let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            guard descriptor >= 0 else {
                cause = errno
                return false
            }
            defer { Darwin.close(descriptor) }
            let written = data.withUnsafeBytes { bytes -> Bool in
                guard let start = bytes.baseAddress else { return true }
                var done = 0
                while done < bytes.count {
                    let count = Darwin.write(descriptor, start + done, bytes.count - done)
                    if count < 0 {
                        if errno == EINTR { continue }
                        cause = errno
                        return false
                    }
                    done += count
                }
                // On the disk before the names change places, so a stop of the power leaves no empty file there.
                if fcntl(descriptor, F_FULLFSYNC) != 0 && fsync(descriptor) != 0 {
                    cause = errno
                    return false
                }
                return true
            }
            if !written { Darwin.unlink(path) }          // the new file of this keeper, and no other
            return written
        }
        guard made else { return .failed(String(cString: strerror(cause))) }
        var swapped = false
        if swapsNames {
            swapped = aside.withUnsafeFileSystemRepresentation { from -> Bool in
                file.withUnsafeFileSystemRepresentation { to -> Bool in
                    guard let from, let to else {
                        cause = ENOENT
                        return false
                    }
                    if renamex_np(from, to, UInt32(RENAME_SWAP)) == 0 { return true }
                    cause = errno
                    return false
                }
            }
        } else {
            cause = ENOTSUP
        }
        if swapped { return .moved(name) }
        if cause == ENOTSUP {
            switch moveInTwoSteps(copy: aside) {
            case .moved(let old): return .moved(old)
            case .bothBeside(let why): return .failed(why)
            case .unchanged(let why): cause = why
            }
        }
        try? FileManager.default.removeItem(at: aside)       // the names did not change: it is this keeper's copy
        return .failed(String(cString: strerror(cause)))
    }

    private enum TwoSteps {
        case moved(String)
        /// Nothing changed at the file's name, for this cause.
        case unchanged(Int32)
        case bothBeside(String)
    }

    /// **The move on a volume that cannot swap two names.** First the thing at the file's name gets a second name, the
    /// copy's name with ".old" after it (`linkat`, which never writes over a name that is there); then the copy takes
    /// the file's name in one step (`rename`), so the name always holds the thing or the copy. Where a second name is
    /// not possible (a folder, a volume without them), the thing goes to that name and then the copy takes the file's
    /// name, in two steps, each refused over a name that is there (`RENAME_EXCL`, or a look first on a volume without
    /// it, so a name that another program makes between the look and the move can be written over); a stop between
    /// those two steps leaves no file at the name, so the next start reads the record of a new Mac. When the copy
    /// cannot take the name, the thing stays or goes back there; when it cannot go back, both stay beside the name and
    /// the copy is not removed.
    private func moveInTwoSteps(copy: URL) -> TwoSteps {
        let old = copy.deletingLastPathComponent().appendingPathComponent(copy.lastPathComponent + ".old")
        let linked = Self.posix(file, old) { linkat(AT_FDCWD, $0, AT_FDCWD, $1, 0) }
        if linked == 0 {
            let cause = Self.posix(copy, file) { Darwin.rename($0, $1) }
            if cause == 0 { return .moved(old.lastPathComponent) }
            // The second name that this keeper made goes, but only while the file's name still holds that same thing:
            // when another program put something else there, the second name is the last one of the thing, and stays.
            if Self.sameThing(file, old) { Darwin.unlink(old.path) }
            return .unchanged(cause)
        }
        if linked == EEXIST { return .unchanged(EEXIST) }
        let first = Self.renameExclusive(file, to: old)
        guard first == 0 else { return .unchanged(first) }
        let second = Self.renameExclusive(copy, to: file)
        if second == 0 { return .moved(old.lastPathComponent) }
        if Self.renameExclusive(old, to: file) == 0 { return .unchanged(second) }
        return .bothBeside("\(String(cString: strerror(second))); the file is at \(old.lastPathComponent) and this Mac's "
                           + "copy at \(copy.lastPathComponent)")
    }

    /// The two names name the same thing on the disk (its volume and its inode), with no link followed.
    private static func sameThing(_ one: URL, _ two: URL) -> Bool {
        var first = stat(), second = stat()
        return lstat(one.path, &first) == 0 && lstat(two.path, &second) == 0
            && first.st_dev == second.st_dev && first.st_ino == second.st_ino
    }

    /// One call of the system on two names, with its cause read in the same step: 0, or `errno`.
    private static func posix(_ first: URL, _ second: URL,
                              _ call: (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32) -> Int32 {
        first.withUnsafeFileSystemRepresentation { one in
            second.withUnsafeFileSystemRepresentation { two in
                guard let one, let two else { return ENOENT }
                return call(one, two) == 0 ? 0 : errno
            }
        }
    }

    /// `rename` that never writes over a name that is there: `RENAME_EXCL`, or on a volume without it a look first.
    private static func renameExclusive(_ from: URL, to: URL) -> Int32 {
        posix(from, to) { one, two in
            if renamex_np(one, two, UInt32(RENAME_EXCL)) == 0 { return 0 }
            guard errno == ENOTSUP || errno == EINVAL else { return -1 }
            var facts = stat()
            guard lstat(two, &facts) != 0, errno == ENOENT else {
                errno = EEXIST
                return -1
            }
            return Darwin.rename(one, two)
        }
    }
}
