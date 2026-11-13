import CryptoKit
import Foundation

/// **A server at a cloud provider, made from this Mac with one token that the owner pastes once**: the fleet's VPS, and
/// later the servers of its agents, at Hetzner Cloud, DigitalOcean, Vultr or Akamai (Linode before; the owner's yes of 9
/// November 2026 to the two after the first two).
///
/// What a server made here is, and why:
///
///   - **Ubuntu 24.04** (`ubuntu`), because the hub's own installer does not take 26.04 yet.
///   - **The cheapest type that fits what it is for, near this Mac.** At Hetzner, every type of Hetzner's own list that
///     has the memory the server check asks, where it is free now, cheapest first and, at one price, in the location
///     whose time zone is nearest the Mac's. At DigitalOcean, its smallest droplet for the use, in the nearest region
///     that has it. At Vultr and Akamai, as at Hetzner, every plan of their own list that fits, where it is free now.
///     The price is the provider's own, for this account.
///   - **On the owner's private network from its first boot.** Its cloud-init installs Tailscale with Tailscale's own
///     installer and joins once, under the name it was given (which is its name in Tailscale too), with a single-use key
///     that the fleet key minted for it (`TailscaleFleetKey.mintAuthKey`).
///   - **Behind a provider firewall with no inbound rule at all**, so the internet reaches no port of it: the fleet
///     reaches it over the private network only, and it reaches out freely.
///   - **With this app's own SSH key**, which is registered at the provider once and found again by its fingerprint.
///
/// A step that fails takes away what this call made, the server and its firewall, and leaves the SSH key, which the next
/// server uses again. The token stays in this Mac's keychain and goes to its provider and nowhere else.
public struct CloudServers: Sendable {
    public typealias Pause = @Sendable (Duration) async throws -> Void

    /// The one system every server made here runs.
    public static let ubuntu = "24.04"
    /// How often a server that is being made is read, and how many times at most, before it counts as not made.
    static let waitStep = Duration.seconds(3)
    static let waitReads = 100
    /// How many times a firewall that a deleted server still holds is asked to go.
    static let removeReads = 10

    public let provider: CloudProvider
    private let exchange: ProviderExchange
    private let shelf: any CredentialShelf
    private let zone: TimeZone
    private let pause: Pause

    /// `zone` is this Mac's, which says where the server goes; `pause` is the wait between two reads of a server that is
    /// being made, which a test does not wait.
    public init(provider: CloudProvider, exchange: @escaping ProviderExchange = ProviderConnection.live,
                shelf: (any CredentialShelf)? = nil, zone: TimeZone = .current,
                pause: @escaping Pause = { try await Task.sleep(for: $0) }) {
        self.provider = provider; self.exchange = exchange; self.shelf = shelf ?? provider.keychain
        self.zone = zone; self.pause = pause
    }

    /// Whether this Mac holds a token of this provider.
    public var isHeld: Bool { shelf.read().map { !$0.isEmpty } ?? false }

    // MARK: - Once: the token

    /// Checks a pasted token, that the provider takes it and that it may make things, and keeps it.
    ///
    /// Whether it may write is asked with a write that cannot make anything: an SSH key with no name and no key. A token
    /// that may write is told its input is wrong; one that may only read is refused for being one, before its input is
    /// read at all. Nothing is kept for a token that fails.
    public func connect(token pasted: String) async throws {
        let token = try provider.token(pasted)
        let call = CloudCall(provider: provider, token: token, exchange: exchange)
        switch provider {
        case .hetzner:
            _ = try await call.send("GET", "locations")
        case .digitalOcean:
            let account = try await call.send("GET", "account")["account"] as? [String: Any]
            if account?["status"] as? String == "locked" {
                let says = (account?["status_message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw CloudError.refused(provider, says.isEmpty ? String(l10n: "the account is locked.") : says)
            }
        case .vultr:
            // Vultr lets a user's key read the account only with the billing permission, so the write that follows,
            // which any key that may add things can make, is the whole check.
            break
        case .akamai:
            // Any token of the account may read its own profile, whatever products it was given.
            _ = try await call.send("GET", "profile")
        }
        for path in provider.writeProbes {
            let probe = try await call.answer("POST", path, body: [:])
            guard probe.ok || [400, 422].contains(probe.status) else { throw call.failure(probe) }
        }
        try shelf.keep(Data(token.utf8))
    }

    // MARK: - Each time: one server

    /// Makes one server and answers what it is: the provider's id of it, its public IPv4 address and what it costs a
    /// month. `name` becomes its name at the provider and in Tailscale; `publicKey` is this app's own SSH public key, as
    /// one line of `authorized_keys`; `authKey` is the single-use key it joins the private network with. `offer`: the
    /// server the owner was shown and said yes to (`offer(use:)`), which is then the only one tried; nil tries each
    /// offer in turn.
    public func createServer(name: String, use: CloudServerUse, publicKey: String, authKey: String,
                             offer: CloudOffer? = nil) async throws -> CloudServer {
        guard Self.isName(name) else { throw CloudError.notAServerName }
        guard let key = SSHPublicKey(publicKey) else { throw CloudError.notAPublicKey }
        guard TailscaleFleetKey.isAuthKey(authKey) else { throw CloudError.notAnAuthKey }
        let call = try heldCall()
        let made = Made(name: name, firewallName: Self.firewallName(name, at: provider))
        let userData = Self.userData(authKey: authKey, hostname: name)
        switch provider {
        case .hetzner: return try await hetzner(made, use: use, key: key, userData: userData, offer: offer, call)
        case .digitalOcean: return try await digitalOcean(made, use: use, key: key, userData: userData, offer: offer, call)
        case .vultr: return try await vultr(made, use: use, key: key, userData: userData, offer: offer, call)
        case .akamai: return try await akamai(made, use: use, key: key, userData: userData, offer: offer, call)
        }
    }

    /// A call with the token this Mac holds for this provider.
    private func heldCall() throws -> CloudCall {
        guard let token = shelf.read().map({ String(decoding: $0, as: UTF8.self) }), !token.isEmpty else {
            throw CloudError.noToken(provider)
        }
        return CloudCall(provider: provider, token: token, exchange: exchange)
    }

    // MARK: - Before a server is made: what it would be, and what the account holds already

    /// **The server this app would make, with what it costs a month**, for the step that asks before anything is made
    /// (the owner, 5 November 2026: "we can't be adding servers blindly, we need to ASK the user before these actions
    /// to confirm, they need to know!"). It is the first of the provider's offers now, and `createServer` given it makes
    /// that one or nothing.
    public func offer(use: CloudServerUse) async throws -> CloudOffer {
        let call = try heldCall()
        guard let first = try await offers(use, call).first else { throw CloudError.noRoom(provider) }
        return CloudOffer(provider: provider, type: first.type, location: first.location, cores: first.cores,
                          memoryGB: first.memoryGB, diskGB: first.diskGB, monthlyPrice: first.price, currency: first.currency)
    }

    /// Every offer of this provider for what the server is for, the one to show first first.
    private func offers(_ use: CloudServerUse, _ call: CloudCall) async throws -> [Offer] {
        switch provider {
        case .hetzner: try await hetznerOffers(use, call)
        case .digitalOcean: try await digitalOceanOffers(use, call)
        case .vultr: try await vultrOffers(use, call)
        case .akamai: try await akamaiOffers(use, call)
        }
    }

    /// **The servers that this provider's account holds already**, so one of them can be chosen in place of a new one
    /// (the owner, 5 November 2026: "the user might already have existing vps on hetzner/digital ocean accounts too, so
    /// they should be able to choose them"). A Hetzner token sees its own project only; a DigitalOcean token sees its
    /// team's servers in all its projects, and each says its project when the team has more than one. A Vultr key and an
    /// Akamai token see the whole account.
    public func servers() async throws -> [CloudExisting] {
        let call = try heldCall()
        switch provider {
        case .hetzner: return try await hetznerServers(call)
        case .digitalOcean: return try await digitalOceanServers(call)
        case .vultr: return try await vultrServers(call)
        case .akamai: return try await akamaiServers(call)
        }
    }

    /// Hetzner's servers, page by page (50 a page, at most 20 pages).
    private func hetznerServers(_ call: CloudCall) async throws -> [CloudExisting] {
        var found: [CloudExisting] = []
        var page = 1
        for _ in 0..<20 {
            let listed = try await call.send("GET", "servers", query: [URLQueryItem(name: "per_page", value: "50"),
                                                                      URLQueryItem(name: "page", value: String(page))])
            for server in (listed["servers"] as? [[String: Any]]) ?? [] {
                guard let id = server["id"] as? Int, let name = server["name"] as? String else { continue }
                let type = server["server_type"] as? [String: Any]
                let image = server["image"] as? [String: Any]
                // `location` since 2025; `datacenter.location` before it.
                let place = (server["location"] as? [String: Any])
                    ?? ((server["datacenter"] as? [String: Any])?["location"] as? [String: Any])
                let ipv4 = ((server["public_net"] as? [String: Any])?["ipv4"] as? [String: Any])?["ip"] as? String
                found.append(CloudExisting(
                    id: String(id), name: name, ipv4: ipv4.flatMap { Self.isIPv4($0) ? $0 : nil },
                    type: (type?["name"] as? String) ?? "",
                    memoryMB: (type?["memory"] as? NSNumber).map { Int(($0.doubleValue * 1024).rounded()) },
                    system: (image?["os_flavor"] as? String)?.lowercased(), version: image?["os_version"] as? String,
                    place: place?["city"] as? String, running: server["status"] as? String == "running", project: nil,
                    madeFor: (server["labels"] as? [String: Any])?["founderizer"] as? String))
            }
            let pages = (listed["meta"] as? [String: Any])?["pagination"] as? [String: Any]
            guard let next = pages?["next_page"] as? Int, next > page else { break }
            page = next
        }
        return found
    }

    /// DigitalOcean's droplets (up to 200), each with its project's name when the team has more than one project.
    private func digitalOceanServers(_ call: CloudCall) async throws -> [CloudExisting] {
        let listed = try await call.send("GET", "droplets", query: [URLQueryItem(name: "per_page", value: "200")])
        let projects = await digitalOceanProjects(call)
        return ((listed["droplets"] as? [[String: Any]]) ?? []).compactMap { droplet in
            guard let id = droplet["id"] as? Int, let name = droplet["name"] as? String else { return nil }
            let image = droplet["image"] as? [String: Any]
            let addresses = ((droplet["networks"] as? [String: Any])?["v4"] as? [[String: Any]]) ?? []
            let ipv4 = addresses.first(where: { $0["type"] as? String == "public" })?["ip_address"] as? String
            // "24.04 (LTS) x64" and "12 x64": the version is the first word.
            let version = (image?["name"] as? String)?.split(separator: " ").first.map(String.init)
            return CloudExisting(
                id: String(id), name: name, ipv4: ipv4.flatMap { Self.isIPv4($0) ? $0 : nil },
                type: (droplet["size_slug"] as? String) ?? "", memoryMB: droplet["memory"] as? Int,
                system: (image?["distribution"] as? String)?.lowercased(), version: version,
                place: (droplet["region"] as? [String: Any])?["name"] as? String,
                running: droplet["status"] as? String == "active", project: projects[String(id)], madeFor: nil)
        }
    }

    /// The project of each droplet, by the droplet's id, when the team has more than one project; empty when it has
    /// one, or when the token may not read projects, which leaves the list without them and nothing else.
    private func digitalOceanProjects(_ call: CloudCall) async -> [String: String] {
        let page = [URLQueryItem(name: "per_page", value: "200")]
        guard let listed = try? await call.send("GET", "projects", query: page),
              let projects = listed["projects"] as? [[String: Any]], projects.count > 1 else { return [:] }
        var names: [String: String] = [:]
        for project in projects {
            guard let id = project["id"] as? String, let name = project["name"] as? String,
                  let held = try? await call.send("GET", "projects/\(id)/resources", query: page) else { continue }
            for resource in (held["resources"] as? [[String: Any]]) ?? [] {
                guard let urn = resource["urn"] as? String, urn.hasPrefix("do:droplet:") else { continue }
                names[String(urn.dropFirst("do:droplet:".count))] = name
            }
        }
        return names
    }

    /// The server's first boot: Tailscale by Tailscale's own installer, and onto the owner's network once, under the
    /// server's own name. The key stands in the provider's metadata for that boot, which is why it is single-use and
    /// worthless in fifteen minutes. DNS stays the server's own, as every other install of the fleet leaves it.
    static func userData(authKey: String, hostname: String) -> String {
        ["#!/bin/sh",
         "curl -fsSL https://tailscale.com/install.sh | sh",
         "tailscale up --auth-key=\(authKey) --hostname=\(hostname) --accept-dns=false"].joined(separator: "\n") + "\n"
    }

    /// A server's name as the hub takes it, and as a host name may be: it must not end in a hyphen.
    static func isName(_ name: String) -> Bool {
        name.range(of: Servers.namePattern, options: .regularExpression) != nil && !name.hasSuffix("-")
    }

    /// The firewall's name: the server's, and six letters of chance, so a firewall that a crash left behind never stands
    /// in the way of the next one. Akamai takes a label of 32 characters at most, so its name is shorter.
    static func firewallName(_ name: String, at provider: CloudProvider = .hetzner) -> String {
        let chance = String((0..<6).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
        guard provider == .akamai else { return "founderizer-\(name)-" + chance }
        var cut = String(name.prefix(32 - "fz--".count - chance.count))
        while cut.hasSuffix("-") { cut.removeLast() }
        return "fz-\(cut)-" + chance
    }

    static func isIPv4(_ address: String) -> Bool {
        address.range(of: "^[0-9]{1,3}(\\.[0-9]{1,3}){3}$", options: .regularExpression) != nil
    }

    /// The offers to try: the one the owner said yes to, when it is still offered, and only that one; every offer when
    /// he was shown none.
    static func only(_ chosen: CloudOffer?, in offers: [Offer]) -> [Offer] {
        guard let chosen else { return offers }
        return offers.filter { $0.type == chosen.type && $0.location == chosen.location }
    }

    // MARK: - Hetzner Cloud

    /// The firewall first, so the server has it from its first boot; then the server, on the first offer the provider
    /// takes; then its creation, read until it ends.
    private func hetzner(_ made: Made, use: CloudServerUse, key: SSHPublicKey, userData: String, offer: CloudOffer?,
                         _ call: CloudCall) async throws -> CloudServer {
        let keyID = try await hetznerKey(key, call)
        let offers = Self.only(offer, in: try await hetznerOffers(use, call))
        guard !offers.isEmpty else { throw CloudError.noRoom(provider) }
        let firewall = try await call.send("POST", "firewalls", body: [
            "name": made.firewallName, "rules": [[String: Any]](), "labels": ["founderizer": use.rawValue]])
        guard let firewallID = (firewall["firewall"] as? [String: Any])?["id"] as? Int else {
            throw CloudError.notUnderstood(provider)
        }
        var made = made
        made.firewall = String(firewallID)
        do {
            for offer in offers {
                let answer = try await call.answer("POST", "servers", body: [
                    "name": made.name, "server_type": offer.type, "location": offer.location, "image": provider.image,
                    "ssh_keys": [keyID], "user_data": userData, "firewalls": [["firewall": firewallID]],
                    "labels": ["founderizer": use.rawValue], "start_after_create": true,
                    "public_net": ["enable_ipv4": true, "enable_ipv6": true]])
                // None free there after all, since the offers were read: the next offer.
                if answer.code == "resource_unavailable" || answer.code == "placement_error" { continue }
                guard answer.ok else { throw call.failure(answer) }
                guard let server = answer.object["server"] as? [String: Any], let id = server["id"] as? Int else {
                    throw CloudError.notUnderstood(provider)
                }
                made.server = String(id)
                let ipv4 = ((server["public_net"] as? [String: Any])?["ipv4"] as? [String: Any])?["ip"] as? String
                guard let ipv4, Self.isIPv4(ipv4), let action = (answer.object["action"] as? [String: Any])?["id"] as? Int
                else { throw CloudError.notUnderstood(provider) }
                try await hetznerWait(action: action, call)
                return CloudServer(provider: provider, id: String(id), name: made.name, ipv4: ipv4, type: offer.type,
                                   location: offer.location, monthlyPrice: offer.price, currency: offer.currency,
                                   firewallID: String(firewallID))
            }
            throw CloudError.noRoom(provider)
        } catch {
            throw await undo(made, after: error, call)
        }
    }

    /// The id of this app's SSH key at Hetzner: found by its fingerprint, or registered once.
    private func hetznerKey(_ key: SSHPublicKey, _ call: CloudCall) async throws -> Int {
        func found() async throws -> Int? {
            let listed = try await call.send("GET", "ssh_keys", query: [URLQueryItem(name: "fingerprint", value: key.fingerprint)])
            let keys = (listed["ssh_keys"] as? [[String: Any]]) ?? []
            return keys.first { $0["fingerprint"] as? String == key.fingerprint }?["id"] as? Int
        }
        if let id = try await found() { return id }
        let answer = try await call.answer("POST", "ssh_keys", body: [
            "name": key.name, "public_key": key.line, "labels": ["founderizer": "app"]])
        if answer.ok, let id = (answer.object["ssh_key"] as? [String: Any])?["id"] as? Int { return id }
        // Registered meanwhile, by another window of this app: it is the same key.
        if answer.code == "uniqueness_error", let id = try await found() { return id }
        throw answer.ok ? CloudError.notUnderstood(provider) : call.failure(answer)
    }

    /// Each of Hetzner's types that fits what the server is for, in each location where Hetzner has it free and not on its
    /// way out, cheapest first and, at one price, nearest first, with what it costs there a month: the type, and the
    /// public addresses it comes with, which Hetzner prices on their own. Hetzner's own list, not one of this app's,
    /// because its types change: on 5 November 2026 it had no CX or CAX type free anywhere, and new CPX types.
    private func hetznerOffers(_ use: CloudServerUse, _ call: CloudCall) async throws -> [Offer] {
        guard let pricing = try await call.send("GET", "pricing")["pricing"] as? [String: Any],
              let currency = pricing["currency"] as? String, !currency.isEmpty else { throw CloudError.notUnderstood(provider) }
        let addresses = ((pricing["primary_ips"] as? [[String: Any]]) ?? [])
            .filter { ["ipv4", "ipv6"].contains($0["type"] as? String) }
            .map { ($0["prices"] as? [[String: Any]]) ?? [] }
        let near = provider.near(zone)
        let listed = try await call.send("GET", "server_types", query: [URLQueryItem(name: "per_page", value: "50")])
        var offers: [(offer: Offer, place: Int, order: Int)] = []
        for (order, entry) in ((listed["server_types"] as? [[String: Any]]) ?? []).enumerated() {
            guard let type = entry["name"] as? String, Self.fits(entry, use) else { continue }
            let free = Set(((entry["locations"] as? [[String: Any]]) ?? [])
                .filter { $0["available"] as? Bool == true && !Self.isSet($0["deprecation"]) }
                .compactMap { $0["name"] as? String })
            let prices = (entry["prices"] as? [[String: Any]]) ?? []
            for (place, location) in near.enumerated() where free.contains(location) {
                guard let server = Self.monthly(prices, at: location) else { continue }
                let extra = addresses.compactMap { Self.monthly($0, at: location) }.reduce(Decimal(0), +)
                offers.append((Offer(type: type, location: location, price: server + extra, currency: currency,
                                     cores: entry["cores"] as? Int, memoryGB: (entry["memory"] as? NSNumber)?.doubleValue,
                                     diskGB: entry["disk"] as? Int), place, order))
            }
        }
        return offers.sorted { ($0.offer.price, $0.place, $0.order) < ($1.offer.price, $1.place, $1.order) }.map(\.offer)
    }

    /// A type of Hetzner's that can take what the server is for: not on its way out, x86 or Arm, with the memory that the
    /// server check asks of that use, and a disk with room for the system and the install's free space.
    static func fits(_ type: [String: Any], _ use: CloudServerUse) -> Bool {
        let need = use == .hub ? ServerCheck.hubMemory : ServerCheck.agentMemory
        guard !isSet(type["deprecation"]), ["x86", "arm"].contains(type["architecture"] as? String ?? ""),
              let memory = (type["memory"] as? NSNumber)?.doubleValue, memory * 1024 >= Double(need.megabytes),
              let disk = type["disk"] as? Int, disk >= 20 else { return false }
        return true
    }

    /// Reads one of Hetzner's actions until it ends. One that ends in an error is a failure, in Hetzner's own words, and
    /// so is one that does not end within `waitReads` reads.
    private func hetznerWait(action: Int, _ call: CloudCall) async throws {
        for _ in 0..<Self.waitReads {
            let state = try await read("actions/\(action)", call)?["action"] as? [String: Any]
            switch state?["status"] as? String {
            case "success": return
            case "error":
                let says = ((state?["error"] as? [String: Any])?["message"] as? String) ?? String(l10n: "the server was not made.")
                throw CloudError.refused(provider, says)
            default: try await pause(Self.waitStep)
            }
        }
        throw CloudError.notReady(provider)
    }

    /// A monthly price of Hetzner's at one location, with the tax Hetzner adds for this account.
    static func monthly(_ prices: [[String: Any]], at location: String) -> Decimal? {
        guard let price = prices.first(where: { $0["location"] as? String == location }),
              let gross = (price["price_monthly"] as? [String: Any])?["gross"] as? String else { return nil }
        return Decimal(string: gross, locale: Locale(identifier: "en_US_POSIX"))
    }

    // MARK: - DigitalOcean

    /// The droplet first, on the first offer DigitalOcean takes, and its firewall at once; then the droplet, read until
    /// it runs, because DigitalOcean gives it its address only then.
    private func digitalOcean(_ made: Made, use: CloudServerUse, key: SSHPublicKey, userData: String, offer: CloudOffer?,
                              _ call: CloudCall) async throws -> CloudServer {
        let keyID = try await digitalOceanKey(key, call)
        let offers = Self.only(offer, in: try await digitalOceanOffers(use, call))
        guard !offers.isEmpty else { throw CloudError.noRoom(provider) }
        var made = made
        do {
            var taken: (id: Int, offer: Offer)?
            var refusal: CloudCall.Answer?
            for offer in offers {
                let answer = try await call.answer("POST", "droplets", body: [
                    "name": made.name, "region": offer.location, "size": offer.type, "image": provider.image,
                    "ssh_keys": [keyID], "user_data": userData])
                // DigitalOcean's answer for a size that a region cannot take now: the next offer.
                if answer.status == 422 { refusal = answer; continue }
                guard answer.ok else { throw call.failure(answer) }
                guard let id = (answer.object["droplet"] as? [String: Any])?["id"] as? Int else {
                    throw CloudError.notUnderstood(provider)
                }
                taken = (id, offer)
                break
            }
            guard let taken else { throw refusal.map(call.failure) ?? CloudError.noRoom(provider) }
            made.server = String(taken.id)
            let firewall = try await call.send("POST", "firewalls", body: [
                "name": made.firewallName, "outbound_rules": Self.outbound, "droplet_ids": [taken.id]])
            guard let firewallID = (firewall["firewall"] as? [String: Any])?["id"] as? String, !firewallID.isEmpty else {
                throw CloudError.notUnderstood(provider)
            }
            made.firewall = firewallID
            let ipv4 = try await digitalOceanWait(taken.id, call)
            return CloudServer(provider: provider, id: String(taken.id), name: made.name, ipv4: ipv4, type: taken.offer.type,
                               location: taken.offer.location, monthlyPrice: taken.offer.price, currency: taken.offer.currency,
                               firewallID: firewallID)
        } catch {
            throw await undo(made, after: error, call)
        }
    }

    /// Everything out, to every address; and no inbound rule, which at DigitalOcean lets nothing in.
    static var outbound: [[String: Any]] {
        let everywhere = ["addresses": ["0.0.0.0/0", "::/0"]]
        return [["protocol": "tcp", "ports": "0", "destinations": everywhere],
                ["protocol": "udp", "ports": "0", "destinations": everywhere],
                ["protocol": "icmp", "destinations": everywhere]]
    }

    /// The id of this app's SSH key at DigitalOcean: found by its fingerprint, or registered once.
    private func digitalOceanKey(_ key: SSHPublicKey, _ call: CloudCall) async throws -> Int {
        func id(_ answer: CloudCall.Answer) -> Int? { (answer.object["ssh_key"] as? [String: Any])?["id"] as? Int }
        let found = try await call.answer("GET", "account/keys/\(key.fingerprint)")
        if found.ok, let id = id(found) { return id }
        guard found.status == 404 else { throw found.ok ? CloudError.notUnderstood(provider) : call.failure(found) }
        let answer = try await call.answer("POST", "account/keys", body: ["name": key.name, "public_key": key.line])
        if answer.ok, let id = id(answer) { return id }
        // Registered meanwhile, by another window of this app: DigitalOcean says it is in use, and it is the same key.
        if answer.status == 422, let again = try? await call.answer("GET", "account/keys/\(key.fingerprint)"), again.ok,
           let id = id(again) { return id }
        throw answer.ok ? CloudError.notUnderstood(provider) : call.failure(answer)
    }

    /// Its droplet for the use, in each region where DigitalOcean has it now, nearest first, with what it costs a month.
    private func digitalOceanOffers(_ use: CloudServerUse, _ call: CloudCall) async throws -> [Offer] {
        let listed = try await call.send("GET", "sizes", query: [URLQueryItem(name: "per_page", value: "200")])
        let type = CloudProvider.digitalOceanSize(for: use)
        guard let size = ((listed["sizes"] as? [[String: Any]]) ?? []).first(where: { $0["slug"] as? String == type }),
              size["available"] as? Bool != false, let number = size["price_monthly"] as? NSNumber,
              let price = Decimal(string: number.stringValue, locale: Locale(identifier: "en_US_POSIX")) else { return [] }
        let regions = Set((size["regions"] as? [String]) ?? [])
        return provider.near(zone).filter(regions.contains).map {
            Offer(type: type, location: $0, price: price, currency: "USD", cores: size["vcpus"] as? Int,
                  memoryGB: (size["memory"] as? NSNumber).map { $0.doubleValue / 1024 }, diskGB: size["disk"] as? Int)
        }
    }

    /// Reads the droplet until it runs with its public IPv4 address, for at most `waitReads` reads.
    private func digitalOceanWait(_ id: Int, _ call: CloudCall) async throws -> String {
        for _ in 0..<Self.waitReads {
            let droplet = try await read("droplets/\(id)", call)?["droplet"] as? [String: Any]
            let addresses = ((droplet?["networks"] as? [String: Any])?["v4"] as? [[String: Any]]) ?? []
            if droplet?["status"] as? String == "active",
               let ipv4 = addresses.first(where: { $0["type"] as? String == "public" })?["ip_address"] as? String,
               Self.isIPv4(ipv4) { return ipv4 }
            try await pause(Self.waitStep)
        }
        throw CloudError.notReady(provider)
    }

    // MARK: - Vultr

    /// The firewall group first, which lets nothing in while it has no rule, so the server has it from its first boot;
    /// then the instance, on the offer the owner said yes to (or the first offer, when he was shown none); then the
    /// instance, read until it is active with its public address. Vultr's plans were read where they are free a moment
    /// before, so a refusal is said in Vultr's own words, and no other offer is tried.
    private func vultr(_ made: Made, use: CloudServerUse, key: SSHPublicKey, userData: String, offer: CloudOffer?,
                       _ call: CloudCall) async throws -> CloudServer {
        let keyID = try await vultrKey(key, call)
        let system = try await vultrSystem(call)
        guard let chosen = Self.only(offer, in: try await vultrOffers(use, call)).first else { throw CloudError.noRoom(provider) }
        let firewall = try await call.send("POST", "firewalls", body: ["description": made.firewallName])
        guard let firewallID = (firewall["firewall_group"] as? [String: Any])?["id"] as? String, !firewallID.isEmpty else {
            throw CloudError.notUnderstood(provider)
        }
        var made = made
        made.firewall = firewallID
        do {
            let answer = try await call.send("POST", "instances", body: [
                "region": chosen.location, "plan": chosen.type, "os_id": system, "label": made.name, "hostname": made.name,
                "sshkey_id": [keyID], "firewall_group_id": firewallID, "user_data": Data(userData.utf8).base64EncodedString(),
                "enable_ipv6": true, "backups": "disabled", "activation_email": false, "tags": [Self.tag(use)]])
            guard let id = (answer["instance"] as? [String: Any])?["id"] as? String, !id.isEmpty else {
                throw CloudError.notUnderstood(provider)
            }
            made.server = id
            let ipv4 = try await vultrWait(id, call)
            return CloudServer(provider: provider, id: id, name: made.name, ipv4: ipv4, type: chosen.type,
                               location: chosen.location, monthlyPrice: chosen.price, currency: chosen.currency,
                               firewallID: firewallID)
        } catch {
            throw await undo(made, after: error, call)
        }
    }

    /// The id of this app's SSH key at Vultr: found by the key itself, or registered once. Vultr lists its keys without
    /// a fingerprint, so the key's own text is what is compared.
    private func vultrKey(_ key: SSHPublicKey, _ call: CloudCall) async throws -> String {
        let listed = try await call.send("GET", "ssh-keys", query: [URLQueryItem(name: "per_page", value: "500")])
        if let id = ((listed["ssh_keys"] as? [[String: Any]]) ?? [])
            .first(where: { Self.sameKey($0["ssh_key"] as? String, key) })?["id"] as? String { return id }
        let answer = try await call.answer("POST", "ssh-keys", body: ["name": key.name, "ssh_key": key.line])
        if answer.ok, let id = (answer.object["ssh_key"] as? [String: Any])?["id"] as? String { return id }
        throw answer.ok ? CloudError.notUnderstood(provider) : call.failure(answer)
    }

    /// Whether a key that a provider lists is this app's: the same kind and the same key, whatever its comment.
    static func sameKey(_ listed: String?, _ key: SSHPublicKey) -> Bool {
        guard let listed else { return false }
        return listed.split(separator: " ").prefix(2) == key.line.split(separator: " ").prefix(2)
    }

    /// Vultr's id of Ubuntu 24.04 for x86, from Vultr's own list of systems, whose ids are Vultr's to change.
    private func vultrSystem(_ call: CloudCall) async throws -> Int {
        let listed = try await call.send("GET", "os", query: [URLQueryItem(name: "per_page", value: "500")])
        let system = ((listed["os"] as? [[String: Any]]) ?? []).first {
            $0["family"] as? String == "ubuntu" && $0["arch"] as? String == "x64"
                && ($0["name"] as? String)?.hasPrefix(provider.image + " ") == true
        }
        guard let id = system?["id"] as? Int else { throw CloudError.notUnderstood(provider) }
        return id
    }

    /// Each of Vultr's plans that fits what the server is for, in each location near the Mac where Vultr has it free
    /// now, cheapest first and, at one price, nearest first, with what it costs there a month. Vultr's own list, as at
    /// Hetzner, because its plans change.
    private func vultrOffers(_ use: CloudServerUse, _ call: CloudCall) async throws -> [Offer] {
        let listed = try await call.send("GET", "plans", query: [URLQueryItem(name: "per_page", value: "500")])
        let plans = ((listed["plans"] as? [[String: Any]]) ?? []).filter { Self.vultrFits($0, use) }
        guard !plans.isEmpty else { return [] }
        var offers: [(offer: Offer, place: Int, order: Int)] = []
        for (place, location) in provider.near(zone).enumerated() {
            let here = try await call.send("GET", "regions/\(location)/availability")
            let free = Set((here["available_plans"] as? [String]) ?? [])
            for (order, plan) in plans.enumerated() {
                guard let type = plan["id"] as? String, free.contains(type),
                      ((plan["locations"] as? [String]) ?? []).contains(location),
                      let price = Self.vultrMonthly(plan, at: location) else { continue }
                offers.append((Offer(type: type, location: location, price: price, currency: "USD",
                                     cores: plan["vcpu_count"] as? Int,
                                     memoryGB: (plan["ram"] as? NSNumber).map { $0.doubleValue / 1024 },
                                     diskGB: plan["disk"] as? Int), place, order))
            }
        }
        return offers.sorted { ($0.offer.price, $0.place, $0.order) < ($1.offer.price, $1.place, $1.order) }.map(\.offer)
    }

    /// A plan of Vultr's that can take what the server is for: a virtual machine of its usual kinds with a disk of its
    /// own and a public IPv4 address, that may be ordered now, with the memory that the server check asks of that use
    /// and room for the system and the install.
    static func vultrFits(_ plan: [String: Any], _ use: CloudServerUse) -> Bool {
        let need = use == .hub ? ServerCheck.hubMemory : ServerCheck.agentMemory
        guard let id = plan["id"] as? String, !id.hasSuffix("-v6"),
              ["vc2", "vhf", "vhp", "voc"].contains(plan["type"] as? String ?? ""), plan["deploy_ondemand"] as? Bool != false,
              let memory = plan["ram"] as? Int, memory >= need.megabytes, let disk = plan["disk"] as? Int, disk >= 20,
              let cost = (plan["monthly_cost"] as? NSNumber)?.doubleValue, cost > 0 else { return false }
        return true
    }

    /// A Vultr plan's monthly price at one location: that location's own price where Vultr has one.
    static func vultrMonthly(_ plan: [String: Any], at location: String) -> Decimal? {
        let local = ((plan["location_cost"] as? [String: Any])?[location] as? [String: Any])?["monthly_cost"] as? NSNumber
        guard let number = local ?? plan["monthly_cost"] as? NSNumber else { return nil }
        return Decimal(string: number.stringValue, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Reads the instance until it is active with its public IPv4 address, for at most `waitReads` reads. Vultr says
    /// 0.0.0.0 until it has given it one.
    private func vultrWait(_ id: String, _ call: CloudCall) async throws -> String {
        for _ in 0..<Self.waitReads {
            let instance = try await read("instances/\(id)", call)?["instance"] as? [String: Any]
            if instance?["status"] as? String == "active", let ipv4 = instance?["main_ip"] as? String, Self.isIPv4(ipv4),
               ipv4 != "0.0.0.0" { return ipv4 }
            try await pause(Self.waitStep)
        }
        throw CloudError.notReady(provider)
    }

    /// Vultr's instances (up to 500), each with its city from Vultr's own list of regions; a list that cannot be read
    /// leaves the region's code.
    private func vultrServers(_ call: CloudCall) async throws -> [CloudExisting] {
        let page = [URLQueryItem(name: "per_page", value: "500")]
        let listed = try await call.send("GET", "instances", query: page)
        let regions = (try? await call.send("GET", "regions", query: page))?["regions"] as? [[String: Any]] ?? []
        let cities = Dictionary(regions.compactMap { region -> (String, String)? in
            guard let id = region["id"] as? String, let city = region["city"] as? String else { return nil }
            return (id, city)
        }, uniquingKeysWith: { first, _ in first })
        return ((listed["instances"] as? [[String: Any]]) ?? []).compactMap { instance in
            guard let id = instance["id"] as? String, let label = instance["label"] as? String else { return nil }
            // "Ubuntu 24.04 LTS x64" and "Debian 12 x64 (bookworm)": the system, then its version.
            let words = ((instance["os"] as? String) ?? "").split(separator: " ").map(String.init)
            let region = instance["region"] as? String
            return CloudExisting(
                id: id, name: label, ipv4: (instance["main_ip"] as? String).flatMap { Self.isIPv4($0) && $0 != "0.0.0.0" ? $0 : nil },
                type: (instance["plan"] as? String) ?? "", memoryMB: instance["ram"] as? Int,
                system: words.first?.lowercased(), version: words.count > 1 ? words[1] : nil,
                place: region.map { cities[$0] ?? $0 },
                running: instance["status"] as? String == "active" && instance["power_status"] as? String == "running",
                project: nil, madeFor: Self.madeFor(tags: instance["tags"] as? [String]))
        }
    }

    // MARK: - Akamai (Linode)

    /// The firewall first, which drops all that comes in, so the server has it from its first boot; then the Linode
    /// behind it, with this app's key for root and the first boot's script, on the offer the owner said yes to (or the
    /// first offer, when he was shown none); then the Linode, read until it runs. Akamai's plans were read where they
    /// are free a moment before, so a refusal is said in Akamai's own words, and no other offer is tried.
    ///
    /// The Linode takes Akamai's older kind of network interface by name (`legacy_config`), because a firewall that a
    /// Linode is made with stands in front of that kind only: an account whose new Linodes take the newer kind by
    /// default would otherwise get a Linode with no firewall at all.
    private func akamai(_ made: Made, use: CloudServerUse, key: SSHPublicKey, userData: String, offer: CloudOffer?,
                        _ call: CloudCall) async throws -> CloudServer {
        guard let chosen = Self.only(offer, in: try await akamaiOffers(use, call)).first else { throw CloudError.noRoom(provider) }
        let firewall = try await call.send("POST", "networking/firewalls", body: [
            "label": made.firewallName, "tags": [Self.tag(use)],
            "rules": ["inbound_policy": "DROP", "outbound_policy": "ACCEPT", "inbound": [Any](), "outbound": [Any]()]])
        guard let firewallID = firewall["id"] as? Int else { throw CloudError.notUnderstood(provider) }
        var made = made
        made.firewall = String(firewallID)
        do {
            let linode = try await call.send("POST", "linode/instances", body: [
                "label": made.name, "region": chosen.location, "type": chosen.type, "image": provider.image,
                "root_pass": Self.rootPassword(), "authorized_keys": [key.line],
                "interface_generation": "legacy_config", "firewall_id": firewallID,
                "metadata": ["user_data": Data(userData.utf8).base64EncodedString()],
                "booted": true, "backups_enabled": false, "private_ip": false, "tags": [Self.tag(use)]])
            guard let id = linode["id"] as? Int else { throw CloudError.notUnderstood(provider) }
            made.server = String(id)
            let ipv4 = try await akamaiWait(id, call)
            return CloudServer(provider: provider, id: String(id), name: made.name, ipv4: ipv4, type: chosen.type,
                               location: chosen.location, monthlyPrice: chosen.price, currency: chosen.currency,
                               firewallID: String(firewallID))
        } catch {
            throw await undo(made, after: error, call)
        }
    }

    /// The root password that Akamai asks of every Linode made from an image: 32 characters of chance, sent once and
    /// kept nowhere, so nobody has it. The server is reached with this app's key, and over the private network only.
    static func rootPassword() -> String {
        let characters = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!#%+-.:=@^_~")
        var chance = SystemRandomNumberGenerator()
        return String((0..<32).map { _ in characters.randomElement(using: &chance)! })
    }

    /// Each of Akamai's shared plans that fits what the server is for, in each region near the Mac where Akamai has it
    /// free now, cheapest first and, at one price, nearest first, with what it costs there a month. Akamai's own list.
    private func akamaiOffers(_ use: CloudServerUse, _ call: CloudCall) async throws -> [Offer] {
        let listed = try await call.send("GET", "linode/types", query: [URLQueryItem(name: "page_size", value: "500")])
        let types = ((listed["data"] as? [[String: Any]]) ?? []).filter { Self.akamaiFits($0, use) }
        guard !types.isEmpty else { return [] }
        var offers: [(offer: Offer, place: Int, order: Int)] = []
        for (place, region) in provider.near(zone).enumerated() {
            // Every plan of the region, with whether it is free now: a list, not an object.
            let here = try await call.answer("GET", "regions/\(region)/availability")
            guard here.ok else { throw call.failure(here) }
            let free = Set(here.items.filter { $0["available"] as? Bool == true }.compactMap { $0["plan"] as? String })
            for (order, entry) in types.enumerated() {
                guard let type = entry["id"] as? String, free.contains(type),
                      let price = Self.akamaiMonthly(entry, in: region) else { continue }
                offers.append((Offer(type: type, location: region, price: price, currency: "USD",
                                     cores: entry["vcpus"] as? Int,
                                     memoryGB: (entry["memory"] as? NSNumber).map { $0.doubleValue / 1024 },
                                     diskGB: (entry["disk"] as? Int).map { $0 / 1024 }), place, order))
            }
        }
        return offers.sorted { ($0.offer.price, $0.place, $0.order) < ($1.offer.price, $1.place, $1.order) }.map(\.offer)
    }

    /// A plan of Akamai's that can take what the server is for: a shared one that is not on its way out, with the
    /// memory that the server check asks of that use, room for the system and the install, and a monthly price.
    static func akamaiFits(_ type: [String: Any], _ use: CloudServerUse) -> Bool {
        let need = use == .hub ? ServerCheck.hubMemory : ServerCheck.agentMemory
        guard ["nanode", "standard"].contains(type["class"] as? String ?? ""), !isSet(type["successor"]),
              let memory = type["memory"] as? Int, memory >= need.megabytes,
              let disk = type["disk"] as? Int, disk >= 20 * 1024,
              (type["price"] as? [String: Any])?["monthly"] as? NSNumber != nil else { return false }
        return true
    }

    /// An Akamai plan's monthly price in one region: that region's own price where Akamai has one.
    static func akamaiMonthly(_ type: [String: Any], in region: String) -> Decimal? {
        let local = ((type["region_prices"] as? [[String: Any]]) ?? []).first { $0["id"] as? String == region }?["monthly"]
            as? NSNumber
        guard let number = local ?? (type["price"] as? [String: Any])?["monthly"] as? NSNumber else { return nil }
        return Decimal(string: number.stringValue, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Reads the Linode until it runs, for at most `waitReads` reads, and answers its public IPv4 address.
    private func akamaiWait(_ id: Int, _ call: CloudCall) async throws -> String {
        for _ in 0..<Self.waitReads {
            let linode = try await read("linode/instances/\(id)", call)
            if linode?["status"] as? String == "running", let ipv4 = Self.publicIPv4(linode?["ipv4"] as? [String]) { return ipv4 }
            try await pause(Self.waitStep)
        }
        throw CloudError.notReady(provider)
    }

    /// The first public IPv4 address of a Linode's: Akamai lists a private address of the Linode's with its public one.
    static func publicIPv4(_ addresses: [String]?) -> String? {
        addresses?.first { address in
            guard isIPv4(address) else { return false }
            let parts = address.split(separator: ".").compactMap { Int($0) }
            return !(parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168)
                     || (parts[0] == 172 && (16...31).contains(parts[1])))
        }
    }

    /// Akamai's Linodes, page by page (100 a page, at most 20 pages), each with its region's name from Akamai's own
    /// list; a list that cannot be read leaves the region's code.
    private func akamaiServers(_ call: CloudCall) async throws -> [CloudExisting] {
        let regions = (try? await call.send("GET", "regions", query: [URLQueryItem(name: "page_size", value: "500")]))?["data"]
            as? [[String: Any]] ?? []
        let names = Dictionary(regions.compactMap { region -> (String, String)? in
            guard let id = region["id"] as? String, let label = region["label"] as? String else { return nil }
            return (id, label)
        }, uniquingKeysWith: { first, _ in first })
        var found: [CloudExisting] = []
        var page = 1
        for _ in 0..<20 {
            let listed = try await call.send("GET", "linode/instances", query: [URLQueryItem(name: "page_size", value: "100"),
                                                                                  URLQueryItem(name: "page", value: String(page))])
            for linode in (listed["data"] as? [[String: Any]]) ?? [] {
                guard let id = linode["id"] as? Int, let label = linode["label"] as? String else { continue }
                // "linode/ubuntu24.04" and "linode/debian12": the system, then its version. An image of the account's
                // own says neither.
                let image = (linode["image"] as? String).flatMap { $0.hasPrefix("linode/") ? String($0.dropFirst(7)) : nil }
                let system = image.map { String($0.prefix(while: \.isLetter)) }.flatMap { $0.isEmpty ? nil : $0 }
                let version = image.map { String($0.drop(while: \.isLetter)) }.flatMap { $0.isEmpty ? nil : $0 }
                let region = linode["region"] as? String
                found.append(CloudExisting(
                    id: String(id), name: label, ipv4: Self.publicIPv4(linode["ipv4"] as? [String]),
                    type: (linode["type"] as? String) ?? "", memoryMB: (linode["specs"] as? [String: Any])?["memory"] as? Int,
                    system: system, version: version, place: region.map { names[$0] ?? $0 },
                    running: linode["status"] as? String == "running", project: nil,
                    madeFor: Self.madeFor(tags: linode["tags"] as? [String])))
            }
            guard let pages = listed["pages"] as? Int, page < pages else { break }
            page += 1
        }
        return found
    }

    /// The tag that says what this app made a server and its firewall for, at Vultr and at Akamai.
    static func tag(_ use: CloudServerUse) -> String { "founderizer-\(use.rawValue)" }

    /// What this app made a server for, by that tag; nil for a server this app did not make.
    static func madeFor(tags: [String]?) -> String? {
        [CloudServerUse.hub, .agent].first { tags?.contains(tag($0)) == true }?.rawValue
    }

    /// One read of a server that is being made. A read that does not get through, or that the provider asks this Mac to
    /// wait with, says nothing about the server, so it is no reason to take the server back: the next read asks again,
    /// within the same count.
    private func read(_ path: String, _ call: CloudCall) async throws -> [String: Any]? {
        do { return try await call.send("GET", path) } catch CloudError.unreachable, CloudError.rateLimited { return nil }
    }

    // MARK: - Taking back what one call made

    /// What one call has made so far.
    struct Made: Sendable {
        let name: String
        let firewallName: String
        var server: String?
        var firewall: String?
    }

    /// Takes away what one call made, and says so when it could not. It runs as a task of its own, so that a create the
    /// owner cancelled still leaves no server running at his cost.
    private func undo(_ made: Made, after error: Error, _ call: CloudCall) async -> Error {
        let left = await Task { await self.remove(made, call) }.value
        guard !left.isEmpty else { return error }
        let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return CloudError.leftBehind(provider, reason: reason, left: left)
    }

    /// Deletes the server, then its firewall, and answers what is still there. At Hetzner and Vultr a firewall goes only
    /// once no server uses it, which the server's own deletion ends, so it is asked again while that deletion runs.
    private func remove(_ made: Made, _ call: CloudCall) async -> [String] {
        var left: [String] = []
        if let server = made.server {
            let answer = try? await call.answer("DELETE", provider.serverPath(server))
            if let answer, answer.ok || answer.status == 404 {
                if let action = (answer.object["action"] as? [String: Any])?["id"] as? Int {
                    try? await hetznerWait(action: action, call)
                }
            } else {
                left.append(String(l10n: "the server \(made.name)"))
            }
        }
        if let firewall = made.firewall {
            var gone = false
            for _ in 0..<Self.removeReads {
                guard let answer = try? await call.answer("DELETE", provider.firewallPath(firewall)) else { break }
                if answer.ok || answer.status == 404 { gone = true; break }
                // Hetzner says the firewall is still in use while the server's deletion runs; Vultr and Akamai say it in
                // words of their own, so any refusal but the token's is asked again.
                let inUse = answer.code == "resource_in_use"
                    || ([.vultr, .akamai].contains(provider) && ![401, 403].contains(answer.status))
                guard inUse else { break }
                try? await pause(Self.waitStep)
            }
            if !gone { left.append(String(l10n: "the firewall \(made.firewallName)")) }
        }
        return left
    }

    /// A JSON value that is there and not null.
    static func isSet(_ value: Any?) -> Bool { value != nil && !(value is NSNull) }
}

/// Hetzner Cloud, DigitalOcean, Vultr and Akamai: the providers a server can be made at from this Mac, in the order
/// their cards stand.
public enum CloudProvider: String, CaseIterable, Codable, Sendable {
    case hetzner
    case digitalOcean = "digitalocean"
    case vultr
    /// Akamai Cloud, which was Linode: its API and its console keep Linode's names.
    case akamai

    public var name: String {
        switch self {
        case .hetzner: "Hetzner"
        case .digitalOcean: "DigitalOcean"
        case .vultr: "Vultr"
        case .akamai: "Akamai"
        }
    }

    /// Where this provider's token is kept on this Mac.
    public var keychain: KeychainShelf {
        KeychainShelf(service: "com.founderizer.cloud.\(rawValue)", account: "api-token", label: "\(name) token")
    }

    var api: URL {
        switch self {
        case .hetzner: URL(string: "https://api.hetzner.cloud/v1")!
        case .digitalOcean: URL(string: "https://api.digitalocean.com/v2")!
        case .vultr: URL(string: "https://api.vultr.com/v2")!
        case .akamai: URL(string: "https://api.linode.com/v4")!
        }
    }

    /// Ubuntu 24.04 by this provider's own name for it. Hetzner picks the image for the type's processor by itself; at
    /// Vultr it is the start of the system's name in Vultr's list, whose id is read there (`vultrSystem`).
    var image: String {
        switch self {
        case .hetzner: "ubuntu-\(CloudServers.ubuntu)"
        case .digitalOcean: "ubuntu-\(CloudServers.ubuntu.replacingOccurrences(of: ".", with: "-"))-x64"
        case .vultr: "Ubuntu \(CloudServers.ubuntu)"
        case .akamai: "linode/ubuntu\(CloudServers.ubuntu)"
        }
    }

    /// The writes that ask whether a token may make what a server needs, each with an empty body that cannot make
    /// anything. Akamai gives a token each product on its own, so both products a server needs are asked. Vultr's
    /// firewall is not asked: an empty body would make one.
    var writeProbes: [String] {
        switch self {
        case .hetzner: ["ssh_keys"]
        case .digitalOcean: ["account/keys"]
        case .vultr: ["ssh-keys"]
        case .akamai: ["linode/instances", "networking/firewalls"]
        }
    }

    /// The path of one server at this provider, and of one firewall.
    func serverPath(_ id: String) -> String {
        switch self {
        case .hetzner: "servers/\(id)"
        case .digitalOcean: "droplets/\(id)"
        case .vultr: "instances/\(id)"
        case .akamai: "linode/instances/\(id)"
        }
    }

    func firewallPath(_ id: String) -> String { self == .akamai ? "networking/firewalls/\(id)" : "firewalls/\(id)" }

    /// DigitalOcean's droplet for each use: its smallest that the server check takes. Hetzner's type comes from Hetzner's
    /// own list (`CloudServers.fits`).
    static func digitalOceanSize(for use: CloudServerUse) -> String { use == .hub ? "s-1vcpu-1gb" : "s-1vcpu-2gb" }

    /// The locations this app makes servers in, each with the standard offset of its time zone from UTC, in hours, in
    /// the order this app prefers them when two are as near.
    var locations: [(name: String, hours: Double)] {
        switch self {
        case .hetzner: [("fsn1", 1), ("nbg1", 1), ("hel1", 2), ("ash", -5), ("hil", -8), ("sin", 8)]
        case .digitalOcean: [("fra1", 1), ("ams3", 1), ("lon1", 0), ("nyc3", -5), ("sfo3", -8), ("sgp1", 8)]
        case .vultr: [("fra", 1), ("ams", 1), ("lhr", 0), ("ewr", -5), ("sjc", -8), ("sgp", 8)]
        case .akamai: [("eu-central", 1), ("nl-ams", 1), ("eu-west", 0), ("us-east", -5), ("us-west", -8), ("ap-south", 8)]
        }
    }

    /// The city and country of one of `locations`, in this app's own words; the code itself for one it does not know.
    public func place(_ location: String) -> String {
        let places = ["fsn1": String(l10n: "Falkenstein, Germany"), "nbg1": String(l10n: "Nuremberg, Germany"), "hel1": String(l10n: "Helsinki, Finland"),
                      "ash": String(l10n: "Ashburn, USA"), "hil": String(l10n: "Hillsboro, USA"), "sin": String(l10n: "Singapore"),
                      "fra1": String(l10n: "Frankfurt, Germany"), "ams3": String(l10n: "Amsterdam, Netherlands"), "lon1": String(l10n: "London, UK"),
                      "nyc3": String(l10n: "New York, USA"), "sfo3": String(l10n: "San Francisco, USA"), "sgp1": String(l10n: "Singapore"),
                      "fra": String(l10n: "Frankfurt, Germany"), "ams": String(l10n: "Amsterdam, Netherlands"), "lhr": String(l10n: "London, UK"),
                      "ewr": String(l10n: "New Jersey, USA"), "sjc": String(l10n: "Silicon Valley, USA"), "sgp": String(l10n: "Singapore"),
                      "eu-central": String(l10n: "Frankfurt, Germany"), "nl-ams": String(l10n: "Amsterdam, Netherlands"), "eu-west": String(l10n: "London, UK"),
                      "us-east": String(l10n: "Newark, USA"), "us-west": String(l10n: "Fremont, USA"), "ap-south": String(l10n: "Singapore")]
        return places[location] ?? location
    }

    /// The locations nearest this Mac first: by how far each location's time zone is from the Mac's around the clock, in
    /// standard time, so a summer does not move a Mac to another location.
    func near(_ zone: TimeZone, at date: Date = Date()) -> [String] {
        let here = (Double(zone.secondsFromGMT(for: date)) - zone.daylightSavingTimeOffset(for: date)) / 3600
        func distance(_ hours: Double) -> Double {
            let apart = abs(here - hours).truncatingRemainder(dividingBy: 24)
            return min(apart, 24 - apart)
        }
        return locations.enumerated()
            .sorted { (distance($0.element.hours), $0.offset) < (distance($1.element.hours), $1.offset) }
            .map(\.element.name)
    }

    /// A pasted token, trimmed, or the reason it is not one. Nothing goes to the provider before this.
    func token(_ given: String) throws -> String {
        let token = given.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (20...256).contains(token.count), !token.hasPrefix("tskey-"),
              token.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw CloudError.notAToken(self) }
        return token
    }
}

/// What a server is for, which says the smallest type that fits it.
public enum CloudServerUse: String, Codable, Sendable {
    /// The fleet's VPS, which runs the hub.
    case hub
    /// A server for agents.
    case agent
}

/// One server, as its provider made it.
public struct CloudServer: Equatable, Sendable {
    public let provider: CloudProvider
    /// The provider's own id of the server.
    public let id: String
    /// Its name at the provider, and in Tailscale.
    public let name: String
    /// Its public address, which nothing from outside reaches: its firewall lets nothing in.
    public let ipv4: String
    public let type: String
    public let location: String
    /// What it costs a month by the provider's own price data, with the tax the provider adds for this account.
    public let monthlyPrice: Decimal
    /// The currency of that price, as ISO 4217 writes it.
    public let currency: String
    /// The provider's own id of the firewall in front of it.
    public let firewallID: String
}

/// One offer of a provider: a type, a location, and what it costs there a month, with what the type is made of.
struct Offer: Equatable, Sendable {
    let type: String
    let location: String
    let price: Decimal
    let currency: String
    var cores: Int? = nil
    var memoryGB: Double? = nil
    var diskGB: Int? = nil
}

/// **The server this app would make**: its type and what it is made of, where, and what it costs a month, as the
/// provider's own data says, with the tax the provider adds for this account.
public struct CloudOffer: Equatable, Sendable {
    public let provider: CloudProvider
    public let type: String
    public let location: String
    public let cores: Int?
    public let memoryGB: Double?
    public let diskGB: Int?
    public let monthlyPrice: Decimal
    /// The currency of that price, as ISO 4217 writes it.
    public let currency: String

    /// The city and country of its location, in this app's own words ("Nuremberg, Germany").
    public var place: String { provider.place(location) }
}

/// **One server that the provider's account holds already**, as its provider lists it.
public struct CloudExisting: Equatable, Sendable, Identifiable {
    /// The provider's own id of it.
    public let id: String
    public let name: String
    /// Its public IPv4 address, which the check of the server goes to; nil when it has none.
    public let ipv4: String?
    /// The provider's name of its type: "cx23", "s-1vcpu-2gb".
    public let type: String
    public let memoryMB: Int?
    /// Its system as `/etc/os-release` names it ("ubuntu", "debian"), and its version ("24.04"), when the provider says.
    public let system: String?
    public let version: String?
    /// Its city, in the provider's words.
    public let place: String?
    public let running: Bool
    /// Its DigitalOcean project, when the team has more than one.
    public let project: String?
    /// What this app made it for, by its label at Hetzner ("hub", "agent"); nil for a server this app did not make.
    public let madeFor: String?

    public init(id: String, name: String, ipv4: String?, type: String, memoryMB: Int?, system: String?, version: String?,
                place: String?, running: Bool, project: String?, madeFor: String?) {
        self.id = id; self.name = name; self.ipv4 = ipv4; self.type = type; self.memoryMB = memoryMB
        self.system = system; self.version = version; self.place = place; self.running = running
        self.project = project; self.madeFor = madeFor
    }
}

public enum CloudError: LocalizedError, Equatable, Sendable {
    /// What was pasted is not a token of this provider.
    case notAToken(CloudProvider)
    /// This Mac holds no token of this provider yet.
    case noToken(CloudProvider)
    /// The provider did not accept the token.
    case tokenNotAccepted(CloudProvider)
    /// The token may read and may not make anything.
    case readOnlyToken(CloudProvider)
    /// The provider asks this Mac to wait.
    case rateLimited(CloudProvider)
    /// The provider could not be reached.
    case unreachable(CloudProvider)
    /// The provider refused, in its own words.
    case refused(CloudProvider, String)
    /// The provider answered something this app does not understand.
    case notUnderstood(CloudProvider)
    /// The provider has no type that fits free in any location now.
    case noRoom(CloudProvider)
    /// The server did not come up in time.
    case notReady(CloudProvider)
    /// What the caller gave is not of the shape a server needs.
    case notAServerName, notAPublicKey, notAnAuthKey
    /// A step failed, and this app could not delete all it had made: `left` says what is still there.
    case leftBehind(CloudProvider, reason: String, left: [String])

    public var errorDescription: String? {
        switch self {
        case .notAToken(let provider): String(l10n: "This is not a \(provider.name) API token. Copy the token \(provider.name) showed you, and paste it.")
        case .noToken(let provider): String(l10n: "This Mac holds no \(provider.name) token yet. Paste one first.")
        case .tokenNotAccepted(let provider):
            String(l10n: "\(provider.name) did not accept this token: it was deleted, or it is not whole. Make a new one and paste it.")
        case .readOnlyToken(.hetzner):
            String(l10n: "This Hetzner token can only read. Make a token with Read & Write in the project's Security page, and paste it.")
        case .readOnlyToken(.vultr):
            String(l10n: "This Vultr API key cannot make servers. Use the API key of the account, or of a user who may manage servers, and paste it.")
        case .readOnlyToken(.akamai):
            String(l10n: "This Akamai token cannot make servers. Make one with Read/Write for Linodes and Firewalls, and paste it.")
        case .readOnlyToken(let provider):
            String(l10n: "This \(provider.name) token cannot make servers. Make one with full access, or with write access to Droplets, SSH keys and firewalls, and paste it.")
        case .rateLimited(let provider): String(l10n: "\(provider.name) asks this Mac to wait. Try again in a minute.")
        case .unreachable(let provider): String(l10n: "\(provider.name) could not be reached. Check this Mac's connection to the internet.")
        case .refused(let provider, let says): String(l10n: "\(provider.name) refused: \(says)")
        case .notUnderstood(let provider): String(l10n: "\(provider.name) answered something this app does not understand.")
        case .noRoom(let provider):
            String(l10n: "\(provider.name) has no server of the smallest types free near you now. Try again later.")
        case .notReady(let provider): String(l10n: "The server did not come up at \(provider.name) in time, so it was deleted. Try again.")
        case .notAServerName: String(l10n: "Use a name of 2 to 31 characters: a-z, 0-9 and -, starting with a letter and not ending in -.")
        case .notAPublicKey: String(l10n: "This app's SSH public key could not be read.")
        case .notAnAuthKey: String(l10n: "The key for the private network is not a Tailscale auth key.")
        case .leftBehind(let provider, let reason, let left):
            left.count == 2
                ? String(l10n: "\(reason) This app could not delete \(left[0]) and \(left[1]): delete it at \(provider.name).")
                : String(l10n: "\(reason) This app could not delete \(left.joined(separator: " and ")): delete it at \(provider.name).")
        }
    }
}

/// One provider's API with one token: the request, the answer as JSON, and a refusal in the provider's own words.
struct CloudCall: Sendable {
    let provider: CloudProvider
    let token: String
    let exchange: ProviderExchange

    struct Answer {
        let status: Int
        let object: [String: Any]
        /// An answer that is a list of objects, as Akamai's list of a region's free plans is; empty for any other.
        var items: [[String: Any]] = []
        let text: String
        var ok: Bool { (200...299).contains(status) }
        /// The provider's own code for a refusal: Hetzner's `error.code`, DigitalOcean's `id`.
        var code: String? { ((object["error"] as? [String: Any])?["code"] as? String) ?? (object["id"] as? String) }
        /// The provider's own words for it: Hetzner's `error.message`, DigitalOcean's `message`, Vultr's `error`, and
        /// each of Akamai's `errors`.
        var says: String {
            if let message = (object["error"] as? [String: Any])?["message"] as? String { return message }
            if let message = object["message"] as? String { return message }
            if let message = object["error"] as? String { return message }
            let reasons = ((object["errors"] as? [[String: Any]]) ?? []).compactMap { error -> String? in
                guard let reason = error["reason"] as? String else { return nil }
                return (error["field"] as? String).map { "\($0): \(reason)" } ?? reason
            }
            return reasons.isEmpty ? text : reasons.joined(separator: "; ")
        }
    }

    func answer(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> Answer {
        var url = provider.api.appendingPathComponent(path)
        if !query.isEmpty, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.queryItems = query
            url = parts.url ?? url
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        let data: Data, http: HTTPURLResponse
        do { (data, http) = try await exchange(request) } catch { throw CloudError.unreachable(provider) }
        let json = try? JSONSerialization.jsonObject(with: data)
        return Answer(status: http.statusCode, object: json as? [String: Any] ?? [:], items: json as? [[String: Any]] ?? [],
                      text: String(decoding: data.prefix(300), as: UTF8.self))
    }

    /// The answer of a request that must succeed.
    func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> [String: Any] {
        let answer = try await answer(method, path, query: query, body: body)
        guard answer.ok else { throw failure(answer) }
        return answer.object
    }

    /// What a refusal means for the owner. A token that may only read is refused by every provider before it reads
    /// what was asked; anything that is not the token or a wait is said in the provider's own words, without the token.
    /// Vultr refuses a key from an address it does not allow with 401 too, and says which address: those words stand.
    /// Akamai refuses a token that was not given the product with 401 too, and says that it is not authorized.
    func failure(_ answer: Answer) -> CloudError {
        switch (provider, answer.status) {
        case (.vultr, 401) where !answer.says.localizedCaseInsensitiveContains("IP address"): return .tokenNotAccepted(provider)
        case (.vultr, 403), (.akamai, 403): return .readOnlyToken(provider)
        case (.akamai, 401):
            return answer.says.localizedCaseInsensitiveContains("not authorized") ? .readOnlyToken(provider) : .tokenNotAccepted(provider)
        default: break
        }
        if provider == .vultr, answer.status == 401 { return .refused(provider, words(answer)) }
        switch (answer.status, answer.code) {
        case (401, "token_readonly"), (403, "token_readonly"), (403, "forbidden"): return .readOnlyToken(provider)
        case (401, _): return .tokenNotAccepted(provider)
        case (429, _): return .rateLimited(provider)
        default: return .refused(provider, words(answer))
        }
    }

    /// The provider's own words for a refusal, on one line and without the token.
    private func words(_ answer: Answer) -> String {
        let says = answer.says.replacingOccurrences(of: token, with: String(l10n: "(not shown)"))
            .trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return says.isEmpty ? String(l10n: "it answered \(answer.status) and said nothing.") : String(says.prefix(300))
    }
}

/// This app's own SSH public key, as one line of `authorized_keys`, with its MD5 fingerprint as Hetzner and DigitalOcean
/// write it.
struct SSHPublicKey: Equatable, Sendable {
    let line: String
    let fingerprint: String

    static let kinds = ["ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521", "ssh-rsa"]

    /// The key, when it is one: one line, a kind this app knows, and a key whose own bytes name that same kind.
    init?(_ text: String) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = line.split(separator: " ")
        guard !line.contains(where: \.isNewline), line.utf8.count <= 16_384, fields.count >= 2,
              Self.kinds.contains(String(fields[0])), let blob = Data(base64Encoded: String(fields[1])), blob.count > 4
        else { return nil }
        let bytes = [UInt8](blob)
        let length = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        guard bytes.count >= 4 + length, String(decoding: bytes[4..<(4 + length)], as: UTF8.self) == fields[0] else {
            return nil
        }
        self.line = line
        fingerprint = Insecure.MD5.hash(data: blob).map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// Its name at the provider, which carries the start of its fingerprint, so another key of the same name never
    /// stands in its way.
    var name: String { "founderizer-" + fingerprint.replacingOccurrences(of: ":", with: "").prefix(12) }
}
