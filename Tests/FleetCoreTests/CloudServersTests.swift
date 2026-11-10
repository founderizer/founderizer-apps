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
                                zone: TimeZone = berlin) -> CloudServers {
        CloudServers(provider: provider, exchange: stand.exchange, shelf: shelf ?? MemoryShelf(Data(token.utf8)), zone: zone,
                     pause: { _ in })
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
        #expect(CloudProvider.digitalOceanSize(for: .hub) == "s-1vcpu-1gb")
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

    @Test func theFirstBootJoinsThePrivateNetworkOnce() {
        #expect(CloudServers.userData(authKey: Self.authKey, hostname: "hub-1") == """
        #!/bin/sh
        curl -fsSL https://tailscale.com/install.sh | sh
        tailscale up --auth-key=tskey-auth-kAUTH1234CNTRL-notarealkey --hostname=hub-1 --accept-dns=false

        """)
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
                                    architecture: String = "x86", monthly: String = "4.1531", deprecated: Bool = false) -> String {
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
        return "{\"id\":114,\"name\":\"\(name)\",\"cores\":2,\"memory\":\(memory),\"disk\":\(disk),"
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
        + "{\"type\":\"ipv6\",\"prices\":[{\"location\":\"fsn1\",\"price_hourly\":{\"net\":\"0.0000\",\"gross\":\"0.0000\"},"
        + "\"price_monthly\":{\"net\":\"0.0000\",\"gross\":\"0.0000\"}}]}],\"server_types\":[]}}"

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
                             zone: TimeZone = berlin) async throws -> CloudServer {
        try await servers(provider, stand, zone: zone).createServer(name: "hub-1", use: use, publicKey: publicKey,
                                                                     authKey: authKey)
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
        // The provider's id, the address, and what it costs a month: the type and its public addresses, with tax.
        #expect(server == CloudServer(provider: .hetzner, id: "1001", name: "hub-1", ipv4: "203.0.113.10", type: "cx23",
                                      location: "fsn1", monthlyPrice: Decimal(string: "4.7481")!, currency: "EUR",
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
        #expect(made["user_data"] as? String == CloudServers.userData(authKey: Self.authKey, hostname: "hub-1"))
        // Its creation is read until it ends, and nothing is taken back.
        #expect(hetzner.calls("GET", "/v1/actions/501").count == 4)
        #expect(!hetzner.calls.contains { $0.method == "DELETE" })
        #expect(hetzner.calls.allSatisfy { $0.url.scheme == "https" && $0.url.host == "api.hetzner.cloud" })
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
            Self.hetznerType("other", free: ["fsn1"], architecture: "riscv", monthly: "3.0000")))
        let servers = Self.servers(.hetzner, hetzner)
        // A hub takes 1 GB: the cheapest type with that much, and at one price the nearest place (Nuremberg for Berlin).
        let hub = try await servers.offer(use: .hub)
        #expect(hub.type == "cpx02" && hub.location == "nbg1" && hub.monthlyPrice == Decimal(string: "6.5850")!)
        // A server for agents takes 2 GB.
        let agent = try await servers.offer(use: .agent)
        #expect(agent.type == "cpx12" && agent.location == "nbg1" && agent.monthlyPrice == Decimal(string: "12.0850")!)
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
        await #expect(throws: CloudError.refused(.hetzner, "server limit reached")) { try await Self.make(.hetzner, limit) }
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
        #expect(hetzner.calls("DELETE", "/v1/firewalls/77").count == CloudServers.removeReads)
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
                     + "\"regions\":[\"ams3\",\"lon1\"],\"available\":true}],\"links\":{},\"meta\":{\"total\":2}}")
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
        #expect(server == CloudServer(provider: .digitalOcean, id: "3164444", name: "hub-1", ipv4: "198.51.100.7",
                                      type: "s-1vcpu-1gb", location: "fra1", monthlyPrice: 6, currency: "USD",
                                      firewallID: Self.oceanFirewall))
        // Not found by its fingerprint, so registered once.
        let registered = try #require(ocean.call("POST", "/v2/account/keys")?.object)
        #expect(registered["public_key"] as? String == Self.publicKey)
        #expect(registered["name"] as? String == "founderizer-7210e7120f70")
        #expect(ocean.call("GET", "/v2/sizes")?.query == "per_page=200")
        let made = try #require(ocean.call("POST", "/v2/droplets")?.object)
        #expect(made["name"] as? String == "hub-1")
        #expect(made["region"] as? String == "fra1")
        #expect(made["size"] as? String == "s-1vcpu-1gb")
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
        #expect(second.location == "ams3")
        #expect(busy.calls("POST", "/v2/account/keys").isEmpty)
        #expect(busy.calls("POST", "/v2/droplets").compactMap { $0.object?["ssh_keys"] as? [Int] } == [[512189], [512189]])
        // When no region can, DigitalOcean's own words say why.
        let none = Self.digitalOcean()
        none.clear("POST", "/v2/droplets")
        none.answer("POST", "/v2/droplets", 422, "{\"id\":\"unprocessable_entity\",\"message\":\"Size is not available in this region.\"}")
        await #expect(throws: CloudError.refused(.digitalOcean, "Size is not available in this region.")) {
            try await Self.make(.digitalOcean, none)
        }
        #expect(none.calls("POST", "/v2/droplets").count == 6)
        #expect(!none.calls.contains { $0.method == "DELETE" })
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
                                 .refused(.hetzner, "x"), .notUnderstood(.digitalOcean), .noRoom(.hetzner), .notReady(.hetzner),
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
                                    monthlyPrice: Decimal(string: "4.7481")!, currency: "EUR"))
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
        // One that is no longer free there makes nothing at all, not another one: the owner said yes to that one.
        let elsewhere = CloudOffer(provider: .hetzner, type: "cx23", location: "hel1", cores: 2, memoryGB: 4, diskGB: 40,
                                   monthlyPrice: 5, currency: "EUR")
        let gone = Self.hetzner()
        await #expect(throws: CloudError.noRoom(.hetzner)) {
            try await Self.servers(.hetzner, gone).createServer(name: "hub-1", use: .hub, publicKey: Self.publicKey,
                                                                 authKey: Self.authKey, offer: elsewhere)
        }
        #expect(gone.calls("POST", "/v1/servers").isEmpty && gone.calls("POST", "/v1/firewalls").isEmpty)
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
                                      type: "vc2-1c-1gb", location: "fra", monthlyPrice: 5, currency: "USD",
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
        #expect(made["region"] as? String == "fra")
        #expect(made["plan"] as? String == "vc2-1c-1gb")
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
                                      type: "g6-nanode-1", location: "eu-central", monthlyPrice: 5, currency: "USD",
                                      firewallID: String(Self.akamaiFirewall)))
        let firewall = try #require(akamai.call("POST", "/v4/networking/firewalls")?.object)
        let label = try #require(firewall["label"] as? String)
        #expect(label.hasPrefix("fz-hub-1-") && label.count <= 32)
        let rules = try #require(firewall["rules"] as? [String: Any])
        #expect(rules["inbound_policy"] as? String == "DROP" && rules["outbound_policy"] as? String == "ACCEPT")
        #expect((rules["inbound"] as? [Any])?.isEmpty == true && (rules["outbound"] as? [Any])?.isEmpty == true)
        let made = try #require(akamai.call("POST", "/v4/linode/instances")?.object)
        #expect(made["label"] as? String == "hub-1")
        #expect(made["region"] as? String == "eu-central")
        #expect(made["type"] as? String == "g6-nanode-1")
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
        #expect(try await Self.servers(.vultr, vultr).offer(use: .hub)
                == CloudOffer(provider: .vultr, type: "vc2-1c-1gb", location: "fra", cores: 1, memoryGB: 1, diskGB: 25,
                              monthlyPrice: 5, currency: "USD"))
        // The 2 GB plan is not free in Frankfurt now: the nearest place that has it.
        let agent = try await Self.servers(.vultr, vultr).offer(use: .agent)
        #expect(agent == CloudOffer(provider: .vultr, type: "vc2-1c-2gb", location: "ams", cores: 1, memoryGB: 2, diskGB: 55,
                                    monthlyPrice: 10, currency: "USD"))
        #expect(agent.place == "Amsterdam, Netherlands")
        #expect(vultr.calls.allSatisfy { $0.method == "GET" }, "reading what would be made makes nothing")
        let akamai = Self.akamai()
        #expect(try await Self.servers(.akamai, akamai).offer(use: .hub)
                == CloudOffer(provider: .akamai, type: "g6-nanode-1", location: "eu-central", cores: 1, memoryGB: 1, diskGB: 25,
                              monthlyPrice: 5, currency: "USD"))
        let linode = try await Self.servers(.akamai, akamai).offer(use: .agent)
        #expect(linode.type == "g6-standard-1" && linode.location == "nl-ams" && linode.monthlyPrice == 12 && linode.diskGB == 50)
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
