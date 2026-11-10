import Foundation
import Testing
@testable import FleetCore

/// Synthetic values only. No test names a real login.
private func login(_ change: (inout LoginSecret) -> Void = { _ in }) -> LoginSecret {
    var value = LoginSecret()
    value.username = " owner@example.test "; value.password = " synthetic pass phrase "
    value.url = " https://shop.example.test/login "
    change(&value)
    return value
}

struct SecretTests {
    @Test func aLoginBecomesTheItemValueThatTheVaultsRead() throws {
        let line = try login { $0.totp = " JBSW Y3DP EHPK 3PXP " }.value()
        let item = try #require(try JSONSerialization.jsonObject(with: line) as? [String: String])
        #expect(item == ["username": "owner@example.test", "password": " synthetic pass phrase ", "url": "https://shop.example.test/login",
                         "totp": "JBSW Y3DP EHPK 3PXP"])                          // the password exactly as typed; no name inside
        let noSeed = try #require(try JSONSerialization.jsonObject(with: login().value()) as? [String: String])
        #expect(noSeed["totp"] == nil)
        #expect(login { $0.totp = "otpauth://totp/Shop:owner?secret=JBSWY3DPEHPK3PXP&issuer=Shop" }.problem == nil)
        #expect(login { $0.totp = "jbsw-y3dp" }.problem == nil)                  // the vaults give a seed no length rule
        #expect(login().title == "shop.example.test · owner@example.test" && login().variable == nil)    // no name to type
        let long = login { $0.username = String(repeating: "u", count: 80) }.title
        #expect(long.unicodeScalars.count == LoginSecret.maxLabel && long.hasSuffix("…"))    // the catalog's title limit
    }

    /// An API key: its variable name is its name, and the vault item is a login with an empty user name.
    @Test func anAPIKeyIsALoginWithAnEmptyUserNameAndItsVariableIsItsName() throws {
        func key(_ change: (inout LoginSecret) -> Void = { _ in }) -> LoginSecret {
            var value = LoginSecret()
            value.kind = .apiKey; value.env = " openai_api_key "; value.password = "sk-synthetic-CANARY-9d2f"
            change(&value)
            return value
        }
        #expect(key().problem == nil && key().title == "OPENAI_API_KEY" && key().variable == "OPENAI_API_KEY")
        #expect(try JSONSerialization.jsonObject(with: key().value()) as? [String: String] == ["username": "", "password": "sk-synthetic-CANARY-9d2f"])
        let served = try #require(try JSONSerialization.jsonObject(with: key { $0.url = " https://api.example.test " }.value()) as? [String: String])
        #expect(served == ["username": "", "password": "sk-synthetic-CANARY-9d2f", "url": "https://api.example.test"])
        let ignored = try #require(try JSONSerialization.jsonObject(with: key { $0.username = "x"; $0.totp = "JBSWY3DPEHPK3PXP" }.value()) as? [String: String])
        #expect(ignored["username"] == "" && ignored["totp"] == nil)                // a key has no user name and no seed
        let changes: [(inout LoginSecret) -> Void] = [
            { $0.env = "" }, { $0.env = "1KEY" }, { $0.env = "MY-KEY" }, { $0.env = String(repeating: "K", count: 61) },
            { $0.env = "FLEET_SESSION_TOKEN" }, { $0.env = "PATH" }, { $0.env = "anthropic_api_key" }, { $0.env = "CODEX_HOME" },
            { $0.password = "" }, { $0.url = "ftp://api.example.test" }, { $0.url = "api.example.test" }]
        for change in changes {
            let value = key(change)
            #expect(value.problem != nil)
            #expect(value.problem?.contains("sk-synthetic-CANARY-9d2f") != true)
            #expect(throws: (any Error).self) { try value.value() }
        }
        #expect(LoginSecret.isVariable("GH_TOKEN") && !LoginSecret.isReserved("GH_TOKEN") && LoginSecret.isReserved("BWS_ACCESS_TOKEN"))
    }

    @Test func aPasswordHasNoLengthRuleAndNoCharacterRule() throws {
        for password in ["x", " ", "line one\nline two\rend\0", String(repeating: "é", count: 4000)] {
            let value = login { $0.password = password }
            #expect(value.problem == nil)
            let item = try #require(try JSONSerialization.jsonObject(with: value.value()) as? [String: String])
            #expect(item["password"] == password)
        }
    }

    /// A value too long to seal into a copy the hub carries is refused in the form, with the length and no value.
    /// Before this it passed, was sealed, and the hub refused the whole delivery after the form had cleared it.
    @Test func aValueTooLongToSealIsRefusedInTheFormAndSaysHowLong() throws {
        let over = { (count: Int) in login { $0.kind = .apiKey; $0.env = "LONG_KEY"; $0.url = ""
                                             $0.password = String(repeating: "k", count: count) } }
        let around = try over(1).value().count - 1                                 // what the JSON around it takes
        let room = LoginSecret.maxValueBytes - around
        #expect(over(room).problem == nil)
        #expect(try over(room).value().count == LoginSecret.maxValueBytes)
        let problem = try #require(over(room + 1).problem)
        #expect(problem.contains("\(LoginSecret.maxValueBytes)"))
        #expect(!problem.contains("kkkk"))
        #expect(throws: (any Error).self) { try over(room + 1).value() }
    }

    @Test func aLoginThatTheVaultsCannotReadIsRefusedWithoutItsValue() {
        let password = "synthetic-CANARY-9d2f"
        let changes: [(inout LoginSecret) -> Void] = [
            { $0.username = "" }, { $0.password = "" },
            { $0.url = "ftp://shop.example.test" }, { $0.url = "https://owner:pw@shop.example.test" }, { $0.url = "https:///path" },
            { $0.url = "shop.example.test" }, { $0.url = "HTTPS://shop.example.test" },      // the Mac vault reads the scheme in lower case
            { $0.totp = "not a seed!" }, { $0.totp = "otpauth://totp/Shop?issuer=Shop" },
            { $0.username = String(repeating: "u", count: LoginSecret.maxValueBytes) }]      // longer than a copy can be
        for change in changes {
            var value = login { $0.password = password }
            change(&value)
            let problem = value.problem
            #expect(problem != nil)
            #expect(problem?.contains(password) != true)
            #expect(throws: (any Error).self) { try value.value() }
        }
        #expect(login { $0.password = password }.problem == nil)
        #expect(!((LoginSecret() as Any) is any Encodable))                             // no general encoder can save a value
    }

    private let reference = "bws://18eaf23b-f5d2-4623-a4fb-b4de012c53fb"
    private let hex = String(repeating: "a", count: 64)

    @Test func theHubStepsOfANewLoginCarryNoValue() throws {
        let id = UUID(), prints = [SecretFingerprint(kind: "password", hash: hex, len: 21), SecretFingerprint(kind: "totp", hash: hex, len: 32)]
        let sent = try SecretCommand.fingerprints(requestID: id, database: "db", login: reference, items: prints)
        let body = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        #expect(Set(body.keys) == ["request_id", "db", "login", "fingerprints"] && body["request_id"] as? String == id.uuidString.lowercased())
        #expect((body["fingerprints"] as? [[String: Any]])?.map { Set($0.keys) } == [["kind", "hash", "len"], ["kind", "hash", "len"]])
        let password = prints[0], seed = prints[1]
        for bad in [[], [password, password], [seed, seed, seed], [password, seed, seed, seed],
                    [SecretFingerprint(kind: "password", hash: hex, len: 7)], [SecretFingerprint(kind: "password", hash: hex.uppercased(), len: 21)],
                    [SecretFingerprint(kind: "url", hash: hex, len: 21)]] {
            #expect(!SecretFingerprint.areValid(bad))
            #expect(throws: HubError.self) { try SecretCommand.fingerprints(requestID: id, database: "db", login: reference, items: bad) }
        }
        #expect(throws: HubError.self) { try SecretCommand.fingerprints(requestID: id, database: "db", login: reference.uppercased(), items: prints) }
        let named = try SecretCommand.title(requestID: id, database: "db", sha256: hex, login: reference, title: " Shop admin ")
        let title = try #require(try JSONSerialization.jsonObject(with: named) as? [String: String])
        #expect(title == ["request_id": id.uuidString.lowercased(), "db": "db", "base_sha256": hex, "login": reference, "title": "Shop admin"])
        for (sha, login, text) in [(hex, reference, String(repeating: "n", count: 61)), (hex, reference, "two\nlines"), (hex, reference, "  "),
                                   ("short", reference, "Shop admin"), (hex, "bws://not-a-reference", "Shop admin")] {
            #expect(throws: HubError.self) { try SecretCommand.title(requestID: id, database: "db", sha256: sha, login: login, title: text) }
        }
        // Remove: the reference leaves the catalog on the team.json that the page read; no title and no value.
        let removed = try #require(try JSONSerialization.jsonObject(with: SecretCommand.removal(
            requestID: id, database: "db", sha256: hex, login: reference)) as? [String: Any])
        #expect(Set(removed.keys) == ["request_id", "db", "base_sha256", "login", "delete"] && removed["delete"] as? Bool == true)
        #expect(removed["login"] as? String == reference && removed["base_sha256"] as? String == hex)
        for (sha, login) in [("short", reference), (hex, reference.uppercased()), (hex, "bws://not-a-reference")] {
            #expect(throws: HubError.self) { try SecretCommand.removal(requestID: id, database: "db", sha256: sha, login: login) }
        }
        // Add secret's one hub step: the fingerprints and the catalog entry, without a value or a salt.
        let added = try SecretCommand.add(requestID: id, database: "db", login: reference, title: "OPENAI_API_KEY", kind: .apiKey,
                                          variable: "OPENAI_API_KEY", fingerprints: [password])
        let entry = try #require(try JSONSerialization.jsonObject(with: added) as? [String: Any])
        #expect(Set(entry.keys) == ["request_id", "db", "login", "title", "kind", "env", "fingerprints"] && entry["kind"] as? String == "api_key")
        let plain = try #require(try JSONSerialization.jsonObject(with: SecretCommand.add(
            requestID: id, database: "db", login: reference, title: "shop.example.test · owner", kind: .login, variable: nil, fingerprints: [])) as? [String: Any])
        #expect(plain["env"] == nil && (plain["fingerprints"] as? [Any])?.isEmpty == true)
        for (kind, variable, title) in [(LoginSecret.Kind.login, "OPENAI_API_KEY", "x"), (.apiKey, nil, "x"), (.apiKey, "PATH", "PATH"),
                                        (.login, nil, ""), (.login, nil, String(repeating: "n", count: 61))] as [(LoginSecret.Kind, String?, String)] {
            #expect(throws: HubError.self) {
                try SecretCommand.add(requestID: id, database: "db", login: reference, title: title, kind: kind, variable: variable, fingerprints: [])
            }
        }
        // One click: one agent's grant of one secret, or its end.
        let granted = try #require(try JSONSerialization.jsonObject(with: SecretCommand.grant(
            requestID: id, database: "db", login: reference, agent: "studio", grant: .read)) as? [String: Any])
        #expect(granted["grant"] as? String == "read" && granted["agent"] as? String == "studio" && granted["login"] as? String == reference)
        let ended = try #require(try JSONSerialization.jsonObject(with: SecretCommand.grant(
            requestID: id, database: "db", login: reference, agent: "studio", grant: nil)) as? [String: Any])
        #expect(ended["grant"] is NSNull)
        #expect(throws: HubError.self) { try SecretCommand.grant(requestID: id, database: "db", login: reference, agent: "Studio", grant: .use) }
    }

    @Test func saltsReceiptsAndTheCatalogAreChecked() throws {
        func salts(_ fields: [String: String]) throws -> SecretSalts { try JSONDecoder().decode(SecretSalts.self, from: JSONSerialization.data(withJSONObject: fields)) }
        let good = try salts(["login": reference, "password": String(repeating: "1", count: 32), "totp": String(repeating: "2", count: 32)])
        #expect(good.isValid)
        #expect(try JSONSerialization.jsonObject(with: good.data()) as? [String: String] == ["password": good.password, "totp": good.totp])
        #expect(try !salts(["login": reference, "password": "short", "totp": good.totp]).isValid)
        #expect(try !salts(["login": reference.uppercased(), "password": good.password, "totp": good.totp]).isValid)
        let id = UUID()
        let receipt = try JSONDecoder().decode(SecretReceipt.self, from: JSONSerialization.data(withJSONObject: [
            "ok": true, "request_id": id.uuidString.lowercased(), "client": "fleet", "replayed": false, "login": reference, "stored": 1, "known": 1]))
        #expect(receipt.matches(requestID: id, client: "fleet", login: reference) && receipt.stored == 1 && receipt.known == 1)
        #expect(!receipt.matches(requestID: UUID(), client: "fleet", login: reference) && !receipt.matches(requestID: id, client: "other", login: reference))
        func team(_ logins: Any?) throws -> TeamSnapshot {
            var object: [String: Any] = ["db": "db", "revision": String(repeating: "b", count: 40), "sha256": hex, "open_tasks": [String: Int](),
                                         "lines": [["agent": "manager", "role": "manager", "reports_to": NSNull()]]]
            object["logins"] = logins
            return try JSONDecoder().decode(TeamSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        }
        #expect(try team([reference: ["title": "Shop admin", "protected": true]]).logins == [reference: TeamLogin(title: "Shop admin", protected: true)])
        let key = try #require(try team([reference: ["title": "OPENAI_API_KEY", "kind": "api_key", "env": "OPENAI_API_KEY", "protected": true,
                                                     "grants": ["studio": "read", "vps": "use"]]]).logins?[reference])
        #expect(key.isAPIKey && key.name == "OPENAI_API_KEY" && key.grants == ["studio": "read", "vps": "use"])
        #expect(try #require(try team([reference: ["title": "shop.example.test · owner", "kind": "login"]]).logins?[reference]).name == "shop.example.test · owner")
        let grant = try JSONDecoder().decode(SecretGrantReceipt.self, from: JSONSerialization.data(withJSONObject: [
            "ok": true, "request_id": id.uuidString.lowercased(), "client": "fleet", "replayed": false, "login": reference, "agent": "beta",
            "grant": "use", "changed": true, "revision": String(repeating: "c", count: 40), "sha256": hex, "updates_requested": ["beta"],
            "vault": ["before": "none", "after": "none", "missing": ["no_vault_store"]]]))
        #expect(grant.vault == SecretGrantReceipt.Access(before: "none", after: "none", missing: ["no_vault_store"]) && grant.grant == "use")
        #expect(try team([String: Any]()).logins == [:])
        #expect(try team(nil).logins == nil)                                             // a hub without the feature
        let odd = try team(["not": "a catalog"])                                         // a bad catalog does not hide the team
        #expect(odd.logins == nil && odd.lines.count == 1)
    }
}
