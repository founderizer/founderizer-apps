import Foundation

/// How a server of the owner signs in (UI-API.md, "Custom MCP servers (owner feature `mcp`)"): nothing, the hub's own
/// Connect in the browser, or an API key of the Secrets page that the agent reads.
public enum MCPAuth: String, Codable, CaseIterable, Sendable {
    case none, oauth, key

    public var title: String {
        switch self {
        case .none: "No sign-in"
        case .oauth: "Connect in the browser"
        case .key: "An API key"
        }
    }
    public var subtitle: String {
        switch self {
        case .none: "A server that gives its tools to everybody"
        case .oauth: "You sign in once; the hub keeps the access and gives each task session a short-lived token"
        case .key: "A key of the Secrets page, which the agent reads in its sessions"
        }
    }
}

/// What a server runs: a remote server at an address, or a program of the agent's machine.
public enum MCPKind: String, CaseIterable, Sendable {
    case remote, local

    public var title: String { self == .remote ? "A remote server" : "A program on the server" }
}

/// One owner MCP server, as the hub takes it in `POST /ui/team/mcp`. It holds no secret: a `key` server names the
/// variable of an API key of the Secrets page, never its value.
public struct MCPServerSpec: Equatable, Sendable {
    public let title: String
    /// A remote server's address; nil for a program.
    public let url: String?
    public let command: String?
    public let args: [String]
    public let auth: MCPAuth
    /// For a url server with `auth` `key`: the variable name of the API key.
    public let key: String?
    /// For a program: {its own variable: the variable name of an API key}.
    public let env: [String: String]

    /// The `server` object of the write.
    public var object: [String: Any] {
        var object: [String: Any] = ["title": title]
        if let url {
            object["url"] = url
            if auth != .none { object["auth"] = auth.rawValue }
            if let key, auth == .key { object["key"] = key }
        } else {
            object["command"] = command ?? ""
            object["args"] = args
            if !env.isEmpty { object["env"] = env }
        }
        return object
    }
}

/// One owner MCP server as the owner writes it in the form, and the server that the hub takes.
public struct MCPDraft: Equatable, Sendable {
    public var title: String = ""
    public var kind: MCPKind = .remote
    /// For `remote`: the server's address.
    public var address: String = ""
    /// For `local`: the program and its arguments, as one line.
    public var command: String = ""
    public var auth: MCPAuth = .oauth
    /// For `auth` `key`: the variable name of the API key; for a program, its own variable gets that key.
    public var key: String = ""
    /// For a program with a key: the variable name that the program itself reads.
    public var variable: String = ""

    public init() {}

    /// The server for `POST /ui/team/mcp`, or nil while the form is not complete.
    public var server: MCPServerSpec? {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...60).contains(name.count), !name.contains("\n") else { return nil }
        switch kind {
        case .remote:
            guard let url = MCP.address(address) else { return nil }
            var named: String?
            if auth == .key {
                guard let variable = MCP.variable(key) else { return nil }
                named = variable
            }
            return MCPServerSpec(title: name, url: url, command: nil, args: [], auth: auth, key: named, env: [:])
        case .local:
            guard let words = MCP.program(command) else { return nil }
            var env: [String: String] = [:]
            if auth == .key {
                guard let key = MCP.variable(key), let own = MCP.variable(variable.isEmpty ? key : variable) else { return nil }
                env = [own: key]
            }
            return MCPServerSpec(title: name, url: nil, command: words.program, args: words.args, auth: .none,
                                 key: nil, env: env)
        }
    }

    /// The name that the hub will keep this server under, from the title; nil while the title gives none.
    public var name: String? { MCP.name(from: title) }
    /// True while the form is complete enough to send.
    public var isComplete: Bool { server != nil && name != nil }
    /// A program server signs in with a key or with nothing: the hub's Connect is for an address.
    public var choices: [MCPAuth] { kind == .remote ? MCPAuth.allCases : [.none, .key] }
}

public enum MCP {
    public static let feature = "mcp"

    /// A server's own published configuration, as the owner copies it from that server's page, turned into the form.
    /// Every shape in use is one object for the server, under `mcpServers` or `servers` or on its own:
    ///
    ///     {"mcpServers": {"notes": {"command": "npx", "args": ["-y", "notes-mcp"], "env": {"NOTES_TOKEN": "sk-…"}}}}
    ///     {"crm": {"url": "https://mcp.example.com/"}}
    ///
    /// **A value in the pasted text is never kept.** An `env` entry gives only its own variable name, which is what
    /// the program reads; which API key of the fleet goes into it stays the owner's choice, by name, because this
    /// app never holds a key. A pasted token is dropped on the floor here.
    public static func read(snippet: String) -> MCPDraft? {
        guard let data = snippet.data(using: .utf8), data.count <= 64_000,
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for wrapper in ["mcpServers", "servers"] {
            if let inner = top[wrapper] as? [String: Any], let draft = first(of: inner) { return draft }
        }
        if let draft = server(top, named: top["name"] as? String) { return draft }
        return first(of: top)
    }

    /// The first entry of a map of servers that this app can read.
    private static func first(of servers: [String: Any]) -> MCPDraft? {
        for key in servers.keys.sorted() {
            if let entry = servers[key] as? [String: Any], let draft = server(entry, named: key) { return draft }
        }
        return nil
    }

    private static func server(_ entry: [String: Any], named: String?) -> MCPDraft? {
        var draft = MCPDraft()
        draft.title = (entry["title"] as? String ?? entry["name"] as? String ?? named ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = entry["url"] as? String ?? entry["endpoint"] as? String {
            guard address(url) != nil else { return nil }
            draft.kind = .remote
            draft.address = url
            // What it signs in with is the owner's to say: a snippet cannot prove it, and a wrong guess would
            // either ask him for a key he does not need or skip one he does.
            draft.auth = .oauth
        } else if let command = entry["command"] as? String {
            let args = (entry["args"] as? [Any] ?? []).compactMap { $0 as? String }
            guard program(([command] + args).joined(separator: " ")) != nil else { return nil }
            draft.kind = .local
            draft.command = ([command] + args).joined(separator: " ")
            draft.auth = .none
            // Only the name of the variable the program reads, never what the snippet put in it.
            if let own = (entry["env"] as? [String: Any])?.keys.sorted().first, variable(own) != nil {
                draft.auth = .key
                draft.variable = own
            }
        } else {
            return nil
        }
        return draft.title.isEmpty ? nil : draft
    }

    /// The hub's name for a server, from its title: lower case, `a-z 0-9 -`, 1 to 31 characters, starting with a
    /// letter. nil when the title gives no such name.
    public static func name(from title: String) -> String? {
        var text = ""
        for character in title.lowercased() {
            if character.isASCII && (character.isLetter || character.isNumber) {
                text.append(character)
            } else if !text.isEmpty && !text.hasSuffix("-") {
                text.append("-")
            }
        }
        while text.hasSuffix("-") { text.removeLast() }
        while let first = text.first, !first.isLetter { text.removeFirst() }
        text = String(text.prefix(31))
        while text.hasSuffix("-") { text.removeLast() }
        return text.isEmpty ? nil : text
    }

    /// One server address as the hub takes it: `https` anywhere, `http` on `127.0.0.1` or `localhost`, with a host, no
    /// user part and no `#fragment`, at most 300 characters. A pasted address without a scheme gets `https://`.
    public static func address(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: \.isWhitespace) else { return nil }
        if !value.contains("://") { value = "https://" + value }
        guard value.count <= 300, let parts = URLComponents(string: value), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.scheme == "https" || (parts.scheme == "http" && (host == "127.0.0.1" || host == "localhost"))
        else { return nil }
        return value
    }

    /// One program line as the hub takes it: the name of a program (1 to 64 characters `A-Z a-z 0-9 . _ -`) and up to
    /// 16 arguments of visible characters. It is no shell line, so it takes no quotes and no `|`, `;`, `&` or `$`.
    public static func program(_ text: String) -> (program: String, args: [String])? {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let program = words.first, words.count <= 17,
              program.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil,
              words.dropFirst().allSatisfy({ argument in
                  (1...200).contains(argument.count) && argument.allSatisfy { $0.isASCII && !$0.isNewline }
                      && !argument.contains(where: { "\"'|;&$`<>".contains($0) })
              })
        else { return nil }
        return (program, Array(words.dropFirst()))
    }

    /// One variable name as the hub takes it: `A-Z 0-9 _`, starting with a letter, at most 60 characters, and not a
    /// name that a session sets itself.
    public static func variable(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard value.range(of: "^[A-Z][A-Z0-9_]{0,59}$", options: .regularExpression) != nil,
              value.range(of: "^(FLEET|BWS|LD|DYLD|ANTHROPIC|CLAUDE|CODEX)_|^(PATH|HOME|SHELL|USER|LOGNAME|TMPDIR|TERM|PWD|IFS|ENV|BASH_ENV|ZDOTDIR|NODE_OPTIONS|PYTHONPATH|PYTHONHOME)$",
                         options: .regularExpression) == nil
        else { return nil }
        return value
    }

    /// The loopback address of a Connect; the hub takes `http://127.0.0.1:<port>/` only.
    public static func redirectURI(port: UInt16) -> String { "http://127.0.0.1:\(port)/" }
}

/// What one Connect needs: the address to open in the owner's browser, and the `state` that must come back.
public struct MCPConnectStart: Sendable {
    public let url: URL
    public let state: String
    public let scopes: [String]
}

/// What the hub says after a Connect: the server's own name and its tools.
public struct MCPConnected: Sendable {
    public let name: String
    public let server: String?
    public let tools: [String]
    public let scopes: [String]
}

/// The writes of this page, without the command fields.
enum MCPCommand {
    case save(name: String, server: MCPServerSpec, sha256: String)
    case delete(name: String, sha256: String)
    /// `client`: the client that the owner registered himself, for a server that registers none.
    case connect(name: String, redirectURI: String, client: (id: String, secret: String?)?)
    case finish(state: String, code: String)
    case disconnect(name: String)

    var route: String {
        switch self {
        case .save, .delete: "ui/team/mcp"
        case .connect: "ui/mcp/connect"
        case .finish: "ui/mcp/finish"
        case .disconnect: "ui/mcp/disconnect"
        }
    }

    var fields: [String: Any] {
        switch self {
        case .save(let name, let server, let sha256): ["base_sha256": sha256, "name": name, "server": server.object]
        case .delete(let name, let sha256): ["base_sha256": sha256, "name": name, "delete": true]
        case .connect(let name, let redirectURI, let client):
            ["name": name, "redirect_uri": redirectURI].merging(client.map {
                ["client": ["client_id": $0.id, "client_secret": $0.secret].compactMapValues { $0 } as [String: Any]]
            } ?? [:]) { _, new in new }
        case .finish(let state, let code): ["state": state, "code": code]
        case .disconnect(let name): ["name": name]
        }
    }
}

/// The owner's MCP servers at the hub: one server added, changed or removed, and the Connect of one server. The page
/// reads `GET /ui/team` with `IntegrationsClient`, so this client only writes. A write that gets no answer can have
/// arrived; the next one, from a new reading, is safe, because the hub refuses an old version (409).
public final class MCPClient: Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60        // the hub talks to the server and commits team.json
        configuration.timeoutIntervalForResource = 120
        session = URLSession(configuration: configuration, delegate: NoMCPRedirect(), delegateQueue: nil)
    }

    /// One server added or changed. The hub keeps it under `name`.
    public func save(hub: URL, database: String, client: String, sha256: String, name: String,
                     server: MCPServerSpec) async throws {
        _ = try await write(.save(name: name, server: server, sha256: sha256), hub: hub, database: database, client: client)
    }

    /// One server removed, with the grants of every agent that had it and its saved connection.
    public func delete(hub: URL, database: String, client: String, sha256: String, name: String) async throws {
        _ = try await write(.delete(name: name, sha256: sha256), hub: hub, database: database, client: client)
    }

    public func connect(hub: URL, database: String, client: String, name: String, redirectURI: String,
                        own: (id: String, secret: String?)? = nil) async throws -> MCPConnectStart {
        let answer = try await write(.connect(name: name, redirectURI: redirectURI, client: own), hub: hub,
                                     database: database, client: client)
        guard let text = answer.url, let url = URL(string: text), let state = answer.state, !state.isEmpty,
              url.scheme == "https" || url.host == "127.0.0.1" || url.host == "localhost" else { throw HubError.invalidResponse }
        return MCPConnectStart(url: url, state: state, scopes: answer.scopes ?? [])
    }

    public func finish(hub: URL, database: String, client: String, state: String, code: String) async throws -> MCPConnected {
        let answer = try await write(.finish(state: state, code: code), hub: hub, database: database, client: client)
        guard let name = answer.name, answer.connected == true else { throw HubError.invalidResponse }
        return MCPConnected(name: name, server: answer.server, tools: answer.tools ?? [], scopes: answer.scopes ?? [])
    }

    public func disconnect(hub: URL, database: String, client: String, name: String) async throws {
        _ = try await write(.disconnect(name: name), hub: hub, database: database, client: client)
    }

    static func body(_ command: MCPCommand, requestID: String, database: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: command.fields.merging(
            ["request_id": requestID, "db": database]) { _, new in new }, options: [.sortedKeys])
    }

    private struct Receipt: Decodable {
        let ok: Bool
        let request_id: String
        let client: String
        let name: String?
        let url: String?
        let state: String?
        let scopes: [String]?
        let server: String?
        let tools: [String]?
        let connected: Bool?
        let changed: Bool?
    }

    private func write(_ command: MCPCommand, hub: URL, database: String, client: String) async throws -> Receipt {
        let requestID = UUID().uuidString.lowercased()
        var request = URLRequest(url: hub.appendingPathComponent(command.route))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client, forHTTPHeaderField: "X-Fleet-Client")
        request.httpBody = try Self.body(command, requestID: requestID, database: database)
        let receipt = try JSONDecoder().decode(Receipt.self, from: await perform(request))
        guard receipt.ok, receipt.request_id == requestID, receipt.client == client else { throw HubError.invalidResponse }
        return receipt
    }

    private func perform(_ request: URLRequest) async throws -> Data {
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

private final class NoMCPRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
