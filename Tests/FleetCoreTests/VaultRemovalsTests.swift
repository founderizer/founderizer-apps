import Foundation
import Testing
@testable import FleetCore

/// The record of the servers that the owner removed on this Mac (package 4 of the vault's gates). Its file here is in a
/// folder of the test, never the app's own.
struct VaultRemovalsTests {
    private let fleet = "0f1e2d3c4b5a6978"

    @Test func aRemovalIsKeptByFleetUntilAddServer() {
        var record = VaultRemovals()
        record.removed("worker-1", fleet: fleet, at: 100, unpin: true)
        record.removed("worker-2", fleet: fleet, at: 200, unpin: false)
        #expect(record.marks(fleet: fleet) == ["worker-1": .init(at: 100, unpin: true), "worker-2": .init(at: 200, unpin: false)])
        #expect(record.marks(fleet: "1122334455667788").isEmpty)
        // The central vault took the unpin: the mark stays, so the machine still gets no pin.
        record.unpinned("worker-1", fleet: fleet)
        #expect(record.marks(fleet: fleet)["worker-1"] == .init(at: 100, unpin: false))
        // Add server for each of them on this Mac: the marks go, and so does the fleet's entry.
        record.added("worker-1", fleet: fleet)
        record.added("worker-2", fleet: fleet)
        #expect(record.fleets.isEmpty)
        record.unpinned("worker-9", fleet: fleet)
        record.added("worker-9", fleet: fleet)
        #expect(record.fleets.isEmpty)
    }

    @Test func anUnpinIsDueUntilTheCentralVaultTookItAndAFailedOneWaitsTenMinutesForEver() {
        var record = VaultRemovals()
        record.removed("worker-2", fleet: fleet, at: 100, unpin: true)
        record.removed("worker-1", fleet: fleet, at: 100, unpin: true)
        record.removed("worker-3", fleet: fleet, at: 100, unpin: false)
        #expect(record.unpinsDue(fleet: fleet, tries: [:], now: 200) == ["worker-1", "worker-2"])
        let failed = VaultTries.failed(after: nil, at: 200, reason: "The hub has not answered.")
        #expect(record.unpinsDue(fleet: fleet, tries: ["worker-1": failed], now: 799) == ["worker-2"])
        #expect(record.unpinsDue(fleet: fleet, tries: ["worker-1": failed], now: 800) == ["worker-1", "worker-2"])
        let sixth = (2...6).reduce(failed) { tries, n in VaultTries.failed(after: tries, at: 200 + Double(n) * 600, reason: "\(n)") }
        #expect(sixth.givenUp && record.unpinsDue(fleet: fleet, tries: ["worker-1": sixth], now: sixth.last + 600).contains("worker-1"))
        record.unpinned("worker-1", fleet: fleet)
        record.unpinned("worker-2", fleet: fleet)
        #expect(record.unpinsDue(fleet: fleet, tries: [:], now: 10_000).isEmpty)
        #expect(record.unpinsDue(fleet: "1122334455667788", tries: [:], now: 10_000).isEmpty)
    }

    @Test func theFileKeepsTheRecordAndAFileThatCannotBeReadIsTheRecordOfANewMac() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vault-removals-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Founderizer/vault-removals.json")
        #expect(VaultRemovals.load(file) == VaultRemovals())
        var record = VaultRemovals()
        record.removed("worker-1", fleet: fleet, at: 1_794_650_000, unpin: true)
        try record.save(file)
        #expect(VaultRemovals.load(file) == record)
        try Data("not json".utf8).write(to: file)
        #expect(VaultRemovals.load(file) == VaultRemovals())
        #expect(VaultRemovals.file.path.hasSuffix("/Application Support/Founderizer/vault-removals.json"))
    }
}
