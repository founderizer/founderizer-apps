import Foundation
import Security
import Testing
@testable import FleetVaultCore

/// A stand-in for the Keychain: items by service and account, a failure that each call answers (a Keychain before its
/// first unlock), and one write or delete that fails (a move that stops at that step). No real Keychain is used, and no
/// older build of Fleet Vault runs.
final class StandInKeychain: VaultKeychainBackend, @unchecked Sendable {
    /// A lock file of this stand-in's own, in the temporary folder: no test reads or writes the home folder.
    let lockFile = FileManager.default.temporaryDirectory.appendingPathComponent("key-move-\(UUID().uuidString).lock")
    deinit { try? FileManager.default.removeItem(at: lockFile) }
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var writes = 0
    var failing: OSStatus?
    var failAt: Int?
    /// After the write that `failAt` stops, each call fails too, as a Keychain that went away in the middle.
    var failsAfterStop = false

    private func key(_ service: String, _ account: String) -> String { service + "|" + account }
    private func stops() -> Bool {
        writes += 1
        if writes == failAt && failsAfterStop { failing = errSecInteractionNotAllowed }
        return writes == failAt
    }

    func read(service: String, account: String) -> (OSStatus, Data?) {
        lock.withLock {
            if let failing { return (failing, nil) }
            guard let data = items[key(service, account)] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, data)
        }
    }
    func add(service: String, account: String, data: Data) -> OSStatus {
        lock.withLock {
            if let failing { return failing }
            if stops() { return errSecIO }
            if items[key(service, account)] != nil { return errSecDuplicateItem }
            items[key(service, account)] = data
            return errSecSuccess
        }
    }
    func update(service: String, account: String, data: Data) -> OSStatus {
        lock.withLock {
            if let failing { return failing }
            if stops() { return errSecIO }
            guard items[key(service, account)] != nil else { return errSecItemNotFound }
            items[key(service, account)] = data
            return errSecSuccess
        }
    }
    func delete(service: String, account: String) -> OSStatus {
        lock.withLock {
            if let failing { return failing }
            if stops() { return errSecIO }
            return items.removeValue(forKey: key(service, account)) == nil ? errSecItemNotFound : errSecSuccess
        }
    }

    func value(_ service: String, _ account: String) -> Data? { lock.withLock { items[key(service, account)] } }
    func set(_ service: String, _ account: String, _ data: Data) { lock.withLock { items[key(service, account)] = data } }
    func resetCount() { lock.withLock { writes = 0 } }
}

/// Package 7 (C23): a build reads only the Keychain names of its own key generation, and its first start moves the
/// keys there: copy, prove by bytes, mark, remove (`VaultKeyMove`).
@Suite(.serialized) struct VaultKeyMoveTests {
    private let one = VaultKeychain.service(1), two = VaultKeychain.service(2)
    private let keys: [String: Data] = [
        "store": Data("AGE-SECRET-KEY-1EXAMPLESTOREKEY\n".utf8),
        "age": Data("# public key: age1exampleexampleexample\nAGE-SECRET-KEY-1EXAMPLEHANDOVER\n".utf8),
        "writes": Data(#"{"v":1,"records":[]}"#.utf8), "calls": Data(#"{"v":1,"calls":[]}"#.utf8)]

    /// A Mac of builds 1 to 14: its four items under the service of generation 1.
    private func olderMac(_ agent: String = "studio") -> StandInKeychain {
        let keychain = StandInKeychain()
        for (item, data) in keys { keychain.set(one, "\(agent).\(item)", data) }
        return keychain
    }

    @Test func theNamesOfEachGenerationAreConstants() {
        #expect(VaultSystemKeychain().lockFile.lastPathComponent == "keys.lock")
        #expect(VaultKeychain.service(1) == "local.agent-fleet.vault")          // builds 1 to 14
        #expect(VaultKeychain.service(2) == "local.agent-fleet.vault.2" && VaultKeychain.generation == 2)
        #expect(VaultKeyMove.items == ["store", "age", "writes", "calls"])
    }

    @Test func theMoveCopiesProvesMarksAndOnlyThenRemoves() throws {
        let keychain = olderMac()
        try VaultKeyMove.move(agent: "studio", backend: keychain, generation: 2)
        for (item, data) in keys {
            #expect(keychain.value(two, "studio.\(item)") == data, "\(item)")
            #expect(keychain.value(one, "studio.\(item)") == nil, "\(item)")
        }
        #expect(keychain.value(two, "studio.moved") != nil)
        // A build of generation 1 now finds no key. One of generation 2 reads the same bytes, so the handover key has
        // the same public half and the hub's pinned key does not change.
        let older = VaultKeychain(agent: "studio", generation: 1, backend: keychain, guarded: false)
        #expect(try older.raw("store") == nil && older.raw("age") == nil)
        VaultKeyMove.forget()
        #expect(try VaultKeychain(agent: "studio", generation: 2, backend: keychain, guarded: true).read("age") == keys["age"])
    }

    @Test func aMoveThatStopsAtAnyStepGoesOnAtTheNextStartAndLosesNoKey() throws {
        for step in 1...12 {
            let keychain = olderMac()
            keychain.failAt = step
            _ = try? VaultKeyMove.move(agent: "studio", backend: keychain, generation: 2)
            for (item, data) in keys {          // at each moment, each key is whole under one of the two services
                #expect(keychain.value(one, "studio.\(item)") == data || keychain.value(two, "studio.\(item)") == data,
                        "step \(step): \(item)")
            }
            keychain.failAt = nil
            try VaultKeyMove.move(agent: "studio", backend: keychain, generation: 2)
            for (item, data) in keys {
                #expect(keychain.value(two, "studio.\(item)") == data && keychain.value(one, "studio.\(item)") == nil,
                        "step \(step): \(item)")
            }
        }
    }

    @Test func aKeyThatAnOlderBuildMakesAfterTheMoveIsNeverTakenAndItGoes() throws {
        let keychain = olderMac()
        try VaultKeyMove.move(agent: "studio", backend: keychain, generation: 2)
        // an older build started after the move: it found no key under its own name and made new ones there
        keychain.set(one, "studio.store", Data("AGE-SECRET-KEY-1EXAMPLEOLDERBUILD\n".utf8))
        keychain.set(one, "studio.age", Data("AGE-SECRET-KEY-1EXAMPLEOLDERHANDOVER\n".utf8))
        try VaultKeyMove.move(agent: "studio", backend: keychain, generation: 2)          // this build's next start
        #expect(keychain.value(two, "studio.store") == keys["store"] && keychain.value(two, "studio.age") == keys["age"])
        #expect(keychain.value(one, "studio.store") == nil && keychain.value(one, "studio.age") == nil)
    }

    @Test func aKeychainThatGivesAnotherAnswerStopsTheMoveAndNoKeyIsMade() throws {
        let keychain = olderMac()
        keychain.failing = errSecInteractionNotAllowed                  // before the first unlock after a restart
        #expect(throws: VaultFailure.keychain) { try VaultKeyMove.move(agent: "studio", backend: keychain, generation: 2) }
        keychain.failing = nil
        #expect(keychain.value(two, "studio.moved") == nil && keychain.value(two, "studio.store") == nil)   // no copy, no marker
        for (item, data) in keys { #expect(keychain.value(one, "studio.\(item)") == data, "\(item)") }
        // A key's use waits too: while the Keychain fails, nothing reads or makes a key of this generation.
        VaultKeyMove.forget()
        keychain.failing = errSecInteractionNotAllowed
        let current = VaultKeychain(agent: "studio", generation: 2, backend: keychain, guarded: true)
        #expect(throws: VaultFailure.keychain) { try current.readIfPresent("store") }
        #expect(throws: VaultFailure.keychain) { try current.create(Data("AGE-SECRET-KEY-1EXAMPLENEW\n".utf8), item: "store") }
        keychain.failing = nil
        #expect(keychain.value(two, "studio.store") == nil && keychain.value(one, "studio.store") == keys["store"])
        // when the Keychain answers again, the first use moves the real keys and reads them
        #expect(try current.read("store") == keys["store"])
    }

    @Test func aNewMacGetsItsKeysUnderItsOwnGenerationOnly() throws {
        let keychain = StandInKeychain()
        VaultKeyMove.forget()
        let current = VaultKeychain(agent: "fresh", generation: 2, backend: keychain, guarded: true)
        #expect(try current.readIfPresent("store") == nil)                // nothing to move: the marker alone
        #expect(keychain.value(two, "fresh.moved") != nil)
        try current.create(Data("AGE-SECRET-KEY-1EXAMPLEFRESH\n".utf8), item: "store")
        #expect(keychain.value(two, "fresh.store") != nil && keychain.value(one, "fresh.store") == nil)
        // a new key never takes the place of a key
        #expect(throws: VaultFailure.keychain) { try current.create(Data("AGE-SECRET-KEY-1EXAMPLEOTHER\n".utf8), item: "store") }
    }

    @Test func theMoveTakesTheNewestLowerGenerationThatHasAKey() throws {
        let keychain = olderMac()                                       // generation 1, from builds 1 to 14
        try VaultKeyMove.move(agent: "studio", backend: keychain, generation: 2)
        keychain.set(one, "studio.store", Data("AGE-SECRET-KEY-1EXAMPLEJUNK\n".utf8))     // an older build's new key
        try VaultKeyMove.move(agent: "studio", backend: keychain, generation: 3)          // a later build
        let three = VaultKeychain.service(3)
        #expect(keychain.value(three, "studio.store") == keys["store"] && keychain.value(three, "studio.age") == keys["age"])
        #expect(keychain.value(two, "studio.store") == nil && keychain.value(one, "studio.store") == nil)
    }

    /// The proof is by bytes, so the move reads no store file. A store file that an agent damaged is no part of it.
    @Test func aStoreFileThatDoesNotOpenDoesNotStopTheMove() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("key-move-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("not a store".utf8).write(to: folder.appendingPathComponent("store.age"))
        let keychain = olderMac()
        try VaultKeyMove.move(agent: "studio", backend: keychain, generation: 2)
        #expect(keychain.value(two, "studio.moved") != nil && keychain.value(two, "studio.store") == keys["store"])
    }

    /// Two processes never move at once: a move takes the lock of the vault's folder and does not wait for it. While
    /// another process holds it, this one copies nothing, writes no marker and deletes nothing; then it moves.
    @Test func aMoveWhileAnotherProcessHoldsTheLockDoesNothing() throws {
        let keychain = olderMac()
        let fd = open(keychain.lockFile.path, O_CREAT | O_RDWR, 0o600)
        #expect(fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0)          // as another process of Fleet Vault would
        #expect(throws: VaultFailure.keychain) { try VaultKeyMove.move(agent: "studio", backend: keychain, generation: 2) }
        #expect(keychain.value(two, "studio.moved") == nil && keychain.value(two, "studio.store") == nil)
        for (item, data) in keys { #expect(keychain.value(one, "studio.\(item)") == data, "\(item)") }
        flock(fd, LOCK_UN); close(fd)
        try VaultKeyMove.move(agent: "studio", backend: keychain, generation: 2)
        #expect(keychain.value(two, "studio.moved") != nil && keychain.value(two, "studio.store") == keys["store"])
    }

    /// A key of the new generation is never written over with other bytes and never deleted, also by a second process
    /// that got past the lock: the move stops, and every key stays where it is.
    @Test func aMoveNeverWritesOverOrDeletesAKeyOfItsGeneration() throws {
        let other = Data("AGE-SECRET-KEY-1EXAMPLEANOTHERKEY\n".utf8)
        let keychain = olderMac()
        keychain.set(two, "studio.store", other)                       // a key under the new names, with other bytes
        #expect(throws: VaultFailure.keyMoveStopped) { try VaultKeyMove.move(agent: "studio", backend: keychain, generation: 2) }
        #expect(keychain.value(two, "studio.store") == other && keychain.value(two, "studio.moved") == nil)
        for (item, data) in keys { #expect(keychain.value(one, "studio.\(item)") == data, "\(item)") }
        let partial = StandInKeychain()                                 // a source that has no handover key
        partial.set(one, "studio.store", keys["store"]!)
        partial.set(two, "studio.age", keys["age"]!)
        #expect(throws: VaultFailure.keyMoveStopped) { try VaultKeyMove.move(agent: "studio", backend: partial, generation: 2) }
        #expect(partial.value(two, "studio.age") == keys["age"])        // not deleted
        // a lock file that is a link is no lock
        let linked = olderMac()
        try FileManager.default.createSymbolicLink(at: linked.lockFile, withDestinationURL: URL(fileURLWithPath: "/dev/null"))
        #expect(throws: VaultFailure.keychain) { try VaultKeyMove.move(agent: "studio", backend: linked, generation: 2) }
        #expect(linked.value(two, "studio.moved") == nil)
    }

    /// A move that fails takes back no key: each key that it copied stays under the new names with the source's bytes,
    /// and the next move ends. Of the journals, it takes back only one that it added itself.
    @Test func aFailedMoveTakesBackNoKeyAndOnlyAJournalThatItAdded() throws {
        let keychain = olderMac()
        keychain.failAt = 4              // the writes of this start: the store key (1), the handover key (2), `writes` (3)
        #expect(throws: VaultFailure.keychain) { try VaultKeyMove.move(agent: "studio", backend: keychain, generation: 2) }
        #expect(keychain.value(two, "studio.store") == keys["store"] && keychain.value(two, "studio.age") == keys["age"])
        #expect(keychain.value(two, "studio.writes") == nil)            // a journal that it added: taken back
        #expect(keychain.value(two, "studio.calls") == nil && keychain.value(two, "studio.moved") == nil)
        for (item, data) in keys { #expect(keychain.value(one, "studio.\(item)") == data, "\(item)") }
        try VaultKeyMove.move(agent: "studio", backend: keychain, generation: 2)        // the next start ends it
        for (item, data) in keys {
            #expect(keychain.value(two, "studio.\(item)") == data && keychain.value(one, "studio.\(item)") == nil, "\(item)")
        }
    }

    /// After a failed move, each key that it copied is still under the new names, for each step that can fail, and the
    /// next move ends.
    @Test func theKeysThatAFailedMoveCopiedStayAndTheNextMoveEnds() throws {
        for step in 1...4 {
            let keychain = olderMac()
            keychain.failAt = step
            #expect(throws: VaultFailure.keychain) { try VaultKeyMove.move(agent: "studio", backend: keychain, generation: 2) }
            for (index, item) in ["store", "age"].enumerated() where index < step - 1 {
                #expect(keychain.value(two, "studio.\(item)") == keys[item], "step \(step): \(item)")
            }
            keychain.failAt = nil
            try VaultKeyMove.move(agent: "studio", backend: keychain, generation: 2)
            #expect(keychain.value(two, "studio.moved") != nil, "step \(step)")
        }
    }

    /// After a failed copy, a marker read that fails too takes nothing back: nobody knows then whether another process
    /// finished the move with those items. The old items stay, so no key is lost.
    @Test func aFailedMoveWhoseMarkerReadFailsTakesNothingBack() throws {
        let keychain = olderMac()
        keychain.failAt = 3
        keychain.failsAfterStop = true
        #expect(throws: VaultFailure.keychain) { try VaultKeyMove.move(agent: "studio", backend: keychain, generation: 2) }
        keychain.failing = nil
        #expect(keychain.value(two, "studio.store") == keys["store"] && keychain.value(two, "studio.age") == keys["age"])
        for (item, data) in keys { #expect(keychain.value(one, "studio.\(item)") == data, "\(item)") }
        try VaultKeyMove.move(agent: "studio", backend: keychain, generation: 2)        // the next start finishes it
        for (item, data) in keys { #expect(keychain.value(two, "studio.\(item)") == data, "\(item)") }
    }

    /// A Mac whose lower generation holds only journals moves them too, and a Mac with no item at all gets the marker
    /// alone and deletes nothing.
    @Test func journalsWithNoKeyMoveAndANewMacDeletesNothing() throws {
        let keychain = StandInKeychain()
        keychain.set(one, "studio.writes", keys["writes"]!)
        try VaultKeyMove.move(agent: "studio", backend: keychain, generation: 2)
        #expect(keychain.value(two, "studio.writes") == keys["writes"] && keychain.value(one, "studio.writes") == nil)
        let fresh = StandInKeychain()
        keychain.set(one, "other.token", Data("an item of no generation's four".utf8))
        try VaultKeyMove.move(agent: "fresh", backend: fresh, generation: 2)
        #expect(fresh.value(two, "fresh.moved") != nil && keychain.value(one, "other.token") != nil)
    }

    @Test func theStatusSaysTheKeyGeneration() {
        let status = VaultBroker.status(agent: "studio", user: "sam", recipient: "age1" + String(repeating: "q", count: 58))
        #expect(status["key_generation"] as? Int == 2)
    }
}
