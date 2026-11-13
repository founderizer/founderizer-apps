import Foundation
import Testing
@testable import FleetVaultCore

/// The `deposit` operation (owner feature secret_deliveries) through the broker: a key or a login that the owner typed
/// into Founderizer and sealed there to this machine's vault key. The hub is `FakeHub`, the copy is opened by a stand-in
/// for `age`, and the values are synthetic. These tests are part of the serialized suite of `FakeHub`.
extension VaultCallerTests {
    private static let depositKey = "STUDIO-KEY_" + String(repeating: "d", count: 32)
    private static let depositSalts = ["password": "0123456789abcdef0123456789abcdef", "totp": "fedcba9876543210fedcba9876543210"]
    private static let depositReference = "bws://ABCDEF12-1234-1234-1234-123456789012"
    private static let depositValue = "sk-synthetic-DEPOSIT-0123456789"
    private static let depositCopy = "-----BEGIN AGE ENCRYPTED FILE-----\nSYNTHETIC\n-----END AGE ENCRYPTED FILE-----\n"

    private static func depositHub() throws -> VaultHub {
        VaultHub(configuration: try VaultConfiguration(data: JSONSerialization.data(withJSONObject: [
            "agent": "studio", "hub": "http://100.64.0.1:9", "store": "fleet", "worker_uid": 501,
            "socket": NSHomeDirectory() + "/Library/Application Support/AgentFleet/vault.sock"])), protocolClasses: [FakeHub.self])
    }

    private static func depositFields(_ changes: [String: Any] = [:]) -> [String: Any] {
        ["ok": true, "job": 4, "kind": "deposit", "login": depositReference, "title": "OPENAI_API_KEY", "item": "api_key",
         "ciphertext": depositCopy, "fingerprint_salts": depositSalts].merging(changes) { _, new in new }
    }

    /// A hub that gives `given` for delivery 4 and compares every value, or refuses each comparison.
    private static func depositAnswers(_ given: [String: Any], compares: Bool = true, seen: DepositBodies) -> @Sendable (String, [String: Any]) -> (Int, Any) {
        let answer = DepositAnswer(given)
        return { route, body in
            if route == "/helper/vault/studio/fingerprints" {
                seen.add(body)
                guard compares else { return (409, ["error": "this copy holds another value than the one the owner saved"]) }
                return (200, ["ok": true, "deposit": body["deposit"] ?? 0, "matched": (body["fingerprints"] as? [Any])?.count ?? 0])
            }
            return route == "/helper/vault/studio" && body["kind"] as? String == "deposit" && body["job"] as? Int == 4
                ? (200, answer.value) : (404, ["error": "no such delivery waits for this agent"] as [String: Any])
        }
    }

    private static func depositReply(payload: String?, put: @escaping (String, String, String, Bool) throws -> String = { _, _, _, _ in "new" })
        async throws -> NSDictionary {
        let request = try VaultRequest(data: JSONSerialization.data(withJSONObject: [
            "v": 2, "op": "deposit", "job": 4, "agent": "studio", "agent_key": depositKey]))
        let caller = try #require(request.caller), hub = try depositHub()
        let reply = await VaultBroker.deposit(request, as: caller, hub: hub, unseal: { sealed in
            guard String(decoding: sealed, as: UTF8.self) == depositCopy, let payload else { throw VaultFailure.handover }
            return Data(payload.utf8)
        }, put: put)
        return NSDictionary(dictionary: reply)
    }

    private static func depositRefusal(_ failure: VaultFailure) -> NSDictionary {
        NSDictionary(dictionary: ["ok": false, "v": 2, "error": failure.rawValue])
    }

    @Test func aDepositNamesItsDeliveryAndAlwaysItsCaller() throws {
        let named = try VaultRequest(data: JSONSerialization.data(withJSONObject: [
            "v": 2, "op": "deposit", "job": 4, "agent": "studio", "agent_key": Self.depositKey]))
        #expect(named.operation == .deposit && named.job == 4 && named.caller == VaultCaller(agent: "studio", key: Self.depositKey))
        // The helper of a shared broker names its agent: a deposit acts for that agent at the hub, and for no other.
        #expect(throws: VaultFailure.caller) { try VaultRequest(data: Data(#"{"v":2,"op":"deposit","job":4}"#.utf8)) }
        for bad: [String: Any] in [["job": 0], ["job": "4"], ["job": 4, "login": Self.depositReference], ["job": 4, "ciphertext": Self.depositCopy]] {
            let fields = bad.merging(["v": 2, "op": "deposit", "agent": "studio", "agent_key": Self.depositKey]) { a, _ in a }
            #expect(throws: VaultFailure.request) { try VaultRequest(data: JSONSerialization.data(withJSONObject: fields)) }
        }
    }

    /// The helper reads `deposits` to tell the hub that this machine's vault takes a delivered secret.
    @Test func theStatusSaysDepositsOnlyWhenAsked() {
        let recipient = "age1" + String(repeating: "q", count: 58)
        #expect(VaultBroker.status(agent: "studio", user: "sam", recipient: recipient, deposits: true)["deposits"] as? Bool == true)
        #expect(VaultBroker.status(agent: "studio", user: "sam", recipient: recipient)["deposits"] == nil)
    }

    @Test func anAPIKeyIsOpenedComparedAndSavedUnderItsOwnReference() async throws {
        let seen = DepositBodies()
        FakeHub.reset(answer: Self.depositAnswers(Self.depositFields(), seen: seen))
        let saved = SavedDeposits()
        let reply = try await Self.depositReply(payload: #"{"password":"\#(Self.depositValue)","username":""}"#) { id, name, value, replace in
            #expect(!replace)           // the hub's answer said nothing of a replace
            saved.add((id, name, value)); return "new"
        }
        #expect(reply == ["ok": true, "v": 2, "deposit": 4, "login": Self.depositReference.lowercased(), "saved": "new"])
        // The copy came from the hub and the comparison went to it before the save, both as the calling agent.
        #expect(FakeHub.seen.map(\.route) == ["/helper/vault/studio", "/helper/vault/studio/fingerprints"])
        #expect(FakeHub.seen.allSatisfy { $0.authorization == "Bearer " + Self.depositKey })
        let compared = try #require(seen.all.first)
        #expect(compared["deposit"] as? Int == 4)
        let prints = try #require(compared["fingerprints"] as? [[String: Any]])
        #expect(prints.count == 1 && prints[0]["kind"] as? String == "password" && prints[0]["len"] as? Int == Self.depositValue.count)
        #expect(!String(describing: compared).contains(Self.depositValue))
        // An API key without an address keeps its password only, under the store id of its reference.
        #expect(saved.all.count == 1)
        #expect(saved.all.first?.id == "abcdef12-1234-1234-1234-123456789012" && saved.all.first?.name == "OPENAI_API_KEY")
        #expect(saved.all.first?.value == #"{"password":"\#(Self.depositValue)"}"#)
        #expect(!(reply.description.contains(Self.depositValue)))
    }

    @Test func aLoginKeepsItsAddressItsUserAndItsSeed() throws {
        let login = #"{"password":"\#(Self.depositValue)","totp":"JBSWY3DPEHPK3PXP","url":"https://shop.example.test/login","username":"owner@example.test"}"#
        let kept = try VaultDeposit.value(Data(login.utf8), item: "login")
        #expect(kept.stored == login)
        #expect(kept.secret.password == Self.depositValue && kept.secret.totp == "JBSWY3DPEHPK3PXP")
        // An API key with an address is kept as a login, so a request can use it there.
        let addressed = try VaultDeposit.value(Data(#"{"password":"\#(Self.depositValue)","url":"https://api.example.test","username":""}"#.utf8), item: "api_key")
        #expect(addressed.stored == #"{"password":"\#(Self.depositValue)","url":"https://api.example.test","username":""}"#)
        // What is not a key or a login is refused, and the refusal says nothing of it.
        for bad in ["not json", #"{"username":"owner"}"#, #"{"password":""}"#, #"{"password":"\#(Self.depositValue)","url":"ftp://x"}"#,
                    #"{"password":"\#(Self.depositValue)","totp":7}"#] {
            #expect(throws: VaultFailure.depositItem) { try VaultDeposit.value(Data(bad.utf8), item: "login") }
        }
        #expect(throws: VaultFailure.depositItem) { try VaultDeposit.value(Data(#"{"password":"\#(Self.depositValue)"}"#.utf8), item: "login") }
    }

    @Test func aValueThatTheHubDoesNotConfirmIsNeverSaved() async throws {
        let seen = DepositBodies(), saved = SavedDeposits()
        let put: (String, String, String, Bool) throws -> String = { id, name, value, _ in saved.add((id, name, value)); return "new" }
        FakeHub.reset(answer: Self.depositAnswers(Self.depositFields(), compares: false, seen: seen))
        #expect(try await Self.depositReply(payload: #"{"password":"\#(Self.depositValue)"}"#, put: put) == Self.depositRefusal(.depositValue))
        // A copy that this vault's key does not open, and one that holds no key, go no further than the vault.
        FakeHub.reset(answer: Self.depositAnswers(Self.depositFields(), seen: seen))
        #expect(try await Self.depositReply(payload: nil, put: put) == Self.depositRefusal(.depositCopy))
        #expect(try await Self.depositReply(payload: #"{"note":"nothing"}"#, put: put) == Self.depositRefusal(.depositItem))
        #expect(seen.all.count == 1)
        // The hub's answer in another form: nothing is opened.
        for given in [Self.depositFields(["item": "card"]), Self.depositFields(["login": "sealed:7"]), Self.depositFields(["job": 5]),
                      Self.depositFields(["ciphertext": "SYNTHETIC"]), Self.depositFields(["title": " padded "]),
                      Self.depositFields(["fingerprint_salts": ["password": "short"]]), ["ok": true]] {
            FakeHub.reset(answer: Self.depositAnswers(given, seen: seen))
            #expect(try await Self.depositReply(payload: #"{"password":"\#(Self.depositValue)"}"#, put: put) == Self.depositRefusal(.hub))
        }
        FakeHub.reset { _, _ in (409, ["error": "this machine's pinned vault key changed since the owner sealed this copy"]) }
        #expect(try await Self.depositReply(payload: #"{"password":"\#(Self.depositValue)"}"#, put: put) == Self.depositRefusal(.hub))
        #expect(saved.all.isEmpty)
        // The store refuses another value under this reference: the answer says so and nothing changed.
        FakeHub.reset(answer: Self.depositAnswers(Self.depositFields(), seen: seen))
        #expect(try await Self.depositReply(payload: #"{"password":"\#(Self.depositValue)"}"#) { _, _, _, _ in throw VaultFailure.storeOther }
                == Self.depositRefusal(.storeOther))
        #expect(try await Self.depositReply(payload: #"{"password":"\#(Self.depositValue)"}"#) { _, _, _, _ in "same" }["saved"] as? String == "same")
    }

    /// The owner replaced the value of the reference: the hub says so in its answer for the delivery, never the
    /// helper in its request, and the store gets that word with the value.
    @Test func aDeliveryThatTheHubMarksSoReplacesTheDeliveredValue() async throws {
        let seen = DepositBodies()
        for (given, expected) in [(Self.depositFields(["replaces": true]), true), (Self.depositFields(), false),
                                  (Self.depositFields(["replaces": "yes"]), false), (Self.depositFields(["replaces": false]), false)] {
            FakeHub.reset(answer: Self.depositAnswers(given, seen: seen))
            let reply = try await Self.depositReply(payload: #"{"password":"\#(Self.depositValue)"}"#) { _, _, _, replace in
                #expect(replace == expected)
                return replace ? "replaced" : "new"
            }
            #expect(reply["saved"] as? String == (expected ? "replaced" : "new"))
        }
        // a value that did not come here by a delivery is not replaced, and the answer says so
        FakeHub.reset(answer: Self.depositAnswers(Self.depositFields(["replaces": true]), seen: seen))
        #expect(try await Self.depositReply(payload: #"{"password":"\#(Self.depositValue)"}"#) { _, _, _, _ in throw VaultFailure.storeNotDelivered }
                == Self.depositRefusal(.storeNotDelivered))
        let recipient = "age1" + String(repeating: "q", count: 58)
        #expect(VaultBroker.status(agent: "studio", user: "sam", recipient: recipient, replaces: true)["replaces"] as? Bool == true)
        #expect(VaultBroker.status(agent: "studio", user: "sam", recipient: recipient)["replaces"] == nil)
    }
}

/// The hub's answer for a sendable closure of a test.
private final class DepositAnswer: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}

/// The bodies of the comparisons that the hub got.
private final class DepositBodies: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [[String: Any]] = []
    func add(_ body: [String: Any]) { lock.withLock { bodies.append(body) } }
    var all: [[String: Any]] { lock.withLock { bodies } }
}

/// What the store was given.
private final class SavedDeposits: @unchecked Sendable {
    private let lock = NSLock()
    private var saved: [(id: String, name: String, value: String)] = []
    func add(_ item: (id: String, name: String, value: String)) { lock.withLock { saved.append(item) } }
    var all: [(id: String, name: String, value: String)] { lock.withLock { saved } }
}
