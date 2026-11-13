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
    /// "Who can use it" in a replace: the rows show each agent's level of now, a level that the owner does not touch
    /// stays, and a row that he sets to no access takes the key back.
    @Test func aReplaceShowsEachAgentsLevelOfNowAndOnlyARowThatHeSetMakesAStep() {
        let holders = ["dev-lead", "builder", "writer", "tester"]
        // the manager also holds the key: it has no row, and nothing here touches its grant
        let now = ["dev-lead": "read", "builder": "use", "manager": "read"]

        // the Save that shows the line: nothing set by hand, so each row is the agent's level of now
        var shown = SecretReplaceAccess.rows(now: now, holders: holders, set: [:], touched: [])
        #expect(shown.rows == ["dev-lead": .read, "builder": .use] && shown.touched.isEmpty)
        #expect(SecretReplaceAccess.changes(now: now, holders: holders, rows: shown.rows, set: []).isEmpty)

        // A row that he set to a level before that Save stays his. A row that he set to no access before it does not
        // count: each row said "No access" then, also for an agent that had the key, so it was no choice to take the
        // key back. It shows the level of now, and it makes no step.
        shown = SecretReplaceAccess.rows(now: now, holders: holders, set: ["writer": .use], touched: ["writer", "builder", "tester"])
        #expect(shown.rows == ["dev-lead": .read, "builder": .use, "writer": .use])
        #expect(shown.touched == ["writer"])
        var steps = SecretReplaceAccess.changes(now: now, holders: holders, rows: shown.rows, set: shown.touched)
        #expect(steps.map(\.agent) == ["writer"] && steps.map(\.grant) == [.use])
        // A level that he picked before that Save takes no level down either: he picked "Uses it" for an agent whose
        // row said "No access", and the agent reads the key. The row shows "Reads it", and nothing changes for it.
        shown = SecretReplaceAccess.rows(now: now, holders: holders, set: ["dev-lead": .use, "builder": .read], touched: ["dev-lead", "builder"])
        #expect(shown.rows == ["dev-lead": .read, "builder": .read] && shown.touched == ["dev-lead", "builder"])
        steps = SecretReplaceAccess.changes(now: now, holders: holders, rows: shown.rows, set: shown.touched)
        #expect(steps.map(\.agent) == ["builder"] && steps.map(\.grant) == [.read])     // more of it: his pick stands
        // After the rows show the levels, a level that he takes down is his choice.
        steps = SecretReplaceAccess.changes(now: now, holders: holders, rows: ["dev-lead": .use, "builder": .use], set: ["dev-lead"])
        #expect(steps.map(\.agent) == ["dev-lead"] && steps.map(\.grant) == [.use])

        // After the rows show the levels, a row that he sets to no access takes the key back from an agent that has it.
        var rows: [String: SecretGrant] = ["dev-lead": .read, "builder": .use, "writer": .use]
        rows["builder"] = nil
        steps = SecretReplaceAccess.changes(now: now, holders: holders, rows: rows, set: ["writer", "builder"])
        #expect(steps.map(\.agent) == ["builder", "writer"])        // in the order of the agents
        #expect(steps.map(\.grant) == [nil, .use])                  // nil takes the key back

        // each kind of change of a row that he set: a new level, the same level (no step), a first grant, a take-back
        let set: [String: SecretGrant] = ["dev-lead": .use, "builder": .use, "writer": .read]
        let all = SecretReplaceAccess.changes(now: now, holders: holders, rows: set, set: Set(holders))
        #expect(all.map(\.agent) == ["dev-lead", "writer"])
        #expect(all.map(\.grant) == [.use, .read])
        #expect(SecretReplaceAccess.changes(now: now, holders: holders, rows: [:], set: ["tester"]).isEmpty)   // had none, gets none
        #expect(SecretReplaceAccess.changes(now: now, holders: holders, rows: [:], set: ["dev-lead"]).map(\.grant) == [nil])

        // A row that is not set makes no step, also when the level changed somewhere else since the rows were shown:
        // here the rows still show "read" for dev-lead, and the list says "use" now.
        #expect(SecretReplaceAccess.changes(now: ["dev-lead": "use"], holders: holders, rows: ["dev-lead": .read], set: []).isEmpty)

        // a key that no agent holds, and a level that the app does not know, show no access
        #expect(SecretReplaceAccess.rows(now: nil, holders: holders, set: [:], touched: []).rows.isEmpty)
        #expect(SecretReplaceAccess.rows(now: ["builder": "owns"], holders: holders, set: [:], touched: []).rows.isEmpty)
        // the levels of a key that the rows showed before leave a row that he did not set
        #expect(SecretReplaceAccess.rows(now: [:], holders: holders, set: ["dev-lead": .read, "writer": .use], touched: ["writer"]).rows
                == ["writer": .use])
    }

    /// A level that the form raised in a row of his is this key's level, and no pick of his. When the name names
    /// that key no more, his own pick comes back, so that a new key never gets a level that the form put into a row.
    @Test func aRaisedLevelLeavesWithTheKeyThatItCameFrom() {
        let holders = ["dev-lead", "builder", "writer", "tester"]
        let now = ["dev-lead": "read", "builder": "use", "tester": "read"]
        // he picked "Uses it" for dev-lead and for builder, and "Reads it" for writer; the request proposes tester
        let set: [String: SecretGrant] = ["dev-lead": .use, "builder": .use, "writer": .read, "tester": .use, "door": .use]
        let shown = SecretReplaceAccess.rows(now: now, holders: holders, set: set, touched: ["dev-lead", "builder", "writer"],
                                             proposed: ["tester", "door"])
        #expect(shown.rows == ["dev-lead": .read, "builder": .use, "writer": .read, "tester": .read, "door": .use])
        #expect(shown.raised == ["dev-lead": .use])         // only his own row that shows more than he picked
        // The name changes to a key that the list does not have: each row is as he and the request set it.
        var own = SecretReplaceAccess.own(rows: shown.rows, holders: holders, touched: shown.touched, raised: shown.raised,
                                          proposal: ["tester": .use, "door": .use], proposed: ["tester", "door"])
        #expect(own == set)
        // a row that showed only a level of now is empty again, and a row that he set after the levels showed stays
        let after = SecretReplaceAccess.rows(now: now, holders: holders, set: [:], touched: [])
        #expect(after.raised.isEmpty)
        own = SecretReplaceAccess.own(rows: after.rows, holders: holders, touched: [], raised: [:], proposal: [:], proposed: [])
        #expect(own.isEmpty)
        own = SecretReplaceAccess.own(rows: ["dev-lead": .use, "builder": .use, "tester": .read], holders: holders, touched: ["dev-lead"],
                                      raised: [:], proposal: [:], proposed: [])
        #expect(own == ["dev-lead": .use])
        // a pick of his that he took back in the row after the levels showed stays taken back
        own = SecretReplaceAccess.own(rows: ["builder": .use], holders: holders, touched: ["dev-lead"], raised: [:], proposal: [:], proposed: [])
        #expect(own.isEmpty)
        // a raised pick of a row that is no longer his (he set it to no access before the next key) does not come back
        own = SecretReplaceAccess.own(rows: [:], holders: holders, touched: [], raised: ["dev-lead": .use], proposal: [:], proposed: [])
        #expect(own.isEmpty)
        // The Save that acts reads the levels again. A row that the form raised gives the agent at most his own pick:
        // dev-lead read the key when the row was raised to "Reads it", and he picked "Uses it".
        let touched: Set<String> = ["dev-lead", "builder", "writer"]
        func steps(_ now: [String: String]) -> [String] {
            SecretReplaceAccess.changes(now: now, holders: holders, rows: shown.rows, set: touched, proposed: ["tester"], raised: shown.raised)
                .map { "\($0.agent): \($0.grant?.rawValue ?? "none")" }
        }
        #expect(steps(now) == ["writer: read"])                                              // dev-lead keeps "read": no step
        #expect(steps(["dev-lead": "use", "builder": "use", "tester": "read"]) == ["writer: read"])   // it went down elsewhere: his pick
        #expect(steps(["builder": "use", "tester": "read"]) == ["dev-lead: use", "writer: read"])     // it lost the key: his pick, not "read"
        // without the record of his pick, the row's level would go to the agent
        #expect(SecretReplaceAccess.changes(now: ["builder": "use"], holders: holders, rows: shown.rows, set: touched).first?.grant == .read)
        // a proposed row that he set to no access is his "no": the proposal does not come back for it
        own = SecretReplaceAccess.own(rows: [:], holders: holders, touched: [], raised: [:], proposal: ["tester": .use], proposed: [])
        #expect(own.isEmpty)
        // The levels of a second key: computed from his own rows, never from the first key's levels.
        let second = SecretReplaceAccess.rows(now: ["writer": "use"], holders: holders, set: set, touched: ["dev-lead", "builder", "writer"],
                                              proposed: ["tester", "door"])
        #expect(second.rows == ["dev-lead": .use, "builder": .use, "writer": .read, "tester": .use, "door": .use])
        #expect(second.raised.isEmpty)
    }

    /// A request's card proposes who gets the key. In a replace, a proposal gives an agent the key, or more of it, and
    /// never takes a level down: an agent that reads the key keeps reading it when the request says "use".
    @Test func aRequestsProposalNeverTakesALevelDownInAReplace() {
        let holders = ["dev-lead", "builder", "writer"]
        let now = ["dev-lead": "read", "builder": "use"]
        // each agent asks for "use": the one that reads it stays, the one that uses it stays, the one with none gets it
        let asked: [String: SecretGrant] = ["dev-lead": .use, "builder": .use, "writer": .use, "door": .use]
        let proposed: Set<String> = ["dev-lead", "builder", "writer", "door"]
        var shown = SecretReplaceAccess.rows(now: now, holders: holders, set: asked, touched: [], proposed: proposed)
        #expect(shown.rows == ["dev-lead": .read, "builder": .use, "writer": .use, "door": .use])    // the door's row is no agent's
        var steps = SecretReplaceAccess.changes(now: now, holders: holders, rows: shown.rows, set: shown.touched, proposed: proposed)
        #expect(steps.map(\.agent) == ["writer"] && steps.map(\.grant) == [.use])
        // a proposal of more than the agent has is the request's point: it goes up
        shown = SecretReplaceAccess.rows(now: now, holders: holders, set: ["builder": .read], touched: [], proposed: ["builder"])
        steps = SecretReplaceAccess.changes(now: now, holders: holders, rows: shown.rows, set: [], proposed: ["builder"])
        #expect(shown.rows["builder"] == .read && steps.map(\.grant) == [.read])
        // The levels are read again at the Save that replaces. An agent whose level went up somewhere else since the
        // rows were shown keeps it: the proposal's row still says "use", and it takes nothing down.
        steps = SecretReplaceAccess.changes(now: ["builder": "read"], holders: holders, rows: ["builder": .use], set: [], proposed: ["builder"])
        #expect(steps.isEmpty)
        // and a proposal never takes a key back: a proposed row always has a level
        #expect(SecretReplaceAccess.changes(now: now, holders: holders, rows: [:], set: [], proposed: ["dev-lead"]).isEmpty)
        // a row of the proposal that the owner changes himself after the levels are shown is his: also down
        steps = SecretReplaceAccess.changes(now: now, holders: holders, rows: ["dev-lead": .use, "builder": .use], set: ["dev-lead"],
                                            proposed: ["builder"])
        #expect(steps.map(\.agent) == ["dev-lead"] && steps.map(\.grant) == [.use])
        #expect(SecretReplaceAccess.higher(nil, nil) == nil && SecretReplaceAccess.higher(.use, nil) == .use
                && SecretReplaceAccess.higher(nil, .read) == .read && SecretReplaceAccess.higher(.read, .use) == .read
                && SecretReplaceAccess.higher(.use, .use) == .use)
    }

    /// The list takes no second API key of one variable name: Add secret replaces the value of the one that is there,
    /// cannot choose between two from before, and adds a second login as before.
    @Test func aNameThatTheListHasIsAKeyToReplaceOrALoginToAddAgain() {
        let first = "bws://11111111-2222-4333-8444-555555555551", second = "bws://11111111-2222-4333-8444-555555555552"
        let other = "bws://11111111-2222-4333-8444-555555555553", login = "bws://11111111-2222-4333-8444-555555555554"
        let key = TeamLogin(title: "EXAMPLE_API_KEY", protected: true, kind: "api_key", env: "EXAMPLE_API_KEY", grants: ["dev-lead": "read"])
        // a key whose title the owner changed is still known by its variable name
        let renamed = TeamLogin(title: "Example, the old one", protected: true, kind: "api_key", env: "EXAMPLE_API_KEY")
        let another = TeamLogin(title: "OTHER_API_KEY", protected: true, kind: "api_key", env: "OTHER_API_KEY")
        let shop = TeamLogin(title: "shop.example.test · owner", protected: true, kind: "login")
        let one = [first: key, other: another, login: shop]
        #expect(SecretNameHeld.of("EXAMPLE_API_KEY", kind: .apiKey, in: one) == .key(first, key))
        #expect(SecretNameHeld.of("NEW_API_KEY", kind: .apiKey, in: one) == SecretNameHeld.none)
        #expect(SecretNameHeld.of("EXAMPLE_API_KEY", kind: .apiKey, in: [second: renamed]) == .key(second, renamed))
        // two of one name, from before the list refused a second one: the form cannot know which
        #expect(SecretNameHeld.of("EXAMPLE_API_KEY", kind: .apiKey, in: [first: key, second: renamed, other: another]) == .twice)
        // this form's own save that the hub did not confirm is no other secret
        #expect(SecretNameHeld.of("EXAMPLE_API_KEY", kind: .apiKey, in: one, but: first) == SecretNameHeld.none)
        #expect(SecretNameHeld.of("EXAMPLE_API_KEY", kind: .apiKey, in: [first: key, second: renamed], but: first) == .key(second, renamed))
        // a login with the title of a key is no key, and a key with the title of a login is no second key
        #expect(SecretNameHeld.of("shop.example.test · owner", kind: .apiKey, in: one) == SecretNameHeld.none)
        #expect(SecretNameHeld.of("shop.example.test · owner", kind: .login, in: one) == .second)
        #expect(SecretNameHeld.of("EXAMPLE_API_KEY", kind: .login, in: one) == .second)
        #expect(SecretNameHeld.of("shop.example.test · owner", kind: .login, in: one, but: login) == SecretNameHeld.none)
        #expect(SecretNameHeld.of("other.example.test · owner", kind: .login, in: one) == SecretNameHeld.none)
    }

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

    private let reference = "bws://11111111-2222-4333-8444-55555555555b"
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
