import Foundation

/// The owner's standing for one resource (owner feature `resource_grants`): who may hand it out.
///
/// The line the owner drew: bringing a credential into the fleet is the owner's, because it is the owner's account,
/// money and liability; handing out something the fleet already holds can be the fleet manager's. So each resource
/// carries one standing, and nothing is grantable until the owner sets it.
///
/// **The grant is the authorization** (the owner, 17 October 2026: "I dont want to preapprove sending emails or
/// deploying to production! If I grant access to a repo/database/system/server is for the relevant agent to take full
/// responsability"). An agent that holds a resource does what that credential allows and answers for it, customer mail
/// and a production deployment included; nothing asks the owner a second time. The owner's two controls are the level,
/// which is part of what is granted, and the record: every change of a hold is a commit of `team.json` and a row that
/// this page shows, and one step takes any hold back.
public enum ResourceStanding: Equatable, Sendable {
    /// The owner gives it alone. This is the default of every resource.
    case ownerOnly
    /// The fleet manager may give it with `grant_access`, at most at `max`, to `to`: every worker and lead
    /// (`ResourceList.everyone`), which is the one audience the hub keeps.
    case grantable(max: String, to: String)

    /// The level that the manager may give, or nil.
    public var max: String? { if case .grantable(let max, _) = self { max } else { nil } }
    /// The audience that may get it, or nil.
    public var audience: String? { if case .grantable(_, let to) = self { to } else { nil } }

    /// What `POST /ui/resources` sends as `policy`; nil takes the entry out, which is `ownerOnly`.
    public var policy: [String: String]? {
        switch self {
        case .ownerOnly: nil
        case .grantable(let max, let to): ["max": max, "to": to]
        }
    }
}

/// One change of who holds a resource, as the hub recorded it: who gave or took it, from whom, at which level, when,
/// and the commit of `team.json` that did it. `level` nil: the hold ended. Since the grant is the authorization, this
/// record is what the owner reads afterwards.
public struct ResourceGrantRecord: Decodable, Identifiable, Equatable, Sendable {
    public let id: Int
    public let ts: Double
    public let agent: String
    public let level: String?
    /// The agent that made the change: the fleet manager's name, or `owner`.
    public let by: String
    public let revision: String?

    public init(id: Int, ts: Double, agent: String, level: String?, by: String, revision: String?) {
        self.id = id; self.ts = ts; self.agent = agent; self.level = level; self.by = by; self.revision = revision
    }

    /// The line the owner reads: "Manager gave dev write" or "You took it back from dev".
    public var words: String {
        let you = by == "owner", who = by.agentLabel, to = agent.agentLabel
        guard let level else {
            return you ? String(l10n: "You took it back from \(to)") : String(l10n: "\(who) took it back from \(to)")
        }
        return you ? String(l10n: "You gave \(to) \(level)") : String(l10n: "\(who) gave \(to) \(level)")
    }
}

/// One kind of resource, as the hub names it: what a duty needs it for, and the levels it has. The hub answers with
/// this block, so the app keeps no second list of kinds or levels.
public struct ResourceKind: Decodable, Identifiable, Equatable, Sendable {
    public let kind: String
    /// The heading of its group on the page.
    public let title: String
    /// The kind in one word for a sentence, for example "GitHub repository".
    public let word: String
    /// From the lowest level to the highest. Every one of them can be granted: a level is part of what the owner
    /// grants, not a second gate.
    public let levels: [String]
    /// What a duty needs it for, for example "a repository to change".
    public let needs: String
    public var id: String { kind }

    public init(kind: String, title: String, word: String, levels: [String], needs: String) {
        self.kind = kind; self.title = title; self.word = word; self.levels = levels; self.needs = needs
    }
}

/// One agent that holds a resource now, at one level.
public struct ResourceHolder: Decodable, Identifiable, Equatable, Sendable {
    public let agent: String
    public let level: String
    public var id: String { agent }

    public init(agent: String, level: String) { self.agent = agent; self.level = level }
}

/// One thing that the owner already brought into the fleet: a secret, a GitHub repository, a Google service or an MCP
/// server. `id` is `<kind>:<what>`. It carries no value and no token: a secret is its reference and its name.
public struct FleetResource: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: String
    /// The reference, repository, account or server name inside the id.
    public let what: String
    /// What the owner reads: a secret's name in the catalog, else `what`.
    public let title: String
    public let needs: String
    public let levels: [String]
    /// The `bws://` references of the catalog that this resource needs: a secret needs itself, an MCP server with a
    /// key needs that key. Empty when the hub holds the credential itself.
    public let uses: [String]
    /// How its credential is held, as a code: `vault`, `github_app`, `google`, `oauth`, `key`, `fleet` or `none`.
    public let credential: String
    /// False only for a Google account that the hub has no token for. A grant is still allowed.
    public let connected: Bool
    /// The policy, when the manager may give it.
    public let grant: Policy?
    public let holders: [ResourceHolder]
    /// The newest changes of who holds it, newest first.
    public let history: [ResourceGrantRecord]

    public struct Policy: Decodable, Equatable, Sendable {
        public let max: String
        public let to: String
        public init(max: String, to: String) { self.max = max; self.to = to }
    }

    public init(id: String, kind: String, what: String, title: String, needs: String, levels: [String],
                uses: [String], credential: String, connected: Bool, grant: Policy?, holders: [ResourceHolder],
                history: [ResourceGrantRecord] = []) {
        self.id = id; self.kind = kind; self.what = what; self.title = title; self.needs = needs; self.levels = levels
        self.uses = uses; self.credential = credential; self.connected = connected; self.grant = grant
        self.holders = holders; self.history = history
    }

    /// The owner's standing for this resource.
    public var standing: ResourceStanding {
        if let grant, levels.contains(grant.max) { return .grantable(max: grant.max, to: grant.to) }
        return .ownerOnly
    }

    /// Every agent's access of this repository after one change. The hub takes a repository's access **whole**
    /// (`POST /ui/team/repos`), so an agent that is missing from the map loses the repository: the others are
    /// carried over here, and a change for one agent can never take it from another.
    public func repositoryAccess(giving agent: String, level: String?) -> [String: String] {
        var access = Dictionary(holders.map { ($0.agent, $0.level) }, uniquingKeysWith: { _, new in new })
        access[agent] = level
        return access.filter { levels.contains($0.value) }
    }

    /// The agents of this MCP server after one change, for the same reason: `POST /ui/team/tools` takes the whole
    /// list, and an agent that is not in it loses the server.
    public func toolAgents(giving agent: String, level: String?) -> [String] {
        var agents = holders.map(\.agent).filter { $0 != agent }
        if level != nil { agents.append(agent) }
        return agents.sorted()
    }

    /// The access map of a Drive or Gmail account after one agent's change, for `saveAccess`, which takes the whole
    /// map: every other agent keeps what it holds. The account is the unit here, as it is on the hub — one account
    /// of the fleet's, held by as many agents as the owner gives it to.
    public func googleAccess(giving agent: String, level: String?) -> [String: GoogleLevel] {
        var access = Dictionary(uniqueKeysWithValues: holders.compactMap { holder in
            holder.agent == agent ? nil : GoogleLevel(rawValue: holder.level ?? "").map { (holder.agent, $0) }
        })
        access[agent] = level.flatMap(GoogleLevel.init(rawValue:))
        return access
    }

    /// Where the credential of this resource is, in the owner's words.
    public var credentialWords: String {
        switch credential {
        case "vault": "Your vault holds the value."
        case "github_app": "Your GitHub App gives the access."
        case "google": "Your Google connection gives the access."
        case "oauth": "The hub holds its sign-in."
        case "key": "It uses an API key of your secrets."
        case "fleet": "Founderizer's own tool."
        default: "It needs no credential."
        }
    }

    /// One line under the name: what a duty needs it for, and who holds it now.
    public func summary(_ kind: ResourceKind?) -> String {
        let word = kind?.word ?? self.kind
        let who = holders.isEmpty ? "no agent" : holders.map { "\($0.agent) \($0.level)" }.joined(separator: ", ")
        return "\(word) · \(who)"
    }
}

/// `GET /ui/resources` `github`: each repository of the list that the hub's GitHub App does not reach, with the GitHub
/// page where the owner adds it (UI-API.md, "What the App reaches"). The hub keeps such a grant and marks it.
public struct GitHubReach: Decodable, Equatable, Sendable {
    /// {owner/name: the page}; empty while the App reaches them all, or while the hub could not read GitHub.
    public let unreached: [String: String]?

    public init(unreached: [String: String]? = nil) { self.unreached = unreached }
}

/// `GET /ui/resources` (owner feature `resource_grants`): what a duty can need, as the owner already holds it, each
/// with its standing and the agents that hold it now. The hub serves it from `team.json`.
public struct ResourceList: Decodable, Sendable {
    public static let feature = "resource_grants"
    /// A standing's `to` that means every worker and lead, instead of the members of one project.
    public static let everyone = "workers"

    public let db: String
    /// The hub revision of the `team.json` that this reading has.
    public let revision: String?
    /// Its version: a change of a standing goes against it.
    public let sha256: String
    public let audience: String
    public let limit: Int
    public let kinds: [ResourceKind]
    public let resources: [FleetResource]
    /// What the hub's GitHub App does not reach; nil from a hub before it read that.
    public let github: GitHubReach?

    public init(db: String, revision: String?, sha256: String, audience: String, limit: Int,
                kinds: [ResourceKind], resources: [FleetResource], github: GitHubReach? = nil) {
        self.db = db; self.revision = revision; self.sha256 = sha256; self.audience = audience
        self.limit = limit; self.kinds = kinds; self.resources = resources; self.github = github
    }

    /// The GitHub page where the owner adds this repository to the hub's GitHub App, while the App does not reach it;
    /// nil for every other resource. GitHub lets only a person add a repository to an App's installation, so the
    /// app opens that page and does not try to change it. Only a page on github.com is taken.
    public func unreachedPage(_ resource: FleetResource) -> URL? {
        guard resource.kind == "repo", let text = github?.unreached?[resource.what], let page = URL(string: text),
              page.scheme == "https", page.host == "github.com" else { return nil }
        return page
    }

    /// The pages of the repositories that the App does not reach, each once: of the repositories that one agent
    /// holds, or of every repository with nil. What Add on GitHub opens; usually one, the installation's page.
    public func unreachedPages(of agent: String? = nil) -> [URL] {
        var pages: [URL] = []
        for resource in resources where agent == nil || resource.holders.contains(where: { $0.agent == agent }) {
            if let page = unreachedPage(resource), !pages.contains(page) { pages.append(page) }
        }
        return pages
    }

    public func validate(database: String) throws {
        guard db == database, sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              limit > 0, resources.count <= 4096, Set(resources.map(\.id)).count == resources.count,
              Set(kinds.map(\.kind)).count == kinds.count,
              resources.allSatisfy({ resource in kinds.contains { $0.kind == resource.kind } }) else {
            throw HubError.invalidResponse
        }
    }

    /// The resources by kind, in the hub's order, with the empty kinds left out.
    public var groups: [ResourceGroup] {
        kinds.compactMap { kind in
            let found = resources.filter { $0.kind == kind.kind }
            return found.isEmpty ? nil : ResourceGroup(kind: kind, resources: found)
        }
    }

    public func kind(of resource: FleetResource) -> ResourceKind? { kinds.first { $0.kind == resource.kind } }

    /// One audience in the owner's words. The hub keeps exactly one, every worker and lead, since the project
    /// concept went; anything else is shown as the hub wrote it, never dressed up as something this app invented.
    public func audienceWords(_ to: String) -> String {
        to == Self.everyone ? String(l10n: "every worker and lead") : to
    }
    public func resource(_ id: String) -> FleetResource? { resources.first { $0.id == id } }

    /// The resources that the fleet manager may hand out now.
    public var grantable: [FleetResource] { resources.filter { $0.standing.max != nil } }

    /// The pool in one line, for the row at the top of Settings › Access: how many of these the fleet manager may
    /// hand out without asking. Nothing is grantable until the owner opens an item, so an empty pool is the ordinary
    /// state of a new fleet and `poolDetail` says what to do about it.
    public var poolTitle: String {
        let open = grantable.count
        return open == 0 ? "Nothing yet" : open == 1 ? "One item" : "\(open) items"
    }

    /// Under it: the items the manager may give with the level of each, or, with an empty pool, the one step that
    /// puts something in it.
    public var poolDetail: String {
        let open = grantable
        guard !open.isEmpty else {
            return "You give every one of these yourself. Open an item and set who may give it: then the fleet "
                + "manager hands it out, up to the level you set, to \(audienceWords(audience))."
        }
        return open.map { "\($0.title) up to \($0.standing.max ?? "")" }.joined(separator: " · ")
    }
}

/// One group of the page: the resources of one kind, under that kind's heading.
public struct ResourceGroup: Identifiable, Equatable, Sendable {
    public let kind: ResourceKind
    public let resources: [FleetResource]
    public var id: String { kind.kind }

    public init(kind: ResourceKind, resources: [FleetResource]) { self.kind = kind; self.resources = resources }
}

/// `GET /ui/resources` and its two writes. `POST /ui/resources` sets the standing of one resource, against the
/// `team.json` version that the page read (`base_sha256`); a write that gets no answer can have arrived, and the next
/// one, from a new reading, is safe, because the hub refuses an old version (409). `POST /ui/resources/take` ends one
/// agent's hold in one step, whoever gave it, and needs no version, as the secrets grant does: two clicks on two
/// holders never undo each other. Settings › Access writes both: which agents may use an item, and who may hand it
/// out. The manager's own `grant_access` writes the second one's result, and this page is where the owner reads who
/// holds what, who gave it, and ends it.
public final class ResourcesClient: Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60        // the hub commits and pushes team.json before it answers
        configuration.timeoutIntervalForResource = 90
        session = URLSession(configuration: configuration)
    }

    public func read(hub: URL, database: String) async throws -> ResourceList {
        var parts = URLComponents(url: hub.appendingPathComponent("ui/resources"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "db", value: database)]
        var request = URLRequest(url: parts.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let list = try JSONDecoder().decode(ResourceList.self, from: await perform(request))
        try list.validate(database: database)
        return list
    }

    /// The standing of one resource. `.ownerOnly` takes its entry out of `team.json`.
    public func saveStanding(hub: URL, database: String, client: String, sha256: String, resource: String,
                             standing: ResourceStanding) async throws -> ResourceReceipt {
        guard sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              resource == resource.lowercased(), resource.contains(":") else { throw HubError.invalidResponse }
        let requestID = UUID().uuidString.lowercased()
        var request = URLRequest(url: hub.appendingPathComponent("ui/resources"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client, forHTTPHeaderField: "X-Fleet-Client")
        let policy: Any = standing.policy.map { $0 as Any } ?? NSNull()
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "request_id": requestID, "db": database, "base_sha256": sha256, "resource": resource,
            "policy": policy] as [String: Any], options: [.sortedKeys])
        let receipt = try JSONDecoder().decode(ResourceReceipt.self, from: await perform(request))
        guard receipt.ok, receipt.request_id == requestID, receipt.client == client,
              receipt.resource == resource else { throw HubError.invalidResponse }
        return receipt
    }

    /// One agent's hold of one resource ends, whoever gave it. The hub writes the same kind of commit and record as a
    /// grant, so the page shows who ended it.
    public func takeBack(hub: URL, database: String, client: String, resource: String,
                         agent: String) async throws -> ResourceTakeReceipt {
        guard resource == resource.lowercased(), resource.contains(":"),
              agent.range(of: "^[a-z][a-z0-9-]{1,30}$", options: .regularExpression) != nil else {
            throw HubError.invalidResponse
        }
        let requestID = UUID().uuidString.lowercased()
        var request = URLRequest(url: hub.appendingPathComponent("ui/resources/take"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client, forHTTPHeaderField: "X-Fleet-Client")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "request_id": requestID, "db": database, "resource": resource, "agent": agent], options: [.sortedKeys])
        let receipt = try JSONDecoder().decode(ResourceTakeReceipt.self, from: await perform(request))
        guard receipt.ok, receipt.request_id == requestID, receipt.client == client, receipt.resource == resource,
              receipt.agent == agent else { throw HubError.invalidResponse }
        return receipt
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        // A read of the hub that is on its way already, through any client with the same time limits, is the answer to
        // the same read now (`HubReads`, fix round 2); a write never is.
        guard let key = HubReads.key(request, in: session.configuration) else { return try await fetch(request) }
        return try await HubReads.shared.share(key) { [self] in HubReads.Answer(data: try await fetch(request), response: nil) }.data
    }

    private func fetch(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        HubWrites.note(request)
        guard let response = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        guard response.statusCode == 200 else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "Unexpected HTTP response."
            throw HubError.refusal(response.statusCode, String(message.prefix(500)))
        }
        return data
    }

    private struct ErrorBody: Decodable { let error: String }
}

/// The hub's answer to `POST /ui/resources/take`. `had`: the level that the agent held, nil when it held none.
public struct ResourceTakeReceipt: Decodable, Sendable {
    public let ok: Bool
    public let request_id: String
    public let client: String
    public let resource: String
    public let agent: String
    public let had: String?
    public let changed: Bool
}

/// The hub's answer to `POST /ui/resources`.
public struct ResourceReceipt: Decodable, Sendable {
    public let ok: Bool
    public let request_id: String
    public let client: String
    public let resource: String
    public let policy: FleetResource.Policy?
    public let sha256: String
    public let changed: Bool
}
