import CryptoKit
import FleetVaultIPC
import Foundation
import Testing
@testable import FleetVaultCore

/// The `create` operation on the wire, and the use of a made login. Fake data only: the hub is `FakeHub`, the store
/// is `FakeItems`, and the worker's journal is in memory. These tests are part of the serialized suite of `FakeHub`.
extension VaultCallerTests {
    private static let key = "STUDIO-KEY_" + String(repeating: "c", count: 32)
    private static let requestID = "0a1b2c3d-1111-4222-8333-444444444444"
    private static let salts = ["password": "0123456789abcdef0123456789abcdef", "totp": "fedcba9876543210fedcba9876543210"]
    private static var caller: VaultCaller { VaultCaller(agent: "studio", key: key) }
    private static func hub() throws -> VaultHub {
        VaultHub(configuration: try VaultConfiguration(data: JSONSerialization.data(withJSONObject: [
            "agent": "studio", "hub": "http://100.64.0.1:9", "store": "fleet", "worker_uid": 501,
            "socket": NSHomeDirectory() + "/Library/Application Support/AgentFleet/vault.sock"])), protocolClasses: [FakeHub.self])
    }
    private static func createRequest(job: Int = 21) throws -> VaultRequest {
        try VaultRequest(data: JSONSerialization.data(withJSONObject: ["v": 2, "op": "create", "job": job, "agent": "studio", "agent_key": key]))
    }
    /// The hub's confirmation of create job 21, as the contract gives it.
    private static func confirmation(_ change: [String: Any] = [:]) -> [String: Any] {
        ["ok": true, "job": 21, "task": "T-7", "kind": "create", "attempt": 2, "project": "shop", "db": "test-generation",
         "request_id": requestID, "label": "Shop admin", "username": "owner@example.test", "url": "https://shop.example.test/login",
         "mark": "fleet-create:studio:" + requestID].merging(change) { _, new in new }
    }
    private static func writer(_ items: FakeItems, _ store: FakeKeychainJournal) throws -> VaultWriter {
        try VaultWriter(store: store, limit: 1_048_576, clock: { 1_000 }) { (items, FakeItems.project) }
    }
    /// A hub that confirms the job, takes the made login and counts the fingerprints.
    private static func answering(_ confirmed: [String: Any] = confirmation(), created status: Int = 200) -> @Sendable (String, [String: Any]) -> (Int, Any) {
        let confirmed = SendableBox(confirmed)
        return { route, body in
            if route.hasSuffix("/created") {
                return (status, ["ok": true, "job": body["job"] ?? 0, "login": body["login"] ?? "", "fingerprint_salts": salts])
            }
            if route.hasSuffix("/fingerprints") {
                return (200, ["ok": true, "job": body["job"] ?? 0, "stored": (body["fingerprints"] as? [Any])?.count ?? 0, "known": 0])
            }
            return (200, confirmed.value)
        }
    }
    private static func create(_ hub: VaultHub, _ writer: VaultWriter) async throws -> [String: Any] {
        await VaultBroker.create(try createRequest(), as: caller, hub: hub, writer: writer, address: "http://100.64.0.1:9")
    }

    @Test func aCreateRequestAlwaysNamesItsCaller() throws {
        #expect(try Self.createRequest().caller == Self.caller)
        #expect(throws: VaultFailure.caller) { try VaultRequest(data: Data(#"{"v":2,"op":"create","job":21}"#.utf8)) }
        #expect(throws: VaultFailure.caller) { try VaultRequest(data: Data(#"{"v":2,"op":"create","job":21,"agent":"studio"}"#.utf8)) }
        for extra in ["label": "Shop admin", "password": "x", "request_id": Self.requestID] {      // nothing but the job comes in the request
            let fields: [String: Any] = ["v": 2, "op": "create", "job": 21, "agent": "studio", "agent_key": Self.key, extra.key: extra.value]
            #expect(throws: VaultFailure.request) { try VaultRequest(data: JSONSerialization.data(withJSONObject: fields)) }
        }
    }

    @Test func theConfirmationOfACreateJobIsReadStrictly() throws {
        func job(_ change: [String: Any] = [:], without key: String? = nil) throws -> VaultCreateJob {
            var fields = Self.confirmation(change)
            if let key { fields.removeValue(forKey: key) }
            return try VaultCreateJob(data: JSONSerialization.data(withJSONObject: fields), request: Self.createRequest(), agent: "studio")
        }
        let good = try job()
        #expect(good.id == 21 && good.mark == "fleet-create:studio:" + Self.requestID)
        #expect(good.creation == VaultCreation(requestID: Self.requestID, db: "test-generation", agent: "studio", task: "T-7", attempt: 2,
                                               project: "shop", label: "Shop admin", username: "owner@example.test",
                                               url: "https://shop.example.test/login"))
        // A worker's save has one mark only. The form of the owner's Add secret, or no mark, is no create job.
        #expect(throws: VaultFailure.hub) { _ = try job(without: "mark") }
        #expect(throws: VaultFailure.hub) { _ = try job(["mark": "fleet-add:" + Self.requestID]) }
        #expect(throws: VaultFailure.hub) { _ = try job(["mark": NSNull()]) }
        #expect(try job(["project": NSNull()]).creation.project == nil)
        #expect(try job(["request_id": Self.requestID.uppercased()]).creation.requestID == Self.requestID)
        // The generation and the attempt are part of what the save is bound to: without them there is no job.
        for missing in ["db", "attempt", "request_id", "label", "username", "url", "task"] {
            #expect(throws: VaultFailure.hub) { _ = try job(without: missing) }
        }
        let bad: [[String: Any]] = [
            ["kind": "signin"], ["job": 22], ["ok": false], ["attempt": 0], ["attempt": "2"], ["db": "bad generation"], ["request_id": "not-a-uuid"],
            ["label": String(repeating: "n", count: 61)], ["label": ""], ["label": "two\nlines"], ["label": " Shop admin"],
            ["username": String(repeating: "u", count: 201)], ["username": ""],
            ["url": "ftp://shop.example.test"], ["url": "https://owner:pw@shop.example.test"], ["url": "shop.example.test"],
            ["project": "Not A Project"], ["mark": "fleet-create:seo:" + Self.requestID], ["mark": "fleet-add:0a1b2c3d-0000-4000-8000-000000000000"],
            ["mark": 7]]
        for change in bad { #expect(throws: VaultFailure.hub) { _ = try job(change) } }
    }

    @Test func aCreateJobSavesOnceTellsTheHubAndAnswersWithTheReferenceOnly() async throws {
        let items = FakeItems(), store = FakeKeychainJournal()
        FakeHub.reset(answer: Self.answering())
        let hub = try Self.hub(), writer = try Self.writer(items, store)
        let reply = try await Self.create(hub, writer)
        let made = try #require(items.stored.first)
        let login = "bws://" + made.key.lowercased()
        #expect(NSDictionary(dictionary: reply) == NSDictionary(dictionary: ["ok": true, "v": 2, "job": 21, "login": login]))
        #expect(made.value.name == "Shop admin" && made.value.note == "fleet-create:studio:" + Self.requestID)   // the hub's mark
        let header = "Bearer " + Self.key
        #expect(FakeHub.seen == [.init(route: "/helper/vault/studio", authorization: header),
                                 .init(route: "/helper/vault/studio/created", authorization: header),
                                 .init(route: "/helper/vault/studio/fingerprints", authorization: header)])
        let password = try #require((try JSONSerialization.jsonObject(with: Data(made.value.value.utf8)) as? [String: String])?["password"])
        #expect(!String(decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self).contains(password))
        // The same request again: the hub confirms it again, and the vault answers from its journal. Nothing is made,
        // and the hub is not told a second time.
        FakeHub.reset(answer: Self.answering())
        #expect(NSDictionary(dictionary: try await Self.create(hub, try Self.writer(items, store))) == NSDictionary(dictionary: reply))
        #expect(items.creates == 1 && FakeHub.seen.map(\.route) == ["/helper/vault/studio"])
        // The same request with another attempt, generation or input is a changed request.
        for change in [["attempt": 3], ["db": "other-generation"], ["label": "Other"], ["username": "other@example.test"], ["project": NSNull()]] as [[String: Any]] {
            FakeHub.reset(answer: Self.answering(Self.confirmation(change)))
            let refused = try await Self.create(hub, try Self.writer(items, store))
            #expect(NSDictionary(dictionary: refused) == NSDictionary(dictionary: ["ok": false, "v": 2, "error": VaultWriteRefusal.changed.rawValue]))
        }
        #expect(items.creates == 1)
    }

    @Test func aRevokedGrantOrAClosedJobMakesNothing() async throws {
        let items = FakeItems(), store = FakeKeychainJournal()
        let hub = try Self.hub(), writer = try Self.writer(items, store)
        // The hub refuses the confirmation: the permission is gone, the task is held, the attempt changed, the job is closed.
        for status in [409, 404, 500] {
            FakeHub.reset(answer: { _, _ in (status, ["error": "the agent's vault_create is no longer there"]) })
            let reply = try await Self.create(hub, writer)
            #expect(NSDictionary(dictionary: reply) == NSDictionary(dictionary: ["ok": false, "v": 2, "error": VaultFailure.hub.rawValue]))
        }
        FakeHub.reset(answer: { _, _ in (403, ["error": "bad key", "auth": "key"]) })          // the caller's key is refused
        #expect((try await Self.create(hub, writer))["error"] as? String == VaultFailure.key.rawValue)
        #expect(items.creates == 0 && store.data == nil && FakeHub.seen.map(\.route) == ["/helper/vault/studio"])
    }

    @Test func anUncertainSaveAnswersUnknownAndIsOnlyReconciled() async throws {
        let items = FakeItems(), store = FakeKeychainJournal()
        let hub = try Self.hub()
        // No answer to the create call, and the item does not show.
        items.answer = .lost; items.hidden = true
        FakeHub.reset(answer: Self.answering())
        let unknown: NSDictionary = ["ok": false, "v": 2, "unknown": true, "error": VaultFailure.saveUnknown.rawValue]
        #expect(NSDictionary(dictionary: try await Self.create(hub, try Self.writer(items, store))) == unknown)
        #expect(NSDictionary(dictionary: try await Self.create(hub, try Self.writer(items, store))) == unknown)     // looked for; not sent again
        items.lookupFails = true
        #expect(NSDictionary(dictionary: try await Self.create(hub, try Self.writer(items, store))) == unknown)     // the store does not answer
        #expect(items.creates == 1 && !FakeHub.seen.contains { $0.route.hasSuffix("/created") })
        // The item shows, and the hub does not take the report: the login is saved, the job stays open.
        items.lookupFails = false; items.hidden = false
        FakeHub.reset(answer: Self.answering(created: 500))
        let unregistered = try await Self.create(hub, try Self.writer(items, store))
        #expect(NSDictionary(dictionary: unregistered) == NSDictionary(dictionary: ["ok": false, "v": 2, "unknown": true, "error": VaultFailure.saveUnregistered.rawValue]))
        // The same request again finishes the hub's steps.
        FakeHub.reset(answer: Self.answering())
        let done = try await Self.create(hub, try Self.writer(items, store))
        #expect(done["ok"] as? Bool == true && (done["login"] as? String)?.hasPrefix("bws://") == true && items.creates == 1)
        #expect(FakeHub.seen.map(\.route) == ["/helper/vault/studio", "/helper/vault/studio/created", "/helper/vault/studio/fingerprints"])
    }

    @Test func aRefusedKeyAfterTheSaveStaysUnknownAndTheSameRequestFinishesIt() async throws {
        let items = FakeItems(), store = FakeKeychainJournal()
        let hub = try Self.hub()
        // The item is made. Then the hub refuses the caller's key, at the report and later at the fingerprints.
        for refusedRoute in ["/created", "/fingerprints"] {
            FakeHub.reset(answer: { route, body in
                route.hasSuffix(refusedRoute) ? (403, ["error": "bad key", "auth": "key"]) : Self.answering()(route, body)
            })
            let reply = try await Self.create(hub, try Self.writer(items, store))
            #expect(NSDictionary(dictionary: reply) == NSDictionary(dictionary: ["ok": false, "v": 2, "unknown": true, "error": VaultFailure.key.rawValue]))
            #expect(items.creates == 1 && items.stored.count == 1)                       // one item; the job must stay open
        }
        // The key works again: the same request finishes the hub's steps and makes nothing.
        FakeHub.reset(answer: Self.answering())
        let done = try await Self.create(hub, try Self.writer(items, store))
        #expect(done["ok"] as? Bool == true && done["login"] as? String == "bws://" + items.stored.keys.first!.lowercased())
        #expect(items.creates == 1 && FakeHub.seen.map(\.route) == ["/helper/vault/studio", "/helper/vault/studio/created", "/helper/vault/studio/fingerprints"])
        // Before any create call, a refused key is a plain refusal: nothing exists.
        FakeHub.reset(answer: { _, _ in (403, ["error": "bad key", "auth": "key"]) })
        let fresh = FakeItems()
        let early = try await Self.create(hub, try Self.writer(fresh, FakeKeychainJournal()))
        #expect(NSDictionary(dictionary: early) == NSDictionary(dictionary: ["ok": false, "v": 2, "error": VaultFailure.key.rawValue]) && fresh.creates == 0)
    }

    @Test func everyFailureOfCreateIsOneFixedSentenceWithoutAValue() async throws {
        let hub = try Self.hub()
        var replies: [[String: Any]] = []
        FakeHub.reset(answer: Self.answering())
        let refusing = FakeItems(); refusing.answer = .refused                          // the store answers that it made nothing
        replies.append(try await Self.create(hub, try Self.writer(refusing, FakeKeychainJournal())))
        #expect(replies[0]["error"] as? String == VaultFailure.saveRefused.rawValue && replies[0]["unknown"] == nil)
        let noSetup = try VaultWriter(store: FakeKeychainJournal(), limit: 1_048_576) { throw VaultWriteRefusal.setup }
        replies.append(await VaultBroker.create(try Self.createRequest(), as: Self.caller, hub: hub, writer: noSetup, address: "http://100.64.0.1:9"))
        #expect(replies[1]["error"] as? String == VaultFailure.creates.rawValue)
        let noJournal = FakeKeychainJournal(); noJournal.fails = true                   // the record cannot be kept: nothing is sent
        let unkept = FakeItems()
        replies.append(try await Self.create(hub, try Self.writer(unkept, noJournal)))
        #expect(replies[2]["error"] as? String == VaultWriteRefusal.journal.rawValue && unkept.creates == 0)
        let fixed = Set(VaultFailure.allCases.map(\.rawValue) + VaultWriteRefusal.allCases.map(\.rawValue))
        for reply in replies {
            let text = try #require(reply["error"] as? String)
            #expect(Set(reply.keys).isSubset(of: ["ok", "v", "error", "unknown"]) && reply["ok"] as? Bool == false && fixed.contains(text))
            for value in ["Shop admin", "owner@example.test", "shop.example.test", Self.requestID, Self.key] { #expect(!text.contains(value)) }
        }
    }

    // MARK: the use of a made login

    private static func signInJob(login: String, createdBy: [String: Any]?, operation: String = "signin") throws -> VaultJob {
        var fields: [String: Any] = ["ok": true, "kind": operation, "job": 30, "task": "T-7", "login": login, "project": "shop",
                                     "fingerprint_salts": salts, "source": login]
        if operation == "handover" { fields["target"] = "seo"; fields["recipient"] = "age1" + String(repeating: "q", count: 58) }
        fields["created_by"] = createdBy
        let request = try VaultRequest(data: JSONSerialization.data(withJSONObject: ["v": 2, "op": operation, "job": 30, "agent": "studio", "agent_key": key]))
        return try VaultJob(data: JSONSerialization.data(withJSONObject: fields), request: request)
    }
    private static func createdBy(_ change: [String: Any] = [:]) -> [String: Any] {
        ["request_id": requestID, "db": "test-generation", "agent": "studio", "attempt": 2, "label": "Shop admin",
         "username": "owner@example.test", "url": "https://shop.example.test/login"].merging(change) { _, new in new }
    }

    @Test func aSignInSaysThatThisBrokerChecksTheCreationOfAMadeLogin() throws {
        let signin = try VaultRequest(data: Data(#"{"v":2,"op":"signin","job":12}"#.utf8))
        let body = try #require(JSONSerialization.jsonObject(with: VaultHub.confirmBody(signin)) as? [String: Any])
        #expect(Set(body.keys) == ["job", "kind", "provenance", "creation"] && body["creation"] as? Int == 1)
        // An ordinary sign-in has no creation, and nothing changes for it.
        #expect(try Self.signInJob(login: "bws://12345678-1234-1234-1234-123456789012", createdBy: nil).createdBy == nil)
        // Only a sign-in can carry it, and only with every field.
        #expect(throws: VaultFailure.hub) { _ = try Self.signInJob(login: "bws://12345678-1234-1234-1234-123456789012", createdBy: Self.createdBy(), operation: "handover") }
        for missing in ["request_id", "db", "agent", "attempt", "label", "username", "url"] {
            var fields = Self.createdBy(); fields.removeValue(forKey: missing)
            #expect(throws: VaultFailure.hub) { _ = try Self.signInJob(login: "bws://12345678-1234-1234-1234-123456789012", createdBy: fields) }
        }
    }

    @Test func aForgedReportOfAMadeLoginDoesNotLetTheVaultUseAnotherLogin() async throws {
        // The vault makes one login for the request. The hub's word about that request can be wrong: the worker's own
        // key can report any reference as made. Only the vault's journal says which login the request made.
        let items = FakeItems(), store = FakeKeychainJournal()
        FakeHub.reset(answer: Self.answering())
        let made = try #require((try await Self.create(try Self.hub(), try Self.writer(items, store)))["login"] as? String)
        let other = "bws://99999999-0000-4000-8000-000000000000"                         // a login that the owner has, not made here
        let writer = try Self.writer(items, store)
        func allowed(_ login: String, _ creation: [String: Any]? = Self.createdBy(), caller: VaultCaller = Self.caller) async throws -> Bool {
            await VaultBroker.madeHere(try Self.signInJob(login: login, createdBy: creation), operation: .signin, caller: caller, writer: writer)
        }
        #expect(try await allowed(made))
        #expect(try await !allowed(other))                                              // the forged report names another reference
        #expect(try await !allowed(made, Self.createdBy(["attempt": 3])))               // another attempt than the one that made it
        #expect(try await !allowed(made, Self.createdBy(["db": "other-generation"])))
        #expect(try await !allowed(made, Self.createdBy(["label": "Other"])))
        #expect(try await !allowed(made, Self.createdBy(["request_id": "0a1b2c3d-0000-4000-8000-000000000000"])))
        #expect(try await !allowed(made, Self.createdBy(["agent": "seo"])))             // made by another agent than the caller
        #expect(try await !allowed(made, caller: VaultCaller(agent: "seo", key: Self.key)))
        // Another machine's vault has no such record: it never uses the exception.
        let elsewhere = try Self.writer(FakeItems(), FakeKeychainJournal())
        #expect(await !VaultBroker.madeHere(try Self.signInJob(login: made, createdBy: Self.createdBy()), operation: .signin, caller: Self.caller, writer: elsewhere))
    }
}

/// `capture`: a key that a service shows in one field of a Chrome page. The page is a stand-in: `Page` answers what
/// the vault's script would give, so no browser runs and no real value exists.
extension VaultCallerTests {
    private static let captureKey = "STUDIO-KEY_" + String(repeating: "d", count: 32)
    private static let captureID = "0b2c3d4e-1111-4222-8333-444444444444"
    private static let captureSalts = ["password": "0123456789abcdef0123456789abcdef", "totp": "fedcba9876543210fedcba9876543210"]
    private static var captureCaller: VaultCaller { VaultCaller(agent: "studio", key: captureKey) }
    private static func captureHub() throws -> VaultHub {
        VaultHub(configuration: try VaultConfiguration(data: JSONSerialization.data(withJSONObject: [
            "agent": "studio", "hub": "http://100.64.0.1:9", "store": "fleet", "worker_uid": 501,
            "socket": NSHomeDirectory() + "/Library/Application Support/AgentFleet/vault.sock"])), protocolClasses: [FakeHub.self])
    }
    private static func request(_ operation: String, job: Int = 41) throws -> VaultRequest {
        try VaultRequest(data: JSONSerialization.data(withJSONObject: ["v": 2, "op": operation, "job": job, "agent": "studio", "agent_key": captureKey]))
    }
    /// The hub's confirmation of capture job 41.
    private static func captureConfirmation(_ change: [String: Any] = [:]) -> [String: Any] {
        ["ok": true, "job": 41, "task": "T-7", "kind": "capture", "attempt": 2, "project": "shop", "db": "test-generation",
         "request_id": captureID, "label": "Shop API key", "username": "shop-key-1", "url": "https://shop.example.test/settings/keys",
         "selector": "#api-key", "mark": "fleet-create:studio:" + captureID].merging(change) { _, new in new }
    }
    private static func hubAnswering(_ confirmed: [String: Any]) -> @Sendable (String, [String: Any]) -> (Int, Any) {
        let confirmed = SendableBox(confirmed)
        return { route, body in
            if route.hasSuffix("/created") {
                return (200, ["ok": true, "job": body["job"] ?? 0, "login": body["login"] ?? "", "fingerprint_salts": captureSalts])
            }
            if route.hasSuffix("/fingerprints") {
                return (200, ["ok": true, "job": body["job"] ?? 0, "stored": (body["fingerprints"] as? [Any])?.count ?? 0, "known": 0])
            }
            return (200, confirmed.value)
        }
    }
    private static func saver(_ items: FakeItems, _ store: FakeKeychainJournal) throws -> VaultWriter {
        try VaultWriter(store: store, limit: 1_048_576, clock: { 1_000 }) { (items, FakeItems.project) }
    }
    private static func capture(_ writer: VaultWriter, _ page: Page, operation: String = "capture") async throws -> [String: Any] {
        await VaultBroker.create(try request(operation), as: captureCaller, hub: try captureHub(), writer: writer, address: "http://100.64.0.1:9",
                                 read: page.read)
    }
    private static func password(of items: FakeItems) throws -> [String] {
        try items.stored.values.map { try #require((try JSONSerialization.jsonObject(with: Data($0.value.utf8)) as? [String: String])?["password"]) }
    }

    @Test func aCaptureJobHasItsCallerItsSelectorAndItsOwnBinding() throws {
        #expect(try Self.request("capture").operation == .capture)
        #expect(throws: VaultFailure.caller) { try VaultRequest(data: Data(#"{"v":2,"op":"capture","job":41}"#.utf8)) }
        func job(_ change: [String: Any] = [:], without key: String? = nil, operation: String = "capture") throws -> VaultCreateJob {
            var fields = Self.captureConfirmation(change)
            if let key { fields.removeValue(forKey: key) }
            return try VaultCreateJob(data: JSONSerialization.data(withJSONObject: fields), request: Self.request(operation), agent: "studio")
        }
        let good = try job().creation
        #expect(good.kind == .capture && good.selector == "#api-key" && good.origin == "https://shop.example.test")
        #expect(try job(["selector": #"form[data-kind="key"] input[name='secret']"#]).creation.selector == #"form[data-kind="key"] input[name='secret']"#)
        for bad: [String: Any] in [["selector": ""], ["selector": "two\nlines"], ["selector": String(repeating: "a", count: 501)], ["selector": 7],
                                   ["selector": NSNull()], ["kind": "create"], ["mark": "fleet-add:" + Self.captureID]] {
            #expect(throws: VaultFailure.hub) { _ = try job(bad) }
        }
        #expect(throws: VaultFailure.hub) { _ = try job(without: "selector") }
        #expect(throws: VaultFailure.hub) { _ = try job(operation: "create") }                 // the answer is of another kind
        #expect(throws: VaultFailure.hub) { _ = try job(["kind": "create"], operation: "create") }   // a create has no selector
        // The binding of a capture has its kind and its selector. The binding of a create is as it was.
        var create = good; create.kind = .create; create.selector = nil
        var other = good; other.selector = "#other-key"
        #expect(Set([good.binding, create.binding, other.binding]).count == 3)
        let before: [String: Any] = ["db": create.db, "agent": create.agent, "task": create.task, "attempt": create.attempt, "project": "shop",
                                     "label": create.label, "username": create.username, "url": create.url]
        let canonical = try JSONSerialization.data(withJSONObject: before, options: [.sortedKeys, .withoutEscapingSlashes])
        #expect(create.binding == SHA256Hex.of(canonical))
        // An older vault does not know the operation: its fixed refusal, and nothing else.
        #expect(throws: VaultFailure.request) { try VaultRequest(data: Data(#"{"v":2,"op":"later","job":41,"agent":"studio","agent_key":"\#(Self.captureKey)"}"#.utf8)) }
        let ready = VaultBroker.status(agent: "studio", user: "sam", recipient: "age1" + String(repeating: "q", count: 58), creates: true)
        let closed = VaultBroker.status(agent: "studio", user: "sam", recipient: "age1" + String(repeating: "q", count: 58))
        #expect(ready["captures"] as? Bool == true && ready["creates"] as? Bool == true && closed["captures"] == nil && closed["creates"] == nil)
    }

    @Test func theVaultReadsTheOneTabThatShowsThePageInAnyWindowAndBehindAnotherTab() throws {
        let page = "http://100.96.10.20:8765/site/key"
        // Chrome's order is the windows and their tabs. Another tab is in front; the key's tab is behind it.
        let behind = [(id: 875477001, address: "https://example.com/"), (id: 875477436, address: page), (id: 875477500, address: "https://news.example.test/")]
        #expect(try VaultBrowser.chosenTab(for: page, in: behind) == 875477436)
        #expect(try VaultBrowser.chosenTab(for: page, in: [(id: 7, address: "chrome://newtab/"), (id: 8, address: page)]) == 8)
        // No tab shows the page: nothing of Chrome, another site with that path, the same site with another path, a
        // query, a fragment, other letters in the path, or an address that only begins with it.
        let near = ["https://100.96.10.20:8765/site/key", "http://100.96.10.20:8766/site/key", "http://100.96.10.20:8765/site/account",
                    page + "?again=1", page + "#top", "http://100.96.10.20:8765/site/Key", page + "s", page + "/", "http://100.96.10.20:8765/"]
        #expect(throws: VaultFailure.captureTab) { _ = try VaultBrowser.chosenTab(for: page, in: []) }
        #expect(throws: VaultFailure.captureTab) { _ = try VaultBrowser.chosenTab(for: page, in: near.enumerated().map { (id: $0.offset + 1, address: $0.element) }) }
        // Two tabs show the page, in one window or in two: the vault does not choose.
        #expect(throws: VaultFailure.captureTabs) {
            _ = try VaultBrowser.chosenTab(for: page, in: [(id: 3, address: page), (id: 4, address: "https://example.com/"), (id: 9, address: page)])
        }
        #expect(VaultFailure.captureTab.rawValue == "No Chrome tab shows that address.")
        #expect(VaultFailure.captureTabs.rawValue == "More than one Chrome tab shows that address. Close all but one.")
        // The comparison is of the whole address as it is: no other form of it counts.
        #expect(throws: VaultFailure.captureTab) { _ = try VaultBrowser.chosenTab(for: "https://Console.Example.test:443", in: [(id: 5, address: "https://console.example.test/")]) }
        #expect(try VaultBrowser.chosenTab(for: page + "?q=A%20b#F", in: [(id: 5, address: page), (id: 6, address: page + "?q=A%20b#F")]) == 6)
    }

    /// The fault of the first version: a tab id of 2^29 or more (875477436 on the real machine) is no integer for
    /// AppleScript, and as text it has an exponent form. So the id comes to the vault as a number. This test runs
    /// AppleScript that is arithmetic only: it addresses no application.
    @MainActor @Test func aLargeTabIdComesFromAppleScriptAsTheSameNumber() throws {
        func run(_ source: String) throws -> NSAppleEventDescriptor {
            var error: NSDictionary?
            let result = try #require(NSAppleScript(source: source)).executeAndReturnError(&error)
            #expect(error == nil)
            return result
        }
        let page = "http://100.96.10.20:8765/site/key"
        // The answer of the list script has this form: for each tab its id `as integer` and its address `as text`.
        let answer = try run(#"return {{875477001 as integer, "https://example.com/" as text}, {875477436 as integer, "\#(page)" as text}, "#
                             + #"{2147483647 as integer, "https://last.example.test/" as text}, {7 as integer, "chrome://newtab/" as text}}"#)
        let tabs = VaultBrowser.tabs(in: answer)
        #expect(tabs.map(\.id) == [875477001, 875477436, 2147483647, 7])
        #expect(tabs.map(\.address) == ["https://example.com/", page, "https://last.example.test/", "chrome://newtab/"])
        #expect(try VaultBrowser.chosenTab(for: page, in: tabs) == 875477436)
        // As text, the same id is no number that can be read back: this is what the first version got.
        let text = try #require(try run("return (875477436 as integer) as text").stringValue)
        #expect(text != "875477436" && Int(text) == nil)
        // A list that Chrome gives with whole-number ids has the same result.
        let made = NSAppleEventDescriptor.list()
        for (index, id) in [NSAppleEventDescriptor(int32: 875477436), NSAppleEventDescriptor(double: 875477436)].enumerated() {
            let pair = NSAppleEventDescriptor.list()
            pair.insert(id, at: 1)
            pair.insert(NSAppleEventDescriptor(string: page + "#\(index)"), at: 2)
            made.insert(pair, at: index + 1)
        }
        #expect(VaultBrowser.tabs(in: made).map(\.id) == [875477436, 875477436])
        // An answer that is no list of pairs has no tab.
        made.insert(NSAppleEventDescriptor(string: "no pair"), at: 3)
        #expect(VaultBrowser.tabs(in: made).count == 2 && VaultBrowser.tabs(in: NSAppleEventDescriptor(string: "")).isEmpty)
        #expect(VaultBrowser.tabs(in: try run("return {}")).isEmpty)
    }

    @Test func theVaultAsksChromeForItsTabsAndThenReadsOnlyInTheChosenTab() throws {
        // The first script runs nothing in a page: it gives ids and addresses.
        let list = VaultBrowser.tabsSource
        #expect(list.contains("repeat with w in windows") && list.contains("repeat with t in tabs of w") && !list.contains("execute") && !list.contains("javascript"))
        #expect(!list.contains("front window") && !list.contains("active tab"))
        // Each tab is a pair of a number and a text. No id becomes text in the script.
        #expect(list.contains("set end of found to {(id of t) as integer, (URL of t) as text}") && !list.contains("integer) as text"))
        // The second script reads in the tab with that id, only while it still has that exact address, with the letters as they are.
        let address = "http://100.96.10.20:8765/site/key?q=\"a\"\\b"
        let source = try VaultBrowser.captureSource(tab: 875477436, address: address, origin: "http://100.96.10.20:8765", selector: "#key")
        #expect(source.contains("if (id of t as integer) is 875477436 then") && source.contains("considering case"))
        #expect(source.contains(#"if (URL of t) is "http://100.96.10.20:8765/site/key?q=\"a\"\\b" then return (execute t javascript "#))
        #expect(!source.contains("front window") && !source.contains("active tab") && !source.contains("starts with"))
        // The script that reads is the one with the origin check and the one-field check, as text for AppleScript.
        let script = try VaultBrowser.captureScript(origin: "http://100.96.10.20:8765", selector: "#key")
        #expect(source.contains(script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")))
        #expect(script.contains("location.origin!==") && script.contains("m.length!==1"))
    }

    @Test func theCaptureScriptChecksTheOriginAndTakesOneFieldAndItsAnswerIsReadExactly() throws {
        let selector = #"input[name="api \"key\""] > code.it's"#
        let script = try VaultBrowser.captureScript(origin: "https://shop.example.test", selector: selector)
        #expect(script.contains("location.origin!==" + (try VaultBrowser.jsonString("https://shop.example.test"))) &&
                script.contains("document.querySelectorAll(") && script.contains("m.length!==1") && script.contains("JSON.stringify"))
        #expect(script.contains(try VaultBrowser.jsonString(selector)) && !script.contains("querySelectorAll(" + selector))   // quoted as data
        func answer(_ object: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) }
        // Every value comes back as the page has it: short, with white space, with quotes and other scripts.
        for value in ["x", " leading and trailing ", "two\nlines\tand a tab", #"quote " back \ slash"#, "kľúč-🔑-\u{301}e", String(repeating: "k", count: 4096)] {
            #expect(try VaultBrowser.captured(answer(["s": "ok", "v": value])) == value)
        }
        #expect(throws: VaultFailure.captureEmpty) { _ = try VaultBrowser.captured(answer(["s": "ok", "v": ""])) }
        #expect(throws: VaultFailure.captureTab) { _ = try VaultBrowser.captured("") }               // the tab does not show the page any more
        #expect(throws: VaultFailure.captureTab) { _ = try VaultBrowser.captured(answer(["s": "wrong-origin"])) }
        for count in [0, 2, 7] { #expect(throws: VaultFailure.captureField) { _ = try VaultBrowser.captured(answer(["s": "count", "n": count])) } }
        #expect(throws: VaultFailure.captureField) { _ = try VaultBrowser.captured(answer(["s": "bad-selector"])) }
        for odd in ["not json", #"{"s":"ok"}"#, #"{"s":"ok","v":7}"#, #"{"s":"later"}"#, "[]"] {
            #expect(throws: VaultFailure.browser) { _ = try VaultBrowser.captured(odd) }
        }
    }

    @Test func aCaptureSavesTheExactValueOnceAndAnswersWithTheReferenceOnly() async throws {
        for value in ["sk_live_SYNTHETIC-0123456789abcdef", "x", " key with spaces\tand \"quotes\" 🔑 "] {
            let items = FakeItems(), store = FakeKeychainJournal(), page = Page([value])
            FakeHub.reset(answer: Self.hubAnswering(Self.captureConfirmation()))
            let writer = try Self.saver(items, store)
            let reply = try await Self.capture(writer, page)
            let made = try #require(items.stored.first)
            #expect(NSDictionary(dictionary: reply) == NSDictionary(dictionary: ["ok": true, "v": 2, "job": 41, "login": "bws://" + made.key.lowercased()]))
            #expect(try Self.password(of: items) == [value])                                 // exactly as the page had it
            #expect(made.value.name == "Shop API key" && made.value.note == "fleet-create:studio:" + Self.captureID)
            #expect(page.asked == [.init(page: "https://shop.example.test/settings/keys", selector: "#api-key")])   // the page that the hub confirmed
            // A value that the hub's filter can find gets its fingerprint; a short one, or one with white space, is
            // saved all the same and only not masked.
            let masked = value.unicodeScalars.count >= 8 && !value.contains(" ")
            #expect(FakeHub.seen.map(\.route) == ["/helper/vault/studio", "/helper/vault/studio/created"] + (masked ? ["/helper/vault/studio/fingerprints"] : []))
            let texts = [String(decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self), String(decoding: try #require(store.data), as: UTF8.self)]
            if value.count > 1 { for text in texts { #expect(!text.contains(value)) } }
            // The same request again: no page is read and nothing is made.
            FakeHub.reset(answer: Self.hubAnswering(Self.captureConfirmation()))
            #expect(NSDictionary(dictionary: try await Self.capture(try Self.saver(items, store), page)) == NSDictionary(dictionary: reply))
            #expect(page.asked.count == 1 && items.creates == 1)
        }
    }

    @Test func aModelProviderSiteMakesNothingAndReadsNoPage() async throws {
        // The hub refuses these first (`save_job`). The vault refuses them too, as `vault.py`'s `creation` does.
        for url in ["https://chatgpt.com/signup", "https://auth.openai.com/log-in", "https://app.claude.ai/settings", "https://api.x.ai/keys"] {
            let items = FakeItems(), store = FakeKeychainJournal()
            FakeHub.reset(answer: Self.answering(Self.confirmation(["url": url])))
            let reply = try await Self.create(try Self.hub(), try Self.writer(items, store))
            #expect(NSDictionary(dictionary: reply) == NSDictionary(dictionary: ["ok": false, "v": 2, "error": VaultFailure.modelProvider.rawValue]))
            #expect(items.creates == 0 && store.data == nil && FakeHub.seen.map(\.route) == ["/helper/vault/studio"])
        }
        // A capture on a provider's site, or one whose page is there: no page is read and nothing is made.
        for change in [["url": "https://auth.openai.com/api-keys"], ["source_url": "https://chatgpt.com/settings"]] {
            let items = FakeItems(), store = FakeKeychainJournal(), page = Page(["sk-SYNTHETIC-0123456789"])
            FakeHub.reset(answer: Self.hubAnswering(Self.captureConfirmation(change)))
            let reply = try await Self.capture(try Self.saver(items, store), page)
            #expect(NSDictionary(dictionary: reply) == NSDictionary(dictionary: ["ok": false, "v": 2, "error": VaultFailure.modelProvider.rawValue]))
            #expect(page.asked.isEmpty && items.creates == 0 && store.data == nil)
        }
        // A key of a provider's paid API is no such login: it is read and saved.
        let items = FakeItems(), store = FakeKeychainJournal(), page = Page(["sk-SYNTHETIC-0123456789"])
        FakeHub.reset(answer: Self.hubAnswering(Self.captureConfirmation(["url": "https://platform.openai.com/api-keys"])))
        let saved = try await Self.capture(try Self.saver(items, store), page)
        #expect(saved["ok"] as? Bool == true && items.creates == 1 && page.asked.count == 1)
    }

    @Test func aPageThatDoesNotGiveOneValueMakesNothing() async throws {
        let cases: [(VaultFailure, VaultFailure)] = [(.captureTab, .captureTab), (.captureField, .captureField), (.captureEmpty, .captureEmpty),
                                                     (.browser, .browser)]
        for (thrown, expected) in cases {
            let items = FakeItems(), store = FakeKeychainJournal()
            FakeHub.reset(answer: Self.hubAnswering(Self.captureConfirmation()))
            let reply = try await Self.capture(try Self.saver(items, store), Page(failing: thrown))
            #expect(NSDictionary(dictionary: reply) == NSDictionary(dictionary: ["ok": false, "v": 2, "error": expected.rawValue]))
            #expect(items.creates == 0 && store.data == nil && FakeHub.seen.map(\.route) == ["/helper/vault/studio"])
        }
        // A value that does not fit the vault's size is refused by the existing rule, and nothing is sent.
        let items = FakeItems(), store = FakeKeychainJournal()
        FakeHub.reset(answer: Self.hubAnswering(Self.captureConfirmation()))
        let long = try await Self.capture(try Self.saver(items, store), Page([String(repeating: "k", count: 25_001)]))
        #expect(long["error"] as? String == VaultWriteRefusal.tooLong.rawValue && items.creates == 0)
    }

    @Test func theSameRequestCannotChangeItsSelectorOrItsOperation() async throws {
        let items = FakeItems(), store = FakeKeychainJournal(), page = Page(["sk_live_SYNTHETIC-first-value"])
        FakeHub.reset(answer: Self.hubAnswering(Self.captureConfirmation()))
        let first = try await Self.capture(try Self.saver(items, store), page)
        #expect(first["ok"] as? Bool == true)
        let changed: NSDictionary = ["ok": false, "v": 2, "error": VaultWriteRefusal.changed.rawValue]
        // Another selector, another attempt, another label: a changed request. The page is not read again.
        for change in [["selector": "#other-key"], ["attempt": 3], ["label": "Other"]] as [[String: Any]] {
            FakeHub.reset(answer: Self.hubAnswering(Self.captureConfirmation(change)))
            #expect(NSDictionary(dictionary: try await Self.capture(try Self.saver(items, store), page)) == changed)
        }
        // The same request as a create: also changed. And a request that began as a create cannot become a capture.
        var asCreate = Self.captureConfirmation(["kind": "create"]); asCreate.removeValue(forKey: "selector")
        FakeHub.reset(answer: Self.hubAnswering(asCreate))
        #expect(NSDictionary(dictionary: try await Self.capture(try Self.saver(items, store), page, operation: "create")) == changed)
        let other = FakeItems(), otherStore = FakeKeychainJournal()
        FakeHub.reset(answer: Self.hubAnswering(asCreate))
        #expect((try await Self.capture(try Self.saver(other, otherStore), page, operation: "create"))["ok"] as? Bool == true)
        FakeHub.reset(answer: Self.hubAnswering(Self.captureConfirmation()))
        #expect(NSDictionary(dictionary: try await Self.capture(try Self.saver(other, otherStore), page)) == changed)
        #expect(items.creates == 1 && other.creates == 1 && page.asked.count == 1)
        #expect(try Self.password(of: items) == ["sk_live_SYNTHETIC-first-value"])
    }

    @Test func twoCallsOfOneCaptureTogetherSendOneCreateCallAndKeepTheFirstValue() async throws {
        let items = FakeItems(), store = FakeKeychainJournal(), page = Page(["sk_live_SYNTHETIC-value-A", "sk_live_SYNTHETIC-value-B"])
        FakeHub.reset(answer: Self.hubAnswering(Self.captureConfirmation()))
        let writer = try Self.saver(items, store)
        async let one = Self.capture(writer, page)
        async let two = Self.capture(writer, page)
        let replies = try await [one, two]
        let saved = try Self.password(of: items)
        #expect(items.creates == 1 && saved.count == 1 && ["sk_live_SYNTHETIC-value-A", "sk_live_SYNTHETIC-value-B"].contains(saved[0]))
        #expect(replies.allSatisfy { $0["ok"] as? Bool == true } && replies[0]["login"] as? String == replies[1]["login"] as? String)
        // A later call does not read the page and does not change the item.
        FakeHub.reset(answer: Self.hubAnswering(Self.captureConfirmation()))
        let later = try await Self.capture(writer, page)
        #expect(later["login"] as? String == replies[0]["login"] as? String && items.creates == 1 && page.asked.count <= 2)
        #expect(try Self.password(of: items) == saved)
    }

    @Test func anUncertainCaptureIsOnlyReconciledAndNeverReadsThePageAgain() async throws {
        let items = FakeItems(), store = FakeKeychainJournal(), page = Page(["sk_live_SYNTHETIC-uncertain-value"])
        items.answer = .lost; items.hidden = true
        FakeHub.reset(answer: Self.hubAnswering(Self.captureConfirmation()))
        let unknown: NSDictionary = ["ok": false, "v": 2, "unknown": true, "error": VaultFailure.saveUnknown.rawValue]
        #expect(NSDictionary(dictionary: try await Self.capture(try Self.saver(items, store), page)) == unknown)
        #expect(NSDictionary(dictionary: try await Self.capture(try Self.saver(items, store), page)) == unknown)
        #expect(items.creates == 1 && page.asked.count == 1)
        items.hidden = false
        FakeHub.reset(answer: Self.hubAnswering(Self.captureConfirmation()))
        let found = try await Self.capture(try Self.saver(items, store), page)
        #expect(found["ok"] as? Bool == true && items.creates == 1 && page.asked.count == 1)
        #expect(try Self.password(of: items) == ["sk_live_SYNTHETIC-uncertain-value"])
    }

    @Test func aCapturedLoginIsUsedInItsTaskOnlyWithItsOwnDescriptor() async throws {
        let items = FakeItems(), store = FakeKeychainJournal()
        FakeHub.reset(answer: Self.hubAnswering(Self.captureConfirmation()))
        let made = try #require((try await Self.capture(try Self.saver(items, store), Page(["sk_live_SYNTHETIC-used-value"])))["login"] as? String)
        let writer = try Self.saver(items, store)
        func descriptor(_ change: [String: Any] = [:], without key: String? = nil) -> [String: Any] {
            var fields: [String: Any] = ["request_id": Self.captureID, "db": "test-generation", "agent": "studio", "attempt": 2, "label": "Shop API key",
                                         "username": "shop-key-1", "url": "https://shop.example.test/settings/keys", "kind": "capture", "selector": "#api-key"]
            fields.merge(change) { _, new in new }
            if let key { fields.removeValue(forKey: key) }
            return fields
        }
        func allowed(_ login: String, _ creation: [String: Any]) async throws -> Bool {
            let fields: [String: Any] = ["ok": true, "kind": "signin", "job": 50, "task": "T-7", "login": login, "project": "shop",
                                         "fingerprint_salts": Self.captureSalts, "source": login, "created_by": creation]
            let request = try Self.request("signin", job: 50)
            return await VaultBroker.madeHere(try VaultJob(data: JSONSerialization.data(withJSONObject: fields), request: request),
                                              operation: .signin, caller: Self.captureCaller, writer: writer)
        }
        #expect(try await allowed(made, descriptor()))
        #expect(try await !allowed("bws://99999999-0000-4000-8000-000000000000", descriptor()))     // a forged report names another login
        #expect(try await !allowed(made, descriptor(["selector": "#other-key"])))
        #expect(try await !allowed(made, descriptor(["attempt": 3])))
        var asCreate = descriptor(without: "selector"); asCreate.removeValue(forKey: "kind")          // the descriptor of a create
        #expect(try await !allowed(made, asCreate))
        // A capture descriptor needs its selector, and a create descriptor has none.
        let job: [String: Any] = ["ok": true, "kind": "signin", "job": 50, "task": "T-7", "login": made, "project": "shop",
                                  "fingerprint_salts": Self.captureSalts, "source": made]
        for bad in [descriptor(without: "selector"), descriptor(["kind": "create"]), descriptor(["kind": "other"])] {
            let fields = job.merging(["created_by": bad]) { _, new in new }
            #expect(throws: VaultFailure.hub) { _ = try VaultJob(data: JSONSerialization.data(withJSONObject: fields), request: Self.request("signin", job: 50)) }
        }
    }

    @Test func aKeyReadOnOneAddressAndUsedOnAnotherIsBoundToBothAndNotUsedThereByItsOwnTask() async throws {
        let use = "https://api.shop.example.test/v1", page = "https://dashboard.shop.example.test/settings/keys"
        let confirmed = Self.captureConfirmation(["url": use, "source_url": page])
        func job(_ fields: [String: Any], operation: String = "capture") throws -> VaultCreateJob {
            try VaultCreateJob(data: JSONSerialization.data(withJSONObject: fields), request: Self.request(operation), agent: "studio")
        }
        // The page address is read where it is, in the form of `url`; a create has none.
        let made = try job(confirmed).creation
        #expect(made.source == page && made.readOrigin == "https://dashboard.shop.example.test" && made.origin == "https://api.shop.example.test")
        let onItsPage = try job(Self.captureConfirmation()).creation.usesItsSource
        #expect(!made.usesItsSource && onItsPage)
        for bad: Any in ["ftp://dashboard.shop.example.test", "https://owner:pw@dashboard.shop.example.test", "dashboard.shop.example.test",
                         "two\nlines", String(repeating: "a", count: 501), 7] {
            #expect(throws: VaultFailure.hub) { _ = try job(Self.captureConfirmation(["source_url": bad])) }
        }
        var create = Self.captureConfirmation(["kind": "create", "source_url": page]); create.removeValue(forKey: "selector")
        #expect(throws: VaultFailure.hub) { _ = try job(create, operation: "create") }
        // The binding has the page address when there is one. Without one it is the binding of a capture as before.
        let plain = try job(Self.captureConfirmation()).creation
        let before: [String: Any] = ["db": plain.db, "agent": plain.agent, "task": plain.task, "attempt": plain.attempt, "project": "shop",
                                     "label": plain.label, "username": plain.username, "url": plain.url, "kind": "capture", "selector": "#api-key"]
        #expect(plain.binding == SHA256Hex.of(try JSONSerialization.data(withJSONObject: before, options: [.sortedKeys, .withoutEscapingSlashes])))
        let withoutPage = try job(Self.captureConfirmation(["url": use])).creation.binding
        let otherPage = try job(Self.captureConfirmation(["url": use, "source_url": "https://other.example.test/keys"])).creation.binding
        #expect(Set([made.binding, withoutPage, otherPage]).count == 3)

        // The vault reads on the page's origin and saves the exact value with the use address.
        let items = FakeItems(), store = FakeKeychainJournal(), shown = Page(["x"])        // a short key is a key
        FakeHub.reset(answer: Self.hubAnswering(confirmed))
        let login = try #require((try await Self.capture(try Self.saver(items, store), shown))["login"] as? String)
        #expect(shown.asked == [.init(page: page, selector: "#api-key")])
        let item = try #require(items.stored.values.first)
        let saved = try #require(try JSONSerialization.jsonObject(with: Data(item.value.utf8)) as? [String: String])
        #expect(saved == ["username": "shop-key-1", "password": "x", "url": use])
        // The same request cannot move to another page or lose its page.
        let changed: NSDictionary = ["ok": false, "v": 2, "error": VaultWriteRefusal.changed.rawValue]
        for other in [Self.captureConfirmation(["url": use, "source_url": "https://other.example.test/keys"]), Self.captureConfirmation(["url": use])] {
            FakeHub.reset(answer: Self.hubAnswering(other))
            #expect(NSDictionary(dictionary: try await Self.capture(try Self.saver(items, store), shown)) == changed)
        }
        #expect(items.creates == 1 && shown.asked.count == 1)

        // Use in the task that saved it: the journal has the save, but the use address is not the page's address.
        let writer = try Self.saver(items, store)
        func refusal(_ reference: String, _ change: [String: Any] = [:], without key: String? = nil) async throws -> VaultFailure? {
            var creation: [String: Any] = ["request_id": Self.captureID, "db": "test-generation", "agent": "studio", "attempt": 2, "label": "Shop API key",
                                           "username": "shop-key-1", "url": use, "kind": "capture", "selector": "#api-key", "source_url": page]
            creation.merge(change) { _, new in new }
            if let key { creation.removeValue(forKey: key) }
            let fields: [String: Any] = ["ok": true, "kind": "signin", "job": 60, "task": "T-7", "login": reference, "project": "shop",
                                         "fingerprint_salts": Self.captureSalts, "source": reference, "created_by": creation]
            let signin = try VaultJob(data: JSONSerialization.data(withJSONObject: fields), request: Self.request("signin", job: 60))
            return await VaultBroker.refusal(ofMadeUse: signin, operation: .signin, caller: Self.captureCaller, writer: writer)
        }
        #expect(try await refusal(login) == .captureUse)
        // A descriptor that leaves the page out, or names the use address as the page, is not the save of the journal.
        #expect(try await refusal(login, without: "source_url") == .notMadeHere)
        #expect(try await refusal(login, ["source_url": use]) == .notMadeHere)
        #expect(try await refusal("bws://99999999-0000-4000-8000-000000000000") == .notMadeHere)

        // A key whose page and use address have one origin is used by its own task, with or without the page address.
        let same = FakeItems(), sameStore = FakeKeychainJournal()
        let onePage = "https://shop.example.test/settings/keys"
        FakeHub.reset(answer: Self.hubAnswering(Self.captureConfirmation(["url": "https://shop.example.test/api", "source_url": onePage])))
        let sameLogin = try #require((try await Self.capture(try Self.saver(same, sameStore), Page(["sk_live_SYNTHETIC-same-origin"])))["login"] as? String)
        let sameWriter = try Self.saver(same, sameStore)
        let creation: [String: Any] = ["request_id": Self.captureID, "db": "test-generation", "agent": "studio", "attempt": 2, "label": "Shop API key",
                                       "username": "shop-key-1", "url": "https://shop.example.test/api", "kind": "capture", "selector": "#api-key",
                                       "source_url": onePage]
        let fields: [String: Any] = ["ok": true, "kind": "signin", "job": 61, "task": "T-7", "login": sameLogin, "project": "shop",
                                     "fingerprint_salts": Self.captureSalts, "source": sameLogin, "created_by": creation]
        let signin = try VaultJob(data: JSONSerialization.data(withJSONObject: fields), request: Self.request("signin", job: 61))
        #expect(await VaultBroker.refusal(ofMadeUse: signin, operation: .signin, caller: Self.captureCaller, writer: sameWriter) == nil)
    }
}

/// A stand-in for the Chrome page of a capture: it gives its values in order, one for each read, or fails.
private final class Page: @unchecked Sendable {
    struct Ask: Equatable { let page: String; let selector: String }
    private let lock = NSLock()
    private var values: [String]
    private let failure: VaultFailure?
    private var asks: [Ask] = []
    init(_ values: [String]) { self.values = values; failure = nil }
    init(failing failure: VaultFailure) { values = []; self.failure = failure }
    var asked: [Ask] { lock.withLock { asks } }
    var read: @Sendable (String, String) async throws -> String {
        { page, selector in
            try await Task.sleep(for: .milliseconds(5))                       // a page read takes time: two calls can overlap
            return try self.lock.withLock {
                self.asks.append(Ask(page: page, selector: selector))
                if let failure = self.failure { throw failure }
                return self.values.count > 1 ? self.values.removeFirst() : self.values[0]
            }
        }
    }
}

private enum SHA256Hex {
    static func of(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// A value for a sendable closure of a test.
private final class SendableBox: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}
