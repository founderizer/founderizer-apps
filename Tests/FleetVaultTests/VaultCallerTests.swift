import Foundation
import Testing
@testable import FleetVaultCore

/// A hub on no network: it records each request's route and Authorization header and answers from `answer`.
final class FakeHub: URLProtocol, @unchecked Sendable {
    struct Seen: Equatable, Sendable { let route: String; let authorization: String? }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var seenRequests: [Seen] = []
    nonisolated(unsafe) private static var reply: @Sendable (String, [String: Any]) -> (Int, Any) = { _, _ in (404, [:]) }
    nonisolated(unsafe) private static var wait: @Sendable (String) -> Double = { _ in 0 }

    static func reset(answer: @escaping @Sendable (String, [String: Any]) -> (Int, Any),
                      delay: @escaping @Sendable (String) -> Double = { _ in 0 }) {
        lock.withLock { seenRequests = []; reply = answer; wait = delay }
    }
    static var seen: [Seen] { lock.withLock { seenRequests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!, route = url.path + (url.query.map { "?" + $0 } ?? "")
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while case let count = stream.read(&buffer, maxLength: buffer.count), count > 0 { body.append(buffer, count: count) }
        }
        let fields = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let (answer, delay) = Self.lock.withLock {
            Self.seenRequests.append(Seen(route: route, authorization: request.value(forHTTPHeaderField: "Authorization")))
            return (Self.reply, Self.wait)
        }
        let (status, object) = answer(route, fields)
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        DispatchQueue.global().asyncAfter(deadline: .now() + delay(route)) {
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                                                       headerFields: ["Content-Type": "application/json"])!,
                                     cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
}

/// Shared broker callers (protocol 2 `callers`). Fake data only: no Keychain, no Bitwarden, no real hub.
@Suite(.serialized) struct VaultCallerTests {
    private let seoKey = "SEO-KEY_" + String(repeating: "a", count: 35)
    private let studioKey = "STUDIO-KEY_" + String(repeating: "b", count: 32)
    private let salts = ["password": "0123456789abcdef0123456789abcdef", "totp": "fedcba9876543210fedcba9876543210"]
    private let source = "bws://12345678-1234-1234-1234-123456789012"

    private var configuration: VaultConfiguration {
        get throws {
            try VaultConfiguration(data: JSONSerialization.data(withJSONObject: [
                "agent": "studio", "hub": "http://100.64.0.1:9", "region": "eu", "worker_uid": 501,      // no hub listens there
                "socket": NSHomeDirectory() + "/Library/Application Support/AgentFleet/vault.sock"]))
        }
    }
    private func request(_ fields: [String: Any]) throws -> VaultRequest {
        try VaultRequest(data: JSONSerialization.data(withJSONObject: fields.merging(["v": 2]) { a, _ in a }))
    }
    /// The hub's answers for one job of each kind, for whichever agent asks.
    private func answer(_ route: String, _ body: [String: Any]) -> (Int, Any) {
        if route.hasSuffix("/fingerprints") {
            return (200, ["ok": true, "job": body["job"]!, "stored": (body["fingerprints"] as? [Any])?.count ?? 0, "known": 0])
        }
        if route.hasPrefix("/sealed/") {
            return (200, ["ciphertext": "-----BEGIN AGE ENCRYPTED FILE-----\nSYNTHETIC\n-----END AGE ENCRYPTED FILE-----\n",
                          "label": "Shop admin", "job": 12, "project": "shop", "source": source])
        }
        if body["kind"] as? String == "probe" { return (200, ["ok": true, "kind": "probe", "job": body["job"]!, "logins": [source]]) }
        return (200, ["ok": true, "kind": body["kind"]!, "job": body["job"]!, "task": "T-1", "login": "sealed:7",
                      "fingerprint_salts": salts, "project": "shop", "source": source])
    }

    @Test func aJobRequestNamesItsCallerWithBothFieldsOrNeither() throws {
        #expect(try request(["op": "signin", "job": 12]).caller == nil)
        let shared = try request(["op": "handover", "job": 12, "agent": "seo", "agent_key": seoKey])
        #expect(shared.caller == VaultCaller(agent: "seo", key: seoKey) && shared.job == 12)
        #expect(try request(["op": "probe", "job": 3, "agent": "ads-2", "agent_key": studioKey]).caller?.agent == "ads-2")
        // Only one field, or a field of the wrong form (nil: the field is absent).
        let short = String(seoKey.dropLast())
        let wrong: [(agent: Any?, key: Any?)] = [
            ("seo", nil), (nil, seoKey), ("SEO", seoKey), ("s", seoKey), ("seo\n", seoKey), ("-seo", seoKey), (7, seoKey),
            ("seo", short), ("seo", seoKey + "a"), ("seo", short + "="), ("seo", short + "/"), ("seo", short + "\n"),
            ("seo", String(seoKey.dropLast(2)) + "\r\n"), ("seo", NSNull())]
        for (agent, key) in wrong {
            var fields: [String: Any] = ["op": "signin", "job": 12]
            if let agent { fields["agent"] = agent }
            if let key { fields["agent_key"] = key }
            #expect(throws: VaultFailure.caller) { try request(fields) }
        }
        // Not a caller problem: the old fixed refusal, as before.
        for bad: [String: Any] in [["op": "status", "agent": "seo", "agent_key": seoKey],
                                   ["op": "signin", "job": 12, "agent": "seo", "agent_key": seoKey, "login": source],
                                   ["op": "signin", "job": 0, "agent": "seo", "agent_key": seoKey]] {
            #expect(throws: VaultFailure.request) { try request(bad) }
        }
    }

    @Test func noTextOrMirrorOfARequestContainsItsKey() throws {
        let shared = try request(["op": "signin", "job": 12, "agent": "seo", "agent_key": seoKey])
        var dumped = "", callerDump = ""
        dump(shared, to: &dumped); dump(shared.caller!, to: &callerDump)
        let texts = [String(describing: shared), String(reflecting: shared), "\(shared)", dumped, callerDump,
                     String(describing: shared.caller!), String(reflecting: shared.caller!)]
        for text in texts { #expect(!text.contains(seoKey) && text.contains("seo")) }
    }

    @Test func everyHubCallOfAJobUsesItsOwnCallerOrNoCredential() async throws {
        FakeHub.reset(answer: answer)
        let hub = VaultHub(configuration: try configuration, protocolClasses: [FakeHub.self])
        let login = try VaultLogin(data: JSONSerialization.data(withJSONObject: [
            "username": "synthetic-user", "password": "SYNTHETIC-PASSWORD", "url": "https://shop.example.test"]), label: "Shop admin")
        let seo = VaultCaller(agent: "seo", key: seoKey), solo = VaultBroker.caller(for: try request(["op": "signin", "job": 12]),
                                                                                    configuration: try configuration)
        #expect(solo == VaultCaller(agent: "studio", key: nil))                   // the configured store agent, as before
        for caller in [seo, solo] {
            let signin = try request(["op": "signin", "job": 12])
            let job = try await hub.confirm(signin, as: caller)
            _ = try await hub.sealed(job, as: caller)
            try await hub.protect(login, job: job, as: caller)
            _ = try await hub.confirmProbe(try request(["op": "probe", "job": 13]), as: caller)
        }
        let header = "Bearer " + seoKey
        #expect(FakeHub.seen == [
            .init(route: "/helper/vault/seo", authorization: header), .init(route: "/sealed/7?agent=seo&task=T-1", authorization: header),
            .init(route: "/helper/vault/seo/fingerprints", authorization: header), .init(route: "/helper/vault/seo", authorization: header),
            .init(route: "/helper/vault/studio", authorization: nil), .init(route: "/sealed/7?agent=studio&task=T-1", authorization: nil),
            .init(route: "/helper/vault/studio/fingerprints", authorization: nil), .init(route: "/helper/vault/studio", authorization: nil)])
    }

    @Test func overlappingJobsOfTwoAgentsNeverShareACredential() async throws {
        // The first requests wait longest, so every request is in flight while later ones start and finish.
        FakeHub.reset(answer: answer, delay: { route in route.contains("/seo") ? 0.25 : 0.05 })
        let hub = VaultHub(configuration: try configuration, protocolClasses: [FakeHub.self])
        let callers = [VaultCaller(agent: "seo", key: seoKey), VaultCaller(agent: "studio", key: studioKey)]
        let jobs = try await withThrowingTaskGroup(of: (String, Int).self) { group in
            for job in 1...12 {
                let caller = callers[job % 2], signin = try request(["op": "signin", "job": job])
                group.addTask { (caller.agent, try await hub.confirm(signin, as: caller).id) }
            }
            return try await group.reduce(into: [(String, Int)]()) { $0.append($1) }
        }
        #expect(Set(jobs.map { "\($0.0)/\($0.1)" }) == Set((1...12).map { "\(callers[$0 % 2].agent)/\($0)" }))
        #expect(FakeHub.seen.count == 12)
        for seen in FakeHub.seen {
            let agent = String(seen.route.dropFirst("/helper/vault/".count))
            #expect(seen.authorization == "Bearer " + (agent == "seo" ? seoKey : studioKey))
        }
    }

    @Test func aRefusedKeyHasItsOwnAnswerAndOtherRefusalsStayTheHubError() async throws {
        let hub = VaultHub(configuration: try configuration, protocolClasses: [FakeHub.self])
        let seo = VaultCaller(agent: "seo", key: seoKey)
        let job = try VaultJob(data: JSONSerialization.data(withJSONObject: [
            "ok": true, "kind": "signin", "job": 12, "task": "T-1", "login": "sealed:7", "fingerprint_salts": salts]),
                               request: try request(["op": "signin", "job": 12]))
        let login = try VaultLogin(data: JSONSerialization.data(withJSONObject: [
            "username": "u", "password": "SYNTHETIC-PASSWORD", "url": "https://shop.example.test"]), label: "Shop admin")
        for (status, body, failure) in [(403, ["error": "this is not seo's agent key", "auth": "key_mismatch"], VaultFailure.key),
                                        (403, ["error": "100.1.2.3 is not seo's machine"], VaultFailure.hub),
                                        (500, ["error": "unavailable", "auth": "key_mismatch"], VaultFailure.hub)] as [(Int, [String: String], VaultFailure)] {
            FakeHub.reset(answer: { _, _ in (status, body) })
            await #expect(throws: failure) { try await hub.confirm(try request(["op": "signin", "job": 12]), as: seo) }
            await #expect(throws: failure) { try await hub.sealed(job, as: seo) }
            await #expect(throws: failure == .key ? .key : VaultFailure.protection) { try await hub.protect(login, job: job, as: seo) }
        }
    }

    @Test func theStatusSaysCallersAndKeepsTheStoreIdentity() throws {
        let recipient = "age1" + String(repeating: "q", count: 58)
        let reply = VaultBroker.status(agent: "studio", user: "sam", recipient: recipient)
        #expect(NSDictionary(dictionary: reply) == NSDictionary(dictionary: [
            "ok": true, "v": 2, "agent": "studio", "store": "keychain", "backend": "bitwarden", "user": "sam",
            "recipient": recipient, "callers": true]))
    }

    /// `fleet.py check <agent>` reads this one word to say which store the broker opens, so it is in every answer.
    @Test func theStatusNamesTheStoreThatThisBrokerOpens() throws {
        let recipient = "age1" + String(repeating: "q", count: 58)
        for backend in [VaultBackend.store, .bitwarden] {
            let reply = VaultBroker.status(agent: "studio", user: "sam", recipient: recipient, backend: backend)
            #expect(reply["backend"] as? String == backend.rawValue)
            #expect(reply["store"] as? String == "keychain")
        }
    }

    @Test func aBadCallerIsRefusedWithTheContractAnswerBeforeAnyHubCall() async throws {
        FakeHub.reset(answer: answer)
        let broker = VaultBroker(configuration: try configuration, bundle: .main, protocolClasses: [FakeHub.self])
        for line in [#"{"v":2,"op":"signin","job":12,"agent":"seo"}"#,
                     #"{"v":2,"op":"handover","job":12,"agent":"seo","agent_key":"\#(seoKey)="}"#] {
            let reply = await broker.handle(Data((line + "\n").utf8), uid: 501)
            let object = try #require(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
            #expect(NSDictionary(dictionary: object) == NSDictionary(dictionary: ["ok": false, "v": 2, "error": "the caller fields are not valid"]))
            #expect(!String(decoding: reply, as: UTF8.self).contains(seoKey))
        }
        #expect(FakeHub.seen.isEmpty)
    }
}
