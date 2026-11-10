import Foundation
import Testing
@testable import FleetVaultCore

/// The `read` operation (owner feature secrets) through the broker: the hub is `FakeHub`, and the values are synthetic.
/// These tests are part of the serialized suite of `FakeHub`.
extension VaultCallerTests {
    private static let readKey = "STUDIO-KEY_" + String(repeating: "f", count: 32)
    private static let readSalts = ["password": "0123456789abcdef0123456789abcdef", "totp": "fedcba9876543210fedcba9876543210"]
    private static let apiKey = "bws://12345678-1234-1234-1234-123456789012"
    private static let shortKey = "bws://12345678-1234-1234-1234-123456789013"
    private static let goneKey = "bws://12345678-1234-1234-1234-123456789014"

    private static func readHub() throws -> VaultHub {
        VaultHub(configuration: try VaultConfiguration(data: JSONSerialization.data(withJSONObject: [
            "agent": "studio", "hub": "http://100.64.0.1:9", "region": "eu", "worker_uid": 501,
            "socket": NSHomeDirectory() + "/Library/Application Support/AgentFleet/vault.sock"])), protocolClasses: [FakeHub.self])
    }
    private static func named(_ secrets: [(String, String)]) -> [String: Any] {
        ["ok": true, "secrets": secrets.map { ["login": $0.0, "env": $0.1, "fingerprint_salts": readSalts] }]
    }
    /// A hub that names `secrets` and takes every fingerprint, or refuses the one of `refused`.
    private static func reading(_ secrets: [String: Any], refused: String? = nil) -> @Sendable (String, [String: Any]) -> (Int, Any) {
        let answer = ReadAnswer(secrets)
        return { route, body in
            if route == "/helper/vault/studio/fingerprints" {
                if let refused, body["login"] as? String == refused { return (409, ["error": "studio may not read this secret"]) }
                return (200, ["ok": true, "login": body["login"] ?? "", "stored": (body["fingerprints"] as? [Any])?.count ?? 0, "known": 0])
            }
            return route == "/helper/vault/studio/read" ? (200, answer.value) : (404, [:])
        }
    }
    private static func read(_ values: [String: String]) async throws -> NSDictionary {
        let reply = await VaultBroker.read(as: VaultCaller(agent: "studio", key: readKey), hub: try readHub()) { id in
            guard let value = values["bws://" + id] else { throw VaultFailure.provider }
            return VaultSecret(password: value, totp: nil)
        }
        return NSDictionary(dictionary: reply)
    }

    @Test func aReadNamesNoJobAndItsCallerWithBothFieldsOrNeither() throws {
        #expect(try VaultRequest(data: Data(#"{"v":2,"op":"read"}"#.utf8)).operation == .read)
        let named = try VaultRequest(data: JSONSerialization.data(withJSONObject: ["v": 2, "op": "read", "agent": "studio", "agent_key": Self.readKey]))
        #expect(named.operation == .read && named.caller == VaultCaller(agent: "studio", key: Self.readKey) && named.job == nil)
        #expect(throws: VaultFailure.request) { try VaultRequest(data: Data(#"{"v":2,"op":"read","job":3}"#.utf8)) }
        #expect(throws: VaultFailure.request) { try VaultRequest(data: Data(#"{"v":2,"op":"read","login":"bws://x"}"#.utf8)) }
    }

    @Test func aReadGivesOnlyTheKeysThatTheHubNamesAndProtectsEachOneFirst() async throws {
        let key = "sk-synthetic-READ-0123456789", short = "abc"
        FakeHub.reset(answer: Self.reading(Self.named([(Self.apiKey, "OPENAI_API_KEY"), (Self.shortKey, "SHORT_KEY"),
                                                        (Self.goneKey, "GONE_KEY")])))
        #expect(try await Self.read([Self.apiKey: key, Self.shortKey: short]) ==
                ["ok": true, "v": 2, "env": ["OPENAI_API_KEY": key, "SHORT_KEY": short], "missing": ["GONE_KEY"]])
        // The key's fingerprint went to the hub before the answer; a value of fewer than 8 characters has none.
        #expect(FakeHub.seen.map(\.route) == ["/helper/vault/studio/read", "/helper/vault/studio/fingerprints"])
        #expect(FakeHub.seen.allSatisfy { $0.authorization == "Bearer " + Self.readKey })
        // A value that the hub does not protect is not given.
        FakeHub.reset(answer: Self.reading(Self.named([(Self.apiKey, "OPENAI_API_KEY")]), refused: Self.apiKey))
        #expect(try await Self.read([Self.apiKey: key]) == ["ok": true, "v": 2, "env": [String: String](), "missing": ["OPENAI_API_KEY"]])
        // The hub refuses, or names the keys in a form that the vault does not take: nothing is read.
        for answer in [Self.named([(Self.apiKey, "A_KEY"), (Self.shortKey, "A_KEY")]), Self.named([(Self.apiKey, "lower_key")]),
                       Self.named([("sealed:4", "A_KEY")]), ["ok": true]] {
            FakeHub.reset(answer: Self.reading(answer))
            #expect(try await Self.read([Self.apiKey: key]) == ["ok": false, "v": 2, "error": VaultFailure.hub.rawValue])
        }
        FakeHub.reset { _, _ in (409, ["error": "studio has no credential access"]) }
        #expect(try await Self.read([Self.apiKey: key]) == ["ok": false, "v": 2, "error": VaultFailure.hub.rawValue])
    }

    @Test func anAPIKeyIsALoginWithAnEmptyUserNameAndAValueWithoutAnAddressIsOnlyRead() throws {
        let key = "sk-synthetic-READ-0123456789"
        let served = try JSONSerialization.data(withJSONObject: ["username": "", "password": key, "url": "https://api.example.test/v1"])
        let login = try VaultLogin(data: served, label: "SHOP_KEY")
        #expect(login.username.isEmpty && login.origin == "https://api.example.test")
        let bare = try JSONSerialization.data(withJSONObject: ["username": "", "password": key])
        #expect(throws: VaultFailure.login) { try VaultLogin(data: bare, label: "SHOP_KEY") }       // no address: no sign-in, no request
        #expect(try VaultSecret(data: bare).password == key)
        #expect(VaultProbeResult.inspect(login: Self.apiKey, value: bare).reason == .ok)
        #expect(VaultProbeResult.inspect(login: Self.apiKey, value: Data(#"{"username":""}"#.utf8)).reason == .bad_format)
    }
}

/// A value for a sendable closure of a test.
private final class ReadAnswer: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}
