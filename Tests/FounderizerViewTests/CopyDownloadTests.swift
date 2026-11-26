import CryptoKit
import FleetCore
import Foundation
import Testing

/// **A copy that the hub gives goes whole into a file of this Mac, and a damaged one leaves nothing** (F14 piece 2; the
/// validator's finding 2-A, 22 November 2026). Each Mac takes its daily copy through `HubClient.takeCopy`, which writes
/// the copy into a file as it arrives, with a delegate of its own (`CopyDownload`). No test gave it a 200: only its
/// refusal ran. The stand-in hub gives 3 MiB in parts of 64 KiB, with its length, its generation and its SHA-256: the
/// file that comes back holds those bytes. The same answer with another SHA-256 is refused as `.checksum`, and no folder
/// of it stays. The file is mode 600, and so is the copy with the fleet's access key that the app makes of it to keep
/// (`OwnerAccess.withKey`, here of the fixture copy of FleetCoreTests): its mode goes with it into his folder. The bugs
/// that it catches: a delegate that writes nothing, or a part twice; a copy whose digest is not checked; a damaged
/// copy's folder left on the disk; a kept copy, with every record and the root key in it, that other accounts of this
/// Mac can read (the second reader's M1).
@Suite(.serialized, .timeLimit(.minutes(2)))
struct CopyDownloadTests {
    /// The folders of a copy on its way in of this process (`founderizer-copy-<pid>-<UUID>`) in this Mac's temporary
    /// folder: not those of the owner's own app, which shares that folder.
    private static func arriving() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []
        return Set(names.filter { $0.hasPrefix("founderizer-copy-\(getpid())-") })
    }

    /// What a start that comes while a copy arrives removed (`FleetCopy.leftoversGone`).
    private final class Removed: @unchecked Sendable {
        private let lock = NSLock()
        private var kept: [String]?
        var names: [String]? { lock.withLock { kept } }
        func set(_ names: [String]) { lock.withLock { kept = names } }
    }

    /// **A start of another app process leaves the copy that this process takes** (the second reader's R2-1, 22 November
    /// 2026): each process of an account shares one temporary folder, and a start removes the copies that earlier
    /// processes left (`FleetCopy.leftoversGone`). The folder of a copy on its way names its process, which runs, so a
    /// start that comes after its first part leaves it, and the copy arrives whole. The folder is in a folder of the
    /// test's own, never the Mac's temporary folder. The bug that it catches: a second app process (a test build,
    /// `open -n`, a test of the app) whose start removes a copy that the first one still takes.
    @Test func aStartOfAnotherProcessLeavesTheCopyThatThisOneTakes() async throws {
        let hub = try LoopbackHub(state: Data("{}".utf8))
        defer { hub.stop() }
        let address = try #require(URL(string: hub.address))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("copy-start-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let body = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ $0 / 65_536) })
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let removed = Removed()
        hub.give(copy: body, fields: ["X-Fleet-DB": "copy-test", "X-Fleet-Backup-SHA256": digest,
                                      "Content-Disposition": "attachment; filename=\"founderizer-start.zip\""],
                 between: { removed.set(FleetCopy.leftoversGone(before: Date(), in: root)) })
        let copy = try await HubClient().takeCopy(hub: address, database: "copy-test", in: root)
        #expect(removed.names == [], "the start removed \(removed.names ?? ["nothing: it did not run"])")
        #expect(try Data(contentsOf: copy.file) == body, "the copy arrived whole")
    }

    /// The permission bits of a file.
    private static func mode(_ file: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber).intValue
    }

    @Test func aCopyGoesIntoItsFileWholeAndADamagedOneLeavesNothing() async throws {
        let hub = try LoopbackHub(state: Data("{}".utf8))
        defer { hub.stop() }
        let address = try #require(URL(string: hub.address))
        let body = Data((0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0 / 65_536 &+ $0 &* 7) })   // each part differs
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let name = "founderizer-0f1e2d3c4b5a6978-20261122T120000Z.zip"
        func answer(_ sha256: String) -> [String: String] {
            ["X-Fleet-DB": "copy-test", "X-Fleet-Backup-SHA256": sha256,
             "Content-Disposition": "attachment; filename=\"\(name)\""]
        }
        let before = Self.arriving()
        hub.give(copy: body, fields: answer(digest))
        let copy = try await HubClient().takeCopy(hub: address, database: "copy-test")
        defer { try? FileManager.default.removeItem(at: copy.file.deletingLastPathComponent()) }
        #expect(try Data(contentsOf: copy.file) == body, "the file holds the bytes that the hub sent")
        #expect(copy.sha256 == digest && copy.bytes == Int64(body.count) && copy.suggestedName == name)
        #expect(hub.requests.contains { $0.method == "GET" && $0.path == "/ui/backup" })
        #expect(try Self.mode(copy.file) == 0o600, "the copy is this account's alone")

        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FleetCoreTests/Fixtures/copy.zip")
        let real = try Data(contentsOf: fixture)
        hub.give(copy: real, fields: answer(SHA256.hash(data: real).map { String(format: "%02x", $0) }.joined()))
        let small = try await HubClient().takeCopy(hub: address, database: "copy-test")
        defer { try? FileManager.default.removeItem(at: small.file.deletingLastPathComponent()) }
        let key = try #require(OwnerAccessKey(seed: Data((0..<32).map { UInt8($0 * 7 + 3) })))
        let kept = try #require(OwnerAccess.withKey(try OwnerAccess.checkHubForm(small.file)) { _ in key },
                                "the fixture copy takes the key")
        #expect(try Self.mode(kept) == 0o600, "the copy with the fleet's access key is this account's alone")

        hub.give(copy: body, fields: answer(String(repeating: "0", count: 64)))
        await #expect(throws: FleetCopyError.checksum) {
            _ = try await HubClient().takeCopy(hub: address, database: "copy-test")
        }
        let left = Self.arriving().subtracting(before)
            .subtracting([copy, small].map { $0.file.deletingLastPathComponent().lastPathComponent })
        #expect(left.isEmpty, "a damaged copy left \(left.sorted())")
    }
}
