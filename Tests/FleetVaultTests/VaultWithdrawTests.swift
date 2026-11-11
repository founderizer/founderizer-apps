import Foundation
import Testing
@testable import FleetVaultCore

/// The `withdraw` operation (helper feature secret_withdrawals) through the broker: a secret that the owner's vault
/// delivered into this machine's store leaves it when no agent of the machine holds it any more. The hub is `FakeHub`
/// and the values are synthetic. These tests are part of the serialized suite of `FakeHub`.
extension VaultCallerTests {
    private static let withdrawKey = "STUDIO-KEY_" + String(repeating: "w", count: 32)
    private static let withdrawReference = "bws://ABCDEF12-1234-1234-1234-123456789012"

    private static func withdrawConfiguration(_ store: [String: Any]) throws -> VaultConfiguration {
        try VaultConfiguration(data: JSONSerialization.data(withJSONObject: [
            "agent": "studio", "hub": "http://100.64.0.1:9", "worker_uid": 501,       // no hub listens there
            "socket": NSHomeDirectory() + "/Library/Application Support/AgentFleet/vault.sock"].merging(store) { _, new in new }))
    }

    private static func withdrawFields(_ changes: [String: Any] = [:]) -> [String: Any] {
        ["ok": true, "job": 6, "kind": "withdraw", "login": withdrawReference].merging(changes) { _, new in new }
    }

    /// A hub that names `given` for withdrawal 6 of studio, and nothing else.
    private static func withdrawAnswers(_ given: [String: Any]) -> @Sendable (String, [String: Any]) -> (Int, Any) {
        let answer = WithdrawAnswer(given)
        return { route, body in
            route == "/helper/vault/studio" && body["kind"] as? String == "withdraw" && body["job"] as? Int == 6
                ? (200, answer.value) : (404, ["error": "no such withdrawal waits for this agent"] as [String: Any])
        }
    }

    private static func withdrawReply(remove: @escaping (String) throws -> String) async throws -> NSDictionary {
        let request = try VaultRequest(data: JSONSerialization.data(withJSONObject: [
            "v": 2, "op": "withdraw", "job": 6, "agent": "studio", "agent_key": withdrawKey]))
        let caller = try #require(request.caller)
        let hub = VaultHub(configuration: try withdrawConfiguration(["store": "fleet"]), protocolClasses: [FakeHub.self])
        return NSDictionary(dictionary: await VaultBroker.withdraw(request, as: caller, hub: hub, remove: remove))
    }

    private static func withdrawRefusal(_ failure: VaultFailure) -> NSDictionary {
        NSDictionary(dictionary: ["ok": false, "v": 2, "error": failure.rawValue])
    }

    @Test func aWithdrawalNamesItsJobAndAlwaysItsCaller() throws {
        let named = try VaultRequest(data: JSONSerialization.data(withJSONObject: [
            "v": 2, "op": "withdraw", "job": 6, "agent": "studio", "agent_key": Self.withdrawKey]))
        #expect(named.operation == .withdraw && named.job == 6 && named.caller == VaultCaller(agent: "studio", key: Self.withdrawKey))
        // The helper of a shared broker names its agent: a withdrawal acts for that agent at the hub, and for no other.
        #expect(throws: VaultFailure.caller) { try VaultRequest(data: Data(#"{"v":2,"op":"withdraw","job":6}"#.utf8)) }
        // The helper names only the withdrawal: never the login, which the hub names.
        for bad: [String: Any] in [[:], ["job": 0], ["job": "6"], ["job": 6, "login": Self.withdrawReference]] {
            let fields = bad.merging(["v": 2, "op": "withdraw", "agent": "studio", "agent_key": Self.withdrawKey]) { a, _ in a }
            #expect(throws: VaultFailure.request) { try VaultRequest(data: JSONSerialization.data(withJSONObject: fields)) }
        }
    }

    /// The helper reads `withdrawals`, and the hub asks this machine for a withdrawal only when it is there.
    @Test func theStatusSaysWithdrawalsOnlyWhenAsked() {
        let recipient = "age1" + String(repeating: "q", count: 58)
        let both = VaultBroker.status(agent: "studio", user: "sam", recipient: recipient, deposits: true, withdrawals: true)
        #expect(both["withdrawals"] as? Bool == true && both["deposits"] as? Bool == true)
        #expect(VaultBroker.status(agent: "studio", user: "sam", recipient: recipient, deposits: true)["withdrawals"] == nil)
    }

    @Test func theHubNamesTheSecretAndTheStoreRemovesIt() async throws {
        FakeHub.reset(answer: Self.withdrawAnswers(Self.withdrawFields()))
        let removed = RemovedIDs()
        let reply = try await Self.withdrawReply { id in removed.add(id); return "removed" }
        #expect(reply == ["ok": true, "v": 2, "withdrawal": 6, "login": Self.withdrawReference.lowercased(), "removed": "removed"])
        // The hub was asked once, as the calling agent, and the store got the id of the hub's reference.
        #expect(FakeHub.seen == [FakeHub.Seen(route: "/helper/vault/studio", authorization: "Bearer " + Self.withdrawKey)])
        #expect(removed.all == ["abcdef12-1234-1234-1234-123456789012"])
        // A store that does not have it says so, and that is no refusal: the same withdrawal again ends the same way.
        FakeHub.reset(answer: Self.withdrawAnswers(Self.withdrawFields()))
        #expect(try await Self.withdrawReply { _ in "absent" }["removed"] as? String == "absent")
    }

    @Test func nothingIsRemovedWithoutTheHubsReference() async throws {
        let removed = RemovedIDs()
        let remove: (String) throws -> String = { id in removed.add(id); return "removed" }
        // The hub's answer in another form: nothing is removed.
        for given in [Self.withdrawFields(["kind": "deposit"]), Self.withdrawFields(["job": 7]), Self.withdrawFields(["ok": false]),
                      Self.withdrawFields(["login": "sealed:7"]), Self.withdrawFields(["login": "bws://not-a-reference"]), ["ok": true]] {
            FakeHub.reset(answer: Self.withdrawAnswers(given))
            #expect(try await Self.withdrawReply(remove: remove) == Self.withdrawRefusal(.hub))
        }
        FakeHub.reset { _, _ in (404, ["error": "no such withdrawal waits for this agent"]) }
        #expect(try await Self.withdrawReply(remove: remove) == Self.withdrawRefusal(.hub))
        FakeHub.reset { _, _ in (403, ["error": "this is not studio's agent key", "auth": "key_mismatch"]) }
        #expect(try await Self.withdrawReply(remove: remove) == Self.withdrawRefusal(.key))
        #expect(removed.all.isEmpty)
        // A login that no delivery saved stays, and the answer says why.
        FakeHub.reset(answer: Self.withdrawAnswers(Self.withdrawFields()))
        #expect(try await Self.withdrawReply { _ in throw VaultFailure.withdrawNotDelivered } == Self.withdrawRefusal(.withdrawNotDelivered))
    }
}

/// The hub's answer for a sendable closure of a test.
private final class WithdrawAnswer: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}

/// The ids that the store was asked to remove.
private final class RemovedIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    func add(_ id: String) { lock.withLock { ids.append(id) } }
    var all: [String] { lock.withLock { ids } }
}
