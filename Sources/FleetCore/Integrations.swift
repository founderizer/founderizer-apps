import Foundation

/// The access that the owner gives an agent to one GitHub repository (owner feature `integrations`), from the lowest
/// to the highest. `deploy` is `write` and the repository's own deployment: its workflow files, which a `write` token
/// may not push at all, and its GitHub Actions runs. The hub's GitHub App must carry the Workflows and Actions
/// permissions, and the owner must accept them on the App's installation, before a `deploy` token can be minted.
public enum RepositoryAccess: String, Codable, CaseIterable, Sendable {
    case read, write, deploy
    public var title: String { rawValue.capitalized }
}

/// The GitHub repositories and the tools of the agents' task sessions, as `GET /ui/team` gives them: each line's
/// `repos` and `tools`, the hub's tool catalog, and whether the hub has its GitHub App. A repository that no agent may
/// use is not in team.json, so it is not here.
public struct IntegrationsSnapshot: Decodable, Sendable {
    public struct Line: Decodable, Identifiable, Sendable {
        public let agent: String
        public let role: String
        public let repos: [String: RepositoryAccess]?
        public let tools: [String]?
        public var id: String { agent }
    }
    /// One MCP server of the catalog: Fleet's own (`custom` false, today the GitHub server) or one that the owner
    /// added (owner feature `mcp`). It has a command with its arguments, or a URL. A server that the owner connects
    /// (`auth` `oauth`) also carries its connection: `connected`, its own name and tools, and a `problem`.
    public struct Tool: Decodable, Equatable, Sendable {
        public let title: String
        public let command: String?
        public let args: [String]?
        public let url: String?
        public let runtimes: [String]
        /// nil on a hub before the feature `mcp`: then every entry is Fleet's own.
        public let custom: Bool?
        /// `none`, `oauth` or `key`; nil on a hub before the feature `mcp`.
        public let auth: String?
        /// The session variables that the server needs, such as `GH_TOKEN` or an API key of the Secrets page.
        public let needs: [String]?
        public let connected: Bool?
        public let connected_at: Double?
        public let scopes: [String]?
        /// The name that the server gives itself, from the last check.
        public let server: String?
        /// The tool names of the last check.
        public let tools: [String]?
        /// When the access token of a server without a refresh token ends; nil for every other server.
        public let access_ends: Double?
        /// A refused refresh, or what is wrong with the hub's MCP file.
        public let problem: String?

        /// What the server runs, in one line: its command and arguments, or its URL.
        public var detail: String { url ?? ([command ?? ""] + (args ?? [])).joined(separator: " ") }
        public var isCustom: Bool { custom == true }
        public var kind: MCPAuth { MCPAuth(rawValue: auth ?? "none") ?? .none }
        /// True while the owner must still connect this server or give its key, so no session can load it.
        public var needsOwner: Bool { kind == .oauth && connected != true }
    }
    public struct GitHubApp: Decodable, Equatable, Sendable {
        public let app: Bool
        /// The App this hub holds. nil while there is none, and on a hub from before the feature.
        public let app_id: String?
        /// What is wrong with the hub's App file; nil while the file is not there.
        public let problem: String?
        /// True while the Needs-you item that asks for the App's new key is open (plan 13, item 4: the App key that the
        /// hub held gets a successor). nil on a hub from before it.
        public let renew: Bool?

        public init(app: Bool, app_id: String? = nil, problem: String? = nil, renew: Bool? = nil) {
            self.app = app; self.app_id = app_id; self.problem = problem; self.renew = renew
        }

        /// **The same fact as one mark.** The owner, 20 October 2026: "not even sentences, just a check or a cross,
        /// and on hover probably show the detail?" Whether his hub can sign for his agents is a yes-or-no fact.
        ///
        /// **Three states and not two.** A hub with no App at all and a hub holding a file it cannot use are not
        /// the same thing, and the page said the second one only in its footer, under a row that showed a seal: he
        /// had to add the two together himself. `nil` is a hub not read yet, which is never drawn as a pass.
        public static func mark(_ app: GitHubApp?) -> (state: MarkState, words: String) {
            guard let app else { return (.working, String(l10n: "Reading your hub")) }
            if app.app { return (.good, String(l10n: "In place")) }
            return app.problem == nil ? (.bad, String(l10n: "None yet")) : (.bad, String(l10n: "Not usable"))
        }

        /// **Whether to ask him for an App.** His hub has none that works, and Founderizer has read the hub: a
        /// hub not read yet asks for nothing, so no credential form appears before we know one is needed.
        ///
        /// This answer belongs here, with the three states, because it used to live in the page above the card —
        /// which took the whole card out of the view the moment a save succeeded, and with it the one line that
        /// tells him to delete the `.pem` file he had just downloaded.
        /// It also asks while the item for the App's new key is open, with the App in place (plan 13, item 4).
        public static func asksForOne(_ app: GitHubApp?) -> Bool { app.map { !$0.app || $0.renew == true } ?? false }

        /// The hub holds a file, usable or not, so a save takes that one's place rather than being the first.
        public static func holdsFile(_ app: GitHubApp?) -> Bool { app.map { $0.app || $0.problem != nil } ?? false }
    }
    public let db: String
    public let sha256: String
    public let lines: [Line]
    /// nil on a hub without the feature.
    public let tools: [String: Tool]?
    public let github: GitHubApp?

    /// The agents that have task sessions: workers and leads, in the hub's order. The manager has no repositories.
    public var agents: [Line] { lines.filter { $0.role != "manager" } }
    /// Every repository that an agent may use, sorted.
    public var repositories: [String] { Set(lines.flatMap { ($0.repos ?? [:]).keys }).sorted() }
    /// {agent: access} of one repository.
    public func access(_ repo: String) -> [String: RepositoryAccess] {
        Dictionary(uniqueKeysWithValues: lines.compactMap { line in line.repos?[repo].map { (line.agent, $0) } })
    }
    /// The agents that get one tool, in the hub's order.
    public func agents(of tool: String) -> [String] { lines.filter { $0.tools?.contains(tool) == true }.map(\.agent) }

    /// Fleet's own tools, by name: today the GitHub server.
    public var catalog: [(name: String, tool: Tool)] {
        (tools ?? [:]).filter { !$0.value.isCustom }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
    /// The MCP servers that the owner added, by name (owner feature `mcp`).
    public var servers: [(name: String, tool: Tool)] {
        (tools ?? [:]).filter(\.value.isCustom).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
    /// True while this name is free for a new server: Fleet's own names and `fleet` are the hub's.
    public func free(name: String) -> Bool { (tools ?? [:])[name] == nil && name != "fleet" }

    public func validate(database: String) throws {
        guard db == database, sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              lines.allSatisfy({ ($0.repos ?? [:]).keys.allSatisfy { Integrations.repository($0) == $0 } })
        else { throw HubError.invalidResponse }
    }
}

/// Every repository that the fleet's GitHub Apps reach, by account, as `GET /ui/github/repos` gives it (owner feature
/// `repo_picker`): the list that gives an agent its repositories. Each repository is `owner/name` in lower case, as
/// team.json keeps it; `problem` says what the hub could not read.
public struct RepositoryList: Decodable, Sendable {
    public struct Account: Decodable, Equatable, Sendable {
        /// As GitHub writes it, such as `AcmeCorp`.
        public let account: String
        public let repos: [String]

        public init(account: String, repos: [String]) { self.account = account; self.repos = repos }
    }
    public let db: String
    public let accounts: [Account]
    public let problem: String?

    public init(db: String, accounts: [Account], problem: String?) {
        self.db = db; self.accounts = accounts; self.problem = problem
    }

    /// An owner as GitHub writes it (`AcmeCorp`), from the owner as team.json keeps it (`acmecorp`); nil when no account
    /// of the list is that owner.
    public func account(_ owner: String) -> String? {
        accounts.first { $0.account.lowercased() == owner.lowercased() }?.account
    }

    /// **A reading that could not read every account keeps the accounts that the one before it had and it lacks**:
    /// the list does not lose an account that GitHub listed a minute ago because one App did not answer now, and its
    /// `problem` still says what could not be read. A whole reading replaces the one before.
    public func keeping(_ older: RepositoryList?) -> RepositoryList {
        guard problem != nil, let older, older.db == db else { return self }
        let read = Set(accounts.map { $0.account.lowercased() })
        return RepositoryList(db: db, accounts: accounts + older.accounts.filter { !read.contains($0.account.lowercased()) },
                              problem: problem)
    }

    public func validate(database: String) throws {
        guard db == database, accounts.allSatisfy({ account in
            account.repos.allSatisfy { Integrations.repository($0) == $0 && $0.hasPrefix(account.account.lowercased() + "/") }
        }) else { throw HubError.invalidResponse }
    }
}

extension RepositoryList.Account {
    /// The repositories of this account that a search shows: each whose name, without its owner, holds every word of
    /// the search, in any case; all of them for an empty search.
    public func shown(by search: String) -> [String] {
        let words = search.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return repos }
        return repos.filter { repo in
            let name = Integrations.name(repo).lowercased()
            return words.allSatisfy { name.contains($0) }
        }
    }

    /// The "N" of "N of M" beside the account's name: how many of its repositories the agent has or gets.
    public func chosen(held: Set<String>, picked: Set<String>) -> Int {
        repos.reduce(0) { $0 + (held.contains($1) || picked.contains($1) ? 1 : 0) }
    }
}

public enum Integrations {
    public static let feature = "integrations"
    /// The list that gives an agent its repositories (`GET /ui/github/repos`, and `POST /ui/team/repos` with `agent`).
    public static let pickerFeature = "repo_picker"

    /// A repository's name without its owner, as the list shows it under the owner's heading.
    public static func name(_ repo: String) -> String {
        repo.split(separator: "/", maxSplits: 1).last.map(String.init) ?? repo
    }

    /// The repositories of one agent, by owner and level, for its Can use (`AccessSettings`): an owner's repositories at
    /// one level are one row with their count once there are more than `few` of them (the owner's yes of 9 November 2026
    /// to the list as shown), and their own rows otherwise.
    public static func groups(_ repos: [String: RepositoryAccess], few: Int = 3) -> [RepositoryGroup] {
        struct Key: Hashable { let owner: String; let access: RepositoryAccess }
        let keyed = Dictionary(grouping: repos.keys) { Key(owner: String($0.prefix { $0 != "/" }), access: repos[$0] ?? .read) }
        func rank(_ access: RepositoryAccess) -> Int { RepositoryAccess.allCases.firstIndex(of: access) ?? 0 }
        return keyed.map { RepositoryGroup(owner: $0.key.owner, access: $0.key.access, repos: $0.value.sorted(),
                                           grouped: $0.value.count > few) }
            .sorted { ($0.owner, rank($0.access)) < ($1.owner, rank($1.access)) }
    }

    /// A GitHub repository as the hub keeps it, `owner/name` in lower case, or nil: an owner of 1 to 39 letters,
    /// digits and hyphens that does not start with a hyphen, and a name of 1 to 100 letters, digits, `.`, `_` and `-`.
    /// A pasted address of the repository on github.com is taken too.
    public static func repository(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://github.com/", "http://github.com/", "github.com/"] where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
        }
        if value.hasSuffix(".git") { value.removeLast(4) }
        if value.hasSuffix("/") { value.removeLast() }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].range(of: "^[a-z0-9][a-z0-9-]{0,38}$", options: .regularExpression) != nil,
              parts[1].range(of: "^[a-z0-9._-]{1,100}$", options: .regularExpression) != nil, parts[1] != ".", parts[1] != ".."
        else { return nil }
        return value
    }

    /// The access map of one repository after one agent's choice: nil removes that agent.
    public static func access(_ current: [String: RepositoryAccess], agent: String, to choice: RepositoryAccess?) -> [String: RepositoryAccess] {
        var result = current
        result[agent] = choice
        return result
    }

    /// The agents of one tool after one agent's chip: on adds it, off removes it. The hub's order is kept.
    public static func agents(_ current: [String], agent: String, on: Bool, order: [String]) -> [String] {
        let chosen = Set(current).union(on ? [agent] : []).subtracting(on ? [] : [agent])
        return order.filter(chosen.contains)
    }
}

/// An owner's repositories at one level, on one agent's Can use (`Integrations.groups`).
public struct RepositoryGroup: Equatable, Sendable {
    public let owner: String
    public let access: RepositoryAccess
    public let repos: [String]
    /// One row with the count, which opens to the repositories; false: each repository is its own row.
    public let grouped: Bool
    public var id: String { "\(owner)/\(access.rawValue)" }
}

/// The owner's own GitHub App, as the form takes it before anything is sent. The hub checks all of this again,
/// and it is the one that proves the key can sign; this is only what a person should not have to be told twice.
public enum GitHubAppForm {
    public static let feature = "github_app"

    /// The App ID as GitHub shows it: 1 to 12 digits, with the spaces around it ignored. nil when it is not one.
    public static func appID(_ given: String) -> String? {
        let id = given.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.range(of: "^[0-9]{1,12}$", options: .regularExpression) != nil ? id : nil
    }

    /// One PEM private key block and nothing else, which is what GitHub downloads: 128 to 16,384 characters, one
    /// BEGIN and one END of the same kind, and base64 between them.
    public static func isPrivateKey(_ given: String) -> Bool {
        let key = given.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (128...16_384).contains(key.count) else { return false }
        let kinds = ["RSA PRIVATE KEY", "PRIVATE KEY"]
        guard let kind = kinds.first(where: { key.hasPrefix("-----BEGIN \($0)-----") }) else { return false }
        guard key.hasSuffix("-----END \(kind)-----") else { return false }
        let body = key.dropFirst("-----BEGIN \(kind)-----".count).dropLast("-----END \(kind)-----".count)
        let inside = body.filter { !$0.isWhitespace }
        return !inside.isEmpty && inside.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=" }
    }

    /// What this Mac says about a key the owner chose, before it travels, or nil when it may go.
    public static func problem(appID: String, key: String) -> String? {
        if GitHubAppForm.appID(appID) == nil { return String(l10n: "The App ID is the number at the top of your App's page.") }
        if !isPrivateKey(key) { return String(l10n: "Choose the .pem file GitHub downloaded when you generated the key.") }
        return nil
    }
}

/// The receipt of `POST /ui/github-app`. It carries no key: the hub keeps only its SHA-256, and this app keeps
/// nothing of it at all.
public struct GitHubAppReceipt: Decodable, Sendable {
    public let ok: Bool
    public let request_id: String
    public let replayed: Bool?
    /// Whether the hub has a usable App file now.
    public let app: Bool?
    public let app_id: String?
    /// True when this save took the place of an App that was there.
    public let replaced: Bool?
}

/// The hub's answer to `POST /ui/team/repos` and `POST /ui/team/tools`.
public struct IntegrationsReceipt: Decodable, Sendable {
    public let ok: Bool
    public let request_id: String
    public let client: String
    public let sha256: String
    public let changed: Bool
}

/// `GET /ui/team` for this page, and its two writes: who may use one repository, and which agents get one tool. Each
/// write goes against the team.json version that the page read (`base_sha256`). A write that gets no answer can have
/// arrived; the next one, from a new reading, is safe, because the hub refuses an old version (409).
public final class IntegrationsClient: Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60        // the hub commits and pushes team.json before it answers
        configuration.timeoutIntervalForResource = 90
        session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }

    public func read(hub: URL, database: String) async throws -> IntegrationsSnapshot {
        var parts = URLComponents(url: hub.appendingPathComponent("ui/team"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "db", value: database)]
        var request = URLRequest(url: parts.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let snapshot = try JSONDecoder().decode(IntegrationsSnapshot.self, from: await perform(request))
        try snapshot.validate(database: database)
        return snapshot
    }

    /// Who may use `repo`: an agent that `access` does not name loses it, and an empty map removes the repository.
    public func saveRepository(hub: URL, database: String, client: String, sha256: String, repo: String,
                               access: [String: RepositoryAccess]) async throws -> IntegrationsReceipt {
        try await write("ui/team/repos", hub: hub, database: database, client: client,
                        ["base_sha256": sha256, "repo": repo, "access": access.mapValues(\.rawValue)])
    }

    /// `GET /ui/github/repos` (owner feature `repo_picker`): every repository that the fleet's GitHub Apps reach.
    public func repositories(hub: URL, database: String) async throws -> RepositoryList {
        var parts = URLComponents(url: hub.appendingPathComponent("ui/github/repos"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "db", value: database)]
        var request = URLRequest(url: parts.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let list = try JSONDecoder().decode(RepositoryList.self, from: await perform(request))
        try list.validate(database: database)
        return list
    }

    /// One agent's access to each of `repos` (owner feature `repo_picker`): nil takes them away from it. Every other
    /// agent keeps what it holds, and the hub makes it one change.
    public func giveRepositories(hub: URL, database: String, client: String, sha256: String, repos: [String],
                                 agent: String, access: RepositoryAccess?) async throws -> IntegrationsReceipt {
        try await write("ui/team/repos", hub: hub, database: database, client: client,
                        ["base_sha256": sha256, "repo": repos, "agent": agent, "level": access?.rawValue ?? NSNull()])
    }

    /// The agents that get one tool of the catalog.
    public func saveTool(hub: URL, database: String, client: String, sha256: String, tool: String,
                         agents: [String]) async throws -> IntegrationsReceipt {
        try await write("ui/team/tools", hub: hub, database: database, client: client,
                        ["base_sha256": sha256, "tool": tool, "agents": agents])
    }

    /// `POST /ui/github-app` (owner feature `github_app`): the owner's own GitHub App on their own hub.
    ///
    /// The key is the whole `.pem` file GitHub downloaded. It is in this one request body and nowhere else: not in
    /// a log, not in a note, not in anything this app keeps, and the hub keeps only its SHA-256 in the owner's
    /// command record. The hub writes `~/.fleet/github-app.pem` on the customer's own machine, mode 600, and
    /// proves the key with `openssl` before it replaces a working one.
    public func saveGitHubApp(hub: URL, database: String, client: String, appID: String,
                              key: String) async throws -> GitHubAppReceipt {
        guard let appID = GitHubAppForm.appID(appID), GitHubAppForm.isPrivateKey(key) else {
            throw HubError.invalidResponse
        }
        return try await appCommand(hub: hub, database: database, client: client,
                                    ["app_id": appID, "key": key])
    }

    /// The same route with `delete`: the App file goes, and no agent gets a token until another one is saved.
    public func removeGitHubApp(hub: URL, database: String, client: String) async throws -> GitHubAppReceipt {
        try await appCommand(hub: hub, database: database, client: client, ["delete": true])
    }

    private func appCommand(hub: URL, database: String, client: String,
                            _ fields: [String: Any]) async throws -> GitHubAppReceipt {
        let requestID = UUID().uuidString.lowercased()
        var request = URLRequest(url: hub.appendingPathComponent("ui/github-app"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client, forHTTPHeaderField: "X-Fleet-Client")
        request.httpBody = try Self.body(fields, requestID: requestID, database: database)
        let receipt = try JSONDecoder().decode(GitHubAppReceipt.self, from: await perform(request))
        guard receipt.ok, receipt.request_id == requestID else { throw HubError.invalidResponse }
        return receipt
    }

    private func write(_ route: String, hub: URL, database: String, client: String, _ fields: [String: Any]) async throws -> IntegrationsReceipt {
        let requestID = UUID().uuidString.lowercased()
        var request = URLRequest(url: hub.appendingPathComponent(route))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client, forHTTPHeaderField: "X-Fleet-Client")
        request.httpBody = try Self.body(fields, requestID: requestID, database: database)
        let receipt = try JSONDecoder().decode(IntegrationsReceipt.self, from: await perform(request))
        guard receipt.ok, receipt.request_id == requestID, receipt.client == client else { throw HubError.invalidResponse }
        return receipt
    }

    static func body(_ fields: [String: Any], requestID: String, database: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: fields.merging(["request_id": requestID, "db": database]) { _, new in new },
                                   options: [.sortedKeys])
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

private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
