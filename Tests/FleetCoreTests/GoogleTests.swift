import Foundation
import Testing
@testable import FleetCore

private let sha = String(repeating: "a", count: 64)
private let requestID = "11111111-2222-4333-8444-555555555555"
private let owner = "owner@example.com", other = "dev.agent@example.com"

private func grant(_ account: String, _ level: String) -> [String: String] { ["account": account, "level": level] }

private func account(_ email: String, connected: Bool = true, scopes: [String] = ["drive", "gmail.modify"],
                     problem: Any = NSNull()) -> [String: Any] {
    ["email": email, "connected": connected, "scopes": connected ? scopes : [], "problem": problem,
     "connected_at": connected ? 1760600000 : NSNull()]
}

/// Dev has Gmail from the other account (Send) and Drive from the owner's (Write); Lead has both from the owner's; Ops
/// has neither. The other account granted Gmail only.
private func snapshot(dev: Any = ["gmail": grant(other, "send"), "drive": grant(owner, "write")],
                      accounts: [[String: Any]] = [account(other, scopes: ["gmail.modify"]), account(owner)],
                      client: Bool = true) throws -> GoogleSnapshot {
    let lines: [[String: Any]] = [
        ["agent": "manager", "role": "manager", "reports_to": NSNull(), "repos": [:], "google": [:]],
        ["agent": "dev", "role": "worker", "reports_to": "manager", "repos": ["acme/web": "write"], "google": dev],
        ["agent": "lead", "role": "lead", "reports_to": "manager", "google": ["drive": grant(owner, "write_shared"), "gmail": grant(owner, "read")]],
        ["agent": "ops", "role": "worker", "reports_to": "lead", "google": [:]]]
    let setup: [String: Any] = ["client": client, "problem": NSNull(), "accounts": accounts,
                                "levels": ["drive": ["read", "write", "write_shared"], "gmail": ["read", "write", "send"]]]
    let object: [String: Any] = ["db": "db", "revision": String(repeating: "b", count: 40), "sha256": sha, "lines": lines,
                                 "open_tasks": [:], "github": ["app": true, "problem": NSNull()], "google": setup]
    return try JSONDecoder().decode(GoogleSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
}

private func sent(_ command: GoogleCommand) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: GoogleClient.body(command, requestID: requestID, database: "db")) as? [String: Any])
}

struct GoogleTests {
    @Test func theTeamGivesEachAgentEachServiceFromItsOwnAccount() throws {
        let team = try snapshot()
        try team.validate(database: "db")
        #expect(team.grant(agent: "dev", .gmail) == GoogleGrant(account: other, level: .send))
        #expect(team.grant(agent: "dev", .drive) == GoogleGrant(account: owner, level: .write))
        #expect(team.grant(agent: "ops", .gmail) == nil && team.grant(agent: "nobody", .drive) == nil)
        #expect(team.access(.drive, account: owner) == ["dev": .write, "lead": .writeShared])
        #expect(team.access(.gmail, account: owner) == ["lead": .read])
        #expect(team.access(.gmail, account: other) == ["dev": .send])
        #expect(team.google?.client == true && team.google?.accounts.map(\.email) == [other, owner])
        #expect(try snapshot(client: false).google?.client == false)
        #expect(throws: HubError.self) { try snapshot().validate(database: "other") }
        // A level of the other service, an unknown service or a grant without an account is not a valid answer.
        #expect(throws: HubError.self) { try snapshot(dev: ["drive": grant(owner, "send")]).validate(database: "db") }
        #expect(throws: HubError.self) { try snapshot(dev: ["gmail": grant(owner, "write_shared")]).validate(database: "db") }
        #expect(throws: HubError.self) { try snapshot(dev: ["calendar": grant(owner, "read")]).validate(database: "db") }
        #expect(throws: HubError.self) { try snapshot(dev: ["drive": grant("", "read")]).validate(database: "db") }
        #expect(throws: (any Error).self) { try snapshot(dev: ["drive": grant(owner, "admin")]) }
        #expect(throws: (any Error).self) { try snapshot(dev: ["drive": "read"]) }        // the shape of contract version 1
    }

    @Test func aHubWithoutGoogleStillDecodes() throws {
        let older = try JSONDecoder().decode(GoogleSnapshot.self, from: JSONSerialization.data(withJSONObject: [
            "db": "db", "sha256": sha, "lines": [["agent": "dev", "role": "worker", "repos": ["acme/web": "read"]]]]))
        try older.validate(database: "db")
        #expect(older.google == nil && older.grant(agent: "dev", .gmail) == nil && older.reason(agent: "dev", .gmail) == nil)
        #expect(older.connect(agent: "dev", .gmail, account: owner) == GoogleChange(agent: "dev", service: .gmail, account: owner, level: .read))
        #expect(!older.unused(owner))
    }

    @Test func anAccountThatTheHubCannotUseForAServiceSaysWhy() throws {
        let team = try snapshot()
        #expect(team.reason(agent: "dev", .gmail) == nil && team.reason(agent: "dev", .drive) == nil)
        #expect(team.reason(agent: "ops", .gmail) == nil)                          // no account: Connect, not Connect again
        // The other account granted Gmail only: it cannot give Drive.
        let scopes = try snapshot(dev: ["drive": grant(other, "read")])
        #expect(scopes.reason(agent: "dev", .drive) == "dev.agent@example.com does not allow Drive. Connect it again.")
        let refused = try snapshot(accounts: [account(other), account(owner, problem: "Google refused the saved access. Connect again.")])
        #expect(refused.reason(agent: "dev", .drive) == "The saved access of owner@example.com stopped working. Connect it again.")
        #expect(refused.reason(agent: "dev", .gmail) == nil)
        let named = try snapshot(accounts: [account(other, connected: false), account(owner)])
        #expect(named.reason(agent: "dev", .gmail) == "dev.agent@example.com is not connected. Connect it again.")
        let missing = try snapshot(accounts: [account(owner)])
        #expect(missing.reason(agent: "dev", .gmail) == "dev.agent@example.com is not connected. Connect it again.")
    }

    @Test func eachServiceHasItsLevelsAndWordsAndNoGoogleLabel() {
        #expect(GoogleService.allCases == [.gmail, .drive])
        #expect(GoogleService.allCases.map(\.title) == ["Gmail", "Drive"])
        #expect(GoogleService.allCases.map(\.scope) == ["gmail.modify", "drive"])
        #expect(GoogleService.drive.levels == [.read, .write, .writeShared])
        #expect(GoogleService.gmail.levels == [.read, .write, .send])
        #expect(GoogleLevel.allCases.map(\.title) == ["Read", "Write", "Write shared", "Send"])
        #expect(GoogleLevel.allCases.map(\.rawValue) == ["read", "write", "write_shared", "send"])
        #expect(GoogleLevel.allCases.filter(\.reachesOthers) == [.writeShared, .send])
        #expect(GoogleService.drive.words(.read) == "Searches and reads the files")
        #expect(GoogleService.drive.words(.write) == "Also makes and changes files that nobody else sees")
        #expect(GoogleService.drive.words(.writeShared) == "Also changes shared files and folders")
        #expect(GoogleService.gmail.words(.read) == "Searches and reads the email")
        #expect(GoogleService.gmail.words(.write) == "Also drafts, labels, archives and trashes")
        #expect(GoogleService.gmail.words(.send) == "Also sends email from this account")
        #expect(GoogleService.drive.words(nil) == "No access" && GoogleService.gmail.words(nil) == "No access")
        #expect(Google.reachesOthers == "Reaches other people, as you, without asking.")
        let texts = GoogleService.allCases.flatMap { service in [service.title] + service.levels.map { service.words($0) } }
            + [GoogleConnectError.wrongState, .timeLimit, .denied("access_denied")].compactMap(\.errorDescription)
            + ["GET /?state=a&code=c HTTP/1.1", "GET /?state=a&error=x HTTP/1.1", "GET /?state=b&code=c HTTP/1.1"].map { GoogleAnswer.to($0, state: "a").page }
        #expect(!texts.contains { $0.localizedCaseInsensitiveContains("google") })
    }

    @Test func connectGivesOneServiceFromTheAccountThatCameBack() throws {
        let team = try snapshot()
        // Ops has no Gmail: it gets Gmail of the owner's account at Read, and its Drive does not change.
        let gmail = try #require(team.connect(agent: "ops", .gmail, account: owner))
        #expect(gmail == GoogleChange(agent: "ops", service: .gmail, account: owner, level: .read))
        #expect(team.access(after: gmail) == ["lead": .read, "ops": .read])
        // Drive is independent: another account, also at Read.
        let drive = try #require(team.connect(agent: "ops", .drive, account: other))
        #expect(team.access(after: drive) == ["ops": .read])
        // Change account: Dev's Gmail moves to the owner's account at its level; the hub replaces the other account.
        let moved = try #require(team.connect(agent: "dev", .gmail, account: owner))
        #expect(moved == GoogleChange(agent: "dev", service: .gmail, account: owner, level: .send))
        #expect(team.access(after: moved) == ["lead": .read, "dev": .send])
        // Connect again of the same account changes nothing.
        #expect(team.connect(agent: "dev", .gmail, account: other) == nil)
    }

    @Test func removeAndALevelChangeOneServiceOnly() throws {
        let team = try snapshot()
        let removed = try #require(team.remove(agent: "dev", .gmail))
        #expect(removed == GoogleChange(agent: "dev", service: .gmail, account: other, level: nil))
        #expect(team.access(after: removed).isEmpty)
        #expect(team.remove(agent: "dev", .drive).map(team.access(after:)) == ["lead": .writeShared])
        #expect(team.remove(agent: "ops", .gmail) == nil)
        #expect(team.change(agent: "dev", .gmail, to: .read) == GoogleChange(agent: "dev", service: .gmail, account: other, level: .read))
        #expect(team.change(agent: "dev", .drive, to: .writeShared).map(team.access(after:)) == ["dev": .writeShared, "lead": .writeShared])
        #expect(team.change(agent: "dev", .gmail, to: .send) == nil)                 // no change
        #expect(team.change(agent: "ops", .drive, to: .read) == nil)                 // no account: it connects first
    }

    @Test func anAccountThatNoAgentUsesIsDisconnected() throws {
        // Dev uses the other account for Gmail: it stays.
        let team = try snapshot()
        #expect(!team.unused(other) && !team.unused(owner))
        // After Remove (or Change account) of Dev's Gmail, no agent uses the other account.
        let after = try snapshot(dev: ["drive": grant(owner, "write")])
        #expect(after.unused(other) && !after.unused(owner))
        // An account that is not connected, or that the hub does not list, has no token to remove.
        #expect(!(try snapshot(dev: [:], accounts: [account(other, connected: false), account(owner)])).unused(other))
        #expect(!after.unused("nobody@example.com"))
    }

    @Test func eachWriteSendsItsFields() throws {
        // Connect names the service, so that the hub asks only for its permission; Connect again also names the account.
        let connect = try sent(.connect(redirectURI: "http://127.0.0.1:50123/", service: .gmail, account: nil))
        #expect(Set(connect.keys) == ["request_id", "db", "redirect_uri", "service"])
        #expect(connect["redirect_uri"] as? String == "http://127.0.0.1:50123/" && connect["service"] as? String == "gmail")
        #expect(connect["request_id"] as? String == requestID)
        let again = try sent(.connect(redirectURI: "http://127.0.0.1:50123/", service: .drive, account: owner))
        #expect(Set(again.keys) == ["request_id", "db", "redirect_uri", "service", "account"])
        #expect(again["service"] as? String == "drive" && again["account"] as? String == owner)
        let finish = try sent(.finish(state: "the-state", code: "4/0Ab-code"))
        #expect(Set(finish.keys) == ["request_id", "db", "state", "code"])
        #expect(finish["state"] as? String == "the-state" && finish["code"] as? String == "4/0Ab-code")
        let disconnect = try sent(.disconnect(account: other))
        #expect(Set(disconnect.keys) == ["request_id", "db", "account"] && disconnect["account"] as? String == other)
        let access = try sent(.access(sha256: sha, account: owner, service: .drive, access: ["dev": .writeShared, "lead": .read]))
        #expect(Set(access.keys) == ["request_id", "db", "base_sha256", "account", "service", "access"])
        #expect(access["account"] as? String == owner && access["service"] as? String == "drive" && access["base_sha256"] as? String == sha)
        #expect(access["access"] as? [String: String] == ["dev": "write_shared", "lead": "read"])
        #expect(try sent(.access(sha256: sha, account: other, service: .gmail, access: [:]))["access"] as? [String: String] == [:])
        #expect(GoogleCommand.connect(redirectURI: "", service: .gmail, account: nil).route == "ui/google/connect")
        #expect(GoogleCommand.finish(state: "", code: "").route == "ui/google/finish")
        #expect(GoogleCommand.disconnect(account: owner).route == "ui/google/disconnect")
        #expect(GoogleCommand.access(sha256: sha, account: owner, service: .drive, access: [:]).route == "ui/team/google")
    }

    @Test func theListenerReadsGooglesAnswer() {
        #expect(GoogleCallback.parse("GET /?state=abc&code=4/0Ab_c-d&scope=x HTTP/1.1") == .code("4/0Ab_c-d", state: "abc"))
        #expect(GoogleCallback.parse("GET /?code=4%2F0Ab%20x&state=a%2Bb HTTP/1.1") == .code("4/0Ab x", state: "a+b"))
        #expect(GoogleCallback.parse("GET /?error=access_denied&state=abc HTTP/1.1") == .error("access_denied", state: "abc"))
        #expect(GoogleCallback.parse("GET /?error=%3Cscript%3Ebad%3C%2Fscript%3E&state=abc HTTP/1.1") == .error("scriptbadscript", state: "abc"))
        #expect(GoogleCallback.parse("GET /?error=%3C%3E&state=abc HTTP/1.1") == .error("unknown", state: "abc"))
        for other in ["GET /favicon.ico HTTP/1.1", "GET /callback?state=abc&code=x HTTP/1.1", "POST /?state=abc&code=x HTTP/1.1",
                      "GET /?code=x HTTP/1.1", "GET /?state=&code=x HTTP/1.1", "GET /?state=abc HTTP/1.1", "GET /?state=abc&code= HTTP/1.1",
                      "GET / HTTP/1.1", "GET /?state=abc&code=x", "", "garbage"] {
            #expect(GoogleCallback.parse(other) == .other, "\(other)")
        }
    }

    @Test func theListenerAnswersAndEndsTheConnect() {
        let done = GoogleAnswer.to("GET /?state=abc&code=the-code HTTP/1.1", state: "abc")
        #expect(done.status == 200 && done.end == .success("the-code"))
        #expect(done.page == "Founderizer is connected. You can close this tab.")
        let wrong = GoogleAnswer.to("GET /?state=other&code=the-code HTTP/1.1", state: "abc")
        #expect(wrong.status == 400 && wrong.end == .failure(.wrongState))
        #expect(GoogleAnswer.to("GET /?state=other&error=access_denied HTTP/1.1", state: "abc").end == .failure(.wrongState))
        let denied = GoogleAnswer.to("GET /?state=abc&error=access_denied HTTP/1.1", state: "abc")
        #expect(denied.end == .failure(.denied("access_denied")) && denied.page.contains("(access_denied)"))
        let stray = GoogleAnswer.to("GET /favicon.ico HTTP/1.1", state: "abc")
        #expect(stray.status == 404 && stray.end == nil)
        let response = String(decoding: done.response, as: UTF8.self)
        #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n") && response.contains("\r\nConnection: close\r\n"))
        #expect(response.contains("Founderizer is connected."))
    }

    @Test func theLoopbackListensOn127001AndEndsWithGooglesAnswer() async throws {
        let loopback = try await GoogleLoopback.open()
        #expect(loopback.port >= 1024 && loopback.redirectURI == "http://127.0.0.1:\(loopback.port)/")
        async let code = loopback.code(state: "abc", limit: .seconds(20))
        let session = URLSession(configuration: .ephemeral)
        let (_, stray) = try await session.data(from: URL(string: "http://127.0.0.1:\(loopback.port)/favicon.ico")!)
        #expect((stray as? HTTPURLResponse)?.statusCode == 404)
        let (page, answer) = try await session.data(from: URL(string: "http://127.0.0.1:\(loopback.port)/?state=abc&code=4%2F0Ab")!)
        #expect((answer as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: page, as: UTF8.self).contains("Founderizer is connected."))
        #expect(try await code == "4/0Ab")
        // The listener stopped: the port takes no new request.
        await #expect(throws: (any Error).self) {
            _ = try await session.data(from: URL(string: "http://127.0.0.1:\(loopback.port)/?state=abc&code=x")!)
        }
    }

    @Test func theLoopbackStopsAtTheTimeLimit() async throws {
        let loopback = try await GoogleLoopback.open()
        await #expect(throws: GoogleConnectError.timeLimit) { try await loopback.code(state: "abc", limit: .milliseconds(50)) }
    }
}
