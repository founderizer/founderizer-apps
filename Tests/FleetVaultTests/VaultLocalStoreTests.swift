import FleetVaultIPC
import Foundation
import Testing
@testable import FleetVaultCore

/// The fleet's own store on a Mac, against the **real** `age`: the cipher is age's own, and these checks are about
/// the format, the key, the locking and what never stands in the file.
///
/// `age` and `age-keygen` come from the vault's own build cache (`python3 Vault/build.py` puts them there), from
/// an installed Fleet Vault, or from the PATH. Without one of those there is nothing to lock with, and the suite says
/// so instead of proving the store against a stand-in.
/// Serialized: each check spawns the real `age`, and a suite of them at once starves the checks that run a `curl`
/// child against a local service of their own.
@Suite(.serialized) struct VaultLocalStoreTests {
    static let password = "SYNTHETIC-PASSWORD-0123456789"
    static let seed = "SYNTHETICSEEDAAAAAAAAAAAAAAAAAAA"

    /// The folder of the two programs, found once for the whole suite: copying them and making a key for each test
    /// would cost more than the checks themselves.
    static func programs() throws -> URL {
        guard let found = ageTools else {
            Issue.record("No age and age-keygen found. Run `python3 Vault/build.py` or install age.")
            throw VaultFailure.dependency
        }
        return found.programs
    }

    static func temporary() throws -> URL {
        let folder = StoreTestFolder.url.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder
    }

    /// One store with a key of its own: what the helper has, without its Keychain. Every store has its own file, so
    /// no two checks meet; the suite's one key stands for the Keychain's.
    static func store(in folder: URL? = nil, programs: URL? = nil, key: Data? = nil) throws -> (store: VaultLocalStore, file: URL, programs: URL, key: Data) {
        let programs = try programs ?? Self.programs()
        let key = try key ?? #require(ageTools).key
        let file = (try folder ?? temporary()).appendingPathComponent("store.age")
        return (try VaultLocalStore(identity: key, programs: programs, file: file), file, programs, key)
    }

    static func login(user: String = "owner@example.test", url: String = "https://shop.example.test", totp: String? = nil) -> String {
        var object: [String: Any] = ["username": user, "password": password, "url": url]
        if let totp { object["totp"] = totp }
        return String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    // MARK: the format and the key

    @Test func aNewStoreIsAnEmptyLockedFileOfThisFormat() throws {
        let made = try Self.store()
        #expect(try made.store.opened().isEmpty)
        let text = try String(contentsOf: made.file, encoding: .utf8)
        #expect(text.hasPrefix(VaultLocalStore.armour))
        var info = stat()
        #expect(lstat(made.file.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        // The same shape as `vault.py`'s store: version 1 and one item for each reference.
        let plain = try VaultPrograms(directory: made.programs).run("age", arguments: ["--decrypt", "--identity", "/dev/fd/3"],
                                                                    input: Data(text.utf8), identity: made.key)
        let object = try #require(try JSONSerialization.jsonObject(with: plain) as? [String: Any])
        #expect(object["v"] as? Int == 1)
        #expect((object["items"] as? [String: Any])?.isEmpty == true)
    }

    @Test func aSecondStoreOfTheSameKeyKeepsTheItemsAndTheStoreIsNotRemade() throws {
        let made = try Self.store()
        let id = try made.store.add(name: "Shop admin", value: Self.login(), note: "")
        let again = try VaultLocalStore(identity: made.key, programs: made.programs, file: made.file)
        #expect(try again.opened().keys.sorted() == [id])
        #expect(try again.item(id: id).key == "Shop admin")
        #expect(try again.login(secretID: id.uppercased()).label == "Shop admin")
    }

    @Test func oneStoreKeyDoesNotOpenAnotherStore() throws {
        let made = try Self.store()
        _ = try made.store.add(name: "Shop admin", value: Self.login(), note: "")
        let other = try VaultPrograms(directory: made.programs).run("age-keygen", arguments: [])     // a second key
        #expect(throws: VaultFailure.store) { try VaultLocalStore(identity: other, programs: made.programs, file: made.file) }
    }

    @Test func aStoreThatIsNotALockedFileIsRefused() throws {
        let made = try Self.store()
        for text in ["{\"v\": 1, \"items\": {}}", "", "-----BEGIN AGE ENCRYPTED FILE-----\nnot a store\n"] {
            try Data(text.utf8).write(to: made.file)
            #expect(throws: (any Error).self) { try made.store.opened() }
        }
    }

    /// The hub names a reference and the store answers; an item of another shape is not read as a login.
    @Test func anItemOfAnotherShapeIsNotALogin() throws {
        let made = try Self.store()
        let id = try made.store.add(name: "Not a login", value: "{\"note\": \"nothing\"}", note: "")
        #expect(throws: (any Error).self) { try made.store.login(secretID: id) }
        #expect(throws: VaultFailure.storeMissing) { try made.store.item(id: UUID().uuidString) }
        #expect(throws: VaultFailure.storeMissing) { try made.store.item(id: "not-a-uuid") }
    }

    /// A delivery (`deposit`) keeps the id that the secret has in the owner's vault, so one reference names one value
    /// in every vault of the fleet: the same value again is the same save, and another value is refused.
    @Test func aDeliveryKeepsItsReferenceOnceAndAnotherValueIsRefused() throws {
        let made = try Self.store()
        let id = "ABCDEF12-1234-1234-1234-123456789012", value = #"{"password":"\#(Self.password)"}"#
        #expect(try made.store.put(id: id, name: "OPENAI_API_KEY", value: value, note: "delivered from the owner's vault") == "new")
        #expect(try made.store.item(id: id).key == "OPENAI_API_KEY")
        #expect(try made.store.secret(id: id.lowercased()).password == Self.password)
        // The same value in another spelling is the same save, and changes nothing.
        let before = try Data(contentsOf: made.file)
        #expect(try made.store.put(id: id.lowercased(), name: "OPENAI_API_KEY", value: #"{ "password" : "\#(Self.password)" }"#, note: "") == "same")
        #expect(try Data(contentsOf: made.file) == before)
        #expect(throws: VaultFailure.storeOther) {
            try made.store.put(id: id, name: "OPENAI_API_KEY", value: #"{"password":"ANOTHER-SYNTHETIC-VALUE-01"}"#, note: "")
        }
        #expect(try made.store.secret(id: id).password == Self.password)
        #expect(throws: VaultFailure.store) { try made.store.put(id: "not-a-uuid", name: "OPENAI_API_KEY", value: value, note: "") }
        #expect(throws: VaultFailure.store) { try made.store.put(id: UUID().uuidString, name: " padded", value: value, note: "") }
        #expect(!(try String(contentsOf: made.file, encoding: .utf8)).contains(Self.password))
    }

    /// The owner replaced the value of a reference: a delivery that the hub marks so puts the new value in the place
    /// of the one that an earlier delivery saved, and of nothing else (`vault.py`'s `put`).
    @Test func aReplaceGoesOnlyOverAValueThatADeliverySaved() throws {
        let made = try Self.store()
        let id = "ABCDEF12-1234-1234-1234-123456789012", value = #"{"password":"\#(Self.password)"}"#
        let new = #"{"password":"THE-NEW-SYNTHETIC-VALUE-01"}"#
        #expect(try made.store.put(id: id, name: "OPENAI_API_KEY", value: value, note: VaultLocalStore.delivered) == "new")
        #expect(try made.store.put(id: id, name: "OPENAI_API_KEY", value: new, note: VaultLocalStore.delivered, replace: true) == "replaced")
        #expect(try made.store.secret(id: id).password == "THE-NEW-SYNTHETIC-VALUE-01")
        #expect(try made.store.opened().count == 1)
        #expect(try made.store.item(id: id).note == VaultLocalStore.delivered)
        #expect(!String(describing: try made.store.opened()).contains(Self.password))       // the old value left the store
        #expect(try made.store.put(id: id, name: "OPENAI_API_KEY", value: new, note: VaultLocalStore.delivered, replace: true) == "same")
        // with the word of a replace, a reference that the store does not hold is a new save
        #expect(try made.store.put(id: UUID().uuidString, name: "OTHER_API_KEY", value: #"{"password":"A-THIRD-SYNTHETIC-VALUE-01"}"#,
                                   note: VaultLocalStore.delivered, replace: true) == "new")
        // the owner's own item, and one that this vault made, are not a delivery's to change
        let own = try made.store.add(name: "Shop admin", value: Self.login(), note: "owner's own")
        let mine = try made.store.add(name: "Made here", value: Self.login(user: "agent@example.test"), note: "fleet-create:studio:1")
        for kept in [own, mine] {
            #expect(throws: VaultFailure.storeNotDelivered) {
                try made.store.put(id: kept, name: "Shop admin", value: new, note: VaultLocalStore.delivered, replace: true)
            }
        }
        #expect(try made.store.item(id: own).note == "owner's own")
        // another store of the same key reads the new value: the replace was saved
        let again = try VaultLocalStore(identity: made.key, programs: made.programs, file: made.file)
        #expect(try again.secret(id: id).password == "THE-NEW-SYNTHETIC-VALUE-01")
    }

    /// A withdrawal takes out only what a delivery saved: the owner's own item, and one that this vault made, stay.
    /// The same withdrawal again finds nothing and changes nothing (`vault.py`'s `remove`).
    @Test func aWithdrawalRemovesOnlyADeliveredItemAndOnlyOnce() throws {
        let made = try Self.store()
        let id = "ABCDEF12-1234-1234-1234-123456789012", value = #"{"password":"\#(Self.password)"}"#
        #expect(try made.store.put(id: id, name: "OPENAI_API_KEY", value: value, note: VaultLocalStore.delivered) == "new")
        let own = try made.store.add(name: "Shop admin", value: Self.login(), note: "owner's own")
        let mine = try made.store.add(name: "Made here", value: Self.login(user: "agent@example.test"), note: "fleet-create:studio:1")
        for kept in [own, mine] {
            #expect(throws: VaultFailure.withdrawNotDelivered) { try made.store.remove(id: kept, note: VaultLocalStore.delivered) }
        }
        #expect(try made.store.remove(id: id, note: VaultLocalStore.delivered) == "removed")
        #expect(try made.store.opened().keys.sorted() == [own, mine].sorted())
        let after = try Data(contentsOf: made.file)
        #expect(try made.store.remove(id: id.lowercased(), note: VaultLocalStore.delivered) == "absent")
        #expect(try Data(contentsOf: made.file) == after)
        #expect(throws: VaultFailure.store) { try made.store.remove(id: "not-a-uuid", note: VaultLocalStore.delivered) }
        // Another store of the same key reads what is left: the removal was saved.
        let again = try VaultLocalStore(identity: made.key, programs: made.programs, file: made.file)
        #expect(throws: VaultFailure.storeMissing) { try again.item(id: id) }
        #expect(try again.item(id: own).key == "Shop admin")
    }

    // MARK: what never stands in the file

    @Test func theLockedStoreHoldsNoValueOfItsItems() throws {
        let made = try Self.store()
        _ = try made.store.add(name: "Shop admin", value: Self.login(totp: Self.seed), note: "owner's own")
        let text = try String(contentsOf: made.file, encoding: .utf8)
        #expect(!text.contains(Self.password))
        #expect(!text.contains(Self.seed))
        #expect(!text.contains("shop.example.test"))
        #expect(!text.contains("Shop admin"))
    }

    /// The check that a save makes, as a handover makes it: an `age` that does not lock writes nothing.
    @Test func anAgeThatDoesNotLockMakesTheStoreWriteNothing() throws {
        let made = try Self.store()
        _ = try made.store.add(name: "Shop admin", value: Self.login(), note: "")
        let before = try Data(contentsOf: made.file)
        // A program that answers with the armour line and the plain text inside it.
        let broken = try Self.temporary()
        try FileManager.default.copyItem(at: made.programs.appendingPathComponent("age-keygen"),
                                         to: broken.appendingPathComponent("age-keygen"))
        let script = "#!/bin/sh\nprintf '%s\\n' '\(VaultLocalStore.armour)'\ncat\n"
        try Data(script.utf8).write(to: broken.appendingPathComponent("age"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: broken.appendingPathComponent("age").path)
        // The store cannot even be opened by that program, so nothing of it is written either.
        #expect(throws: (any Error).self) { try VaultLocalStore(identity: made.key, programs: broken, file: made.file) }
        #expect(try Data(contentsOf: made.file) == before)
    }

    @Test func aStoreThatAnotherUserCouldWriteIsRefused() throws {
        let made = try Self.store()
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: made.file.path)
        #expect(throws: VaultFailure.store) { try made.store.opened() }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: made.file.path)
        #expect(try made.store.opened().isEmpty)
    }

    @Test func aSaveLeavesOneFileAndOneLockAndNoHalfWrittenStore() throws {
        let folder = try Self.temporary()
        let made = try Self.store(in: folder)
        _ = try made.store.add(name: "Shop admin", value: Self.login(), note: "")
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(left == ["store.age", "store.age.lock"])
    }

    // MARK: the operations of the broker

    @Test func aProbeSaysReadableOnlyForAnItemThatThisStoreHolds() throws {
        let made = try Self.store()
        let login = try made.store.add(name: "Shop admin", value: Self.login(), note: "")
        let broken = try made.store.add(name: "Not a login", value: "{}", note: "")
        let missing = UUID().uuidString.lowercased()
        let job = try VaultProbeJob(data: JSONSerialization.data(withJSONObject: [
            "ok": true, "kind": "probe", "job": 7,
            "logins": ["bws://" + login, "bws://" + broken, "bws://" + missing]]),
            request: try VaultRequest(data: Data("{\"v\":2,\"op\":\"probe\",\"job\":7}\n".utf8)))
        let results = made.store.probe(job: job)
        #expect(results.map(\.reason) == [.ok, .bad_format, .not_found])
        #expect(results.map(\.state) == ["readable", "not_readable", "not_readable"])
        // No part of a login leaves the helper.
        let text = String(decoding: try JSONEncoder().encode(results), as: UTF8.self)
        #expect(!text.contains(Self.password))
        #expect(!text.contains("Shop admin"))
    }

    @Test func aSessionReadsTheValueOfAnApiKeyOfThisStore() throws {
        let made = try Self.store()
        let value = String(decoding: try JSONSerialization.data(withJSONObject: ["password": Self.password]), as: UTF8.self)
        let id = try made.store.add(name: "SHOP_LEGACY_DB", value: value, note: "")
        #expect(try made.store.secret(id: id).password == Self.password)
        #expect(throws: (any Error).self) { try made.store.secret(id: UUID().uuidString) }
    }

    // MARK: what a writer asks of a store (`create_login` and `save_key`)

    @Test func theStoreIsOnePlaceAndNamesNoProject() throws {
        let made = try Self.store()
        #expect(try made.store.organization(ofProject: VaultLocalStore.place) == VaultLocalStore.place)
        #expect(throws: VaultFailure.store) { try made.store.organization(ofProject: UUID().uuidString) }
        #expect(made.store.create(name: "Shop admin", value: Self.login(), note: "m",
                                  project: UUID().uuidString, organization: "x") == .refused)
    }

    @Test func aWriterFindsItsOwnItemAgainByItsNameAndItsMark() throws {
        let made = try Self.store()
        guard case let .created(id) = made.store.create(name: "Shop admin", value: Self.login(), note: "fleet:1",
                                                        project: VaultLocalStore.place, organization: VaultLocalStore.place) else {
            Issue.record("the store made no item"); return
        }
        #expect(try made.store.items(named: "Shop admin", project: VaultLocalStore.place, organization: VaultLocalStore.place) == [id])
        #expect(try made.store.notes(of: [id]) == [id: "fleet:1"])
        #expect(try made.store.items(named: "Another", project: VaultLocalStore.place, organization: VaultLocalStore.place).isEmpty)
    }

    /// The writer's own journal decides whether a request makes an item; the store is what it saves into. One save,
    /// one reference, and the reference is what the hub registers.
    @Test func aSaveOfAJobMakesOneItemOfThisStore() async throws {
        let made = try Self.store()
        let store = made.store
        let journal = MemoryJournal()
        let writer = try VaultWriter(store: journal, limit: 1_048_576) { (store, VaultLocalStore.place) }
        let request = UUID().uuidString.lowercased()
        let creation = VaultCreation(requestID: request, db: "g1", agent: "studio", task: "T-7", attempt: 1, project: nil,
                                     label: "Shop admin", username: "owner@example.test", url: "https://shop.example.test")
        let mark = VaultCreateJob.mark(agent: "studio", requestID: request)
        func save() async throws -> VaultWriteRecord {
            try await writer.create(requestID: request, binding: creation.binding, title: creation.label, hub: "http://100.96.10.20:8765",
                                    db: creation.db, mark: mark) { Data(Self.login().utf8) }
        }
        let record = try await save()
        #expect(record.state == .created)
        let reference = try #require(record.login)
        let item = try store.item(id: String(reference.dropFirst(6)))
        #expect(item.key == "Shop admin" && item.note == mark)
        // The same request again makes no second item.
        let again = try await save()
        #expect(again.login == reference)
        #expect(try store.opened().count == 1)
        // The fingerprints come from the store's own item, and are not the value.
        let salts = ["password": String(repeating: "a", count: 32), "totp": String(repeating: "b", count: 32)]
        let prints = try await writer.fingerprints(requestID: request, salts: salts)
        #expect(prints.login == reference)
        #expect(prints.items.map(\.kind) == ["password"])
        #expect(prints.items.allSatisfy { $0.hash.count == 64 && $0.len == Self.password.count })
        #expect(!String(decoding: try JSONEncoder().encode(prints.items), as: UTF8.self).contains(Self.password))
        // No record and no journal holds a value.
        #expect(!String(decoding: journal.data ?? Data(), as: UTF8.self).contains(Self.password))
    }

    // MARK: the words of this store

    /// The broker opens only the fleet's own store, so each fixed outcome of a save is in that store's words: the words
    /// that a Mac with this store gave already, so the answers of the live Mac do not change. The two outcomes of a save
    /// are the Linux broker's words for its store too.
    @Test func everyFixedOutcomeIsSaidInTheWordsOfThisStore() {
        #expect(VaultFailure.creates.rawValue == "This machine's vault has no store of its own yet.")
        #expect(VaultFailure.saveRefused.rawValue == "The vault store refused this save and made nothing.")
        #expect(VaultFailure.saveUnknown.rawValue == "The vault could not confirm that its store saved the login. It is not sent again.")
        #expect(VaultWriteRefusal.setup.rawValue == VaultFailure.creates.rawValue)
        #expect(VaultWriteRefusal.provider.rawValue == "The vault store could not be opened for a save. Nothing was made.")
        #expect(VaultWriteRefusal.check.rawValue == "The vault store did not answer the check. Nothing changed.")
    }

    // MARK: `store-put`: the item that the owner gives this store

    /// The stored text holds the item's known fields and nothing else of what came in, as `vault.py store_item`
    /// reads it: a login with an address, or a key that a session reads without one.
    @Test func theStoredItemHoldsItsKnownFieldsAndNothingElse() throws {
        let login = try VaultStoreCommand.canonical(Data("""
            {"username": "owner@example.test", "password": "\(Self.password)", "url": "https://shop.example.test",
             "totp": "\(Self.seed)", "note": "dropped", "id": 7}
            """.utf8), label: "Shop admin")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(login.utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["username", "password", "url", "totp"])
        // An API key needs no address, and a login with no user name keeps an empty one.
        let key = try VaultStoreCommand.canonical(Data("{\"password\": \"\(Self.password)\"}".utf8), label: "A key")
        #expect(try JSONSerialization.jsonObject(with: Data(key.utf8)) as? [String: String] == ["password": Self.password])
        let anonymous = try VaultStoreCommand.canonical(Data("{\"password\": \"\(Self.password)\", \"url\": \"https://a.example.test\"}".utf8),
                                                        label: "A key with an address")
        #expect((try JSONSerialization.jsonObject(with: Data(anonymous.utf8)) as? [String: String])?["username"] == "")
        // What is not an item of ours is not saved.
        for bad in ["{}", "{\"password\": \"\"}", "[]", "not json", "{\"password\": \"\(Self.password)\", \"url\": \"ftp://a.test\"}"] {
            #expect(throws: VaultFailure.login) { try VaultStoreCommand.canonical(Data(bad.utf8), label: "x") }
        }
    }

    @Test func aStoreGivesItsNamesAndDatesAndNeverAValue() throws {
        let made = try Self.store()
        let first = try made.store.add(name: "Shop admin", value: Self.login(), note: "")
        let second = try made.store.add(name: "SHOP_LEGACY_DB", value: "{\"password\": \"\(Self.password)\"}", note: "")
        let listing = try made.store.listing()
        #expect(listing.map(\.login) == ["bws://" + first, "bws://" + second])
        #expect(listing.map(\.title) == ["Shop admin", "SHOP_LEGACY_DB"])
        #expect(listing.allSatisfy { $0.savedAt > 1_700_000_000 })
    }

    // MARK: the configuration of the store

    /// The configuration that `install.py` writes for a worker Mac, in the bytes that its `json.dump` writes, loads as
    /// before. So a Mac that opens this store now keeps its configuration, and with it its Keychain items.
    @Test func theConfigurationThatTheInstallerWritesLoadsAsBefore() throws {
        let socket = NSHomeDirectory() + "/Library/Application Support/AgentFleet/vault.sock"
        let written = #"{"agent": "studio", "hub": "http://100.96.10.20:8765", "store": "fleet", "worker_uid": 501, "socket": "\#(socket)"}"#
        let configuration = try VaultConfiguration(data: Data(written.utf8))
        #expect(configuration.agent == "studio" && configuration.store == VaultBackend.fleetStore && configuration.workerUID == 501)
        #expect(configuration.hub.absoluteString == "http://100.96.10.20:8765" && configuration.socket == socket)
    }

    /// A configuration names the fleet's own store and nothing else. A worker's configuration that names a region, of
    /// the store that this vault opened before, has its own refusal, which says what to do; so the broker does not start
    /// on it. The owner's Mac has its own form, and no broker.
    @Test func aConfigurationNamesTheFleetsOwnStoreOnly() throws {
        let socket = NSHomeDirectory() + "/Library/Application Support/AgentFleet/vault.sock"
        func configuration(_ object: [String: Any]) throws -> VaultConfiguration {
            try VaultConfiguration(data: try JSONSerialization.data(withJSONObject: object))
        }
        let base: [String: Any] = ["agent": "studio", "hub": "http://100.96.10.20:8765", "socket": socket, "worker_uid": 501]
        #expect(try configuration(base.merging(["store": "fleet"]) { _, new in new }).store == "fleet")
        for old in [base.merging(["region": "eu"]) { _, new in new }, base.merging(["region": "us", "store": "fleet"]) { _, new in new },
                    base.merging(["region": NSNull()]) { _, new in new }, ["region": "eu"]] {
            #expect(throws: VaultFailure.regionConfiguration) { try configuration(old) }
        }
        let owner: [String: Any] = ["role": "owner", "fleet_app": "/Applications/Founderizer.app", "owner_uid": 501]
        for bad in [base, base.merging(["store": "other"]) { _, new in new }, base.merging(["store": "fleet", "role": "worker"]) { _, new in new },
                    owner.merging(["region": "eu"]) { _, new in new }, owner.merging(["store": "fleet"]) { _, new in new }] {
            #expect(throws: VaultFailure.configuration) { try configuration(bad) }
        }
    }

    // MARK: the items of the store that this vault opened before

    /// The cleanup deletes the old items by their names, each one once, and it has no way to read one. None of the
    /// names is an item of the fleet's own store, so the store key, the handover key and the two journals stay.
    @Test func theCleanupDeletesOnlyTheOldItemsAndReadsNone() {
        let kept = [VaultLocalStore.keyItem, "age", VaultJournalKeychain(keychain: VaultKeychain(agent: "studio")).item, "calls"]
        #expect(VaultOldItems.workerItems == ["token", "write-project"])
        #expect(VaultOldItems.writerAccount == "_writer" && VaultOldItems.writerItems == ["token", "project"])
        #expect(Set(VaultOldItems.workerItems).isDisjoint(with: kept))
        #expect(!VaultCaller.isAgent(VaultOldItems.writerAccount))         // no agent's item has the writer's account
        var asked: [String] = []
        let gone = VaultOldItems.remove(VaultOldItems.workerItems) { asked.append($0) }
        #expect(gone && asked == ["token", "write-project"])
        // A delete that fails makes the answer false, and the next item is still deleted: the next start tries again.
        asked = []
        let failed = VaultOldItems.remove(VaultOldItems.writerItems) { item in
            asked.append(item)
            if item == "token" { throw VaultFailure.keychain }
        }
        #expect(!failed && asked == ["token", "project"])
    }

    @Test func onlyTheOwnersConfigurationMakesTheOwnersMac() {
        for owner in [#"{"role": "owner", "region": "eu", "fleet_app": "/Applications/Founderizer.app", "owner_uid": 501}"#,
                      #"{"role": "owner", "store": "fleet", "fleet_app": "/Applications/Founderizer.app", "owner_uid": 501}"#] {
            #expect(VaultOldItems.isOwner(Data(owner.utf8)))
        }
        for other in [#"{"agent": "studio", "hub": "http://100.96.10.20:8765", "store": "fleet"}"#, #"{"role": "worker"}"#,
                      #"{"role": 1}"#, "[]", "not json"] {
            #expect(!VaultOldItems.isOwner(Data(other.utf8)))
        }
    }
}

/// The one folder of this suite's files in a test process: a folder for each store, and the copy of the two programs.
/// It goes when the process ends, so a run that passes leaves nothing in the temporary folder. Until 11 November 2026
/// each store's folder stayed there, and each run's copy of `age` and `age-keygen` (1.4 MB): 5,000 folders and 390 MB
/// on the owner's Mac, which macOS empties of their files only after three days.
enum StoreTestFolder {
    static let url: URL = {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fleet-store-tests-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        atexit { StoreTestFolder.remove() }
        return folder
    }()

    static func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// The programs and the one key of this suite, made at the first check that needs them. The programs come from the
/// vault's own build cache, from an installed Fleet Vault, or from the PATH.
let ageTools: (programs: URL, key: Data)? = {
    let places = [URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                    .deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("build/vault-dependencies/age"),
                  URL(fileURLWithPath: "/Applications/Fleet Vault.app/Contents/Helpers"),
                  URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/local/bin")]
    guard let found = places.first(where: { place in
        ["age", "age-keygen"].allSatisfy { FileManager.default.isExecutableFile(atPath: place.appendingPathComponent($0).path) }
    }) else { return nil }
    // A copy of its own, because `VaultPrograms` reads the two names of that folder and nothing else of it.
    let folder = StoreTestFolder.url.appendingPathComponent("age")
    guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])) != nil else { return nil }
    for name in ["age", "age-keygen"] {
        guard (try? FileManager.default.copyItem(at: found.appendingPathComponent(name),
                                                  to: folder.appendingPathComponent(name))) != nil else { return nil }
    }
    guard let key = try? VaultPrograms(directory: folder).run("age-keygen", arguments: []) else { return nil }
    return (folder, key)
}()

/// A journal in memory: the writer's records, without the helper's Keychain.
final class MemoryJournal: VaultJournalStore, @unchecked Sendable {
    private let lock = NSLock()
    private var kept: Data?
    var data: Data? { lock.withLock { kept } }
    func load(limit: Int) throws -> Data? { lock.withLock { kept } }
    func save(_ data: Data) throws { lock.withLock { kept = data } }
}
