#if os(macOS)
import Foundation
import Testing
@testable import FleetCore

/// **The reader of the files that the app keeps** (`KeptFile`): only a regular file within the caller's limit is
/// read, a link is followed to such a file unless the caller says no, no read waits for a writer, and nothing on the
/// disk changes. Each test has a scratch folder of its own and removes it.
struct KeptFileTests {
    private final class Scratch {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kept-file-\(UUID().uuidString)")
        init() throws { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        func remove() { try? FileManager.default.removeItem(at: folder) }
        func file(_ name: String) -> URL { folder.appendingPathComponent(name, isDirectory: false) }
        /// The names in the folder with the kind and the size of each, by the name itself and through no link.
        func picture() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted().map { name in
                var facts = stat()
                lstat(folder.appendingPathComponent(name).path, &facts)
                return "\(name) \(facts.st_mode & S_IFMT) \(facts.st_size)"
            }
        }
    }

    @Test func aRegularFileWithinTheLimitIsReadWhole() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let words = Data("a kept file".utf8)
        try words.write(to: scratch.file("small.json"))
        #expect(KeptFile.read(scratch.file("small.json"), atMost: 64) == .bytes(words))
        #expect(KeptFile.bytes(of: scratch.file("small.json"), atMost: 64) == words)
        // An empty file is a file with no bytes, not a missing one.
        try Data().write(to: scratch.file("empty.json"))
        #expect(KeptFile.read(scratch.file("empty.json"), atMost: 64) == .bytes(Data()))
        #expect(KeptFile.read(scratch.file("empty.json"), atMost: 0) == .bytes(Data()))
        // A file larger than one piece of the read (1 MiB) comes back whole, byte for byte.
        var large = Data(count: 2 * 1024 * 1024 + 7)
        for index in stride(from: 0, to: large.count, by: 4099) { large[index] = UInt8(index % 251) }
        try large.write(to: scratch.file("large.json"))
        #expect(KeptFile.bytes(of: scratch.file("large.json"), atMost: KeptFile.largestReading) == large)
    }

    @Test func theLimitIsOfTheFileItself() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try Data(repeating: 0x20, count: 100).write(to: scratch.file("at.json"))
        try Data(repeating: 0x20, count: 101).write(to: scratch.file("over.json"))
        #expect(KeptFile.bytes(of: scratch.file("at.json"), atMost: 100)?.count == 100)
        #expect(KeptFile.read(scratch.file("over.json"), atMost: 100) == .refused(.tooLarge))
        #expect(KeptFile.bytes(of: scratch.file("over.json"), atMost: 100) == nil)
        // The limit holds behind a link: the link's own few bytes say nothing.
        try FileManager.default.createSymbolicLink(at: scratch.file("link.json"), withDestinationURL: scratch.file("over.json"))
        #expect(KeptFile.read(scratch.file("link.json"), atMost: 100) == .refused(.tooLarge))
        // A limit that no file passes, and the largest limit that a caller can name.
        #expect(KeptFile.read(scratch.file("at.json"), atMost: -1) == .refused(.tooLarge))
        #expect(KeptFile.bytes(of: scratch.file("at.json"), atMost: .max)?.count == 100)
    }

    @Test func noFileIsMissingAndNotARefusal() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        #expect(KeptFile.read(scratch.file("none.json"), atMost: 64) == .missing)
        // No folder of that name either, and a name under something that is no folder.
        #expect(KeptFile.read(scratch.folder.appendingPathComponent("no-folder/none.json"), atMost: 64) == .missing)
        try Data("x".utf8).write(to: scratch.file("plain"))
        #expect(KeptFile.read(scratch.folder.appendingPathComponent("plain/none.json"), atMost: 64) == .missing)
        // A link that leads to no file is no file, as the system's own look said before; not followed, it is a link.
        try FileManager.default.createSymbolicLink(at: scratch.file("dangling.json"), withDestinationURL: scratch.file("gone.json"))
        #expect(KeptFile.read(scratch.file("dangling.json"), atMost: 64) == .missing)
        #expect(KeptFile.read(scratch.file("dangling.json"), atMost: 64, followsLinks: false) == .refused(.notAFile))
    }

    @Test func aLinkIsFollowedToARegularFileUnlessTheCallerSaysNo() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let words = Data("behind a link".utf8)
        try words.write(to: scratch.file("real.json"))
        try FileManager.default.createSymbolicLink(at: scratch.file("link.json"), withDestinationURL: scratch.file("real.json"))
        #expect(KeptFile.read(scratch.file("link.json"), atMost: 64) == .bytes(words))
        #expect(KeptFile.read(scratch.file("link.json"), atMost: 64, followsLinks: false) == .refused(.notAFile))
        #expect(KeptFile.bytes(of: scratch.file("link.json"), atMost: 64, followsLinks: false) == nil)
        // A link to a folder is refused as the folder is, followed or not; so is a link that leads to itself.
        try FileManager.default.createDirectory(at: scratch.file("folder.json"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: scratch.file("to-folder.json"), withDestinationURL: scratch.file("folder.json"))
        try FileManager.default.createSymbolicLink(atPath: scratch.file("ring.json").path, withDestinationPath: "ring.json")
        for name in ["folder.json", "to-folder.json", "ring.json"] {
            #expect(KeptFile.read(scratch.file(name), atMost: 64) == .refused(.notAFile), "\(name)")
            #expect(KeptFile.read(scratch.file(name), atMost: 64, followsLinks: false) == .refused(.notAFile), "\(name)")
        }
        // A folder above the file can be a link also for a caller that follows none: only the file's own name counts.
        try FileManager.default.createDirectory(at: scratch.file("home"), withIntermediateDirectories: true)
        try words.write(to: scratch.file("home").appendingPathComponent("kept.json"))
        try FileManager.default.createSymbolicLink(at: scratch.file("to-home"), withDestinationURL: scratch.file("home"))
        let kept = scratch.file("to-home").appendingPathComponent("kept.json")
        #expect(KeptFile.read(kept, atMost: 64, followsLinks: false) == .bytes(words))
    }

    /// A file that this user may not read is refused with the system's own cause, and the error that is made from
    /// the refusal has the kind and the words of the system reader's own error for that file.
    @Test func aFileThatThisUserCannotReadIsRefusedWithItsCause() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let closed = scratch.file("closed.json")
        try Data("closed".utf8).write(to: closed)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: closed.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: closed.path) }
        // The other kinds need no file that is closed: a thing that is no file, a file that is too large.
        #expect(KeptFile.systemError(.notAFile, file: closed).code == .fileReadUnknown)
        #expect(KeptFile.systemError(.tooLarge, file: closed).code == .fileReadTooLarge)
        #expect(KeptFile.systemError(.unreadable(errno: EIO), file: closed).code == .fileReadUnknown)
        // Root reads every file: the rest says nothing there.
        guard getuid() != 0 else { return }
        #expect(KeptFile.read(closed, atMost: 64) == .refused(.unreadable(errno: EACCES)))
        let ours = KeptFile.systemError(.unreadable(errno: EACCES), file: closed)
        #expect(ours.code == .fileReadNoPermission)
        var thrown: (any Error)?
        do { _ = try Data(contentsOf: closed) } catch { thrown = error }
        let systems = try #require(thrown) as NSError
        #expect(systems.domain == CocoaError.errorDomain && systems.code == ours.errorCode)
        #expect(systems.localizedDescription == ours.localizedDescription)
    }

    /// **No read waits for a pipe's writer, and a pipe gives no bytes**: not at the file's own place and not behind
    /// a link. Every read of a pipe runs beside the test, with a counted way out, so a read that waits fails the
    /// test and does not hold it. (macOS 27 refuses a pipe at once in its own reader too; other systems were not
    /// measured.)
    @Test func aNamedPipeIsNeverReadAndNeverWaitedFor() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        // A pipe that nobody writes to; a pipe with bytes in it and its writer still open; a link to each.
        let silent = scratch.file("silent.json"), fed = scratch.file("fed.json")
        #expect(mkfifo(silent.path, 0o600) == 0 && mkfifo(fed.path, 0o600) == 0)
        let writer = Darwin.open(fed.path, O_RDWR | O_NONBLOCK)
        try #require(writer >= 0)
        var writerOpen = true
        defer { if writerOpen { Darwin.close(writer) } }
        let words = Array("bytes that no reader may take".utf8)
        #expect(Darwin.write(writer, words, words.count) == words.count)
        try FileManager.default.createSymbolicLink(at: scratch.file("to-silent.json"), withDestinationURL: silent)
        try FileManager.default.createSymbolicLink(at: scratch.file("to-fed.json"), withDestinationURL: fed)
        let asked = [silent, fed, scratch.file("to-silent.json"), scratch.file("to-fed.json")]
        let before = scratch.picture()

        final class Answers: @unchecked Sendable { var reads: [KeptFile.Read] = [] }
        let answers = Answers(), done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            answers.reads = asked.map { KeptFile.read($0, atMost: 1024) }
                + asked.map { KeptFile.read($0, atMost: 1024, followsLinks: false) }
            done.signal()
        }
        let returned = done.wait(timeout: .now() + 5) == .success
        Darwin.close(writer)
        writerOpen = false
        // While a read still waits at a pipe, a writer comes and goes there, a counted number of times.
        var ended = returned
        for _ in 0..<40 where !ended {
            for pipe in [silent, fed] {
                let release = Darwin.open(pipe.path, O_WRONLY | O_NONBLOCK)
                guard release >= 0 else { continue }
                Thread.sleep(forTimeInterval: 0.05)
                Darwin.close(release)
            }
            ended = done.wait(timeout: .now() + 0.2) == .success
        }
        #expect(returned, "a read waited for a named pipe")
        try #require(ended, "a read still waits for a named pipe")
        // Followed or not, a pipe and a link to one are no file.
        #expect(answers.reads == Array(repeating: .refused(.notAFile), count: 8))
        // Nothing on the disk changed: the same names, each of its kind and its size.
        #expect(scratch.picture() == before)
    }

    /// A read changes nothing: no file is made, moved, cut or removed, whatever it finds.
    @Test func aReadChangesNothingOnTheDisk() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try Data(repeating: 0x41, count: 300).write(to: scratch.file("large.json"))
        try Data("small".utf8).write(to: scratch.file("small.json"))
        try FileManager.default.createDirectory(at: scratch.file("folder.json"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: scratch.file("link.json"), withDestinationURL: scratch.file("large.json"))
        let before = scratch.picture()
        for name in ["large.json", "small.json", "folder.json", "link.json", "none.json"] {
            _ = KeptFile.read(scratch.file(name), atMost: 100)
            _ = KeptFile.read(scratch.file(name), atMost: 100, followsLinks: false)
        }
        #expect(scratch.picture() == before)
        #expect(try Data(contentsOf: scratch.file("large.json")) == Data(repeating: 0x41, count: 300))
    }
}
#endif
