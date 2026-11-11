import Foundation
import Testing
@testable import FleetVaultCore

struct VaultTests {
    private let salts = ["password": "0123456789abcdef0123456789abcdef", "totp": "fedcba9876543210fedcba9876543210"]
    @Test func onlyFixedOperationsAndJobIDsAreAccepted() throws {
        #expect(try VaultRequest(data: Data(#"{"v":2,"op":"status"}"#.utf8)).job == nil)
        #expect(try VaultRequest(data: Data(#"{"v":2,"op":"chrome"}"#.utf8)).job == nil)
        #expect(try VaultRequest(data: Data(#"{"v":2,"op":"signin","job":12}"#.utf8)).job == 12)
        #expect(try VaultRequest(data: Data(#"{"v":2,"op":"probe","job":12}"#.utf8)).operation == .probe)
        for input in [
            #"{"v":2,"op":"get","job":1}"#,
            #"{"v":2,"op":"resolve","job":1}"#,
            #"{"v":2,"op":"signin","job":true}"#,
            #"{"v":2,"op":"signin","job":0}"#,
            #"{"v":2,"op":"signin","job":1.5}"#,
            #"{"v":2,"op":"signin","job":1,"login":"bws://override"}"#,
            #"{"v":2,"op":"handover","job":1,"recipient":"override"}"#,
            #"{"v":2,"op":"status","job":1}"#,
            #"{"v":2,"op":"chrome","job":1}"#,
            #"{"v":2,"op":"probe","job":1,"logins":["bws://override"]}"#,
            #"{"v":1,"op":"status"}"#
        ] { #expect(throws: VaultFailure.self) { try VaultRequest(data: Data(input.utf8)) } }
    }

    @Test func probeAcceptsOnlyTheExactHubJobAndItsNamedReferences() throws {
        let request = try VaultRequest(data: Data(#"{"v":2,"op":"probe","job":12}"#.utf8))
        let login = "bws://12345678-1234-1234-1234-123456789012"
        let good: [String: Any] = ["ok": true, "kind": "probe", "job": 12, "logins": [login]]
        #expect(try VaultProbeJob(data: JSONSerialization.data(withJSONObject: good), request: request).logins == [login])
        for (key, value) in [("job", 13 as Any), ("job", true as Any), ("kind", "signin" as Any),
                             ("ok", false as Any), ("logins", [login, login] as Any),
                             ("logins", ["sealed:1"] as Any), ("logins", ["file:/tmp/token"] as Any)] {
            var bad = good; bad[key] = value
            #expect(throws: VaultFailure.self) { try VaultProbeJob(data: JSONSerialization.data(withJSONObject: bad), request: request) }
        }
        let wrongOperation = try VaultRequest(data: Data(#"{"v":2,"op":"signin","job":12}"#.utf8))
        #expect(throws: VaultFailure.self) { try VaultProbeJob(data: JSONSerialization.data(withJSONObject: good), request: wrongOperation) }
    }

    @Test func probeReplyContainsOnlyTheReferenceAndFixedResultCodes() throws {
        let login = "bws://12345678-1234-1234-1234-123456789012"
        for password in ["1", "SYNTHETIC-PROBE-SECRET"] {
            let data = try JSONSerialization.data(withJSONObject: ["username": "SYNTHETIC-USER", "password": password,
                "url": "https://private.example.test", "totp": "SYNTHETIC-SEED"])
            let result = VaultProbeResult.inspect(login: login, value: data)
            #expect(result.state == "readable")
            let reply = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: String])
            #expect(reply == ["login": login, "state": "readable", "reason": "ok"])
        }
        for value: [String: Any] in [["username": "x", "password": ""], ["username": 5, "password": "x"],
                                    ["username": "x", "password": 1234], ["username": "x"]] {
            #expect(VaultProbeResult.inspect(login: login, value: try JSONSerialization.data(withJSONObject: value)).reason == .bad_format)
        }
        for value: [String: Any] in [["username": "", "password": "x"], ["password": "x"]] {          // an API key (owner feature secrets)
            #expect(VaultProbeResult.inspect(login: login, value: try JSONSerialization.data(withJSONObject: value)).reason == .ok)
        }
        #expect(VaultProbeResult.inspect(login: login, value: Data("not json".utf8)).state == "not_readable")
    }

    @Test func jobMustMatchHubGrant() throws {
        let request = try VaultRequest(data: Data(#"{"v":2,"op":"signin","job":12}"#.utf8))
        let grant: [String: Any] = ["ok": true, "kind": "signin", "job": 12, "task": "T-1",
                                   "login": "bws://12345678-1234-1234-1234-123456789012", "fingerprint_salts": salts]
        #expect(try VaultJob(data: JSONSerialization.data(withJSONObject: grant), request: request).task == "T-1")
        for (key, value) in [("job", 13 as Any), ("kind", "handover" as Any), ("login", "file:/tmp/token" as Any), ("task", "" as Any)] {
            var bad = grant; bad[key] = value
            #expect(throws: VaultFailure.self) { try VaultJob(data: JSONSerialization.data(withJSONObject: bad), request: request) }
        }
        for value in [[:], ["password": salts["password"]!], ["password": "bad", "totp": salts["totp"]!]] {
            var bad = grant; bad["fingerprint_salts"] = value
            #expect(throws: VaultFailure.self) { try VaultJob(data: JSONSerialization.data(withJSONObject: bad), request: request) }
        }
    }

    @Test func handoverMustHavePinnedRecipient() throws {
        let request = try VaultRequest(data: Data(#"{"v":2,"op":"handover","job":12}"#.utf8))
        let incomplete: [String: Any] = ["ok": true, "kind": "handover", "job": 12, "task": "T-1", "login": "sealed:1", "fingerprint_salts": salts]
        #expect(throws: VaultFailure.self) { try VaultJob(data: JSONSerialization.data(withJSONObject: incomplete), request: request) }
        var complete = incomplete; complete["target"] = "studio"; complete["recipient"] = "age1" + String(repeating: "q", count: 58)
        #expect(try VaultJob(data: JSONSerialization.data(withJSONObject: complete), request: request).target == "studio")
    }

    @Test func configurationRejectsRedirectsAndPublicHTTP() throws {
        let base: [String: Any] = ["agent": "studio", "hub": "http://100.96.10.20:8765", "store": "fleet",
                                   "socket": NSHomeDirectory() + "/Library/Application Support/AgentFleet/vault.sock", "worker_uid": 501]
        #expect(try VaultConfiguration(data: JSONSerialization.data(withJSONObject: base)).agent == "studio")
        for (key, value) in [("hub", "http://example.com" as Any), ("hub", "https://user:pass@example.com" as Any),
                             ("hub", "http://100.invalid.64.1.1" as Any), ("hub", "http://100..64.1.1" as Any),
                             ("hub", "https://example.com?redirect=bad" as Any), ("socket", "/tmp/vault.sock" as Any),
                             ("store", "custom" as Any), ("agent", "../studio" as Any)] {
            var bad = base; bad[key] = value
            #expect(throws: VaultFailure.self) { try VaultConfiguration(data: JSONSerialization.data(withJSONObject: bad)) }
        }
    }

    /// The Mac Studio after its macOS update, 4 November 2026: Setup Assistant held the session for hours, and AppKit's
    /// launch, which gives the main thread to AppleScript, waited for it. The worker's socket opens before that launch,
    /// so browser work can come first: it is refused at once, and it does not run when the main thread comes free.
    @Test func browserWorkBeforeTheLaunchEndsIsRefusedAtOnce() async {
        await #expect(throws: VaultFailure.browser) {
            try await VaultBrowser.onMainThread { () -> Bool in
                Issue.record("Browser work ran before the launch ended.")
                return true
            }
        }
    }

    @Test func browserRechecksOriginAndFormTargetBeforeFilling() throws {
        let value = try JSONSerialization.data(withJSONObject: ["username": "test", "password": "quote\"\\\nsecret", "url": "https://example.test/login"])
        let login = try VaultLogin(data: value, label: "Test login")
        let script = try VaultBrowser.fillScript(login)
        #expect(script.contains("location.origin!==\"https:\\/\\/example.test\""))
        #expect(script.contains("new URL(f.action||location.href,location.href).origin!==location.origin"))
        #expect(script.contains("quote\\\"\\\\\\nsecret"))
        #expect(!script.contains("quote\"\\\nsecret"))
        let explicitPort = try VaultLogin(data: JSONSerialization.data(withJSONObject: ["username": "test", "password": "test", "url": "https://Example.test:443/login"]), label: "Test")
        #expect(explicitPort.origin == "https://example.test")
    }

    @Test func authenticatorMatchesRFC6238() throws {
        let seed = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
        #expect(try VaultBrowser.totp(seed: "otpauth://totp/Test?secret=\(seed)&digits=8", at: 59) == "94287082")
        #expect(try VaultBrowser.totp(seed: "otpauth://totp/Test?secret=\(seed)&digits=8", at: 1_111_111_109) == "07081804")
        #expect(try VaultBrowser.totp(seed: seed, at: 59) == "287082")
        for bad in ["!!", "", "otpauth://totp/Test?secret=\(seed)&period=0", "otpauth://hotp/Test?secret=\(seed)",
                    "otpauth://totp/Test?secret=\(seed)&algorithm=MD5", "otpauth://totp/Test?secret=A&secret=B"] {
            #expect(throws: VaultFailure.self) { try VaultBrowser.totp(seed: bad, at: 59) }
        }
    }

    @Test func fingerprintsMatchTheExistingFilterWithoutSendingValues() throws {
        let request = try VaultRequest(data: Data(#"{"v":2,"op":"signin","job":12}"#.utf8))
        let job = try VaultJob(data: JSONSerialization.data(withJSONObject: ["ok": true, "kind": "signin", "job": 12,
            "task": "T-1", "login": "sealed:1", "fingerprint_salts": salts]), request: request)
        let value = "two words\nwith\ttabs"
        let login = try VaultLogin(data: JSONSerialization.data(withJSONObject: ["username": "test", "password": value,
            "url": "https://example.test"]), label: "Test")
        let items = VaultHub.fingerprints(login, job: job)
        #expect(items.isEmpty)
        #expect(login.protectedValues.map(\.value) == [value]) // Existing local reply check still covers spaces.
        let unicode = "e\u{301}👩\u{200d}💻repeated"
        let other = try VaultLogin(data: JSONSerialization.data(withJSONObject: ["username": "test", "password": unicode,
            "url": "https://example.test"]), label: "Test")
        let item = VaultHub.fingerprints(other, job: job)[0]
        #expect(item["len"] as? Int == unicode.unicodeScalars.count)
        #expect(item["len"] as? Int != unicode.count)
        #expect(item["hash"] as? String == "22e607a096c9b19e8e6af79dfc25ffd70aae6e808a905f6819f7ec6973c88780")
        #expect(Set(item.keys) == ["kind", "hash", "len"])
    }

    @Test func shortPasswordsRemainAllowedAndAuthenticatorFormsAreCovered() throws {
        func login(_ password: String, totp: String? = nil) throws -> VaultLogin {
            var value = ["username": "test", "password": password, "url": "https://example.test"]
            value["totp"] = totp
            return try VaultLogin(data: JSONSerialization.data(withJSONObject: value), label: "Test")
        }
        for password in ["v", "true", "1234", "abc123", "1234567", "e\u{301} 👩\u{200d}💻"] {
            #expect(try login(password).protectedValues.isEmpty)
        }
        #expect(try login(String(repeating: "x", count: 2048)).protectedValues.count == 1)
        let seed = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
        let uri = "otpauth://totp/Test?secret=gezdgnbv%20gy3tqojq-gezdgnbvgy3tqojq%3D"
        let values = try login("1234", totp: uri).protectedValues
        #expect(values.map(\.kind) == ["totp", "totp"])
        #expect(values.map(\.value) == [uri, seed])
        #expect(try login("1234", totp: seed).protectedValues.count == 1)
        #expect(try VaultBrowser.totp(seed: uri, at: 59) == "287082")
        #expect(VaultBrowser.canonicalSeed("gezd\u{1c}gnbv\n=") == "GEZDGNBV")
    }

    @Test func protectionReceiptMustCoverTheExactJobAndEveryFingerprint() throws {
        let good: [String: Any] = ["ok": true, "job": 12, "stored": 1, "known": 1]
        try VaultHub.confirmProtection(JSONSerialization.data(withJSONObject: good), job: 12, count: 2)
        for (key, value) in [("ok", false as Any), ("job", 13 as Any), ("stored", 0 as Any),
                             ("known", 3 as Any), ("known", -1 as Any), ("known", true as Any)] {
            var bad = good; bad[key] = value
            #expect(throws: VaultFailure.protection) {
                try VaultHub.confirmProtection(JSONSerialization.data(withJSONObject: bad), job: 12, count: 2)
            }
        }
        #expect(throws: VaultFailure.protection) { try VaultHub.confirmProtection(Data("{}".utf8), job: 12, count: 1) }
    }
}
