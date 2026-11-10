import Foundation

/// One request to a provider's own API and its answer: Tailscale's, Hetzner's or DigitalOcean's, from this Mac. It is the
/// one way out to the network of `TailscaleFleetKey` and `CloudServers`, so every path of both is proved without one.
public typealias ProviderExchange = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

public enum ProviderConnection {
    /// One session for every provider (`HubClient.shared` says why one): nothing cached, no cookie, no stored
    /// credential, and no redirect followed, so a token goes to the host it was written for and to no other.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    /// The provider over this Mac's own connection.
    public static let live: ProviderExchange = { request in
        let (data, response) = try await ProviderConnection.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Where one credential of this Mac is kept: its keychain (`KeychainShelf`), or a test's own memory.
public protocol CredentialShelf: Sendable {
    func read() -> Data?
    func keep(_ data: Data) throws
}

/// One generic password of this app in this Mac's keychain, kept the way the owner key is (`FleetKeychainItem`): on this
/// Mac only, never in iCloud, and touched by the app as its Developer ID signed it and by no other copy. A credential of
/// the Mac's own exists before any fleet does, so the item is named by what it holds and not by a fleet.
public struct KeychainShelf: CredentialShelf {
    let item: FleetKeychainItem
    let account: String

    public init(service: String, account: String, label: String) {
        item = FleetKeychainItem(service: service, label: label)
        self.account = account
    }

    public func read() -> Data? { item.read(fleet: account) }
    public func keep(_ data: Data) throws { try item.keep(data, fleet: account) }
}

/// **The fleet's own lasting key to the owner's private network (Tailscale)**, made from one access token that he pastes
/// once, so that every server joins his network later with no approval to press and never falls off it.
///
/// He makes an API access token on Tailscale's Keys page (`keysPage`) and pastes it. This Mac makes what the fleet keeps
/// out of it, in three steps, and keeps nothing of the token itself:
///
///   1. **The policy file is changed only where no other tool keeps it.** A tailnet whose policy lives in a repository
///      (GitOps, Terraform) says so (`aclsExternallyManagedOn`), and such a file is never written, because the next run
///      of that tool would undo the change: the owner gets the exact lines to add there instead.
///   2. **What the fleet needs goes into the file, and nothing else changes** (`FleetPolicy`): `tag:founderizer` in
///      `tagOwners` and, unless the file lets everything reach everything, the grants that let the owner's devices reach
///      the fleet and its machines reach one another, on SSH and on the hub's port. Tailscale checks the file before it
///      is set, and it is set against the version that was read, so a change somebody made meanwhile is not lost.
///   3. **The fleet key itself is an OAuth client of the owner's tailnet**: it never expires, it belongs to the tailnet
///      and not to a person, and it can only make keys for `tag:founderizer`, a tag that turns key expiry off for each
///      machine that carries it. Its id and its secret stay in this Mac's keychain.
///
/// After that, `mintAuthKey(hostname:)` makes one key for one machine: single-use, pre-authorized, tagged, not ephemeral
/// (ephemeral minutes are metered on the free plan), and worthless in fifteen minutes.
public struct TailscaleFleetKey: Sendable {
    /// The tag every machine of a fleet carries.
    public static let tag = "tag:founderizer"
    /// The page where the owner makes the access token, once.
    public static let keysPage = URL(string: "https://login.tailscale.com/admin/settings/keys")!
    /// Tailscale's own API. `-` is "the tailnet of this token", so no tailnet name is ever asked for.
    static let api = URL(string: "https://api.tailscale.com/api/v2")!
    /// SSH, and the hub's own port.
    public static let ports = ["tcp:22", "tcp:8765"]
    /// The owner's devices, as the policy names them: the people who run the tailnet. Only an Owner or an Admin can make
    /// the fleet key, and both could give themselves this reach anyway, so the line gives nobody a reach he could not.
    public static let owners = ["autogroup:owner", "autogroup:admin"]
    /// What the fleet key may do: make keys for machines, and read and change the machines it made.
    static let scopes = ["auth_keys", "devices:core"]
    /// The fleet key's name in Tailscale's list of credentials.
    static let clientDescription = "Founderizer fleet"
    /// How long a minted key may be used before it is worthless. An install uses it within minutes.
    public static let keyLifeSeconds = 900
    /// Where the fleet key is kept.
    public static let keychain = KeychainShelf(service: "com.founderizer.tailscale.fleet-client", account: "fleet-client",
                                               label: "Tailscale fleet key")

    private let exchange: ProviderExchange
    private let shelf: any CredentialShelf

    public init(exchange: @escaping ProviderExchange = ProviderConnection.live,
                shelf: any CredentialShelf = TailscaleFleetKey.keychain) {
        self.exchange = exchange; self.shelf = shelf
    }

    /// Whether this Mac holds a fleet key.
    public var isHeld: Bool { shelf.read().flatMap(FleetClient.init(stored:)) != nil }

    // MARK: - Once: the token, the policy file, the fleet key

    /// Prepares the owner's tailnet and keeps the fleet key, from one access token that is used here and kept nowhere.
    ///
    /// A policy file that another tool keeps is read and never written: the answer then carries the lines to add, and the
    /// fleet key is made only once the tag stands, because Tailscale refuses a credential for a tag that nobody owns. The
    /// owner adds the lines and pastes a token again, and this goes on from the file as it then stands.
    public func connect(accessToken: String) async throws -> FleetKeySetup {
        let token = try Self.checkedToken(accessToken)
        let place = try await settings(token)
        var wrote = false
        for attempt in 1...2 {
            let policy = try await policy(token)
            guard let needs = FleetPolicy.needs(in: policy.text) else {
                // A file this app cannot read is not this app's to guess at: the owner gets every line.
                return FleetKeySetup(keyMade: false, wrotePolicy: false, linesToAdd: FleetPolicy.lines(for: .everything),
                                     managedAt: place.link)
            }
            if needs.isEmpty { break }
            guard !place.managed, let etag = policy.etag, let written = FleetPolicy.writing(needs, into: policy.text) else {
                // Another tool keeps the file, or this app cannot place the lines in it, or could not set it against the
                // version it read: the owner adds them. A tag that stands is all the fleet key needs.
                if !needs.tag { try await makeKey(token) }
                return FleetKeySetup(keyMade: !needs.tag, wrotePolicy: false, linesToAdd: FleetPolicy.lines(for: needs),
                                     managedAt: place.link)
            }
            try await validate(written, token: token)
            if try await set(written, etag: etag, token: token) { wrote = true; break }
            // Somebody changed the file since it was read: once more from the file as it is now, and no further.
            guard attempt == 1 else { throw FleetKeyError.policyChangedMeanwhile }
        }
        try await makeKey(token)
        return FleetKeySetup(keyMade: true, wrotePolicy: wrote, linesToAdd: nil, managedAt: nil)
    }

    /// The token as Tailscale makes one, or the reason it is not one. Nothing goes to Tailscale before this.
    static func checkedToken(_ given: String) throws -> String {
        let token = given.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.hasPrefix("tskey-api-"), token.count <= 256,
              token.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil else {
            throw FleetKeyError.notAnAccessToken
        }
        return token
    }

    /// Whether another tool keeps the policy file, and where, as Tailscale names it.
    func settings(_ token: String) async throws -> (managed: Bool, link: URL?) {
        let data = try await send(request("tailnet/-/settings", token: token), token: token)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FleetKeyError.notUnderstood
        }
        let managed = object["aclsExternallyManagedOn"] as? Bool ?? false
        let link = (object["aclsExternalLink"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        return (managed, managed ? link : nil)
    }

    /// The policy file as it stands, as the HuJSON the owner wrote, with the tag of the version that was read.
    func policy(_ token: String) async throws -> (text: String, etag: String?) {
        let (data, http) = try await reach(request("tailnet/-/acl", token: token, accept: "application/hujson"))
        guard (200...299).contains(http.statusCode) else { throw Self.failure(data, http, hiding: token) }
        return (String(decoding: data, as: UTF8.self), http.value(forHTTPHeaderField: "ETag"))
    }

    /// Tailscale's own check of a file, which changes nothing. An empty answer is a file it takes; one that names errors
    /// is one it would refuse, and warnings alone are no refusal.
    func validate(_ text: String, token: String) async throws {
        var request = request("tailnet/-/acl/validate", token: token, method: "POST")
        request.setValue("application/hujson", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(text.utf8)
        let data = try await send(request, token: token)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["message"] as? String, !message.isEmpty else { return }
        let found = (object["data"] as? [[String: Any]]) ?? []
        let errors = found.flatMap { ($0["errors"] as? [String]) ?? [] }
        if errors.isEmpty, found.contains(where: { $0["warnings"] != nil }) { return }
        throw FleetKeyError.refused(Self.hidden(([message] + errors.prefix(1)).joined(separator: ": "), token))
    }

    /// Sets the file against the version that was read. False when somebody changed it since (412).
    func set(_ text: String, etag: String, token: String) async throws -> Bool {
        var request = request("tailnet/-/acl", token: token, method: "POST")
        request.setValue("application/hujson", forHTTPHeaderField: "Content-Type")
        request.setValue(etag, forHTTPHeaderField: "If-Match")
        request.httpBody = Data(text.utf8)
        let (data, http) = try await reach(request)
        if http.statusCode == 412 { return false }
        guard (200...299).contains(http.statusCode) else { throw Self.failure(data, http, hiding: token) }
        return true
    }

    /// Makes the fleet key and keeps it. A key this Mac held before is replaced, and ended in Tailscale too: nothing but
    /// this Mac ever held its secret. A key that the keychain will not keep is ended at once, because a credential that
    /// never expires and that nobody holds is one credential too many.
    func makeKey(_ token: String) async throws {
        let before = shelf.read().flatMap(FleetClient.init(stored:))
        let body: [String: Any] = ["keyType": "client", "description": Self.clientDescription, "scopes": Self.scopes,
                                   "tags": [Self.tag]]
        let data = try await send(request("tailnet/-/keys", token: token, method: "POST", json: body), token: token)
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let id = object?["id"] as? String ?? ""
        guard let client = FleetClient(id: id, secret: object?["key"] as? String ?? "") else {
            if FleetClient.isID(id) { await end(id, token: token) }
            throw FleetKeyError.notUnderstood
        }
        do { try shelf.keep(client.stored) } catch {
            await end(client.id, token: token)
            throw error
        }
        if let before, before.id != client.id { await end(before.id, token: token) }
    }

    /// Ends one credential in Tailscale. It is tidying, so a failure of it is no failure of the step it follows.
    private func end(_ id: String, token: String) async {
        _ = try? await reach(request("tailnet/-/keys/\(id)", token: token, method: "DELETE"))
    }

    // MARK: - Each time: one key for one machine

    /// One key for one machine, from the fleet key: single-use, pre-authorized, tagged, not ephemeral, and worthless in
    /// fifteen minutes. The machine's name is in its description, so the owner reads in Tailscale what each key was for.
    public func mintAuthKey(hostname: String) async throws -> String {
        guard let client = shelf.read().flatMap(FleetClient.init(stored:)) else { throw FleetKeyError.noFleetKey }
        let access = try await accessToken(client)
        let body: [String: Any] = [
            "capabilities": ["devices": ["create": [
                "reusable": false, "ephemeral": false, "preauthorized": true, "tags": [Self.tag]]]],
            "expirySeconds": Self.keyLifeSeconds,
            "description": Self.keyDescription(hostname),
        ]
        let (data, http) = try await reach(request("tailnet/-/keys", token: access, method: "POST", json: body))
        guard http.statusCode != 401 else { throw FleetKeyError.fleetKeyEnded }
        guard (200...299).contains(http.statusCode) else { throw Self.refusal(data, http, hiding: access) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = object["key"] as? String, Self.isAuthKey(key) else { throw FleetKeyError.notUnderstood }
        return key
    }

    /// A one-hour access token from the fleet key, by OAuth's client-credentials grant. Only the two statuses that OAuth
    /// itself gives a client that is no more (RFC 6749 section 5.2) are read as that: a Tailscale that is down says
    /// nothing about the key.
    func accessToken(_ client: FleetClient) async throws -> String {
        var request = URLRequest(url: Self.api.appendingPathComponent("oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let form = ["grant_type=client_credentials", "client_id=" + Self.formValue(client.id),
                    "client_secret=" + Self.formValue(client.secret)]
        request.httpBody = Data(form.joined(separator: "&").utf8)
        let (data, http) = try await reach(request)
        guard ![400, 401].contains(http.statusCode) else { throw FleetKeyError.fleetKeyEnded }
        guard (200...299).contains(http.statusCode) else { throw Self.refusal(data, http, hiding: client.secret) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["access_token"] as? String, !token.isEmpty, token.count <= 512,
              !token.contains(where: { $0 == "\n" || $0 == "\r" }) else { throw FleetKeyError.notUnderstood }
        return token
    }

    /// The machine's name as Tailscale shows it beside the key: letters, digits, hyphens and spaces only, in at most 50
    /// characters, as Tailscale's API says a description may be.
    static func keyDescription(_ hostname: String) -> String {
        let name = String(hostname.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        return String(("Founderizer " + (name.isEmpty ? "server" : name)).prefix(50))
    }

    /// An auth key as Tailscale makes one: one line, and nothing of a shape this app would pass on by mistake.
    static func isAuthKey(_ key: String) -> Bool {
        key.hasPrefix("tskey-auth-") && key.count <= 512 && key.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil
    }

    // MARK: - The pieces

    private func request(_ path: String, token: String, method: String = "GET", accept: String = "application/json",
                         json body: [String: Any]? = nil) -> URLRequest {
        var request = URLRequest(url: Self.api.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        return request
    }

    /// One exchange, with a connection that does not come up said as one. Every caller reads the status itself.
    private func reach(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do { return try await exchange(request) } catch { throw FleetKeyError.unreachable }
    }

    private func send(_ request: URLRequest, token: String) async throws -> Data {
        let (data, http) = try await reach(request)
        guard (200...299).contains(http.statusCode) else { throw Self.failure(data, http, hiding: token) }
        return data
    }

    /// What a refusal of a request made with the owner's own token means: 401 is the token, 403 is his role.
    static func failure(_ data: Data, _ http: HTTPURLResponse, hiding secret: String) -> FleetKeyError {
        switch http.statusCode {
        case 401: .tokenNotAccepted
        case 403: .roleCannotWrite
        default: refusal(data, http, hiding: secret)
        }
    }

    /// Any other refusal: 429 is Tailscale asking this Mac to wait, and the rest is said in Tailscale's own words, in one
    /// line and with the secret taken out of them, so a refusal is never guessed at.
    static func refusal(_ data: Data, _ http: HTTPURLResponse, hiding secret: String) -> FleetKeyError {
        guard http.statusCode != 429 else { return .rateLimited }
        var says = String(decoding: data, as: UTF8.self)
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            says = (object["message"] as? String) ?? (object["error_description"] as? String)
                ?? (object["error"] as? String) ?? says
        }
        says = hidden(says, secret).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        if says.count > 300 { says = String(says.prefix(300)) + "…" }
        return .refused(says.isEmpty ? "it answered \(http.statusCode) and said nothing." : says)
    }

    static func hidden(_ text: String, _ secret: String) -> String {
        secret.count >= 8 ? text.replacingOccurrences(of: secret, with: "(not shown)") : text
    }

    /// One form value. A credential has no character that needs escaping, and this makes sure of it.
    static func formValue(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

/// What `connect` did, for the screen that follows it.
public struct FleetKeySetup: Equatable, Sendable {
    /// This Mac holds the fleet key now, so every server joins the network with no approval.
    public let keyMade: Bool
    /// This app changed the owner's policy file itself.
    public let wrotePolicy: Bool
    /// What the owner adds to his policy file himself, as policy text, because another tool keeps the file or this app
    /// could not see where the lines belong; nil when nothing is left for him to add.
    public let linesToAdd: String?
    /// Where that other tool keeps the policy, as Tailscale names it.
    public let managedAt: URL?
}

public enum FleetKeyError: LocalizedError, Equatable, Sendable {
    /// What was pasted is not an API access token.
    case notAnAccessToken
    /// Tailscale did not accept the token: it expired, or it was revoked.
    case tokenNotAccepted
    /// The token's user has a role that may not change the policy file or make credentials.
    case roleCannotWrite
    /// Tailscale asks this Mac to wait.
    case rateLimited
    /// Tailscale could not be reached.
    case unreachable
    /// Tailscale refused, in its own words.
    case refused(String)
    /// Tailscale answered something this app does not understand.
    case notUnderstood
    /// The policy file changed twice while this app wrote to it.
    case policyChangedMeanwhile
    /// This Mac holds no fleet key yet.
    case noFleetKey
    /// Tailscale no longer accepts the fleet key: it was ended there.
    case fleetKeyEnded

    public var errorDescription: String? {
        switch self {
        case .notAnAccessToken:
            "This is not a Tailscale API access token. Make one on Tailscale's Keys page: it starts with tskey-api-."
        case .tokenNotAccepted:
            "Tailscale did not accept this access token: it has expired or it was revoked. Make a new one on Tailscale's "
                + "Keys page and paste it."
        case .roleCannotWrite:
            "Your role in Tailscale cannot change the policy file. Use an access token of an Owner or an Admin of the "
                + "tailnet."
        case .rateLimited: "Tailscale asks this Mac to wait. Try again in a minute."
        case .unreachable: "Tailscale could not be reached. Check this Mac's connection to the internet."
        case .refused(let says): "Tailscale refused: \(says)"
        case .notUnderstood: "Tailscale answered something this app does not understand."
        case .policyChangedMeanwhile:
            "Your Tailscale policy file changed while this app was adding to it. Try again."
        case .noFleetKey: "This Mac has no key to your Tailscale network yet. Connect Tailscale first."
        case .fleetKeyEnded:
            "Tailscale no longer accepts this Mac's key to your network: it was ended in Tailscale. Connect Tailscale again."
        }
    }
}

/// The fleet key: the id and the secret of the OAuth client that this app made in the owner's tailnet. It is not
/// `Codable` on purpose, so no general encoder carries the secret into a draft, a log or the hub, and nothing that
/// prints it shows the secret.
struct FleetClient: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let id: String
    let secret: String

    init?(id: String, secret: String) {
        guard Self.isID(id), secret.hasPrefix("tskey-client-"), secret.count <= 256,
              secret.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil else { return nil }
        self.id = id; self.secret = secret
    }

    /// The two values as one line for this Mac's keychain, and back. No encoder sees the secret.
    init?(stored: Data) {
        let parts = String(decoding: stored, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        self.init(id: String(parts[0]), secret: String(parts[1]))
    }

    var stored: Data { Data((id + "\n" + secret).utf8) }

    static func isID(_ id: String) -> Bool { id.range(of: "^[A-Za-z0-9]{4,64}$", options: .regularExpression) != nil }

    var description: String { "FleetClient(\(id), secret not shown)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["id": id]) }
}

/// **The tailnet policy file, as far as the fleet needs it**: what it misses, the same file with those lines in it, and
/// the lines as text for a file that this app does not write.
///
/// The file is HuJSON (JSON with comments and trailing commas) and it holds the owner's own rules, so it is read as a
/// whole only to understand it, and it is changed only by inserting bytes into it. It is never written out anew: every
/// byte the owner wrote stays where it was, his comments and his layout with it.
enum FleetPolicy {
    /// One grant the fleet needs.
    struct Grant: Equatable, Sendable {
        let src: [String]
        let dst: [String]
        let ip: [String]

        /// As it stands in the file, on one line.
        var text: String {
            func list(_ values: [String]) -> String { "[" + values.map { "\"\($0)\"" }.joined(separator: ", ") + "]" }
            return "{\"src\": \(list(src)), \"dst\": \(list(dst)), \"ip\": \(list(ip))}"
        }
    }

    /// What one file misses of what the fleet needs.
    struct Needs: Equatable, Sendable {
        /// `tag:founderizer` is not in `tagOwners`.
        var tag: Bool
        /// The grants it has none of, or none that covers them.
        var grants: [Grant]
        var isEmpty: Bool { !tag && grants.isEmpty }
        static let everything = Needs(tag: true, grants: FleetPolicy.grants)
    }

    /// The tag, owned by the tailnet's admins, who are the people that can make the fleet key.
    static let tagLine = "\"\(TailscaleFleetKey.tag)\": [\"autogroup:admin\"]"
    /// The owner's devices reach the fleet, and its machines reach one another: SSH, and the hub's port.
    static let grants = [Grant(src: TailscaleFleetKey.owners, dst: [TailscaleFleetKey.tag], ip: TailscaleFleetKey.ports),
                         Grant(src: [TailscaleFleetKey.tag], dst: [TailscaleFleetKey.tag], ip: TailscaleFleetKey.ports)]

    /// What the file misses, or nil when this app cannot read it.
    static func needs(in text: String) -> Needs? { parsed(text).map(needs) }

    /// Keys of the policy are read as Tailscale reads them, whatever their case.
    static func needs(_ policy: [String: Any]) -> Needs {
        let members = lowered(policy)
        let owners = (members["tagowners"] as? [String: Any]) ?? [:]
        let tag = !owners.keys.contains { $0.lowercased() == TailscaleFleetKey.tag }
        guard !allowsAll(members) else { return Needs(tag: tag, grants: []) }
        let existing = objects(members["grants"])
        return Needs(tag: tag, grants: grants.filter { grant in !existing.contains { covers($0, grant) } })
    }

    /// Whether the file lets every device reach every other on every port, so a grant would add nothing. A file with
    /// neither `acls` nor `grants` does, by Tailscale's own rule; so does one with an accept from `*` to `*:*`, or a grant
    /// from `*` to `*` on `*`. A rule narrowed by a protocol, a posture or a route is not all.
    static func allowsAll(_ members: [String: Any]) -> Bool {
        let acls = members["acls"].flatMap { $0 is NSNull ? nil : $0 }
        let granted = members["grants"].flatMap { $0 is NSNull ? nil : $0 }
        if acls == nil && granted == nil { return true }
        if objects(acls).contains(where: { rule in
            (rule["action"] as? String)?.lowercased() == "accept" && rule["proto"] == nil && rule["srcposture"] == nil
                && (strings(rule["src"]) + strings(rule["users"])).contains("*")
                && (strings(rule["dst"]) + strings(rule["ports"])).contains("*:*")
        }) { return true }
        return objects(granted).contains { grant in
            grant["srcposture"] == nil && grant["via"] == nil && strings(grant["src"]).contains("*")
                && strings(grant["dst"]).contains("*") && strings(grant["ip"]).contains("*")
        }
    }

    /// Whether a grant of the file already gives all of what `grant` gives.
    static func covers(_ other: [String: Any], _ grant: Grant) -> Bool {
        let src = strings(other["src"]), dst = strings(other["dst"]), ip = strings(other["ip"])
        return other["srcposture"] == nil && other["via"] == nil
            && (src.contains("*") || grant.src.allSatisfy(src.contains))
            && (dst.contains("*") || grant.dst.allSatisfy(dst.contains))
            && grant.ip.allSatisfy { port in
                ip.contains("*") || ip.contains("tcp:*") || ip.contains(port) || ip.contains(String(port.dropFirst(4)))
            }
    }

    /// The file with what it misses inserted, and every byte it had still in it, in order; nil when this app cannot see
    /// where the lines belong, which is the one thing it will not guess at. A section that is there gets the lines at
    /// its start; one that is not is added at the start of the file's object. The result is read again before it is
    /// given back: a file that does not then say what the fleet needs (a key written twice, say) is not sent at all.
    static func writing(_ needs: Needs, into text: String) -> String? {
        var bytes = Array(text.utf8)
        guard !needs.isEmpty, let found = scan(bytes) else { return nil }
        var inserts: [(at: Int, text: String)] = []
        var atRoot = ""
        if needs.tag {
            let line = "\n\t\t" + tagLine + ","
            switch found.members["tagowners"] {
            case nil: atRoot += "\n\t\"tagOwners\": {" + line + "\n\t},"
            case let member? where member.opener == UInt8(ascii: "{"): inserts.append((member.at, line))
            default: return nil
            }
        }
        if !needs.grants.isEmpty {
            let lines = needs.grants.map { "\n\t\t" + $0.text + "," }.joined()
            switch found.members["grants"] {
            case nil: atRoot += "\n\t\"grants\": [" + lines + "\n\t],"
            case let member? where member.opener == UInt8(ascii: "["): inserts.append((member.at, lines))
            default: return nil
            }
        }
        if !atRoot.isEmpty { inserts.append((found.root, atRoot)) }
        for insert in inserts.sorted(by: { $0.at > $1.at }) {
            bytes.insert(contentsOf: Array(insert.text.utf8), at: insert.at)
        }
        let written = String(decoding: bytes, as: UTF8.self)
        guard let after = parsed(written), Self.needs(after).isEmpty else { return nil }
        return written
    }

    /// The same lines as text, for the owner to add himself, each in the section it belongs to; nil when the file has
    /// them all already.
    static func lines(for needs: Needs) -> String? {
        var sections: [String] = []
        if needs.tag { sections.append("\"tagOwners\": {\n\t" + tagLine + ",\n},") }
        if !needs.grants.isEmpty {
            sections.append("\"grants\": [\n" + needs.grants.map { "\t" + $0.text + ",\n" }.joined() + "],")
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n")
    }

    // MARK: - Reading HuJSON

    /// The file as one object, read the way Tailscale reads it, or nil.
    static func parsed(_ text: String) -> [String: Any]? {
        guard let json = standardized(Array(text.utf8)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(json))) as? [String: Any]
    }

    /// The file as plain JSON, for reading only: comments out, and a comma that only a closing bracket follows out.
    /// Strings are copied as they are. Nil when a string or a block comment never ends.
    static func standardized(_ bytes: [UInt8]) -> [UInt8]? {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var comma = false
        let ended = walk(bytes) { token in
            switch token {
            case .comment: break
            case .string(let range):
                if comma { out.append(UInt8(ascii: ",")); comma = false }
                out.append(contentsOf: bytes[range])
            case .byte(let index):
                let byte = bytes[index]
                if byte == UInt8(ascii: ",") {
                    if comma { out.append(byte) }       // two in a row stay, and the file fails to read as it should
                    comma = true
                } else if byte == UInt8(ascii: "]") || byte == UInt8(ascii: "}") {
                    comma = false
                    out.append(byte)
                } else if isSpace(byte) {
                    out.append(byte)
                } else {
                    if comma { out.append(UInt8(ascii: ",")); comma = false }
                    out.append(byte)
                }
            }
        }
        if comma { out.append(UInt8(ascii: ",")) }
        return ended ? out : nil
    }

    /// One pass over the file outside every string and comment: where its object opens (the offset just after the
    /// `{`), and where the value of each of that object's own members starts (just after its first byte), by the
    /// member's name in lower case. A `"grants"` inside a comment, a string or a nested object is none of these, which
    /// is why the file is read here and not searched.
    static func scan(_ bytes: [UInt8]) -> (root: Int, members: [String: (at: Int, opener: UInt8)])? {
        var depth = 0
        var root: Int?
        var members: [String: (at: Int, opener: UInt8)] = [:]
        /// A string at the object's own level, which a `:` turns into a member's name.
        var key: String?
        /// A member whose `:` was read, so its value starts next.
        var named: String?
        let ended = walk(bytes) { token in
            switch token {
            case .comment: break
            case .string(let range):
                if let name = named {
                    if members[name] == nil { members[name] = (range.lowerBound + 1, UInt8(ascii: "\"")) }
                    named = nil
                    key = nil
                } else {
                    key = depth == 1
                        ? String(decoding: bytes[(range.lowerBound + 1)..<(range.upperBound - 1)], as: UTF8.self).lowercased()
                        : nil
                }
            case .byte(let index):
                let byte = bytes[index]
                guard !isSpace(byte) else { return }
                if let name = named {
                    if members[name] == nil { members[name] = (index + 1, byte) }
                    named = nil
                }
                switch byte {
                case UInt8(ascii: ":"): named = depth == 1 ? key : nil
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                    if depth == 1, byte == UInt8(ascii: "{"), root == nil { root = index + 1 }
                case UInt8(ascii: "}"), UInt8(ascii: "]"): depth -= 1
                default: break
                }
                key = nil
            }
        }
        guard ended, depth == 0, let root else { return nil }
        return (root, members)
    }

    enum Token {
        /// A string with its quotes.
        case string(Range<Int>)
        case comment
        /// One byte outside every string and comment.
        case byte(Int)
    }

    /// Walks the file once: a string or a comment whole, everything else one byte at a time. False when a string or a
    /// block comment never ends. No byte of a character outside ASCII looks like a quote or a slash, so bytes are enough.
    static func walk(_ bytes: [UInt8], _ visit: (Token) -> Void) -> Bool {
        var index = 0
        while index < bytes.count {
            let next = index + 1 < bytes.count ? bytes[index + 1] : 0
            switch bytes[index] {
            case UInt8(ascii: "\""):
                var end = index + 1
                while end < bytes.count, bytes[end] != UInt8(ascii: "\"") {
                    end += bytes[end] == UInt8(ascii: "\\") ? 2 : 1
                }
                guard end < bytes.count else { return false }
                visit(.string(index..<(end + 1)))
                index = end + 1
            case UInt8(ascii: "/") where next == UInt8(ascii: "/"):
                while index < bytes.count, bytes[index] != UInt8(ascii: "\n") { index += 1 }
                visit(.comment)
            case UInt8(ascii: "/") where next == UInt8(ascii: "*"):
                var end = index + 2
                while end + 1 < bytes.count, !(bytes[end] == UInt8(ascii: "*") && bytes[end + 1] == UInt8(ascii: "/")) {
                    end += 1
                }
                guard end + 1 < bytes.count else { return false }
                visit(.comment)
                index = end + 2
            default:
                visit(.byte(index))
                index += 1
            }
        }
        return true
    }

    static func isSpace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
    }

    static func lowered(_ object: [String: Any]) -> [String: Any] {
        Dictionary(object.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    static func objects(_ value: Any?) -> [[String: Any]] {
        ((value as? [Any]) ?? []).compactMap { ($0 as? [String: Any]).map(lowered) }
    }

    static func strings(_ value: Any?) -> [String] {
        ((value as? [Any]) ?? []).compactMap { ($0 as? String)?.lowercased() }
    }
}
