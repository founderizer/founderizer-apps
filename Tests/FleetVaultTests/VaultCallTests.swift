import FleetVaultIPC
import Foundation
import Testing
@testable import FleetVaultCore

/// The `request` and `cancel` operations through the broker: the hub is `FakeHub`, the service is `LocalService` on
/// this machine, and the child is the system curl. Synthetic values only. These tests are part of the serialized
/// suite of `FakeHub`.
extension VaultCallerTests {
    private static let agentKey = "STUDIO-KEY_" + String(repeating: "d", count: 32)
    private static let otherKey = "STUDIO-KEY_" + String(repeating: "e", count: 32)
    private static let value = "SYNTHETIC-API-KEY-0123456789"
    private static let callID = "0a1b2c3d-5555-4666-8777-888888888888"
    private static let reference = "bws://12345678-1234-1234-1234-123456789012"
    private static let callSalts = ["password": "0123456789abcdef0123456789abcdef", "totp": "fedcba9876543210fedcba9876543210"]
    private static var studio: VaultCaller { VaultCaller(agent: "studio", key: agentKey) }
    private static var callConfiguration: VaultConfiguration {
        get throws {
            try VaultConfiguration(data: JSONSerialization.data(withJSONObject: [
                "agent": "studio", "hub": "http://100.64.0.1:9", "region": "eu", "worker_uid": 501,
                "socket": NSHomeDirectory() + "/Library/Application Support/AgentFleet/vault.sock"]))
        }
    }
    private static func callHub() throws -> VaultHub { VaultHub(configuration: try callConfiguration, protocolClasses: [FakeHub.self]) }
    private static func line(_ fields: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: fields.merging(["v": 2]) { given, _ in given }) + Data([10])
    }
    private static func request(job: Int = 31, key: String = agentKey) throws -> VaultRequest {
        try VaultRequest(data: JSONSerialization.data(withJSONObject: ["v": 2, "op": "request", "job": job, "agent": "studio", "agent_key": key]))
    }
    private static func cancelFields(_ change: [String: Any] = [:]) -> [String: Any] {
        ["op": "cancel", "db": "test-generation", "task": "T-7", "attempt": 2, "agent": "studio", "agent_key": agentKey].merging(change) { _, new in new }
    }
    /// The hub's confirmation of request job 31, as the contract gives it.
    private static func confirmed(_ change: [String: Any] = [:]) -> [String: Any] {
        ["ok": true, "kind": "request", "job": 31, "task": "T-7", "login": reference, "fingerprint_salts": callSalts, "project": "shop",
         "db": "test-generation", "attempt": 2, "request_id": callID, "method": "GET", "path": "/v1/things?x=1",
         "auth": "bearer"].merging(change) { _, new in new }
    }
    /// A hub that confirms the job of each request with `fields` and takes the fingerprints.
    private static func confirming(_ fields: [String: Any] = confirmed()) -> @Sendable (String, [String: Any]) -> (Int, Any) {
        let fields = Fields(fields)
        return { route, body in
            if route.hasSuffix("/fingerprints") {
                return (200, ["ok": true, "job": body["job"] ?? 0, "stored": (body["fingerprints"] as? [Any])?.count ?? 0, "known": 0])
            }
            return (200, fields.value.merging(["job": body["job"] ?? 0]) { _, new in new })
        }
    }
    private static func login(at address: String, password: String = value, username: String = "api-user") throws -> VaultLogin {
        try VaultLogin(data: JSONSerialization.data(withJSONObject: ["username": username, "password": password, "url": address]), label: "Shop API")
    }
    /// One `request` through the broker. In these tests the one host without TLS is this machine.
    private static func send(_ calls: VaultCalls, job: Int = 31, limit: Int = 5, login: VaultLogin,
                             plain: @escaping @Sendable (String) -> Bool = { $0 == "127.0.0.1" }) async throws -> [String: Any] {
        await VaultBroker.call(try request(job: job), as: studio, hub: try callHub(), calls: calls, limit: limit, plain: plain) { _ in login }
    }
    /// One request to a service that gives `body`: a new hub answer, a new journal, and the reply.
    private static func exchange(_ body: Data, _ change: [String: Any] = [:], password: String = value) async throws -> [String: Any] {
        let service = try LocalService(.answer(LocalService.response(body: body)))
        defer { service.stop() }
        FakeHub.reset(answer: confirming(confirmed(change)))
        return try await send(VaultCalls(store: FakeKeychainJournal()), login: login(at: service.origin, password: password))
    }
    private static func refusal(_ failure: VaultFailure) -> NSDictionary { ["ok": false, "v": 2, "error": failure.rawValue] }
    private static func unknown(_ failure: VaultFailure) -> NSDictionary { ["ok": false, "v": 2, "unknown": true, "error": failure.rawValue] }
    private struct Late: Error {}
    private static func until(_ seconds: Double = 5, _ done: @Sendable () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !done() {
            guard Date() < end else { throw Late() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    /// The process of the request that the journal has, while it has one.
    private static func process(in store: FakeKeychainJournal) -> pid_t? {
        struct Journal: Decodable {
            struct Call: Decodable { struct Child: Decodable { let pid: Int32 }; let child: Child? }
            let calls: [Call]
        }
        guard let data = store.data, let journal = try? JSONDecoder().decode(Journal.self, from: data) else { return nil }
        return journal.calls.compactMap(\.child).first?.pid
    }

    // MARK: The request line, the hub's fields and the config

    @Test func aRequestAndACancelAlwaysNameTheirCallerAndACancelNamesOneTaskAttempt() throws {
        let request = try Self.request()
        #expect(request.operation == .request && request.job == 31 && request.caller == Self.studio && request.scope == nil)
        #expect(throws: VaultFailure.caller) { try VaultRequest(data: Data(#"{"v":2,"op":"request","job":31}"#.utf8)) }
        for extra in ["path": "/v1/x", "login": Self.reference, "method": "GET", "body": "{}", "db": "test-generation"] {     // only the job comes in the line
            #expect(throws: VaultFailure.request) {
                try VaultRequest(data: Self.line(["op": "request", "job": 31, "agent": "studio", "agent_key": Self.agentKey, extra.key: extra.value]))
            }
        }
        let cancel = try VaultRequest(data: Self.line(Self.cancelFields()))
        #expect(cancel.operation == .cancel && cancel.job == nil && cancel.caller == Self.studio)
        let scope = try #require(cancel.scope)
        #expect(scope.db == "test-generation" && scope.agent == "studio" && scope.task == "T-7" && scope.attempt == 2)
        #expect(try VaultRequest(data: Self.line(Self.cancelFields(["task": 7]))).scope?.task == "7")
        // The scope has the hash of the key. Another key is another scope of the same task attempt.
        #expect(scope.key.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil)
        let other = try #require(try VaultRequest(data: Self.line(Self.cancelFields(["agent_key": Self.otherKey]))).scope)
        #expect(other != scope && other.isAttempt(of: scope))
        #expect(scope == VaultCallScope(db: "test-generation", task: "T-7", attempt: 2, caller: Self.studio))
        var dumped = ""
        dump(cancel, to: &dumped)
        for text in [dumped, String(describing: cancel), String(reflecting: cancel)] { #expect(!text.contains(Self.agentKey)) }
        // A cancel has its three fields and no job.
        for missing in ["db", "task", "attempt"] {
            var fields = Self.cancelFields()
            fields.removeValue(forKey: missing)
            #expect(throws: VaultFailure.request) { try VaultRequest(data: Self.line(fields)) }
        }
        let bad: [[String: Any]] = [["job": 31], ["attempt": 0], ["attempt": "2"], ["attempt": 2.5], ["db": "bad generation"], ["db": ""], ["task": ""],
                                    ["task": String(repeating: "t", count: 64)], ["task": ["T-7"]], ["login": Self.reference]]
        for change in bad { #expect(throws: VaultFailure.request) { try VaultRequest(data: Self.line(Self.cancelFields(change))) } }
        var alone = Self.cancelFields()
        alone.removeValue(forKey: "agent_key")
        #expect(throws: VaultFailure.caller) { try VaultRequest(data: Self.line(alone)) }
        alone.removeValue(forKey: "agent")
        #expect(throws: VaultFailure.caller) { try VaultRequest(data: Self.line(alone)) }
    }

    @Test func theFieldsOfARequestJobAreReadStrictly() throws {
        func call(_ change: [String: Any] = [:], without key: String? = nil) throws -> VaultCall {
            var fields = Self.confirmed(change)
            if let key { fields.removeValue(forKey: key) }
            return try VaultCall(fields: fields)
        }
        let good = try call()
        #expect(good.requestID == Self.callID && good.db == "test-generation" && good.attempt == 2)
        #expect(good.method == "GET" && good.path == "/v1/things?x=1" && good.auth == .bearer && good.body == nil)
        #expect(try call(["request_id": Self.callID.uppercased()]).requestID == Self.callID)
        #expect(try call(["auth": "basic"]).auth == .basic)
        #expect(try call(["auth": "header:X-Api-Key"]).auth == .header("X-Api-Key"))
        #expect(try call(["path": "/"]).path == "/")
        #expect(try call(["path": "/a{1,2}/[1-3]?q=%20&f[x]=y|z"]).path == "/a{1,2}/[1-3]?q=%20&f[x]=y|z")
        // No body: the field is absent, null or empty.
        #expect(try call(["body": NSNull()]).body == nil)
        #expect(try call(["body": ""]).body == nil)
        #expect(try call(["method": "POST", "body": #"{"n":1}"#]).body == Data(#"{"n":1}"#.utf8))
        #expect(try call(["body": String(repeating: "b", count: 65_536)]).body?.count == 65_536)
        for missing in ["db", "attempt", "request_id", "method", "path", "auth"] { #expect(throws: VaultFailure.hub) { _ = try call(without: missing) } }
        let bad: [[String: Any]] = [
            ["method": "get"], ["method": "HEAD"], ["method": "OPTIONS"], ["method": 7],
            ["path": "v1/things"], ["path": "//other.example.test/x"], ["path": "/a b"], ["path": "/a#b"], ["path": "/a\\b"], ["path": "/a\nb"],
            ["path": "/caf\u{e9}"], ["path": ""], ["path": "/" + String(repeating: "p", count: 2000)], ["path": "https://other.example.test/x"],
            ["auth": "Bearer"], ["auth": "header:"], ["auth": "header:Host"], ["auth": "header:authorization"], ["auth": "header:Content-Length"],
            ["auth": "header:transfer-encoding"], ["auth": "header:CONNECTION"], ["auth": "header:Content-Type"], ["auth": "header:X Key"],
            ["auth": "header:9-key"], ["auth": "header:X-Key\r\nHost"], ["auth": "header:" + String(repeating: "h", count: 65)], ["auth": "digest"],
            ["body": 7], ["body": ["n": 1]], ["body": String(repeating: "b", count: 65_537)],
            ["attempt": 0], ["attempt": "2"], ["db": "bad generation"], ["request_id": "not-a-uuid"]]
        for change in bad { #expect(throws: VaultFailure.hub) { _ = try call(change) } }
    }

    @Test func theHubConfirmsARequestJobWithTheSignInFieldsAndTheRequestFields() async throws {
        let asked = try #require(try JSONSerialization.jsonObject(with: VaultHub.confirmBody(try Self.request())) as? [String: Any])
        #expect(NSDictionary(dictionary: asked) == NSDictionary(dictionary: ["job": 31, "kind": "request", "provenance": 1, "creation": 1]))
        FakeHub.reset(answer: Self.confirming(Self.confirmed(["method": "POST", "body": #"{"n":1}"#])))
        let (job, call) = try await Self.callHub().confirmCall(try Self.request(), as: Self.studio)
        #expect(job.id == 31 && job.task == "T-7" && job.login == Self.reference && job.project == "shop" && job.createdBy == nil)
        #expect(call == (try VaultCall(fields: Self.confirmed(["method": "POST", "body": #"{"n":1}"#]))))
        #expect(FakeHub.seen == [.init(route: "/helper/vault/studio", authorization: "Bearer " + Self.agentKey)])
        // Another kind, another job, or a field that is not there: no job.
        var changes: [[String: Any]] = [["kind": "signin"], ["ok": false], ["path": "no-slash"], ["login": "not-a-reference"]]
        changes += ["task", "login", "fingerprint_salts", "db", "attempt", "request_id", "method", "path", "auth"].map { [$0: NSNull()] }
        for change in changes {
            FakeHub.reset(answer: Self.confirming(Self.confirmed(change)))
            await #expect(throws: VaultFailure.hub) { _ = try await Self.callHub().confirmCall(try Self.request(), as: Self.studio) }
        }
        FakeHub.reset(answer: { _, _ in (200, Self.confirmed(["job": 32])) })
        await #expect(throws: VaultFailure.hub) { _ = try await Self.callHub().confirmCall(try Self.request(), as: Self.studio) }
        // A body of the largest size, in its JSON form, is still one confirmation.
        let large = String(repeating: "\"", count: 65_536)
        FakeHub.reset(answer: Self.confirming(Self.confirmed(["method": "POST", "body": large])))
        #expect(try await Self.callHub().confirmCall(try Self.request(), as: Self.studio).1.body?.count == 65_536)
    }

    @Test func theConfigCarriesTheValueAsOneHeaderAndOnlyItsLastLinePermitsAProtocol() throws {
        // A value with a quote, a backslash, a tab, a space and a letter that is not ASCII goes as it is.
        let odd = "k\"e\\y\t1 \u{e9}-0123"
        let login = try Self.login(at: "https://API.Example.test:443/app/login", password: odd)
        let plan = try VaultCall(fields: Self.confirmed()).plan(for: login)
        #expect(plan.lead == nil && plan.body == nil)
        #expect(String(decoding: plan.config, as: UTF8.self) == #"""
            proto = "-all"
            silent
            globoff
            http1.1
            noproxy = "*"
            max-redirs = 0
            max-time = 60
            connect-timeout = 15
            request = "GET"
            header = "Accept: application/json"
            header = "Authorization: Bearer k\"e\\y\t1 é-0123"
            write-out = "%{stderr}fleet %{http_code}\n"
            url = "https://api.example.test/v1/things?x=1"
            proto = "=https"

            """#)
        #expect(plan.forms.contains(Data(odd.utf8)))
        func lines(_ change: [String: Any], limit: Int = 60, password: String = Self.value) throws -> [String] {
            let plan = try VaultCall(fields: Self.confirmed(change)).plan(for: Self.login(at: "https://api.example.test", password: password), limit: limit)
            return String(decoding: plan.config, as: UTF8.self).split(separator: "\n").map(String.init)
        }
        // A body: curl reads it at the first line, and it is JSON.
        let posted = try VaultCall(fields: Self.confirmed(["method": "POST", "body": #"{"n":1}"#])).plan(for: Self.login(at: "https://api.example.test"))
        #expect(posted.lead == Data("data-binary = \"@-\"\n".utf8) && posted.body == Data(#"{"n":1}"#.utf8))
        #expect(String(decoding: posted.config, as: UTF8.self).contains("request = \"POST\"\nheader = \"Accept: application/json\"\nheader = \"Content-Type: application/json\"\n"))
        // Without a body, a method that can have one says that it has none.
        for method in ["POST", "PUT", "PATCH"] { #expect(try lines(["method": method]).contains("header = \"Content-Length: 0\"")) }
        for method in ["GET", "DELETE"] { #expect(try !lines(["method": method]).contains { $0.contains("Content-") }) }
        #expect(try lines(["auth": "header:X-Api-Key"]).contains("header = \"X-Api-Key: " + Self.value + "\""))
        #expect(try lines(["auth": "header:X-Api-Key"]).filter { $0.hasPrefix("header") }.count == 2)
        #expect(try lines([:], limit: 2).contains("max-time = 2") && lines([:], limit: 2).contains("connect-timeout = 2"))
        // Basic: the vault makes the value, and an answer must not show it.
        let token = Data(("api-user:" + Self.value).utf8).base64EncodedString()
        let basic = try VaultCall(fields: Self.confirmed(["auth": "basic"])).plan(for: Self.login(at: "https://api.example.test"))
        #expect(String(decoding: basic.config, as: UTF8.self).contains("header = \"Authorization: Basic " + token + "\"\n"))
        #expect(basic.forms.contains(Data(token.utf8)) && basic.forms.contains(Data(Self.value.utf8)))
        // In each config the first line permits nothing, the address is in the line before the last, and only the last line permits.
        for change in [[:], ["auth": "basic"], ["auth": "header:X-Api-Key"], ["method": "POST", "body": "{}"], ["method": "PUT"]] as [[String: Any]] {
            let all = try lines(change)
            #expect(all.first == "proto = \"-all\"" && all.last == "proto = \"=https\"" && all.dropLast().last == "url = \"https://api.example.test/v1/things?x=1\"")
            #expect(all.filter { $0.hasPrefix("proto") || $0.hasPrefix("url") }.count == 3)
        }
    }

    @Test func aValueThatCannotBeAHeaderLineIsNotSentAndBasicTakesEveryValue() throws {
        let call = try VaultCall(fields: Self.confirmed()), named = try VaultCall(fields: Self.confirmed(["auth": "header:X-Api-Key"]))
        let basic = try VaultCall(fields: Self.confirmed(["auth": "basic"]))
        for value in ["line\nend-0123", "carriage\rreturn-0123", "nul\0value-0123", "delete\u{7f}value-0123", "bell\u{07}value-0123", "x\ny"] {
            let login = try Self.login(at: "https://api.example.test", password: value)
            #expect(throws: VaultFailure.callHeader) { _ = try call.plan(for: login) }
            #expect(throws: VaultFailure.callHeader) { _ = try named.plan(for: login) }
            let config = String(decoding: try basic.plan(for: login).config, as: UTF8.self)
            #expect(config.contains("Authorization: Basic " + Data(("api-user:" + value).utf8).base64EncodedString()) && !config.contains(value))
        }
        // No rule for the length or for white space: a value of one character and a value with spaces go in each form.
        for value in ["x", "two words", " edge ", "tab\there"] {
            let login = try Self.login(at: "https://api.example.test", password: value)
            for form in [call, named, basic] { #expect(throws: Never.self) { _ = try form.plan(for: login) } }
        }
    }

    @Test func aRequestGoesOnlyToHTTPSOrToThePrivateRange() throws {
        let call = try VaultCall(fields: Self.confirmed())
        func last(_ address: String) throws -> String? {
            String(decoding: try call.plan(for: Self.login(at: address)).config, as: UTF8.self).split(separator: "\n").last.map(String.init)
        }
        #expect(try last("https://api.example.test:8443/x") == "proto = \"=https\"")
        #expect(try last("http://100.64.0.7:8080/x") == "proto = \"=http\"")
        #expect(try last("http://100.127.255.255") == "proto = \"=http\"")
        for address in ["http://api.example.test", "http://127.0.0.1:8080", "http://100.128.0.1", "http://10.0.0.1", "http://192.168.1.1", "http://localhost"] {
            #expect(throws: VaultFailure.callAddress) { _ = try call.plan(for: Self.login(at: address)) }
        }
        // The address of the request is the origin of the login and the path, and nothing of the login's own path.
        let config = String(decoding: try call.plan(for: Self.login(at: "https://api.example.test/admin/login?next=/x#top")).config, as: UTF8.self)
        #expect(config.contains("url = \"https://api.example.test/v1/things?x=1\"\n"))
    }

    @Test func theStatusSaysRequestsOnlyForABrokerThatSendsThem() {
        let recipient = "age1" + String(repeating: "q", count: 58)
        #expect(VaultBroker.status(agent: "studio", user: "sam", recipient: recipient, requests: true)["requests"] as? Bool == true)
        #expect(VaultBroker.status(agent: "studio", user: "sam", recipient: recipient)["requests"] == nil)
        #expect(VaultCurl.isAvailable)
    }

    // MARK: Real requests to a service on this machine

    @Test func aRequestSendsTheValueOnlyToTheServiceAndAnswersWithTheStatusAndTheText() async throws {
        let service = try LocalService(.answer(LocalService.response(headers: ["Content-Type: application/json"], body: Data(#"{"things":[1,2]}"#.utf8))))
        defer { service.stop() }
        FakeHub.reset(answer: Self.confirming())
        let reply = try await Self.send(VaultCalls(store: FakeKeychainJournal()), login: Self.login(at: service.origin + "/console/login"))
        #expect(NSDictionary(dictionary: reply) == NSDictionary(dictionary: [
            "ok": true, "v": 2, "job": 31, "status": 200, "body": #"{"things":[1,2]}"#, "truncated": false]))
        #expect(service.received.count == 1)
        let lines = LocalService.parts(of: try #require(service.received.first)).lines
        #expect(lines.first == "GET /v1/things?x=1 HTTP/1.1")
        #expect(lines.contains("Authorization: Bearer " + Self.value) && lines.contains("Accept: application/json"))
        #expect(lines.contains("Host: 127.0.0.1:\(service.port)"))
        // The hub: one confirmation, then the fingerprints of the login, each with the caller's key.
        let header = "Bearer " + Self.agentKey
        #expect(FakeHub.seen == [.init(route: "/helper/vault/studio", authorization: header),
                                 .init(route: "/helper/vault/studio/fingerprints", authorization: header)])
        #expect(!String(decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self).contains(Self.value))
    }

    @Test func aBodyGoesAsJSONAndBasicAndANamedHeaderCarryTheValue() async throws {
        let service = try LocalService(.answer(LocalService.response("201 Created", body: Data("made".utf8))))
        defer { service.stop() }
        let calls = VaultCalls(store: FakeKeychainJournal())
        // Basic takes every value: this one has a line end, a quote, a backslash and white space.
        let odd = "pass word\n\"q\"\\ \u{e9}", body = #"{"name":"a \"b\"","n":[1,2]}"#
        FakeHub.reset(answer: Self.confirming(Self.confirmed(["method": "POST", "path": "/v1/things", "auth": "basic", "body": body])))
        let made = try await Self.send(calls, login: Self.login(at: service.origin, password: odd, username: "user-1"))
        #expect(made["status"] as? Int == 201 && made["body"] as? String == "made")
        var parts = LocalService.parts(of: try #require(service.received.last))
        #expect(parts.lines.first == "POST /v1/things HTTP/1.1" && parts.body == Data(body.utf8))
        #expect(parts.lines.contains("Authorization: Basic " + Data(("user-1:" + odd).utf8).base64EncodedString()))
        #expect(parts.lines.contains("Content-Type: application/json") && parts.lines.contains("Content-Length: \(body.utf8.count)"))
        // A named header, and a method without a body.
        FakeHub.reset(answer: Self.confirming(Self.confirmed(["request_id": "0a1b2c3d-5555-4666-8777-999999999999", "method": "DELETE",
                                                              "path": "/v1/things/7", "auth": "header:X-Api-Key"])))
        _ = try await Self.send(calls, job: 32, login: Self.login(at: service.origin))
        parts = LocalService.parts(of: try #require(service.received.last))
        #expect(parts.lines.first == "DELETE /v1/things/7 HTTP/1.1" && parts.lines.contains("X-Api-Key: " + Self.value) && parts.body.isEmpty)
        #expect(!parts.lines.contains { $0.hasPrefix("Authorization") || $0.hasPrefix("Content-") })
        FakeHub.reset(answer: Self.confirming(Self.confirmed(["request_id": "0a1b2c3d-5555-4666-8777-aaaaaaaaaaaa", "method": "POST", "path": "/v1/things/7/close"])))
        _ = try await Self.send(calls, job: 33, login: Self.login(at: service.origin))
        parts = LocalService.parts(of: try #require(service.received.last))
        #expect(parts.lines.first == "POST /v1/things/7/close HTTP/1.1" && parts.lines.contains("Content-Length: 0") && parts.body.isEmpty)
        #expect(service.received.count == 3)
    }

    @Test func aTimeoutAfterTheServiceGotTheRequestIsUnknown() async throws {
        let service = try LocalService(.silent)
        defer { service.stop() }
        FakeHub.reset(answer: Self.confirming())
        let started = Date()
        let reply = try await Self.send(VaultCalls(store: FakeKeychainJournal()), limit: 2, login: Self.login(at: service.origin))
        #expect(NSDictionary(dictionary: reply) == NSDictionary(dictionary: [
            "ok": false, "v": 2, "unknown": true, "error": "The request may have been sent. Its answer is not known. It is not sent again."]))
        #expect(Date().timeIntervalSince(started) >= 1.9)
        // The service has the request and the value: "nothing was sent" would not be true.
        #expect(service.received.count == 1)
        #expect(String(decoding: try #require(service.received.first), as: UTF8.self).contains("Authorization: Bearer " + Self.value))
    }

    @Test func anAnswerThatIsLostAfterTheSendIsUnknown() async throws {
        // The service takes the request and closes without an answer.
        let service = try LocalService(.close)
        defer { service.stop() }
        FakeHub.reset(answer: Self.confirming(Self.confirmed(["method": "POST", "body": #"{"pay":1}"#])))
        let reply = try await Self.send(VaultCalls(store: FakeKeychainJournal()), login: Self.login(at: service.origin))
        #expect(NSDictionary(dictionary: reply) == Self.unknown(.callUnknown))
        #expect(service.received.count == 1)
        #expect(LocalService.parts(of: try #require(service.received.first)).body == Data(#"{"pay":1}"#.utf8))
        // An answer that stops in its middle is not a complete answer.
        let half = try LocalService(.answer(Data("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nonly the start".utf8)))
        defer { half.stop() }
        FakeHub.reset(answer: Self.confirming(Self.confirmed(["request_id": "0a1b2c3d-5555-4666-8777-bbbbbbbbbbbb"])))
        let cut = try await Self.send(VaultCalls(store: FakeKeychainJournal()), login: Self.login(at: half.origin))
        #expect(NSDictionary(dictionary: cut) == Self.unknown(.callUnknown) && half.received.count == 1)
    }

    @Test func aRedirectIsNotFollowed() async throws {
        let other = try LocalService(.answer(LocalService.response(body: Data("the other place".utf8))))
        defer { other.stop() }
        let service = try LocalService(.answer(LocalService.response("302 Found", headers: ["Location: \(other.origin)/else"], body: Data("moved".utf8))))
        defer { service.stop() }
        FakeHub.reset(answer: Self.confirming())
        let reply = try await Self.send(VaultCalls(store: FakeKeychainJournal()), login: Self.login(at: service.origin))
        #expect(NSDictionary(dictionary: reply) == NSDictionary(dictionary: ["ok": true, "v": 2, "job": 31, "status": 302, "body": "moved", "truncated": false]))
        #expect(service.received.count == 1 && other.received.isEmpty)
    }

    @Test func aHostThatIsNotFoundOrNotReachedGetsNothingAndATLSFailureIsNotCalledThat() async throws {
        // No listener on the port: curl makes no connection.
        FakeHub.reset(answer: Self.confirming())
        let closed = try await Self.send(VaultCalls(store: FakeKeychainJournal()), login: Self.login(at: "http://127.0.0.1:\(try LocalService.closedPort())"))
        #expect(NSDictionary(dictionary: closed) == Self.refusal(.callUnreachable))
        #expect(VaultFailure.callUnreachable.rawValue == "The service could not be reached. Nothing was sent.")
        // A name that no resolver can find: one of its parts is too long.
        FakeHub.reset(answer: Self.confirming())
        let unnamed = try await Self.send(VaultCalls(store: FakeKeychainJournal()),
                                          login: Self.login(at: "http://" + String(repeating: "a", count: 64) + ".invalid"), plain: { _ in true })
        #expect(NSDictionary(dictionary: unnamed) == Self.refusal(.callUnreachable))
        // A listener without TLS at an HTTPS address: the handshake fails, and the service does not get the value.
        // The vault still does not say "nothing was sent": only the two cases above are that certain.
        let service = try LocalService(.early(Data("HTTP/1.1 400 Bad Request\r\n\r\n".utf8)))
        defer { service.stop() }
        FakeHub.reset(answer: Self.confirming())
        let handshake = try await Self.send(VaultCalls(store: FakeKeychainJournal()), login: Self.login(at: "https://127.0.0.1:\(service.port)"))
        #expect(NSDictionary(dictionary: handshake) == Self.unknown(.callUnknown))
        #expect(service.received.count == 1)
        #expect(!String(decoding: try #require(service.received.first), as: UTF8.self).contains(Self.value))
    }

    @Test func aLongAnswerIsCutAndAValueAcrossTheCutIsNotShown() async throws {
        // 100,000 bytes of text: the first 65,536 are shown.
        let long = try await Self.exchange(Data(repeating: 0x61, count: 100_000))
        #expect(long["truncated"] as? Bool == true && long["status"] as? Int == 200)
        #expect(long["body"] as? String == String(repeating: "a", count: 65_536))
        // The value begins 6 bytes before the cut, so its first 6 characters would be at the end of the shown part.
        let across = Data(repeating: 0x61, count: 65_530) + Data(Self.value.utf8) + Data(repeating: 0x62, count: 2_000)
        let withheld = try await Self.exchange(across)
        #expect(NSDictionary(dictionary: withheld) == NSDictionary(dictionary: ["ok": true, "v": 2, "job": 31, "status": 200, "withheld": "key"]))
        // The same answer for a login with another value is shown, with the cut.
        let shown = try await Self.exchange(across, password: "ANOTHER-SYNTHETIC-KEY-987654")
        #expect(shown["truncated"] as? Bool == true && (shown["body"] as? String)?.hasSuffix("aaaaSYNTHE") == true)
        // A cut inside one character drops that character and nothing more.
        let letters = try await Self.exchange(Data("a".utf8) + Data(String(repeating: "\u{e9}", count: 40_000).utf8))
        #expect(letters["truncated"] as? Bool == true && letters["body"] as? String == "a" + String(repeating: "\u{e9}", count: 32_767))
        // An answer that is not text is not shown.
        let binary = try await Self.exchange(Data([0xff, 0xfe, 0x00, 0x01]))
        #expect(NSDictionary(dictionary: binary) == NSDictionary(dictionary: ["ok": true, "v": 2, "job": 31, "status": 200, "withheld": "binary"]))
    }

    @Test func anAnswerThatEchoesTheValueInItsJSONFormOrItsBasicFormIsNotShown() async throws {
        let withheld: NSDictionary = ["ok": true, "v": 2, "job": 31, "status": 200, "withheld": "key"]
        // The value as it is.
        #expect(NSDictionary(dictionary: try await Self.exchange(Data(("{\"headers\":{\"authorization\":\"Bearer " + Self.value + "\"}}").utf8))) == withheld)
        // A value with a quote and a slash, as a JSON answer gives it: with `\/` and without it.
        let odd = "SYNTHETIC/\"KEY\"/0123456789"
        for echoed in [#"{"authorization":"Bearer SYNTHETIC/\"KEY\"/0123456789"}"#, #"{"authorization":"Bearer SYNTHETIC\/\"KEY\"\/0123456789"}"#] {
            #expect(NSDictionary(dictionary: try await Self.exchange(Data(echoed.utf8), password: odd)) == withheld)
        }
        // A service that answers as Python's `json.dumps` does: a letter that is not ASCII is a `\u` escape.
        let accented = "stand-in-\u{e9}-value-0123456789", escaped = #"stand-in-\u00e9-value-0123456789"#
        #expect(NSDictionary(dictionary: try await Self.exchange(Data((#"{"headers":{"Authorization":"Bearer "# + escaped + #""}}"#).utf8), password: accented)) == withheld)
        // The same form across the cut: it begins in the part that would be shown.
        let across = Data(repeating: 0x61, count: 65_520) + Data(escaped.utf8) + Data(repeating: 0x62, count: 500)
        #expect(NSDictionary(dictionary: try await Self.exchange(across, password: accented)) == withheld)
        // Basic: the service echoes the header that it got. That value holds the password.
        let token = Data(("api-user:" + Self.value).utf8).base64EncodedString()
        #expect(NSDictionary(dictionary: try await Self.exchange(Data(("{\"authorization\":\"Basic " + token + "\"}").utf8), ["auth": "basic"])) == withheld)
        // The same text is shown when the request did not send that Basic value.
        #expect(try await Self.exchange(Data(("{\"authorization\":\"Basic " + token + "\"}").utf8))["body"] as? String == "{\"authorization\":\"Basic " + token + "\"}")
        // The existing rule for a short value: it is used, it is not looked for, and it is not called masked.
        let short = try await Self.exchange(Data("your key is short-7".utf8), password: "short-7")
        #expect(short["body"] as? String == "your key is short-7" && short["withheld"] == nil)
    }

    // MARK: One start for each request

    @Test func theSameRequestIsNeverStartedASecondTime() async throws {
        let service = try LocalService(.answer(LocalService.response(body: Data("done".utf8))))
        defer { service.stop() }
        let store = FakeKeychainJournal()
        // This hub confirms the same job again, which the real hub must not do.
        FakeHub.reset(answer: Self.confirming(Self.confirmed(["method": "POST", "body": #"{"pay":1}"#])))
        let first = try await Self.send(VaultCalls(store: store), login: Self.login(at: service.origin))
        #expect(first["status"] as? Int == 200 && service.received.count == 1)
        let again: NSDictionary = ["ok": false, "v": 2, "unknown": true, "error": "This request was already started. It is not sent again."]
        // The same vault process, and a new one on the same journal (the vault started again).
        let calls = VaultCalls(store: store)
        #expect(NSDictionary(dictionary: try await Self.send(calls, login: Self.login(at: service.origin))) == again)
        #expect(NSDictionary(dictionary: try await Self.send(VaultCalls(store: store), login: Self.login(at: service.origin))) == again)
        // The same request under another job number is still that request.
        #expect(NSDictionary(dictionary: try await Self.send(calls, job: 32, login: Self.login(at: service.origin))) == again)
        #expect(service.received.count == 1)
        // The hub's refusal of a second confirmation: the vault keeps no confirmation, so it sends nothing.
        FakeHub.reset(answer: { _, _ in (409, ["error": "this job is confirmed"]) })
        #expect(NSDictionary(dictionary: try await Self.send(calls, login: Self.login(at: service.origin))) == Self.refusal(.hub))
        #expect(service.received.count == 1)
        // Another request of the same task is sent.
        FakeHub.reset(answer: Self.confirming(Self.confirmed(["request_id": "0a1b2c3d-5555-4666-8777-cccccccccccc"])))
        #expect(try await Self.send(calls, job: 33, login: Self.login(at: service.origin))["status"] as? Int == 200)
        #expect(service.received.count == 2)
    }

    @Test func aRequestThatTheJournalCannotKeepIsNotSent() async throws {
        let service = try LocalService(.answer(LocalService.response(body: Data("done".utf8))))
        defer { service.stop() }
        let store = FakeKeychainJournal()
        store.fails = true
        FakeHub.reset(answer: Self.confirming())
        let reply = try await Self.send(VaultCalls(store: store), login: Self.login(at: service.origin))
        #expect(NSDictionary(dictionary: reply) == Self.refusal(.keychain))
        #expect(service.received.isEmpty && store.data == nil)
    }

    @Test func aRefusedKeyAClosedJobOrALoginOfAnotherProjectReadsAndSendsNothing() async throws {
        let service = try LocalService(.answer(LocalService.response(body: Data("done".utf8))))
        defer { service.stop() }
        let calls = VaultCalls(store: FakeKeychainJournal()), read = Log(), login = try Self.login(at: service.origin)
        func send(_ login: @escaping @Sendable (VaultJob) async throws -> VaultLogin) async throws -> NSDictionary {
            NSDictionary(dictionary: await VaultBroker.call(try Self.request(), as: Self.studio, hub: try Self.callHub(), calls: calls, limit: 5,
                                                            plain: { $0 == "127.0.0.1" }, login: login))
        }
        // The hub refuses the caller's key, or the job: it is closed, its task has a hold, or the login is not of its project.
        for (status, body, failure) in [(403, ["error": "this is not studio's agent key", "auth": "key_mismatch"], VaultFailure.key),
                                        (403, ["error": "the login is of another project"], .hub), (409, ["error": "the task has a hold"], .hub),
                                        (404, [:], .hub)] as [(Int, [String: String], VaultFailure)] {
            FakeHub.reset(answer: { _, _ in (status, body) })
            #expect(try await send { _ in read.add("login"); return login } == Self.refusal(failure))
        }
        #expect(read.events.isEmpty && service.received.isEmpty)
        // A sealed copy that was made for project `shop`, in a job of project `other`: the check of the copy refuses it.
        FakeHub.reset(answer: Self.confirming(Self.confirmed(["login": "sealed:7", "project": "other"])))
        let copy = try login.sealedPayload(provenance: VaultProvenance.stamp(job: 12, project: "shop", source: Self.reference))
        let relabelled = try await send { job in
            _ = try VaultProvenance.check(payload: copy, record: SealedRecord(job: 12, project: "shop", source: Self.reference), usingProject: job.project)
            return login
        }
        #expect(relabelled == Self.refusal(.relabelledCopy))
        // A login that cannot be protected in messages is not used.
        FakeHub.reset(answer: { route, _ in route.hasSuffix("/fingerprints") ? (500, [:]) : (200, Self.confirmed()) })
        #expect(try await send { _ in login } == Self.refusal(.protection))
        #expect(service.received.isEmpty)
    }

    @Test func aRequestUsesALoginThatItsTaskMadeOnlyWhenThisVaultMadeIt() async throws {
        let id = "0a1b2c3d-7777-4888-8999-aaaaaaaaaaaa"
        let fields: [String: Any] = ["db": "test-generation", "attempt": 2, "request_id": id, "label": "Shop API key", "username": "shop-key-1",
                                     "url": "https://shop.example.test/settings/keys"]
        let made = try VaultCreation(fields: fields, agent: "studio", task: "T-7", project: "shop")
        let items = FakeItems()
        let writer = try VaultWriter(store: FakeKeychainJournal(), limit: 1_048_576, clock: { 1_000 }) { (items, FakeItems.project) }
        let record = try await writer.create(requestID: id, binding: made.binding, title: made.label, hub: "http://100.64.0.1:9", db: made.db,
                                             mark: VaultCreateJob.mark(agent: "studio", requestID: id)) { try made.value() }
        let login = try #require(record.login)
        func job(_ login: String, _ change: [String: Any] = [:]) throws -> VaultJob {
            let by = fields.merging(["agent": "studio"]) { given, _ in given }.merging(change) { _, new in new }
            return try VaultJob(data: JSONSerialization.data(withJSONObject: Self.confirmed(["login": login, "created_by": by])), request: Self.request())
        }
        #expect(try job(login).createdBy == made)
        #expect(await VaultBroker.refusal(ofMadeUse: try job(login), operation: .request, caller: Self.studio, writer: writer) == nil)
        // Another reference, another input, another agent, or a vault that did not make it.
        #expect(await VaultBroker.refusal(ofMadeUse: try job(Self.reference), operation: .request, caller: Self.studio, writer: writer) == .notMadeHere)
        #expect(await VaultBroker.refusal(ofMadeUse: try job(login, ["attempt": 3]), operation: .request, caller: Self.studio, writer: writer) == .notMadeHere)
        #expect(await VaultBroker.refusal(ofMadeUse: try job(login), operation: .request, caller: VaultCaller(agent: "seo", key: Self.otherKey), writer: writer) == .notMadeHere)
        let elsewhere = try VaultWriter(store: FakeKeychainJournal(), limit: 1_048_576, clock: { 1_000 }) { (items, FakeItems.project) }
        #expect(await VaultBroker.refusal(ofMadeUse: try job(login), operation: .request, caller: Self.studio, writer: elsewhere) == .notMadeHere)
        // A handover never has this permission.
        #expect(await VaultBroker.refusal(ofMadeUse: try job(login), operation: .handover, caller: Self.studio, writer: writer) == .notMadeHere)
    }

    /// The two operations together: the vault makes a login (the stand-in for Bitwarden keeps the item), and a request
    /// of the same task then sends that item's value to the service. The refusals of a made login have their own test
    /// above; this one has the one case that shows the chain sends nothing after a refusal.
    @Test func aLoginThatTheVaultMadeGoesInARequestOfItsTaskWithItsExactValue() async throws {
        let service = try LocalService(.answer(LocalService.response(body: Data("ok".utf8))))
        defer { service.stop() }
        let items = FakeItems()
        let writer = try VaultWriter(store: FakeKeychainJournal(), limit: 1_048_576, clock: { 1_000 }) { (items, FakeItems.project) }
        // The task makes a login for the service's own address.
        let createID = "0a1b2c3d-7777-4888-8999-bbbbbbbbbbbb"
        let creation: [String: Any] = ["db": "test-generation", "attempt": 2, "request_id": createID, "label": "Shop API account",
                                       "username": "shop-api-1", "url": service.origin + "/account/login"]
        let created = Fields(creation.merging(["ok": true, "job": 21, "task": "T-7", "kind": "create", "project": "shop",
                                               "mark": "fleet-create:studio:" + createID]) { given, _ in given })
        FakeHub.reset(answer: { route, body in
            if route.hasSuffix("/created") {
                return (200, ["ok": true, "job": body["job"] ?? 0, "login": body["login"] ?? "", "fingerprint_salts": Self.callSalts])
            }
            if route.hasSuffix("/fingerprints") {
                return (200, ["ok": true, "job": body["job"] ?? 0, "stored": (body["fingerprints"] as? [Any])?.count ?? 0, "known": 0])
            }
            return (200, created.value)
        })
        let make = try VaultRequest(data: Self.line(["op": "create", "job": 21, "agent": "studio", "agent_key": Self.agentKey]))
        let made = await VaultBroker.create(make, as: Self.studio, hub: try Self.callHub(), writer: writer, address: "http://100.64.0.1:9")
        let login = try #require(made["login"] as? String)
        // The value is in the stand-in's item only. The test reads it there to know what the service must get.
        let item = try #require(items.stored.first?.value)
        let password = try #require((try JSONSerialization.jsonObject(with: Data(item.value.utf8)) as? [String: String])?["password"])
        #expect(items.creates == 1 && item.name == "Shop API account" && item.note == "fleet-create:studio:" + createID)
        // The hub gives the use of that login to a request of the same task only with `created_by`.
        let by = creation.merging(["agent": "studio"]) { given, _ in given }
        let confirmation = Self.confirmed(["login": login, "created_by": by, "method": "POST", "path": "/v1/orders", "auth": "basic", "body": #"{"n":1}"#])
        func request(_ calls: VaultCalls, journal: VaultWriter) async throws -> NSDictionary {
            FakeHub.reset(answer: Self.confirming(confirmation))
            return NSDictionary(dictionary: await VaultBroker.call(try Self.request(), as: Self.studio, hub: try Self.callHub(), calls: calls, limit: 5,
                                                                    plain: { $0 == "127.0.0.1" }) { job in
                // As the broker does for a made login: the vault's own record first, then the item.
                if let refusal = await VaultBroker.refusal(ofMadeUse: job, operation: .request, caller: Self.studio, writer: journal) { throw refusal }
                return try items.login(id: String(job.login.dropFirst(6)))
            })
        }
        let reply = try await request(VaultCalls(store: FakeKeychainJournal()), journal: writer)
        #expect(reply == ["ok": true, "v": 2, "job": 31, "status": 200, "body": "ok", "truncated": false])
        // The service got one request, with the Basic value of exactly the user name and the password of the made item.
        #expect(service.received.count == 1)
        let parts = LocalService.parts(of: try #require(service.received.first))
        #expect(parts.lines.first == "POST /v1/orders HTTP/1.1" && parts.body == Data(#"{"n":1}"#.utf8))
        #expect(parts.lines.filter { $0.hasPrefix("Authorization:") } == ["Authorization: Basic " + Data(("shop-api-1:" + password).utf8).base64EncodedString()])
        #expect(!String(decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self).contains(password))
        #expect(FakeHub.seen.map(\.route) == ["/helper/vault/studio", "/helper/vault/studio/fingerprints"])
        // A vault that did not make the login reads no item and sends nothing, with the same confirmation of the hub.
        let elsewhere = try VaultWriter(store: FakeKeychainJournal(), limit: 1_048_576, clock: { 1_000 }) { (items, FakeItems.project) }
        #expect(try await request(VaultCalls(store: FakeKeychainJournal()), journal: elsewhere) == Self.refusal(.notMadeHere))
        #expect(service.received.count == 1 && FakeHub.seen.map(\.route) == ["/helper/vault/studio"] && items.creates == 1)
    }

    /// The same for a key that the vault reads from a page (`capture`): the value that the page gave goes to the service
    /// in a request of the same task. A stand-in gives the page's value; the script that reads a real page has its own
    /// tests. A key that was read on another origin than the one where it is used gets no request.
    @Test func aKeyThatTheVaultReadFromAPageGoesInARequestOfItsTaskWithItsExactValue() async throws {
        let service = try LocalService(.answer(LocalService.response(body: Data("ok".utf8))))
        defer { service.stop() }
        let items = FakeItems(), calls = VaultCalls(store: FakeKeychainJournal()), reads = Log()
        let writer = try VaultWriter(store: FakeKeychainJournal(), limit: 1_048_576, clock: { 1_000 }) { (items, FakeItems.project) }
        /// One `capture` job: the hub's fields of the save, and the value that the page shows. The login's name.
        func capture(job: Int, _ fields: [String: Any], page value: String) async throws -> String {
            let id = try #require(fields["request_id"] as? String)
            let confirmed = Fields(fields.merging(["ok": true, "job": job, "task": "T-7", "project": "shop", "mark": "fleet-create:studio:" + id]) { given, _ in given })
            FakeHub.reset(answer: { route, body in
                if route.hasSuffix("/created") {
                    return (200, ["ok": true, "job": body["job"] ?? 0, "login": body["login"] ?? "", "fingerprint_salts": Self.callSalts])
                }
                if route.hasSuffix("/fingerprints") {
                    return (200, ["ok": true, "job": body["job"] ?? 0, "stored": (body["fingerprints"] as? [Any])?.count ?? 0, "known": 0])
                }
                return (200, confirmed.value)
            })
            let line = try VaultRequest(data: Self.line(["op": "capture", "job": job, "agent": "studio", "agent_key": Self.agentKey]))
            let made = await VaultBroker.create(line, as: Self.studio, hub: try Self.callHub(), writer: writer, address: "http://100.64.0.1:9") { origin, selector in
                reads.add(origin + " " + selector)
                return value
            }
            return try #require(made["login"] as? String)
        }
        /// One `request` of the same task with the login of a save, as the hub confirms it with `created_by`.
        func request(job: Int, id: String, login: String, madeBy fields: [String: Any]) async throws -> NSDictionary {
            let by = fields.merging(["agent": "studio"]) { given, _ in given }
            FakeHub.reset(answer: Self.confirming(Self.confirmed(["request_id": id, "login": login, "created_by": by, "method": "POST",
                                                                  "path": "/v1/orders", "auth": "basic", "body": #"{"n":1}"#])))
            return NSDictionary(dictionary: await VaultBroker.call(try Self.request(job: job), as: Self.studio, hub: try Self.callHub(), calls: calls,
                                                                    limit: 5, plain: { $0 == "127.0.0.1" }) { job in
                // As the broker does for a made login: the vault's own record first, then the item.
                if let refusal = await VaultBroker.refusal(ofMadeUse: job, operation: .request, caller: Self.studio, writer: writer) { throw refusal }
                return try items.login(id: String(job.login.dropFirst(6)))
            })
        }
        // The service shows a new key on a page of its own address. Only the stand-in for the page has the value.
        let shown = "fresh-" + UUID().uuidString
        let onItsPage: [String: Any] = ["db": "test-generation", "attempt": 2, "request_id": "0a1b2c3d-7777-4888-8999-cccccccccccc", "label": "Shop API key",
                                        "username": "shop-key-1", "url": service.origin + "/keys", "kind": "capture", "selector": "#key"]
        let login = try await capture(job: 22, onItsPage, page: shown)
        #expect(reads.events == [service.origin + "/keys #key"])         // one read, of that field, on the page that the hub confirmed
        #expect(items.creates == 1)
        let reply = try await request(job: 31, id: Self.callID, login: login, madeBy: onItsPage)
        #expect(reply == ["ok": true, "v": 2, "job": 31, "status": 200, "body": "ok", "truncated": false])
        // The service got one request, with the Basic value of exactly the value that the page gave.
        #expect(service.received.count == 1)
        let parts = LocalService.parts(of: try #require(service.received.first))
        #expect(parts.lines.first == "POST /v1/orders HTTP/1.1" && parts.body == Data(#"{"n":1}"#.utf8))
        #expect(parts.lines.filter { $0.hasPrefix("Authorization:") } == ["Authorization: Basic " + Data(("shop-key-1:" + shown).utf8).base64EncodedString()])
        #expect(!String(decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self).contains(shown))
        // A second key for the same service, which another site shows. The vault reads it there and saves it. The task
        // that saved it gets no request with it: a site's key does not go to an address that the agent named.
        let other = "fresh-" + UUID().uuidString
        let onAnotherSite = onItsPage.merging(["request_id": "0a1b2c3d-7777-4888-8999-dddddddddddd", "label": "Shop API key 2", "username": "shop-key-2",
                                               "source_url": "https://console.example.test/keys"]) { _, new in new }
        let second = try await capture(job: 23, onAnotherSite, page: other)
        #expect(reads.events.last == "https://console.example.test/keys #key" && items.creates == 2 && second != login)
        #expect(try await request(job: 32, id: "0a1b2c3d-5555-4666-8777-999999999990", login: second, madeBy: onAnotherSite) == Self.refusal(.captureUse))
        // Nothing went to the service, and the vault read no login for that request (no fingerprints at the hub).
        #expect(service.received.count == 1 && FakeHub.seen.map(\.route) == ["/helper/vault/studio"])
    }

    // MARK: Cancel

    @Test func aCancelBetweenTheConfirmationAndTheStartSendsNothingAndTheNextAttemptWorks() async throws {
        let service = try LocalService(.answer(LocalService.response(body: Data("done".utf8))))
        defer { service.stop() }
        let calls = VaultCalls(store: FakeKeychainJournal()), login = try Self.login(at: service.origin)
        let scope = try #require(VaultCallScope(db: "test-generation", task: "T-7", attempt: 2, caller: Self.studio))
        // The hub confirms the job at once, and its answer to the fingerprints comes late. The cancel comes in that
        // time: after the confirmation, and before the request has a child that a cancel could find.
        FakeHub.reset(answer: Self.confirming(), delay: { $0.hasSuffix("/fingerprints") ? 0.5 : 0 })
        async let late = Self.send(calls, login: login)
        try await Self.until { FakeHub.seen.contains { $0.route.hasSuffix("/fingerprints") } }
        #expect(calls.cancel(scope) == 0)                    // nothing runs yet: nothing to end, and the task attempt is stopped
        #expect(NSDictionary(dictionary: try await late) == NSDictionary(dictionary: [
            "ok": false, "v": 2, "error": "This task's requests were stopped. Nothing was sent."]))
        #expect(service.received.isEmpty)
        // A request whose confirmation itself comes after the cancel reads no login.
        let read = Log()
        FakeHub.reset(answer: Self.confirming(Self.confirmed(["request_id": "0a1b2c3d-5555-4666-8777-dddddddddddd"])))
        let after = await VaultBroker.call(try Self.request(job: 32), as: Self.studio, hub: try Self.callHub(), calls: calls, limit: 5,
                                           plain: { $0 == "127.0.0.1" }) { _ in read.add("login"); return login }
        #expect(NSDictionary(dictionary: after) == Self.refusal(.callStopped))
        #expect(read.events.isEmpty && FakeHub.seen.map(\.route) == ["/helper/vault/studio"] && service.received.isEmpty)
        // The same task in its next attempt is another scope: it works.
        FakeHub.reset(answer: Self.confirming(Self.confirmed(["attempt": 3, "request_id": "0a1b2c3d-5555-4666-8777-eeeeeeeeeeee"])))
        let next = try await Self.send(calls, job: 33, login: login)
        #expect(next["status"] as? Int == 200 && next["body"] as? String == "done" && service.received.count == 1)
    }

    @Test func aCancelEndsARequestThatTheServiceHasAndProvesThatItsProcessIsGone() async throws {
        let service = try LocalService(.silent)
        defer { service.stop() }
        let store = FakeKeychainJournal(), calls = VaultCalls(store: store)
        let broker = VaultBroker(configuration: try Self.callConfiguration, bundle: .main, protocolClasses: [FakeHub.self], calls: calls)
        func cancel(_ change: [String: Any] = [:]) throws -> NSDictionary {
            NSDictionary(dictionary: try #require(try JSONSerialization.jsonObject(with: broker.cancel(try Self.line(Self.cancelFields(change)), uid: 501)) as? [String: Any]))
        }
        FakeHub.reset(answer: Self.confirming())
        let login = try Self.login(at: service.origin)
        async let stopped = Self.send(calls, limit: 30, login: login)
        // The request is at the service, with the value.
        #expect(service.waitForMessages())
        let pid = try #require(Self.process(in: store))
        #expect(kill(pid, 0) == 0)
        // Another agent, another task, another attempt and another generation name another scope: nothing of this request ends.
        let nothing: NSDictionary = ["ok": true, "v": 2, "task": "T-7", "attempt": 2, "stopped": true, "ended": 0]
        #expect(try cancel(["agent": "seo", "agent_key": Self.otherKey]) == nothing)
        #expect(try cancel(["db": "other-generation"]) == nothing)
        #expect(try cancel(["task": "T-8"]) == ["ok": true, "v": 2, "task": "T-8", "attempt": 2, "stopped": true, "ended": 0])
        #expect(try cancel(["attempt": 3]) == ["ok": true, "v": 2, "task": "T-7", "attempt": 3, "stopped": true, "ended": 0])
        // The same task attempt with another key: that caller does not end the request, and it gets no proof.
        let unproved: NSDictionary = ["ok": false, "v": 2, "error": "The vault cannot prove that its request ended."]
        #expect(try cancel(["agent_key": Self.otherKey]) == unproved)
        // Another user of this machine, and a line that is not a cancel.
        #expect(NSDictionary(dictionary: try #require(try JSONSerialization.jsonObject(with: broker.cancel(try Self.line(Self.cancelFields()), uid: 502)) as? [String: Any]))
                == Self.refusal(.request))
        #expect(kill(pid, 0) == 0 && service.received.count == 1)
        // The caller of the request: its child ends, and the vault has taken its status before it answers.
        #expect(try cancel() == ["ok": true, "v": 2, "task": "T-7", "attempt": 2, "stopped": true, "ended": 1])
        #expect(kill(pid, 0) != 0 && errno == ESRCH)
        #expect(Self.process(in: store) == nil)
        #expect(NSDictionary(dictionary: try await stopped) == NSDictionary(dictionary: [
            "ok": false, "v": 2, "unknown": true, "canceled": true,
            "error": "The request was stopped before its answer. The service can have received it. It is not sent again."]))
        // The cancel again finds nothing, and it still says stopped. It is the same answer when it comes as a job line.
        #expect(try cancel() == nothing)
        let asJob = await broker.handle(try Self.line(Self.cancelFields()), uid: 501)
        #expect(NSDictionary(dictionary: try #require(try JSONSerialization.jsonObject(with: asJob) as? [String: Any])) == nothing)
        // The stopped request is not sent again. The service can have it, so the answer is not "nothing was sent".
        FakeHub.reset(answer: Self.confirming())
        #expect(NSDictionary(dictionary: try await Self.send(calls, login: login)) == Self.unknown(.callRepeated))
        #expect(FakeHub.seen.map(\.route) == ["/helper/vault/studio"])         // it read no login: no fingerprints
        // Another request of the stopped task attempt was never started: nothing was sent.
        FakeHub.reset(answer: Self.confirming(Self.confirmed(["request_id": "0a1b2c3d-5555-4666-8777-ffffffffffff"])))
        #expect(NSDictionary(dictionary: try await Self.send(calls, job: 32, login: login)) == Self.refusal(.callStopped))
        #expect(service.received.count == 1)
    }

    @Test func theSocketServesACancelAtOnceAndEveryOtherJobInItsTurn() async throws {
        let log = Log()
        let socket = VaultSocket(configuration: try Self.callConfiguration, handle: { data, _ in
            let name = String(decoding: data, as: UTF8.self)
            log.add("start " + name)
            try? await Task.sleep(for: .milliseconds(300))
            log.add("end " + name)
            return data
        }, cancel: { _, _ in
            log.add("cancel")
            return Data("stopped".utf8)
        })
        socket.take(Data("A".utf8), uid: 501) { log.add("reply " + String(decoding: $0, as: UTF8.self)) }
        socket.take(Data("B".utf8), uid: 501) { log.add("reply " + String(decoding: $0, as: UTF8.self)) }
        try await Self.until { log.events.contains("start A") }
        // Job A runs and job B waits. The cancel does not wait for them.
        socket.take(try Self.line(Self.cancelFields()), uid: 501) { log.add("reply " + String(decoding: $0, as: UTF8.self)) }
        #expect(log.events == ["start A", "cancel", "reply stopped"])
        try await Self.until { log.events.contains("reply B") }
        #expect(log.events == ["start A", "cancel", "reply stopped", "end A", "reply A", "start B", "end B", "reply B"])
    }

    @Test func aStatusReadingDoesNotWaitForARequestAndTheCancelStillProvesTheEnd() async throws {
        let service = try LocalService(.silent)
        defer { service.stop() }
        let store = FakeKeychainJournal(), calls = VaultCalls(store: store), replies = Replies()
        let broker = VaultBroker(configuration: try Self.callConfiguration, bundle: .main, protocolClasses: [FakeHub.self], calls: calls)
        let login = try Self.login(at: service.origin)
        FakeHub.reset(answer: Self.confirming())
        // The socket with the broker's own cancel. A job line is a real request to the service; a status line gives the
        // broker's status. (The broker's own job path needs the Keychain, which a test process does not have.)
        let socket = VaultSocket(configuration: try Self.callConfiguration, handle: { data, _ in
            guard let request = try? VaultRequest(data: data), let hub = try? Self.callHub() else { return Data() }
            let reply: [String: Any]
            if request.operation == .status {
                reply = VaultBroker.status(agent: "studio", user: "sam", recipient: "age1" + String(repeating: "q", count: 58), requests: true)
            } else {
                reply = await VaultBroker.call(request, as: Self.studio, hub: hub, calls: calls, limit: 30, plain: { $0 == "127.0.0.1" }) { _ in login }
            }
            return (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
        }, cancel: { broker.cancel($0, uid: $1) })
        socket.take(try Self.line(["op": "request", "job": 31, "agent": "studio", "agent_key": Self.agentKey]), uid: 501) { replies.set("request", $0) }
        // The request is at the service, which holds its answer.
        #expect(service.waitForMessages())
        let pid = try #require(Self.process(in: store))
        // A status reading comes while the request is held: it gets its answer, and the request still runs.
        socket.take(try Self.line(["op": "status"]), uid: 501) { replies.set("status", $0) }
        try await Self.until(2) { replies.has("status") }
        #expect(try replies.object("status")["requests"] as? Bool == true)
        #expect(!replies.has("request") && kill(pid, 0) == 0)
        // Stop: the cancel ends the child, and the vault has taken its status before it answers.
        socket.take(try Self.line(Self.cancelFields()), uid: 501) { replies.set("cancel", $0) }
        #expect(try replies.object("cancel") == ["ok": true, "v": 2, "task": "T-7", "attempt": 2, "stopped": true, "ended": 1])
        #expect(kill(pid, 0) != 0 && errno == ESRCH)
        try await Self.until { replies.has("request") }
        #expect(try replies.object("request") == ["ok": false, "v": 2, "unknown": true, "canceled": true, "error": VaultFailure.callCanceled.rawValue])
        #expect(service.received.count == 1)
    }
}

/// The replies of a socket by name, from more than one thread.
private final class Replies: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String: Data] = [:]
    func set(_ name: String, _ reply: Data) { lock.withLock { all[name] = reply } }
    func has(_ name: String) -> Bool { lock.withLock { all[name] != nil } }
    func object(_ name: String) throws -> NSDictionary {
        let reply = try #require(lock.withLock { all[name] })
        return NSDictionary(dictionary: try #require(try JSONSerialization.jsonObject(with: reply) as? [String: Any]))
    }
}

/// A value for a sendable closure of a test.
private final class Fields: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}

/// What happened, in its order, from more than one thread.
private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ event: String) { lock.withLock { list.append(event) } }
    var events: [String] { lock.withLock { list } }
}
