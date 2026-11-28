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
///     installer, once apt's lock is free, and joins once, under the name it was given (which is its name in Tailscale
///     too), with a single-use key that the fleet key minted for it and that lives one hour (`joinKey`, `joinKeyLife`).
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
    /// **How long a new server has to join the owner's private network, in seconds: the life of the single-use key that
    /// its first boot joins with, and the app waits for it as long** (the owner's choice of 11 November 2026, "1 hour,
    /// both"; until then the app waited five minutes, and the key lived fifteen). Most servers join in about a minute
    /// and a half. The first boot waits for apt's lock before each try of Tailscale's installer (`userData`), and a new
    /// server's first updates hold that lock for about nine minutes: a server whose boot meets them joins after about
    /// ten. After that life the server cannot join with its key, so the wait ends with it.
    public static let joinKeyLife = 3600
    /// How often the private network is read while a new server joins it.
    static let joinLookEvery = Duration.seconds(5)
    /// From how long after the server was made, and how often, the tailnet's own list is read too while it joins
    /// (`joined`'s `listed`): the five minutes that the whole wait had until 11 November 2026, then once a minute.
    static let joinListAfter: TimeInterval = 300, joinListEvery: TimeInterval = 60

    public let provider: CloudProvider
    private let exchange: ProviderExchange
    private let shelf: any CredentialShelf
    private let zone: TimeZone
    private let pause: Pause
    private let follow: Follow

    /// How a call starts the reads that go on after it ended (`followUp`): a task of its own, which a test can wait for.
    public typealias Follow = @Sendable (@escaping @Sendable () async -> Void) -> Void

    /// `zone` is this Mac's, which says where the server goes; `pause` is the wait between two reads of a server that is
    /// being made, which a test does not wait; `follow` starts the reads that go on after a call whose end is not known.
    public init(provider: CloudProvider, exchange: @escaping ProviderExchange = ProviderConnection.live,
                shelf: (any CredentialShelf)? = nil, zone: TimeZone = .current,
                pause: @escaping Pause = { try await Task.sleep(for: $0) },
                follow: @escaping Follow = { body in Task.detached { await body() } }) {
        self.provider = provider; self.exchange = exchange; self.shelf = shelf ?? provider.keychain
        self.zone = zone; self.pause = pause; self.follow = follow
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
        case .hostinger:
            // A Hostinger token has the rights of the user that made it, so a read is the whole check.
            _ = try await hostingerList("vps/v1/virtual-machines", call)
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
        case .hostinger: return try await hostinger(made, use: use, key: key, userData: userData, offer: offer, call)
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
    /// that one or nothing. `except`: the `CloudOffer.key` of each offer that the provider refused as taken in this
    /// run (`CloudError.taken`), so the next one is the next free server, of any size that fits, also when it costs
    /// more (the owner, 15 November 2026: "it should still show some servers even if more expensive").
    public func offer(use: CloudServerUse, except: Set<String> = []) async throws -> CloudOffer {
        try await offers(use: use, except: except)[0]
    }

    /// **Every type of this provider that fits what the server is for, each once** (slice 2b of the one wizard: the
    /// owner's "Yes, build them" of 18 November 2026 to the list under each server of "Your fleet", after his "hetzner
    /// has alternatives even if more expensive, we need to show more options!"): each type at its cheapest place free
    /// now, and at one price the nearest, the cheapest type first, so the first is `offer(use:except:)`'s. `except` as
    /// there: a taken place of a type gives that type's next place. Another provider's rows are its sizes (`row`).
    public func offers(use: CloudServerUse, except: Set<String> = []) async throws -> [CloudOffer] {
        let call = try heldCall()
        var rows = Set<String>()
        let each = try await offers(use, call).filter {
            !except.contains(Self.key($0.type, $0.location)) && rows.insert(Self.row($0, of: provider)).inserted
        }
        guard !each.isEmpty else { throw CloudError.noRoom(provider) }
        return each.map {
            CloudOffer(provider: provider, type: $0.type, location: $0.location, cores: $0.cores, memoryGB: $0.memoryGB,
                       diskGB: $0.diskGB, monthlyPrice: $0.price, currency: $0.currency, dedicated: $0.dedicated,
                       plan: $0.plan, firstPrice: $0.firstPrice, city: $0.city, paid: $0.paid, label: $0.label)
        }
    }

    /// One offer's name in a set of offers: its type and its location.
    static func key(_ type: String, _ location: String) -> String { "\(type)@\(location)" }

    /// **One row of the list under a server** (`offers(use:except:)`): Hetzner's type, which the row names; another
    /// provider's size as its row says it (cores, memory, own cores), whose kinds of one size (a regular and an AMD
    /// droplet) would read the same.
    static func row(_ offer: Offer, of provider: CloudProvider) -> String {
        kind(provider, type: offer.type, cores: offer.cores, memoryGB: offer.memoryGB, dedicated: offer.dedicated)
    }

    static func kind(_ provider: CloudProvider, type: String, cores: Int?, memoryGB: Double?, dedicated: Bool) -> String {
        // A Hostinger row is one VPS that the account bought, or one plan of the catalog: its type names it.
        [.hetzner, .hostinger].contains(provider) ? type : "\(cores ?? 0) \(memoryGB ?? 0) \(dedicated)"
    }

    /// Every offer of this provider for what the server is for, the one to show first first.
    private func offers(_ use: CloudServerUse, _ call: CloudCall) async throws -> [Offer] {
        switch provider {
        case .hetzner: try await hetznerOffers(use, call)
        case .digitalOcean: try await digitalOceanOffers(use, call)
        case .vultr: try await vultrOffers(use, call)
        case .akamai: try await akamaiOffers(use, call)
        case .hostinger: try await hostingerOffers(use, call)
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
        case .hostinger: return try await hostingerServers(call)
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
                running: droplet["status"] as? String == "active", project: projects[String(id)],
                madeFor: Self.madeFor(tags: droplet["tags"] as? [String]))
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

    /// **The server's first boot**: Tailscale by Tailscale's own installer, and onto the owner's network once, under the
    /// server's own name. The installer runs apt-get with no wait for apt's lock, and apt's own timers start a new
    /// server's first updates at a random time, which then hold that lock for minutes: so each try first waits for the
    /// lock, with an `apt-get install` that installs nothing, and a try counts only when `tailscale` is there after it,
    /// three tries at most. These are the words of hub.py's TAILSCALE_INSTALL (since 11 November 2026; before, a boot
    /// that met the updates stopped at once, and its server never joined). A real first boot at Hetzner on that day met
    /// no lock: the script started 62 seconds after the server was made and ended 15 seconds later, with Tailscale
    /// installed at the first try, and the server's update timers were due 11 and 16 hours later. The key stands in the
    /// provider's metadata for that boot, which is why it is single-use and worthless after `joinKeyLife`. DNS stays the
    /// server's own, as every other install of the fleet leaves it.
    static func userData(authKey: String, hostname: String) -> String {
        ["#!/bin/sh",
         "for try in 1 2 3; do DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=\(InstallPlan.aptLockWait) -q "
            + "install </dev/null >/dev/null 2>&1; curl -fsSL https://tailscale.com/install.sh | sh && "
            + "command -v tailscale >/dev/null && break; sleep 20; done",
         "tailscale up --auth-key=\(authKey) --hostname=\(hostname) --accept-dns=false"].joined(separator: "\n") + "\n"
    }

    // MARK: - After a server is made: its join

    /// **The key that a new server's first boot joins the private network with**: from the fleet key, for this one
    /// server, single-use, and worthless after `joinKeyLife`.
    public static func joinKey(for name: String, from fleetKey: TailscaleFleetKey = TailscaleFleetKey()) async throws -> String {
        try await fleetKey.mintAuthKey(hostname: name, life: joinKeyLife)
    }

    /// **The wait for a new server on the private network**, from `made`, the moment the provider made it, which is after
    /// its key was minted: so the wait ends a little after the key. `status` is the network as this Mac sees it
    /// (`MacNetwork.status()`), read every `joinLookEvery`, and once more at the end. The answer is `online` with the
    /// server's private address the moment it is there and online, or `ended` once `joinKeyLife` has gone by with no
    /// such server (`notJoined` says so). A wait that is ended (Back) throws `CancellationError`, also after a read that
    /// saw the server.
    ///
    /// **`listed`, the tailnet's own list, ends the wait early** for a server that joined and that this Mac does not
    /// see (a policy that keeps it from this Mac, or this Mac's Tailscale stopped or in another tailnet): it is read
    /// from `joinListAfter` on, once in `joinListEvery`, and when two reads in a row have the server while this Mac's
    /// network, read every `joinLookEvery` between them, never showed it online, the wait ends with `listed` and the
    /// device of the second read, so the caller says why (`FleetReach`) with no read of its own that could fail. A
    /// server that the list has a moment before this Mac sees it is found in that minute. Until the hour of 11
    /// November 2026 that line came after the five minutes of the wait, and the hour is for a boot that waits for the
    /// server's first updates, not for this line.
    public static func joined(_ name: String, since made: Date, status: @Sendable () async -> String?,
                              listed: (@Sendable () async -> JoinedDevice?)? = nil,
                              now: @Sendable () -> Date = { Date() },
                              pause: Pause = { try await Task.sleep(for: $0) }) async throws -> JoinEnd {
        let until = made.addingTimeInterval(TimeInterval(joinKeyLife))
        var nextList = made.addingTimeInterval(joinListAfter)
        var listedBefore = false
        while now() < until {
            try Task.checkCancellation()
            let json = await status()
            try Task.checkCancellation()
            if let address = online(name, in: json) { return .online(address) }
            if let listed, now() >= nextList {
                nextList = now().addingTimeInterval(joinListEvery)
                let device = await listed()
                try Task.checkCancellation()
                if let device, listedBefore { return .listed(device) }
                listedBefore = device != nil
            }
            try await pause(joinLookEvery)
        }
        // A last look at the end: a Mac that slept past the end did not read the network in the last minutes.
        let last = await status()
        try Task.checkCancellation()
        return online(name, in: last).map(JoinEnd.online) ?? .ended
    }

    /// **How the wait for a new server ended** (`joined`).
    public enum JoinEnd: Equatable, Sendable {
        /// This Mac sees the server online, at this private address.
        case online(String)
        /// The tailnet's own list had the server at two reads in a row, and this Mac never showed it online.
        case listed(JoinedDevice)
        /// The key's life went by with no such server in this Mac's sight.
        case ended
    }

    /// The private address of the device `name` in this Mac's network (`tailscale status --json`), when it is online.
    private static func online(_ name: String, in json: String?) -> String? {
        json.flatMap { FleetOnTailscale.devices(in: $0).first(where: { $0.name == name && $0.online })?.address }
    }

    /// The step's one line when a new server did not join within `joinKeyLife` (the owner's words of 11 November 2026).
    public static func notJoined(_ name: String, at provider: CloudProvider) -> String {
        String(l10n: "\(name) did not join your network within an hour. Open it in \(provider.name)'s console.")
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

    /// **No server could be made of the offers tried**: the one the owner said yes to is taken now (`taken`, and the
    /// page shows him the next free one, with its price, before anything is made); with none shown, nothing that fits
    /// is free (`noRoom`).
    static func none(of chosen: CloudOffer?, at provider: CloudProvider) -> CloudError {
        chosen == nil ? .noRoom(provider) : .taken(provider)
    }

    // MARK: - Hetzner Cloud

    /// The firewall first, so the server has it from its first boot; then the server, on the first offer the provider
    /// takes; then its creation, read until it ends.
    private func hetzner(_ made: Made, use: CloudServerUse, key: SSHPublicKey, userData: String, offer: CloudOffer?,
                         _ call: CloudCall) async throws -> CloudServer {
        let keyID = try await hetznerKey(key, call)
        let offers = Self.only(offer, in: try await hetznerOffers(use, call))
        guard !offers.isEmpty else { throw Self.none(of: offer, at: provider) }
        let firewall = try await call.send("POST", "firewalls", body: [
            "name": made.firewallName, "rules": [[String: Any]](), "labels": ["founderizer": use.rawValue]])
        guard let firewallID = (firewall["firewall"] as? [String: Any])?["id"] as? Int else {
            throw CloudError.notUnderstood(provider)
        }
        var made = made
        made.firewall = String(firewallID)
        do {
            for offer in offers {
                let answer = try await create("servers", [
                    "name": made.name, "server_type": offer.type, "location": offer.location, "image": provider.image,
                    "ssh_keys": [keyID], "user_data": userData, "firewalls": [["firewall": firewallID]],
                    "labels": ["founderizer": use.rawValue], "start_after_create": true,
                    // Each public address takes one of the account's primary IPs, which Hetzner limits for each customer
                    // across all its projects, so a server for agents has one: IPv4, for what it reaches out to. The
                    // hub's server has IPv6 too, so that one failed lease of its IPv4 address does not take the whole
                    // fleet off the network (the owner's yes of 21 November 2026). The fleet reaches each server over
                    // Tailscale.
                    "public_net": ["enable_ipv4": true, "enable_ipv6": use == .hub]], &made, call)
                // None free there after all, since the offers were read: the next offer.
                if answer.code == "resource_unavailable" || answer.code == "placement_error" { continue }
                guard answer.ok else { throw try await failed(answer, &made, call) }
                guard let server = answer.object["server"] as? [String: Any], let id = server["id"] as? Int else {
                    throw try await unread(&made, call)
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
            throw Self.none(of: offer, at: provider)
        } catch let unsure as Unsure {
            throw unsure.error
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
    /// public addresses it comes with, which Hetzner prices on their own (IPv4, and IPv6 for the hub's server). Hetzner's
    /// own list, not one of this app's, because its types change: on 5 November 2026 it had no CX or CAX type free
    /// anywhere, and new CPX types.
    private func hetznerOffers(_ use: CloudServerUse, _ call: CloudCall) async throws -> [Offer] {
        guard let pricing = try await call.send("GET", "pricing")["pricing"] as? [String: Any],
              let currency = pricing["currency"] as? String, !currency.isEmpty else { throw CloudError.notUnderstood(provider) }
        let kinds = use == .hub ? ["ipv4", "ipv6"] : ["ipv4"]
        let addresses = ((pricing["primary_ips"] as? [[String: Any]]) ?? [])
            .filter { kinds.contains($0["type"] as? String ?? "") }
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
                                     diskGB: entry["disk"] as? Int, dedicated: entry["cpu_type"] as? String == "dedicated"),
                               place, order))
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
        guard !offers.isEmpty else { throw Self.none(of: offer, at: provider) }
        var made = made
        do {
            var taken: (id: Int, offer: Offer)?
            var refusal: CloudCall.Answer?
            for offer in offers {
                let answer = try await create("droplets", [
                    "name": made.name, "region": offer.location, "size": offer.type, "image": provider.image,
                    "ssh_keys": [keyID], "user_data": userData,
                    "tags": [Self.tag(use), made.firewallName]], &made, call)
                // DigitalOcean's answer for a size that a region cannot take now: the next offer. Its other 422s (a
                // limit) end the try at once, in its own words.
                if Self.saysUnavailable(answer) { refusal = answer; continue }
                guard answer.ok else { throw try await failed(answer, &made, call) }
                guard let id = (answer.object["droplet"] as? [String: Any])?["id"] as? Int else {
                    throw try await unread(&made, call)
                }
                taken = (id, offer)
                break
            }
            guard let taken else {
                // The size that the owner said yes to, which this region cannot take now: the page shows the next one.
                if offer != nil, let refusal, Self.saysUnavailable(refusal) { throw CloudError.taken(provider) }
                throw refusal.map(call.failure) ?? Self.none(of: offer, at: provider)
            }
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
        } catch let unsure as Unsure {
            throw unsure.error
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

    /// Each of DigitalOcean's sizes that fits the use, in each region near the Mac where DigitalOcean has it now,
    /// cheapest first and, at one price, its smallest droplet for the use first and then the nearest region, with what
    /// it costs a month. Every size that fits, not only the smallest: when that one is not free near the Mac, the
    /// next free one is offered, also when it costs more (the owner, 15 November 2026).
    private func digitalOceanOffers(_ use: CloudServerUse, _ call: CloudCall) async throws -> [Offer] {
        let listed = try await call.send("GET", "sizes", query: [URLQueryItem(name: "per_page", value: "200")])
        let smallest = CloudProvider.digitalOceanSize(for: use)
        let near = provider.near(zone)
        var offers: [(offer: Offer, first: Bool, place: Int, order: Int)] = []
        for (order, size) in ((listed["sizes"] as? [[String: Any]]) ?? []).enumerated() {
            guard Self.digitalOceanFits(size, use), let type = size["slug"] as? String,
                  let number = size["price_monthly"] as? NSNumber,
                  let price = Decimal(string: number.stringValue, locale: Locale(identifier: "en_US_POSIX")) else { continue }
            let regions = Set((size["regions"] as? [String]) ?? [])
            for (place, region) in near.enumerated() where regions.contains(region) {
                offers.append((Offer(type: type, location: region, price: price, currency: "USD", cores: size["vcpus"] as? Int,
                                     memoryGB: (size["memory"] as? NSNumber).map { $0.doubleValue / 1024 },
                                     diskGB: size["disk"] as? Int), type == smallest, place, order))
            }
        }
        return offers.sorted {
            ($0.offer.price, $0.first ? 0 : 1, $0.place, $0.order) < ($1.offer.price, $1.first ? 0 : 1, $1.place, $1.order)
        }.map(\.offer)
    }

    /// A size of DigitalOcean's that can take what the server is for: one that may be ordered now, with no GPU, the
    /// memory that the server check asks of that use, room for the system and the install, and a monthly price.
    static func digitalOceanFits(_ size: [String: Any], _ use: CloudServerUse) -> Bool {
        let need = use == .hub ? ServerCheck.hubMemory : ServerCheck.agentMemory
        guard size["available"] as? Bool != false, let slug = size["slug"] as? String, !slug.hasPrefix("gpu-"),
              let memory = size["memory"] as? Int, memory >= need.megabytes, let disk = size["disk"] as? Int, disk >= 20,
              let cost = (size["price_monthly"] as? NSNumber)?.doubleValue, cost > 0 else { return false }
        return true
    }

    /// DigitalOcean's refusal of a droplet whose size the region cannot take now: its 422, in words such as "Size is not
    /// available in this region." Its other 422s (a limit, an image that the region lacks, a wrong field) say something
    /// else, and all of them have the same `id`.
    static func saysUnavailable(_ answer: CloudCall.Answer) -> Bool {
        let words = answer.says.lowercased()
        return answer.status == 422 && words.contains("size")
            && (words.contains("not available") || words.contains("unavailable"))
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
        guard let chosen = Self.only(offer, in: try await vultrOffers(use, call)).first else { throw Self.none(of: offer, at: provider) }
        let firewall = try await call.send("POST", "firewalls", body: ["description": made.firewallName])
        guard let firewallID = (firewall["firewall_group"] as? [String: Any])?["id"] as? String, !firewallID.isEmpty else {
            throw CloudError.notUnderstood(provider)
        }
        var made = made
        made.firewall = firewallID
        do {
            let answer = try await create("instances", [
                "region": chosen.location, "plan": chosen.type, "os_id": system, "label": made.name, "hostname": made.name,
                "sshkey_id": [keyID], "firewall_group_id": firewallID, "user_data": Data(userData.utf8).base64EncodedString(),
                "enable_ipv6": true, "backups": "disabled", "activation_email": false, "tags": [Self.tag(use)]], &made, call)
            guard answer.ok else { throw try await failed(answer, &made, call) }
            guard let id = (answer.object["instance"] as? [String: Any])?["id"] as? String, !id.isEmpty else {
                throw try await unread(&made, call)
            }
            made.server = id
            let ipv4 = try await vultrWait(id, call)
            return CloudServer(provider: provider, id: id, name: made.name, ipv4: ipv4, type: chosen.type,
                               location: chosen.location, monthlyPrice: chosen.price, currency: chosen.currency,
                               firewallID: firewallID)
        } catch let unsure as Unsure {
            throw unsure.error
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
        guard let chosen = Self.only(offer, in: try await akamaiOffers(use, call)).first else { throw Self.none(of: offer, at: provider) }
        let firewall = try await call.send("POST", "networking/firewalls", body: [
            "label": made.firewallName, "tags": [Self.tag(use)],
            "rules": ["inbound_policy": "DROP", "outbound_policy": "ACCEPT", "inbound": [Any](), "outbound": [Any]()]])
        guard let firewallID = firewall["id"] as? Int else { throw CloudError.notUnderstood(provider) }
        var made = made
        made.firewall = String(firewallID)
        do {
            let answer = try await create("linode/instances", [
                "label": made.name, "region": chosen.location, "type": chosen.type, "image": provider.image,
                "root_pass": Self.rootPassword(), "authorized_keys": [key.line],
                "interface_generation": "legacy_config", "firewall_id": firewallID,
                "metadata": ["user_data": Data(userData.utf8).base64EncodedString()],
                "booted": true, "backups_enabled": false, "private_ip": false, "tags": [Self.tag(use)]], &made, call)
            guard answer.ok else { throw try await failed(answer, &made, call) }
            guard let id = answer.object["id"] as? Int else { throw try await unread(&made, call) }
            made.server = String(id)
            let ipv4 = try await akamaiWait(id, call)
            return CloudServer(provider: provider, id: String(id), name: made.name, ipv4: ipv4, type: chosen.type,
                               location: chosen.location, monthlyPrice: chosen.price, currency: chosen.currency,
                               firewallID: String(firewallID))
        } catch let unsure as Unsure {
            throw unsure.error
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

    // MARK: - Hostinger

    /// How often, and how many times, a Hostinger server is read while Hostinger sets it up: a setup takes some
    /// minutes, longer than a server of the providers that bill by the hour.
    static let slowStep = Duration.seconds(10)
    static let slowReads = 90

    /// **A server at Hostinger, which bills by the month** (the owner's "Also buy from the app", 25 November 2026). The
    /// offer is a VPS that the account bought and did not set up yet (Hostinger's state `initial`), which costs nothing
    /// more, or a plan of Hostinger's catalog, which Hostinger charges to the account's default card when it is bought
    /// (`hostingerBuy`, which charges once at most). Either is set up with Ubuntu 24.04, this app's key and the first
    /// boot's script, which goes as a post-install script of the account because it holds the single-use key.
    ///
    /// **Nothing is taken back.** Hostinger's API deletes no VPS, and a VPS that was bought is paid: a step that fails
    /// after the purchase or the setup leaves it in the account, and the error says so with its id (`paidNotReady`),
    /// which the build's record keeps, so that a remove and Start again can end its renewal. A VPS whose setup was not
    /// taken stays `initial`, so the next list offers it again at no cost.
    ///
    /// **The script**: one that Hostinger did not take goes at once, outside a cancel of the page; one of a server that
    /// was set up, or of a call whose end Hostinger did not say (`KeptScript`), stays until a later build sweeps it
    /// (`hostingerSweep`), in case Hostinger runs it after the wait.
    ///
    /// **No provider firewall yet**: no proof says that Hostinger's firewall with no rule lets a server's own outbound
    /// connections answer, and a server that cannot reach Tailscale never joins. The install's own firewall stands
    /// from the install on.
    private func hostinger(_ made: Made, use: CloudServerUse, key: SSHPublicKey, userData: String, offer: CloudOffer?,
                           _ call: CloudCall) async throws -> CloudServer {
        let template = try await hostingerTemplate(call)
        guard let chosen = Self.only(offer, in: try await hostingerOffers(use, call)).first else {
            throw Self.none(of: offer, at: provider)
        }
        guard let center = Int(chosen.location) else { throw CloudError.notUnderstood(provider) }
        await hostingerSweep(call)
        let script = try await call.send("POST", "vps/v1/post-install-scripts",
                                         body: ["name": made.firewallName, "content": userData])
        guard let scriptID = script["id"] as? Int else { throw CloudError.notUnderstood(provider) }
        let setup: [String: Any] = [
            "template_id": template, "data_center_id": center, "post_install_script_id": scriptID,
            "hostname": made.name, "ssh_keys": [key.line], "enable_backups": false, "install_monarx": false]
        var machine: Int?
        do {
            if let bought = Self.hostingerBought(chosen.type) {
                try await hostingerSetUp(bought, name: made.name, setup: setup, call)
                machine = bought
            } else {
                machine = try await hostingerBuy(chosen, setup: setup, name: made.name, call)
            }
            guard let machine else { throw CloudError.notUnderstood(provider) }
            let ipv4 = try await hostingerWait(machine, name: made.name, call)
            return CloudServer(provider: provider, id: String(machine), name: made.name, ipv4: ipv4, type: chosen.type,
                               location: chosen.location, monthlyPrice: chosen.price, currency: chosen.currency, firewallID: "")
        } catch {
            guard let machine else {
                // A call whose end Hostinger did not say keeps the script for the sweep: Hostinger can still run it.
                if let kept = error as? KeptScript { throw kept.error }
                await Task { _ = try? await call.answer("DELETE", "vps/v1/post-install-scripts/\(scriptID)") }.value
                throw error
            }
            if case .paidNotReady = error as? CloudError { throw error }
            throw CloudError.paidNotReady(provider, made.name, String(machine))
        }
    }

    /// How many times the account's VPS are read for a purchase or a setup whose answer did not say what happened.
    static let findReads = 6

    /// **A purchase or a setup whose end Hostinger did not say** (a payment that waits, an answer that said nothing):
    /// Hostinger can still set the VPS up with this build's first-boot script, so the script is not deleted at once, and
    /// a later build's sweep takes it after the single-use key's hour (`hostingerSweep`), as it takes the script of a
    /// server that was set up (the Setup area's create after a 5xx or no answer, a945ec353: nothing is taken back while
    /// the end is not known). `error` is what the press says.
    private struct KeptScript: Error {
        let error: CloudError
    }

    /// **The setup of a VPS that the account bought**, which charges nothing. An answer that does not say what happened
    /// (none, or the provider's own fault) can follow a setup that Hostinger took: the VPS is read again by its own id,
    /// outside a cancel of the page, and one that left `initial` with this build's name is being set up. Else the end is
    /// not known (`unsure`, which the build's record keeps as not known, so that its name stays taken and a server that
    /// comes later is still this build's), and the script stays (`KeptScript`), since Hostinger can still take the setup.
    private func hostingerSetUp(_ id: Int, name: String, setup: [String: Any], _ call: CloudCall) async throws {
        let says: String?
        do {
            let answer = try await call.answer("POST", "vps/v1/virtual-machines/\(id)/setup", body: setup)
            if answer.ok { return }
            guard answer.status >= 500 else { throw call.failure(answer) }
            let fault = call.failure(answer)
            var words = if case .refused(_, let said) = fault { said } else { fault.errorDescription ?? "" }
            while words.hasSuffix(".") { words.removeLast() }       // the line's own brackets end it
            says = words
        } catch CloudError.unreachable {
            says = nil
        }
        if await Task(operation: { await self.hostingerTookSetup(id, name: name, call) }).value { return }
        throw KeptScript(error: .unsure(provider, says: says, server: name, mark: String(id)))
    }

    /// Whether Hostinger took this build's setup of the VPS: it left the state `initial` (not set up) and carries this
    /// build's name, which a setup of another build or of the owner's own in hPanel does not. Read a few times while
    /// Hostinger starts the setup; a read that fails is read again.
    private func hostingerTookSetup(_ id: Int, name: String, _ call: CloudCall) async -> Bool {
        for read in 0..<Self.findReads {
            if read > 0 { try? await pause(Self.slowStep) }
            guard let machine = try? await call.send("GET", provider.serverPath(String(id))),
                  let state = machine["state"] as? String else { continue }
            if state != "initial", Self.hostingerNamed(machine, name) { return true }
        }
        return false
    }

    /// Whether a VPS carries this build's name, which the setup gives it (Hostinger can add a domain to it).
    static func hostingerNamed(_ machine: [String: Any], _ name: String) -> Bool {
        let host = ((machine["hostname"] as? String) ?? "").lowercased()
        return host == name || host.hasPrefix(name + ".")
    }

    /// **The purchase of a new VPS, charged once at most.** Only the account's default card is charged (`hostingerCard`),
    /// and no purchase starts while one of an earlier press still waits for its payment (`hostingerPending`). An answer
    /// that does not say what happened (none, the provider's own fault, or one with no server) can follow a purchase
    /// that went through: the account's VPS are read again, outside a cancel of the page, and a new one is the server;
    /// with none, the payment counts as pending, which keeps the name and starts no second purchase. The mark of this
    /// press is a VPS that the list read just before the purchase did not hold, with this build's name: Hostinger keeps
    /// no tag or label of a VPS, and the purchase makes no firewall that a server could stand behind.
    private func hostingerBuy(_ chosen: Offer, setup: [String: Any], name: String, _ call: CloudCall) async throws -> Int {
        let card = try await hostingerCard(call)
        let machines = try await hostingerList("vps/v1/virtual-machines", call)
        try await hostingerPending(machines, call)
        let before = Set(machines.compactMap { $0["id"] as? Int })
        var answer: CloudCall.Answer?
        do {
            answer = try await call.answer("POST", "vps/v1/virtual-machines",
                                           body: ["item_id": chosen.type, "payment_method_id": card, "setup": setup])
        } catch CloudError.unreachable {
            answer = nil
        }
        if let answer {
            if answer.status == 202 { throw KeptScript(error: .paymentPending(provider)) }
            if !answer.ok, answer.status < 500 { throw call.failure(answer) }
            if answer.ok, let id = (answer.object["virtual_machine"] as? [String: Any])?["id"] as? Int { return id }
        }
        guard let found = await Task(operation: { await self.hostingerFind(name, before: before, call) }).value else {
            throw KeptScript(error: .paymentPending(provider))
        }
        return found
    }

    /// The VPS that is new since `before` and has this build's name (Hostinger can add a domain to it): the purchase's
    /// setup gives the name, and a VPS that the owner bought at the same time in hPanel has another one. Read a few
    /// times while Hostinger makes it; nil when none comes.
    private func hostingerFind(_ name: String, before: Set<Int>, _ call: CloudCall) async -> Int? {
        for read in 0..<Self.findReads {
            if read > 0 { try? await pause(Self.slowStep) }
            guard let machines = try? await hostingerList("vps/v1/virtual-machines", call) else { continue }
            let new = machines.filter { ($0["id"] as? Int).map { !before.contains($0) } ?? false }
            let named = new.first { Self.hostingerNamed($0, name) }
            if let id = named?["id"] as? Int { return id }
        }
        return nil
    }

    /// **A purchase of an earlier press that still waits for its payment** stops a new one: a VPS subscription of the
    /// account of less than a day, active, that no VPS of the list holds yet. An older one (an add-on, a VPS that has
    /// no subscription id) never stops a purchase for good.
    private func hostingerPending(_ machines: [[String: Any]], _ call: CloudCall) async throws {
        let held = Set(machines.compactMap { $0["subscription_id"] as? String })
        let plain = ISO8601DateFormatter(), fine = ISO8601DateFormatter()
        fine.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let day = Date().addingTimeInterval(-86_400)
        let waiting = try await hostingerList("billing/v1/subscriptions", call).contains {
            let name = (($0["name"] as? String) ?? "").lowercased()
            let made = ($0["created_at"] as? String).flatMap { plain.date(from: $0) ?? fine.date(from: $0) }
            return (name.contains("vps") || name.contains("kvm")) && (made.map { $0 > day } ?? false)
                && ["active", "in_trial", "future"].contains($0["status"] as? String ?? "")
                && !held.contains(($0["id"] as? String) ?? "")
        }
        if waiting { throw CloudError.paymentPending(provider) }
    }

    /// **The first boot's scripts of earlier builds** go: each post-install script that this app named for a server
    /// (`firewallName`) and that is more than an hour old, when the single-use key in it is dead. A script that cannot
    /// be read or deleted stays for the next sweep.
    private func hostingerSweep(_ call: CloudCall) async {
        guard let scripts = try? await hostingerList("vps/v1/post-install-scripts", call) else { return }
        let plain = ISO8601DateFormatter(), fine = ISO8601DateFormatter()
        fine.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let hour = Date().addingTimeInterval(-TimeInterval(Self.joinKeyLife))
        for script in scripts {
            guard let id = script["id"] as? Int, (script["name"] as? String)?.hasPrefix("founderizer-") == true,
                  let made = (script["created_at"] as? String).flatMap({ plain.date(from: $0) ?? fine.date(from: $0) }),
                  made < hour else { continue }
            _ = try? await call.answer("DELETE", "vps/v1/post-install-scripts/\(id)")
        }
    }

    /// The id of a VPS that the account bought, from its offer's type (`vm-<id>`); nil for a plan of the catalog.
    static func hostingerBought(_ type: String) -> Int? {
        type.hasPrefix("vm-") ? Int(type.dropFirst(3)) : nil
    }

    /// **Hostinger's offers**: first each VPS that the account bought and did not set up, which costs nothing more,
    /// then each KVM plan of the catalog that fits, cheapest first, by what each month costs after the first. All go
    /// to the data center nearest the Mac, by Hostinger's own list; a bought VPS that has its data center keeps it.
    private func hostingerOffers(_ use: CloudServerUse, _ call: CloudCall) async throws -> [Offer] {
        let centers = Self.hostingerNear(try await hostingerList("vps/v1/data-centers", call), zone)
        guard let near = centers.first else { return [] }
        let cities = Dictionary(centers.map { ($0.id, $0.city) }, uniquingKeysWith: { first, _ in first })
        let need = use == .hub ? ServerCheck.hubMemory : ServerCheck.agentMemory
        var bought: [Offer] = []
        for machine in try await hostingerList("vps/v1/virtual-machines", call) where machine["state"] as? String == "initial" {
            guard let id = machine["id"] as? Int, let memory = machine["memory"] as? Int, memory >= need.megabytes else { continue }
            let center = (machine["data_center_id"] as? Int).flatMap { cities[$0] == nil ? nil : $0 } ?? near.id
            bought.append(Offer(type: "vm-\(id)", location: String(center), price: 0, currency: "",
                                cores: machine["cpus"] as? Int, memoryGB: Double(memory) / 1024,
                                diskGB: (machine["disk"] as? Int).map { $0 / 1024 }, plan: machine["plan"] as? String,
                                city: cities[center], paid: true,
                                label: (machine["hostname"] as? String).map { String($0.split(separator: ".").first ?? Substring($0)) }))
        }
        let items = try await hostingerList("billing/v1/catalog", call, query: [URLQueryItem(name: "category", value: "VPS")])
        let plans = items.compactMap { item -> Offer? in
            guard let name = item["name"] as? String, let size = Self.hostingerSize(name),
                  Int(size.memoryGB * 1024) >= need.megabytes,
                  let price = Self.hostingerMonthly(item["prices"] as? [[String: Any]]) else { return nil }
            return Offer(type: price.id, location: String(near.id), price: price.each, currency: price.currency,
                         cores: size.cores, memoryGB: size.memoryGB, diskGB: size.diskGB, plan: name,
                         firstPrice: price.first == price.each ? nil : price.first, city: near.city)
        }
        return bought + plans.enumerated().sorted { ($0.element.price, $0.offset) < ($1.element.price, $1.offset) }.map(\.element)
    }

    /// What a KVM plan of Hostinger is made of, by its name: the catalog's own data for it has no form that Hostinger
    /// documents. A name that is not one of these plans is no offer.
    static func hostingerSize(_ name: String) -> (cores: Int, memoryGB: Double, diskGB: Int)? {
        switch name.trimmingCharacters(in: .whitespaces) {
        case "KVM 1": (1, 4, 50)
        case "KVM 2": (2, 8, 100)
        case "KVM 4": (4, 16, 200)
        case "KVM 8": (8, 32, 400)
        default: nil
        }
    }

    /// A plan's price for one month at a time: its price item's id, what each month costs and what the first one costs
    /// (Hostinger's prices are in cents), and the currency. A plan with no such price is no offer.
    static func hostingerMonthly(_ prices: [[String: Any]]?) -> (id: String, each: Decimal, first: Decimal, currency: String)? {
        guard let price = (prices ?? []).first(where: {
            $0["period"] as? Int == 1 && $0["period_unit"] as? String == "month" && (($0["price"] as? Int) ?? 0) > 0
        }), let id = price["id"] as? String, let each = price["price"] as? Int, let currency = price["currency"] as? String
        else { return nil }
        let first = (price["first_period_price"] as? Int).flatMap { $0 > 0 ? $0 : nil } ?? each
        return (id, Decimal(each) / 100, Decimal(first) / 100, currency)
    }

    /// Hostinger's data centers, the nearest to the Mac first, each with its city and country. Its list gives each one's
    /// country by code: the standard offset of each country where Hostinger has one, and of its continent for another.
    static func hostingerNear(_ centers: [[String: Any]], _ zone: TimeZone) -> [(id: Int, city: String)] {
        let countries: [String: Double] = ["nl": 1, "de": 1, "fr": 1, "lt": 2, "gb": 0, "uk": 0, "us": -5, "br": -3,
                                           "in": 5.5, "id": 7, "sg": 8, "my": 8]
        let continents: [String: Double] = ["Europe": 1, "North America": -6, "South America": -3, "Asia": 7, "Oceania": 10]
        let found = centers.compactMap { center -> (id: Int, city: String, hours: Double)? in
            guard let id = center["id"] as? Int, let city = center["city"] as? String else { return nil }
            let code = ((center["location"] as? String) ?? "").lowercased()
            let hours = countries[code] ?? continents[(center["continent"] as? String) ?? ""] ?? 0
            let country = Locale(identifier: "en_US").localizedString(forRegionCode: code == "uk" ? "GB" : code.uppercased())
            return (id, country.map { "\(city), \($0)" } ?? city, hours)
        }
        return found.enumerated()
            .sorted { (CloudProvider.apart(zone, $0.element.hours), $0.offset) < (CloudProvider.apart(zone, $1.element.hours), $1.offset) }
            .map { ($0.element.id, $0.element.city) }
    }

    /// Hostinger's id of Ubuntu 24.04, from its own list of templates: the plain system, not one with an app on it.
    private func hostingerTemplate(_ call: CloudCall) async throws -> Int {
        let templates = try await hostingerList("vps/v1/templates", call)
        let plain = templates.first { ["\(provider.image) LTS", provider.image].contains($0["name"] as? String ?? "") }
            ?? templates.first {
                let name = $0["name"] as? String ?? ""
                return name.hasPrefix(provider.image + " ") && !name.localizedCaseInsensitiveContains(" with ")
            }
        guard let id = plain?["id"] as? Int else { throw CloudError.notUnderstood(provider) }
        return id
    }

    /// The card that Hostinger charges for a new server: the account's default one, and only when it can be charged.
    /// The owner chose no other card, so no other one is charged.
    private func hostingerCard(_ call: CloudCall) async throws -> Int {
        let methods = try await hostingerList("billing/v1/payment-methods", call)
        guard let card = methods.first(where: { $0["is_default"] as? Bool == true }),
              card["is_expired"] as? Bool != true, card["is_suspended"] as? Bool != true,
              let id = card["id"] as? Int else { throw CloudError.noPaymentMethod(provider) }
        return id
    }

    /// Reads the server until it runs with its public IPv4 address, for at most `slowReads` reads. A server whose
    /// setup ends in `error` stops the wait at once. Either stop leaves a paid server in the account.
    private func hostingerWait(_ id: Int, name: String, _ call: CloudCall) async throws -> String {
        for _ in 0..<Self.slowReads {
            let machine = try await read(provider.serverPath(String(id)), call)
            if machine?["state"] as? String == "error" { throw CloudError.paidNotReady(provider, name, String(id)) }
            if machine?["state"] as? String == "running", let ipv4 = Self.hostingerIPv4(machine?["ipv4"]) { return ipv4 }
            try await pause(Self.slowStep)
        }
        throw CloudError.paidNotReady(provider, name, String(id))
    }

    /// The first public IPv4 address of Hostinger's list of a server's addresses.
    static func hostingerIPv4(_ addresses: Any?) -> String? {
        ((addresses as? [[String: Any]]) ?? []).compactMap { $0["address"] as? String }.first(where: isIPv4)
    }

    /// **Hostinger's servers that run or ran**: a VPS that was bought and not set up is an offer, not a server
    /// (`hostingerOffers`), one that Hostinger destroyed is gone, and one whose renewal is off is going: Hostinger
    /// deletes it at the end of its paid period, so no agent goes on it.
    private func hostingerServers(_ call: CloudCall) async throws -> [CloudExisting] {
        let ending = Set(((try? await hostingerList("billing/v1/subscriptions", call)) ?? [])
            .filter { $0["is_auto_renewed"] as? Bool == false }.compactMap { $0["id"] as? String })
        let machines = try await hostingerList("vps/v1/virtual-machines", call)
            .filter { !ending.contains(($0["subscription_id"] as? String) ?? "") }
        let centers = (try? await hostingerList("vps/v1/data-centers", call)) ?? []
        let cities = Dictionary(centers.compactMap { center -> (Int, String)? in
            guard let id = center["id"] as? Int, let city = center["city"] as? String else { return nil }
            return (id, city)
        }, uniquingKeysWith: { first, _ in first })
        return machines.compactMap { machine in
            guard let id = machine["id"] as? Int, let name = machine["hostname"] as? String,
                  !["initial", "destroying", "destroyed"].contains(machine["state"] as? String ?? "") else { return nil }
            // "Ubuntu 24.04 LTS" and "Debian 12": the system, then its version.
            let words = (((machine["template"] as? [String: Any])?["name"] as? String) ?? "").split(separator: " ").map(String.init)
            return CloudExisting(
                id: String(id), name: name, ipv4: Self.hostingerIPv4(machine["ipv4"]), type: (machine["plan"] as? String) ?? "",
                memoryMB: machine["memory"] as? Int, system: words.first?.lowercased(), version: words.count > 1 ? words[1] : nil,
                place: (machine["data_center_id"] as? Int).flatMap { cities[$0] }, running: machine["state"] as? String == "running",
                project: nil, madeFor: nil)
        }
    }

    /// **A remove at Hostinger ends the server's renewal**: Hostinger's API deletes no VPS, so the server runs to the
    /// end of the period that was paid, and Hostinger charges nothing more. A server that Hostinger does not know for
    /// this token is not there, as a 404 is at the other providers.
    private func hostingerEnd(_ id: String, accepted: (@Sendable () -> Void)?, _ call: CloudCall) async throws -> CloudDeletion {
        let found = try await call.answer("GET", provider.serverPath(id))
        if found.status == 404 { return .notThere(call.failure(found)) }
        guard found.ok else { throw call.failure(found) }
        guard let subscription = found.object["subscription_id"] as? String,
              (1...128).contains(subscription.utf8.count),
              subscription.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { throw CloudError.notUnderstood(provider) }
        // A renewal that is off already (an earlier remove that the hub then refused) is not asked again.
        let row = try await hostingerList("billing/v1/subscriptions", call).first { $0["id"] as? String == subscription }
        if row?["is_auto_renewed"] as? Bool != false {
            let answer = try await call.answer("DELETE", "billing/v1/subscriptions/\(subscription)/auto-renewal/disable")
            guard answer.ok else { throw call.failure(answer) }
        }
        accepted?()
        return .deleted
    }

    /// **Until when a server at a provider that bills by the month is paid**, for the question before its remove (the
    /// owner's "Remove ends the renewal" of 25 November 2026): the end of its paid period by the provider's own record.
    /// nil where the provider does not say.
    public func paidUntil(id: String) async throws -> Date? {
        guard provider == .hostinger, Self.isID(id) else { return nil }
        let call = try heldCall()
        guard let subscription = try await call.send("GET", provider.serverPath(id))["subscription_id"] as? String else {
            return nil
        }
        let row = try await hostingerList("billing/v1/subscriptions", call).first { $0["id"] as? String == subscription }
        guard let text = (row?["expires_at"] as? String) ?? (row?["next_billing_at"] as? String) else { return nil }
        let plain = ISO8601DateFormatter(), fine = ISO8601DateFormatter()
        fine.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: text) ?? fine.date(from: text)
    }

    /// One of Hostinger's lists: its answers are a list, or a page of one under `data`.
    private func hostingerList(_ path: String, _ call: CloudCall, query: [URLQueryItem] = []) async throws -> [[String: Any]] {
        let answer = try await call.answer("GET", path, query: query)
        guard answer.ok else { throw call.failure(answer) }
        return answer.items.isEmpty ? ((answer.object["data"] as? [[String: Any]]) ?? []) : answer.items
    }

    // MARK: - Taking back what one call made

    /// What one call has made so far.
    struct Made: Sendable {
        let name: String
        /// The firewall's name, six letters of chance after the server's: this call's own mark. At Hetzner, Vultr and
        /// Akamai the firewall is made first and the server is made behind it; at DigitalOcean the droplet carries the
        /// name as its tag (`madeBehind`).
        let firewallName: String
        var server: String?
        var firewall: String?
    }

    /// **A call whose end this Mac cannot know** (`madeMeanwhile`): nothing is taken back, because a server that the
    /// provider made all the same can stand behind the firewall that this call made, and Akamai deletes a firewall that
    /// a Linode uses. The build's record then says that what was left is not known (`BuildRecord.AtProvider`), and
    /// `followUp` reads on for it.
    struct Unsure: Error {
        let error: CloudError
    }

    /// The reads after a call whose end is not known, and the wait before each: the join key's life, an hour, in which
    /// a server that the provider made later can still join (`joinKeyLife`; the Door area's read of 318167959).
    static let followReads = joinKeyLife / 30
    static let followStep = Duration.seconds(30)

    /// **The servers that carry this call's own mark** (the Door area's read of ab7318f29, its MUST 2: a name and a
    /// time can be another build's server, of another fleet in the same account or of another Mac of this fleet): at
    /// Hetzner the servers that its firewall stands in front of, at Akamai the Linodes of its firewall's devices, at
    /// Vultr the instances behind its firewall group, at DigitalOcean the droplets with its tag. Each one
    /// of the call's own name only: a person's other server put behind the call's new firewall in that hour, or given
    /// its tag, is not the call's (the PC readers' point 3 of 26 November 2026). One read, and nothing else of the
    /// account; at Hetzner, whose firewall names its servers by id only, a second one, of the servers of that name.
    private func madeBehind(_ made: Made, _ call: CloudCall) async throws -> [String] {
        switch provider {
        case .hetzner:
            guard let firewall = made.firewall else { return [] }
            let read = try await call.send("GET", provider.firewallPath(firewall))
            let uses = ((read["firewall"] as? [String: Any])?["applied_to"] as? [[String: Any]]) ?? []
            let behind = uses.compactMap { (($0["server"] as? [String: Any])?["id"] as? Int).map(String.init) }
            guard !behind.isEmpty else { return [] }
            let named = try await call.send("GET", "servers", query: [URLQueryItem(name: "name", value: made.name)])
            let ids = Set(((named["servers"] as? [[String: Any]]) ?? []).compactMap { server -> String? in
                guard server["name"] as? String == made.name else { return nil }
                return (server["id"] as? Int).map(String.init)
            })
            return behind.filter(ids.contains)
        case .digitalOcean:
            let read = try await call.send("GET", "droplets", query: [URLQueryItem(name: "tag_name", value: made.firewallName),
                                                                      URLQueryItem(name: "per_page", value: "200")])
            return ((read["droplets"] as? [[String: Any]]) ?? []).compactMap { droplet in
                guard droplet["name"] as? String == made.name else { return nil }
                return (droplet["id"] as? Int).map(String.init)
            }
        case .vultr:
            guard let firewall = made.firewall else { return [] }
            let read = try await call.send("GET", "instances", query: [URLQueryItem(name: "label", value: made.name),
                                                                       URLQueryItem(name: "per_page", value: "500")])
            return ((read["instances"] as? [[String: Any]]) ?? []).compactMap { instance in
                guard instance["firewall_group_id"] as? String == firewall, instance["label"] as? String == made.name else {
                    return nil
                }
                return instance["id"] as? String
            }
        case .akamai:
            guard let firewall = made.firewall else { return [] }
            let read = try await call.send("GET", provider.firewallPath(firewall) + "/devices",
                                           query: [URLQueryItem(name: "page_size", value: "500")])
            return ((read["data"] as? [[String: Any]]) ?? []).compactMap { device in
                guard let entity = device["entity"] as? [String: Any], entity["type"] as? String == "linode",
                      entity["label"] as? String == made.name else { return nil }
                return (entity["id"] as? Int).map(String.init)
            }
        case .hostinger:
            // Hostinger's purchase reads its own unclear answers (`hostingerFind`), and it makes no firewall: no call of
            // it goes through `create`.
            return []
        }
    }

    /// **After the provider's own fault answer (a 5xx), or no answer at all, to the call that makes the server**
    /// (finding 3 of the checked audit of 24 November 2026): the provider can have made the server all the same, so the
    /// servers with this call's mark are read before anything is taken back, the firewall included. The one server
    /// there is this call's: its id is what `undo` then deletes with the rest. Every other end is `Unsure`, with
    /// `unsure` as its error, and nothing is taken back: no such server yet (a gateway's 502 or 504, or a time-out,
    /// while the provider goes on making it: a firewall taken back now would leave it with none: the Vault area's read
    /// of ab7318f29), a read that does not get through, or two of them. `followUp` reads on then.
    private func madeMeanwhile(_ made: Made, _ call: CloudCall, unsure: CloudError) async throws -> String {
        // In a task of its own, as `undo` is: the owner's Back while the call ran cancels the call's task, and must not
        // cut this read short (the validation of 2be411f3b).
        let read = await Task { try? await self.madeBehind(made, call) }.value
        guard let marked = read, marked.count == 1 else {
            followUp(made, call)
            throw Unsure(error: unsure)
        }
        return marked[0]
    }

    /// **A call that ended not knowing whether the provider made the server goes on reading for it**, in a task of its
    /// own, while this app runs (the Door area's read of ab7318f29, its MUST 3: else a server that came later runs at
    /// the owner's cost, with no record that finds it): every `followStep`, `followReads` times, the servers with the
    /// call's mark. The one that comes is deleted with the call's firewall (`remove`), and the reads go on while it
    /// stays: a deletion that failed, or Hetzner's `locked` while it still makes the server (the Door area's read of
    /// 318167959, its MUST 1). Two with the mark are not the call's alone: nothing is deleted, and the reads go on. A
    /// firewall with no server stays: it costs nothing, and a server can still come behind it.
    private func followUp(_ made: Made, _ call: CloudCall) {
        follow { [self] in
            for _ in 0..<Self.followReads {
                do { try await pause(Self.followStep) } catch { return }
                guard let marked = try? await madeBehind(made, call), marked.count == 1 else { continue }
                var found = made
                found.server = marked[0]
                // Done once the server is gone: a firewall that stays after it costs nothing (its NIT).
                if !(await remove(found, call)).serverStays { return }
            }
        }
    }

    /// The error of a call for the server that the provider did not answer with one: after the provider's own fault
    /// answer, the server that it made all the same is `made.server` (`madeMeanwhile`), or the call ends `Unsure`.
    private func failed(_ answer: CloudCall.Answer, _ made: inout Made, _ call: CloudCall) async throws -> CloudError {
        let fault = call.failure(answer)
        guard answer.status >= 500 else { return fault }
        var says = if case .refused(_, let words) = fault { words } else { fault.errorDescription ?? "" }
        while says.hasSuffix(".") { says.removeLast() }         // the line's own brackets end it (its NIT 5)
        let unsure = CloudError.unsure(provider, says: says, server: made.name, mark: made.firewallName)
        made.server = try await madeMeanwhile(made, call, unsure: unsure)
        return .takenBack(provider, says: says, server: made.name)
    }

    /// **A success to the call for the server, with no id that this app reads** (the PC readers' point 1 of 26 November
    /// 2026): the provider made the server, so the servers with this call's mark are read, as after a fault answer.
    /// The one there is `made.server`, which `undo` then deletes with the rest; every other end is `unread`, and
    /// nothing is taken back, as after `unsure`. Before, the firewall went with no read, and at Akamai a Linode that
    /// stayed had none.
    private func unread(_ made: inout Made, _ call: CloudCall) async throws -> CloudError {
        let unsure = CloudError.unread(provider, server: made.name, mark: made.firewallName)
        made.server = try await madeMeanwhile(made, call, unsure: unsure)
        return .unreadTakenBack(provider, server: made.name)
    }

    /// The call for the server, whose answer this Mac may not get: a time-out, a connection that ended, or the owner's
    /// Back while it was on its way. The provider can have made the server all the same (the Door area's read of
    /// ab7318f29, its MUST 1), so the servers with the call's mark are read as after a fault answer: the one there goes
    /// with the rest, and the call ends as not reached; else the end is not known, in the words of a call with no
    /// answer (its read of 318167959, SHOULD 3).
    private func create(_ path: String, _ body: [String: Any], _ made: inout Made, _ call: CloudCall) async throws
        -> CloudCall.Answer {
        do { return try await call.answer("POST", path, body: body) } catch CloudError.unreachable {
            let unsure = CloudError.unsure(provider, says: nil, server: made.name, mark: made.firewallName)
            made.server = try await madeMeanwhile(made, call, unsure: unsure)
            throw CloudError.takenBack(provider, says: nil, server: made.name)
        }
    }

    /// Takes away what one call made, and says so when it could not. It runs as a task of its own, so that a create the
    /// owner cancelled still leaves no server running at his cost.
    private func undo(_ made: Made, after error: Error, _ call: CloudCall) async -> Error {
        let removed = await Task { await self.remove(made, call) }.value
        guard !removed.left.isEmpty else { return error }
        // A server that the call found and could not delete is said in the provider's own words, never as deleted.
        let (said, found): (Error, Bool) = switch error as? CloudError {
        case .takenBack(_, let says, _)?: (says.map { CloudError.refused(provider, $0) } ?? CloudError.unreachable(provider), true)
        case .unreadTakenBack?: (CloudError.notUnderstood(provider), true)
        default: (error, false)
        }
        // One that the mark read found and that does not go now (Hetzner's `locked` while it still makes the server) is
        // read for and deleted in the hour after, as one that comes late (the PC readers' point 5 and the Vault area's
        // SHOULD 3 of 26 November 2026): else it runs on at the owner's cost.
        if found, removed.serverStays { followUp(made, call) }
        let reason = (said as? LocalizedError)?.errorDescription ?? String(describing: said)
        return CloudError.leftBehind(provider, reason: reason, left: removed.left)
    }

    /// Deletes the server, then its firewall, and answers what is still there. At Hetzner and Vultr a firewall goes only
    /// once no server uses it, which the server's own deletion ends, so it is asked again while that deletion runs. A
    /// server that does not go keeps its firewall (the validation of c64b10b03, S1): Akamai deletes a firewall that a
    /// Linode uses, which would leave that server open. Hetzner refuses to delete a server that is still being made
    /// (`locked`), so that deletion is asked again while it is (its S6).
    private func remove(_ made: Made, _ call: CloudCall) async -> (left: [String], serverStays: Bool) {
        var left: [String] = [], serverStays = false
        if let server = made.server {
            var answer = try? await call.answer("DELETE", provider.serverPath(server))
            for _ in 1..<Self.removeReads where answer?.code == "locked" {
                try? await pause(Self.waitStep)
                answer = try? await call.answer("DELETE", provider.serverPath(server))
            }
            if let answer, answer.ok || answer.status == 404 {
                // Hetzner's deletion is an action: one that ends in an error leaves the server there (the Door area's
                // read of ab7318f29, its NIT 7).
                if let action = (answer.object["action"] as? [String: Any])?["id"] as? Int,
                   (try? await hetznerWait(action: action, call)) == nil {
                    serverStays = true
                }
            } else {
                serverStays = true
            }
            if serverStays { left.append(String(l10n: "the server \(made.name)")) }
        }
        if made.firewall != nil, serverStays {
            left.append(String(l10n: "the firewall \(made.firewallName)"))
        } else if let firewall = made.firewall {
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
        return (left, serverStays)
    }

    // MARK: - Deleting what this app made, one thing at a time ("Start again")

    /// A provider's own id of a server, a firewall or a key, as it may stand in a path: digits, or letters, digits and
    /// hyphens (Vultr's), the whole of it (a pattern's `$` also stands before a last line end).
    static func isID(_ id: String) -> Bool {
        (1...64).contains(id.utf8.count) && id.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || byte == 0x2D
        }
    }

    /// **Deletes one server by the provider's own id of it, and nothing else**: never "the server of this name" and
    /// never "the servers with this label". At Hetzner a deletion is an action, which is read until it ends: one that
    /// ends with an error says so in Hetzner's words, and one that still runs after every read is settled by one read
    /// of the server itself.
    ///
    /// **A 404 is not the same as a deletion**, and the answer says which it was (`CloudDeletion`): the provider has
    /// no server of this id for this token. That is a server that is gone, and it is also a server of another project
    /// or account than the token's. The caller decides with what else it knows (`StartAgain.isAlive`).
    ///
    /// `accepted` is called at the moment the provider takes the deletion, before the wait for its end: a wait that
    /// is cut off (the page closed) or that ends with an error leaves a server that the provider is deleting, and the
    /// caller knows that from then on.
    @discardableResult
    public func deleteServer(id: String, accepted: (@Sendable () -> Void)? = nil) async throws -> CloudDeletion {
        guard Self.isID(id) else { throw CloudError.notUnderstood(provider) }
        let call = try heldCall()
        if provider == .hostinger { return try await hostingerEnd(id, accepted: accepted, call) }
        let answer = try await call.answer("DELETE", provider.serverPath(id))
        if answer.status == 404 { return .notThere(call.failure(answer)) }
        guard answer.ok else { throw call.failure(answer) }
        accepted?()
        guard let action = (answer.object["action"] as? [String: Any])?["id"] as? Int else { return .deleted }
        for _ in 0..<Self.waitReads {
            let state = try await read("actions/\(action)", call)?["action"] as? [String: Any]
            switch state?["status"] as? String {
            case "success": return .deleted
            case "error":
                let error = state?["error"] as? [String: Any]
                throw CloudError.refused(provider, (error?["message"] as? String) ?? (error?["code"] as? String) ?? "error")
            default: try await pause(Self.waitStep)
            }
        }
        let left = try await call.answer("GET", provider.serverPath(id))
        guard left.status == 404 else { throw left.ok ? CloudError.notUnderstood(provider) : call.failure(left) }
        return .deleted
    }

    /// **Whether a firewall's name is one that this app gave the firewall of a server of this name** (`firewallName`):
    /// the same start, then exactly six characters of a to z and 0 to 9, and nothing more. So the firewall of
    /// `worker-1` is never taken for the firewall of `worker-10` or of a server whose name only starts so.
    static func isFirewallName(_ candidate: String, ofServer name: String, at provider: CloudProvider) -> Bool {
        let model = firewallName(name, at: provider)
        let start = String(model.dropLast(6))
        guard candidate.count == model.count, candidate.hasPrefix(start) else { return false }
        return candidate.dropFirst(start.count).allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
    }

    /// **The firewalls that this app made for a server of this name**, from the provider's own list: by the exact form
    /// of their name (`isFirewallName`), and at Hetzner only with the label that this app gives its firewalls there.
    /// Each comes with the servers that it stands in front of now, where the provider's list names them. A provider's
    /// list is read whole (Hetzner and Akamai page by page).
    public func firewalls(ofServer name: String) async throws -> [CloudFirewall] {
        guard Self.isName(name) else { return [] }
        let call = try heldCall()
        func mine(_ candidate: String?) -> Bool {
            candidate.map { Self.isFirewallName($0, ofServer: name, at: provider) } ?? false
        }
        switch provider {
        case .hetzner:
            var found: [CloudFirewall] = [], page = 1
            for _ in 0..<20 {
                let listed = try await call.send("GET", "firewalls", query: [
                    URLQueryItem(name: "label_selector", value: "founderizer"), URLQueryItem(name: "per_page", value: "50"),
                    URLQueryItem(name: "page", value: String(page))])
                for firewall in (listed["firewalls"] as? [[String: Any]]) ?? [] {
                    guard let id = firewall["id"] as? Int, mine(firewall["name"] as? String),
                          (firewall["labels"] as? [String: Any])?["founderizer"] != nil else { continue }
                    let uses = (firewall["applied_to"] as? [[String: Any]]) ?? []
                    let servers = uses.compactMap { (($0["server"] as? [String: Any])?["id"] as? Int).map(String.init) }
                    found.append(CloudFirewall(id: String(id), servers: servers, other: servers.count != uses.count))
                }
                let pages = (listed["meta"] as? [String: Any])?["pagination"] as? [String: Any]
                guard let next = pages?["next_page"] as? Int, next > page else { break }
                page = next
            }
            return found
        case .digitalOcean:
            let listed = try await call.send("GET", "firewalls", query: [URLQueryItem(name: "per_page", value: "200")])
            return ((listed["firewalls"] as? [[String: Any]]) ?? []).compactMap { firewall in
                guard mine(firewall["name"] as? String), let id = firewall["id"] as? String else { return nil }
                // A firewall whose list of droplets the answer does not give is not known to be free.
                guard let droplets = firewall["droplet_ids"] as? [Any] else { return CloudFirewall(id: id, servers: [], other: true) }
                let servers = droplets.compactMap { ($0 as? Int).map(String.init) }
                return CloudFirewall(id: id, servers: servers,
                                     other: servers.count != droplets.count || !((firewall["tags"] as? [Any]) ?? []).isEmpty)
            }
        case .vultr:
            // Vultr's list gives only how many servers a group stands in front of, not which: a group with one, or
            // with a count that the answer does not give, is in use.
            let listed = try await call.send("GET", "firewalls", query: [URLQueryItem(name: "per_page", value: "500")])
            return ((listed["firewall_groups"] as? [[String: Any]]) ?? []).compactMap { group in
                guard mine(group["description"] as? String), let id = group["id"] as? String else { return nil }
                return CloudFirewall(id: id, servers: [], other: group["instance_count"] as? Int != 0)
            }
        case .akamai:
            var found: [CloudFirewall] = [], page = 1
            for _ in 0..<20 {
                let listed = try await call.send("GET", "networking/firewalls", query: [
                    URLQueryItem(name: "page_size", value: "100"), URLQueryItem(name: "page", value: String(page))])
                for firewall in (listed["data"] as? [[String: Any]]) ?? [] {
                    guard let id = firewall["id"] as? Int, mine(firewall["label"] as? String) else { continue }
                    // The devices of the firewall, by its own list: a Linode by its id, anything else as another use.
                    let devices = (try await call.send("GET", "networking/firewalls/\(id)/devices",
                                                       query: [URLQueryItem(name: "page_size", value: "500")])["data"]
                        as? [[String: Any]])
                    guard let devices else { found.append(CloudFirewall(id: String(id), servers: [], other: true)); continue }
                    let servers = devices.compactMap { device -> String? in
                        guard let entity = device["entity"] as? [String: Any], entity["type"] as? String == "linode",
                              let linode = entity["id"] as? Int else { return nil }
                        return String(linode)
                    }
                    found.append(CloudFirewall(id: String(id), servers: servers, other: servers.count != devices.count))
                }
                guard let pages = listed["pages"] as? Int, page < pages else { break }
                page += 1
            }
            return found
        case .hostinger:
            // This app makes no firewall at Hostinger (`hostinger`).
            return []
        }
    }

    /// **Deletes the firewalls that this app made for a server of this name, after this run deleted that server.**
    /// `deleted` are the provider's ids of the servers that the run deleted.
    ///
    /// - **Hetzner** refuses to delete a firewall that a server still uses (`resource_in_use`, Hetzner's own
    ///   document), and is asked again as `remove` asks (`deleteFirewall`): one that stays in use is the call's error.
    /// - **DigitalOcean and Akamai** delete a firewall that is in use. There a firewall that stands in front of any
    ///   server but the deleted ones, or that something else uses, is another server's firewall now: it stays, and
    ///   it is not asked.
    /// - **Vultr** says only how many servers a group has, and this app does not rely on a refusal of Vultr's: a
    ///   group that still has a server is read again while the server's own deletion can still run, a counted number
    ///   of times, and one that has a server after them stays, and is not asked.
    ///
    /// Every firewall that may go is asked, also after one that failed: the first error is the call's.
    public func deleteFirewalls(ofServer name: String, deleted: Set<String>) async throws {
        var found = try await firewalls(ofServer: name)
        if provider == .vultr {
            var reads = 1
            while reads < Self.removeReads, found.contains(where: { !$0.isFree(of: deleted) }) {
                try await pause(Self.waitStep)
                found = try await firewalls(ofServer: name)
                reads += 1
            }
        }
        var failed: Error?
        for firewall in found {
            if provider != .hetzner, !firewall.isFree(of: deleted) { continue }
            do { try await deleteFirewall(id: firewall.id) } catch { if failed == nil { failed = error } }
        }
        if let failed { throw failed }
    }

    /// **Deletes one firewall by its id.** One that is gone (404) is deleted already. One that a server's deletion
    /// still holds is asked again, `removeReads` times, as `remove` asks; one that is still held after them is a
    /// server's that stays, and the call says so in the provider's words.
    public func deleteFirewall(id: String) async throws {
        guard Self.isID(id) else { throw CloudError.notUnderstood(provider) }
        let call = try heldCall()
        var last: CloudCall.Answer?
        for _ in 0..<Self.removeReads {
            let answer = try await call.answer("DELETE", provider.firewallPath(id))
            if answer.ok || answer.status == 404 { return }
            last = answer
            let inUse = answer.code == "resource_in_use"
                || ([.vultr, .akamai].contains(provider) && ![401, 403].contains(answer.status))
            guard inUse else { break }
            try await pause(Self.waitStep)
        }
        throw last.map(call.failure) ?? CloudError.notUnderstood(provider)
    }

    /// **Deletes this app's own SSH key at the provider**, found by its fingerprint as `createServer` finds it (at
    /// Vultr by the key itself). No such key there: nothing is deleted. Akamai keeps no key of its own: a Linode
    /// takes the key's text when it is made.
    public func deleteKey(publicKey: String) async throws {
        guard let key = SSHPublicKey(publicKey) else { throw CloudError.notAPublicKey }
        guard provider != .akamai else { return }
        let call = try heldCall()
        let path: String
        switch provider {
        case .hetzner:
            let listed = try await call.send("GET", "ssh_keys", query: [URLQueryItem(name: "fingerprint", value: key.fingerprint)])
            guard let id = ((listed["ssh_keys"] as? [[String: Any]]) ?? [])
                .first(where: { $0["fingerprint"] as? String == key.fingerprint })?["id"] as? Int else { return }
            path = "ssh_keys/\(id)"
        case .digitalOcean:
            let found = try await call.answer("GET", "account/keys/\(key.fingerprint)")
            if found.status == 404 { return }
            guard found.ok, let id = (found.object["ssh_key"] as? [String: Any])?["id"] as? Int else {
                throw found.ok ? CloudError.notUnderstood(provider) : call.failure(found)
            }
            path = "account/keys/\(id)"
        case .vultr:
            let listed = try await call.send("GET", "ssh-keys", query: [URLQueryItem(name: "per_page", value: "500")])
            guard let id = ((listed["ssh_keys"] as? [[String: Any]]) ?? [])
                .first(where: { Self.sameKey($0["ssh_key"] as? String, key) })?["id"] as? String, Self.isID(id) else { return }
            path = "ssh-keys/\(id)"
        case .akamai: return
        case .hostinger:
            guard let id = try await hostingerList("vps/v1/public-keys", call)
                .first(where: { Self.sameKey($0["key"] as? String, key) })?["id"] as? Int else { return }
            path = "vps/v1/public-keys/\(id)"
        }
        let answer = try await call.answer("DELETE", path)
        guard answer.ok || answer.status == 404 else { throw call.failure(answer) }
    }

    /// A JSON value that is there and not null.
    static func isSet(_ value: Any?) -> Bool { value != nil && !(value is NSNull) }
}

/// Hetzner Cloud, DigitalOcean, Vultr, Akamai and Hostinger: the providers a server can be made at from this Mac, in the
/// order their cards stand.
public enum CloudProvider: String, CaseIterable, Codable, Sendable {
    case hetzner
    case digitalOcean = "digitalocean"
    case vultr
    /// Akamai Cloud, which was Linode: its API and its console keep Linode's names.
    case akamai
    /// Hostinger's VPS, which bill by the month or longer (the owner, 25 November 2026: "we also need to add support
    /// for Contabo and Hostinger", and his "Also buy from the app").
    case hostinger

    /// **The providers whose card the owner's screen shows**, in their order. A provider joins it only after the
    /// owner's yes to its card (AGENTS.md, "The owner's screen"): Hostinger's waits for his answer to the mock-up of
    /// 25 November 2026 (`~/dev/founderizer-plans/providers-contabo-hostinger-2026-11-25`).
    public static let shown: [CloudProvider] = [.hetzner, .digitalOcean, .vultr, .akamai]

    /// **The cards of Add server**: the first run's, and Hostinger after them (the owner's "Yes, as drawn" of 25
    /// November 2026, and his "Buy in the app demo"). The first run's page, which can make two servers at once, takes it
    /// in a step of its own.
    public static let addServer: [CloudProvider] = shown + [.hostinger]

    /// **Its step-by-step guide on founderizer.com**, in the language of the app's words (the owner's "Yes, as drawn" of
    /// 25 November 2026 to the link under each key page's field): nil for a provider whose guide is not on the site.
    public func guide(language: String?) -> URL? {
        // Hostinger's guide joins once its page is live on the site.
        guard [.hetzner, .digitalOcean, .vultr, .akamai].contains(self) else { return nil }
        let spanish = language.map { $0 == "es" || $0.hasPrefix("es-") || $0.hasPrefix("es_") } == true
        return URL(string: "https://founderizer.com\(spanish ? "/es" : "")/guides/\(rawValue)")
    }

    /// Its guide for the words that the app shows now (`Localized.bundle`), as `ErrorReports.privacyPage` is.
    public var guidePage: URL? { guide(language: AgentPrompt.language(of: Localized.bundle)) }

    /// **A provider that bills by the month or longer**, where a server that this app makes is bought, and a remove
    /// ends its renewal in place of a delete.
    public var billsMonthly: Bool { self == .hostinger }

    public var name: String {
        switch self {
        case .hetzner: "Hetzner"
        case .digitalOcean: "DigitalOcean"
        case .vultr: "Vultr"
        case .akamai: "Akamai"
        case .hostinger: "Hostinger"
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
        case .hostinger: URL(string: "https://developers.hostinger.com/api")!
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
        // The start of the template's name in Hostinger's list ("Ubuntu 24.04 LTS"), whose id is read there.
        case .hostinger: "Ubuntu \(CloudServers.ubuntu)"
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
        // A Hostinger token has the rights of the user that made it: no token of it can only read.
        case .hostinger: []
        }
    }

    /// The path of one server at this provider, and of one firewall.
    func serverPath(_ id: String) -> String {
        switch self {
        case .hetzner: "servers/\(id)"
        case .digitalOcean: "droplets/\(id)"
        case .vultr: "instances/\(id)"
        case .akamai: "linode/instances/\(id)"
        case .hostinger: "vps/v1/virtual-machines/\(id)"
        }
    }

    func firewallPath(_ id: String) -> String {
        switch self {
        case .akamai: "networking/firewalls/\(id)"
        case .hostinger: "vps/v1/firewall/\(id)"
        default: "firewalls/\(id)"
        }
    }

    /// DigitalOcean's droplet for each use: its smallest that the server check takes, 2 GB for both since 21 November
    /// 2026. Hetzner's type comes from Hetzner's own list (`CloudServers.fits`).
    static func digitalOceanSize(for use: CloudServerUse) -> String { "s-1vcpu-2gb" }

    /// The locations this app makes servers in, each with the standard offset of its time zone from UTC, in hours, in
    /// the order this app prefers them when two are as near.
    var locations: [(name: String, hours: Double)] {
        switch self {
        case .hetzner: [("fsn1", 1), ("nbg1", 1), ("hel1", 2), ("ash", -5), ("hil", -8), ("sin", 8)]
        case .digitalOcean: [("fra1", 1), ("ams3", 1), ("lon1", 0), ("nyc3", -5), ("sfo3", -8), ("sgp1", 8)]
        case .vultr: [("fra", 1), ("ams", 1), ("lhr", 0), ("ewr", -5), ("sjc", -8), ("sgp", 8)]
        case .akamai: [("eu-central", 1), ("nl-ams", 1), ("eu-west", 0), ("us-east", -5), ("us-west", -8), ("ap-south", 8)]
        // Hostinger's data centers come from its own list, with their cities (`CloudServers.hostingerNear`).
        case .hostinger: []
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
        locations.enumerated()
            .sorted { (Self.apart(zone, $0.element.hours, at: date), $0.offset) < (Self.apart(zone, $1.element.hours, at: date), $1.offset) }
            .map(\.element.name)
    }

    /// How many hours a place of this standard offset from UTC is from the Mac's zone around the clock, in standard time.
    static func apart(_ zone: TimeZone, _ hours: Double, at date: Date = Date()) -> Double {
        let here = (Double(zone.secondsFromGMT(for: date)) - zone.daylightSavingTimeOffset(for: date)) / 3600
        let apart = abs(here - hours).truncatingRemainder(dividingBy: 24)
        return min(apart, 24 - apart)
    }

    /// A pasted token, trimmed, or the reason it is not one. Nothing goes to the provider before this.
    func token(_ given: String) throws -> String {
        let token = given.trimmingCharacters(in: .whitespacesAndNewlines)
        // Hostinger does not say the form of its tokens: a `|` between an id and the secret is let through too.
        let form = self == .hostinger ? "^[A-Za-z0-9_|.-]+$" : "^[A-Za-z0-9_-]+$"
        guard (20...256).contains(token.count), !token.hasPrefix("tskey-"),
              token.range(of: form, options: .regularExpression) != nil else { throw CloudError.notAToken(self) }
        return token
    }
}

/// How a call to delete a server ended, when it did not fail (`CloudServers.deleteServer`).
public enum CloudDeletion: Equatable, Sendable {
    /// The provider took the deletion.
    case deleted
    /// The provider has no server of this id for this token (404), with its answer as this app's error: the server
    /// is gone, or it is in another project or account than the token's.
    case notThere(CloudError)
}

/// One firewall that this app made for a server, as the provider's list gives it (`CloudServers.firewalls`).
public struct CloudFirewall: Equatable, Sendable {
    /// The provider's own id of it.
    public let id: String
    /// The provider's ids of the servers that it stands in front of now, where the list names them.
    public let servers: [String]
    /// Something that the list does not name by a server's id uses it: a label or a tag that applies it, a device
    /// that is no server, a list of its servers that the answer did not give, or, at Vultr, a count of servers that
    /// is not zero.
    public let other: Bool

    public init(id: String, servers: [String], other: Bool) { self.id = id; self.servers = servers; self.other = other }

    /// Nothing uses it but the servers that a run deleted.
    public func isFree(of deleted: Set<String>) -> Bool { !other && Set(servers).isSubset(of: deleted) }
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
    /// Its cores are its own (Hetzner's `cpu_type` "dedicated"), not shared with other servers.
    var dedicated = false
    /// The provider's own name of the plan, where the row shows it ("KVM 2" at Hostinger).
    var plan: String? = nil
    /// What the first month costs, where it is not what each month after it costs (Hostinger's first-period price).
    var firstPrice: Decimal? = nil
    /// Its city and country, where the provider's own list says it (Hostinger's data centers).
    var city: String? = nil
    /// A server that the account bought already and did not set up: making it costs nothing more.
    var paid = false
    /// Such a server's own name at the provider ("srv123456"), the title of its row.
    var label: String? = nil
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
    /// Its cores are its own, not shared with other servers (Hetzner's dedicated types).
    public var dedicated = false
    /// The provider's own name of the plan ("KVM 2" at Hostinger), where the row shows it.
    public var plan: String? = nil
    /// What the first month costs where it differs from `monthlyPrice` (Hostinger's first-period price).
    public var firstPrice: Decimal? = nil
    /// Its city and country from the provider's own list, where this app has no words of its own for the location.
    public var city: String? = nil
    /// **A server that the account bought already and did not set up**: the press sets it up and charges nothing.
    public var paid = false
    /// Such a server's own name at the provider ("srv123456"), the title of its row.
    public var label: String? = nil

    /// The city and country of its location, in this app's own words ("Nuremberg, Germany").
    public var place: String { city ?? provider.place(location) }

    /// Its name in a set of offers (`CloudServers.offer(use:except:)`).
    public var key: String { CloudServers.key(type, location) }

    /// **Its row in the list under a server** (`CloudServers.offers`): Hetzner's type; another provider's size.
    public var kind: String {
        CloudServers.kind(provider, type: type, cores: cores, memoryGB: memoryGB, dedicated: dedicated)
    }
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

/// **What a stop of a server's page leads to** (`FleetCloudModel` in the app): the token asked for again, or the list
/// read again with its press. The owner, 15 November 2026, of a page that asked for the token after "no server free":
/// "asks for the token again!! when it is already there!"
public enum CloudStop {
    /// The provider's refusal of the token itself, after which the page asks for a token again: every other stop keeps
    /// the token that the provider took.
    public static func refusesToken(_ error: Error) -> Bool {
        switch error as? CloudError {
        case .notAToken, .noToken, .tokenNotAccepted, .readOnlyToken: true
        default: false
        }
    }

    /// **A build's stop after which the list is read again, with its press**: nothing of the try can be at the provider,
    /// and another press can do better. The server that the owner said yes to is taken (the next free one shows), none
    /// is free, it did not come up and was deleted, or the provider asked to wait; before the call for the server
    /// (`called` false), anything but the network's own key, which no press on that page can mend. Every other stop
    /// keeps the line alone: a provider's refusal can be its own fault answer (a 502), after which the server can be
    /// there all the same (`BuildRecord.AtProvider`), and a press at once could make a second one.
    public static func readsListAgain(after error: Error, called: Bool) -> Bool {
        if let error = error as? CloudError {
            switch error {
            // A full account reads the choice again too: its "Another provider" is the way on (slice 3).
            case .taken, .noRoom, .notReady, .rateLimited, .full: return called
            default: return false
            }
        }
        guard !called else { return false }
        switch error as? FleetKeyError {
        case .fleetKeyEnded, .noFleetKey: return false
        default: return true
        }
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
    /// **The provider answered the call that makes the server with a fault of its own (a 5xx), in these words, or did
    /// not answer it at all (`says` nil), and can have made it all the same** (`CloudServers.madeMeanwhile`): this Mac
    /// does not know whether `server` is there, and looks for it for an hour while this app runs (followUp). `mark` is
    /// the call's own firewall, or at DigitalOcean its tag, by which the owner tells that server from another of the
    /// same name in the provider's own pages (the Door area's read of b7214a0df). At Hostinger, the setup of a VPS that
    /// the account bought (`hostingerSetUp`): `mark` is that VPS's id, and nothing is looked for or deleted.
    case unsure(CloudProvider, says: String?, server: String, mark: String)
    /// The provider answered that call with a fault of its own (`says`), or not at all (nil), and had made `server` all
    /// the same; this app deleted it, with what else the call made (the validation of 2be411f3b: "refused" was untrue).
    case takenBack(CloudProvider, says: String?, server: String)
    /// **The provider answered that call with a success that holds no id that this app reads, and no one server with
    /// the call's own mark was there** (`CloudServers.unread`; the PC readers' point 1 of 26 November 2026): the
    /// provider can have made `server`, so this app looks for it for an hour while it runs, as after `unsure`.
    case unread(CloudProvider, server: String, mark: String)
    /// The provider answered that call with a success that this app could not read, and the one server with the
    /// call's mark was `server`: this app deleted it, with what else the call made.
    case unreadTakenBack(CloudProvider, server: String)
    /// The provider answered something this app does not understand.
    case notUnderstood(CloudProvider)
    /// The provider has no type that fits free in any location now.
    case noRoom(CloudProvider)
    /// **The account has no room for another server** (its limit of servers; slice 3 of the one wizard, the owner's
    /// picture of 17 November 2026): no type of this provider helps, another provider may.
    case full(CloudProvider)
    /// The server that the owner said yes to is not free any more: the provider refused it as taken, or no longer lists
    /// it as free. Nothing was made; the next offer is the next free server.
    case taken(CloudProvider)
    /// The server did not come up in time.
    case notReady(CloudProvider)
    /// What the caller gave is not of the shape a server needs.
    case notAServerName, notAPublicKey, notAnAuthKey
    /// A step failed, and this app could not delete all it had made: `left` says what is still there.
    case leftBehind(CloudProvider, reason: String, left: [String])
    /// The account has no card that the provider can charge for a new server.
    case noPaymentMethod(CloudProvider)
    /// The provider still takes the payment for a new server, which it sets up only after that.
    case paymentPending(CloudProvider)
    /// A server that the account bought did not come up in time, by its name and, when the provider gave it, its id. It
    /// stays in the account, paid: nothing deletes it, and its record keeps the id (`BuildRecord.callEnded`).
    case paidNotReady(CloudProvider, String, String?)

    /// A call's own mark in the words of the provider's own pages: the firewall that its server stands behind, or at
    /// DigitalOcean the tag that its droplet carries.
    static func marked(_ mark: String, at provider: CloudProvider) -> String {
        provider == .digitalOcean ? String(l10n: "with the tag \(mark)") : String(l10n: "behind the firewall \(mark)")
    }

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
        // Hostinger's setup of a VPS that the account bought (`hostingerSetUp`): nothing there to look for or delete.
        case .unsure(.hostinger, let says?, let server, _):
            String(l10n: "Hostinger answered with a fault of its own (\(says)), so it may still set up \(server) on your VPS. Wait a few minutes: if the VPS still shows here as bought and not set up, choose it again.")
        case .unsure(.hostinger, nil, let server, _):
            String(l10n: "Hostinger did not answer the call that sets up \(server), so it may still set it up on your VPS. Wait a few minutes: if the VPS still shows here as bought and not set up, choose it again.")
        case .unsure(let provider, let says?, let server, let mark):
            String(l10n: "\(provider.name) answered with a fault of its own (\(says)), so it may have made \(server) all the same. While this app is open, it looks for \(server) for an hour and deletes it if it comes. If you quit it sooner, delete the \(server) \(Self.marked(mark, at: provider)) at \(provider.name) if it is there.")
        case .takenBack(let provider, let says?, let server):
            String(l10n: "\(provider.name) answered with a fault of its own (\(says)), but it had made \(server) all the same, so this app deleted it.")
        case .takenBack(let provider, nil, let server):
            String(l10n: "\(provider.name) did not answer the call that makes \(server), but it had made it all the same, so this app deleted it.")
        case .unsure(let provider, nil, let server, let mark):
            String(l10n: "\(provider.name) did not answer the call that makes \(server), so it may have made it all the same. While this app is open, it looks for \(server) for an hour and deletes it if it comes. If you quit it sooner, delete the \(server) \(Self.marked(mark, at: provider)) at \(provider.name) if it is there.")
        case .unread(let provider, let server, let mark):
            String(l10n: "\(provider.name) may have made \(server), but this app cannot read its answer. While this app is open, it looks for \(server) for an hour and deletes it if it comes. If you quit it sooner, delete the \(server) \(Self.marked(mark, at: provider)) at \(provider.name) if it is there.")
        case .unreadTakenBack(let provider, let server):
            String(l10n: "\(provider.name) made \(server), but this app cannot read its answer, so this app deleted \(server).")
        case .notUnderstood(let provider): String(l10n: "\(provider.name) answered something this app does not understand.")
        // Every size that fits was asked, in every location: "smallest" and "near you" were not what was looked at.
        case .noRoom(let provider): String(l10n: "\(provider.name) has no server free now.")
        case .full(let provider): String(l10n: "\(provider.name) has no room for another server in your account.")
        case .taken(let provider): String(l10n: "That server is not free at \(provider.name) any more.")
        case .notReady(let provider): String(l10n: "The server did not come up at \(provider.name) in time, so it was deleted. Try again.")
        case .notAServerName: String(l10n: "Use a name of 2 to 31 characters: a-z, 0-9 and -, starting with a letter and not ending in -.")
        case .notAPublicKey: String(l10n: "This app's SSH public key could not be read.")
        case .notAnAuthKey: String(l10n: "The key for the private network is not a Tailscale auth key.")
        case .leftBehind(let provider, let reason, let left):
            left.count == 2
                ? String(l10n: "\(reason) This app could not delete \(left[0]) and \(left[1]): delete it at \(provider.name).")
                : String(l10n: "\(reason) This app could not delete \(left.joined(separator: " and ")): delete it at \(provider.name).")
        case .noPaymentMethod(let provider):
            String(l10n: "\(provider.name) has no default card that it can charge in your account. Set one at \(provider.name), then try again.")
        case .paymentPending(let provider):
            String(l10n: "\(provider.name) still takes the payment. When it ends, \(provider.name) may set up the server by itself; if it does not, the server shows here as bought and not set up: choose it then.")
        case .paidNotReady(let provider, let name, _):
            String(l10n: "\(name) did not come up at \(provider.name) in time. It stays in your account, paid: choose it here when it runs, or see it at \(provider.name).")
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
        // The account's limit of servers: Hetzner's code, DigitalOcean's words ("will exceed your droplet limit").
        if provider == .hetzner, answer.code == "resource_limit_exceeded" { return .full(provider) }
        if provider == .digitalOcean, answer.says.localizedCaseInsensitiveContains("droplet limit") { return .full(provider) }
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
        // A gateway's own page (a 502 or 504 of HTML) is no words for the owner (the validation of c64b10b03, S5).
        let page = says.hasPrefix("<") || says.range(of: "<html", options: .caseInsensitive) != nil
        return says.isEmpty || page ? String(l10n: "it answered \(answer.status) and said nothing.") : String(says.prefix(300))
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
