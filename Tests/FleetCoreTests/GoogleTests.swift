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

/// A stand-in for the hub after the Disconnect of the owner's account: what is left of it (Gmail's agents and standing,
/// then Drive's), and the version of `team.json` that each write moves. The first `conflicts` writes are refused with
/// 409, as when another write came first; the write number `fails` is refused with 502; with `staleOnce`, the reading
/// after the first write is the one from before it, once.
private actor StandIn {
    private(set) var left: [GoogleCleanup] = [.access(.gmail), .standing(.gmail), .access(.drive), .standing(.drive)]
    private(set) var done: [GoogleCleanup] = []
    private(set) var writes = 0
    private var version = 0
    private var conflicts: Int
    private let fails: Int?
    private var staleOnce: Bool
    private var before: (left: [GoogleCleanup], version: Int)?

    init(conflicts: Int = 0, fails: Int? = nil, staleOnce: Bool = false) {
        self.conflicts = conflicts; self.fails = fails; self.staleOnce = staleOnce
    }

    func read() -> ResourceList {
        if staleOnce, let before {
            staleOnce = false
            return Self.list(before.left, before.version)
        }
        return Self.list(left, version)
    }

    func write(_ item: GoogleCleanup, _ sha256: String) throws {
        writes += 1
        if writes == fails { throw HubError.refusal(HubRefusal(status: 502, hubWords: "Google cannot be reached now.")) }
        if conflicts > 0 {
            conflicts -= 1
            version += 1
            throw HubError.refusal(HubRefusal(status: 409, hubWords: "team.json changed: read it again"))
        }
        guard sha256 == Self.sha(version) else {
            throw HubError.refusal(HubRefusal(status: 409, hubWords: "team.json changed: read it again"))
        }
        before = (left, version)
        left.removeAll { $0 == item }
        done.append(item)
        version += 1
    }

    private static func sha(_ version: Int) -> String { String(format: "%064d", version) }

    private static func list(_ left: [GoogleCleanup], _ version: Int) -> ResourceList {
        let resources = GoogleService.allCases.map { service in
            FleetResource(id: "\(service.rawValue):\(owner)", kind: service.rawValue, what: owner, title: owner, needs: "",
                          levels: service.levels.map(\.rawValue), uses: [], credential: "google", connected: false,
                          grant: left.contains(.standing(service)) ? .init(max: "read", to: ResourceList.everyone) : nil,
                          holders: left.contains(.access(service)) ? [.init(agent: "dev", level: "read")] : [])
        }
        return ResourceList(db: "db", revision: nil, sha256: sha(version), audience: ResourceList.everyone, limit: 100,
                            kinds: [], resources: resources)
    }
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
        // owner API 1.255: one folder of the account, by its link or its id, and only then a folder field
        let folder = try sent(.access(sha256: sha, account: owner, service: .drive, access: ["dev": .write],
                                      folder: "https://drive.google.com/drive/folders/Abc-Folder_01"))
        #expect(Set(folder.keys) == ["request_id", "db", "base_sha256", "account", "service", "access", "folder"])
        #expect(folder["folder"] as? String == "https://drive.google.com/drive/folders/Abc-Folder_01")
    }

    /// The one line under the wait for the browser (the owner's "Yes, as drawn" of 15 November 2026): only for
    /// Founderizer's own Google app, and only while Google has not verified it (UI-API.md 1.185).
    @Test func theWaitSaysHowToPassGooglesWarningOnlyWhileFounderizersAppIsNotVerified() throws {
        let url = try #require(URL(string: "https://accounts.google.com/o/oauth2/v2/auth?state=s"))
        #expect(GoogleConnectStart(url: url, state: "s", app: "founderizer", verified: false).hint
                == "If Google says that it has not verified Founderizer, press Advanced, then Go to Founderizer.")
        #expect(GoogleConnectStart(url: url, state: "s", app: "founderizer", verified: true).hint == nil)
        #expect(GoogleConnectStart(url: url, state: "s", app: "own", verified: nil).hint == nil)
        #expect(GoogleConnectStart(url: url, state: "s", app: "founderizer", verified: nil).hint == nil)
        #expect(GoogleConnectStart(url: url, state: "s").hint == nil)          // a hub from before 1.185
        // The Connect sends no client: the hub has Founderizer's (its release brings the ID, founderizer.com the secret).
        let fields = try sent(.connect(redirectURI: "http://127.0.0.1:53111/", service: .gmail, account: nil))
        #expect(fields["client"] == nil)
    }

    /// **The notice before Google's page** (the owner's "Yes, both as drawn" of 16 November 2026; Google's Workspace User
    /// Data and Developer Policy): who asks, for what, where the access stays, what the agents do with it, who else reads
    /// it, and that Founderizer's servers never receive it, for each service in its own words.
    @Test func theNoticeSaysWhoAsksForWhatWhereItStaysAndWhoReadsIt() {
        #expect(GoogleService.gmail.notice == "Google will ask you to give Founderizer access to the email of one account. "
                + "Your hub keeps this access on your server. The agents that you give the account search, read, draft, "
                + "label, archive, trash and send its email, as far as their level allows, and send what they read to the "
                + "AI provider that they run on, and to the people and apps that their tasks reach. Founderizer's servers "
                + "never receive your email.")
        #expect(GoogleService.drive.notice == "Google will ask you to give Founderizer access to the Google Drive of one "
                + "account. Your hub keeps this access on your server. The agents that you give the account search, read, "
                + "make, change, move and trash its files, as far as their level allows, and send what they read to the AI "
                + "provider that they run on, and to the people and apps that their tasks reach. Founderizer's servers "
                + "never receive your files.")
        // What each level of the service lets an agent do is in its notice (`words`): Send sends, Write trashes.
        #expect(GoogleService.gmail.notice.contains("send its email") && GoogleService.gmail.notice.contains("trash"))
        #expect(GoogleService.drive.notice.contains("make, change, move and trash its files"))
        #expect(Google.disconnectWords == "Google ends this account's Gmail and Google Drive access in every fleet that "
                + "connected it. The agents that have it lose it.")
    }

    /// Connect account shows the notice and starts nothing; only its Continue starts a Connect, once; Cancel, another
    /// page and another hub are no yes; and every Connect asks again (Google: the notice must "immediately precede a
    /// request for user consent", and "must not interpret navigation away from the disclosure ... as consent").
    @Test func onlyTheNoticesContinueStartsAConnect() {
        // A consent (`GoogleConsent`) is what `GoogleClient.connect` needs, and only `proceed()` makes one.
        var notice = GoogleConnectNotice()
        var started = notice.proceed() != nil
        #expect(!notice.shows && !started)                           // a Continue with no notice starts nothing
        notice.press(connecting: false)
        #expect(notice.shows)
        notice.dismiss()                                             // Cancel, another page, another hub
        started = notice.proceed() != nil
        #expect(!notice.shows && !started)
        notice.press(connecting: false)
        started = notice.proceed() != nil
        #expect(started && !notice.shows)                            // Continue: one Connect
        started = notice.proceed() != nil
        #expect(!started)                                            // and not a second one
        notice.press(connecting: true)                               // while a Connect is on its way: nothing
        #expect(!notice.shows)
        notice.press(connecting: false)                              // the next Connect asks again
        #expect(notice.shows)
    }

    /// **After a Disconnect, nothing of the account stays** (the owner's "Yes, both as drawn" of 16 November 2026: "The
    /// agents that have it lose it", and the account leaves the list): Google's revoke ends both services, so the agents
    /// and the standing of each go, Gmail first, whichever page the Disconnect was on; another account keeps its own.
    @Test func afterADisconnectTheAgentsAndTheStandingsOfBothServicesGo() throws {
        func item(_ kind: String, _ email: String, holders: [ResourceHolder], grant: FleetResource.Policy?) -> FleetResource {
            FleetResource(id: "\(kind):\(email)", kind: kind, what: email, title: email, needs: "a mail account",
                          levels: kind == "gmail" ? ["read", "write", "send"] : ["read", "write", "write_shared"], uses: [],
                          credential: "google", connected: true, grant: grant, holders: holders)
        }
        let list = ResourceList(db: "db", revision: nil, sha256: sha, audience: ResourceList.everyone, limit: 100, kinds: [],
                                resources: [item("gmail", owner, holders: [.init(agent: "dev", level: "send"), .init(agent: "lead", level: "read")],
                                                 grant: .init(max: "read", to: ResourceList.everyone)),
                                            item("drive", owner, holders: [], grant: .init(max: "write", to: ResourceList.everyone)),
                                            item("gmail", other, holders: [.init(agent: "dev", level: "read")], grant: nil),
                                            item("drive", other, holders: [], grant: nil)])
        #expect(list.cleanup(account: owner) == [.access(.gmail), .standing(.gmail), .standing(.drive)])
        #expect(list.cleanup(account: "Owner@Example.com") == list.cleanup(account: owner))
        #expect(list.cleanup(account: other) == [.access(.gmail)])
        #expect(list.cleanup(account: "nobody@example.com").isEmpty)    // nothing left: the account leaves the list
    }

    /// **A folder of a Drive account** (owner API 1.255, the owner's "Yes, as drawn" of 20 November 2026): it decodes
    /// with its holders, its key keeps the case of Drive's id (the hub's resource ids are lower case), a folder holder
    /// reaches the account's row, the card offers only levels that add something to an agent's whole Drive (and no
    /// Write on a shared folder, where it gives nothing), and a Disconnect takes each folder away too. A hub from
    /// before 1.255 gives no folders. Bugs it catches: a folder card that offers a level the hub drops, a lower-cased
    /// folder id, an agent with folders only that has no row, a Disconnect that leaves folder grants behind.
    @Test func aFolderOfADriveAccountGivesOnlyTheLevelsThatAddSomething() throws {
        let json = """
        {"id": "drive:\(owner)", "kind": "drive", "what": "\(owner)", "title": "\(owner)", "needs": "files",
         "levels": ["read", "write", "write_shared"], "uses": [], "credential": "google", "connected": true,
         "grant": null, "holders": [{"agent": "dev", "level": "read"}], "history": [],
         "folders": [{"id": "Abc-Folder_01", "link": "https://drive.google.com/drive/folders/Abc-Folder_01",
                      "name": "Support replies", "shared": false, "gone": false,
                      "holders": [{"agent": "lead", "level": "write"}], "history": []}]}
        """
        let drive = try JSONDecoder().decode(FleetResource.self, from: Data(json.utf8))
        let folder = try #require(drive.folders?.first)
        #expect(folder.title == "Support replies" && folder.holders == [.init(agent: "lead", level: "write")])
        let key = drive.folderKey(folder.id)
        let parts = try #require(FleetResource.folderParts(key))
        #expect(parts.resource == "drive:\(owner)" && parts.folder == "Abc-Folder_01")
        #expect(FleetResource.folderParts("drive:\(owner)") == nil && FleetResource.folderParts("repo:a/b#x") == nil)
        #expect(drive.reaches("lead") && drive.reaches("dev") && !drive.reaches("ops"))
        #expect(drive.folderLevels(for: "dev", shared: false) == [.write, .writeShared])
        #expect(drive.folderLevels(for: "dev", shared: true) == [.writeShared])
        #expect(drive.folderLevels(for: "lead", shared: false) == [.read, .write, .writeShared])
        #expect(drive.folderLevels(for: "lead", shared: true) == [.read, .writeShared])
        #expect(folder.access(giving: "dev", level: .write) == ["lead": .write, "dev": .write])
        #expect(folder.access(giving: "lead", level: nil) == [:])
        let older = try JSONDecoder().decode(FleetResource.self, from: Data(json.replacingOccurrences(
            of: #""folders": [{"#, with: #""_folders": [{"#).utf8))
        #expect(older.folders == nil)
        let list = ResourceList(db: "db", revision: nil, sha256: sha, audience: ResourceList.everyone, limit: 100, kinds: [],
                                resources: [drive])
        #expect(list.cleanup(account: owner) == [.access(.drive), .folder("Abc-Folder_01")])
    }

    /// **A Disconnect takes every folder away, and a 409 that is no newer version stops it** (the reviews of 20 November
    /// 2026). Bugs it catches: an account with more folders than the rounds of the writes is left half cleared; a 409
    /// of a folder that the hub cannot read is taken as a newer team.json and tried again until the rounds run out, so
    /// the standing and Gmail are never cleared; `DriveFolder.id(in:)`, which Add folder uses to find a folder that agents
    /// hold, reads an id that the hub would read otherwise.
    @Test func theCleanUpTakesEveryFolderAndStopsAtA409ThatIsNoNewerVersion() async throws {
        actor Folders {
            var left: [String] = (1...10).map { "Folder-\($0)-000000" }
            var writes = 0
            let refuse: String?
            init(refuse: String? = nil) { self.refuse = refuse }
            func list() -> ResourceList {
                let folders = left.map { DriveFolder(id: $0, link: "https://drive.google.com/drive/folders/\($0)", name: nil,
                                                     shared: false, holders: [.init(agent: "dev", level: "read")]) }
                let drive = FleetResource(id: "drive:\(owner)", kind: "drive", what: owner, title: owner, needs: "files",
                                          levels: ["read", "write", "write_shared"], uses: [], credential: "google",
                                          connected: false, grant: nil, holders: [], folders: folders)
                return ResourceList(db: "db", revision: nil, sha256: sha, audience: ResourceList.everyone, limit: 100,
                                    kinds: [], resources: [drive])
            }
            func write(_ item: GoogleCleanup) throws {
                writes += 1
                if let refuse { throw HubError.refusal(HubRefusal(status: 409, hubWords: "x", code: refuse)) }
                if case .folder(let id) = item { left.removeAll { $0 == id } }
            }
        }
        let all = Folders()
        try await GoogleDisconnect.clear(account: owner, read: { await all.list() }, write: { item, _ in try await all.write(item) })
        let (left, writes) = await (all.left, all.writes)
        #expect(left.isEmpty && writes == 10)
        let stuck = Folders(refuse: "drive_folder_account")
        await #expect(throws: HubError.self) {
            try await GoogleDisconnect.clear(account: owner, read: { await stuck.list() }, write: { item, _ in try await stuck.write(item) })
        }
        #expect(await stuck.writes == 1)
        #expect(DriveFolder.id(in: " https://drive.google.com/drive/folders/Abc-Folder_01?usp=sharing ") == "Abc-Folder_01")
        #expect(DriveFolder.id(in: "Abc-Folder_01") == "Abc-Folder_01")
        #expect(DriveFolder.id(in: "https://drive.google.com/drive/u/0/folders/Abc-Folder_01") == "Abc-Folder_01")
        #expect(DriveFolder.id(in: "https://drive.google.com/drive/drives/0AbcSharedDrive") == "0AbcSharedDrive")
        #expect(DriveFolder.id(in: "https://drive.google.com/open?id=Abc-Folder_01") == "Abc-Folder_01")
        #expect(DriveFolder.id(in: "https://example.com/x") == nil && DriveFolder.id(in: "root") == nil)
    }

    /// The clean-up after a Disconnect writes against each new reading, Gmail first, and ends with nothing left also
    /// when other writes come first (409) four times: four writes and a last reading need more than the rounds of the
    /// writes (the review of 16 November 2026).
    @Test func theCleanUpTakesEverythingAwayThroughRefusalsOfANewerVersion() async throws {
        let hub = StandIn(conflicts: 4)
        try await GoogleDisconnect.clear(account: owner, read: { await hub.read() }, write: { try await hub.write($0, $1) })
        let (left, writes, done) = await (hub.left, hub.writes, hub.done)
        #expect(left.isEmpty && writes == 8)
        #expect(done == [.access(.gmail), .standing(.gmail), .access(.drive), .standing(.drive)])
        // A reading from before the last write (more left, an old version): its write gets 409, and the next reading
        // goes on from what is there.
        let late = StandIn(staleOnce: true)
        try await GoogleDisconnect.clear(account: "Owner@Example.com", read: { await late.read() },
                                         write: { try await late.write($0, $1) })
        let (lateLeft, lateWrites) = await (late.left, late.writes)
        #expect(lateLeft.isEmpty && lateWrites == 5)
    }

    /// Any refusal that is not a newer version stops the clean-up at once, and more refusals than rounds end it with the
    /// last one; what is left stays for the next Disconnect.
    @Test func theCleanUpStopsAtARefusalAndAfterItsRounds() async {
        let refused = StandIn(fails: 2)
        do {
            try await GoogleDisconnect.clear(account: owner, read: { await refused.read() }, write: { try await refused.write($0, $1) })
            Issue.record("the clean-up went on after a refusal")
        } catch HubError.refusal(let refusal) {
            #expect(refusal.status == 502)
        } catch { Issue.record("\(error)") }
        let (refusedWrites, refusedLeft) = await (refused.writes, refused.left)
        #expect(refusedWrites == 2 && refusedLeft == [.standing(.gmail), .access(.drive), .standing(.drive)])
        let busy = StandIn(conflicts: 100)
        do {
            try await GoogleDisconnect.clear(account: owner, read: { await busy.read() }, write: { try await busy.write($0, $1) })
            Issue.record("the clean-up ended well with everything left")
        } catch HubError.refusal(let refusal) {
            #expect(refusal.status == 409)
        } catch { Issue.record("\(error)") }
        let (busyWrites, busyLeft) = await (busy.writes, busy.left)
        #expect(busyWrites == GoogleDisconnect.rounds && busyLeft.count == 4)
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
