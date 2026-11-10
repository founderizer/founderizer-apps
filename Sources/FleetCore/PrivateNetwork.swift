import Foundation

/// The owner's own private network (Tailscale), and the one credential that puts every machine of a fleet on it
/// without them opening a console again.
///
/// **What Tailscale allows, which is why this is shaped the way it is.** Their only credential that does not
/// expire is an *OAuth client*, made by hand in the admin console: it uses the client-credentials grant, it is
/// owned by the tailnet and not by a person, and there is no flow by which this app could ask Tailscale for one on
/// a customer's behalf. Their three-legged flow (an "OAuth app", in alpha) only works for users of the same
/// tailnet as the app, so a product cannot register one for its customers. **So a customer who connects the network
/// visits Tailscale once**, and after that this Mac makes what each machine needs (one who does not approves a link
/// for each server, `NetworkSignIn`):
///
///   - a key minted by an OAuth client **must carry a tag**, and a tag exists only once it stands in `tagOwners`
///     in the tailnet policy file. A new network has no tag, so this app writes the one it needs itself
///     (`PolicyFile`), keeping every other line and every comment of that file as it was;
///   - a tagged machine is what a server should be, and Tailscale turns key expiry off for it, so a fleet does not
///     fall off the network six months later;
///   - the key is single-use, pre-authorized, **not** ephemeral (ephemeral minutes are metered on the free plan)
///     and lives fifteen minutes, which is all an install needs.
///
/// The credential is a credential: it is kept in this Mac's own keychain, it never goes to the hub, it stands in no
/// argument and no file, and it is in every install's redaction list. Tailscale lets a client secret be used as an
/// auth key directly, so it is exactly as dangerous as a key and is treated so.
public enum PrivateNetwork {
    /// The tag every machine of a fleet carries.
    public static let tag = "tag:founderizer"
    /// The one page the customer opens, once. The console moved to this host; the old one was `login.tailscale.com`.
    public static let console = URL(string: "https://console.tailscale.com/admin/settings/trust-credentials")!
    /// Where a credential is ended, which the app offers beside its own "forget".
    public static let revokePage = PrivateNetwork.console
    /// Tailscale's own API. `-` means "the tailnet this credential belongs to", so no tailnet name is ever asked for.
    public static let api = URL(string: "https://api.tailscale.com")!
    /// How long a minted key may be used before it is worthless. An install uses it within seconds.
    public static let keyLifeSeconds = 900
    /// The same for a bare Mac, whose installer first installs what Tailscale needs, in minutes that nobody can name.
    public static let macKeyLifeSeconds = 7200
}

/// The one credential the customer pastes: the client id and the client secret of an OAuth client of their own
/// tailnet. Not `Codable` on purpose, so no general encoder can carry the secret into a draft, a log or the hub.
public struct NetworkCredential: Equatable, Sendable {
    public var clientID: String
    public var secret: String
    public init(clientID: String = "", secret: String = "") {
        self.clientID = clientID; self.secret = secret
    }

    private var trimmed: (id: String, secret: String) {
        (clientID.trimmingCharacters(in: .whitespacesAndNewlines),
         secret.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Why this cannot be a Tailscale credential, in the owner's own words, or nil. The shapes are Tailscale's own:
    /// a client id, and a secret that starts `tskey-client-`. Nothing here repeats a value.
    public var problem: String? {
        let fields = trimmed
        guard !fields.id.isEmpty else { return "Paste the client id from Tailscale." }
        guard fields.id.range(of: "^[A-Za-z0-9]{4,64}$", options: .regularExpression) != nil else {
            return "A client id is the short code beside the credential in Tailscale, letters and digits only."
        }
        guard !fields.secret.isEmpty else { return "Paste the client secret from Tailscale." }
        guard fields.secret.hasPrefix("tskey-client-"), fields.secret.count <= 256,
              fields.secret.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil else {
            return "A client secret starts with tskey-client-. Tailscale shows it once, when the credential is made."
        }
        return nil
    }

    public var isValid: Bool { problem == nil }

    /// Why the client id alone cannot be one, for a screen that checks it while it is typed. The secret is not
    /// looked at here, because it is still being pasted.
    public var clientIDProblem: String? {
        NetworkCredential(clientID: clientID, secret: "tskey-client-placeholder").problem
    }
    /// The id alone, which is safe to show and to keep: it opens nothing without the secret.
    public var shownID: String { trimmed.id }

    /// The two values as one line for this Mac's keychain, and back. No encoder sees the secret.
    public func stored() throws -> Data {
        guard isValid else { throw NetworkError.notACredential }
        return Data((trimmed.id + "\n" + trimmed.secret).utf8)
    }

    public init?(stored: Data) {
        let parts = String(decoding: stored, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        self.init(clientID: String(parts[0]), secret: String(parts[1]))
        guard isValid else { return nil }
    }
}

public enum NetworkError: LocalizedError, Equatable, Sendable {
    /// The credential is not of the shape Tailscale makes.
    case notACredential
    /// Tailscale did not accept the credential at all.
    case notAccepted
    /// Tailscale refused, in its own words.
    case refused(String)
    /// Tailscale could not be reached.
    case unreachable
    /// Tailscale answered something this app does not understand.
    case notUnderstood
    /// This app will not guess where the tag belongs in a policy file it cannot read.
    case policyNotUnderstood

    public var errorDescription: String? {
        switch self {
        case .notACredential: "Paste the client id and the client secret of the Tailscale credential."
        case .notAccepted: "Tailscale did not accept that credential. Make a new one and paste both halves again."
        case .refused(let says): "Tailscale refused: \(says)"
        case .unreachable: "Tailscale could not be reached from this Mac."
        case .notUnderstood: "Tailscale answered something this app does not understand."
        case .policyNotUnderstood:
            "This app did not change your Tailscale policy file, because it could not see where the tag belongs. "
                + "Add \(PrivateNetwork.tag) in Tailscale yourself, then try again."
        }
    }
}

/// What this Mac knows about the credential it holds.
public struct NetworkStanding: Equatable, Sendable {
    /// The credential works.
    public let accepted: Bool
    /// `tag:founderizer` stands in the tailnet policy file, so a key can carry it.
    public let tagReady: Bool
    public init(accepted: Bool, tagReady: Bool) { self.accepted = accepted; self.tagReady = tagReady }

    /// **The credential this Mac holds, as one mark.** `nil` is a Tailscale that was not asked or could not be
    /// reached, which says nothing about the credential and is therefore not a doubt: the mark says only that this
    /// Mac holds one.
    public static func mark(_ confirmed: NetworkStanding?) -> (state: MarkState, words: String) {
        guard let confirmed else { return (.good, "Held") }
        if !confirmed.accepted { return (.bad, "Not accepted") }
        return confirmed.tagReady ? (.good, "Ready") : (.warn, "Tag gone")
    }
}

/// Tailscale's API, as this app uses it: one token, one policy file, one key for one machine.
///
/// `exchange` is the one way out to the network, so every path here is proved without one.
public struct NetworkClient: Sendable {
    public typealias Exchange = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let exchange: Exchange

    public init(exchange: @escaping Exchange) { self.exchange = exchange }

    /// Tailscale over this Mac's own connection: nothing cached, no cookie, no redirect followed.
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        self.exchange = { request in
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw NetworkError.notUnderstood }
            return (data, http)
        }
    }

    // MARK: - The three things this app does

    /// Whether the credential still works and whether the tag is still there. Nothing is changed.
    ///
    /// A credential Tailscale refuses is an answer, not a failure: it is what a revoked credential looks like, and
    /// the screen says so. Everything else — a network that cannot be reached, an answer that makes no sense —
    /// still throws, because that is not the owner's doing.
    public func standing(_ credential: NetworkCredential) async throws -> NetworkStanding {
        let token: String
        do { token = try await self.token(credential) }
        catch NetworkError.notAccepted { return NetworkStanding(accepted: false, tagReady: false) }
        let policy = try await policy(token: token)
        return NetworkStanding(accepted: true, tagReady: PolicyFile.defines(PrivateNetwork.tag, in: policy.text))
    }

    /// Puts `tag:founderizer` in the tailnet policy file, once, and answers whether it had to write anything. A
    /// file that already has the tag is not written at all, and a file this app cannot read is left alone and said
    /// so. This is also what proves a credential: a credential Tailscale does not accept fails here, before
    /// anything is kept.
    ///
    /// The file is sent back as the HuJSON it came as, with one line inserted and an `If-Match` on what was read,
    /// so the owner's own rules and comments survive and a change somebody else made meanwhile is not overwritten.
    @discardableResult
    public func prepare(_ credential: NetworkCredential) async throws -> Bool {
        let token = try await token(credential)
        let policy = try await policy(token: token)
        guard !PolicyFile.defines(PrivateNetwork.tag, in: policy.text) else { return false }
        let owner = try? await owner(token: token)
        guard let written = PolicyFile.adding(PrivateNetwork.tag, owner: owner, to: policy.text) else {
            throw NetworkError.policyNotUnderstood
        }
        var request = URLRequest(url: PrivateNetwork.api.appendingPathComponent("api/v2/tailnet/-/acl"))
        request.httpMethod = "POST"
        request.setValue("application/hujson", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let tag = policy.etag { request.setValue(tag, forHTTPHeaderField: "If-Match") }
        request.httpBody = Data(written.utf8)
        _ = try await send(request)
        return true
    }

    /// One key for one machine: single-use, tagged, pre-authorized, not ephemeral, and worthless in fifteen
    /// minutes. The machine's name goes in the description, so the owner reads in Tailscale what each key was for.
    /// `tags` are the ones of the hub's join line for a server that joins a fleet (`NetworkSignIn.tags`), so a key and
    /// a sign-in link give it the same tags; a tag this app would not write itself is never sent.
    public func key(for machine: String, with credential: NetworkCredential,
                    life: Int = PrivateNetwork.keyLifeSeconds, tags: [String] = [PrivateNetwork.tag]) async throws -> String {
        let tags = !tags.isEmpty && tags.allSatisfy(PolicyFile.isTag) ? tags : [PrivateNetwork.tag]
        let token = try await token(credential)
        var request = URLRequest(url: PrivateNetwork.api.appendingPathComponent("api/v2/tailnet/-/keys"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "capabilities": ["devices": ["create": [
                "reusable": false, "ephemeral": false, "preauthorized": true, "tags": tags]]],
            "expirySeconds": life,
            "description": Self.description(for: machine)
        ], options: [.sortedKeys])
        let answer = try await send(request)
        guard let object = try? JSONSerialization.jsonObject(with: answer) as? [String: Any],
              let key = object["key"] as? String, Self.isKey(key) else { throw NetworkError.notUnderstood }
        return key
    }

    // MARK: - The pieces

    /// A one-hour access token from the client-credentials grant. Tailscale gives no longer one, by design.
    func token(_ credential: NetworkCredential) async throws -> String {
        guard credential.isValid else { throw NetworkError.notACredential }
        var request = URLRequest(url: PrivateNetwork.api.appendingPathComponent("api/v2/oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let form = ["grant_type=client_credentials",
                    "client_id=" + Self.formValue(credential.shownID),
                    "client_secret=" + Self.formValue(credential.secret)]
        request.httpBody = Data(form.joined(separator: "&").utf8)
        let (answer, http) = try await reach(request)
        // Only the two statuses that mean "not this credential" are read as that. A Tailscale that is down, or
        // that answers 500, says nothing about the credential, and must never be reported as a revoked one.
        guard !Self.notAcceptedStatuses.contains(http.statusCode) else { throw NetworkError.notAccepted }
        guard (200...299).contains(http.statusCode) else { throw Self.refusal(answer, http) }
        guard let object = try? JSONSerialization.jsonObject(with: answer) as? [String: Any],
              let token = object["access_token"] as? String, !token.isEmpty, token.count <= 512,
              !token.contains(where: { $0 == "\n" || $0 == "\r" }) else { throw NetworkError.notUnderstood }
        return token
    }

    /// The tailnet policy file as it stands, with the tag of what was read.
    func policy(token: String) async throws -> (text: String, etag: String?) {
        var request = URLRequest(url: PrivateNetwork.api.appendingPathComponent("api/v2/tailnet/-/acl"))
        request.setValue("application/hujson", forHTTPHeaderField: "Accept")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, http) = try await reach(request)
        guard (200...299).contains(http.statusCode) else { throw Self.refusal(data, http) }
        let etag = http.value(forHTTPHeaderField: "ETag")
        return (String(decoding: data, as: UTF8.self), etag)
    }

    /// The login name of the tailnet's owner, for the tag's owner line. A tag that nobody owns is owned by the
    /// tailnet's admins alone, which is enough, so this is a nicety and never a reason to fail.
    func owner(token: String) async throws -> String? {
        var request = URLRequest(url: PrivateNetwork.api.appendingPathComponent("api/v2/tailnet/-/users"))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let answer = try await send(request)
        guard let object = try? JSONSerialization.jsonObject(with: answer) as? [String: Any],
              let users = object["users"] as? [[String: Any]] else { return nil }
        let owners = users.filter { ($0["role"] as? String)?.lowercased() == "owner" }
        guard owners.count == 1, let name = owners[0]["loginName"] as? String, PolicyFile.isOwnerName(name) else {
            return nil
        }
        return name
    }

    /// One exchange, with a failure of the connection said as one. Every caller reads the status itself, because
    /// what a status means is not the same at the token endpoint as it is everywhere else.
    private func reach(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do { return try await exchange(request) }
        catch let error as NetworkError { throw error }
        catch { throw NetworkError.unreachable }
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, http) = try await reach(request)
        guard (200...299).contains(http.statusCode) else { throw Self.refusal(data, http) }
        return data
    }

    /// What Tailscale answers when the credential itself is the problem: OAuth's own `invalid_client`, which is a
    /// 400 or a 401 (RFC 6749 section 5.2). Nothing else is read as a credential that stopped working.
    static let notAcceptedStatuses = [400, 401]

    /// What Tailscale itself said, in one line, so a refusal is never guessed at. Nothing of the request is echoed.
    static func refusal(_ data: Data, _ http: HTTPURLResponse) -> NetworkError {
        var says = String(decoding: data, as: UTF8.self)
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            says = (object["message"] as? String) ?? (object["error_description"] as? String)
                ?? (object["error"] as? String) ?? says
        }
        says = says.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if says.count > 300 { says = String(says.prefix(300)) + "…" }
        return .refused(says.isEmpty ? "it answered \(http.statusCode) and said nothing." : says)
    }

    /// A key as Tailscale makes one: one line, and nothing of a shape this app would pass on by mistake.
    static func isKey(_ key: String) -> Bool {
        key.hasPrefix("tskey-") && key.count <= 512
            && key.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil
    }

    /// The machine's name as Tailscale shows it beside the key, within the length a description may have.
    static func description(for machine: String) -> String {
        let name = machine.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
        let said = "Founderizer: " + (name.isEmpty ? "a machine" : name)
        return said.count <= 50 ? said : String(said.prefix(50))
    }

    /// One form value. A credential has no character that needs escaping, and this makes sure of it.
    static func formValue(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

/// The tailnet policy file, which is HuJSON: JSON with comments and trailing commas. The owner's own rules are in
/// it, so this app reads it as text and inserts one line, instead of parsing it and writing a new file that would
/// lose every comment they wrote.
public enum PolicyFile {
    /// Whether `tagOwners` already defines this tag.
    public static func defines(_ tag: String, in text: String) -> Bool {
        read(text).tags.contains(tag.lowercased())
    }

    /// The same file with the tag added to `tagOwners`, and nothing else changed at all; nil when this app cannot
    /// see where it belongs, which is the one case it refuses to guess.
    ///
    /// `owner` is the login name that may use the tag. A tag with no owner belongs to the tailnet's admins, which
    /// is enough for the credential that made it, so nil is a fine answer.
    public static func adding(_ tag: String, owner: String?, to text: String) -> String? {
        guard isTag(tag) else { return nil }
        let owners = owner.flatMap { isOwnerName($0) ? "\"\($0)\"" : nil } ?? ""
        let found = read(text)
        if let body = found.tagOwners {
            var written = text
            written.insert(contentsOf: "\n\t\t\"\(tag)\": [\(owners)],", at: body)
            return written
        }
        guard let root = found.root else { return nil }
        var written = text
        written.insert(contentsOf: "\n\t\"tagOwners\": {\n\t\t\"\(tag)\": [\(owners)],\n\t},", at: root)
        return written
    }

    /// A tag as Tailscale writes one.
    public static func isTag(_ tag: String) -> Bool {
        tag.range(of: "^tag:[a-z0-9][a-z0-9-]{0,62}$", options: .regularExpression) != nil
    }

    /// A login name that may stand in the policy file. It goes into a file of the owner's, so nothing but a plain
    /// address is accepted.
    public static func isOwnerName(_ name: String) -> Bool {
        name.count <= 254
            && name.range(of: "^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$", options: .regularExpression) != nil
    }

    // MARK: - Reading HuJSON as text

    /// One pass over the file: where the root object opens, where `tagOwners` opens (the index just after its
    /// `{`), and the tags it defines. A `"tagOwners"` inside a comment, a value or a nested object is none of
    /// these, which is the whole reason this is read as text and not searched for.
    static func read(_ text: String) -> (root: String.Index?, tagOwners: String.Index?, tags: Set<String>) {
        var root: String.Index?
        var tagOwners: String.Index?
        var tags: Set<String> = []
        var braces = 0, brackets = 0
        /// The string that closed last, which a following `:` turns into a key.
        var lastString: (value: String, depth: Int)?
        /// The `:` after `"tagOwners"` was seen, so the next `{` opens its object.
        var expectingBody = false
        /// The depth of the inside of `tagOwners`, while this pass is in it.
        var inside: Int?
        var closed = false
        walk(text) { event in
            switch event {
            case .string(let value, let depth, _):
                lastString = (value, depth)
                return
            case .punctuation(let character, let index):
                defer { lastString = nil }
                switch character {
                case "{":
                    braces += 1
                    if braces == 1, brackets == 0, root == nil { root = text.index(after: index) }
                    if expectingBody, !closed {
                        tagOwners = text.index(after: index)
                        inside = braces
                        expectingBody = false
                    }
                case "}":
                    braces -= 1
                    expectingBody = false
                    if let depth = inside, braces < depth { inside = nil; closed = true }
                case "[":
                    brackets += 1
                    expectingBody = false
                case "]":
                    brackets -= 1
                case ":":
                    guard let last = lastString, brackets == 0 else { return }
                    if let depth = inside, braces == depth, last.depth == depth {
                        tags.insert(last.value.lowercased())
                    } else if tagOwners == nil, !closed, braces == 1, last.depth == 1,
                              last.value.lowercased() == "tagowners" {
                        expectingBody = true
                    }
                case ",":
                    expectingBody = false
                default: break
                }
            }
        }
        return (root, tagOwners, tags)
    }

    enum Event {
        /// A string literal that closed: its contents, the brace depth it stood at, and where it ended.
        case string(String, Int, String.Index)
        /// One character of structure, outside every string and comment.
        case punctuation(Character, String.Index)
    }

    /// Walks HuJSON once: strings, line comments and block comments are passed over, and everything else is
    /// reported where it stands. This is what keeps a `"tagOwners"` inside a comment or a value from being read as
    /// the key.
    static func walk(_ text: String, _ report: (Event) -> Void) {
        enum State { case code, string, escape, lineComment, blockComment, blockCommentStar }
        var state = State.code
        var depth = 0
        var literal = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            switch state {
            case .code:
                switch character {
                case "\"": state = .string; literal = ""
                case "/" where next < text.endIndex && text[next] == "/": state = .lineComment
                case "/" where next < text.endIndex && text[next] == "*": state = .blockComment
                default:
                    if character == "{" { depth += 1 }
                    if character == "}" { depth -= 1 }
                    if !character.isWhitespace { report(.punctuation(character, index)) }
                }
            case .string:
                switch character {
                case "\\": state = .escape
                case "\"":
                    state = .code
                    report(.string(literal, depth, index))
                default: literal.append(character)
                }
            case .escape:
                // Only what a key could hold is kept: an escape this app does not read keeps the string from
                // matching, which is the safe way round.
                literal.append(character)
                state = .string
            case .lineComment:
                if character == "\n" { state = .code }
            case .blockComment:
                if character == "*" { state = .blockCommentStar }
            case .blockCommentStar:
                if character == "/" { state = .code } else if character != "*" { state = .blockComment }
            }
            index = next
        }
    }
}
