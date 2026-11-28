#if os(macOS)
import Foundation

/// This start of the app, in each record that it writes (`KeptRecords`).
public enum AppLaunch {
    public static let id = UUID().uuidString
}

/// **A record of work that this Mac did, which must outlive the page that did it** (an install, `InstallRecord`; a
/// server made at a provider, `BuildRecord`). The start of the app that wrote it is in it, so that a later start reads
/// work that was cut off as that, and never as work that runs.
public protocol KeptRecord: Codable, Equatable, Sendable, Identifiable where ID == UUID {
    /// The start of the app that wrote this record (`AppLaunch.id`).
    var launch: String { get }
    var began: Date { get }
    /// The record says that its work runs.
    var runs: Bool { get }
    /// The same record as a later start of the app reads it when it says that its work runs: cut off.
    func cutOff() -> Self
    /// Posted on `NotificationCenter.default` after a write that changed a record of this kind.
    static var changed: Notification.Name { get }
    /// A record that stays past the store's limit (`KeptRecords.write`).
    var keepsAlways: Bool { get }
}

public extension KeptRecord {
    var keepsAlways: Bool { false }
}

/// Where the app keeps its records: a folder of its own in `Application Support/Founderizer`.
enum KeptRecordsPlace {
    static func folder(_ name: String) -> URL {
        AppFolders.support
            .appendingPathComponent("Founderizer").appendingPathComponent(name)
    }
}

/// **The records of one kind, in a folder of the app**: one small file for each record, written whole at each change,
/// readable by its user only. A process writes the files of its own work's records, and closes a record of an earlier
/// start only where later work proved it (`noteJoined`); past the limit it removes the oldest files, whoever wrote
/// them. The folder is read one time; after that every read is from memory and opens no file, so the records are for
/// the app's own process. Safe from any thread.
///
/// **Work that was cut off never reads as work that runs**: every read gives a record that says `runs` and that another
/// start of the app wrote as `cutOff()` gives it, never as its file has it.
///
/// **A sign of change**: `changes` goes up at each write that changed a record, and each such write posts the record's
/// `changed`, so a reader in this app knows when to read again without a look at the folder.
///
/// **A record can have a mark beside it, an empty file `<id>.swept`** (`sweep`, F17's SP1): the record, its file and
/// every read of it stay as they are, so an older build of the app, which reads only `<id>.json`, has every record too;
/// only `unswept` leaves a marked record out.
public final class KeptRecords<Record: KeptRecord>: @unchecked Sendable {
    /// The largest file that is read as a record: a record is about 2 KiB.
    public static var largestFile: Int { 64 * 1024 }
    /// Posted on `NotificationCenter.default` after a write that changed a record of this kind, with this object.
    public static var changed: Notification.Name { Record.changed }

    private let folder: URL
    private let launch: String
    private let keeps: Int
    private let lock = NSLock()
    private var records: [UUID: Record]?
    private var counted = 0
    /// The records whose last write did not reach the disk: each write tries them again.
    private var unsaved: Set<UUID> = []
    /// The records with a mark beside them (`sweep`).
    private var marked: Set<UUID> = []

    /// `keeps`: the newest records that stay; an older one goes with its file at the next write.
    public init(folder: URL, launch: String = AppLaunch.id, keeps: Int = 40) {
        self.folder = folder
        self.launch = launch
        self.keeps = max(1, keeps)
    }

    /// How many writes changed a record since this object was made.
    public var changes: Int {
        lock.lock(); defer { lock.unlock() }
        return counted
    }

    /// Reads the folder, one time. Every read and every write does it when it is still to do; a caller that wants it
    /// off the main thread calls it there first.
    public func load() {
        lock.lock(); defer { lock.unlock() }
        _ = loaded()
    }

    /// Every record, newest first, each as this start of the app reads it.
    public func all() -> [Record] {
        lock.lock(); defer { lock.unlock() }
        return Self.sorted(loaded().values).map { $0.runs && $0.launch != launch ? $0.cutOff() : $0 }
    }

    /// The records of `all` with no mark beside them (`sweep`).
    public func unswept() -> [Record] {
        lock.lock(); defer { lock.unlock() }
        return Self.sorted(loaded().values.filter { !marked.contains($0.id) })
            .map { $0.runs && $0.launch != launch ? $0.cutOff() : $0 }
    }

    /// **These records get a mark beside them**: an empty file `<id>.swept`, and nothing else of a record changes, so
    /// it counts and says no change. A record whose mark does not reach the disk stays in `unswept`.
    public func sweep(_ ids: Set<UUID>) {
        lock.lock(); defer { lock.unlock() }
        let all = loaded()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        for id in ids where all[id] != nil && !marked.contains(id) {
            guard (try? Data().write(to: mark(id), options: .atomic)) != nil else { continue }
            marked.insert(id)
        }
    }

    /// Keeps the record as it is now. A record that did not change writes nothing and counts nothing. Every record
    /// whose last write did not reach the disk is written again at each call, also at one that changes nothing; a
    /// write counts only when it changed a record.
    public func write(_ record: Record) {
        lock.lock()
        var all = loaded()
        let changed = all[record.id] != record
        guard changed || !unsaved.isEmpty else { lock.unlock(); return }
        all[record.id] = record
        // The oldest go, with their files; never one that this start of the app still runs, and never one that stays.
        let extra = Self.sorted(all.values).dropFirst(keeps).filter { !($0.runs && $0.launch == launch) && !$0.keepsAlways }
        for old in extra where old.id != record.id {
            all[old.id] = nil
            removeFiles(old.id)
        }
        records = all
        if changed { counted += 1; unsaved.insert(record.id) }
        // The last write of a record (its end) has no next write of its own: each write, also one that changes
        // nothing, tries every record that still waits for the disk.
        for id in Array(unsaved) {
            if let waits = all[id] { if save(waits) { unsaved.remove(id) } } else { unsaved.remove(id) }
        }
        lock.unlock()
        if changed { NotificationCenter.default.post(name: Record.changed, object: self) }
    }

    /// **Takes records away, with their files**: the ones for which `matches` is true, as this start of the app
    /// reads them. For a fleet that the app forgets ("Start again"). It counts and says one change when a record went.
    public func remove(where matches: (Record) -> Bool) {
        lock.lock()
        var all = loaded()
        let gone = all.values.filter { matches($0.runs && $0.launch != launch ? $0.cutOff() : $0) }
        for record in gone {
            all[record.id] = nil
            unsaved.remove(record.id)
            removeFiles(record.id)
        }
        records = all
        if !gone.isEmpty { counted += 1 }
        lock.unlock()
        if !gone.isEmpty { NotificationCenter.default.post(name: Record.changed, object: self) }
    }

    private static func sorted(_ records: some Collection<Record>) -> [Record] {
        records.sorted { $0.began != $1.began ? $0.began > $1.began : $0.id.uuidString < $1.id.uuidString }
    }

    private func file(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString.lowercased()).json") }

    /// The mark beside a record (`sweep`).
    private func mark(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString.lowercased()).swept") }

    /// With the lock held: the record's file goes, and its mark.
    private func removeFiles(_ id: UUID) {
        for place in [file(id), mark(id)] { try? FileManager.default.removeItem(at: place) }
        marked.remove(id)
    }

    /// With the lock held: the records of the folder, read at the first call. A file that is no record of this
    /// version, that is larger than a record can be, or that is no regular file (`bytes`), is passed over and stays.
    private func loaded() -> [UUID: Record] {
        if let records { return records }
        var found: [UUID: Record] = [:]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasSuffix(".json") {
            // No folder: with no such word the URL's own maker may look at the file by its name, through a link.
            guard let data = Self.bytes(of: folder.appendingPathComponent(name, isDirectory: false)),
                  let record = try? keptDecoder().decode(Record.self, from: data),
                  name == "\(record.id.uuidString.lowercased()).json" else { continue }
            found[record.id] = record
        }
        // The marks: by their names alone, of a record that the folder holds. A mark is an empty file.
        let ids = Set(found.keys.map { $0.uuidString.lowercased() })
        marked = Set(names.compactMap { name -> UUID? in
            guard name.hasSuffix(".swept"), ids.contains(String(name.dropLast(6))) else { return nil }
            return UUID(uuidString: String(name.dropLast(6)))
        })
        records = found
        return found
    }

    /// **A file's bytes, only when it is a regular file of at most `largestFile` bytes**; else nil.
    ///
    /// The read is `KeptFile`'s, with no step through a link: the file is opened with no wait, and then the opened
    /// file itself is asked what it is. So a named pipe, a device, a folder or a link in a record's place is passed
    /// over, and at most one byte more than a record can have is read.
    /// Before, the file's size was read by its name and the file was then read whole, by the system's own reader:
    ///
    /// - **A link** passed the size check with its own few bytes and was then read through, whatever it led to
    ///   (measured on 16 November 2026: a record behind a link was read).
    /// - **A named pipe** says size 0, and what its read does was the system's to decide. macOS 27 refuses it at
    ///   once (measured the same day). A system whose reader waits for the pipe's writer would hold the folder's one
    ///   read for ever, and with it each reader that waits for that read: every request of the owner's own agent
    ///   (`SetupChannel`, which reads the folders beside the app's start), and the app's main thread at its first own
    ///   use of a record. The app runs from macOS 15 on, which was not measured; a reviewer read in the public source
    ///   of Foundation that its reader opened a file with a wait before its version 6.2 (not measured either). So
    ///   the rule is the app's own now, and no system's.
    ///
    /// Only a program of this Mac's own user can put such a file there.
    static func bytes(of file: URL) -> Data? {
        KeptFile.bytes(of: file, atMost: largestFile, followsLinks: false)
    }

    /// With the lock held: the record's file, whole, for its user only. False when it did not reach the disk.
    private func save(_ record: Record) -> Bool {
        guard let data = try? keptEncoder().encode(record) else { return false }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let file = file(record.id)
        guard (try? data.write(to: file, options: .atomic)) != nil else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return true
    }
}

/// A record's file: its dates as whole milliseconds, its keys in order.
private func keptEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}

private func keptDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return decoder
}
#endif
