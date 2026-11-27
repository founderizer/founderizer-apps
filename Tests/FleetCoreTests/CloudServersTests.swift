import Foundation
import Testing
@testable import FleetCore

/// A server made at Hetzner Cloud, DigitalOcean, Vultr or Akamai from this Mac: the token the owner pastes once, where the server goes,
/// what it is made of, and what is taken back when a step fails. Every request is proved against a stand-in for the
/// provider, so none of this needs a network, an account or a real token, and nothing is ever made anywhere.
struct CloudServersTests {
    private static let token = "notarealtoken0123456789notarealtoken0123456789notarealtoken0123"
    /// A key made for this test with `ssh-keygen -t ed25519`, whose private half was thrown away, and its fingerprint as
    /// `ssh-keygen -l -E md5` printed it.
    private static let publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAo/DN+NoNbdAzU3DYGLTD7ne5vXT9bm+oEyoiacxwWg founderizer-test"
    private static let fingerprint = "72:10:e7:12:0f:70:ca:e3:25:aa:b4:7c:4c:b1:75:24"
    private static let authKey = "tskey-auth-kAUTH1234CNTRL-notarealkey"
    private static let berlin = TimeZone(identifier: "Europe/Berlin")!

    private static func servers(_ provider: CloudProvider, _ stand: ProviderStandIn, shelf: MemoryShelf? = nil,
                                zone: TimeZone = berlin, follows: Follows = Follows()) -> CloudServers {
        CloudServers(provider: provider, exchange: stand.exchange, shelf: shelf ?? MemoryShelf(Data(token.utf8)), zone: zone,
                     pause: { _ in }, follow: follows.follow)
    }

    // MARK: - Where a server goes

    @Test func aServerGoesWhereTheMacIs() {
        func near(_ provider: CloudProvider, _ zone: String) -> [String] { provider.near(TimeZone(identifier: zone)!) }
        #expect(near(.hetzner, "Europe/Berlin") == ["fsn1", "nbg1", "hel1", "ash", "sin", "hil"])
        #expect(near(.hetzner, "Europe/Helsinki").first == "hel1")
        #expect(near(.hetzner, "America/New_York").prefix(2) == ["ash", "hil"])
        #expect(near(.hetzner, "America/Los_Angeles").prefix(2) == ["hil", "ash"])
        #expect(near(.hetzner, "Asia/Tokyo").first == "sin")
        #expect(near(.digitalOcean, "Europe/Madrid").prefix(3) == ["fra1", "ams3", "lon1"])
        #expect(near(.digitalOcean, "Europe/London").first == "lon1")
        #expect(near(.digitalOcean, "America/Chicago").prefix(2) == ["nyc3", "sfo3"])
        #expect(near(.digitalOcean, "America/Los_Angeles").first == "sfo3")
        #expect(near(.digitalOcean, "Asia/Singapore").first == "sgp1")
        #expect(near(.vultr, "Europe/Madrid").prefix(3) == ["fra", "ams", "lhr"])
        #expect(near(.vultr, "America/Los_Angeles").first == "sjc")
        #expect(near(.akamai, "Europe/London").first == "eu-west")
        #expect(near(.akamai, "America/New_York").first == "us-east")
        #expect(near(.akamai, "Asia/Singapore").first == "ap-south")
        // Standard time decides, so a summer does not move a Mac to another place.
        let summer = Date(timeIntervalSince1970: 1_782_000_000), winter = Date(timeIntervalSince1970: 1_767_000_000)
        #expect(CloudProvider.hetzner.near(Self.berlin, at: summer) == CloudProvider.hetzner.near(Self.berlin, at: winter))
        #expect(CloudProvider.hetzner.near(TimeZone(identifier: "America/Denver")!, at: summer).first == "hil")
    }

    @Test func eachProviderHasItsOwnNameForUbuntu2404AndItsSmallestTypes() {
        #expect(CloudServers.ubuntu == "24.04")
        #expect(CloudProvider.hetzner.image == "ubuntu-24.04")
        #expect(CloudProvider.digitalOcean.image == "ubuntu-24-04-x64")
        #expect(CloudProvider.digitalOceanSize(for: .hub) == "s-1vcpu-2gb")
        #expect(CloudProvider.digitalOceanSize(for: .agent) == "s-1vcpu-2gb")
        #expect(CloudProvider.hetzner.keychain.item.service == "com.founderizer.cloud.hetzner")
        #expect(CloudProvider.digitalOcean.keychain.item.service == "com.founderizer.cloud.digitalocean")
        #expect(CloudProvider.hetzner.api.absoluteString == "https://api.hetzner.cloud/v1")
        #expect(CloudProvider.digitalOcean.api.absoluteString == "https://api.digitalocean.com/v2")
        #expect(CloudProvider.vultr.image == "Ubuntu 24.04")
        #expect(CloudProvider.akamai.image == "linode/ubuntu24.04")
        #expect(CloudProvider.vultr.keychain.item.service == "com.founderizer.cloud.vultr")
        #expect(CloudProvider.akamai.keychain.item.service == "com.founderizer.cloud.akamai")
        #expect(CloudProvider.vultr.api.absoluteString == "https://api.vultr.com/v2")
        #expect(CloudProvider.akamai.api.absoluteString == "https://api.linode.com/v4")
        // The cards stand in this order.
        #expect(CloudProvider.allCases == [.hetzner, .digitalOcean, .vultr, .akamai])
        #expect(CloudProvider.allCases.map(\.name) == ["Hetzner", "DigitalOcean", "Vultr", "Akamai"])
    }

    /// **The first boot waits for apt's lock, then joins the private network once.** Tailscale's installer runs apt-get
    /// with no wait for the lock, which a new server's first updates hold for about nine minutes: so each try waits for
    /// it first, in the words of hub.py's TAILSCALE_INSTALL, which stand here character for character.
    @Test func theFirstBootWaitsForAptsLockThenJoinsThePrivateNetworkOnce() {
        let hubsWords = "for try in 1 2 3; do DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=1200 -q "
            + "install </dev/null >/dev/null 2>&1; curl -fsSL https://tailscale.com/install.sh | sh && "
            + "command -v tailscale >/dev/null && break; sleep 20; done"
        #expect(CloudServers.userData(authKey: Self.authKey, hostname: "hub-1") == """
        #!/bin/sh
        \(hubsWords)
        tailscale up --auth-key=tskey-auth-kAUTH1234CNTRL-notarealkey --hostname=hub-1 --accept-dns=false

        """)
    }

    /// **A first boot that meets the server's first updates waits for them, and then joins**, as cloud-init runs it: as
    /// root, under this Mac's `/bin/sh` and under dash, on the stand-in server of the network prompt's tests, whose
    /// apt-get needs dpkg's lock as apt's own does while the first updates hold it for 540 seconds more, and whose curl
    /// gives Tailscale's installer. A try that curl got no script for is made again after 20 seconds; after three such
    /// tries the server has no Tailscale, and it does not join. Until 11 November 2026 the boot ran the installer at once,
    /// whose apt-get stopped on the lock, so its server never joined.
    @Test func aFirstBootThatMeetsTheFirstUpdatesWaitsForThemAndJoins() throws {
        let firstBoot = CloudServers.userData(authKey: Self.authKey, hostname: "worker-3")
        for sh in NetworkPromptRootTests.shells {
            for misses in [0, 1, 3] {
                let server = try NetworkPromptRootTests.StandInServer()
                defer { server.remove() }
                try server.holdAptLock(540)
                try server.failCurl(misses)
                let ran = try server.boot(firstBoot, sh: sh)
                let who = "\(sh), \(misses) tries of curl with nothing"
                #expect(server.aptWaits == [540], "\(who): the boot waited \(server.aptWaits) seconds for apt's lock: \(ran.err)")
                #expect(server.slept == Array(repeating: 20, count: misses), "\(who): the boot slept \(server.slept)")
                #expect(server.installed == (misses < 3), "\(who): Tailscale there: \(server.installed): \(ran.err)")
                if misses < 3 {
                    #expect(ran.status == 0, "\(who): the boot ended with \(ran.status): \(ran.err)")
                    #expect(server.upInWords() == "--auth-key=\(Self.authKey) --hostname=worker-3 --accept-dns=false\n",
                            "\(who): tailscale up got \(String(describing: server.upInWords()))")
                } else {
                    #expect(ran.status != 0 && server.upInWords() == nil, "\(who): the boot ended with \(ran.status)")
                }
            }
        }
    }

    /// **The app waits for a new server until its key ends, one hour** (the owner's choice of 11 November 2026): a first
    /// boot that meets the server's first updates waits for them, about nine minutes, so its server comes after the five
    /// minutes that the app waited before. A server that is there but not online yet does not count, nor does another
    /// device. A server that never comes ends the wait when its key ends, with the step's one failure line, and Back
    /// ends the wait at once.
    @Test func theAppWaitsForANewServerUntilItsKeyEnds() async throws {
        #expect(CloudServers.joinKeyLife == 3600)
        let made = Date(timeIntervalSince1970: 1_800_000_000)
        let late = Clock(made)
        let address = try await CloudServers.joined("worker-3", since: made, status: {
            let gone = late.now.timeIntervalSince(made)
            return gone < 600 ? Self.network(nil) : Self.network(gone >= 620)
        }, now: { late.now }, pause: { late.pass($0) })
        #expect(address == .online("100.64.0.31"))
        #expect(late.now.timeIntervalSince(made) == 620)
        let never = Clock(made)
        let none = try await CloudServers.joined("worker-3", since: made, status: { Self.network(false) },
                                                 now: { never.now }, pause: { never.pass($0) })
        #expect(none == .ended)
        #expect(never.now.timeIntervalSince(made) == TimeInterval(CloudServers.joinKeyLife))
        #expect(CloudServers.notJoined("worker-3", at: .hetzner)
                == "worker-3 did not join your network within an hour. Open it in Hetzner's console.")
        let waiting = Task {
            try await CloudServers.joined("worker-3", since: made, status: { Self.network(false) }, now: { made },
                                          pause: { _ in try await Task.sleep(for: .seconds(3600)) })
        }
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        // Back during a read that sees the server: no install starts.
        let backDuringRead = Task {
            try await CloudServers.joined("worker-3", since: made, status: {
                withUnsafeCurrentTask { $0?.cancel() }
                return Self.network(true)
            }, now: { made }, pause: { _ in })
        }
        await #expect(throws: CancellationError.self) { try await backDuringRead.value }
        // A Mac that slept past the end: the last look still finds the server.
        let slept = Clock(made)
        let woke = try await CloudServers.joined("worker-3", since: made, status: {
            Self.network(slept.now.timeIntervalSince(made) > 3600)
        }, now: { slept.now }, pause: { _ in slept.pass(.seconds(3601)) })
        #expect(woke == .online("100.64.0.31"))
    }

    /// **A server that joined and that this Mac does not see is told after six minutes, not after the hour**: the
    /// tailnet's own list is read from five minutes on, once a minute, and when two reads in a row have the server the
    /// wait ends, so the step says why (`FleetReach`). A list without the server lets the wait go on; a server that
    /// the list has a moment before this Mac sees it is found.
    @Test func aServerThatJoinedOutOfThisMacsSightEndsTheWaitAfterFiveMinutes() async throws {
        let made = Date(timeIntervalSince1970: 1_800_000_000)
        let hidden = Clock(made), asked = Times()
        let none = try await CloudServers.joined("worker-3", since: made, status: { Self.network(false) }, listed: {
            asked.add(hidden.now.timeIntervalSince(made))
            return Self.listed
        }, now: { hidden.now }, pause: { hidden.pass($0) })
        #expect(none == .listed(Self.listed))
        #expect(asked.all == [300, 360])
        #expect(hidden.now.timeIntervalSince(made) == 360)
        let notYet = Clock(made), times = Times()
        let late = try await CloudServers.joined("worker-3", since: made, status: {
            Self.network(notYet.now.timeIntervalSince(made) >= 600 ? true : nil)
        }, listed: {
            times.add(notYet.now.timeIntervalSince(made))
            return nil
        }, now: { notYet.now }, pause: { notYet.pass($0) })
        #expect(late == .online("100.64.0.31"))
        #expect(times.all == [300, 360, 420, 480, 540])
        let between = Clock(made)
        let found = try await CloudServers.joined("worker-3", since: made, status: {
            Self.network(between.now.timeIntervalSince(made) > 300 ? true : nil)  // seen only after the list had it
        }, listed: { Self.listed }, now: { between.now }, pause: { between.pass($0) })
        #expect(found == .online("100.64.0.31"))
        #expect(between.now.timeIntervalSince(made) == 305)
    }

    /// worker-3 as the tailnet's own list has it (`TailscaleFleetKey.joined`).
    private static let listed = JoinedDevice(name: "worker-3", addresses: ["100.64.0.31"])

    /// The moments at which a stand-in was asked, in order.
    private final class Times: @unchecked Sendable {
        private let lock = NSLock()
        private var at: [TimeInterval] = []
        func add(_ time: TimeInterval) { lock.withLock { at.append(time) } }
        var all: [TimeInterval] { lock.withLock { at } }
    }

    /// This Mac's network as `tailscale status --json` gives it: another server online, and worker-3 when it is there.
    private static func network(_ online: Bool?) -> String {
        let three = online.map { #", "c": {"DNSName": "worker-3.tail1234.ts.net.", "TailscaleIPs": ["100.64.0.31"], "Online": \#($0)}"# }
        return #"{"Self": {"DNSName": "macbook.tail1234.ts.net."}, "Peer": {"a": {"DNSName": "worker-1.tail1234.ts.net.", "#
            + #""TailscaleIPs": ["100.96.100.130"], "Online": true}"# + (three ?? "") + "}}"
    }

    /// A clock that only the wait's own pauses move, so a wait of an hour takes no time.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var at: Date
        init(_ at: Date) { self.at = at }
        var now: Date { lock.withLock { at } }
        func pass(_ time: Duration) { lock.withLock { at += TimeInterval(time.components.seconds) } }
    }

    @Test func thisAppsKeyIsReadWithItsFingerprint() throws {
        let key = try #require(SSHPublicKey(Self.publicKey + "\n"))
        #expect(key.fingerprint == Self.fingerprint)
        #expect(key.line == Self.publicKey)
        #expect(key.name == "founderizer-7210e7120f70")
        // Not a key, a kind this app does not know, a key whose own bytes name another kind, and two lines.
        #expect(SSHPublicKey("") == nil)
        #expect(SSHPublicKey("ssh-dss AAAAB3NzaC1kc3MAAACBAP= x") == nil)
        #expect(SSHPublicKey(Self.publicKey.replacingOccurrences(of: "ssh-ed25519", with: "ssh-rsa")) == nil)
        #expect(SSHPublicKey(Self.publicKey + "\n" + Self.publicKey) == nil)
        #expect(SSHPublicKey("ssh-ed25519 not-base64!") == nil)
    }

    // MARK: - The token

    @Test func aHetznerTokenIsCheckedAndKept() async throws {
        let hetzner = ProviderStandIn()
        hetzner.answer("GET", "/v1/locations", 200, "{\"locations\":[{\"id\":1,\"name\":\"fsn1\"}]}")
        hetzner.answer("POST", "/v1/ssh_keys", 422, "{\"error\":{\"code\":\"invalid_input\",\"message\":\"invalid input\"}}")
        let shelf = MemoryShelf()
        try await Self.servers(.hetzner, hetzner, shelf: shelf).connect(token: "  \(Self.token)\n")
        #expect(shelf.held == Data(Self.token.utf8))
        // Whether it may write is asked with a write that cannot make anything.
        let probe = try #require(hetzner.call("POST", "/v1/ssh_keys"))
        #expect(probe.body == "{}")
        #expect(hetzner.calls.allSatisfy { $0.headers["Authorization"] == "Bearer \(Self.token)" && $0.url.host == "api.hetzner.cloud" })
        // A token that may only read is said to be one, by either word Hetzner has for it, and is not kept.
        for (status, code) in [(403, "forbidden"), (401, "token_readonly")] {
            let reader = ProviderStandIn()
            reader.answer("GET", "/v1/locations", 200, "{\"locations\":[]}")
            reader.answer("POST", "/v1/ssh_keys", status, "{\"error\":{\"code\":\"\(code)\",\"message\":\"insufficient permissions\"}}")
            let none = MemoryShelf()
            await #expect(throws: CloudError.readOnlyToken(.hetzner)) { try await Self.servers(.hetzner, reader, shelf: none).connect(token: Self.token) }
            #expect(none.held == nil)
        }
        // One Hetzner does not take is not asked anything more.
        let wrong = ProviderStandIn()
        wrong.answer("GET", "/v1/locations", 401, "{\"error\":{\"code\":\"unauthorized\",\"message\":\"unable to authenticate\"}}")
        await #expect(throws: CloudError.tokenNotAccepted(.hetzner)) { try await Self.servers(.hetzner, wrong).connect(token: Self.token) }
        #expect(wrong.calls.count == 1)
        // And what is not a token at all never reaches Hetzner.
        for pasted in ["", "short", "has spaces in it that make it no token", Self.authKey] {
            let unused = ProviderStandIn()
            await #expect(throws: CloudError.notAToken(.hetzner)) { try await Self.servers(.hetzner, unused).connect(token: pasted) }
            #expect(unused.calls.isEmpty)
        }
    }

    @Test func aDigitalOceanTokenIsCheckedAndKept() async throws {
        let ocean = ProviderStandIn()
        ocean.answer("GET", "/v2/account", 200, "{\"account\":{\"droplet_limit\":10,\"status\":\"active\",\"status_message\":\"\"}}")
        ocean.answer("POST", "/v2/account/keys", 422, "{\"id\":\"unprocessable_entity\",\"message\":\"Name is required\"}")
        let shelf = MemoryShelf()
        try await Self.servers(.digitalOcean, ocean, shelf: shelf).connect(token: Self.token)
        #expect(shelf.held == Data(Self.token.utf8))
        #expect(ocean.call("POST", "/v2/account/keys")?.body == "{}")
        let reader = ProviderStandIn()
        reader.answer("GET", "/v2/account", 200, "{\"account\":{\"status\":\"active\"}}")
        reader.answer("POST", "/v2/account/keys", 403, "{\"id\":\"forbidden\",\"message\":\"You do not have access for the attempted action.\"}")
        await #expect(throws: CloudError.readOnlyToken(.digitalOcean)) { try await Self.servers(.digitalOcean, reader).connect(token: Self.token) }
        let locked = ProviderStandIn()
        locked.answer("GET", "/v2/account", 200, "{\"account\":{\"status\":\"locked\",\"status_message\":\"Billing is overdue.\"}}")
        let none = MemoryShelf()
        await #expect(throws: CloudError.refused(.digitalOcean, "Billing is overdue.")) {
            try await Self.servers(.digitalOcean, locked, shelf: none).connect(token: Self.token)
        }
        #expect(none.held == nil)
    }

    // MARK: - A server at Hetzner

    private static let hetznerKeys = "{\"ssh_keys\":[{\"id\":42,\"name\":\"founderizer-7210e7120f70\",\"fingerprint\":\"\(fingerprint)\","
        + "\"public_key\":\"\(publicKey)\",\"labels\":{}}],\"meta\":{\"pagination\":{\"page\":1}}}"

    /// One of Hetzner's server types as `GET /server_types` lists it: free in some locations and taken in others, at one
    /// monthly price in Falkenstein, Nuremberg and Helsinki.
    private static func hetznerType(_ name: String, free: [String], taken: [String] = [], memory: Double = 4, disk: Int = 40,
                                    architecture: String = "x86", monthly: String = "4.1531", deprecated: Bool = false,
                                    cpuType: String = "shared") -> String {
        let locations = (free.map { "{\"id\":1,\"name\":\"\($0)\",\"deprecation\":null,\"available\":true,\"recommended\":true}" }
            + taken.map { "{\"id\":2,\"name\":\"\($0)\",\"deprecation\":null,\"available\":false,\"recommended\":false}" })
            .joined(separator: ",")
        let prices = ["fsn1", "nbg1", "hel1"].map {
            "{\"location\":\"\($0)\",\"price_hourly\":{\"net\":\"0.0056\",\"gross\":\"0.0067\"},"
                + "\"price_monthly\":{\"net\":\"3.4900\",\"gross\":\"\(monthly)\"},\"included_traffic\":21990232555520,"
                + "\"price_per_tb_traffic\":{\"net\":\"1.0000\",\"gross\":\"1.1900\"}}"
        }.joined(separator: ",")
        let deprecation = deprecated
            ? "{\"announced\":\"2026-01-01T00:00:00+00:00\",\"unavailable_after\":\"2026-04-01T00:00:00+00:00\"}" : "null"
        return "{\"id\":114,\"name\":\"\(name)\",\"cores\":2,\"memory\":\(memory),\"disk\":\(disk),\"cpu_type\":\"\(cpuType)\","
            + "\"architecture\":\"\(architecture)\",\"deprecation\":\(deprecation),\"prices\":[\(prices)],\"locations\":[\(locations)]}"
    }

    /// Hetzner's answer that lists these types, in its own order.
    private static func hetznerTypes(_ types: String...) -> String {
        "{\"server_types\":[\(types.joined(separator: ","))],\"meta\":{\"pagination\":{\"page\":1}}}"
    }

    private static let hetznerPricing = "{\"pricing\":{\"currency\":\"EUR\",\"vat_rate\":\"19.00\",\"primary_ips\":["
        + "{\"type\":\"ipv4\",\"prices\":[{\"location\":\"fsn1\",\"price_hourly\":{\"net\":\"0.0008\",\"gross\":\"0.0010\"},"
        + "\"price_monthly\":{\"net\":\"0.5000\",\"gross\":\"0.5950\"}},{\"location\":\"nbg1\",\"price_hourly\":{\"net\":\"0.0008\","
        + "\"gross\":\"0.0010\"},\"price_monthly\":{\"net\":\"0.5000\",\"gross\":\"0.5950\"}},{\"location\":\"hel1\","
        + "\"price_hourly\":{\"net\":\"0.0008\",\"gross\":\"0.0010\"},\"price_monthly\":{\"net\":\"0.5000\",\"gross\":\"0.5950\"}}]},"
        // An IPv6 address costs the same at each place, so it moves no hub to another place.
        + "{\"type\":\"ipv6\",\"prices\":[" + ["fsn1", "nbg1", "hel1"].map {
            "{\"location\":\"\($0)\",\"price_hourly\":{\"net\":\"0.0006\",\"gross\":\"0.0007\"},"
                + "\"price_monthly\":{\"net\":\"0.4200\",\"gross\":\"0.4998\"}}"
        }.joined(separator: ",") + "]}],\"server_types\":[]}}"

    private static let hetznerServer = "{\"server\":{\"id\":1001,\"name\":\"hub-1\",\"status\":\"initializing\",\"public_net\":"
        + "{\"ipv4\":{\"id\":5,\"ip\":\"203.0.113.10\",\"blocked\":false,\"dns_ptr\":\"static.example\"},\"ipv6\":null,"
        + "\"floating_ips\":[],\"firewalls\":[{\"id\":77,\"status\":\"pending\"}]}},"
        + "\"action\":{\"id\":501,\"command\":\"create_server\",\"status\":\"running\",\"error\":null},\"next_actions\":[],"
        + "\"root_password\":null}"

    /// A Hetzner project that answers everything, with cx23 free in Falkenstein and Nuremberg.
    private static func hetzner() -> ProviderStandIn {
        let hetzner = ProviderStandIn()
        hetzner.answer("GET", "/v1/ssh_keys", 200, hetznerKeys)
        hetzner.answer("GET", "/v1/pricing", 200, hetznerPricing)
        hetzner.answer("GET", "/v1/server_types", 200, hetznerTypes(
            hetznerType("cx23", free: ["fsn1", "nbg1"], taken: ["hel1"]),
            hetznerType("cax11", free: ["fsn1"], architecture: "arm", monthly: "4.7600")))
        hetzner.answer("POST", "/v1/firewalls", 201, "{\"firewall\":{\"id\":77,\"name\":\"x\",\"rules\":[]},\"actions\":[]}")
        hetzner.answer("POST", "/v1/servers", 201, hetznerServer)
        hetzner.answer("GET", "/v1/actions/501", 200, "{\"action\":{\"id\":501,\"status\":\"running\"}}")
        hetzner.answer("GET", "/v1/actions/501", 200, "{\"action\":{\"id\":501,\"status\":\"success\",\"error\":null}}")
        hetzner.answer("DELETE", "/v1/servers/1001", 200, "{\"action\":{\"id\":601,\"command\":\"delete_server\",\"status\":\"running\"}}")
        hetzner.answer("GET", "/v1/actions/601", 200, "{\"action\":{\"id\":601,\"status\":\"success\"}}")
        hetzner.answer("DELETE", "/v1/firewalls/77", 204, "")
        return hetzner
    }

    private static func make(_ provider: CloudProvider, _ stand: ProviderStandIn, use: CloudServerUse = .hub,
                             zone: TimeZone = berlin, follows: Follows = Follows()) async throws -> CloudServer {
        try await servers(provider, stand, zone: zone, follows: follows).createServer(name: "hub-1", use: use,
                                                                                       publicKey: publicKey, authKey: authKey)
    }

    @Test func aHetznerServerIsMadeNearTheMacBehindAFirewallThatLetsNothingIn() async throws {
        let hetzner = Self.hetzner()
        // A read of its creation that does not get through, and one Hetzner asks to wait with, say nothing about it.
        hetzner.clear("GET", "/v1/actions/501")
        hetzner.answer("GET", "/v1/actions/501", 200, "{\"action\":{\"id\":501,\"status\":\"running\"}}")
        hetzner.answer("GET", "/v1/actions/501", ProviderStandIn.dropped)
        hetzner.answer("GET", "/v1/actions/501", 429, "{\"error\":{\"code\":\"rate_limit_exceeded\",\"message\":\"limit\"}}")
        hetzner.answer("GET", "/v1/actions/501", 200, "{\"action\":{\"id\":501,\"status\":\"success\",\"error\":null}}")
        let server = try await Self.make(.hetzner, hetzner)
        // The provider's id, the address, and what it costs a month: the type and its public IPv4 and IPv6 addresses,
        // with tax.
        #expect(server == CloudServer(provider: .hetzner, id: "1001", name: "hub-1", ipv4: "203.0.113.10", type: "cx23",
                                      location: "fsn1", monthlyPrice: Decimal(string: "5.2479")!, currency: "EUR",
                                      firewallID: "77"))
        // The key is found by its fingerprint and not registered again.
        #expect(hetzner.call("GET", "/v1/ssh_keys")?.query == "fingerprint=\(Self.fingerprint)")
        #expect(hetzner.calls("POST", "/v1/ssh_keys").isEmpty)
        #expect(hetzner.calls("GET", "/v1/server_types").map(\.query) == ["per_page=50"])
        // A firewall with no rule: nothing comes in, and everything goes out.
        let firewall = try #require(hetzner.call("POST", "/v1/firewalls")?.object)
        #expect((firewall["rules"] as? [Any])?.isEmpty == true)
        #expect((firewall["name"] as? String)?.hasPrefix("founderizer-hub-1-") == true)
        let made = try #require(hetzner.call("POST", "/v1/servers")?.object)
        #expect(made["name"] as? String == "hub-1")
        #expect(made["server_type"] as? String == "cx23")
        #expect(made["location"] as? String == "fsn1")
        #expect(made["image"] as? String == "ubuntu-24.04")
        #expect(made["ssh_keys"] as? [Int] == [42])
        #expect((made["firewalls"] as? [[String: Int]]) == [["firewall": 77]])
        // The hub's server has IPv6 too, so that one failed lease of its IPv4 address does not take the fleet off the
        // network.
        #expect((made["public_net"] as? [String: Bool]) == ["enable_ipv4": true, "enable_ipv6": true])
        #expect(made["user_data"] as? String == CloudServers.userData(authKey: Self.authKey, hostname: "hub-1"))
        // Its creation is read until it ends, and nothing is taken back.
        #expect(hetzner.calls("GET", "/v1/actions/501").count == 4)
        #expect(!hetzner.calls.contains { $0.method == "DELETE" })
        #expect(hetzner.calls.allSatisfy { $0.url.scheme == "https" && $0.url.host == "api.hetzner.cloud" })
        // A server for agents has one public address, IPv4: the account's primary IPs are limited, and an IPv6 one is
        // priced too.
        let agents = Self.hetzner()
        #expect(try await Self.make(.hetzner, agents, use: .agent).monthlyPrice == Decimal(string: "4.7481")!)
        #expect((agents.call("POST", "/v1/servers")?.object?["public_net"] as? [String: Bool])
                == ["enable_ipv4": true, "enable_ipv6": false])
    }

    @Test func thisAppsKeyIsRegisteredOnceAtHetzner() async throws {
        let hetzner = Self.hetzner()
        hetzner.clear("GET", "/v1/ssh_keys")
        hetzner.answer("GET", "/v1/ssh_keys", 200, "{\"ssh_keys\":[],\"meta\":{\"pagination\":{\"page\":1}}}")
        hetzner.answer("POST", "/v1/ssh_keys", 201, "{\"ssh_key\":{\"id\":43,\"fingerprint\":\"\(Self.fingerprint)\"}}")
        _ = try await Self.make(.hetzner, hetzner)
        let registered = try #require(hetzner.call("POST", "/v1/ssh_keys")?.object)
        #expect(registered["name"] as? String == "founderizer-7210e7120f70")
        #expect(registered["public_key"] as? String == Self.publicKey)
        #expect(hetzner.call("POST", "/v1/servers")?.object?["ssh_keys"] as? [Int] == [43])
        // Registered by another window meanwhile: Hetzner says the fingerprint is taken, and the key is found again.
        let race = Self.hetzner()
        race.clear("GET", "/v1/ssh_keys")
        race.answer("GET", "/v1/ssh_keys", 200, "{\"ssh_keys\":[]}")
        race.answer("GET", "/v1/ssh_keys", 200, Self.hetznerKeys)
        race.answer("POST", "/v1/ssh_keys", 409, "{\"error\":{\"code\":\"uniqueness_error\",\"message\":\"SSH key with the same fingerprint already exists\"}}")
        _ = try await Self.make(.hetzner, race)
        #expect(race.call("POST", "/v1/servers")?.object?["ssh_keys"] as? [Int] == [42])
    }

    @Test func theNextTypeOrPlaceIsTriedWhenOneIsTaken() async throws {
        // No cx23 free anywhere: the Arm type, which is as small.
        let hetzner = Self.hetzner()
        hetzner.clear("GET", "/v1/server_types")
        hetzner.answer("GET", "/v1/server_types", 200, Self.hetznerTypes(
            Self.hetznerType("cx23", free: [], taken: ["fsn1", "nbg1", "hel1"]),
            Self.hetznerType("cax11", free: ["nbg1"], architecture: "arm", monthly: "4.7600")))
        let arm = try await Self.make(.hetzner, hetzner)
        #expect(arm.type == "cax11" && arm.location == "nbg1")
        // Free when it was read and taken when it was asked for: the next offer, behind the same firewall.
        let raced = Self.hetzner()
        raced.clear("POST", "/v1/servers")
        raced.answer("POST", "/v1/servers", 412, "{\"error\":{\"code\":\"resource_unavailable\",\"message\":\"server type unavailable\"}}")
        raced.answer("POST", "/v1/servers", 201, Self.hetznerServer)
        let second = try await Self.make(.hetzner, raced)
        #expect(raced.calls("POST", "/v1/servers").compactMap { $0.object?["location"] as? String } == ["fsn1", "nbg1"])
        #expect(second.location == "nbg1")
        #expect(raced.calls("POST", "/v1/firewalls").count == 1)
    }

    @Test func hetznersOwnTypesAreOfferedCheapestFirstWhenTheSmallOnesAreTaken() async throws {
        // As Hetzner said on 5 November 2026: no CX or CAX type free anywhere, and new CPX types.
        let hetzner = Self.hetzner()
        hetzner.clear("GET", "/v1/server_types")
        hetzner.answer("GET", "/v1/server_types", 200, Self.hetznerTypes(
            Self.hetznerType("cx23", free: [], taken: ["fsn1", "nbg1", "hel1"], monthly: "5.4900"),
            Self.hetznerType("cpx22", free: ["fsn1", "nbg1", "hel1"], monthly: "19.4900"),
            Self.hetznerType("cpx12", free: ["hel1", "nbg1"], memory: 2, monthly: "11.4900"),
            Self.hetznerType("cpx02", free: ["hel1", "nbg1"], memory: 1, disk: 20, monthly: "5.9900"),
            Self.hetznerType("small", free: ["fsn1"], memory: 0.5, monthly: "1.0000"),
            Self.hetznerType("old", free: ["fsn1"], monthly: "2.0000", deprecated: true),
            Self.hetznerType("other", free: ["fsn1"], architecture: "riscv", monthly: "3.0000"),
            Self.hetznerType("ccx13", free: ["nbg1"], memory: 8, monthly: "36.4900", cpuType: "dedicated")))
        let servers = Self.servers(.hetzner, hetzner)
        // A hub takes 2 GB: the cheapest type with that much, and at one price the nearest place (Nuremberg for Berlin).
        // Not the cheaper type of 1 GB, on which a release's checks beside the live hub do not fit. Its price has the
        // type, its IPv4 address and its IPv6 address.
        let hub = try await servers.offer(use: .hub)
        #expect(hub.type == "cpx12" && hub.location == "nbg1" && hub.monthlyPrice == Decimal(string: "12.5848")!)
        // A server for agents takes 2 GB too, and has no IPv6 address.
        let agent = try await servers.offer(use: .agent)
        #expect(agent.type == "cpx12" && agent.location == "nbg1" && agent.monthlyPrice == Decimal(string: "12.0850")!)
        // **The list under a server on "Your fleet"** (slice 2b): each type that fits once, at its cheapest and then
        // nearest place, the cheapest type first, its first the offer above; a dedicated type says so.
        let list = try await servers.offers(use: .hub)
        #expect(list.map(\.key) == ["cpx12@nbg1", "cpx22@fsn1", "ccx13@nbg1"] && list.first == hub)
        #expect(list.map(\.dedicated) == [false, false, true])
        // A place that was taken gives its type's next place, and every other type stays.
        let again = try await servers.offers(use: .hub, except: ["cpx12@nbg1"])
        #expect(again.map(\.key) == ["cpx12@hel1", "cpx22@fsn1", "ccx13@nbg1"])
    }

    @Test func aHetznerServerThatFailsIsTakenBackAndTheKeyStays() async throws {
        let hetzner = Self.hetzner()
        hetzner.clear("GET", "/v1/actions/501")
        hetzner.answer("GET", "/v1/actions/501", 200, "{\"action\":{\"id\":501,\"status\":\"error\","
                       + "\"error\":{\"code\":\"action_failed\",\"message\":\"the server could not be started\"}}}")
        // The firewall goes once the deleted server lets go of it.
        hetzner.clear("DELETE", "/v1/firewalls/77")
        hetzner.answer("DELETE", "/v1/firewalls/77", 422, "{\"error\":{\"code\":\"resource_in_use\",\"message\":\"firewall still applied\"}}")
        hetzner.answer("DELETE", "/v1/firewalls/77", 204, "")
        await #expect(throws: CloudError.refused(.hetzner, "the server could not be started")) { try await Self.make(.hetzner, hetzner) }
        #expect(hetzner.calls.filter { $0.method == "DELETE" }.map(\.path)
            == ["/v1/servers/1001", "/v1/firewalls/77", "/v1/firewalls/77"])
        #expect(hetzner.calls("GET", "/v1/actions/601").count == 1)
        // None free anywhere: the firewall it made goes, and nothing else was made.
        let full = Self.hetzner()
        full.clear("POST", "/v1/servers")
        full.answer("POST", "/v1/servers", 422, "{\"error\":{\"code\":\"placement_error\",\"message\":\"no capacity\"}}")
        await #expect(throws: CloudError.noRoom(.hetzner)) { try await Self.make(.hetzner, full) }
        #expect(full.calls("POST", "/v1/servers").count == 3)          // fsn1 and nbg1 for cx23, fsn1 for cax11
        #expect(full.calls.filter { $0.method == "DELETE" }.map(\.path) == ["/v1/firewalls/77"])
        // A refusal that is not about room ends the try at once, in Hetzner's words.
        let limit = Self.hetzner()
        limit.clear("POST", "/v1/servers")
        limit.answer("POST", "/v1/servers", 403, "{\"error\":{\"code\":\"resource_limit_exceeded\",\"message\":\"server limit reached\"}}")
        // The account's limit is its own stop (slice 3): "no room in your account", whose way on is another provider.
        await #expect(throws: CloudError.full(.hetzner)) { try await Self.make(.hetzner, limit) }
        #expect(limit.calls("POST", "/v1/servers").count == 1)
        #expect(limit.calls.filter { $0.method == "DELETE" }.map(\.path) == ["/v1/firewalls/77"])
    }

    @Test func whatCannotBeDeletedIsSaid() async throws {
        let hetzner = Self.hetzner()
        hetzner.clear("GET", "/v1/actions/501")
        hetzner.answer("GET", "/v1/actions/501", 200, "{\"action\":{\"id\":501,\"status\":\"error\",\"error\":{\"message\":\"boom\"}}}")
        hetzner.clear("DELETE", "/v1/servers/1001")
        hetzner.answer("DELETE", "/v1/servers/1001", 500, "{\"error\":{\"code\":\"server_error\",\"message\":\"later\"}}")
        hetzner.clear("DELETE", "/v1/firewalls/77")
        hetzner.answer("DELETE", "/v1/firewalls/77", 422, "{\"error\":{\"code\":\"resource_in_use\",\"message\":\"still applied\"}}")
        let failed = await #expect(throws: CloudError.self) { try await Self.make(.hetzner, hetzner) }
        guard case .leftBehind(.hetzner, let reason, let left) = failed else {
            Issue.record("expected what is left, got \(String(describing: failed))")
            return
        }
        #expect(reason == "Hetzner refused: boom")
        #expect(left.count == 2 && left[0] == "the server hub-1" && left[1].hasPrefix("the firewall founderizer-hub-1-"))
        // The firewall stays while its server stays: a server left behind is never left open.
        #expect(hetzner.calls("DELETE", "/v1/firewalls/77").isEmpty)
        #expect(failed?.errorDescription?.contains("delete it at Hetzner") == true)
    }

    // MARK: - A server at DigitalOcean

    private static let droplet = "/v2/droplets/3164444"
    private static let oceanFirewall = "bb4b2611-3d72-467b-8602-280330ecd65c"

    private static func digitalOcean() -> ProviderStandIn {
        let ocean = ProviderStandIn()
        ocean.answer("GET", "/v2/account/keys/\(fingerprint)", 404, "{\"id\":\"not_found\",\"message\":\"The resource you were accessing could not be found.\"}")
        ocean.answer("POST", "/v2/account/keys", 201, "{\"ssh_key\":{\"id\":512190,\"fingerprint\":\"\(fingerprint)\",\"name\":\"x\"}}")
        ocean.answer("GET", "/v2/sizes", 200, "{\"sizes\":["
                     + "{\"slug\":\"s-1vcpu-1gb\",\"memory\":1024,\"vcpus\":1,\"disk\":25,\"price_monthly\":6,\"price_hourly\":0.00893,"
                     + "\"regions\":[\"ams3\",\"fra1\",\"lon1\",\"nyc3\",\"sfo3\",\"sgp1\"],\"available\":true},"
                     + "{\"slug\":\"s-1vcpu-2gb\",\"memory\":2048,\"vcpus\":1,\"disk\":50,\"price_monthly\":12,\"price_hourly\":0.01786,"
                     + "\"regions\":[\"ams3\",\"lon1\"],\"available\":true},"
                     + "{\"slug\":\"s-2vcpu-4gb\",\"memory\":4096,\"vcpus\":2,\"disk\":80,\"price_monthly\":24,\"price_hourly\":0.03571,"
                     + "\"regions\":[\"fra1\"],\"available\":true}],\"links\":{},\"meta\":{\"total\":3}}")
        ocean.answer("POST", "/v2/droplets", 202, "{\"droplet\":{\"id\":3164444,\"name\":\"hub-1\",\"status\":\"new\","
                     + "\"networks\":{\"v4\":[],\"v6\":[]}},\"links\":{\"actions\":[{\"id\":7,\"rel\":\"create\"}]}}")
        ocean.answer("POST", "/v2/firewalls", 202, "{\"firewall\":{\"id\":\"\(oceanFirewall)\",\"status\":\"waiting\"}}")
        ocean.answer("GET", droplet, 200, "{\"droplet\":{\"id\":3164444,\"status\":\"new\",\"networks\":{\"v4\":[],\"v6\":[]}}}")
        ocean.answer("GET", droplet, 200, "{\"droplet\":{\"id\":3164444,\"status\":\"active\",\"networks\":{\"v4\":["
                     + "{\"ip_address\":\"10.114.0.2\",\"netmask\":\"255.255.240.0\",\"gateway\":null,\"type\":\"private\"},"
                     + "{\"ip_address\":\"198.51.100.7\",\"netmask\":\"255.255.240.0\",\"gateway\":\"198.51.100.1\",\"type\":\"public\"}],"
                     + "\"v6\":[]}}}")
        ocean.answer("DELETE", droplet, 204, "")
        ocean.answer("DELETE", "/v2/firewalls/\(oceanFirewall)", 204, "")
        return ocean
    }

    @Test func aDigitalOceanServerIsMadeNearTheMacBehindAFirewallThatLetsNothingIn() async throws {
        let ocean = Self.digitalOcean()
        let server = try await Self.make(.digitalOcean, ocean)
        // A hub takes 2 GB: not the size of 1 GB in Frankfurt, the one of 2 GB in the nearest region that has it.
        #expect(server == CloudServer(provider: .digitalOcean, id: "3164444", name: "hub-1", ipv4: "198.51.100.7",
                                      type: "s-1vcpu-2gb", location: "ams3", monthlyPrice: 12, currency: "USD",
                                      firewallID: Self.oceanFirewall))
        // Not found by its fingerprint, so registered once.
        let registered = try #require(ocean.call("POST", "/v2/account/keys")?.object)
        #expect(registered["public_key"] as? String == Self.publicKey)
        #expect(registered["name"] as? String == "founderizer-7210e7120f70")
        #expect(ocean.call("GET", "/v2/sizes")?.query == "per_page=200")
        let made = try #require(ocean.call("POST", "/v2/droplets")?.object)
        #expect(made["name"] as? String == "hub-1")
        #expect(made["region"] as? String == "ams3")
        #expect(made["size"] as? String == "s-1vcpu-2gb")
        #expect(made["image"] as? String == "ubuntu-24-04-x64")
        #expect(made["ssh_keys"] as? [Int] == [512190])
        #expect(made["user_data"] as? String == CloudServers.userData(authKey: Self.authKey, hostname: "hub-1"))
        // No inbound rule, which at DigitalOcean lets nothing in; every protocol out to every address.
        let firewall = try #require(ocean.call("POST", "/v2/firewalls")?.object)
        #expect(firewall["inbound_rules"] == nil)
        #expect(firewall["droplet_ids"] as? [Int] == [3164444])
        let out = try #require(firewall["outbound_rules"] as? [[String: Any]])
        #expect(out.compactMap { $0["protocol"] as? String } == ["tcp", "udp", "icmp"])
        #expect(out.allSatisfy { ($0["destinations"] as? [String: [String]])?["addresses"] == ["0.0.0.0/0", "::/0"] })
        #expect(out.prefix(2).allSatisfy { $0["ports"] as? String == "0" })
        // Read until it runs, which is when it has its public address.
        #expect(ocean.calls("GET", Self.droplet).count == 2)
        #expect(!ocean.calls.contains { $0.method == "DELETE" })
        #expect(ocean.calls.allSatisfy { $0.headers["Authorization"] == "Bearer \(Self.token)" && $0.url.host == "api.digitalocean.com" })
    }

    @Test func anAgentsServerAtDigitalOceanIsTheNextSizeUpWhereItIsFree() async throws {
        let ocean = Self.digitalOcean()
        let server = try await Self.make(.digitalOcean, ocean, use: .agent)
        // Not in Frankfurt now, so the nearest region that has it.
        #expect(server.type == "s-1vcpu-2gb" && server.location == "ams3" && server.monthlyPrice == 12)
        // A region that cannot take it now answers 422: the next region; and the key, once found, is not registered.
        let busy = Self.digitalOcean()
        busy.clear("GET", "/v2/account/keys/\(Self.fingerprint)")
        busy.answer("GET", "/v2/account/keys/\(Self.fingerprint)", 200, "{\"ssh_key\":{\"id\":512189}}")
        busy.clear("POST", "/v2/droplets")
        busy.answer("POST", "/v2/droplets", 422, "{\"id\":\"unprocessable_entity\",\"message\":\"Size is not available in this region.\"}")
        busy.answer("POST", "/v2/droplets", 202, "{\"droplet\":{\"id\":3164444,\"status\":\"new\"}}")
        let second = try await Self.make(.digitalOcean, busy)
        #expect(second.location == "lon1")
        #expect(busy.calls("POST", "/v2/account/keys").isEmpty)
        #expect(busy.calls("POST", "/v2/droplets").compactMap { $0.object?["ssh_keys"] as? [Int] } == [[512189], [512189]])
        // When no region can, DigitalOcean's own words say why: the two regions of the smallest size, then the one of
        // the next size up.
        let none = Self.digitalOcean()
        none.clear("POST", "/v2/droplets")
        none.answer("POST", "/v2/droplets", 422, "{\"id\":\"unprocessable_entity\",\"message\":\"Size is not available in this region.\"}")
        await #expect(throws: CloudError.refused(.digitalOcean, "Size is not available in this region.")) {
            try await Self.make(.digitalOcean, none)
        }
        #expect(none.calls("POST", "/v2/droplets").count == 3)
        #expect(!none.calls.contains { $0.method == "DELETE" })
    }

    /// The owner, 15 November 2026: "it should still show some servers even if more expensive". DigitalOcean offered
    /// its one smallest size only, and nothing when that size was not free near the Mac.
    @Test func digitalOceanOffersTheNextSizeUpWhenTheSmallestIsNotFree() async throws {
        let ocean = ProviderStandIn()
        ocean.answer("GET", "/v2/sizes", 200, "{\"sizes\":["
                     + "{\"slug\":\"s-1vcpu-512mb-10gb\",\"memory\":512,\"vcpus\":1,\"disk\":10,\"price_monthly\":4,"
                     + "\"regions\":[\"fra1\"],\"available\":true},"
                     + "{\"slug\":\"s-1vcpu-2gb-intel\",\"memory\":2048,\"vcpus\":1,\"disk\":50,\"price_monthly\":10,"
                     + "\"regions\":[\"fra1\"],\"available\":false},"
                     + "{\"slug\":\"gpu-h100x1-80gb\",\"memory\":245760,\"vcpus\":20,\"disk\":720,\"price_monthly\":2000,"
                     + "\"regions\":[\"fra1\"],\"available\":true},"
                     + "{\"slug\":\"s-2vcpu-2gb\",\"memory\":2048,\"vcpus\":2,\"disk\":60,\"price_monthly\":18,"
                     + "\"regions\":[\"fra1\",\"ams3\"],\"available\":true},"
                     + "{\"slug\":\"s-1vcpu-2gb\",\"memory\":2048,\"vcpus\":1,\"disk\":50,\"price_monthly\":12,"
                     + "\"regions\":[\"nyc3\",\"ams3\"],\"available\":true}]}")
        let servers = Self.servers(.digitalOcean, ocean)
        // Too small, not free and a GPU are left out: the cheapest that fits, nearest first (Amsterdam for Berlin).
        let hub = try await servers.offer(use: .hub)
        #expect(hub.type == "s-1vcpu-2gb" && hub.location == "ams3" && hub.monthlyPrice == 12)
        // That one taken in Amsterdam: the same size in New York, then the next size up.
        let next = try await servers.offer(use: .hub, except: [hub.key])
        #expect(next.type == "s-1vcpu-2gb" && next.location == "nyc3")
        let up = try await servers.offer(use: .hub, except: [hub.key, next.key])
        #expect(up.type == "s-2vcpu-2gb" && up.location == "fra1" && up.monthlyPrice == 18)
        // **The list under a server on "Your fleet"** (slice 2b): another provider's rows name no type, so one size is
        // one row, its cheapest kind; an AMD droplet of the same size is no second row that reads the same.
        let kinds = ProviderStandIn()
        kinds.answer("GET", "/v2/sizes", 200, "{\"sizes\":["
                     + "{\"slug\":\"s-1vcpu-2gb-amd\",\"memory\":2048,\"vcpus\":1,\"disk\":50,\"price_monthly\":14,"
                     + "\"regions\":[\"ams3\"],\"available\":true},"
                     + "{\"slug\":\"s-1vcpu-2gb\",\"memory\":2048,\"vcpus\":1,\"disk\":50,\"price_monthly\":12,"
                     + "\"regions\":[\"ams3\"],\"available\":true},"
                     + "{\"slug\":\"s-2vcpu-4gb\",\"memory\":4096,\"vcpus\":2,\"disk\":80,\"price_monthly\":24,"
                     + "\"regions\":[\"ams3\"],\"available\":true}]}")
        #expect(try await Self.servers(.digitalOcean, kinds).offers(use: .hub).map(\.type) == ["s-1vcpu-2gb", "s-2vcpu-4gb"])
        await #expect(throws: CloudError.noRoom(.digitalOcean)) {
            try await servers.offer(use: .hub, except: [hub.key, next.key, up.key, "s-2vcpu-2gb@ams3"])
        }
        #expect(ocean.calls.allSatisfy { $0.method == "GET" }, "reading what would be made makes nothing")
    }

    /// The size that the owner said yes to, which its region cannot take now: nothing is made, and the page reads the
    /// next free one (`CloudError.taken`). Another refusal keeps DigitalOcean's own words.
    @Test func aDropletSizeTakenMeanwhileIsSaidSoAndMakesNothing() async throws {
        let chosen = CloudOffer(provider: .digitalOcean, type: "s-1vcpu-2gb", location: "ams3", cores: 1, memoryGB: 2,
                                diskGB: 50, monthlyPrice: 12, currency: "USD")
        let busy = Self.digitalOcean()
        busy.clear("POST", "/v2/droplets")
        busy.answer("POST", "/v2/droplets", 422, "{\"id\":\"unprocessable_entity\",\"message\":\"Size is not available in this region.\"}")
        await #expect(throws: CloudError.taken(.digitalOcean)) {
            try await Self.servers(.digitalOcean, busy).createServer(name: "hub-1", use: .hub, publicKey: Self.publicKey,
                                                                      authKey: Self.authKey, offer: chosen)
        }
        #expect(busy.calls("POST", "/v2/droplets").count == 1 && busy.calls("POST", "/v2/firewalls").isEmpty)
        let limit = Self.digitalOcean()
        limit.clear("POST", "/v2/droplets")
        limit.answer("POST", "/v2/droplets", 422, "{\"id\":\"unprocessable_entity\",\"message\":\"creating this droplet will exceed your droplet limit\"}")
        // The account's limit is its own stop (slice 3), whose way on is another provider.
        await #expect(throws: CloudError.full(.digitalOcean)) {
            try await Self.servers(.digitalOcean, limit).createServer(name: "hub-1", use: .hub, publicKey: Self.publicKey,
                                                                       authKey: Self.authKey, offer: chosen)
        }
        // With none chosen, such a refusal ends the try at once: no other size or region is asked.
        let limited = Self.digitalOcean()
        limited.clear("POST", "/v2/droplets")
        limited.answer("POST", "/v2/droplets", 422, "{\"id\":\"unprocessable_entity\",\"message\":\"creating this droplet will exceed your droplet limit\"}")
        await #expect(throws: CloudError.full(.digitalOcean)) {
            try await Self.make(.digitalOcean, limited)
        }
        #expect(limited.calls("POST", "/v2/droplets").count == 1)
        // An image that a region lacks is no size taken.
        let image = CloudCall.Answer(status: 422, object: ["id": "unprocessable_entity", "message": "Image is not available in this region."],
                                     text: "")
        #expect(!CloudServers.saysUnavailable(image))
    }

    /// **What a stop of the server's page leads to** (the owner, 15 November 2026: the page "asks for the token
    /// again!! when it is already there!"): only the token's own refusal asks for a token, and only a stop that leaves
    /// nothing at the provider shows the list again with its press.
    @Test func aStopAsksForTheTokenOnlyWhenTheTokenIsRefused() {
        let tokens: [CloudError] = [.notAToken(.hetzner), .noToken(.vultr), .tokenNotAccepted(.akamai), .readOnlyToken(.digitalOcean)]
        for error in tokens { #expect(CloudStop.refusesToken(error)) }
        let others: [any Error] = [CloudError.noRoom(.hetzner), CloudError.taken(.hetzner), CloudError.unreachable(.hetzner),
                                   CloudError.rateLimited(.vultr), CloudError.refused(.hetzner, "x"),
                                   FleetKeyError.fleetKeyEnded, URLError(.timedOut)]
        for error in others { #expect(!CloudStop.refusesToken(error)) }
        // After the call for the server: taken, none free, deleted after it did not come up, or asked to wait.
        let again: [CloudError] = [.taken(.hetzner), .noRoom(.digitalOcean), .notReady(.akamai), .rateLimited(.vultr)]
        for error in again { #expect(CloudStop.readsListAgain(after: error, called: true)) }
        // A refusal can be the provider's own fault answer, after which the server can be there: the line alone. So
        // are a call whose end is not known, what could not be deleted, and the token's refusal.
        let alone: [any Error] = [CloudError.refused(.digitalOcean, "502 Bad Gateway"), CloudError.unreachable(.hetzner),
                                  CloudError.unsure(.digitalOcean, says: "502 Bad Gateway", server: "hub-1", mark: "x"),
                                  CloudError.notUnderstood(.vultr), CloudError.leftBehind(.hetzner, reason: "x", left: ["y"]),
                                  CloudError.tokenNotAccepted(.hetzner), URLError(.timedOut)]
        for error in alone { #expect(!CloudStop.readsListAgain(after: error, called: true)) }
        // Before the call: anything but the network's own key, which no press on the page can mend.
        #expect(CloudStop.readsListAgain(after: URLError(.timedOut), called: false))
        #expect(CloudStop.readsListAgain(after: FleetKeyError.unreachable, called: false))
        #expect(!CloudStop.readsListAgain(after: FleetKeyError.fleetKeyEnded, called: false))
        #expect(!CloudStop.readsListAgain(after: FleetKeyError.noFleetKey, called: false))
    }

    @Test func aDropletThatFailsIsTakenBackAndTheKeyStays() async throws {
        // Its firewall is refused: the droplet goes.
        let ocean = Self.digitalOcean()
        ocean.clear("POST", "/v2/firewalls")
        ocean.answer("POST", "/v2/firewalls", 422, "{\"id\":\"unprocessable_entity\",\"message\":\"name is invalid\"}")
        await #expect(throws: CloudError.refused(.digitalOcean, "name is invalid")) { try await Self.make(.digitalOcean, ocean) }
        #expect(ocean.calls.filter { $0.method == "DELETE" }.map(\.path) == [Self.droplet])
        // It never runs: the droplet and its firewall go, after a bounded number of reads.
        let stuck = Self.digitalOcean()
        stuck.clear("GET", Self.droplet)
        stuck.answer("GET", Self.droplet, 200, "{\"droplet\":{\"id\":3164444,\"status\":\"new\",\"networks\":{\"v4\":[]}}}")
        await #expect(throws: CloudError.notReady(.digitalOcean)) { try await Self.make(.digitalOcean, stuck) }
        #expect(stuck.calls("GET", Self.droplet).count == CloudServers.waitReads)
        #expect(stuck.calls.filter { $0.method == "DELETE" }.map(\.path) == [Self.droplet, "/v2/firewalls/\(Self.oceanFirewall)"])
    }

    /// **A fault answer of the provider's own (a 5xx), or no answer at all, to the call that makes the server**
    /// (finding 3 of the checked audit of 24 November 2026): until then a 5xx was a refusal, the build's record said
    /// nothing was left and freed the name, and a retry could install onto the server that the provider had made all
    /// the same; a time-out took the firewall back. Now the servers that carry the call's own mark are read before
    /// anything is taken back (its firewall at Hetzner, Vultr and Akamai, its tag at DigitalOcean): the one there is
    /// deleted with the rest. Any other end takes nothing back, says that the end is not known, and reads on for that
    /// server in a task of its own, which deletes it when it comes (the reads of the Vault and Door areas).
    /// An end that is not known, of the server hub-1, with these words of the provider's, and with the call's own mark:
    /// its firewall's name (the server's, then six letters of chance), which its words name.
    private static func unsure(_ error: CloudError?, _ provider: CloudProvider, _ says: String?) -> Bool {
        guard case .unsure(provider, says, "hub-1", let mark)? = error,
              CloudServers.isFirewallName(mark, ofServer: "hub-1", at: provider) else { return false }
        return error?.errorDescription?.contains(" \(CloudError.marked(mark, at: provider)) at \(provider.name) ") == true
    }

    @Test func aCreateWithNoSureAnswerReadsItsOwnMarkBeforeAnythingIsTakenBack() async throws {
        func deleted(_ stand: ProviderStandIn) -> [String] { stand.calls.filter { $0.method == "DELETE" }.map(\.path) }
        // DigitalOcean made the droplet and answered 502: the droplet with the call's tag goes.
        let ocean = Self.digitalOcean()
        ocean.clear("POST", "/v2/droplets")
        ocean.answer("POST", "/v2/droplets", 502, "{\"id\":\"bad_gateway\",\"message\":\"502 Bad Gateway\"}")
        ocean.answer("GET", "/v2/droplets", 200, "{\"droplets\":[{\"id\":3164444,\"name\":\"hub-1\"},"
                     + "{\"id\":3164445,\"name\":\"shop\"}]}")
        let made = await #expect(throws: CloudError.self) { try await Self.make(.digitalOcean, ocean) }
        #expect(made == .takenBack(.digitalOcean, says: "502 Bad Gateway", server: "hub-1"))
        #expect(made.map(BuildRecord.AtProvider.after) == .nothing)
        #expect(deleted(ocean) == [Self.droplet])
        let tags = try #require(ocean.call("POST", "/v2/droplets")?.object?["tags"] as? [String])
        #expect(tags.count == 2 && tags[0] == "founderizer-hub")
        #expect(ocean.call("GET", "/v2/droplets")?.query.contains("tag_name=\(tags[1])") == true)
        // The account's list shows such a droplet as this app's, so it is no server to choose (the Door area's read of
        // 318167959, SHOULD 4).
        let listed = ProviderStandIn()
        listed.answer("GET", "/v2/droplets", 200, "{\"droplets\":[{\"id\":3164444,\"name\":\"hub-1\",\"tags\":[\"founderizer-hub\","
                      + "\"\(tags[1])\"]}]}")
        #expect(try await Self.servers(.digitalOcean, listed).servers().map(\.madeFor) == ["hub"])
        // A 500 with no droplet of the tag yet: nothing now, the end is not known, and the droplet that comes at the
        // third read after it goes.
        let late = Self.digitalOcean(), follows = Follows()
        late.clear("POST", "/v2/droplets")
        late.answer("POST", "/v2/droplets", 500, "{\"id\":\"server_error\",\"message\":\"try again\"}")
        for _ in 0..<3 { late.answer("GET", "/v2/droplets", 200, "{\"droplets\":[]}") }
        late.answer("GET", "/v2/droplets", 200, "{\"droplets\":[{\"id\":3164444,\"name\":\"hub-1\"}]}")
        let notYet = await #expect(throws: CloudError.self) { try await Self.make(.digitalOcean, late, follows: follows) }
        #expect(Self.unsure(notYet, .digitalOcean, "try again"))
        #expect(notYet?.errorDescription?.contains("with the tag founderizer-hub-1-") == true)
        #expect(notYet.map(BuildRecord.AtProvider.after) == .notKnown)
        await follows.done()
        #expect(late.calls("GET", "/v2/droplets").count == 4 && deleted(late) == [Self.droplet])
        // Hetzner: the server behind the call's firewall goes first, then the firewall.
        let hetzner = Self.hetzner()
        hetzner.clear("POST", "/v1/servers")
        hetzner.answer("POST", "/v1/servers", 503, "{\"error\":{\"code\":\"unavailable\",\"message\":\"service unavailable\"}}")
        hetzner.answer("GET", "/v1/firewalls/77", 200, "{\"firewall\":{\"id\":77,\"applied_to\":[{\"type\":\"server\","
                       + "\"server\":{\"id\":1001}},{\"type\":\"server\",\"server\":{\"id\":1002}}]}}")
        hetzner.answer("GET", "/v1/servers", 200, "{\"servers\":[{\"id\":1001,\"name\":\"hub-1\"},{\"id\":1002,\"name\":\"hub-10\"}]}")
        await #expect(throws: CloudError.takenBack(.hetzner, says: "service unavailable", server: "hub-1")) {
            try await Self.make(.hetzner, hetzner)
        }
        #expect(deleted(hetzner) == ["/v1/servers/1001", "/v1/firewalls/77"])
        // Only a server of the call's own name is the call's: 1002, a person's other server put behind the new firewall
        // in that hour, is not (the PC readers' point 3 of 26 November 2026).
        #expect(hetzner.call("GET", "/v1/servers")?.query == "name=hub-1")
        // A deletion whose action ends in an error leaves that server, and the call says so.
        let stays = Self.hetzner(), again = Follows()
        stays.clear("POST", "/v1/servers")
        stays.answer("POST", "/v1/servers", 503, "{\"error\":{\"code\":\"unavailable\",\"message\":\"service unavailable\"}}")
        stays.answer("GET", "/v1/firewalls/77", 200, "{\"firewall\":{\"id\":77,\"applied_to\":[{\"type\":\"server\","
                     + "\"server\":{\"id\":1001}}]}}")
        stays.answer("GET", "/v1/servers", 200, "{\"servers\":[{\"id\":1001,\"name\":\"hub-1\"}]}")
        stays.clear("GET", "/v1/actions/601")
        stays.answer("GET", "/v1/actions/601", 200, "{\"action\":{\"id\":601,\"status\":\"error\","
                     + "\"error\":{\"code\":\"action_failed\",\"message\":\"not deleted\"}}}")
        let left = await #expect(throws: CloudError.self) { try await Self.make(.hetzner, stays, follows: again) }
        guard case .leftBehind(.hetzner, let reason, let what)? = left else {
            Issue.record("not left behind: \(String(describing: left))"); return
        }
        // Said in the provider's words, not as deleted; and the server keeps its firewall, which is named too.
        #expect(reason == CloudError.refused(.hetzner, "service unavailable").errorDescription)
        #expect(what.count == 2 && what.first == "the server hub-1" && what.last?.hasPrefix("the firewall founderizer-hub-1-") == true)
        // And the reads go on for it in the hour after, each one asking its deletion again.
        await again.done()
        #expect(stays.calls("DELETE", "/v1/servers/1001").count == 1 + CloudServers.followReads)
        // A refusal that is no fault of the provider's is read as before: no read, the firewall goes.
        let refused = Self.hetzner()
        refused.clear("POST", "/v1/servers")
        refused.answer("POST", "/v1/servers", 422, "{\"error\":{\"code\":\"invalid_input\",\"message\":\"invalid\"}}")
        await #expect(throws: CloudError.refused(.hetzner, "invalid")) { try await Self.make(.hetzner, refused) }
        #expect(refused.calls("GET", "/v1/firewalls/77").isEmpty && deleted(refused) == ["/v1/firewalls/77"])
        // The call for the server got no answer (a time-out, a Back press): no server behind the firewall in ten
        // minutes of reads, and the firewall stays for one that can still come.
        let lost = Self.hetzner(), waited = Follows()
        lost.clear("POST", "/v1/servers")
        lost.answer("POST", "/v1/servers", ProviderStandIn.dropped)
        lost.answer("GET", "/v1/firewalls/77", 200, "{\"firewall\":{\"id\":77,\"applied_to\":[]}}")
        let none = await #expect(throws: CloudError.self) { try await Self.make(.hetzner, lost, follows: waited) }
        #expect(Self.unsure(none, .hetzner, nil))
        #expect(none?.errorDescription?.contains("behind the firewall founderizer-hub-1-") == true)
        await waited.done()
        #expect(lost.calls("GET", "/v1/firewalls/77").count == 1 + CloudServers.followReads && deleted(lost).isEmpty)
        // Vultr: only the instance of that name behind the call's own group goes, with the group.
        let vultr = Self.vultr()
        vultr.clear("POST", "/v2/instances")
        vultr.answer("POST", "/v2/instances", 504, "{\"error\":\"Gateway Timeout\"}")
        vultr.answer("GET", "/v2/instances", 200, "{\"instances\":[{\"id\":\"\(Self.vultrInstance)\",\"label\":\"hub-1\","
                     + "\"firewall_group_id\":\"\(Self.vultrFirewall)\"},{\"id\":\"another\",\"label\":\"hub-1\","
                     + "\"firewall_group_id\":\"another-group\"},{\"id\":\"shop\",\"label\":\"shop\","
                     + "\"firewall_group_id\":\"\(Self.vultrFirewall)\"}]}")
        vultr.answer("DELETE", "/v2/firewalls/\(Self.vultrFirewall)", 204, "")
        await #expect(throws: CloudError.takenBack(.vultr, says: "Gateway Timeout", server: "hub-1")) {
            try await Self.make(.vultr, vultr)
        }
        #expect(deleted(vultr) == ["/v2/instances/\(Self.vultrInstance)", "/v2/firewalls/\(Self.vultrFirewall)"])
        // Akamai: the Linode among its firewall's devices goes, with the firewall.
        let akamai = Self.akamai()
        akamai.clear("POST", "/v4/linode/instances")
        akamai.answer("POST", "/v4/linode/instances", 500, "{\"errors\":[{\"reason\":\"Please try again\"}]}")
        akamai.answer("GET", "/v4/networking/firewalls/\(Self.akamaiFirewall)/devices", 200,
                      "{\"data\":[{\"entity\":{\"id\":\(Self.linode),\"type\":\"linode\",\"label\":\"hub-1\"}},"
                      + "{\"entity\":{\"id\":4242,\"type\":\"linode\",\"label\":\"shop\"}}]}")
        await #expect(throws: CloudError.takenBack(.akamai, says: "Please try again", server: "hub-1")) {
            try await Self.make(.akamai, akamai)
        }
        #expect(deleted(akamai) == ["/v4/linode/instances/\(Self.linode)", "/v4/networking/firewalls/\(Self.akamaiFirewall)"])
        // Akamai's devices cannot be read: nothing is taken back, its firewall least of all, and none of the reads
        // after it deletes anything that it could not read.
        let unread = Self.akamai(), reads = Follows()
        unread.clear("POST", "/v4/linode/instances")
        unread.answer("POST", "/v4/linode/instances", 500, "{\"errors\":[{\"reason\":\"Please try again\"}]}")
        unread.answer("GET", "/v4/networking/firewalls/\(Self.akamaiFirewall)/devices", 500, "{\"errors\":[{\"reason\":\"x\"}]}")
        let unsure = await #expect(throws: CloudError.self) { try await Self.make(.akamai, unread, follows: reads) }
        #expect(Self.unsure(unsure, .akamai, "Please try again"))
        #expect(unsure.map(BuildRecord.AtProvider.after) == .notKnown)
        await reads.done()
        #expect(deleted(unread).isEmpty)
        // Two servers with the call's mark and name: not this call's alone, so nothing goes, now or later. DigitalOcean's
        // names can be the same for two droplets; Hetzner's are one to a server.
        let two = Self.digitalOcean(), later = Follows()
        two.clear("POST", "/v2/droplets")
        two.answer("POST", "/v2/droplets", 502, "{\"id\":\"bad_gateway\",\"message\":\"bad gateway\"}")
        two.answer("GET", "/v2/droplets", 200, "{\"droplets\":[{\"id\":3164444,\"name\":\"hub-1\"},{\"id\":3164445,\"name\":\"hub-1\"}]}")
        let twice = await #expect(throws: CloudError.self) { try await Self.make(.digitalOcean, two, follows: later) }
        #expect(Self.unsure(twice, .digitalOcean, "bad gateway"))
        await later.done()
        #expect(deleted(two).isEmpty && two.calls("GET", "/v2/droplets").count == 1 + CloudServers.followReads)
        // A gateway's own page is no words: its status is (the validation of c64b10b03, S5).
        let page = Self.hetzner()
        page.clear("POST", "/v1/servers")
        page.answer("POST", "/v1/servers", 502, "<html><body><h1>502 Bad Gateway</h1></body></html>")
        page.answer("GET", "/v1/firewalls/77", 200, "{\"firewall\":{\"id\":77,\"applied_to\":[]}}")
        let paged = await #expect(throws: CloudError.self) { try await Self.make(.hetzner, page) }
        #expect(Self.unsure(paged, .hetzner, "it answered 502 and said nothing"))
        // A Linode that does not go keeps its firewall, which Akamai would delete in front of it (its S1).
        let held = Self.akamai(), heldOn = Follows()
        held.clear("POST", "/v4/linode/instances")
        held.answer("POST", "/v4/linode/instances", 500, "{\"errors\":[{\"reason\":\"Please try again\"}]}")
        held.answer("GET", "/v4/networking/firewalls/\(Self.akamaiFirewall)/devices", 200,
                    "{\"data\":[{\"entity\":{\"id\":\(Self.linode),\"type\":\"linode\",\"label\":\"hub-1\"}}]}")
        held.clear("DELETE", "/v4/linode/instances/\(Self.linode)")
        held.answer("DELETE", "/v4/linode/instances/\(Self.linode)", 500, "{\"errors\":[{\"reason\":\"busy\"}]}")
        let kept = await #expect(throws: CloudError.self) { try await Self.make(.akamai, held, follows: heldOn) }
        guard case .leftBehind(.akamai, _, let both)? = kept else { Issue.record("not left behind: \(String(describing: kept))"); return }
        await heldOn.done()
        #expect(both.count == 2
                && deleted(held) == Array(repeating: "/v4/linode/instances/\(Self.linode)", count: 1 + CloudServers.followReads))
        // A server that comes later and does not go at once: the reads go on until it goes (its read of 318167959, MUST 1).
        let stubborn = Self.akamai(), on = Follows()
        stubborn.clear("POST", "/v4/linode/instances")
        stubborn.answer("POST", "/v4/linode/instances", 500, "{\"errors\":[{\"reason\":\"Please try again\"}]}")
        stubborn.answer("GET", "/v4/networking/firewalls/\(Self.akamaiFirewall)/devices", 200, "{\"data\":[]}")
        stubborn.answer("GET", "/v4/networking/firewalls/\(Self.akamaiFirewall)/devices", 200,
                        "{\"data\":[{\"entity\":{\"id\":\(Self.linode),\"type\":\"linode\",\"label\":\"hub-1\"}}]}")
        stubborn.clear("DELETE", "/v4/linode/instances/\(Self.linode)")
        stubborn.answer("DELETE", "/v4/linode/instances/\(Self.linode)", 500, "{\"errors\":[{\"reason\":\"busy\"}]}")
        stubborn.answer("DELETE", "/v4/linode/instances/\(Self.linode)", 200, "{}")
        let late2 = await #expect(throws: CloudError.self) { try await Self.make(.akamai, stubborn, follows: on) }
        #expect(Self.unsure(late2, .akamai, "Please try again"))
        await on.done()
        #expect(deleted(stubborn) == ["/v4/linode/instances/\(Self.linode)", "/v4/linode/instances/\(Self.linode)",
                                      "/v4/networking/firewalls/\(Self.akamaiFirewall)"])
        // Hetzner refuses to delete a server that it is still making: the deletion is asked again (its S6).
        let locked = Self.hetzner()
        locked.clear("POST", "/v1/servers")
        locked.answer("POST", "/v1/servers", 503, "{\"error\":{\"code\":\"unavailable\",\"message\":\"service unavailable\"}}")
        locked.answer("GET", "/v1/firewalls/77", 200, "{\"firewall\":{\"id\":77,\"applied_to\":[{\"type\":\"server\","
                      + "\"server\":{\"id\":1001}}]}}")
        locked.answer("GET", "/v1/servers", 200, "{\"servers\":[{\"id\":1001,\"name\":\"hub-1\"}]}")
        locked.clear("DELETE", "/v1/servers/1001")
        locked.answer("DELETE", "/v1/servers/1001", 423, "{\"error\":{\"code\":\"locked\",\"message\":\"server is locked\"}}")
        locked.answer("DELETE", "/v1/servers/1001", 200, "{\"action\":{\"id\":601,\"command\":\"delete_server\",\"status\":\"running\"}}")
        await #expect(throws: CloudError.takenBack(.hetzner, says: "service unavailable", server: "hub-1")) {
            try await Self.make(.hetzner, locked)
        }
        #expect(deleted(locked) == ["/v1/servers/1001", "/v1/servers/1001", "/v1/firewalls/77"])
    }

    /// **A server of another name behind the call's mark is never deleted** (the Door area's SHOULD 1 of 26 November
    /// 2026): a person's own server put behind the call's new firewall in that hour, at Hetzner, Akamai and Vultr, is no
    /// server of the call's, now or in the reads after it, and neither is one that a failed read of the names leaves. A
    /// bug here (a read saved when one server stands behind the firewall): the app deletes that person's server.
    @Test func aServerOfAnotherNameBehindTheCallsMarkIsNeverDeleted() async throws {
        func deleted(_ stand: ProviderStandIn) -> [String] { stand.calls.filter { $0.method == "DELETE" }.map(\.path) }
        let hetzner = Self.hetzner(), reads = Follows()
        hetzner.clear("POST", "/v1/servers")
        hetzner.answer("POST", "/v1/servers", 503, "{\"error\":{\"code\":\"unavailable\",\"message\":\"service unavailable\"}}")
        hetzner.answer("GET", "/v1/firewalls/77", 200, "{\"firewall\":{\"id\":77,\"applied_to\":[{\"type\":\"server\","
                       + "\"server\":{\"id\":1002}}]}}")
        hetzner.answer("GET", "/v1/servers", 200, "{\"servers\":[]}")
        let foreign = await #expect(throws: CloudError.self) { try await Self.make(.hetzner, hetzner, follows: reads) }
        #expect(Self.unsure(foreign, .hetzner, "service unavailable"))
        await reads.done()
        #expect(deleted(hetzner).isEmpty)
        // The names cannot be read: no server is the call's.
        let blind = Self.hetzner(), blindReads = Follows()
        blind.clear("POST", "/v1/servers")
        blind.answer("POST", "/v1/servers", 503, "{\"error\":{\"code\":\"unavailable\",\"message\":\"service unavailable\"}}")
        blind.answer("GET", "/v1/firewalls/77", 200, "{\"firewall\":{\"id\":77,\"applied_to\":[{\"type\":\"server\","
                     + "\"server\":{\"id\":1002}}]}}")
        blind.answer("GET", "/v1/servers", 503, "{\"error\":{\"code\":\"unavailable\",\"message\":\"service unavailable\"}}")
        let unread = await #expect(throws: CloudError.self) { try await Self.make(.hetzner, blind, follows: blindReads) }
        #expect(Self.unsure(unread, .hetzner, "service unavailable"))
        await blindReads.done()
        #expect(deleted(blind).isEmpty)
        let akamai = Self.akamai(), akamaiReads = Follows()
        akamai.clear("POST", "/v4/linode/instances")
        akamai.answer("POST", "/v4/linode/instances", 500, "{\"errors\":[{\"reason\":\"Please try again\"}]}")
        akamai.answer("GET", "/v4/networking/firewalls/\(Self.akamaiFirewall)/devices", 200,
                      "{\"data\":[{\"entity\":{\"id\":4242,\"type\":\"linode\",\"label\":\"shop\"}}]}")
        let linode = await #expect(throws: CloudError.self) { try await Self.make(.akamai, akamai, follows: akamaiReads) }
        #expect(Self.unsure(linode, .akamai, "Please try again"))
        await akamaiReads.done()
        #expect(deleted(akamai).isEmpty)
        let vultr = Self.vultr(), vultrReads = Follows()
        vultr.clear("POST", "/v2/instances")
        vultr.answer("POST", "/v2/instances", 504, "{\"error\":\"Gateway Timeout\"}")
        vultr.answer("GET", "/v2/instances", 200, "{\"instances\":[{\"id\":\"shop\",\"label\":\"shop\","
                     + "\"firewall_group_id\":\"\(Self.vultrFirewall)\"}]}")
        let instance = await #expect(throws: CloudError.self) { try await Self.make(.vultr, vultr, follows: vultrReads) }
        #expect(Self.unsure(instance, .vultr, "Gateway Timeout"))
        await vultrReads.done()
        #expect(deleted(vultr).isEmpty)
    }

    /// **A success to the call for the server with no id that this app reads** (the PC readers' point 1 of 26 November
    /// 2026): the provider made the server, so the servers with the call's mark are read as after a fault answer, at
    /// each provider; the one there goes with the rest. A bug here: the firewall goes with no read, and the server that
    /// the provider made runs on at the owner's cost, at Akamai with no firewall in front of it.
    @Test func aSuccessWithNoIDReadsItsOwnMarkBeforeAnythingIsTakenBack() async throws {
        func deleted(_ stand: ProviderStandIn) -> [String] { stand.calls.filter { $0.method == "DELETE" }.map(\.path) }
        let hetzner = Self.hetzner()
        hetzner.clear("POST", "/v1/servers")
        hetzner.answer("POST", "/v1/servers", 201, "{\"server\":{\"name\":\"hub-1\"}}")
        hetzner.answer("GET", "/v1/firewalls/77", 200, "{\"firewall\":{\"id\":77,\"applied_to\":[{\"type\":\"server\","
                       + "\"server\":{\"id\":1001}}]}}")
        hetzner.answer("GET", "/v1/servers", 200, "{\"servers\":[{\"id\":1001,\"name\":\"hub-1\"}]}")
        let undone = await #expect(throws: CloudError.self) { try await Self.make(.hetzner, hetzner) }
        #expect(undone == .unreadTakenBack(.hetzner, server: "hub-1"))
        #expect(undone.map(BuildRecord.AtProvider.after) == .nothing)
        #expect(deleted(hetzner) == ["/v1/servers/1001", "/v1/firewalls/77"])
        let ocean = Self.digitalOcean()
        ocean.clear("POST", "/v2/droplets")
        ocean.answer("POST", "/v2/droplets", 202, "{\"droplet\":{\"name\":\"hub-1\"}}")
        ocean.answer("GET", "/v2/droplets", 200, "{\"droplets\":[{\"id\":3164444,\"name\":\"hub-1\"}]}")
        await #expect(throws: CloudError.unreadTakenBack(.digitalOcean, server: "hub-1")) { try await Self.make(.digitalOcean, ocean) }
        #expect(deleted(ocean) == [Self.droplet])
        let vultr = Self.vultr()
        vultr.clear("POST", "/v2/instances")
        vultr.answer("POST", "/v2/instances", 202, "{\"instance\":{\"label\":\"hub-1\"}}")
        vultr.answer("GET", "/v2/instances", 200, "{\"instances\":[{\"id\":\"\(Self.vultrInstance)\",\"label\":\"hub-1\","
                     + "\"firewall_group_id\":\"\(Self.vultrFirewall)\"}]}")
        vultr.answer("DELETE", "/v2/firewalls/\(Self.vultrFirewall)", 204, "")
        await #expect(throws: CloudError.unreadTakenBack(.vultr, server: "hub-1")) { try await Self.make(.vultr, vultr) }
        #expect(deleted(vultr) == ["/v2/instances/\(Self.vultrInstance)", "/v2/firewalls/\(Self.vultrFirewall)"])
        let akamai = Self.akamai()
        akamai.clear("POST", "/v4/linode/instances")
        akamai.answer("POST", "/v4/linode/instances", 200, "{\"label\":\"hub-1\"}")
        akamai.answer("GET", "/v4/networking/firewalls/\(Self.akamaiFirewall)/devices", 200,
                      "{\"data\":[{\"entity\":{\"id\":\(Self.linode),\"type\":\"linode\",\"label\":\"hub-1\"}}]}")
        await #expect(throws: CloudError.unreadTakenBack(.akamai, server: "hub-1")) { try await Self.make(.akamai, akamai) }
        #expect(deleted(akamai) == ["/v4/linode/instances/\(Self.linode)", "/v4/networking/firewalls/\(Self.akamaiFirewall)"])
        // Akamai's devices cannot be read: nothing is taken back, its firewall least of all, the end is not known, and
        // the reads go on for the hour.
        let blank = Self.akamai(), reads = Follows()
        blank.clear("POST", "/v4/linode/instances")
        blank.answer("POST", "/v4/linode/instances", 200, "{\"label\":\"hub-1\"}")
        blank.answer("GET", "/v4/networking/firewalls/\(Self.akamaiFirewall)/devices", 500, "{\"errors\":[{\"reason\":\"x\"}]}")
        let open = await #expect(throws: CloudError.self) { try await Self.make(.akamai, blank, follows: reads) }
        guard case .unread(.akamai, "hub-1", let mark)? = open, CloudServers.isFirewallName(mark, ofServer: "hub-1", at: .akamai) else {
            Issue.record("not unread: \(String(describing: open))"); return
        }
        #expect(open?.errorDescription?.contains(" \(CloudError.marked(mark, at: .akamai)) at \(CloudProvider.akamai.name) ") == true)
        #expect(open.map(BuildRecord.AtProvider.after) == .notKnown)
        await reads.done()
        #expect(deleted(blank).isEmpty
                && blank.calls("GET", "/v4/networking/firewalls/\(Self.akamaiFirewall)/devices").count == 1 + CloudServers.followReads)
        // A found server that does not go is said as the answer was, never as deleted, and keeps its firewall.
        let stays = Self.hetzner(), still = Follows()
        stays.clear("POST", "/v1/servers")
        stays.answer("POST", "/v1/servers", 201, "{\"server\":{\"name\":\"hub-1\"}}")
        stays.answer("GET", "/v1/firewalls/77", 200, "{\"firewall\":{\"id\":77,\"applied_to\":[{\"type\":\"server\","
                     + "\"server\":{\"id\":1001}}]}}")
        stays.answer("GET", "/v1/servers", 200, "{\"servers\":[{\"id\":1001,\"name\":\"hub-1\"}]}")
        stays.clear("GET", "/v1/actions/601")
        stays.answer("GET", "/v1/actions/601", 200, "{\"action\":{\"id\":601,\"status\":\"error\","
                     + "\"error\":{\"code\":\"action_failed\",\"message\":\"not deleted\"}}}")
        let left = await #expect(throws: CloudError.self) { try await Self.make(.hetzner, stays, follows: still) }
        guard case .leftBehind(.hetzner, let reason, let what)? = left else {
            Issue.record("not left behind: \(String(describing: left))"); return
        }
        #expect(reason == CloudError.notUnderstood(.hetzner).errorDescription && what.count == 2)
        await still.done()
        #expect(deleted(stays) == Array(repeating: "/v1/servers/1001", count: 1 + CloudServers.followReads))
        // Hetzner keeps the server locked while it makes it, longer than the first asks: a read after them deletes it,
        // then its firewall (the Vault area's SHOULD 3 of 26 November 2026).
        let slow = Self.hetzner(), later = Follows()
        slow.clear("POST", "/v1/servers")
        slow.answer("POST", "/v1/servers", 201, "{\"server\":{\"name\":\"hub-1\"}}")
        slow.answer("GET", "/v1/firewalls/77", 200, "{\"firewall\":{\"id\":77,\"applied_to\":[{\"type\":\"server\","
                    + "\"server\":{\"id\":1001}}]}}")
        slow.answer("GET", "/v1/servers", 200, "{\"servers\":[{\"id\":1001,\"name\":\"hub-1\"}]}")
        slow.clear("DELETE", "/v1/servers/1001")
        for _ in 0..<CloudServers.removeReads {
            slow.answer("DELETE", "/v1/servers/1001", 423, "{\"error\":{\"code\":\"locked\",\"message\":\"server is locked\"}}")
        }
        slow.answer("DELETE", "/v1/servers/1001", 200, "{\"action\":{\"id\":601,\"command\":\"delete_server\",\"status\":\"running\"}}")
        let locked = await #expect(throws: CloudError.self) { try await Self.make(.hetzner, slow, follows: later) }
        guard case .leftBehind(.hetzner, _, _)? = locked else { Issue.record("not left behind: \(String(describing: locked))"); return }
        await later.done()
        #expect(deleted(slow) == Array(repeating: "/v1/servers/1001", count: 1 + CloudServers.removeReads) + ["/v1/firewalls/77"])
    }

    // MARK: - What is not right

    @Test func nothingIsMadeFromWhatIsNotRight() async throws {
        let cases: [(String, String, String, CloudError)] = [
            ("Hub_1", Self.publicKey, Self.authKey, .notAServerName),
            ("hub-", Self.publicKey, Self.authKey, .notAServerName),
            ("h", Self.publicKey, Self.authKey, .notAServerName),
            ("hub-1", "not a key", Self.authKey, .notAPublicKey),
            ("hub-1", Self.publicKey, "tskey-client-kX1234CNTRL-secret", .notAnAuthKey),
        ]
        for (name, key, auth, error) in cases {
            let unused = ProviderStandIn()
            await #expect(throws: error) {
                try await Self.servers(.hetzner, unused).createServer(name: name, use: .hub, publicKey: key, authKey: auth)
            }
            #expect(unused.calls.isEmpty)
        }
        let unused = ProviderStandIn()
        await #expect(throws: CloudError.noToken(.digitalOcean)) {
            try await Self.servers(.digitalOcean, unused, shelf: MemoryShelf()).createServer(
                name: "hub-1", use: .hub, publicKey: Self.publicKey, authKey: Self.authKey)
        }
        #expect(unused.calls.isEmpty)
        #expect(!Self.servers(.digitalOcean, unused, shelf: MemoryShelf()).isHeld)
        #expect(Self.servers(.digitalOcean, unused).isHeld)
    }

    @Test func eachRefusalIsSaidInPlainWords() async throws {
        let busy = ProviderStandIn()
        busy.answer("GET", "/v1/locations", 429, "{\"error\":{\"code\":\"rate_limit_exceeded\",\"message\":\"limit\"}}")
        await #expect(throws: CloudError.rateLimited(.hetzner)) { try await Self.servers(.hetzner, busy).connect(token: Self.token) }
        let away = ProviderStandIn()
        away.offline = true
        await #expect(throws: CloudError.unreachable(.digitalOcean)) { try await Self.servers(.digitalOcean, away).connect(token: Self.token) }
        // A provider's words never carry the token back to the screen.
        let echo = ProviderStandIn()
        echo.answer("GET", "/v2/account", 500, "{\"id\":\"server_error\",\"message\":\"token \(Self.token) failed\"}")
        await #expect(throws: CloudError.refused(.digitalOcean, "token (not shown) failed")) {
            try await Self.servers(.digitalOcean, echo).connect(token: Self.token)
        }
        let all: [CloudError] = [.notAToken(.hetzner), .noToken(.hetzner), .tokenNotAccepted(.digitalOcean), .readOnlyToken(.hetzner),
                                 .readOnlyToken(.digitalOcean), .rateLimited(.hetzner), .unreachable(.hetzner),
                                 .refused(.hetzner, "x"), .notUnderstood(.digitalOcean), .noRoom(.hetzner), .taken(.hetzner), .notReady(.hetzner),
                                 .notAServerName, .notAPublicKey, .notAnAuthKey, .leftBehind(.hetzner, reason: "x", left: ["y"]),
                                 .readOnlyToken(.vultr), .readOnlyToken(.akamai), .tokenNotAccepted(.vultr),
                                 .tokenNotAccepted(.akamai), .notAToken(.akamai), .leftBehind(.vultr, reason: "x", left: ["y"])]
        for error in all {
            let words = try #require(error.errorDescription)
            #expect(!words.isEmpty && !words.contains(Self.token))
        }
    }
}

// MARK: - Before a server is made: what it would be, and what the account holds (the owner's yes of 5 November 2026)

extension CloudServersTests {
    @Test func theServerToMakeIsShownWithItsPriceBeforeAnythingIsMade() async throws {
        let hetzner = Self.hetzner()
        let offer = try await Self.servers(.hetzner, hetzner).offer(use: .hub)
        #expect(offer == CloudOffer(provider: .hetzner, type: "cx23", location: "fsn1", cores: 2, memoryGB: 4, diskGB: 40,
                                    monthlyPrice: Decimal(string: "5.2479")!, currency: "EUR"))
        #expect(offer.place == "Falkenstein, Germany")
        #expect(hetzner.calls.allSatisfy { $0.method == "GET" }, "reading what would be made makes nothing")
        let none = ProviderStandIn()
        await #expect(throws: CloudError.noToken(.hetzner)) {
            try await Self.servers(.hetzner, none, shelf: MemoryShelf()).offer(use: .hub)
        }
        #expect(none.calls.isEmpty)
    }

    @Test func theServerTheOwnerSaidYesToIsTheOnlyOneTried() async throws {
        let chosen = CloudOffer(provider: .hetzner, type: "cx23", location: "nbg1", cores: 2, memoryGB: 4, diskGB: 40,
                                monthlyPrice: 5, currency: "EUR")
        let hetzner = Self.hetzner()
        let server = try await Self.servers(.hetzner, hetzner).createServer(
            name: "hub-1", use: .hub, publicKey: Self.publicKey, authKey: Self.authKey, offer: chosen)
        #expect(server.location == "nbg1")
        #expect(hetzner.calls("POST", "/v1/servers").count == 1)
        // One that is no longer free there makes nothing at all, not another one: the owner said yes to that one. It is
        // taken, and the page shows him the next free one before anything is made.
        let elsewhere = CloudOffer(provider: .hetzner, type: "cx23", location: "hel1", cores: 2, memoryGB: 4, diskGB: 40,
                                   monthlyPrice: 5, currency: "EUR")
        let gone = Self.hetzner()
        await #expect(throws: CloudError.taken(.hetzner)) {
            try await Self.servers(.hetzner, gone).createServer(name: "hub-1", use: .hub, publicKey: Self.publicKey,
                                                                 authKey: Self.authKey, offer: elsewhere)
        }
        #expect(gone.calls("POST", "/v1/servers").isEmpty && gone.calls("POST", "/v1/firewalls").isEmpty)
        // Listed as free, and refused as taken when it is asked for: its firewall goes, and nothing else is made.
        let refused = Self.hetzner()
        refused.clear("POST", "/v1/servers")
        refused.answer("POST", "/v1/servers", 412, "{\"error\":{\"code\":\"resource_unavailable\",\"message\":\"unavailable\"}}")
        await #expect(throws: CloudError.taken(.hetzner)) {
            try await Self.servers(.hetzner, refused).createServer(name: "hub-1", use: .hub, publicKey: Self.publicKey,
                                                                    authKey: Self.authKey, offer: chosen)
        }
        #expect(refused.calls("POST", "/v1/servers").count == 1)
        #expect(refused.calls.filter { $0.method == "DELETE" }.map(\.path) == ["/v1/firewalls/77"])
        // The next offer leaves the taken one out.
        let next = try await Self.servers(.hetzner, Self.hetzner()).offer(use: .hub, except: [chosen.key])
        #expect(next.key != chosen.key)
    }

    @Test func theServersOfAHetznerProjectAreListedPageByPage() async throws {
        let hetzner = ProviderStandIn()
        hetzner.answer("GET", "/v1/servers", 200, "{\"servers\":["
            + "{\"id\":11,\"name\":\"web-1\",\"status\":\"running\",\"public_net\":{\"ipv4\":{\"ip\":\"203.0.113.20\"}},"
            + "\"server_type\":{\"name\":\"cpx22\",\"cores\":2,\"memory\":4.0,\"disk\":80},"
            + "\"image\":{\"os_flavor\":\"ubuntu\",\"os_version\":\"24.04\"},\"location\":{\"name\":\"nbg1\",\"city\":\"Nuremberg\"},"
            + "\"labels\":{}},"
            + "{\"id\":12,\"name\":\"old\",\"status\":\"off\",\"public_net\":{\"ipv4\":null},\"server_type\":{\"name\":\"cx11\","
            + "\"memory\":2},\"image\":null,\"datacenter\":{\"location\":{\"city\":\"Falkenstein\"}},\"labels\":{}}],"
            + "\"meta\":{\"pagination\":{\"page\":1,\"next_page\":2}}}")
        hetzner.answer("GET", "/v1/servers", 200, "{\"servers\":["
            + "{\"id\":13,\"name\":\"worker-1\",\"status\":\"running\",\"public_net\":{\"ipv4\":{\"ip\":\"203.0.113.30\"}},"
            + "\"server_type\":{\"name\":\"cx23\",\"memory\":4},\"image\":{\"os_flavor\":\"ubuntu\",\"os_version\":\"24.04\"},"
            + "\"location\":{\"city\":\"Nuremberg\"},\"labels\":{\"founderizer\":\"hub\"}}],"
            + "\"meta\":{\"pagination\":{\"page\":2,\"next_page\":null}}}")
        let listed = try await Self.servers(.hetzner, hetzner).servers()
        #expect(listed.map(\.name) == ["web-1", "old", "worker-1"])
        #expect(listed[0] == CloudExisting(id: "11", name: "web-1", ipv4: "203.0.113.20", type: "cpx22", memoryMB: 4096,
                                           system: "ubuntu", version: "24.04", place: "Nuremberg", running: true,
                                           project: nil, madeFor: nil))
        #expect(listed[1] == CloudExisting(id: "12", name: "old", ipv4: nil, type: "cx11", memoryMB: 2048, system: nil,
                                           version: nil, place: "Falkenstein", running: false, project: nil, madeFor: nil))
        #expect(listed[2].madeFor == "hub")
        #expect(hetzner.calls("GET", "/v1/servers").map(\.query) == ["per_page=50&page=1", "per_page=50&page=2"])
    }

    @Test func theDropletsOfADigitalOceanTeamSayTheirProjectWhenItHasMoreThanOne() async throws {
        let droplets = "{\"droplets\":["
            + "{\"id\":31,\"name\":\"api\",\"status\":\"active\",\"memory\":2048,\"vcpus\":1,\"disk\":50,"
            + "\"size_slug\":\"s-1vcpu-2gb\",\"image\":{\"distribution\":\"Ubuntu\",\"name\":\"24.04 (LTS) x64\"},"
            + "\"region\":{\"slug\":\"fra1\",\"name\":\"Frankfurt 1\"},\"networks\":{\"v4\":[{\"ip_address\":\"10.0.0.2\","
            + "\"type\":\"private\"},{\"ip_address\":\"198.51.100.31\",\"type\":\"public\"}]},\"tags\":[]},"
            + "{\"id\":32,\"name\":\"db\",\"status\":\"off\",\"memory\":1024,\"size_slug\":\"s-1vcpu-1gb\","
            + "\"image\":{\"distribution\":\"Debian\",\"name\":\"12 x64\"},\"region\":{\"slug\":\"ams3\",\"name\":\"Amsterdam 3\"},"
            + "\"networks\":{\"v4\":[]},\"tags\":[]}]}"
        let ocean = ProviderStandIn()
        ocean.answer("GET", "/v2/droplets", 200, droplets)
        ocean.answer("GET", "/v2/projects", 200, "{\"projects\":[{\"id\":\"p1\",\"name\":\"Web\"},{\"id\":\"p2\",\"name\":\"Data\"}]}")
        ocean.answer("GET", "/v2/projects/p1/resources", 200, "{\"resources\":[{\"urn\":\"do:droplet:31\"}]}")
        ocean.answer("GET", "/v2/projects/p2/resources", 200,
                     "{\"resources\":[{\"urn\":\"do:droplet:32\"},{\"urn\":\"do:volume:abc\"}]}")
        let listed = try await Self.servers(.digitalOcean, ocean).servers()
        #expect(listed == [
            CloudExisting(id: "31", name: "api", ipv4: "198.51.100.31", type: "s-1vcpu-2gb", memoryMB: 2048,
                          system: "ubuntu", version: "24.04", place: "Frankfurt 1", running: true, project: "Web", madeFor: nil),
            CloudExisting(id: "32", name: "db", ipv4: nil, type: "s-1vcpu-1gb", memoryMB: 1024, system: "debian",
                          version: "12", place: "Amsterdam 3", running: false, project: "Data", madeFor: nil)])
        // A team of one project says none, and a token that may not read projects lists the droplets all the same.
        let single = ProviderStandIn()
        single.answer("GET", "/v2/droplets", 200, droplets)
        single.answer("GET", "/v2/projects", 200, "{\"projects\":[{\"id\":\"p1\",\"name\":\"Web\"}]}")
        #expect(try await Self.servers(.digitalOcean, single).servers().allSatisfy { $0.project == nil })
        let unread = ProviderStandIn()
        unread.answer("GET", "/v2/droplets", 200, droplets)
        unread.answer("GET", "/v2/projects", 403, "{\"id\":\"forbidden\",\"message\":\"no\"}")
        #expect(try await Self.servers(.digitalOcean, unread).servers().count == 2)
    }
}

// MARK: - Vultr and Akamai (the owner's yes of 9 November 2026)

extension CloudServersTests {
    /// The shape of a Vultr API key: 36 letters and digits. Not a real one.
    private static let vultrKey = "NOTAREALVULTRKEY0123456789ABCDEFGHIJ"
    private static let vultrInstance = "cb676a46-66fd-4dfb-b839-443f2e6c0b60"
    private static let vultrFirewall = "1234abcd-5678-4ef0-9abc-def012345678"

    /// One of Vultr's plans as `GET /plans` lists it.
    private static func vultrPlan(_ id: String, type: String = "vc2", ram: Int, disk: Int, monthly: Double,
                                  locations: [String]) -> String {
        "{\"id\":\"\(id)\",\"vcpu_count\":1,\"ram\":\(ram),\"disk\":\(disk),\"disk_count\":1,\"bandwidth\":1024,"
            + "\"monthly_cost\":\(monthly),\"hourly_cost\":0.007,\"type\":\"\(type)\",\"deploy_ondemand\":true,"
            + "\"locations\":[\(locations.map { "\"\($0)\"" }.joined(separator: ","))],\"location_cost\":{}}"
    }

    /// A Vultr account that answers everything: no key of this app's yet, and the 1 GB plan free in Frankfurt and
    /// Amsterdam, the 2 GB one in Amsterdam only.
    private static func vultr() -> ProviderStandIn {
        let vultr = ProviderStandIn()
        vultr.answer("GET", "/v2/ssh-keys", 200, "{\"ssh_keys\":[{\"id\":\"k-laptop\",\"name\":\"laptop\",\"ssh_key\":"
                     + "\"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherKeyOtherKeyOtherKeyOtherKeyOtherKey00 laptop\"}],"
                     + "\"meta\":{\"total\":1}}")
        vultr.answer("POST", "/v2/ssh-keys", 201, "{\"ssh_key\":{\"id\":\"k-app\",\"name\":\"founderizer-7210e7120f70\"}}")
        vultr.answer("GET", "/v2/os", 200, "{\"os\":[{\"id\":1743,\"name\":\"Ubuntu 22.04 LTS x64\",\"arch\":\"x64\",\"family\":\"ubuntu\"},"
                     + "{\"id\":2284,\"name\":\"Ubuntu 24.04 LTS x64\",\"arch\":\"x64\",\"family\":\"ubuntu\"},"
                     + "{\"id\":2760,\"name\":\"Ubuntu 26.04 LTS x64\",\"arch\":\"x64\",\"family\":\"ubuntu\"}]}")
        vultr.answer("GET", "/v2/plans", 200, "{\"plans\":[" + [
            vultrPlan("vc2-1c-0.5gb-v6", ram: 512, disk: 10, monthly: 2.5, locations: ["fra"]),
            vultrPlan("vc2-1c-1gb", ram: 1024, disk: 25, monthly: 5, locations: ["fra", "ams", "lhr"]),
            vultrPlan("vc2-1c-2gb", ram: 2048, disk: 55, monthly: 10, locations: ["fra", "ams", "lhr"]),
            vultrPlan("vhp-1c-2gb-amd", type: "vhp", ram: 2048, disk: 50, monthly: 12, locations: ["fra"]),
            // A plan whose disk is block storage, and a plan with a GPU: neither is one of its usual machines.
            vultrPlan("vx1-g-2c-8g", type: "vx1", ram: 8192, disk: 1, monthly: 4, locations: ["fra"]),
            vultrPlan("vcg-a16-6c-60g-16vram", type: "vcg", ram: 61440, disk: 350, monthly: 3, locations: ["fra"]),
        ].joined(separator: ",") + "],\"meta\":{\"total\":6}}")
        vultr.answer("GET", "/v2/regions/fra/availability", 200,
                     "{\"available_plans\":[\"vc2-1c-1gb\",\"vhp-1c-2gb-amd\",\"vx1-g-2c-8g\",\"vcg-a16-6c-60g-16vram\"]}")
        vultr.answer("GET", "/v2/regions/ams/availability", 200, "{\"available_plans\":[\"vc2-1c-1gb\",\"vc2-1c-2gb\"]}")
        for region in ["lhr", "ewr", "sjc", "sgp"] {
            vultr.answer("GET", "/v2/regions/\(region)/availability", 200, "{\"available_plans\":[]}")
        }
        vultr.answer("POST", "/v2/firewalls", 201, "{\"firewall_group\":{\"id\":\"\(vultrFirewall)\",\"rule_count\":0}}")
        vultr.answer("POST", "/v2/instances", 202, "{\"instance\":{\"id\":\"\(vultrInstance)\",\"main_ip\":\"0.0.0.0\","
                     + "\"status\":\"pending\",\"default_password\":\"notarealpassword\"}}")
        vultr.answer("GET", "/v2/instances/\(vultrInstance)", 200, "{\"instance\":{\"id\":\"\(vultrInstance)\","
                     + "\"main_ip\":\"0.0.0.0\",\"status\":\"pending\",\"power_status\":\"running\"}}")
        vultr.answer("GET", "/v2/instances/\(vultrInstance)", 200, "{\"instance\":{\"id\":\"\(vultrInstance)\","
                     + "\"main_ip\":\"192.0.2.44\",\"status\":\"active\",\"power_status\":\"running\"}}")
        vultr.answer("DELETE", "/v2/instances/\(vultrInstance)", 204, "")
        vultr.answer("DELETE", "/v2/firewalls/\(vultrFirewall)", 204, "")
        return vultr
    }

    @Test func aVultrKeyIsCheckedAndKept() async throws {
        let vultr = ProviderStandIn()
        vultr.answer("POST", "/v2/ssh-keys", 400, "{\"error\":\"Missing ssh_key\",\"status\":400}")
        let shelf = MemoryShelf()
        try await Self.servers(.vultr, vultr, shelf: shelf).connect(token: Self.vultrKey)
        #expect(shelf.held == Data(Self.vultrKey.utf8))
        // One write that cannot make anything is the whole check: a user's key reads the account only with billing.
        #expect(vultr.calls.map(\.path) == ["/v2/ssh-keys"])
        #expect(vultr.call("POST", "/v2/ssh-keys")?.body == "{}")
        #expect(vultr.calls.allSatisfy { $0.headers["Authorization"] == "Bearer \(Self.vultrKey)" && $0.url.host == "api.vultr.com" })
        // The key of a user who may not add things.
        let user = ProviderStandIn()
        user.answer("POST", "/v2/ssh-keys", 403, "{\"error\":\"You are not allowed to perform that action.\",\"status\":403}")
        let none = MemoryShelf()
        await #expect(throws: CloudError.readOnlyToken(.vultr)) { try await Self.servers(.vultr, user, shelf: none).connect(token: Self.vultrKey) }
        #expect(none.held == nil)
        // A key Vultr does not know, and one from an address the account does not let in, said in Vultr's words.
        let wrong = ProviderStandIn()
        wrong.answer("POST", "/v2/ssh-keys", 401, "{\"error\":\"Invalid API token.\",\"status\":401}")
        await #expect(throws: CloudError.tokenNotAccepted(.vultr)) { try await Self.servers(.vultr, wrong).connect(token: Self.vultrKey) }
        let elsewhere = ProviderStandIn()
        elsewhere.answer("POST", "/v2/ssh-keys", 401, "{\"error\":\"Unauthorized IP address: 203.0.113.9\",\"status\":401}")
        await #expect(throws: CloudError.refused(.vultr, "Unauthorized IP address: 203.0.113.9")) {
            try await Self.servers(.vultr, elsewhere).connect(token: Self.vultrKey)
        }
    }

    @Test func aVultrServerIsMadeNearTheMacBehindAFirewallThatLetsNothingIn() async throws {
        let vultr = Self.vultr()
        let server = try await Self.make(.vultr, vultr)
        #expect(server == CloudServer(provider: .vultr, id: Self.vultrInstance, name: "hub-1", ipv4: "192.0.2.44",
                                      type: "vc2-1c-2gb", location: "ams", monthlyPrice: 10, currency: "USD",
                                      firewallID: Self.vultrFirewall))
        // The key is not among the account's, so it is registered once.
        let registered = try #require(vultr.call("POST", "/v2/ssh-keys")?.object)
        #expect(registered["name"] as? String == "founderizer-7210e7120f70")
        #expect(registered["ssh_key"] as? String == Self.publicKey)
        // A firewall group with no rule, which lets nothing in: no rule is ever added to it.
        let firewall = try #require(vultr.call("POST", "/v2/firewalls")?.object)
        #expect((firewall["description"] as? String)?.hasPrefix("founderizer-hub-1-") == true)
        #expect(!vultr.calls.contains { $0.path.hasPrefix("/v2/firewalls/") && $0.method == "POST" })
        let made = try #require(vultr.call("POST", "/v2/instances")?.object)
        #expect(made["region"] as? String == "ams")
        #expect(made["plan"] as? String == "vc2-1c-2gb")
        #expect(made["os_id"] as? Int == 2284)
        #expect(made["label"] as? String == "hub-1" && made["hostname"] as? String == "hub-1")
        #expect(made["sshkey_id"] as? [String] == ["k-app"])
        #expect(made["firewall_group_id"] as? String == Self.vultrFirewall)
        #expect(made["user_data"] as? String
                == Data(CloudServers.userData(authKey: Self.authKey, hostname: "hub-1").utf8).base64EncodedString())
        #expect(made["tags"] as? [String] == ["founderizer-hub"])
        #expect(made["backups"] as? String == "disabled" && made["activation_email"] as? Bool == false)
        // Read until it is active with its address, and nothing is taken back.
        #expect(vultr.calls("GET", "/v2/instances/\(Self.vultrInstance)").count == 2)
        #expect(!vultr.calls.contains { $0.method == "DELETE" })
        #expect(vultr.calls.allSatisfy { $0.headers["Authorization"] == "Bearer \(Self.token)" && $0.url.host == "api.vultr.com" })
        // A key the account has already, with another comment, is found by the key itself.
        let known = Self.vultr()
        known.clear("GET", "/v2/ssh-keys")
        known.answer("GET", "/v2/ssh-keys", 200, "{\"ssh_keys\":[{\"id\":\"k-known\",\"ssh_key\":\""
                     + Self.publicKey.replacingOccurrences(of: "founderizer-test", with: "renamed") + "\"}]}")
        _ = try await Self.make(.vultr, known)
        #expect(known.calls("POST", "/v2/ssh-keys").isEmpty)
        #expect(known.call("POST", "/v2/instances")?.object?["sshkey_id"] as? [String] == ["k-known"])
    }

    // MARK: Akamai

    private static let linode = 54748754
    private static let akamaiFirewall = 88712

    /// One of Akamai's plans as `GET /linode/types` lists it.
    private static func akamaiType(_ id: String, kind: String, memory: Int, disk: Int, monthly: String,
                                   successor: String = "null", regionPrices: String = "[]") -> String {
        "{\"id\":\"\(id)\",\"label\":\"x\",\"class\":\"\(kind)\",\"vcpus\":1,\"memory\":\(memory),\"disk\":\(disk),"
            + "\"price\":{\"hourly\":0.0075,\"monthly\":\(monthly)},\"region_prices\":\(regionPrices),\"successor\":\(successor)}"
    }

    /// A region's plans as Akamai lists them: a list, with whether each is free now.
    private static func availability(_ region: String, free: [String], taken: [String] = []) -> String {
        "[" + (free.map { "{\"region\":\"\(region)\",\"plan\":\"\($0)\",\"available\":true}" }
            + taken.map { "{\"region\":\"\(region)\",\"plan\":\"\($0)\",\"available\":false}" }).joined(separator: ",") + "]"
    }

    /// An Akamai account that answers everything: the Nanode free in Frankfurt, and the 2 GB Linode in Amsterdam only.
    private static func akamai() -> ProviderStandIn {
        let akamai = ProviderStandIn()
        akamai.answer("GET", "/v4/linode/types", 200, "{\"data\":[" + [
            akamaiType("g6-nanode-1", kind: "nanode", memory: 1024, disk: 25600, monthly: "5.0"),
            akamaiType("g6-standard-1", kind: "standard", memory: 2048, disk: 51200, monthly: "12.0",
                       regionPrices: "[{\"id\":\"br-gru\",\"hourly\":0.0252,\"monthly\":16.8}]"),
            // A plan on its way out, one with no monthly price, and a dedicated one.
            akamaiType("g6-standard-old", kind: "standard", memory: 2048, disk: 51200, monthly: "1.0",
                       successor: "\"g6-standard-1\""),
            akamaiType("g1-gpu-rtx6000-1", kind: "gpu", memory: 32768, disk: 655360, monthly: "null"),
            akamaiType("g6-dedicated-2", kind: "dedicated", memory: 4096, disk: 81920, monthly: "2.0"),
        ].joined(separator: ",") + "],\"page\":1,\"pages\":1,\"results\":5}")
        akamai.answer("GET", "/v4/regions/eu-central/availability", 200,
                      availability("eu-central", free: ["g6-nanode-1", "g6-standard-old", "g6-dedicated-2"],
                                   taken: ["g6-standard-1"]))
        akamai.answer("GET", "/v4/regions/nl-ams/availability", 200, availability("nl-ams", free: ["g6-nanode-1", "g6-standard-1"]))
        for region in ["eu-west", "us-east", "us-west", "ap-south"] {
            akamai.answer("GET", "/v4/regions/\(region)/availability", 200, availability(region, free: []))
        }
        akamai.answer("POST", "/v4/networking/firewalls", 200, "{\"id\":\(akamaiFirewall),\"label\":\"x\",\"status\":\"enabled\"}")
        akamai.answer("POST", "/v4/linode/instances", 200, "{\"id\":\(linode),\"label\":\"hub-1\",\"status\":\"provisioning\","
                      + "\"ipv4\":[\"198.51.100.88\"]}")
        akamai.answer("GET", "/v4/linode/instances/\(linode)", 200, "{\"id\":\(linode),\"status\":\"booting\",\"ipv4\":[\"198.51.100.88\"]}")
        akamai.answer("GET", "/v4/linode/instances/\(linode)", 200, "{\"id\":\(linode),\"status\":\"running\","
                      + "\"ipv4\":[\"192.168.140.2\",\"198.51.100.88\"]}")
        akamai.answer("DELETE", "/v4/linode/instances/\(linode)", 200, "{}")
        akamai.answer("DELETE", "/v4/networking/firewalls/\(akamaiFirewall)", 200, "{}")
        return akamai
    }

    @Test func anAkamaiTokenIsCheckedAndKept() async throws {
        let akamai = ProviderStandIn()
        akamai.answer("GET", "/v4/profile", 200, "{\"username\":\"owner\"}")
        akamai.answer("POST", "/v4/linode/instances", 400, "{\"errors\":[{\"reason\":\"type is required\",\"field\":\"type\"}]}")
        akamai.answer("POST", "/v4/networking/firewalls", 400, "{\"errors\":[{\"reason\":\"label is required\",\"field\":\"label\"}]}")
        let shelf = MemoryShelf()
        try await Self.servers(.akamai, akamai, shelf: shelf).connect(token: Self.token)
        #expect(shelf.held == Data(Self.token.utf8))
        // Both products a server needs are asked, each with a write that cannot make anything.
        #expect(akamai.call("POST", "/v4/linode/instances")?.body == "{}")
        #expect(akamai.call("POST", "/v4/networking/firewalls")?.body == "{}")
        #expect(akamai.calls.allSatisfy { $0.headers["Authorization"] == "Bearer \(Self.token)" && $0.url.host == "api.linode.com" })
        // A token given Linodes but not Firewalls: Akamai says it is not authorized, and it is not kept.
        let half = ProviderStandIn()
        half.answer("GET", "/v4/profile", 200, "{}")
        half.answer("POST", "/v4/linode/instances", 400, "{\"errors\":[{\"reason\":\"type is required\"}]}")
        half.answer("POST", "/v4/networking/firewalls", 401,
                    "{\"errors\":[{\"reason\":\"Your OAuth token is not authorized to use this endpoint.\"}]}")
        let none = MemoryShelf()
        await #expect(throws: CloudError.readOnlyToken(.akamai)) { try await Self.servers(.akamai, half, shelf: none).connect(token: Self.token) }
        #expect(none.held == nil)
        // One Akamai does not know is not asked anything more.
        let wrong = ProviderStandIn()
        wrong.answer("GET", "/v4/profile", 401, "{\"errors\":[{\"reason\":\"Invalid Token\"}]}")
        await #expect(throws: CloudError.tokenNotAccepted(.akamai)) { try await Self.servers(.akamai, wrong).connect(token: Self.token) }
        #expect(wrong.calls.count == 1)
    }

    @Test func anAkamaiServerIsMadeNearTheMacBehindAFirewallThatDropsAllThatComesIn() async throws {
        let akamai = Self.akamai()
        let server = try await Self.make(.akamai, akamai)
        #expect(server == CloudServer(provider: .akamai, id: String(Self.linode), name: "hub-1", ipv4: "198.51.100.88",
                                      type: "g6-standard-1", location: "nl-ams", monthlyPrice: 12, currency: "USD",
                                      firewallID: String(Self.akamaiFirewall)))
        let firewall = try #require(akamai.call("POST", "/v4/networking/firewalls")?.object)
        let label = try #require(firewall["label"] as? String)
        #expect(label.hasPrefix("fz-hub-1-") && label.count <= 32)
        let rules = try #require(firewall["rules"] as? [String: Any])
        #expect(rules["inbound_policy"] as? String == "DROP" && rules["outbound_policy"] as? String == "ACCEPT")
        #expect((rules["inbound"] as? [Any])?.isEmpty == true && (rules["outbound"] as? [Any])?.isEmpty == true)
        let made = try #require(akamai.call("POST", "/v4/linode/instances")?.object)
        #expect(made["label"] as? String == "hub-1")
        #expect(made["region"] as? String == "nl-ams")
        #expect(made["type"] as? String == "g6-standard-1")
        #expect(made["image"] as? String == "linode/ubuntu24.04")
        #expect(made["authorized_keys"] as? [String] == [Self.publicKey])
        // The kind of interface that the firewall stands in front of, named, so no account's default can leave it out.
        #expect(made["firewall_id"] as? Int == Self.akamaiFirewall)
        #expect(made["interface_generation"] as? String == "legacy_config")
        #expect((made["metadata"] as? [String: String])?["user_data"]
                == Data(CloudServers.userData(authKey: Self.authKey, hostname: "hub-1").utf8).base64EncodedString())
        #expect(made["tags"] as? [String] == ["founderizer-hub"])
        #expect(made["booted"] as? Bool == true && made["backups_enabled"] as? Bool == false)
        // A root password Akamai asks for, of chance, which the server's answer does not carry back.
        let password = try #require(made["root_pass"] as? String)
        #expect(password.count == 32 && password != CloudServers.rootPassword())
        #expect(!String(describing: server).contains(password))
        // Read until it runs, with the public address and not the private one, and nothing is taken back.
        #expect(akamai.calls("GET", "/v4/linode/instances/\(Self.linode)").count == 2)
        #expect(!akamai.calls.contains { $0.method == "DELETE" })
    }

    @Test func akamaisFirewallNameFitsItsLabel() {
        for name in ["hub-1", "abcdefghijklmnopqrstu-vwxyz", "a234567890123456789012345678901"] {
            let label = CloudServers.firewallName(name, at: .akamai)
            #expect(label.count <= 32 && label.hasPrefix("fz-") && !label.contains("--"), "\(label)")
            #expect(label.range(of: "^[a-z][a-z0-9-]+[a-z0-9]$", options: .regularExpression) != nil, "\(label)")
        }
        #expect(CloudServers.firewallName("hub-1", at: .vultr).hasPrefix("founderizer-hub-1-"))
    }

    @Test func vultrAndAkamaiOfferTheirCheapestPlanThatFitsWhereItIsFree() async throws {
        let vultr = Self.vultr()
        // A hub takes 2 GB, as a server for agents does: the 1 GB plan, free in Frankfurt, is no offer for either. The
        // 2 GB plan is not free in Frankfurt now: the nearest place that has it.
        let hub = try await Self.servers(.vultr, vultr).offer(use: .hub)
        #expect(hub == CloudOffer(provider: .vultr, type: "vc2-1c-2gb", location: "ams", cores: 1, memoryGB: 2, diskGB: 55,
                                  monthlyPrice: 10, currency: "USD"))
        #expect(hub.place == "Amsterdam, Netherlands")
        #expect(try await Self.servers(.vultr, vultr).offer(use: .agent) == hub)
        #expect(vultr.calls.allSatisfy { $0.method == "GET" }, "reading what would be made makes nothing")
        let akamai = Self.akamai()
        // At Akamai too: not the Nanode of 1 GB, the 2 GB Linode where it is free.
        let linode = try await Self.servers(.akamai, akamai).offer(use: .hub)
        #expect(linode.type == "g6-standard-1" && linode.location == "nl-ams" && linode.monthlyPrice == 12 && linode.diskGB == 50)
        #expect(try await Self.servers(.akamai, akamai).offer(use: .agent) == linode)
        #expect(akamai.calls.allSatisfy { $0.method == "GET" })
        // A place's own price stands where the provider has one.
        let standard: [String: Any] = ["price": ["monthly": 12.0], "region_prices": [["id": "br-gru", "monthly": 16.8]]]
        #expect(CloudServers.akamaiMonthly(standard, in: "br-gru") == Decimal(string: "16.8"))
        #expect(CloudServers.akamaiMonthly(standard, in: "eu-central") == 12)
        let regular: [String: Any] = ["monthly_cost": 10, "location_cost": ["sao": ["monthly_cost": 15]]]
        #expect(CloudServers.vultrMonthly(regular, at: "sao") == 15 && CloudServers.vultrMonthly(regular, at: "fra") == 10)
    }

    @Test func aVultrOrAkamaiServerThatFailsIsTakenBack() async throws {
        // Vultr refuses the instance: its firewall goes, and Vultr's own words say why.
        let vultr = Self.vultr()
        vultr.clear("POST", "/v2/instances")
        vultr.answer("POST", "/v2/instances", 400, "{\"error\":\"Server add failed: plan is sold out\",\"status\":400}")
        await #expect(throws: CloudError.refused(.vultr, "Server add failed: plan is sold out")) { try await Self.make(.vultr, vultr) }
        #expect(vultr.calls.filter { $0.method == "DELETE" }.map(\.path) == ["/v2/firewalls/\(Self.vultrFirewall)"])
        // The instance is never active: it goes, then its firewall, asked again while the instance still holds it.
        let stuck = Self.vultr()
        stuck.clear("GET", "/v2/instances/\(Self.vultrInstance)")
        stuck.answer("GET", "/v2/instances/\(Self.vultrInstance)", 200, "{\"instance\":{\"status\":\"pending\",\"main_ip\":\"0.0.0.0\"}}")
        stuck.clear("DELETE", "/v2/firewalls/\(Self.vultrFirewall)")
        stuck.answer("DELETE", "/v2/firewalls/\(Self.vultrFirewall)", 400,
                     "{\"error\":\"Unable to delete firewall group: instances still attached\",\"status\":400}")
        stuck.answer("DELETE", "/v2/firewalls/\(Self.vultrFirewall)", 204, "")
        await #expect(throws: CloudError.notReady(.vultr)) { try await Self.make(.vultr, stuck) }
        #expect(stuck.calls("GET", "/v2/instances/\(Self.vultrInstance)").count == CloudServers.waitReads)
        #expect(stuck.calls.filter { $0.method == "DELETE" }.map(\.path)
                == ["/v2/instances/\(Self.vultrInstance)", "/v2/firewalls/\(Self.vultrFirewall)", "/v2/firewalls/\(Self.vultrFirewall)"])
        // Akamai refuses the Linode: its firewall goes, and Akamai's own words say why, with the field they are about.
        let akamai = Self.akamai()
        akamai.clear("POST", "/v4/linode/instances")
        akamai.answer("POST", "/v4/linode/instances", 400,
                      "{\"errors\":[{\"reason\":\"Linode interfaces only\",\"field\":\"interface_generation\"}]}")
        await #expect(throws: CloudError.refused(.akamai, "interface_generation: Linode interfaces only")) {
            try await Self.make(.akamai, akamai)
        }
        #expect(akamai.calls.filter { $0.method == "DELETE" }.map(\.path) == ["/v4/networking/firewalls/\(Self.akamaiFirewall)"])
        // The Linode never runs: it goes, and its firewall.
        let slow = Self.akamai()
        slow.clear("GET", "/v4/linode/instances/\(Self.linode)")
        slow.answer("GET", "/v4/linode/instances/\(Self.linode)", 200, "{\"status\":\"provisioning\",\"ipv4\":[\"198.51.100.88\"]}")
        await #expect(throws: CloudError.notReady(.akamai)) { try await Self.make(.akamai, slow) }
        #expect(slow.calls.filter { $0.method == "DELETE" }.map(\.path)
                == ["/v4/linode/instances/\(Self.linode)", "/v4/networking/firewalls/\(Self.akamaiFirewall)"])
    }

    @Test func theServersOfAVultrAccountAreListed() async throws {
        let vultr = ProviderStandIn()
        vultr.answer("GET", "/v2/instances", 200, "{\"instances\":["
            + "{\"id\":\"i-1\",\"label\":\"web\",\"main_ip\":\"192.0.2.10\",\"ram\":2048,\"plan\":\"vc2-1c-2gb\","
            + "\"os\":\"Ubuntu 24.04 LTS x64\",\"region\":\"fra\",\"status\":\"active\",\"power_status\":\"running\",\"tags\":[]},"
            + "{\"id\":\"i-2\",\"label\":\"old\",\"main_ip\":\"0.0.0.0\",\"ram\":1024,\"plan\":\"vc2-1c-1gb\","
            + "\"os\":\"Debian 12 x64 (bookworm)\",\"region\":\"zzz\",\"status\":\"active\",\"power_status\":\"stopped\","
            + "\"tags\":[\"founderizer-agent\"]}],\"meta\":{\"total\":2}}")
        vultr.answer("GET", "/v2/regions", 200, "{\"regions\":[{\"id\":\"fra\",\"city\":\"Frankfurt\",\"country\":\"DE\"}]}")
        let listed = try await Self.servers(.vultr, vultr).servers()
        #expect(listed == [
            CloudExisting(id: "i-1", name: "web", ipv4: "192.0.2.10", type: "vc2-1c-2gb", memoryMB: 2048, system: "ubuntu",
                          version: "24.04", place: "Frankfurt", running: true, project: nil, madeFor: nil),
            CloudExisting(id: "i-2", name: "old", ipv4: nil, type: "vc2-1c-1gb", memoryMB: 1024, system: "debian",
                          version: "12", place: "zzz", running: false, project: nil, madeFor: "agent")])
        #expect(vultr.call("GET", "/v2/instances")?.query == "per_page=500")
    }

    @Test func theLinodesOfAnAkamaiAccountAreListedPageByPage() async throws {
        let akamai = ProviderStandIn()
        akamai.answer("GET", "/v4/regions", 200, "{\"data\":[{\"id\":\"eu-central\",\"label\":\"Frankfurt, DE\"}],\"pages\":1}")
        akamai.answer("GET", "/v4/linode/instances", 200, "{\"data\":[{\"id\":11,\"label\":\"api\",\"status\":\"running\","
            + "\"ipv4\":[\"192.168.130.4\",\"198.51.100.11\"],\"type\":\"g6-standard-1\",\"specs\":{\"memory\":2048},"
            + "\"image\":\"linode/ubuntu24.04\",\"region\":\"eu-central\",\"tags\":[]}],\"page\":1,\"pages\":2,\"results\":2}")
        akamai.answer("GET", "/v4/linode/instances", 200, "{\"data\":[{\"id\":12,\"label\":\"hub\",\"status\":\"offline\","
            + "\"ipv4\":[],\"type\":\"g6-nanode-1\",\"specs\":{\"memory\":1024},\"image\":\"private/123\",\"region\":\"us-east\","
            + "\"tags\":[\"founderizer-hub\"]}],\"page\":2,\"pages\":2,\"results\":2}")
        let listed = try await Self.servers(.akamai, akamai).servers()
        #expect(listed == [
            CloudExisting(id: "11", name: "api", ipv4: "198.51.100.11", type: "g6-standard-1", memoryMB: 2048,
                          system: "ubuntu", version: "24.04", place: "Frankfurt, DE", running: true, project: nil, madeFor: nil),
            CloudExisting(id: "12", name: "hub", ipv4: nil, type: "g6-nanode-1", memoryMB: 1024, system: nil, version: nil,
                          place: "us-east", running: false, project: nil, madeFor: "hub")])
        #expect(akamai.calls("GET", "/v4/linode/instances").map(\.query) == ["page_size=100&page=1", "page_size=100&page=2"])
    }
}
