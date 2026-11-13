import Foundation
import Security
#if os(macOS)
import Network
#endif

/// **A GitHub App of the owner's own, made with GitHub's manifest flow** (DevOps plan 13, item 4, and plan 2.20; the
/// customer's path of PRODUCT.md 4.6).
///
/// A private App reaches only the account that made it, so an account where agents hold repositories and that no App
/// of the door reaches needs one of its own. The hub tells the manager, the manager raises one Needs-you item that
/// names that account (`OwnerNeed.github_app`), and the owner's press of its first option on this Mac starts this:
/// GitHub's own page that makes the App with its permissions filled in, GitHub's return to a loopback address of this
/// Mac with a one-time code, GitHub's answer to that code with the App's key, which goes to the door, and GitHub's own
/// page that installs the App. Nothing of Founderizer's shows: the one page of this Mac that the browser opens has no
/// words, and it gives GitHub the form at once. The key is in memory only, for the steps that give it to the door.
public enum GitHubManifest {
    public enum Failure: LocalizedError, Equatable, Sendable {
        case refused(Int), answer

        public var errorDescription: String? {
            switch self {
            case .refused(let status): return "GitHub did not answer the App's code (\(status))."
            case .answer: return "GitHub's answer about the new App was not one Founderizer reads."
            }
        }
    }

    /// What the door's forms and the hub's tokens need of an App: the tokens of each level (`GITHUB_ACCESS` of the
    /// hub and the door, and the issues that a token of each level reads and, from write, opens and comments on), the
    /// door's reads of runs, runners and alerts, and the secrets that it sets to a key it rotated. Webhooks stay off.
    /// Administration and Repository creation at write are the upper limit that the new-projects plan gives the door
    /// (N2, D2): only the door's own token for one call uses them, to make a repository or to register a runner.
    public static let permissions: [String: String] = [
        "actions": "write", "administration": "write", "contents": "write", "issues": "write", "metadata": "read",
        "pull_requests": "write", "repository_creation": "write", "secret_scanning_alerts": "read", "secrets": "write",
        "security_events": "read", "vulnerability_alerts": "read", "workflows": "write"]

    public static func isLogin(_ text: String) -> Bool {
        text.range(of: "^[A-Za-z0-9][A-Za-z0-9-]{0,38}$", options: .regularExpression) != nil
    }

    /// The App's name, at most 34 characters as GitHub allows: the account, the product, and four letters of chance,
    /// because a name is unique on GitHub and a second attempt must never meet the first one's.
    public static func name(owner: String, suffix: String) -> String {
        String(owner.prefix(17)) + " Founderizer " + String(suffix.prefix(4))
    }

    /// The manifest, as GitHub takes it in the form's one field: a private App with no webhook.
    public static func manifest(owner: String, redirect: URL, suffix: String) throws -> String {
        let object: [String: Any] = [
            "name": name(owner: owner, suffix: suffix), "url": "https://founderizer.com", "public": false,
            "redirect_url": redirect.absoluteString, "default_permissions": permissions, "default_events": [String]()]
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    /// GitHub's page that makes an App in this account, from the manifest that the form gives it.
    public static func newAppPage(owner: String, organization: Bool, state: String) -> URL {
        var parts = URLComponents(string: organization ? "https://github.com/organizations/\(owner)/settings/apps/new"
                                  : "https://github.com/settings/apps/new")!
        parts.queryItems = [URLQueryItem(name: "state", value: state)]
        return parts.url!
    }

    /// The one page of this Mac's: no words, and its form goes to GitHub as soon as the browser has it.
    public static func startPage(action: URL, manifest: String) -> String {
        "<!doctype html><html><head><meta charset=\"utf-8\"><title>GitHub</title></head>"
            + "<body onload=\"document.forms[0].submit()\"><form method=\"post\" action=\"\(escape(action.absoluteString))\">"
            + "<input type=\"hidden\" name=\"manifest\" value=\"\(escape(manifest))\"></form></body></html>"
    }

    /// GitHub's page that installs the App: he chooses the account's repositories there.
    public static func installPage(slug: String) -> URL? {
        guard slug.range(of: "^[a-z0-9][a-z0-9-]{0,99}$", options: .regularExpression) != nil else { return nil }
        return URL(string: "https://github.com/apps/\(slug)/installations/new")
    }

    /// GitHub's page of the account's Apps, where a flow that went wrong leaves him: GitHub's own, and no page of ours.
    public static func appsPage(owner: String, organization: Bool) -> URL {
        URL(string: organization ? "https://github.com/organizations/\(owner)/settings/apps"
            : "https://github.com/settings/apps")!
    }

    /// The account, as GitHub's public API names it: its login, its id and whether it is an organization.
    public struct Account: Decodable, Equatable, Sendable {
        public let login: String
        public let id: Int
        public let type: String
        public var isOrganization: Bool { type == "Organization" }
    }

    public static func account(_ login: String, session: URLSession = .shared) async throws -> Account {
        guard isLogin(login) else { throw Failure.answer }
        var request = URLRequest(url: URL(string: "https://api.github.com/users/\(login)")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.refused(status) }
        guard let account = try? JSONDecoder().decode(Account.self, from: data), isLogin(account.login),
              account.login.lowercased() == login.lowercased() else { throw Failure.answer }
        return account
    }

    /// GitHub's answer to the App's one-time code (`POST /app-manifests/{code}/conversions`): the App and its key.
    public struct Made: Decodable, Sendable {
        public struct Owner: Decodable, Equatable, Sendable { public let login: String }
        public let id: Int
        public let slug: String
        public let pem: String
        public let owner: Owner
    }

    public static func convert(code: String, session: URLSession = .shared) async throws -> Made {
        guard code.range(of: "^[A-Za-z0-9]{1,100}$", options: .regularExpression) != nil else { throw Failure.answer }
        var request = URLRequest(url: URL(string: "https://api.github.com/app-manifests/\(code)/conversions")!)
        request.httpMethod = "POST"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 201 else { throw Failure.refused(status) }
        guard let made = try? JSONDecoder().decode(Made.self, from: data), isLogin(made.owner.login),
              installPage(slug: made.slug) != nil, made.pem.contains("PRIVATE KEY") else { throw Failure.answer }
        return made
    }

    /// The code of GitHub's return to `/done`, when the request carries this flow's own state; nil for any other.
    public static func code(target: String, state: String) -> String? {
        guard let parts = URLComponents(string: "http://127.0.0.1" + target), parts.path == "/done" else { return nil }
        let items = parts.queryItems ?? []
        guard let code = items.first(where: { $0.name == "code" })?.value,
              let given = items.first(where: { $0.name == "state" })?.value,
              code.range(of: "^[A-Za-z0-9]{1,100}$", options: .regularExpression) != nil,
              Data(given.utf8).count == Data(state.utf8).count,
              zip(Data(given.utf8), Data(state.utf8)).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0 else { return nil }
        return code
    }

    /// A random value in hex: the state that guards the return, and the name's letters of chance.
    public static func random(bytes: Int) -> String {
        var data = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &data)
        return data.map { String(format: "%02x", $0) }.joined()
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

#if os(macOS)
/// **The loopback half of the manifest flow.** It listens on 127.0.0.1 only, so nothing on the network reaches it,
/// and it answers two requests of the browser: `GET /start` gives the page that sends GitHub its form, and
/// `GET /done?code=…&state=…` takes GitHub's return once, with this flow's own state, and sends the browser where
/// `done` says. Everything else gets an empty 404, and after the return it stops.
public final class GitHubManifestListener: @unchecked Sendable {
    public typealias Done = @Sendable (String) async -> URL

    private let state: String
    private var page = ""
    private let done: Done
    private let queue = DispatchQueue(label: "founderizer.github-manifest")
    private let lock = NSLock()
    private var listener: NWListener?
    private var returned = false

    public init(state: String, done: @escaping Done) {
        self.state = state
        self.done = done
    }

    /// The page that `/start` gives: it names this listener's own port as GitHub's return, so it comes after `start`.
    public func serve(_ page: String) {
        lock.lock(); self.page = page; lock.unlock()
    }

    /// Starts listening on a free port of 127.0.0.1, and answers that port.
    public func start() throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.take(connection) }
        listener.start(queue: queue)
        lock.lock(); self.listener = listener; lock.unlock()
        for _ in 0..<150 where (listener.port?.rawValue ?? 0) == 0 { usleep(20_000) }
        guard let port = listener.port?.rawValue, port != 0 else {
            stop()
            throw GitHubManifest.Failure.answer
        }
        return port
    }

    public func stop() {
        lock.lock(); let listener = self.listener; self.listener = nil; lock.unlock()
        listener?.cancel()
    }

    private func take(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] piece, _, _, _ in
            guard let self, let piece, let head = String(data: piece, encoding: .utf8),
                  let first = head.split(separator: "\r\n", maxSplits: 1).first else { return connection.cancel() }
            let parts = first.split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET" else { return self.answer(connection, status: 404) }
            let target = String(parts[1])
            if target == "/start" {
                self.lock.lock()
                let page = self.page
                self.lock.unlock()
                return page.isEmpty ? self.answer(connection, status: 404)
                    : self.answer(connection, status: 200, body: Data(page.utf8))
            }
            guard let code = GitHubManifest.code(target: target, state: self.state) else {
                return self.answer(connection, status: 404)
            }
            self.lock.lock()
            let again = self.returned
            self.returned = true
            self.lock.unlock()
            if again { return self.answer(connection, status: 404) }
            let done = self.done
            Task {
                let next = await done(code)
                self.answer(connection, status: 302, location: next)
                self.stop()
            }
        }
    }

    private func answer(_ connection: NWConnection, status: Int, body: Data = Data(), location: URL? = nil) {
        var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : status == 302 ? "Found" : "Not Found")\r\n"
        if let location { head += "Location: \(location.absoluteString)\r\n" }
        head += "Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\n"
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}
#endif
