import Foundation
import Testing
@testable import FleetCore

private let sha = String(repeating: "a", count: 64)

private func snapshot(db: String = "db", repos: [String: Any] = ["acme/web": "write", "acme/lib": "read"],
                      github: Any = ["app": true, "problem": NSNull()]) throws -> IntegrationsSnapshot {
    let lines: [[String: Any]] = [
        ["agent": "manager", "role": "manager", "reports_to": NSNull(), "repos": [:], "tools": []],
        ["agent": "dev", "role": "worker", "reports_to": "manager", "repos": repos, "tools": ["github"], "model": NSNull()],
        ["agent": "lead", "role": "lead", "reports_to": "manager", "repos": ["acme/web": "read"], "tools": []],
        ["agent": "ops", "role": "worker", "reports_to": "lead"]]
    let object: [String: Any] = ["db": db, "revision": String(repeating: "b", count: 40), "sha256": sha, "lines": lines,
                                 "open_tasks": [:], "github": github,
                                 "tools": ["github": ["title": "GitHub", "command": "github-mcp-server", "args": ["stdio"],
                                                      "runtimes": ["claude", "codex"]]]]
    return try JSONDecoder().decode(IntegrationsSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
}

/// The owner's own GitHub App, as the form takes it before anything travels (`POST /ui/github-app`). The hub
/// checks all of this again and is the one that proves the key can sign; this is what a person should not have to
/// be told twice — and what keeps a key that is not a key from leaving this Mac at all.
struct GitHubAppFormTests {
    private let key = "-----BEGIN RSA PRIVATE KEY-----\n" + String(repeating: "MIIEpAIBAAKCAQEA1234567890abcd\n", count: 6)
        + "-----END RSA PRIVATE KEY-----"

    @Test func theAppIdIsTheNumberGitHubShows() {
        #expect(GitHubAppForm.appID("123456") == "123456")
        #expect(GitHubAppForm.appID("  123456 \n") == "123456")
        #expect(GitHubAppForm.appID("App 123456") == nil)
        #expect(GitHubAppForm.appID("") == nil)
        #expect(GitHubAppForm.appID(String(repeating: "9", count: 13)) == nil)
    }

    @Test func onlyOnePrivateKeyBlockGoesToTheHub() {
        #expect(GitHubAppForm.isPrivateKey(key))
        #expect(GitHubAppForm.isPrivateKey(key.replacingOccurrences(of: "RSA PRIVATE KEY", with: "PRIVATE KEY")))
        // What a person pastes by mistake: a public key, half a file, two blocks, or a key with a note after it.
        #expect(GitHubAppForm.isPrivateKey("ssh-rsa AAAAB3Nza" + String(repeating: "x", count: 200)) == false)
        #expect(GitHubAppForm.isPrivateKey(key.replacingOccurrences(of: "-----END RSA PRIVATE KEY-----", with: "")) == false)
        #expect(GitHubAppForm.isPrivateKey(key + "\n" + key) == false)
        #expect(GitHubAppForm.isPrivateKey(key + "\nthe App ID is 123456") == false)
        #expect(GitHubAppForm.isPrivateKey("-----BEGIN RSA PRIVATE KEY-----\n-----END RSA PRIVATE KEY-----") == false)
    }

    @Test func theProblemIsSaidInTheOwnersOwnWords() {
        #expect(GitHubAppForm.problem(appID: "123456", key: key) == nil)
        #expect(GitHubAppForm.problem(appID: "x", key: key)?.contains("number at the top") == true)
        #expect(GitHubAppForm.problem(appID: "123456", key: "not a key")?.contains(".pem file") == true)
    }

    /// The row answers with a mark, and it has three answers where the page had two. The owner, 20 October 2026:
    /// "not even sentences, just a check or a cross, and on hover probably show the detail?"
    @Test func theRowHasThreeAnswersAndNotTwo() {
        typealias App = IntegrationsSnapshot.GitHubApp
        #expect(App.mark(App(app: true, app_id: "123456")).state == .good)
        #expect(App.mark(App(app: false)).state == .bad)
        // A file the hub cannot use is not the same thing as no file, and the page said this one only in its
        // footer, under a row that was showing a seal.
        let broken = App.mark(App(app: false, app_id: "123456", problem: "The App file is not readable."))
        #expect(broken.state == .bad && broken.words != App.mark(App(app: false)).words)
        // A hub not read yet is never drawn as a pass.
        #expect(App.mark(nil).state == .working)
    }

    /// Whether the card asks for an App is the card's own answer, from these same three states. It used to be a
    /// condition on the page above it, which took the whole card out of the view the moment a save succeeded —
    /// and with it the one line that tells him to delete the `.pem` file he had just downloaded.
    @Test func theCardAsksForAnAppOnlyWhileTheHubNeedsOneAndHasBeenRead() {
        typealias App = IntegrationsSnapshot.GitHubApp
        #expect(App.asksForOne(App(app: false)))
        #expect(App.asksForOne(App(app: false, problem: "The App file is not readable.")))
        #expect(!App.asksForOne(App(app: true, app_id: "123456")))
        // plan 13, item 4: while the item for the App's new key is open, the card takes the new key of the App
        #expect(App.asksForOne(App(app: true, app_id: "123456", renew: true)))
        #expect(!App.asksForOne(App(app: true, app_id: "123456", renew: false)))
        // A hub not read yet asks for nothing, so no credential form appears and is taken away again.
        #expect(!App.asksForOne(nil))
        // A save takes the place of a file that is there, usable or not.
        #expect(App.holdsFile(App(app: true, app_id: "123456")))
        #expect(App.holdsFile(App(app: false, problem: "The App file is not readable.")))
        #expect(!App.holdsFile(App(app: false)) && !App.holdsFile(nil))
    }

    @Test func theReceiptCarriesNoKey() throws {
        let receipt = try JSONDecoder().decode(GitHubAppReceipt.self, from: Data("""
        {"ok": true, "request_id": "r", "client": "c", "replayed": false, "app": true, "app_id": "123456",
         "replaced": true}
        """.utf8))
        #expect(receipt.app == true && receipt.app_id == "123456" && receipt.replaced == true)
        // There is no field for a key, so no screen of this app can show one back.
        #expect(Mirror(reflecting: receipt).children.allSatisfy { $0.label != "key" })
    }
}

struct IntegrationsTests {
    @Test func theTeamGivesEachRepositoryItsAgentsAndEachToolItsAgents() throws {
        let team = try snapshot()
        try team.validate(database: "db")
        #expect(team.repositories == ["acme/lib", "acme/web"])
        #expect(team.access("acme/web") == ["dev": .write, "lead": .read])
        #expect(team.access("acme/lib") == ["dev": .read])
        #expect(team.access("other/x").isEmpty)
        #expect(team.agents.map(\.agent) == ["dev", "lead", "ops"])         // the manager has no task sessions
        #expect(team.agents(of: "github") == ["dev"])
        #expect(team.tools?["github"]?.detail == "github-mcp-server stdio")
        #expect(team.github == .init(app: true, problem: nil))
        #expect(throws: HubError.self) { try snapshot().validate(database: "other") }
        #expect(throws: HubError.self) { try snapshot(repos: ["Acme/Web": "write"]).validate(database: "db") }
        #expect(throws: (any Error).self) { try snapshot(repos: ["acme/web": "admin"]) }
        // A hub before the feature: no catalog, no App state and no repos.
        let older = try JSONDecoder().decode(IntegrationsSnapshot.self, from: JSONSerialization.data(withJSONObject: [
            "db": "db", "sha256": sha, "lines": [["agent": "dev", "role": "worker"]]]))
        #expect(older.tools == nil && older.github == nil && older.repositories.isEmpty)
    }

    @Test func aRepositoryIsOwnerAndNameInLowerCase() {
        #expect(Integrations.repository(" Acme/Web ") == "acme/web")
        #expect(Integrations.repository("https://github.com/Acme/web.git") == "acme/web")
        #expect(Integrations.repository("github.com/acme/web/") == "acme/web")
        #expect(Integrations.repository("acme/.github") == "acme/.github")
        for bad in ["acme", "acme/", "/web", "acme/web/x", "-acme/web", "acme/..", "acme/.", "acme/w b",
                    String(repeating: "a", count: 40) + "/web", "acme/" + String(repeating: "w", count: 101)] {
            #expect(Integrations.repository(bad) == nil, "\(bad)")
        }
    }

    /// A repository runs read, write, deploy, from the lowest to the highest, and the app reads and writes the third
    /// one as it does the other two. Deploy is write and the repository's own deployment: its workflow files and its
    /// GitHub Actions runs.
    @Test func aRepositoryHasThreeLevelsAndDeployIsTheHighest() throws {
        #expect(RepositoryAccess.allCases == [.read, .write, .deploy])
        #expect(RepositoryAccess(rawValue: "deploy") == .deploy && RepositoryAccess.deploy.title == "Deploy")
        #expect(RepositoryAccess(rawValue: "admin") == nil)
        let reading = try snapshot(repos: ["acme/web": "deploy", "acme/lib": "read"])
        #expect(reading.lines.first { $0.agent == "dev" }?.repos == ["acme/web": .deploy, "acme/lib": .read])
        #expect(reading.access("acme/web") == ["dev": .deploy, "lead": .read])
        #expect(Integrations.access(reading.access("acme/web"), agent: "lead", to: .deploy)
                == ["dev": .deploy, "lead": .deploy])
    }

    @Test func oneChoiceChangesOneAgentAndKeepsTheOthers() {
        let current: [String: RepositoryAccess] = ["dev": .write, "lead": .read]
        #expect(Integrations.access(current, agent: "ops", to: .read) == ["dev": .write, "lead": .read, "ops": .read])
        #expect(Integrations.access(current, agent: "dev", to: .read) == ["dev": .read, "lead": .read])
        #expect(Integrations.access(current, agent: "lead", to: nil) == ["dev": .write])
        let order = ["manager", "dev", "lead", "ops"]
        #expect(Integrations.agents(["ops"], agent: "dev", on: true, order: order) == ["dev", "ops"])
        #expect(Integrations.agents(["dev", "ops"], agent: "dev", on: false, order: order) == ["ops"])
        #expect(Integrations.agents(["dev"], agent: "dev", on: true, order: order) == ["dev"])
    }

    /// Owner feature `repo_picker`: the list names each account as GitHub writes it and each repository as team.json
    /// keeps it, under its own account only.
    @Test func theListToChooseFromKeepsEachRepositoryUnderItsOwnAccount() throws {
        func list(_ accounts: [[String: Any]], db: String = "db") throws -> RepositoryList {
            try JSONDecoder().decode(RepositoryList.self, from: JSONSerialization.data(withJSONObject: [
                "db": db, "accounts": accounts, "problem": NSNull()]))
        }
        let good = try list([["account": "Globex", "repos": ["globex/adminapi", "globex/shopapi"]]])
        try good.validate(database: "db")
        #expect(good.accounts.first?.account == "Globex" && good.problem == nil)
        #expect(Integrations.name("globex/shopapi") == "shopapi")
        #expect(throws: HubError.self) { try good.validate(database: "other") }
        #expect(throws: HubError.self) { try list([["account": "acme", "repos": ["other/x"]]]).validate(database: "db") }
        #expect(throws: HubError.self) { try list([["account": "acme", "repos": ["acme/Web"]]]).validate(database: "db") }
        #expect(Integrations.pickerFeature == "repo_picker")
    }

    /// The list under the + of an agent's Can use › GitHub: a search shows the repositories whose name, without the
    /// owner, holds its words in any case, and "N of M" counts what the agent has and what it gets.
    @Test func theListsSearchReadsTheNameAndItsCountReadsWhatTheAgentHasOrGets() throws {
        let account = try JSONDecoder().decode(RepositoryList.Account.self, from: JSONSerialization.data(withJSONObject: [
            "account": "Globex", "repos": ["globex/adminapi", "globex/argocd", "globex/shopapi", "globex/webadmin"]]))
        #expect(account.shown(by: "") == account.repos && account.shown(by: "  \n") == account.repos)
        #expect(account.shown(by: " ADMIN ") == ["globex/adminapi", "globex/webadmin"])
        #expect(account.shown(by: "admin  web") == ["globex/webadmin"])
        #expect(account.shown(by: "globex").isEmpty)
        #expect(account.shown(by: "argo") == ["globex/argocd"])
        #expect(RepositoryList.Account(account: "Acme", repos: ["acme/WebApp"]).shown(by: "webapp") == ["acme/WebApp"])
        #expect(account.chosen(held: [], picked: []) == 0)
        #expect(account.chosen(held: ["globex/adminapi"], picked: ["globex/argocd", "other/x"]) == 2)
        #expect(account.chosen(held: ["globex/adminapi"], picked: ["globex/adminapi"]) == 1)
    }

    /// A reading of the list that could not read one App keeps the accounts that the reading before it listed and it
    /// lacks, with its own problem; a whole reading, or one of another hub generation, replaces it.
    @Test func aListThatCouldNotReadEveryAppKeepsTheAccountsItLacks() {
        let older = RepositoryList(db: "db", accounts: [.init(account: "Globex", repos: ["globex/web"]),
                                                       .init(account: "acme", repos: ["acme/lib"])], problem: nil)
        let partial = RepositoryList(db: "db", accounts: [.init(account: "acme", repos: ["acme/lib", "acme/new"])],
                                     problem: "The door did not answer.")
        let kept = partial.keeping(older)
        #expect(kept.accounts == [.init(account: "acme", repos: ["acme/lib", "acme/new"]),
                                  .init(account: "Globex", repos: ["globex/web"])])
        #expect(kept.problem == "The door did not answer." && kept.db == "db")
        let whole = RepositoryList(db: "db", accounts: [.init(account: "acme", repos: ["acme/lib"])], problem: nil)
        #expect(whole.keeping(older).accounts == whole.accounts)
        let other = RepositoryList(db: "other", accounts: [], problem: "The door did not answer.")
        #expect(other.keeping(older).accounts.isEmpty)
        #expect(partial.keeping(nil).accounts == partial.accounts)
        let cased = RepositoryList(db: "db", accounts: [.init(account: "GLOBEX", repos: ["globex/web"])], problem: "x")
        #expect(cased.keeping(older).accounts.map(\.account) == ["GLOBEX", "acme"])
    }

    /// The owner's yes of 9 November 2026 to the list as shown: an owner's repositories at one level are one row with
    /// their count when there are more than a few, in the order of the levels.
    @Test func manyRepositoriesOfOneOwnerAndLevelAreOneRow() {
        var repos: [String: RepositoryAccess] = ["globex/shopapi": .write, "acme/web": .deploy]
        for name in ["a", "b", "c", "d"] { repos["globex/\(name)"] = .read }
        let groups = Integrations.groups(repos)
        #expect(groups.map(\.id) == ["acme/deploy", "globex/read", "globex/write"])
        #expect(groups.map(\.grouped) == [false, true, false])
        #expect(groups[1].repos == ["globex/a", "globex/b", "globex/c", "globex/d"])
        #expect(Integrations.groups([:]).isEmpty)
        // Three of one owner at one level stay three rows.
        #expect(Integrations.groups(["globex/a": .read, "globex/b": .read, "globex/c": .read]).map(\.grouped) == [false])
        // The row names the owner as GitHub writes it, once the list is read.
        let list = RepositoryList(db: "db", accounts: [.init(account: "GlobexCorp", repos: ["globexcorp/a"])], problem: nil)
        #expect(list.account("globexcorp") == "GlobexCorp" && list.account("GLOBEXCORP") == "GlobexCorp")
        #expect(list.account("acme") == nil)
    }

    /// Owner feature `repo_picker`: one agent and a level, or null that takes the repositories away from it, so the
    /// other agents keep theirs.
    @Test func oneAgentsWriteNamesTheAgentAndTheLevel() throws {
        let data = try IntegrationsClient.body(["base_sha256": sha, "repo": ["acme/lib", "acme/web"], "agent": "dev",
                                                "level": "read"],
                                               requestID: "11111111-2222-4333-8444-555555555555", database: "db")
        let sent = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(sent.keys) == ["request_id", "db", "base_sha256", "repo", "agent", "level"])
        #expect(sent["repo"] as? [String] == ["acme/lib", "acme/web"] && sent["level"] as? String == "read")
        let away = try IntegrationsClient.body(["base_sha256": sha, "repo": ["acme/lib"], "agent": "dev", "level": NSNull()],
                                               requestID: "11111111-2222-4333-8444-555555555555", database: "db")
        #expect(String(data: away, encoding: .utf8)?.contains("\"level\":null") == true)
    }

    @Test func aWriteSendsTheCommandFieldsAndTheBaseVersion() throws {
        let data = try IntegrationsClient.body(["base_sha256": sha, "repo": "acme/web",
                                                "access": (["dev": RepositoryAccess.write] as [String: RepositoryAccess]).mapValues(\.rawValue)],
                                               requestID: "11111111-2222-4333-8444-555555555555", database: "db")
        let sent = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(sent.keys) == ["request_id", "db", "base_sha256", "repo", "access"])
        #expect(sent["access"] as? [String: String] == ["dev": "write"])
        #expect(sent["db"] as? String == "db" && sent["base_sha256"] as? String == sha)
    }
}
