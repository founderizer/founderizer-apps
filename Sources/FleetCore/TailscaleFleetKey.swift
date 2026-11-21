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
///   1. **The key needs one thing of the policy file: the tag.** Tailscale makes no credential for a tag that nobody
///      owns, so `tag:founderizer` must stand in `tagOwners`. Only a tag that is missing from a file that this app may
///      not write is asked of the owner: one line, and where his file is kept (`PolicyPlace`). **What the fleet's
///      machines may reach is never asked of him here** (the owner, 13 November 2026, of the two wide grants that this
///      step asked a working policy for: "what is this?? not good!"). A file can give the fleet its reach with rules
///      that no reading of it sees (one device's address, a host's name, a group), so the connections themselves prove
///      it at the install: this Mac to the new server over SSH, and the new server to the hub (`FleetReach`).
///   2. **The policy file is changed only where no other tool keeps it.** A tailnet whose policy lives in a repository
///      (GitOps, Terraform) says so (`aclsExternallyManagedOn`), and such a file is never written, because the next run
///      of that tool would undo the change. A file that Tailscale keeps gets what it misses, and nothing else changes
///      (`FleetPolicy`): the tag and, unless the file lets everything reach everything, the two grants of what the
///      fleet uses. Tailscale checks the file before it is set, and it is set against the version that was read, so a
///      change somebody made meanwhile is not lost. A file whose own tests refuse the grants gets the tag alone, and
///      where the tag stands, a write of the grants that does not go through is no stop.
///   3. **The fleet key itself is an OAuth client of the owner's tailnet**: it never expires, it belongs to the tailnet
///      and not to a person, and it can only make keys for `tag:founderizer`, a tag that turns key expiry off for each
///      machine that carries it. Its id and its secret stay in this Mac's keychain.
///
/// After that, `mintAuthKey(hostname:)` makes one key for one machine: single-use, pre-authorized, tagged, not ephemeral
/// (ephemeral minutes are metered on the free plan), and worthless in fifteen minutes, or after the life that its caller
/// gives it (a cloud server's first boot: one hour, `CloudServers.joinKeyLife`; a bare Mac: two hours,
/// `PrivateNetwork.macKeyLifeSeconds`).
public struct TailscaleFleetKey: Sendable {
    /// The tag every machine of a fleet carries.
    public static let tag = "tag:founderizer"
    /// The page where the owner makes the access token, once.
    public static let keysPage = URL(string: "https://login.tailscale.com/admin/settings/keys")!
    /// Tailscale's own API. `-` is "the tailnet of this token", so no tailnet name is ever asked for.
    static let api = URL(string: "https://api.tailscale.com/api/v2")!
    /// What the owner's devices use of a fleet's machines: SSH, over which this Mac installs and restarts a server,
    /// the hub's own port, and the port from which every machine fetches the fleet's code (`git://`, 9418). A Mac that
    /// stays on is one of his devices, with no tag, and its join fetches the code as every server's does.
    public static let ports = ["tcp:22", "tcp:8765", "tcp:9418"]
    /// What a machine of the fleet uses of the hub: its own port, and the port of the fleet's code (join.sh stops
    /// without it). No machine of a fleet opens SSH to another one, so that port is not in it.
    public static let hubPorts = ["tcp:8765", "tcp:9418"]
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
    /// **Only the tag, the token and Tailscale itself can stop it.** A file with the tag in it gets the key, whoever
    /// keeps the file and whatever its rules are: the install proves the fleet's reach by its own connections
    /// (`FleetReach`). A policy file that another tool keeps is read and never written: when the tag is missing there,
    /// the answer carries that one line and the place of the file, and no key is made, because Tailscale refuses a
    /// credential for a tag that nobody owns. The owner adds the line and pastes a token again, and this goes on from
    /// the file as it then stands.
    public func connect(accessToken: String) async throws -> FleetKeySetup {
        let token = try Self.checkedToken(accessToken)
        let kept = try await settings(token)
        let place: PolicyPlace = kept.managed ? .tool(kept.link) : .tailscale
        /// The tag is the owner's to add: this app may not write the file, or cannot see where the line belongs in it.
        let asksForTag = FleetKeySetup(keyMade: false, wrotePolicy: false, linesToAdd: FleetPolicy.tagLine + ",", place: place)
        var wrote = false
        for attempt in 1...2 {
            let policy = try await policy(token)
            // A file this app cannot read is not this app's to guess at, and Tailscale itself knows whether the tag
            // stands in it: it makes the key, or it refuses it in its own words, which the page then says.
            guard let needs = FleetPolicy.needs(in: policy.text), !needs.isEmpty else { break }
            // Another tool keeps the file, or it cannot be set against the version that was read: a tag that stands
            // is all the fleet key needs, and a missing one is the owner's line.
            guard !kept.managed, let etag = policy.etag else {
                if needs.tag { return asksForTag }
                break
            }
            guard needs.tag else {
                // The tag stands, so the key needs nothing of this write. The grants go in where the file takes them:
                // a check that refuses them, a role that may not write the file and a file that changes twice
                // meanwhile leave the file as it is, and the install's own connections say whether its rules are enough.
                // A change meanwhile gets one more try, from the file as it is now, as every write of this step.
                guard let written = try? await taken(needs, into: policy.text, token: token),
                      let set = try? await set(written, etag: etag, token: token) else { break }
                if set { wrote = true; break }
                if attempt == 1 { continue }
                break
            }
            // No line of what it misses goes into the file: the tag is the owner's line.
            guard let written = try await taken(needs, into: policy.text, token: token) else { return asksForTag }
            if try await set(written, etag: etag, token: token) { wrote = true; break }
            // Somebody changed the file since it was read: once more from the file as it is now, and no further.
            guard attempt == 1 else { throw FleetKeyError.policyChangedMeanwhile }
        }
        try await makeKey(token)
        return FleetKeySetup(keyMade: true, wrotePolicy: wrote, linesToAdd: nil, place: place)
    }

    /// The file with what it misses, as Tailscale's own check takes it; nil when no line of it goes in. All of what it
    /// misses first. **A file whose own check refuses the grants gets the tag alone**: an owner who wrote tests that
    /// keep his fleet's ports closed (one who lets his own Mac in by its address, and nothing else) has said what his
    /// machines may reach, and the install's own connections then show whether that is enough. A check that refuses
    /// the tag's line too is said in Tailscale's own words, as before.
    func taken(_ needs: FleetPolicy.Needs, into text: String, token: String) async throws -> String? {
        if let whole = FleetPolicy.writing(needs, into: text) {
            guard let refusal = try await check(whole, token: token) else { return whole }
            guard !needs.grants.isEmpty else { throw FleetKeyError.refused(refusal) }
        }
        guard needs.tag, !needs.grants.isEmpty,
              let tagged = FleetPolicy.writing(FleetPolicy.Needs(tag: true, grants: []), into: text) else { return nil }
        if let refusal = try await check(tagged, token: token) { throw FleetKeyError.refused(refusal) }
        return tagged
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

    /// Tailscale's own check of a file, which changes nothing: a file that it would refuse is `FleetKeyError.refused`.
    func validate(_ text: String, token: String) async throws {
        if let refusal = try await check(text, token: token) { throw FleetKeyError.refused(refusal) }
    }

    /// Tailscale's own check of a file, which changes nothing: nil for a file that it takes, else its words for why it
    /// would refuse it. An empty answer is a file it takes; one that names errors (a rule it cannot read, or one of the
    /// file's own tests that fails) is one it would refuse, and warnings alone are no refusal. A check that Tailscale
    /// did not make at all (the token, the connection, its own failure) throws, and is no word about the file.
    func check(_ text: String, token: String) async throws -> String? {
        var request = request("tailnet/-/acl/validate", token: token, method: "POST")
        request.setValue("application/hujson", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(text.utf8)
        let data = try await send(request, token: token)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["message"] as? String, !message.isEmpty else { return nil }
        let found = (object["data"] as? [[String: Any]]) ?? []
        let errors = found.flatMap { ($0["errors"] as? [String]) ?? [] }
        if errors.isEmpty, found.contains(where: { $0["warnings"] != nil }) { return nil }
        // One line of Tailscale's own words, as every refusal is said (`refusal`).
        var says = Self.hidden(([message] + errors.prefix(1)).joined(separator: ": "), token)
            .trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        if says.count > 300 { says = String(says.prefix(300)) + "…" }
        return says
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

    /// One key for one machine, from the fleet key: single-use, pre-authorized, tagged, not ephemeral, and worthless after
    /// `life` seconds, fifteen minutes unless the caller says otherwise. The machine's name is in its description, so the
    /// owner reads in Tailscale what each key was for.
    public func mintAuthKey(hostname: String, life: Int = TailscaleFleetKey.keyLifeSeconds) async throws -> String {
        guard let client = shelf.read().flatMap(FleetClient.init(stored:)) else { throw FleetKeyError.noFleetKey }
        let access = try await accessToken(client)
        let body: [String: Any] = [
            "capabilities": ["devices": ["create": [
                "reusable": false, "ephemeral": false, "preauthorized": true, "tags": [Self.tag]]]],
            "expirySeconds": life,
            "description": Self.keyDescription(hostname),
        ]
        let (data, http) = try await reach(request("tailnet/-/keys", token: access, method: "POST", json: body))
        guard http.statusCode != 401 else { throw FleetKeyError.fleetKeyEnded }
        guard (200...299).contains(http.statusCode) else { throw Self.refusal(data, http, hiding: access) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = object["key"] as? String, Self.isAuthKey(key) else { throw FleetKeyError.notUnderstood }
        return key
    }

    /// **The machine that a server which this app made became in the owner's tailnet**, as Tailscale's own list of
    /// devices says with the fleet key: the newest authorized device that gave itself this name, carries the fleet's tag
    /// and was made since `since` (five minutes of slack, for a clock that is off). nil when the list has none: the
    /// server did not join. It is the first half of the proof that a server joined and that the policy keeps it from
    /// this Mac (`FleetReach.keeps`). A device of that name from an earlier try is older, and is not it.
    public func joined(hostname: String, since: Date) async throws -> JoinedDevice? {
        guard let client = shelf.read().flatMap(FleetClient.init(stored:)) else { throw FleetKeyError.noFleetKey }
        let access = try await accessToken(client)
        let (data, http) = try await reach(request("tailnet/-/devices", token: access))
        guard http.statusCode != 401 else { throw FleetKeyError.fleetKeyEnded }
        guard (200...299).contains(http.statusCode) else { throw Self.refusal(data, http, hiding: access) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = object["devices"] as? [[String: Any]] else { throw FleetKeyError.notUnderstood }
        let wanted = hostname.lowercased()
        guard !wanted.isEmpty else { return nil }
        let found = devices.compactMap { device -> (made: Date, device: JoinedDevice)? in
            // `hostname` is the name the machine gave itself, which is the one this app gave it. Its name in Tailscale
            // can be another one: Tailscale adds "-1" where a device of the tailnet has the name already.
            guard (device["hostname"] as? String)?.lowercased() == wanted, device["authorized"] as? Bool != false,
                  ((device["tags"] as? [String]) ?? []).contains(Self.tag),
                  let made = (device["created"] as? String).flatMap(Self.time), made >= since.addingTimeInterval(-300)
            else { return nil }
            let name = ((device["name"] as? String) ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let locked = !((device["tailnetLockError"] as? String) ?? "").isEmpty
            return (made, JoinedDevice(name: name, addresses: (device["addresses"] as? [String]) ?? [], locked: locked))
        }
        return found.max { $0.made < $1.made }?.device
    }

    /// **The devices of the owner's tailnet, as Tailscale's own list gives them with the fleet key**, for the one
    /// caller that removes a machine which this app made ("Start again", `StartAgain.device`). A device with no id is
    /// left out.
    public func devices() async throws -> [FleetDevice] {
        guard let client = shelf.read().flatMap(FleetClient.init(stored:)) else { throw FleetKeyError.noFleetKey }
        let access = try await accessToken(client)
        let (data, http) = try await reach(request("tailnet/-/devices", token: access))
        guard http.statusCode != 401 else { throw FleetKeyError.fleetKeyEnded }
        guard (200...299).contains(http.statusCode) else { throw Self.refusal(data, http, hiding: access) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = object["devices"] as? [[String: Any]] else { throw FleetKeyError.notUnderstood }
        return devices.compactMap { device in
            // Tailscale prefers a device's `nodeId` in a path; its numeric `id` is the older form of the same.
            guard let id = [device["nodeId"] as? String, device["id"] as? String].compactMap({ $0 }).first(where: Self.isDeviceID)
            else { return nil }
            return FleetDevice(id: id, hostname: (device["hostname"] as? String) ?? "",
                               name: ((device["name"] as? String) ?? "").lowercased()
                                   .trimmingCharacters(in: CharacterSet(charactersIn: ".")),
                               addresses: (device["addresses"] as? [String]) ?? [], tags: (device["tags"] as? [String]) ?? [],
                               created: (device["created"] as? String).flatMap(Self.time),
                               authorized: device["authorized"] as? Bool != false, external: device["isExternal"] as? Bool == true,
                               connected: device["connectedToControl"] as? Bool == true)
        }
    }

    /// **Removes one device from the tailnet by Tailscale's own id of it** (`DELETE /device/{id}`, which the scope
    /// `devices:core` of the fleet key allows), and nothing else: never a device by its name or its address. A
    /// device that Tailscale no longer has (404) is removed already.
    public func deleteDevice(id: String) async throws {
        guard Self.isDeviceID(id) else { throw FleetKeyError.notUnderstood }
        guard let client = shelf.read().flatMap(FleetClient.init(stored:)) else { throw FleetKeyError.noFleetKey }
        let access = try await accessToken(client)
        let (data, http) = try await reach(request("device/\(id)", token: access, method: "DELETE"))
        guard http.statusCode != 401 else { throw FleetKeyError.fleetKeyEnded }
        guard (200...299).contains(http.statusCode) || http.statusCode == 404 else { throw Self.refusal(data, http, hiding: access) }
    }

    /// A device's id as it may stand in a path: letters and digits only, the whole of it (a pattern's `$` also
    /// stands before a last line end).
    static func isDeviceID(_ id: String) -> Bool {
        (1...64).contains(id.utf8.count) && id.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
        }
    }

    /// A time as Tailscale's API writes one ("2026-11-13T21:04:05Z", with or without fractions of a second).
    static func time(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        let fractions = ISO8601DateFormatter()
        fractions.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: text) ?? fractions.date(from: text)
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

    func request(_ path: String, token: String, method: String = "GET", accept: String = "application/json",
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
    func reach(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do { return try await exchange(request) } catch { throw FleetKeyError.unreachable }
    }

    func send(_ request: URLRequest, token: String) async throws -> Data {
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
        return .refused(says.isEmpty ? String(l10n: "it answered \(http.statusCode) and said nothing.") : says)
    }

    static func hidden(_ text: String, _ secret: String) -> String {
        secret.count >= 8 ? text.replacingOccurrences(of: secret, with: String(l10n: "(not shown)")) : text
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
    /// The one line that the owner adds to `tagOwners` of his policy file himself, as policy text, because another tool
    /// keeps the file or this app could not see where the line belongs; nil when nothing is left for him to add.
    public let linesToAdd: String?
    /// Where his policy file is kept.
    public let place: PolicyPlace

    /// What the page says over `linesToAdd`: what the file misses, and where he adds it. Nil with no line to add.
    public var asks: String? { linesToAdd == nil ? nil : place.tagAsk }
}

/// **Where the owner's Tailscale policy file is kept**, as far as Tailscale itself says it: the place that this app
/// names when it asks him to change that file (the owner, 13 November 2026, of "Add these lines there": the line named
/// no place). The address of another tool's file is said as text, with no scheme and no query, and is no link.
public enum PolicyPlace: Equatable, Sendable {
    /// Tailscale keeps it: the Access controls page of its admin console.
    case tailscale
    /// Another tool keeps it (GitOps, Terraform), at this address when the tailnet's settings name one.
    case tool(URL?)

    /// The address of the other tool's file as he reads it: "github.com/example/tailnet-policy". Its host, its port and
    /// its path only, so nothing of a link's user, query or fragment shows. The link is a setting that any admin of the
    /// tailnet writes, and its words stand inside a sentence of this app's: so an address with anything but the plain
    /// characters of a host and a path (a space, a percent escape, a letter outside ASCII), or one too long for a line
    /// of a page, is none, and the words then name the tool.
    var address: String? {
        guard case .tool(let link?) = self, let host = link.host(percentEncoded: true), !host.isEmpty else { return nil }
        var path = link.path(percentEncoded: true)
        if path.hasSuffix("/") { path.removeLast() }
        let address = host + (link.port.map { ":\($0)" } ?? "") + path
        guard address.count <= 80,
              address.range(of: "^[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$", options: .regularExpression) != nil
        else { return nil }
        return address
    }

    /// The line over the tag's line on the key's page.
    public var tagAsk: String {
        let tag = TailscaleFleetKey.tag
        switch self {
        case .tailscale:
            return String(l10n: "Your Tailscale policy has no \(tag). Add this line to tagOwners on the Access controls page of Tailscale, then paste a key again.")
        case .tool:
            if let address {
                return String(l10n: "Your Tailscale policy has no \(tag). Add this line to tagOwners in \(address), then paste a key again.")
            }
            return String(l10n: "Your Tailscale policy has no \(tag). Add this line to tagOwners in the file of the tool that keeps your policy, then paste a key again.")
        }
    }

    // MARK: Kept on this Mac

    private static let key = "tailscale.policy.place"

    /// Keeps the place as the key's step read it, for a line of a later install. It is no secret: Tailscale shows the
    /// same address on its Access controls page.
    public func keep(in defaults: UserDefaults = AppDefaults.store) {
        switch self {
        case .tailscale: defaults.set("tailscale", forKey: Self.key)
        case .tool(let link): defaults.set(link.map { "tool " + $0.absoluteString } ?? "tool", forKey: Self.key)
        }
    }

    /// The place as the last key's step read it; nil on a Mac whose key is from before 13 November 2026.
    public static func kept(in defaults: UserDefaults = AppDefaults.store) -> PolicyPlace? {
        guard let value = defaults.string(forKey: key) else { return nil }
        if value == "tailscale" { return .tailscale }
        guard value == "tool" || value.hasPrefix("tool ") else { return nil }
        let link = URL(string: String(value.dropFirst(5))).flatMap { $0.scheme == "https" ? $0 : nil }
        return .tool(link)
    }
}

/// A server of the fleet as the owner's tailnet lists it (`TailscaleFleetKey.joined`): its full name there, its
/// addresses, and whether Tailnet Lock keeps it from its peers.
/// One device of the owner's tailnet, as Tailscale's list of devices gives it (`TailscaleFleetKey.devices`).
public struct FleetDevice: Equatable, Sendable {
    /// Tailscale's own id of the device, for a path.
    public let id: String
    /// The name that the machine gave itself, which for a server that this app made is the name that the app gave it.
    public let hostname: String
    /// Its name in the tailnet, in lower case and without the last dot.
    public let name: String
    public let addresses: [String]
    public let tags: [String]
    public let created: Date?
    public let authorized: Bool
    /// A device that another tailnet shared in: Tailscale deletes none of those.
    public let external: Bool
    /// Tailscale's own word that the device recently held its connection to Tailscale (`connectedToControl`): the
    /// machine behind it runs.
    public let connected: Bool

    public init(id: String, hostname: String, name: String = "", addresses: [String] = [], tags: [String] = [],
                created: Date?, authorized: Bool = true, external: Bool = false, connected: Bool = false) {
        self.id = id; self.hostname = hostname; self.name = name; self.addresses = addresses; self.tags = tags
        self.created = created; self.authorized = authorized; self.external = external; self.connected = connected
    }
}

public struct JoinedDevice: Equatable, Sendable {
    public let name: String
    public let addresses: [String]
    public let locked: Bool

    public init(name: String, addresses: [String], locked: Bool = false) {
        self.name = name; self.addresses = addresses; self.locked = locked
    }
}

/// **The two connections that a server of a fleet needs on the owner's private network, and the line for one that the
/// policy does not let through.** They are proved by the connections themselves and never by a reading of the policy
/// file: this Mac reaches the server over SSH (the wait for a server that its provider made, and the first SSH of a
/// check and of an install), and the server reaches the hub (join.sh, whose own line names the hub's two ports). A
/// line names what failed and asks for that reach alone, never for more, in the words of a grant's `ip` ("tcp:22").
public enum FleetReach {
    /// **Whether the policy keeps this server from this Mac**: the tailnet lists the server (`device`), and this Mac's
    /// own Tailscale (`status`, its `tailscale status --json`) runs in that same tailnet and shows no device with the
    /// server's name or one of its addresses. Tailscale shows a device only the machines that the policy lets it
    /// reach or be reached by, so that is a server which the policy gives this Mac no way to. Each other reason why
    /// this Mac does not see it is not the policy's: a Tailscale that is stopped, signed out or cut off from its
    /// network here (its list of devices is then an old one), a Mac in another tailnet than the fleet key's, a server
    /// that Tailnet Lock has not signed, and a server that this Mac does show, under any name and also offline. Read
    /// `status` after the tailnet's list, so that a server which joined between the two reads is in it.
    public static func keeps(_ device: JoinedDevice, from status: String) -> Bool {
        guard !device.locked, !device.name.isEmpty, let data = status.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["BackendState"] as? String == "Running", let own = object["Self"] as? [String: Any],
              own["Online"] as? Bool == true else { return false }
        func full(_ node: [String: Any]) -> String {
            ((node["DNSName"] as? String) ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        /// The tailnet's part of a full name: what follows its first label.
        func tailnet(_ name: String) -> String { name.split(separator: ".", maxSplits: 1).dropFirst().first.map(String.init) ?? "" }
        guard !tailnet(device.name).isEmpty, tailnet(full(own)) == tailnet(device.name) else { return false }
        let peers = (object["Peer"] as? [String: Any])?.values.compactMap { $0 as? [String: Any] } ?? []
        return !peers.contains { peer in
            full(peer) == device.name || !Set((peer["TailscaleIPs"] as? [String]) ?? []).isDisjoint(with: device.addresses)
        }
    }

    /// The server joined, and the policy keeps it from this Mac (`keeps`). A hub is also what the app itself talks to,
    /// so its line asks for the hub's port with SSH, and he changes his policy once. Each place has its whole
    /// sentence, so that another language can order its words.
    public static func hidden(_ server: String, hub: Bool = false, place: PolicyPlace? = PolicyPlace.kept()) -> String {
        let tag = TailscaleFleetKey.tag, ports = hub ? "tcp:22, tcp:8765" : "tcp:22"
        if let address = place?.address {
            return String(l10n: "\(server) is on your Tailscale network, but this Mac cannot reach it. Change your Tailscale policy in \(address) so that this Mac reaches \(tag) on \(ports).")
        }
        if case .tool = place {
            return String(l10n: "\(server) is on your Tailscale network, but this Mac cannot reach it. Change your Tailscale policy, which another tool keeps, so that this Mac reaches \(tag) on \(ports).")
        }
        return String(l10n: "\(server) is on your Tailscale network, but this Mac cannot reach it. Change your Tailscale policy so that this Mac reaches \(tag) on \(ports).")
    }

    /// The server joined, and this Mac's Tailscale does not show it online for another reason than the policy
    /// (`keeps` is false): the line says what is known, and where to look first.
    public static func unseen(_ server: String) -> String {
        String(l10n: "\(server) is on your Tailscale network, but Tailscale on this Mac does not show it online. Check that Tailscale on this Mac is connected to the same network.")
    }

    /// **The line for an SSH connection to an address on the private network that nothing answered**, or nil when
    /// `said` is not that. Tailscale drops what its policy does not allow, so `ssh` waits and gives up: its own line
    /// for this host ("ssh: connect to host 100.64.0.9 port 22: Operation timed out"), which names the port that the
    /// policy must let through. A server that is off gives the same line, so the words name both: they are the words
    /// of every server that did not answer (`ServerCheck.unreached(_:said:)`), with the policy in the place of the
    /// server's firewall, because on the private network the policy is what lets a connection in. A server that
    /// refused the connection or closed it did get it, an address outside the private network is no matter of the
    /// policy, and a line of another program on the server, or for another host, is not this connection.
    public static func dropped(_ said: String, host: String, place: PolicyPlace? = PolicyPlace.kept()) -> String? {
        let said = said.lowercased(), start = "ssh: connect to host \(host.lowercased()) port "
        guard ClaimCode.isPrivateAddress(host), said.hasPrefix(start), said.contains("timed out") else { return nil }
        let port = String(said.dropFirst(start.count).prefix { $0.isNumber })
        guard !port.isEmpty else { return nil }
        return unreached(host, port: port, place: place)
    }

    /// A server did not answer SSH at its address on the private network, on which the policy decides what arrives.
    static func unreached(_ server: String, port: String, place: PolicyPlace?) -> String {
        let ports = "tcp:" + port
        if let address = place?.address {
            return String(l10n: "\(server) did not answer SSH on port \(port). Check that the server is on, and that your Tailscale policy in \(address) lets this Mac reach it on \(ports).")
        }
        if case .tool = place {
            return String(l10n: "\(server) did not answer SSH on port \(port). Check that the server is on, and that your Tailscale policy, which another tool keeps, lets this Mac reach it on \(ports).")
        }
        return String(l10n: "\(server) did not answer SSH on port \(port). Check that the server is on, and that your Tailscale policy lets this Mac reach it on \(ports).")
    }
}

public enum FleetKeyError: LocalizedError, Equatable, Sendable {
    /// What was pasted is not an API access token.
    case notAnAccessToken
    /// Tailscale did not accept the token: it expired, or it was revoked.
    case tokenNotAccepted
    /// The token's user has a role that may not make the change that was asked: the policy file, the fleet key, or a
    /// device's tags.
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
            String(l10n: "This is not a Tailscale API access token. Make one on Tailscale's Keys page: it starts with tskey-api-.")
        case .tokenNotAccepted:
            String(l10n: "Tailscale did not accept this access token: it has expired or it was revoked. Make a new one on Tailscale's Keys page and paste it.")
        case .roleCannotWrite:
            String(l10n: "Your role in Tailscale cannot make this change. Use an access token of an Owner or an Admin of the tailnet.")
        case .rateLimited: String(l10n: "Tailscale asks this Mac to wait. Try again in a minute.")
        case .unreachable: String(l10n: "Tailscale could not be reached. Check this Mac's connection to the internet.")
        case .refused(let says): String(l10n: "Tailscale refused: \(says)")
        case .notUnderstood: String(l10n: "Tailscale answered something this app does not understand.")
        case .policyChangedMeanwhile:
            String(l10n: "Your Tailscale policy file changed while this app was adding to it. Try again.")
        case .noFleetKey: String(l10n: "This Mac has no key to your Tailscale network yet. Connect Tailscale first.")
        case .fleetKeyEnded:
            String(l10n: "Tailscale no longer accepts this Mac's key to your network: it was ended in Tailscale. Connect Tailscale again.")
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

/// **The tailnet policy file, as far as the fleet needs it**: what it misses, and the same file with those lines in it,
/// for a file that this app may write. The grants it reads are for that write alone: no reading of a file says what the
/// fleet may reach, so none is ever asked of the owner (`TailscaleFleetKey.connect`).
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
    }

    /// The tag, owned by the tailnet's admins, who are the people that can make the fleet key.
    static let tagLine = "\"\(TailscaleFleetKey.tag)\": [\"autogroup:admin\"]"
    /// What the fleet uses, and no more: the owner's devices reach its machines on SSH and on the hub's port, and its
    /// machines reach the hub, which carries the fleet's tag as they do, on its own port and on the port of the fleet's
    /// code. Until 13 November 2026 the second grant was SSH and the hub's port: no machine opens SSH to another one,
    /// and a join stopped at the fetch of the code in a tailnet that let nothing else through.
    static let grants = [Grant(src: TailscaleFleetKey.owners, dst: [TailscaleFleetKey.tag], ip: TailscaleFleetKey.ports),
                         Grant(src: [TailscaleFleetKey.tag], dst: [TailscaleFleetKey.tag], ip: TailscaleFleetKey.hubPorts)]

    /// What the file misses, or nil when this app cannot read it. A file that names `tagOwners` twice is one of those:
    /// which of the two a reader takes is not this app's to guess, and Tailscale itself says whether the tag stands
    /// when the key is made.
    static func needs(in text: String) -> Needs? {
        guard scan(Array(text.utf8))?.twice.contains("tagowners") != true else { return nil }
        return parsed(text).map(needs)
    }

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
    /// given back: a file that then still misses a line of `needs`, because this app's two readers of it did not agree,
    /// is not sent at all. What `needs` leaves out can still be missing: the tag alone goes into a file whose own
    /// tests refuse the grants. **A section that the file names twice is not written into**: a line in one of them
    /// may say nothing to the reader that takes the other, and which one the owner means is not this app's to guess.
    static func writing(_ needs: Needs, into text: String) -> String? {
        var bytes = Array(text.utf8)
        guard !needs.isEmpty, let found = scan(bytes) else { return nil }
        if needs.tag && found.twice.contains("tagowners") || !needs.grants.isEmpty && found.twice.contains("grants") { return nil }
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
        guard let left = parsed(written).map(Self.needs), !(needs.tag && left.tag),
              !needs.grants.contains(where: left.grants.contains) else { return nil }
        return written
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
    /// is why the file is read here and not searched. `twice`: the members that the object names more than once, of
    /// which `members` has the first.
    static func scan(_ bytes: [UInt8]) -> (root: Int, members: [String: (at: Int, opener: UInt8)], twice: Set<String>)? {
        var depth = 0
        var root: Int?
        var members: [String: (at: Int, opener: UInt8)] = [:]
        var twice: Set<String> = []
        /// A string at the object's own level, which a `:` turns into a member's name.
        var key: String?
        /// A member whose `:` was read, so its value starts next.
        var named: String?
        let ended = walk(bytes) { token in
            switch token {
            case .comment: break
            case .string(let range):
                if let name = named {
                    if members[name] == nil { members[name] = (range.lowerBound + 1, UInt8(ascii: "\"")) } else { twice.insert(name) }
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
                    if members[name] == nil { members[name] = (index + 1, byte) } else { twice.insert(name) }
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
        return (root, members, twice)
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
