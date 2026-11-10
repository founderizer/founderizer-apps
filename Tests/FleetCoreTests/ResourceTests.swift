import Foundation
import Testing
@testable import FleetCore

private let sha = String(repeating: "a", count: 64)
private let key = "bws://28eaf23b-f5d2-4623-a4fb-b4de012c53fb"

/// One reading of `GET /ui/resources`, in the hub's own shape.
private func list(db: String = "db", standing: [String: Any]? = ["max": "write", "to": "workers"],
                  mail: [String: Any]? = ["max": "send", "to": "shop"],
                  holders: [[String: Any]] = [["agent": "dev", "level": "write"]],
                  history: [[String: Any]] = [["id": 2, "ts": 1_760_700_000.0, "agent": "dev", "level": "write",
                                               "by": "manager", "revision": String(repeating: "c", count: 40)],
                                              ["id": 1, "ts": 1_760_600_000.0, "agent": "ops", "level": NSNull(),
                                               "by": "owner", "revision": String(repeating: "d", count: 40)]],
                  projects: [[String: Any]] = [["id": "shop", "title": "Shop"]],
                  github: [String: Any]? = nil) throws -> ResourceList {
    let kinds: [[String: Any]] = [
        ["kind": "secret", "title": "Data sources and deploy routes", "word": "secret", "levels": ["use", "read"],
         "needs": "a data source or a deploy route"],
        ["kind": "repo", "title": "Repositories", "word": "GitHub repository", "levels": ["read", "write"],
         "needs": "a repository to change"],
        ["kind": "gmail", "title": "Mail accounts", "word": "Gmail", "levels": ["read", "write", "send"],
         "needs": "a mail account"],
        ["kind": "tool", "title": "MCP servers", "word": "MCP server", "levels": ["use"], "needs": "an MCP server"]]
    let grant: Any = standing.map { $0 as Any } ?? NSNull()
    let mailGrant: Any = mail.map { $0 as Any } ?? NSNull()
    let resources: [[String: Any]] = [
        ["id": "secret:\(key)", "kind": "secret", "what": key, "title": "DEPLOY_KEY",
         "needs": "a data source or a deploy route", "levels": ["use", "read"], "uses": [key],
         "credential": "vault", "connected": true, "grant": NSNull(), "holders": [], "history": []],
        ["id": "repo:acme/web", "kind": "repo", "what": "acme/web", "title": "acme/web",
         "needs": "a repository to change", "levels": ["read", "write"], "uses": [],
         "credential": "github_app", "connected": true, "grant": grant, "holders": holders, "history": history],
        ["id": "gmail:support@shop.test", "kind": "gmail", "what": "support@shop.test", "title": "support@shop.test",
         "needs": "a mail account", "levels": ["read", "write", "send"], "uses": [],
         "credential": "google", "connected": false, "grant": mailGrant, "holders": [],
         "history": []],
        ["id": "tool:jobs", "kind": "tool", "what": "jobs", "title": "Failed jobs", "needs": "an MCP server",
         "levels": ["use"], "uses": [key], "credential": "key", "connected": true, "grant": NSNull(),
         "holders": [], "history": []]]
    var object: [String: Any] = ["db": db, "revision": String(repeating: "b", count: 40), "sha256": sha,
                                 "audience": "workers", "limit": 256,
                                 "projects": projects, "kinds": kinds, "resources": resources]
    object["github"] = github
    return try JSONDecoder().decode(ResourceList.self, from: JSONSerialization.data(withJSONObject: object))
}

struct ResourceTests {
    /// Settings › Access writes "which agents may use this item", and the hub takes a repository's access and an
    /// MCP server's agents **whole**: whoever is missing from that write loses the item. So a change for one agent
    /// must carry every other holder with it, and this is the check that says it does.
    @Test func givingOneAgentAnItemTakesItFromNobodyElse() {
        let repo = FleetResource(id: "repo:acme/web", kind: "repo", what: "acme/web", title: "acme/web",
                                 needs: "a repository to change", levels: ["read", "write"], uses: [],
                                 credential: "github_app", connected: true, grant: nil,
                                 holders: [ResourceHolder(agent: "dev", level: "write"),
                                           ResourceHolder(agent: "scout", level: "read")])
        #expect(repo.repositoryAccess(giving: "writer", level: "read")
                == ["dev": "write", "scout": "read", "writer": "read"])
        // Taking it back from one agent leaves the others exactly as they were.
        #expect(repo.repositoryAccess(giving: "dev", level: nil) == ["scout": "read"])
        // A level that this kind does not have is not written at all.
        #expect(repo.repositoryAccess(giving: "writer", level: "admin") == ["dev": "write", "scout": "read"])

        let tool = FleetResource(id: "tool:jobs", kind: "tool", what: "jobs", title: "jobs", needs: "an MCP server",
                                 levels: ["use"], uses: [], credential: "key", connected: true, grant: nil,
                                 holders: [ResourceHolder(agent: "dev", level: "use"),
                                           ResourceHolder(agent: "scout", level: "use")])
        #expect(tool.toolAgents(giving: "writer", level: "use") == ["dev", "scout", "writer"])
        #expect(tool.toolAgents(giving: "scout", level: nil) == ["dev"])
        // The same agent twice is one agent, whichever way the change came.
        #expect(tool.toolAgents(giving: "dev", level: "use") == ["dev", "scout"])
    }

    @Test func theListGivesEachResourceItsStandingItsSecretsAndItsHolders() throws {
        let pool = try list()
        try pool.validate(database: "db")
        #expect(pool.groups.map(\.kind.kind) == ["secret", "repo", "gmail", "tool"])
        #expect(pool.groups.map { $0.resources.count } == [1, 1, 1, 1])
        let repo = try #require(pool.resource("repo:acme/web"))
        #expect(repo.standing == .grantable(max: "write", to: "workers"))
        #expect(repo.standing.max == "write" && repo.standing.audience == "workers")
        #expect(repo.holders == [ResourceHolder(agent: "dev", level: "write")])
        #expect(repo.credentialWords == "Your GitHub App gives the access.")
        #expect(repo.uses.isEmpty)
        #expect(repo.summary(pool.kind(of: repo)) == "GitHub repository · dev write")
        // A secret names itself as the secret it uses; an MCP server with a key names that key.
        let secret = try #require(pool.resource("secret:\(key)"))
        #expect(secret.uses == [key] && secret.credential == "vault" && secret.title == "DEPLOY_KEY")
        #expect(try #require(pool.resource("tool:jobs")).uses == [key])
        #expect(pool.resource("repo:other/x") == nil)
    }

    /// A repository that the hub's GitHub App does not reach carries the GitHub page where the owner adds it (the
    /// orange mark of its row, and Add on GitHub on the group's heading). Only a page on github.com is ever opened.
    @Test func aRepositoryTheGitHubAppDoesNotReachGivesThePageThatAddsIt() throws {
        let page = "https://github.com/settings/installations/12345678"
        let pool = try list(github: ["unreached": ["acme/web": page]])
        try pool.validate(database: "db")
        let repo = try #require(pool.resource("repo:acme/web"))
        #expect(pool.unreachedPage(repo) == URL(string: page))
        #expect(pool.unreachedPages() == [URL(string: page)!])
        #expect(pool.unreachedPages(of: "dev") == [URL(string: page)!])         // dev holds it
        #expect(pool.unreachedPages(of: "ops").isEmpty)                         // ops does not
        #expect(pool.unreachedPage(try #require(pool.resource("tool:jobs"))) == nil)
        // Nothing marked, a hub from before the field, and a page anywhere else than github.com: no page at all.
        for github in [["unreached": [:] as [String: String]], nil,
                       ["unreached": ["acme/web": "https://example.com/settings/installations/1"]],
                       ["unreached": ["acme/web": "http://github.com/settings/installations/1"]]] as [[String: Any]?] {
            let other = try list(github: github)
            #expect(other.unreachedPage(try #require(other.resource("repo:acme/web"))) == nil)
            #expect(other.unreachedPages().isEmpty)
        }
    }

    @Test func aStandingSaysWhoMayGiveTheResource() throws {
        let pool = try list()
        // Not grantable: the owner alone, which is the default of every resource.
        let plain = try #require(try list(standing: nil).resource("repo:acme/web"))
        #expect(plain.standing == .ownerOnly)
        #expect(plain.standing.max == nil && plain.standing.policy == nil)
        // Grantable at send level, because the grant is the authorization.
        let mail = try #require(pool.resource("gmail:support@shop.test"))
        #expect(mail.standing == .grantable(max: "send", to: "shop"))
        #expect(mail.standing.policy == ["max": "send", "to": "shop"])
        // The hub keeps one audience now. An audience it does not know is shown as it came, not as a project.
        #expect(pool.audienceWords(ResourceList.everyone) == "every worker and lead")
        #expect(pool.audienceWords("shop") == "shop")
        // A level that this kind does not have is no standing at all: the owner alone, never a guess.
        let odd = try #require(try list(standing: ["max": "admin", "to": "workers"]).resource("repo:acme/web"))
        #expect(odd.standing == .ownerOnly && odd.standing.max == nil)
        // Only the resources that the manager may hand out.
        #expect(pool.grantable.map(\.id) == ["repo:acme/web", "gmail:support@shop.test"])
        #expect(try list(standing: nil).grantable.map(\.id) == ["gmail:support@shop.test"])
    }

    /// The pool is what the manager may hand out, and Settings › Access reads it in one line over the items. A
    /// fleet where the owner has opened nothing is the ordinary first state, so that line says so plainly and says
    /// the one step that changes it, instead of leaving the owner to click every item to find out.
    @Test func theOneLineOverTheItemsSaysWhatTheManagerMayGive() throws {
        let empty = try list(standing: nil, mail: nil)
        #expect(empty.grantable.isEmpty)
        #expect(empty.poolTitle == "Nothing yet")
        #expect(empty.poolDetail == "You give every one of these yourself. Open an item and set who may give it: "
                + "then the fleet manager hands it out, up to the level you set, to every worker and lead.")
        // With something in it, the line is the items themselves, each with the level the owner allowed.
        #expect(try list().poolTitle == "2 items")
        #expect(try list().poolDetail == "acme/web up to write · support@shop.test up to send")
        #expect(try list(mail: nil).poolTitle == "One item")
        #expect(try list(mail: nil).poolDetail == "acme/web up to write")
    }

    @Test func everyLevelOfAKindCanBeGranted() throws {
        let pool = try list()
        // No level is held back for the owner: sending mail is part of what a mail account is granted at.
        let mail = try #require(pool.kinds.first { $0.kind == "gmail" })
        #expect(mail.levels == ["read", "write", "send"])
        #expect(try #require(pool.kinds.first { $0.kind == "repo" }).levels == ["read", "write"])
        #expect(try #require(pool.kinds.first { $0.kind == "tool" }).levels == ["use"])
    }

    @Test func theRecordSaysWhoGaveWhatToWhom() throws {
        let repo = try #require(try list().resource("repo:acme/web"))
        #expect(repo.history.map(\.id) == [2, 1])                          // newest first, as the hub gives it
        #expect(repo.history[0].words == "Manager gave Dev write")
        #expect(repo.history[1].words == "You took it back from Ops")      // the owner's own step
        #expect(repo.history[0].level == "write" && repo.history[1].level == nil)
        #expect(repo.history[0].revision?.count == 40)
        #expect(try #require(try list().resource("tool:jobs")).history.isEmpty)
    }

    @Test func aReadingOfAnotherHubOrAWrongShapeIsRefused() throws {
        #expect(throws: HubError.self) { try list().validate(database: "other") }
        #expect(throws: HubError.self) { try list(db: "db").validate(database: "db2") }
        // A resource of a kind that the answer does not describe, and a bad version.
        let noKind: [String: Any] = ["db": "db", "revision": NSNull(), "sha256": sha, "audience": "workers",
                                     "limit": 256, "projects": [], "kinds": [],
                                     "resources": [["id": "repo:acme/web", "kind": "repo", "what": "acme/web",
                                                    "title": "acme/web", "needs": "x", "levels": ["read"],
                                                    "uses": [], "credential": "github_app",
                                                    "connected": true, "grant": NSNull(),
                                                    "holders": [], "history": []]]]
        let unknownKind = try JSONDecoder().decode(ResourceList.self,
                                                   from: JSONSerialization.data(withJSONObject: noKind))
        #expect(throws: HubError.self) { try unknownKind.validate(database: "db") }
        let badSHA = try JSONDecoder().decode(ResourceList.self, from: JSONSerialization.data(
            withJSONObject: ["db": "db", "revision": NSNull(), "sha256": "short", "audience": "workers",
                             "limit": 256, "projects": [], "kinds": [], "resources": []]))
        #expect(throws: HubError.self) { try badSHA.validate(database: "db") }
    }

    @Test func theWritesRefuseAResourceOrAnAgentThatIsNotOneBeforeTheyLeave() async throws {
        let client = ResourcesClient()
        let hub = URL(string: "http://127.0.0.1:1/")!
        for bad in ["repo", "Repo:Acme/Web", ""] {
            await #expect(throws: HubError.self) {
                try await client.saveStanding(hub: hub, database: "db", client: "test", sha256: sha, resource: bad,
                                              standing: .ownerOnly)
            }
            await #expect(throws: HubError.self) {
                try await client.takeBack(hub: hub, database: "db", client: "test", resource: bad, agent: "dev")
            }
        }
        await #expect(throws: HubError.self) {
            try await client.saveStanding(hub: hub, database: "db", client: "test", sha256: "short",
                                          resource: "repo:acme/web", standing: .ownerOnly)
        }
        for bad in ["Dev", "-dev", "d", ""] {
            await #expect(throws: HubError.self) {
                try await client.takeBack(hub: hub, database: "db", client: "test", resource: "repo:acme/web", agent: bad)
            }
        }
    }
}
