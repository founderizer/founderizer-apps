import FleetVaultIPC
import Foundation
import Testing
@testable import FleetVaultCore

/// A stand-in for Bitwarden: no token, no network and no real item. It counts the create calls.
final class FakeItems: VaultItems, @unchecked Sendable {
    static let project = "11111111-2222-3333-4444-555555555555", organization = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    struct Item { var name: String; var value: String; var note: String; var project: String }
    enum Answer { case made, lost, refused }
    var stored: [String: Item] = [:]
    var creates = 0
    /// `lost`: the item is made and the answer does not arrive.
    var answer = Answer.made
    /// A made item that a look-up does not show yet.
    var hidden = false
    var lookupFails = false

    func organization(ofProject project: String) throws -> String {
        guard project == Self.project else { throw VaultFailure.provider }
        return Self.organization
    }
    func items(named name: String, project: String, organization: String) throws -> [String] {
        if lookupFails { throw VaultFailure.provider }
        return hidden ? [] : stored.filter { $0.value.name == name && $0.value.project == project }.map(\.key)
    }
    func notes(of ids: [String]) throws -> [String: String] {
        Dictionary(uniqueKeysWithValues: ids.compactMap { id in stored[id].map { (id, $0.note) } })
    }
    func create(name: String, value: String, note: String, project: String, organization: String) -> VaultCreateOutcome {
        creates += 1
        guard answer != .refused else { return .refused }
        let id = UUID().uuidString                                  // upper case, as a server can give it
        stored[id] = Item(name: name, value: value, note: note, project: project)
        return answer == .made ? .created(id) : .unknown
    }
    func login(id: String) throws -> VaultLogin {
        guard let item = stored.first(where: { $0.key.lowercased() == id.lowercased() })?.value else { throw VaultFailure.provider }
        return try VaultLogin(data: Data(item.value.utf8), label: item.name)
    }
    func secret(id: String) throws -> VaultSecret {
        guard let item = stored.first(where: { $0.key.lowercased() == id.lowercased() })?.value else { throw VaultFailure.provider }
        return try VaultSecret(data: Data(item.value.utf8))
    }
}

/// Synthetic values only. No test names a real login.
private let canary = "synthetic-CANARY-9d2f"
private func value(password: String = canary, totp: String? = nil) throws -> Data {
    var item = ["username": "owner@example.test", "password": password, "url": "https://shop.example.test/login"]
    item["totp"] = totp
    return try JSONSerialization.data(withJSONObject: item)
}

private struct Journal {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fleet-writer-test-" + UUID().uuidString)
    var file: URL { folder.appendingPathComponent("writes.json") }
    func writer(_ items: FakeItems, limit: Int = VaultWriter.maxJournalBytes,
                session: (@Sendable () throws -> (items: any VaultItems, project: String))? = nil) throws -> VaultWriter {
        try VaultWriter(journal: file, limit: limit, clock: { 1_000 }, session: session ?? { (items, FakeItems.project) })
    }
    /// A writer on this journal after its earlier writer ended, as a new process has it. In one test process the lock
    /// can stay for a moment after that end: a child process that another test starts at that time has a copy of the
    /// lock's open file until its program runs. So this tries again for a short time. A lock that stays is an error.
    func next(_ items: FakeItems, limit: Int = VaultWriter.maxJournalBytes,
              session: (@Sendable () throws -> (items: any VaultItems, project: String))? = nil) async throws -> VaultWriter {
        for _ in 0..<2_000 {
            do { return try writer(items, limit: limit, session: session) } catch VaultWriteRefusal.journal { try await Task.sleep(for: .milliseconds(1)) }
        }
        return try writer(items, limit: limit, session: session)
    }
    func remove() { try? FileManager.default.removeItem(at: folder) }
}

private func refusal(_ body: () async throws -> Void) async -> VaultWriteRefusal? {
    do { try await body(); return nil } catch { return error as? VaultWriteRefusal }
}

private let hub = "http://localhost:8765/", generation = "test-generation"
private extension VaultWriter {
    /// A submission for the test hub and generation.
    func add(requestID: String, label: String, value: Data) throws -> VaultWriteRecord {
        try add(requestID: requestID, label: label, hub: hub, db: generation, value: value)
    }
}

struct VaultWriterTests {
    private let first = "0a0a0a0a-1111-4222-8333-444444444444", second = "0b0b0b0b-1111-4222-8333-444444444444"

    /// An API key (owner feature secrets): a login with an empty user name, with its service's address or without one.
    @Test func anAPIKeyIsSavedWithOrWithoutAnAddressAndGetsItsFingerprints() async throws {
        let journal = Journal(), items = FakeItems()
        defer { journal.remove() }
        let writer = try journal.writer(items)
        let key = "sk-synthetic-CANARY-9d2f"
        let bare = try JSONSerialization.data(withJSONObject: ["username": "", "password": key])
        let record = try await writer.add(requestID: first, label: "OPENAI_API_KEY", value: bare)
        #expect(record.state == .created && items.creates == 1)
        let salts = ["password": String(repeating: "1", count: 32), "totp": String(repeating: "2", count: 32)]
        let prints = try await writer.fingerprints(requestID: first, salts: salts)
        #expect(prints.login == record.login && prints.items.count == 1 && prints.items[0].kind == "password" && prints.items[0].len == key.count)
        let served = try JSONSerialization.data(withJSONObject: ["username": "", "password": key, "url": "https://api.example.test"])
        #expect(try await writer.add(requestID: second, label: "SHOP_KEY", value: served).state == .created)
        #expect(try VaultLogin(data: served, label: "SHOP_KEY").username.isEmpty)       // call_api reads it as a login
        for bad in [["password": key, "url": "ftp://api.example.test"], ["username": "someone", "password": key], ["password": ""],
                    ["password": key, "note": "x"]] {
            let data = try JSONSerialization.data(withJSONObject: bad)
            #expect(await refusal { _ = try await writer.add(requestID: UUID().uuidString, label: "BAD_KEY", value: data) } == .login)
        }
        #expect(items.creates == 2)
    }

    @Test func oneSubmissionGetsOneCreateCall() async throws {
        let journal = Journal(), items = FakeItems()
        defer { journal.remove() }
        let writer = try journal.writer(items)
        let login = try value()
        let record = try await writer.add(requestID: first, label: " Shop admin ", value: login)
        let made = try #require(items.stored.first)
        #expect(record.state == .created && record.login == "bws://" + made.key.lowercased() && record.title == "Shop admin")
        #expect(made.value.name == "Shop admin" && made.value.note == "fleet-add:" + first && made.value.project == FakeItems.project)
        #expect(Data(made.value.value.utf8) == login)                                    // the value exactly as it came
        // A second click, another value and another spelling of the same UUID get the first record.
        #expect(try await writer.add(requestID: first, label: "Other", value: value(password: "x")) == record)
        #expect(try await writer.add(requestID: first.uppercased(), label: "Shop admin", value: login) == record)
        #expect(items.creates == 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: journal.file.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        let saved = try String(contentsOf: journal.file, encoding: .utf8)
        #expect(saved.contains(first) && !saved.contains(canary) && !saved.contains("owner@example.test"))     // no secret on disk
        #expect(record.hub == hub && record.db == generation)                            // where Fleet registers it, and nowhere else
        #expect(await writer.pending() == [record])                                      // Fleet has not registered it yet
        #expect(await refusal { _ = try await writer.close(requestID: self.second, registered: true) } == .request)
        #expect(try await writer.close(requestID: first, registered: true).state == .registered)
        #expect(await refusal { _ = try await writer.close(requestID: self.first, registered: false) } == .state)   // it is registered
        #expect(await writer.pending().isEmpty && items.creates == 1)
        for (address, database) in [("ftp://hub.example.test", generation), ("no address", generation), (hub, "bad generation"), (hub, "")] {
            #expect(await refusal { _ = try await writer.add(requestID: self.second, label: "Other", hub: address, db: database, value: login) } == .request)
        }
        #expect(items.creates == 1)
        // A made item that Fleet does not register (another hub now) is discarded by the owner and keeps its reference.
        let other = try await writer.add(requestID: second, label: "Other", value: login)
        let dropped = try await writer.close(requestID: second, registered: false)
        #expect(dropped.state == .discarded && dropped.login == other.login && items.creates == 2)
    }

    @Test func anUnknownOutcomeIsOnlyReconciledAndNeverSentAgain() async throws {
        let journal = Journal(), items = FakeItems()
        defer { journal.remove() }
        items.answer = .lost; items.hidden = true
        var process: VaultWriter? = try journal.writer(items)
        let writer = try #require(process)
        #expect(try await writer.add(requestID: first, label: "Shop admin", value: value()).state == .unknown)
        #expect(try await writer.add(requestID: first, label: "Shop admin", value: value()).state == .unknown)
        #expect(await refusal { _ = try await writer.add(requestID: second, label: "Other", value: value()) } == .unresolved)
        #expect(try await writer.check(requestID: first).state == .unknown)              // nothing found proves nothing
        items.lookupFails = true
        #expect(await refusal { _ = try await writer.check(requestID: first) } == .check)
        items.lookupFails = false; items.hidden = false
        items.stored["99999999-0000-4000-8000-000000000000"] = .init(name: "Shop admin", value: "{}", note: "", project: FakeItems.project)
        let found = try await writer.check(requestID: first)                             // the owner's own item has no mark
        let made = try #require(items.stored.first { $0.value.note == "fleet-add:" + first })
        #expect(found.state == .created && found.login == "bws://" + made.key.lowercased())
        #expect(items.creates == 1)
        #expect(throws: VaultWriteRefusal.journal) { _ = try journal.writer(items) }      // one writer process for one journal
        weak let ended = process
        process = nil
        _ = consume writer
        #expect(ended == nil)                                                             // the first writer has ended at once
        // The same journal in a new process still knows the submission.
        #expect(try await journal.next(items).add(requestID: first, label: "Shop admin", value: value()) == found)
        #expect(items.creates == 1)
    }

    @Test func aSubmissionThatWasBeingSentAtARestartIsUnknown() async throws {
        let journal = Journal(), items = FakeItems()
        defer { journal.remove() }
        try FileManager.default.createDirectory(at: journal.folder, withIntermediateDirectories: true)
        let record = #"[{"request_id":"\#(first)","title":"Shop admin","hub":"\#(hub)","db":"\#(generation)","state":"creating","login":null,"started_at":900,"updated_at":900}]"#
        #expect(FileManager.default.createFile(atPath: journal.file.path, contents: Data(record.utf8), attributes: [.posixPermissions: 0o600]))
        let writer = try journal.writer(items)
        #expect(await writer.pending().map(\.state) == [.unknown])
        #expect(try await writer.add(requestID: first, label: "Shop admin", value: value()).state == .unknown)
        #expect(try await writer.check(requestID: first).state == .unknown && items.creates == 0)
        #expect(await refusal { _ = try await writer.close(requestID: self.first, registered: true) } == .state)   // nothing to register
        #expect(try await writer.close(requestID: first, registered: false).state == .discarded)   // the owner's decision
        #expect(try await writer.add(requestID: first, label: "Shop admin", value: value()).state == .discarded && items.creates == 0)
        #expect(try await writer.add(requestID: second, label: "Shop admin", value: value()).state == .created && items.creates == 1)
    }

    @Test func aDefiniteRefusalMakesNothingAndANewSubmissionCanFollow() async throws {
        let journal = Journal(), items = FakeItems()
        defer { journal.remove() }
        items.answer = .refused
        let writer = try journal.writer(items)
        #expect(try await writer.add(requestID: first, label: "Shop admin", value: value()).state == .failed)
        #expect(items.stored.isEmpty && items.creates == 1)
        #expect(await writer.pending().isEmpty)
        items.answer = .made
        #expect(try await writer.add(requestID: first, label: "Shop admin", value: value()).state == .failed)   // never the same UUID
        #expect(try await writer.add(requestID: second, label: "Shop admin", value: value()).state == .created && items.creates == 2)
    }

    @Test func nothingIsSentWithoutSignInAValidLoginAndARecordOnDisk() async throws {
        let journal = Journal(), items = FakeItems()
        defer { journal.remove() }
        let login = try value(), id = first
        func attempt(_ session: @escaping @Sendable () throws -> (items: any VaultItems, project: String)) async -> VaultWriteRefusal? {
            await refusal { _ = try await journal.next(items, session: session).add(requestID: id, label: "Shop admin", value: login) }
        }
        #expect(await attempt { throw VaultWriteRefusal.setup } == .setup)               // no write token
        #expect(await attempt { throw VaultFailure.provider } == .provider)              // Bitwarden refused the token
        #expect(await attempt { (items, "99999999-2222-3333-4444-555555555555") } == .provider)   // the token does not reach the project
        let writer = try await journal.next(items)
        let long = try value(password: String(repeating: "é", count: 25_000))
        let noPassword = try JSONSerialization.data(withJSONObject: ["username": "owner", "password": "", "url": "https://shop.example.test"])
        #expect(await refusal { _ = try await writer.add(requestID: "not-a-uuid", label: "Shop admin", value: login) } == .request)
        #expect(await refusal { _ = try await writer.add(requestID: first, label: "  ", value: login) } == .login)
        #expect(await refusal { _ = try await writer.add(requestID: first, label: String(repeating: "n", count: 501), value: login) } == .login)
        #expect(await refusal { _ = try await writer.add(requestID: first, label: "Shop admin", value: noPassword) } == .login)
        #expect(await refusal { _ = try await writer.add(requestID: first, label: "Shop admin", value: long) } == .tooLong)
        #expect(await refusal { _ = try await writer.check(requestID: first) } == .request)       // no record of it
        #expect(items.creates == 0 && !FileManager.default.fileExists(atPath: journal.file.path))
        // Without a record on disk, no create call goes out.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: journal.folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: journal.folder.path) }
        #expect(await refusal { _ = try await writer.add(requestID: first, label: "Shop admin", value: login) } == .journal)
        #expect(items.creates == 0)
    }

    @Test func everyUsedRequestKeepsItsRecordAndAFullJournalRefusesBeforeTheCall() async throws {
        let journal = Journal(), items = FakeItems()
        defer { journal.remove() }
        func id(_ number: Int) -> String { String(format: "00000000-0000-4000-8000-%012d", number) }
        var writer: VaultWriter? = try journal.writer(items)
        for number in 1...205 {
            _ = try await writer?.add(requestID: id(number), label: "Login \(number)", value: value())
            #expect(try await writer?.close(requestID: id(number), registered: true).state == .registered)
        }
        #expect(items.creates == 205)
        // A replay of the oldest finished submission, also in a new process, gets its record and no create call.
        #expect(try await writer?.add(requestID: id(1), label: "Login 1", value: value()).state == .registered)
        writer = nil
        writer = try await journal.next(items)
        #expect(try await writer?.add(requestID: id(1), label: "Login 1", value: value()).state == .registered)
        #expect(try await writer?.add(requestID: id(205), label: "Other", value: value()).state == .registered)
        #expect(items.creates == 205)
        writer = nil
        // A journal without room does not forget an ID to make room: the new submission makes nothing.
        let size = try #require(try FileManager.default.attributesOfItem(atPath: journal.file.path)[.size] as? Int)
        let full = try await journal.next(items, limit: size + VaultWriter.reserve + 100)
        #expect(await refusal { _ = try await full.add(requestID: id(206), label: "Login 206", value: value()) } == .journal)
        #expect(items.creates == 205 && items.stored.count == 205)
        #expect(try await full.add(requestID: id(2), label: "Login 2", value: value()).state == .registered)
    }

    @Test func aOneCharacterPasswordIsALogin() async throws {
        let journal = Journal(), items = FakeItems()
        defer { journal.remove() }
        let record = try await journal.writer(items).add(requestID: first, label: "Short", value: value(password: "x"))
        #expect(record.state == .created && items.stored.first?.value.value.contains(#""password":"x""#) == true)
    }

    @Test func fingerprintsComeFromTheWritersOwnItemWithoutItsValue() async throws {
        let journal = Journal(), items = FakeItems()
        defer { journal.remove() }
        let salts = ["password": "0123456789abcdef0123456789abcdef", "totp": "fedcba9876543210fedcba9876543210"]
        let seed = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
        _ = try await journal.writer(items).add(requestID: first, label: "Shop admin", value: value(totp: seed))
        // A new process has no value in memory: it reads its own item again.
        let writer = try await journal.next(items)
        let later = try await writer.fingerprints(requestID: first, salts: salts)
        let expected = VaultHub.fingerprints(try VaultLogin(data: value(totp: seed), label: "Shop admin"), salts: salts)
        #expect(later.items.count == 2 && later.items.map(\.hash) == expected.map { $0["hash"] as? String })
        #expect(later.items.map(\.kind) == ["password", "totp"] && later.items.map(\.len) == [canary.count, seed.count] && later.login.hasPrefix("bws://"))
        let text = String(decoding: VaultWriterReply(login: later.login, fingerprints: later.items).data(), as: UTF8.self)
        #expect(!text.contains(canary) && !text.contains(seed))
        #expect(await refusal { _ = try await writer.fingerprints(requestID: first, salts: ["password": salts["password"]!]) } == .state)
        #expect(await refusal { _ = try await writer.fingerprints(requestID: first, salts: ["password": "x", "totp": "y"]) } == .state)
        _ = try await writer.close(requestID: first, registered: true)
        #expect(await refusal { _ = try await writer.fingerprints(requestID: first, salts: salts) } == .state)   // registered: done
        _ = try await writer.add(requestID: second, label: "Short", value: value(password: "abc"))
        #expect(try await writer.fingerprints(requestID: second, salts: salts).items.isEmpty)    // stored and used; only not masked
    }

    @Test func aJournalThatCannotBeTrustedStopsTheWriter() async throws {
        for (content, mode) in [("not json", 0o600), ("[]", 0o644),
                                (#"[{"request_id":"NOT-CANONICAL","title":"x","hub":"http://h/","db":"d","state":"unknown","login":null,"started_at":1,"updated_at":1}]"#, 0o600)] {
            let journal = Journal()
            defer { journal.remove() }
            try FileManager.default.createDirectory(at: journal.folder, withIntermediateDirectories: true)
            #expect(FileManager.default.createFile(atPath: journal.file.path, contents: Data(content.utf8), attributes: [.posixPermissions: mode]))
            #expect(throws: VaultWriteRefusal.journal) { _ = try journal.writer(FakeItems()) }
        }
    }
}

/// A stand-in for the helper's Keychain item: a worker's journal in memory.
final class FakeKeychainJournal: VaultJournalStore, @unchecked Sendable {
    var data: Data?
    var fails = false
    func load(limit: Int) throws -> Data? { data }
    func save(_ data: Data) throws {
        if fails { throw VaultFailure.keychain }
        self.data = data
    }
}

/// A random source that is the same in every run: the bytes 0, 1, 2, … in order.
private final class Counter: @unchecked Sendable {
    var next: UInt8 = 0
    /// The passwords that were made with this source.
    var made = 0
    func bytes(_ count: Int) -> [UInt8] { (0..<count).map { _ in defer { next &+= 1 }; return next } }
}

/// A save that an agent's confirmed job asks for on a worker Mac: the vault makes the password.
struct VaultCreateTests {
    private let first = "0e0e0e0e-1111-4222-8333-444444444444", second = "0f0f0f0f-1111-4222-8333-444444444444"
    private func job(_ requestID: String, task: String = "T-7", attempt: Int = 1, label: String = "Shop admin", project: String? = "shop",
                     username: String = "owner@example.test") -> VaultCreateJob {
        VaultCreateJob(id: 12, creation: VaultCreation(requestID: requestID, db: generation, agent: "studio", task: task, attempt: attempt,
                                                       project: project, label: label, username: username, url: "https://shop.example.test/login"))
    }
    private func writer(_ items: FakeItems, _ store: FakeKeychainJournal, signedIn: Bool = true) throws -> VaultWriter {
        try VaultWriter(store: store, limit: 1_048_576, clock: { 1_000 }) {
            guard signedIn else { throw VaultWriteRefusal.setup }
            return (items, FakeItems.project)
        }
    }
    /// One save of a job, as the broker does it.
    private func save(_ writer: VaultWriter, _ job: VaultCreateJob, _ source: Counter) async throws -> VaultWriteRecord {
        try await writer.create(requestID: job.creation.requestID, binding: job.creation.binding, title: job.creation.label, hub: hub,
                                db: job.creation.db, mark: job.mark) {
            source.made += 1
            return try job.creation.value(random: source.bytes)
        }
    }

    @Test func aRequestGetsOnePasswordAndOneItemAlsoWhenItIsAskedAgain() async throws {
        let items = FakeItems(), store = FakeKeychainJournal(), source = Counter()
        let record = try await save(try writer(items, store), job(first), source)
        let made = try #require(items.stored.first)
        let value = try #require(try JSONSerialization.jsonObject(with: Data(made.value.value.utf8)) as? [String: String])
        let password = try #require(value["password"])
        #expect(record.state == .created && record.login == "bws://" + made.key.lowercased() && record.binding == job(first).creation.binding)
        #expect(made.value.name == "Shop admin" && made.value.note == "fleet-create:studio:" + first && record.mark == made.value.note)
        #expect(value["username"] == "owner@example.test" && password.count == 24 && source.made == 1)
        let kept = String(decoding: try #require(store.data), as: UTF8.self)
        #expect(kept.contains(first) && !kept.contains(password) && !kept.contains("owner@example.test"))    // the journal has no value
        // The request UUID is the identity of a retry: the same one again, also after a restart, gets the first
        // record, no new password and no create call.
        #expect(try await save(try writer(items, store), job(first), source) == record)
        #expect(items.creates == 1 && source.made == 1)
        // The vault's own journal says that it made this login for this request, and nothing else.
        let asked = try writer(items, store), binding = job(first).creation.binding, reference = try #require(record.login)
        #expect(await asked.made(requestID: first, binding: binding, login: reference.uppercased()))
        #expect(await !asked.made(requestID: first, binding: binding, login: "bws://99999999-0000-4000-8000-000000000000"))
        #expect(await !asked.made(requestID: first, binding: job(first, attempt: 2).creation.binding, login: reference))
        #expect(await !asked.made(requestID: second, binding: binding, login: reference))
        // Another request UUID is another explicit save, also with the same label, user name and address.
        let other = try await save(asked, job(second), source)
        #expect(other.state == .created && other.login != record.login && items.creates == 2 && source.made == 2)
        // The binding has the generation, the agent, the task, its attempt, the project and the input.
        let bindings = [job(first), job(first, task: "T-8"), job(first, attempt: 2), job(first, project: nil), job(first, label: "Other"),
                        job(first, username: "other@example.test")].map(\.creation.binding)
        #expect(Set(bindings).count == bindings.count)
    }

    @Test func aRequestWithChangedInputIsRefusedAndMakesNothing() async throws {
        let items = FakeItems(), store = FakeKeychainJournal(), source = Counter()
        let writer = try writer(items, store)
        _ = try await save(writer, job(first), source)
        for changed in [job(first, task: "T-8"), job(first, attempt: 2), job(first, label: "Other"), job(first, project: nil),
                        job(first, username: "other@example.test")] {
            #expect(await refusal { _ = try await self.save(writer, changed, source) } == .changed)
        }
        // A worker's save has only the mark of its own form, for this request.
        let good = job(second).creation.binding
        for (binding, mark) in [("not a hash", "fleet-create:studio:" + second), (good, "fleet-create:studio:" + first), (good, ""),
                                (good, "fleet-add:" + second), (good, "fleet-create:" + second)] {
            #expect(await refusal { _ = try await writer.create(requestID: self.second, binding: binding, title: "x", hub: hub, db: generation, mark: mark) { Data() } } == .request)
        }
        #expect(items.creates == 1 && source.made == 1)
    }

    @Test func anUnknownOutcomeOfARequestIsOnlyLookedFor() async throws {
        let items = FakeItems(), store = FakeKeychainJournal(), source = Counter()
        items.answer = .lost; items.hidden = true
        #expect(try await save(try writer(items, store), job(first), source).state == .unknown)
        #expect(try await save(try writer(items, store), job(first), source).state == .unknown)        // looked for, not found, not sent
        items.lookupFails = true
        let asked = try writer(items, store)
        #expect(await refusal { _ = try await self.save(asked, self.job(self.first), source) } == .check)
        #expect(await !asked.made(requestID: first, binding: job(first).creation.binding, login: "bws://" + items.stored.keys.first!.lowercased()))
        items.lookupFails = false; items.answer = .made
        // An open save of one request does not stop the save of another request.
        #expect(try await save(asked, job(second, label: "Other"), source).state == .created)
        items.hidden = false
        let found = try await save(asked, job(first), source)
        #expect(found.state == .created && found.login != nil && items.creates == 2 && source.made == 2)
        #expect(try await asked.close(requestID: first, registered: true).state == .registered)
        #expect(try await save(asked, job(first), source).state == .registered && items.creates == 2)
    }

    @Test func aJobThatWasBeingSentAtARestartIsUnknown() async throws {
        let items = FakeItems(), store = FakeKeychainJournal(), source = Counter()
        let binding = job(first).creation.binding
        store.data = Data(#"[{"request_id":"\#(first)","title":"Shop admin","hub":"\#(hub)","db":"\#(generation)","state":"creating","login":null,"started_at":900,"updated_at":900,"binding":"\#(binding)","mark":"fleet-create:studio:\#(first)"}]"#.utf8)
        let writer = try writer(items, store)
        #expect(try await save(writer, job(first), source).state == .unknown && items.creates == 0 && source.made == 0)
        #expect(String(decoding: try #require(store.data), as: UTF8.self).contains(#""state":"unknown""#))
    }

    @Test func aMachineWithoutTheSetupOrWithoutItsJournalMakesNothing() async throws {
        let items = FakeItems(), store = FakeKeychainJournal(), source = Counter()
        let closed = try writer(items, store, signedIn: false)
        #expect(await refusal { _ = try await self.save(closed, self.job(self.first), source) } == .setup)
        #expect(store.data == nil && source.made == 0)                                  // no record and no password
        store.fails = true
        let broken = try writer(items, store)
        #expect(await refusal { _ = try await self.save(broken, self.job(self.first), source) } == .journal)
        #expect(items.creates == 0)
        store.fails = false; store.data = Data("not json".utf8)
        #expect(throws: VaultWriteRefusal.journal) { _ = try writer(items, store) }
    }

    @Test func everyRefusalIsAFixedTextWithoutAValue() {
        for refusal in VaultWriteRefusal.allCases {
            #expect(!refusal.rawValue.isEmpty && refusal.rawValue.hasSuffix("."))
            for value in [canary, "owner@example.test", "shop.example.test", "Shop admin", first] { #expect(!refusal.rawValue.contains(value)) }
        }
    }

    @Test func aGeneratedPasswordHasEveryAskedClassAndNoFavoredCharacter() throws {
        let plain = try VaultGenerator.password()
        #expect(plain.count == 24 && plain.allSatisfy { (VaultGenerator.upper + VaultGenerator.lower + VaultGenerator.digits).contains($0) })
        for part in [VaultGenerator.upper, VaultGenerator.lower, VaultGenerator.digits] { #expect(plain.contains(where: part.contains)) }
        #expect(try VaultGenerator.password() != plain)
        let marked = try VaultGenerator.password(.init(length: 128, symbols: true))
        #expect(marked.count == 128 && marked.contains(where: VaultGenerator.symbols.contains))
        #expect(try VaultGenerator.password(.init(length: 8)).count == 8)
        for length in [7, 129, 0] { #expect(throws: VaultFailure.request) { _ = try VaultGenerator.password(.init(length: length)) } }
        // The same source gives the same password, so a test knows its value.
        #expect(try VaultGenerator.password(random: Counter().bytes) == VaultGenerator.password(random: Counter().bytes))
        // 62 characters: a byte from 248 up is not used, or the first 8 characters would come more often.
        let skipped = try VaultGenerator.password(.init(length: 8)) { count in (0..<count).map { [250, 0, 255, 27, 248, 53][$0 % 6] } }
        #expect(skipped == "Ab1Ab1Ab")
        // A source that cannot give every class, or no usable byte, is refused.
        #expect(throws: VaultFailure.dependency) { _ = try VaultGenerator.password { [UInt8](repeating: 0, count: $0) } }
        #expect(throws: VaultFailure.dependency) { _ = try VaultGenerator.password { [UInt8](repeating: 255, count: $0) } }
    }
}
