#if os(macOS)
import Foundation
import Testing
@testable import FleetCore

/// **Each place of FleetCore that reads a kept file through `KeptFile`, when what is at the file's name is not a file
/// that it reads**: a named pipe, a folder, a file that is too large (and, for the outbox, a file that cannot be
/// opened). For each place: what its caller gets, that no read waits, and that the read changes nothing. A link to
/// a file that it reads is read as before. Each test has a scratch folder of its own and removes it. A file that is
/// too large is made with no byte written (`truncate`), but for one of 128 KB.
struct KeptFilePlacesTests {
    private final class Scratch {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kept-places-\(UUID().uuidString)")
        init() throws { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        func remove() { try? FileManager.default.removeItem(at: folder) }
        func file(_ name: String) -> URL { folder.appendingPathComponent(name, isDirectory: false) }

        func pipe(_ name: String) throws -> URL {
            try #require(mkfifo(file(name).path, 0o600) == 0)
            return file(name)
        }

        func link(_ name: String, to target: URL) throws -> URL {
            try FileManager.default.createSymbolicLink(at: file(name), withDestinationURL: target)
            return file(name)
        }

        func emptyFolder(_ name: String) throws -> URL {
            try FileManager.default.createDirectory(at: file(name), withIntermediateDirectories: true)
            return file(name)
        }

        /// A regular file of `bytes` bytes that takes no room on the disk.
        func sparse(_ name: String, bytes: Int) throws -> URL {
            try #require(FileManager.default.createFile(atPath: file(name).path, contents: nil))
            let handle = try FileHandle(forWritingTo: file(name))
            try handle.truncate(atOffset: UInt64(bytes))
            try handle.close()
            return file(name)
        }

        /// The names in the folder with the kind and the size of each, by the name itself and through no link.
        func picture() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted().map { name in
                var facts = stat()
                lstat(folder.appendingPathComponent(name).path, &facts)
                return "\(name) \(facts.st_mode & S_IFMT) \(facts.st_size)"
            }
        }
    }

    /// What `answered` carries from the thread of the work to the test: written before the signal, read after it.
    private final class Box<Value>: @unchecked Sendable { var value: Value? }

    /// **The answer of `work`, which runs beside the test; nil when it did not come within five seconds.** A read
    /// that waits at a pipe fails its test so, and does not hold it: a writer then comes and goes at each of `pipes`,
    /// a counted number of times, so that the read ends.
    private func answered<Answer>(pipes: [URL], _ work: @escaping @Sendable () -> Answer) -> Answer? {
        let box = Box<Answer>(), done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            box.value = work()
            done.signal()
        }
        let inTime = done.wait(timeout: .now() + 5) == .success
        var ended = inTime
        for _ in 0..<40 where !ended {
            for pipe in pipes {
                let release = Darwin.open(pipe.path, O_WRONLY | O_NONBLOCK)
                guard release >= 0 else { continue }
                Thread.sleep(forTimeInterval: 0.05)
                Darwin.close(release)
            }
            ended = done.wait(timeout: .now() + 0.2) == .success
        }
        return inTime ? box.value : nil
    }

    // ------------------------------------------------------------ the request that waits to be sent

    private func request(_ text: String = "a message that waits") -> PendingRequest {
        PendingRequest(hub: URL(string: "http://100.64.0.1:8765")!, database: "g1", client: "test", text: text)
    }

    /// What a load of the outbox gave: a request, none, `invalidRecord`, a Cocoa error of a kind, another error.
    private enum Loaded: Equatable, Sendable { case request, noRequest, invalidRecord, cocoa(Int), other }

    private static func loaded(_ outbox: Outbox) -> Loaded {
        do { return try outbox.load() == nil ? .noRequest : .request }
        catch OutboxError.invalidRecord { return .invalidRecord }
        catch let error as CocoaError { return .cocoa(error.errorCode) }
        catch { return .other }
    }

    /// **What is at the outbox's name and is not read is never "no request"**, but for a name at which the system's
    /// own look finds no file (no file, and a link that leads to none), which is no request, as before. For the
    /// rest the load throws, and `save` and `clear` read first, so they write and remove nothing there. A thing that
    /// is no file and a file that cannot be opened throw the system's kind of error; a file that is larger than a
    /// saved request can be throws `invalidRecord`.
    @Test func whatTheOutboxDoesNotReadBlocksSendingAndStays() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let plain = Outbox(file: scratch.file("plain.json"))
        #expect(Self.loaded(plain) == .noRequest)
        let waiting = request()
        try plain.save(waiting)
        #expect(try plain.load() == waiting)
        // A link to a saved request is read as before, and a link that leads nowhere is no request, as before.
        #expect(try Outbox(file: try scratch.link("link.json", to: scratch.file("plain.json"))).load() == waiting)
        #expect(Self.loaded(Outbox(file: try scratch.link("dangling.json", to: scratch.file("gone.json")))) == .noRequest)
        // So is a link that leads to itself: the system's look finds no file there.
        try FileManager.default.createSymbolicLink(atPath: scratch.file("ring.json").path, withDestinationPath: "ring.json")
        #expect(Self.loaded(Outbox(file: scratch.file("ring.json"))) == .noRequest)

        let pipe = try scratch.pipe("pipe.json")
        let places: [(URL, Loaded)] = [
            (pipe, .cocoa(CocoaError.Code.fileReadUnknown.rawValue)),
            (try scratch.emptyFolder("folder.json"), .cocoa(CocoaError.Code.fileReadUnknown.rawValue)),
            (try scratch.link("to-pipe.json", to: pipe), .cocoa(CocoaError.Code.fileReadUnknown.rawValue)),
            (try scratch.sparse("large.json", bytes: 262_145), .invalidRecord),
        ]
        let before = scratch.picture()
        let kept = try Data(contentsOf: scratch.file("plain.json"))
        for (place, expected) in places {
            let outbox = Outbox(file: place), name = place.lastPathComponent
            let got = answered(pipes: [pipe]) { Self.loaded(outbox) }
            #expect(got == expected, "\(name): \(got.map { "\($0)" } ?? "the read waited")")
            guard got != nil else { continue }
            #expect(throws: (any Error).self, "\(name)") { try outbox.save(request("another")) }
            #expect(throws: (any Error).self, "\(name)") { try outbox.clear(matching: waiting.requestID) }
        }
        // Each thing is what it was, and the saved request is the one that was saved.
        #expect(scratch.picture() == before)
        #expect(try Data(contentsOf: scratch.file("plain.json")) == kept)

        // A file that this user may not read: the system's error for it, and the file stays. (Root reads every file.)
        let closed = Outbox(file: scratch.file("closed.json"))
        try closed.save(waiting)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: closed.file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: closed.file.path) }
        if getuid() != 0 {
            #expect(Self.loaded(closed) == .cocoa(CocoaError.Code.fileReadNoPermission.rawValue))
            #expect(throws: (any Error).self) { try closed.save(request("another")) }
            #expect(throws: (any Error).self) { try closed.clear(matching: waiting.requestID) }
            #expect(FileManager.default.fileExists(atPath: closed.file.path))
        }
    }

    /// At a link that leads nowhere, a save puts the request in the link's place, as before.
    @Test func aSaveAtALinkThatLeadsNowhereKeepsTheRequest() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let outbox = Outbox(file: try scratch.link("pending.json", to: scratch.file("gone.json")))
        let waiting = request()
        try outbox.save(waiting)
        #expect(try outbox.load() == waiting)
        #expect(!FileManager.default.fileExists(atPath: scratch.file("gone.json").path))
    }

    // ------------------------------------------------------------ the vault's two records

    /// **The record of the removed servers**: what is not read is the record of a new Mac, which is the record's own
    /// rule for a file that cannot be read. A link to a record is read as before. The read changes nothing.
    @Test func theVaultsRemovalsAreReadOnlyFromARegularFileOfTheirSize() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        var record = VaultRemovals()
        record.removed("worker-1", fleet: "0f1e2d3c4b5a6978", at: 1_794_650_000, unpin: true)
        try record.save(scratch.file("plain.json"))
        #expect(VaultRemovals.load(scratch.file("plain.json")) == record)
        #expect(VaultRemovals.load(try scratch.link("link.json", to: scratch.file("plain.json"))) == record)

        let pipe = try scratch.pipe("pipe.json"), folder = try scratch.emptyFolder("folder.json")
        let large = try scratch.sparse("large.json", bytes: KeptFile.largestRecord + 1)
        let before = scratch.picture()
        let loads = answered(pipes: [pipe]) { [pipe, folder, large].map { VaultRemovals.load($0) } }
        #expect(loads == Array(repeating: VaultRemovals(), count: 3), "the read of a pipe waited")
        #expect(scratch.picture() == before)
    }

    /// **The key swap's state**, by the same rule.
    @Test func theKeySwapsStateIsReadOnlyFromARegularFileOfItsSize() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        var state = KeySwapState()
        state.setUpdate(KeySwapUpdate(program: "sha256:" + String(repeating: "a", count: 64),
                                      tries: KeySwapTries(failures: 2, last: 1_794_650_000, reason: "x")),
                        fleet: "0f1e2d3c4b5a6978")
        try state.save(scratch.file("plain.json"))
        #expect(KeySwapState.load(scratch.file("plain.json")) == state)
        #expect(KeySwapState.load(try scratch.link("link.json", to: scratch.file("plain.json"))) == state)

        let pipe = try scratch.pipe("pipe.json"), folder = try scratch.emptyFolder("folder.json")
        let large = try scratch.sparse("large.json", bytes: KeptFile.largestRecord + 1)
        let before = scratch.picture()
        let loads = answered(pipes: [pipe]) { [pipe, folder, large].map { KeySwapState.load($0) } }
        #expect(loads == Array(repeating: KeySwapState(), count: 3), "the read of a pipe waited")
        #expect(scratch.picture() == before)
    }

    // ------------------------------------------------------------ this Mac's key for its hub

    /// **The key's file**: at most 256 bytes of a regular file, also behind a link, as before. What is no such file
    /// gives no key, at once.
    @Test func thisMacsKeyIsReadOnlyFromARegularFileOfItsSize() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let key = String(repeating: "k", count: 43)
        try Data((key + "\n").utf8).write(to: scratch.file("key"))
        #expect(OwnerMacKey.key(in: scratch.file("key")) == key)
        #expect(OwnerMacKey.key(in: try scratch.link("to-key", to: scratch.file("key"))) == key)
        #expect(OwnerMacKey.key(in: scratch.file("none")) == nil)
        // The limit is of the file: 256 bytes that hold a key give it, and one byte more gives none.
        try Data((key + String(repeating: "\n", count: 256 - 43)).utf8).write(to: scratch.file("at-limit"))
        try Data((key + String(repeating: "\n", count: 257 - 43)).utf8).write(to: scratch.file("long"))
        #expect(OwnerMacKey.key(in: scratch.file("at-limit")) == key)
        #expect(OwnerMacKey.key(in: scratch.file("long")) == nil)

        let pipe = try scratch.pipe("pipe"), folder = try scratch.emptyFolder("folder")
        let toPipe = try scratch.link("to-pipe", to: pipe)
        let before = scratch.picture()
        let keys = answered(pipes: [pipe]) { [pipe, toPipe, folder].map(OwnerMacKey.key(in:)) }
        #expect(keys == [nil, nil, nil], "the read of a pipe waited")
        #expect(scratch.picture() == before)
    }

    // ------------------------------------------------------------ the crashes that wait for a send

    /// **The file of the crashes that wait**: at most twice a report's size, by the size of the file that is read.
    /// The size was asked of the name before, so a link passed with its own few bytes and the file behind it was
    /// read whole, whatever its size. A link to a file of the right size is read as before. The read changes nothing.
    @Test func theCrashesThatWaitAreReadOnlyFromARegularFileOfTheirSize() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let crash = ErrorReport.Crash(signal: 6, type: 10, code: 0, frames: [.lib], first: 1_763_300_000, last: 1_763_300_000)
        try ErrorReport.keep([crash], in: scratch.file("plain.json"))
        #expect(ErrorReport.kept(scratch.file("plain.json")) == [crash])
        #expect(ErrorReport.kept(try scratch.link("link.json", to: scratch.file("plain.json"))) == [crash])

        // A file that holds a crash and is one byte over the limit: not read, by its name and behind a link.
        var long = try Data(contentsOf: scratch.file("plain.json"))
        long.append(Data(repeating: 0x20, count: 2 * ErrorReport.maxBytes + 1 - long.count))
        try long.write(to: scratch.file("long.json"))
        #expect(ErrorReport.kept(scratch.file("long.json")).isEmpty)
        #expect(ErrorReport.kept(try scratch.link("to-long.json", to: scratch.file("long.json"))).isEmpty)
        // One byte less is a file that is read: the spaces after the crashes say nothing.
        try long.dropLast().write(to: scratch.file("at-limit.json"))
        #expect(ErrorReport.kept(scratch.file("at-limit.json")) == [crash])

        let pipe = try scratch.pipe("pipe.json"), folder = try scratch.emptyFolder("folder.json")
        let before = scratch.picture()
        let kept = answered(pipes: [pipe]) { [pipe, folder].map { ErrorReport.kept($0) } }
        #expect(kept == [[], []], "the read of a pipe waited")
        #expect(ErrorReport.kept(scratch.file("none.json")).isEmpty)
        #expect(scratch.picture() == before)
    }

    // ------------------------------------------------------------ the Mac app's own target, which no test imports

    /// **The Mac app reads its kept files through the reader too**: the readings that it kept for a window's first
    /// frame (read on the main thread at the app's start) and the staged files of a message (read in `upload`, and
    /// when making the small picture). The app's target has no tests, so its source is read, as
    /// `InstallStartTests` reads it, with each run of spaces and line ends as one space, so a line that is wrapped
    /// anew is the same line. The system's own reader stays for the file that the owner picks himself.
    @Test func theMacAppReadsItsKeptFilesThroughTheReader() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ file: String) throws -> String {
            try String(contentsOf: app.appendingPathComponent("Sources/Founderizer/" + file), encoding: .utf8)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let store = try source("FleetStore.swift"), views = try source("AttachmentViews.swift")
        // No read of the system's own of one of these files.
        for own in ["contentsOf: lastReadingFile", "contentsOf: keptFile(", "contentsOf: stagedURL(", "contentsOf: store.stagedURL("] {
            #expect(!store.contains(own) && !views.contains(own), "\(own)")
        }
        // Each of them through the reader, with the limit of its kind.
        for own in ["lastReadingFile", #"keptFile("health")"#, #"keptFile("releases")"#, #"keptFile("app-update")"#] {
            #expect(store.contains("KeptFile.bytes(of: \(own), atMost: KeptFile.largestReading)"), "\(own)")
        }
        #expect(store.contains("KeptFile.read(stagedURL(file), atMost: MessageAttachment.sizeLimit)"))
        #expect(views.contains("let url = store.stagedURL(file)"))
        #expect(views.contains("KeptFile.bytes(of: url, atMost: MessageAttachment.sizeLimit)"))
        // A staged file that is too large keeps the words that its upload gave it before, with no read of it: they
        // stand in `upload` before the file is marked as going up.
        let upload = try #require(store.range(of: "func upload(_ file: StagedFile, for composer: String) async {"))
        let goesUp = try #require(store.range(of: "uploading.insert(file.requestID)", range: upload.upperBound..<store.endIndex))
        #expect(store[upload.upperBound..<goesUp.lowerBound].contains("AttachmentError.tooLarge.errorDescription"))
    }
}
#endif
