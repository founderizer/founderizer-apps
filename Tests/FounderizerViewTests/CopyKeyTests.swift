import CryptoKit
import FleetCore
import Foundation
import Testing
@testable import Founderizer

/// **A copy whose access key did not go in is kept, says so, and tells the hub** (the audit's finding 1, 24 November
/// 2026; the validators' round 2 of 25 November 2026). Both savers kept the bare copy when the key's step failed and
/// confirmed it as a whole one, so the hub cleared its warning and no screen said that no copy could give a new Mac its
/// servers back. The stand-in hub serves the fixture copy of FleetCoreTests and answers each confirm with its copy.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct CopyKeyTests {
    struct NoKeychain: Error {}

    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("FleetCoreTests/Fixtures/copy.zip")
    static let key = OwnerAccessKey(seed: Data((0..<32).map { UInt8($0 * 7 + 3) }))!
    static let fleet = "0f1e2d3c4b5a6978"

    /// One stand-in hub, a store that reads it, and a folder of the test's own for the copies; `body` runs on the main
    /// loop, and the hub and the folder go at its end.
    @MainActor final class Rig {
        let database = "copy-key-\(UUID().uuidString)"
        let hub: LoopbackHub
        let store: FleetStore
        let folder: URL
        let copy: Data
        let digest: String

        init() throws {
            copy = try Data(contentsOf: CopyKeyTests.fixture)
            digest = SHA256.hash(data: copy).map { String(format: "%02x", $0) }.joined()
            let state: [String: Any] = [
                "schema_version": 1, "db": database, "time": Int(Date().timeIntervalSince1970),
                "agents": [["name": "manager", "role": "manager", "runtime": "claude", "can": [], "placed": true]],
                "tasks": [], "holds": [], "outcomes": [], "notes": [], "needs": [], "permissions": [], "messages": [],
                "reports": [], "ui_features": ["health", "restore"]]
            let reading = try JSONSerialization.data(withJSONObject: state)
            hub = try LoopbackHub(state: reading)
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("copy-key-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            _ = ViewHost.store(try HubState.decode(reading))       // the test's own defaults, emptied
            AppDefaults.store.set(hub.address, forKey: "hubAddress")
            AppDefaults.store.set(try folder.bookmarkData(), forKey: "copyFolder")
            hub.answer("POST", "/ui/backups/confirm") { request in
                let asked = (try? JSONSerialization.jsonObject(with: Data(request.body.utf8))) as? [String: Any] ?? [:]
                let answer: [String: Any] = ["ok": true, "backup": ["at": 1_792_500_000, "bytes": asked["bytes"] ?? 0,
                                                                    "sha256": asked["sha256"] ?? ""]]
                return (status: 200, body: (try? JSONSerialization.data(withJSONObject: answer)) ?? Data())
            }
            store = FleetStore()
            store.copies.accessKey = { _ in throw NoKeychain() }       // before any copy: never the Mac's keychain
        }

        func stop() {
            hub.stop()
            try? FileManager.default.removeItem(at: folder)
        }

        /// The confirms that the hub got, as their bodies.
        var confirms: [[String: Any]] {
            hub.requests.filter { $0.method == "POST" && $0.path == "/ui/backups/confirm" }
                .map { (try? JSONSerialization.jsonObject(with: Data($0.body.utf8))) as? [String: Any] ?? [:] }
        }

        /// The hub serves its copy under this name from now on, to a reading that is current.
        func serve(_ name: String) {
            Task { await store.refresh() }          // a copy is taken only from a reading that is current
            ViewHost.turn(10) { self.store.isFresh && self.store.state?.db == self.database && !self.store.refreshing }
            hub.give(copy: copy, fields: ["X-Fleet-DB": database, "X-Fleet-Backup-SHA256": digest,
                                          "Content-Disposition": "attachment; filename=\"\(name)\""])
        }

        /// One automatic copy under this name, at this time.
        func take(_ name: String, at now: Date) {
            serve(name)
            let before = confirms.count
            Task { await store.copies.tick(store: store, now: now) }
            ViewHost.turn(20) { self.confirms.count > before && !self.store.copies.busy }
        }

        /// One Save copy under this name, into the copies' folder (its panel answers with that place).
        func save(_ name: String, with model: FleetCopyModel) {
            serve(name)
            model.place = { _ in self.folder.appendingPathComponent(name) }
            let before = confirms.count
            Task { await model.save(store: store) }
            ViewHost.turn(20) { self.confirms.count > before && !model.busy }
        }
    }

    struct Seen: Sendable, Equatable {
        let keyed: [Bool?]
        let makers: [String?]
        let keyMissing: [Bool]
        let failures: [String?]
        let causes: [Bool]
        let carried: [Bool]
        let recorded: [String: Bool]
    }

    /// **The automatic copy.** The first time the key cannot be had: the copy is kept in his folder with no key, the
    /// confirm says `keyed: false`, the row's failure is `CopySchedule.noKey` with its flag, the cause is kept for Report
    /// a problem, and the record says that copy has no key. The second time, two days later, the key goes in: the
    /// confirm says `keyed: true`, and the failure, its flag and its cause are gone. The bugs that it catches: a copy with
    /// no key confirmed as a whole one; a copy with no key that no row names, or whose cause is lost; a copy with the
    /// key that leaves the old failure on the row; a copy that retention does not know by its name.
    @Test func anAutomaticCopyWithNoKeyIsKeptNamedAndConfirmedAsOne() async throws {
        let names = ["founderizer-\(Self.fleet)-20261125T080000Z.zip", "founderizer-\(Self.fleet)-20261127T080000Z.zip"]
        let (seen, _) = try await ViewHost.onMainLoop(limit: 90) { () -> Seen in
            let rig = try Rig()
            defer { rig.stop() }
            rig.take(names[0], at: Date())
            let first = (rig.store.copies.schedule.failureWords, rig.store.copies.schedule.keyMissing,
                         rig.store.copies.keyCause != nil)
            rig.store.copies.accessKey = { _ in Self.key }
            rig.take(names[1], at: Date().addingTimeInterval(2 * 86_400))
            return Seen(keyed: rig.confirms.map { $0["keyed"] as? Bool }, makers: rig.confirms.map { $0["maker"] as? String },
                        keyMissing: [first.1, rig.store.copies.schedule.keyMissing],
                        failures: [first.0, rig.store.copies.schedule.failureWords],
                        causes: [first.2, rig.store.copies.keyCause != nil],
                        carried: names.map { OwnerAccess.key(in: rig.folder.appendingPathComponent($0)) != nil },
                        recorded: CopyKept.keyed(fleet: Self.fleet, in: AppDefaults.store))
        }
        #expect(seen == Seen(keyed: [false, true], makers: ["mac", "mac"], keyMissing: [true, false],
                             failures: [CopySchedule.noKey, nil], causes: [true, false], carried: [false, true],
                             recorded: [names[0]: false, names[1]: true]))
    }

    /// **Save copy** (the validators' round 2, S2, S3 and S5). An automatic copy with no key sets the row's "no key"
    /// failure. Then Save copy, with no key either: its confirm says `keyed: false`, its line says so and sends him to
    /// Report a problem, and its cause is kept. Then Save copy with the key: its confirm says `keyed: true`, it is saved
    /// and confirmed, and the automatic copy's "no key" failure ends at once, since the newest copy carries the key. The
    /// bugs that it catches: Save copy that says `keyed: true` for a copy with no key; a cause that is lost; a row that
    /// still says "no key" for a day after a copy with the key.
    @Test func aSaveCopySaysWhetherItsCopyHasTheKeyAndEndsTheNoKeyLine() async throws {
        struct Saw: Sendable, Equatable {
            let keyed: [Bool?]
            let saidNoKey: Bool
            let cause: Bool
            let missingBefore: Bool
            let savedAfter: Bool
            let missingAfter: Bool
            let rowAfter: String?
            let recorded: [String: Bool]
        }
        let names = ["founderizer-\(Self.fleet)-20261125T080000Z.zip", "founderizer-\(Self.fleet)-20261125T090000Z.zip",
                     "founderizer-\(Self.fleet)-20261125T100000Z.zip"]
        let (saw, _) = try await ViewHost.onMainLoop(limit: 90) { () -> Saw in
            let rig = try Rig()
            defer { rig.stop() }
            rig.take(names[0], at: Date())
            let missingBefore = rig.store.copies.schedule.keyMissing
            let model = FleetCopyModel()
            rig.save(names[1], with: model)
            let saidNoKey = model.failure?.contains("not the key that opens your servers") == true
                && model.failure?.contains("report a problem") == true
            let cause = model.cause?.hasPrefix("The access key did not go into the copy") == true
            rig.store.copies.accessKey = { _ in Self.key }
            rig.save(names[2], with: model)
            return Saw(keyed: rig.confirms.map { $0["keyed"] as? Bool }, saidNoKey: saidNoKey, cause: cause,
                       missingBefore: missingBefore, savedAfter: model.said != nil && model.failure == nil,
                       missingAfter: rig.store.copies.schedule.keyMissing,
                       rowAfter: rig.store.copies.schedule.warning(saved: model.failure, savedAt: model.failedAt),
                       recorded: CopyKept.keyed(fleet: Self.fleet, in: AppDefaults.store))
        }
        #expect(saw == Saw(keyed: [false, false, true], saidNoKey: true, cause: true, missingBefore: true,
                           savedAfter: true, missingAfter: false, rowAfter: nil,
                           recorded: [names[0]: false, names[1]: false, names[2]: true]))
    }

    /// **Retention's read of one copy** (`FleetCopyKeeper.carriesKey`): true for a copy with the key, false for a copy on
    /// this Mac with none, and nil for an iCloud placeholder, whose bytes are not here and are never read. The bug that
    /// it catches: false for a copy whose key nobody can read, which lets the copy with the key go.
    @Test func retentionReadsAKeyOnlyFromBytesThatAreHere() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("carries-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bare = folder.appendingPathComponent("founderizer-\(Self.fleet)-20261125T080000Z.zip")
        try FileManager.default.copyItem(at: Self.fixture, to: bare)
        let keyed = try #require(OwnerAccess.withKey(bare) { _ in Self.key })
        let placeholder = folder.appendingPathComponent(".founderizer-\(Self.fleet)-20261124T080000Z.zip.icloud")
        try Data("<plist/>".utf8).write(to: placeholder)
        #expect(FleetCopyKeeper.carriesKey(keyed) == true)
        #expect(FleetCopyKeeper.carriesKey(bare) == false)
        #expect(FleetCopyKeeper.carriesKey(placeholder) == nil)
    }
}
