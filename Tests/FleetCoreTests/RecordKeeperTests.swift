import Foundation
import Testing
@testable import FleetCore

/// The keeper of the app's small record files (`RecordKeeper`): a read that gives no record keeps the last good copy, a
/// change never goes over such a file and waits for a good read, the record is not known before the first good read,
/// a file that went away is written again, and a file that gives no record at sixty round reads in a row goes to a new
/// name in one step, with nothing deleted. Each file is in a folder of the test, never the app's own.
struct RecordKeeperTests {
    private let fleet = "0f1e2d3c4b5a6978"
    private let bad = Data("not json".utf8)
    private let most = RecordKeeper<VaultRemovals>.mostUnread

    /// A new folder of the test, which is not there yet, and the record's file in it.
    private func place(_ name: String = "vault-removals.json") -> (folder: URL, file: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("record-keeper-\(UUID().uuidString)")
        return (folder, folder.appendingPathComponent(name))
    }

    private func keeper(_ file: URL) -> RecordKeeper<VaultRemovals> {
        RecordKeeper(file: file, empty: VaultRemovals())
    }

    private func marks(_ record: VaultRemovals) -> Set<String> {
        Set(record.marks(fleet: fleet).keys)
    }

    private func names(_ folder: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
    }

    /// Puts a thing that is not read at the file's name: a folder, a named pipe, a file with no right to read, a file
    /// over the limit (with no data written, so the test writes no 16 MiB), a link to a named pipe beside it, or bytes
    /// that do not decode.
    private func putThing(_ kind: String, at file: URL) throws {
        switch kind {
        case "folder":
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        case "pipe":
            #expect(mkfifo(file.path, 0o600) == 0)
        case "no right":
            var record = VaultRemovals()
            record.removed("worker-3", fleet: fleet, at: 300, unpin: true)
            try record.save(file)
            #expect(chmod(file.path, 0) == 0)
        case "link":
            let target = file.deletingLastPathComponent().appendingPathComponent("target-pipe")
            #expect(mkfifo(target.path, 0o600) == 0)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        case "too large":
            #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: UInt64(KeptFile.largestRecord) + 1)
            try handle.close()
        default:
            try bad.write(to: file)
        }
    }

    @Test func noFileIsTheRecordOfANewMacAndAChangeIsWrittenAtOnce() throws {
        let (folder, file) = place()
        defer { try? FileManager.default.removeItem(at: folder) }
        var one = keeper(file)
        #expect(one.known && one.unread == 0 && one.record == VaultRemovals())
        one.change { $0.added("worker-9", fleet: fleet) }                  // it changes nothing: nothing is written
        #expect(!FileManager.default.fileExists(atPath: file.path) && one.waits == 0)
        one.change { $0.removed("worker-1", fleet: fleet, at: 100, unpin: true) }
        #expect(VaultRemovals.load(file) == one.record && one.waits == 0)
        // Another keeper of the same file: its change goes onto the file as it is now, so the first mark stays.
        var two = keeper(file)
        two.change { $0.removed("worker-2", fleet: fleet, at: 200, unpin: false) }
        one.reread()
        #expect(marks(one.record) == ["worker-1", "worker-2"])
        #expect(marks(VaultRemovals.load(file)) == ["worker-1", "worker-2"])
    }

    @Test func aReadThatGivesNoRecordKeepsTheCopyAndAChangeWaitsForAGoodRead() throws {
        let (folder, file) = place()
        defer { try? FileManager.default.removeItem(at: folder) }
        var one = keeper(file)
        one.change { $0.removed("worker-1", fleet: fleet, at: 100, unpin: true) }
        try bad.write(to: file)
        one.reread()
        #expect(one.known && one.unread == 1 && marks(one.record) == ["worker-1"])
        one.change { $0.removed("worker-2", fleet: fleet, at: 200, unpin: true) }
        // A change reads the file too, and its read does not count.
        #expect(marks(one.record) == ["worker-1", "worker-2"] && one.waits == 1 && one.unread == 1)
        #expect(try Data(contentsOf: file) == bad)                         // nothing went over the file
        // The file gives a record again, with a mark that this keeper did not make: the change goes onto it.
        var other = VaultRemovals()
        other.removed("worker-1", fleet: fleet, at: 100, unpin: true)
        other.removed("worker-3", fleet: fleet, at: 300, unpin: false)
        try other.save(file)
        one.reread()
        #expect(marks(one.record) == ["worker-1", "worker-2", "worker-3"] && one.waits == 0 && one.unread == 0)
        #expect(VaultRemovals.load(file) == one.record)
    }

    @Test(arguments: ["folder", "pipe", "no right", "too large", "link", "bad bytes"])
    func eachThingThatIsNotReadKeepsTheCopyAndStaysAsItWas(_ kind: String) throws {
        let (folder, file) = place()
        defer {
            if kind == "no right" { chmod(file.path, 0o600) }
            try? FileManager.default.removeItem(at: folder)
        }
        var one = keeper(file)
        one.change { $0.removed("worker-1", fleet: fleet, at: 100, unpin: true) }
        try FileManager.default.removeItem(at: file)
        try putThing(kind, at: file)
        let before = KeptFile.read(file, atMost: KeptFile.largestRecord)
        if case .bytes = before, kind != "bad bytes" { Issue.record("\(kind) is read") }
        one.reread()
        one.change { $0.removed("worker-2", fleet: fleet, at: 200, unpin: true) }
        #expect(marks(one.record) == ["worker-1", "worker-2"] && one.waits == 1 && one.unread == 1 && one.known)
        #expect(KeptFile.read(file, atMost: KeptFile.largestRecord) == before)
        #expect(try names(folder) == (kind == "link" ? ["vault-removals.json", "target-pipe"] : ["vault-removals.json"]))
    }

    @Test func beforeTheFirstGoodReadTheRecordIsNotKnown() throws {
        let (folder, file) = place()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try bad.write(to: file)
        var one = keeper(file)                                             // the first read is no round's read
        #expect(!one.known && one.unread == 0 && one.record == VaultRemovals())
        one.change { $0.removed("worker-2", fleet: fleet, at: 200, unpin: true) }
        #expect(!one.known && marks(one.record) == ["worker-2"] && one.waits == 1)
        #expect(try Data(contentsOf: file) == bad)
        var before = VaultRemovals()
        before.removed("worker-1", fleet: fleet, at: 100, unpin: false)
        try before.save(file)
        one.reread()
        #expect(one.known && one.waits == 0 && marks(one.record) == ["worker-1", "worker-2"])
        #expect(VaultRemovals.load(file) == one.record)
    }

    @Test func aFileThatWentAwayAfterAGoodReadIsWrittenAgainFromTheCopy() throws {
        let (folder, file) = place()
        defer { try? FileManager.default.removeItem(at: folder) }
        var one = keeper(file)
        one.change { $0.removed("worker-1", fleet: fleet, at: 100, unpin: true) }
        try FileManager.default.removeItem(at: file)
        one.reread()
        #expect(one.known && marks(one.record) == ["worker-1"] && marks(VaultRemovals.load(file)) == ["worker-1"])
        // A copy with no mark writes nothing when the file is not there.
        one.change { $0.added("worker-1", fleet: fleet) }
        try FileManager.default.removeItem(at: file)
        one.reread()
        #expect(one.record == VaultRemovals() && !FileManager.default.fileExists(atPath: file.path))
    }

    /// The sixtieth round read that gives no record moves the thing at the file's name to a new name beside it, in one
    /// step, and this Mac's copy takes its place: also before the first good read. The first read and a change do not
    /// count. A link goes as a link: the thing that it leads to stays where it is.
    @Test(arguments: ["folder", "pipe", "no right", "too large", "link", "bad bytes"])
    func aFileThatGivesNoRecordAtSixtyRoundReadsGoesToANewName(_ kind: String) throws {
        let (folder, file) = place()
        var aside: URL?
        defer {
            if kind == "no right", let aside { chmod(aside.path, 0o600) }
            try? FileManager.default.removeItem(at: folder)
        }
        #expect(most == 60)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try putThing(kind, at: file)
        let before = KeptFile.read(file, atMost: KeptFile.largestRecord)
        var one = keeper(file)
        #expect(!one.known && one.unread == 0)
        one.change { $0.removed("worker-2", fleet: fleet, at: 200, unpin: true) }
        for _ in 1..<most { #expect(one.reread() == nil) }
        #expect(!one.known && one.unread == most - 1 && one.waits == 1)
        let event = one.reread()
        guard case .movedAside(let name, let new)? = event else {
            Issue.record("not moved: \(String(describing: event))")
            return
        }
        aside = folder.appendingPathComponent(new)
        #expect(name == "vault-removals.json" && new.hasPrefix("vault-removals.json.unread-"))
        #expect(one.known && one.unread == 0 && one.waits == 0 && marks(one.record) == ["worker-2"])
        #expect(marks(VaultRemovals.load(file)) == ["worker-2"])
        #expect(KeptFile.read(folder.appendingPathComponent(new), atMost: KeptFile.largestRecord) == before)
        let beside: Set<String> = kind == "link" ? ["target-pipe"] : []
        #expect(try names(folder) == beside.union(["vault-removals.json", new]))   // nothing deleted, nothing left over
    }

    /// A move that fails changes nothing on the disk and removes nothing that this keeper did not make: here each name
    /// it could take is there already. The record that was not known is known from then on, so the steps go on with
    /// this Mac's copy; the change waits, and the move is tried again after sixty more.
    @Test func aMoveThatFailsChangesNothingAndTheRecordIsKnownAllTheSame() throws {
        let (folder, file) = place()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try bad.write(to: file)
        let now = Int(Date().timeIntervalSince1970)
        let taken = (now - 2...now + 60).map { folder.appendingPathComponent("vault-removals.json.unread-\($0)") }
        for name in taken { try Data("theirs".utf8).write(to: name) }
        var one = keeper(file)
        one.change { $0.removed("worker-1", fleet: fleet, at: 100, unpin: true) }
        for _ in 1..<most { one.reread() }
        #expect(!one.known)
        guard case .notMoved(let name, let cause)? = one.reread() else {
            Issue.record("moved")
            return
        }
        #expect(name == "vault-removals.json" && !cause.isEmpty)
        #expect(one.known && one.unread == most && one.waits == 1 && marks(one.record) == ["worker-1"])
        #expect(try Data(contentsOf: file) == bad)
        for name in taken { #expect(try Data(contentsOf: name) == Data("theirs".utf8)) }
        #expect(try names(folder).count == taken.count + 1)
        // The names are free again: the next sixty round reads move the file.
        for name in taken { try FileManager.default.removeItem(at: name) }
        for _ in 1..<most { #expect(one.reread() == nil) }
        guard case .movedAside? = one.reread() else {
            Issue.record("not moved")
            return
        }
        #expect(marks(VaultRemovals.load(file)) == ["worker-1"] && one.waits == 0)
    }

    /// After a move, the next one needs a good read first: a copy that gives no record either is never moved again
    /// and again. After a good read, a file that gives no record again is moved again.
    @Test func aSecondMoveNeedsAGoodReadFirst() throws {
        let (folder, file) = place()
        defer { try? FileManager.default.removeItem(at: folder) }
        var one = keeper(file)
        one.change { $0.removed("worker-1", fleet: fleet, at: 100, unpin: true) }
        try bad.write(to: file)
        for _ in 1..<most { one.reread() }
        guard case .movedAside(_, let first)? = one.reread() else {
            Issue.record("not moved")
            return
        }
        try FileManager.default.removeItem(at: folder.appendingPathComponent(first))
        try bad.write(to: file)                                            // the copy gives no record either
        for _ in 1..<most { one.reread() }
        guard case .notMoved(_, let cause)? = one.reread() else {
            Issue.record("moved again")
            return
        }
        #expect(cause.contains("either"))
        #expect(try names(folder) == ["vault-removals.json"])
        #expect(marks(one.record) == ["worker-1"])
        // A good read, and then a file that gives no record again: moved again.
        var good = VaultRemovals()
        good.removed("worker-1", fleet: fleet, at: 100, unpin: true)
        try good.save(file)
        one.reread()
        try bad.write(to: file)
        for _ in 1..<most { one.reread() }
        guard case .movedAside? = one.reread() else {
            Issue.record("not moved after a good read")
            return
        }
        #expect(marks(VaultRemovals.load(file)) == ["worker-1"])
    }

    /// A copy that is larger than a read takes is never written: no read would take it back. The record is known all
    /// the same, and nothing is written or moved.
    @Test func aCopyLargerThanAReadTakesIsNotMoved() throws {
        let (folder, file) = place()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try bad.write(to: file)
        var one = keeper(file)
        let long = String(repeating: "w", count: KeptFile.largestRecord + 1)
        one.change { $0.removed(long, fleet: fleet, at: 100, unpin: true) }  // it waits: the file gives no record
        for _ in 1..<most { one.reread() }
        guard case .notMoved(_, let cause)? = one.reread() else {
            Issue.record("moved")
            return
        }
        #expect(cause.contains("larger") && one.known && one.waits == 1)
        #expect(try Data(contentsOf: file) == bad)
        #expect(try names(folder) == ["vault-removals.json"])
    }

    /// A file that went away, and whose new write fails: the copy stays, and a later read writes it.
    @Test func aFileThatWentAwayAndCannotBeWrittenKeepsTheCopy() throws {
        let (folder, file) = place()
        defer {
            chmod(folder.path, 0o755)
            try? FileManager.default.removeItem(at: folder)
        }
        var one = keeper(file)
        one.change { $0.removed("worker-1", fleet: fleet, at: 100, unpin: true) }
        try FileManager.default.removeItem(at: file)
        #expect(chmod(folder.path, 0o555) == 0)
        one.reread()
        #expect(one.known && marks(one.record) == ["worker-1"] && !FileManager.default.fileExists(atPath: file.path))
        #expect(chmod(folder.path, 0o755) == 0)
        one.reread()
        #expect(marks(VaultRemovals.load(file)) == ["worker-1"])
    }

    /// The move in two steps, the way of a volume that cannot swap two names: the thing goes to the new name with
    /// ".old" after it, and the copy takes the file's name.
    @Test func theMoveInTwoSteps() throws {
        let (folder, file) = place()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try bad.write(to: file)
        var one = keeper(file)
        one.swapsNames = false
        one.change { $0.removed("worker-2", fleet: fleet, at: 200, unpin: true) }
        for _ in 1..<most { one.reread() }
        guard case .movedAside(_, let old)? = one.reread() else {
            Issue.record("not moved")
            return
        }
        #expect(old.hasPrefix("vault-removals.json.unread-") && old.hasSuffix(".old"))
        #expect(try Data(contentsOf: folder.appendingPathComponent(old)) == bad)
        #expect(marks(VaultRemovals.load(file)) == ["worker-2"] && one.known && one.waits == 0)
        #expect(try names(folder) == ["vault-removals.json", old])
    }

    /// The move in two steps of a folder, which can have no second name: the folder goes to the new name with ".old"
    /// after it, and then the copy takes the file's name.
    @Test func theMoveInTwoStepsOfAFolder() throws {
        let (folder, file) = place()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        var one = keeper(file)
        one.swapsNames = false
        one.change { $0.removed("worker-2", fleet: fleet, at: 200, unpin: true) }
        for _ in 1..<most { one.reread() }
        guard case .movedAside(_, let old)? = one.reread() else {
            Issue.record("not moved")
            return
        }
        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(old).path, isDirectory: &isFolder))
        #expect(isFolder.boolValue && old.hasSuffix(".old"))
        #expect(marks(VaultRemovals.load(file)) == ["worker-2"])
        #expect(try names(folder) == ["vault-removals.json", old])
    }

    /// A record larger than a read takes is never written: the file keeps its last record, and the change waits.
    @Test func aRecordLargerThanAReadTakesIsNotSaved() throws {
        let (folder, file) = place()
        defer { try? FileManager.default.removeItem(at: folder) }
        var one = keeper(file)
        one.change { $0.removed("worker-1", fleet: fleet, at: 100, unpin: true) }
        let written = try Data(contentsOf: file)
        let long = String(repeating: "w", count: KeptFile.largestRecord + 1)
        one.change { $0.removed(long, fleet: fleet, at: 200, unpin: true) }
        #expect(one.waits == 1 && one.record.marks(fleet: fleet)[long] != nil)
        #expect(try Data(contentsOf: file) == written)
        one.reread()
        #expect(one.waits == 1)
        #expect(try Data(contentsOf: file) == written)
        one.change { $0.added(long, fleet: fleet) }                        // the record is the file's again
        #expect(one.waits == 0 && marks(one.record) == ["worker-1"])
        #expect(try Data(contentsOf: file) == written)
    }

    @Test func aSaveThatFailsKeepsTheChangeUntilAWriteWorks() throws {
        let (folder, file) = place()
        defer {
            chmod(folder.path, 0o755)
            try? FileManager.default.removeItem(at: folder)
        }
        var one = keeper(file)
        one.change { $0.removed("worker-1", fleet: fleet, at: 100, unpin: true) }
        let written = try Data(contentsOf: file)
        #expect(chmod(folder.path, 0o555) == 0)                            // no new file can be made in the folder
        one.change { $0.removed("worker-2", fleet: fleet, at: 200, unpin: true) }
        #expect(marks(one.record) == ["worker-1", "worker-2"] && one.waits == 1 && one.known && one.unread == 0)
        #expect(try Data(contentsOf: file) == written)
        one.reread()                                                       // a good read: the change still waits
        #expect(marks(one.record) == ["worker-1", "worker-2"] && one.waits == 1)
        #expect(chmod(folder.path, 0o755) == 0)
        one.reread()
        #expect(one.waits == 0 && VaultRemovals.load(file) == one.record)
    }

    /// The key swap's records: a step's record that is made inside its change, from the record that the change is made
    /// to, keeps a put-back's hold that only the file holds (a start where the file gave no record at first).
    @Test func aChangeMadeFromTheRecordThatItIsMadeToKeepsAPutBacksHold() throws {
        let (folder, file) = place("key-swap.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        let program = String(repeating: "a", count: 64)
        let hold = KeySwapHold(program: program, wish: nil, reason: "Put back.", at: 100)
        var held = KeySwapState()
        held.set(KeySwapRecord(program: program, hold: hold), server: "box", fleet: fleet)
        try held.save(file)
        let good = try Data(contentsOf: file)
        try Data("{".utf8).write(to: file)
        var swap = RecordKeeper(file: file, empty: KeySwapState())
        #expect(!swap.known && swap.record == KeySwapState())
        let answer = KeySwapAnswer(program: program, outcome: .done(state: "there", swaps: false, ownerKeys: 1, fleet: true),
                                   serverWords: nil)
        let fleet = fleet
        swap.change { state in
            let earlier = state.records(fleet: fleet)["box"]
            state.set(KeySwapPlan.record(answer, after: earlier, wish: nil, keys: ["key"], fleet: fleet, at: 200),
                      server: "box", fleet: fleet)
        }
        #expect(swap.record.records(fleet: fleet)["box"]?.hold == nil)    // made from the empty copy, for now
        try good.write(to: file)
        swap.reread()
        let kept = KeySwapState.load(file).records(fleet: fleet)["box"]
        #expect(kept?.hold == hold && kept?.at == 200 && kept?.keys == ["key"] && swap.record == KeySwapState.load(file))
    }
}
