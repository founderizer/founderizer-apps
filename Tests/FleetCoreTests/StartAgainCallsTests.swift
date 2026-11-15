#if os(macOS)
import Foundation
import Testing
@testable import FleetCore

/// **The calls of "Start again" to a provider and to Tailscale** (`CloudServers.deleteServer`, `firewalls`,
/// `deleteFirewalls`, `deleteKey`; `TailscaleFleetKey.devices`, `deleteDevice`): each deletes one thing by the
/// provider's own id of it, and what is gone already is deleted. Every request goes to a stand-in, so nothing here
/// needs a network, an account or a real token, and nothing is ever deleted anywhere.
struct StartAgainCallsTests {
    private static let token = "notarealtoken0123456789notarealtoken0123456789notarealtoken0123"
    /// A key made for the tests of `CloudServers` with `ssh-keygen -t ed25519`, whose private half was thrown away.
    private static let publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAo/DN+NoNbdAzU3DYGLTD7ne5vXT9bm+oEyoiacxwWg founderizer-test"
    private static let fingerprint = "72:10:e7:12:0f:70:ca:e3:25:aa:b4:7c:4c:b1:75:24"

    private static func servers(_ provider: CloudProvider, _ stand: ProviderStandIn, shelf: MemoryShelf? = nil) -> CloudServers {
        CloudServers(provider: provider, exchange: stand.exchange, shelf: shelf ?? MemoryShelf(Data(token.utf8)),
                     zone: TimeZone(identifier: "Europe/Berlin")!, pause: { _ in })
    }

    private static func deletes(_ stand: ProviderStandIn) -> [String] { stand.calls.filter { $0.method == "DELETE" }.map(\.path) }

    // MARK: - One server, by its id

    @Test func aServerIsDeletedByItsIdAndOneThatIsGoneIsDeleted() async throws {
        let hetzner = ProviderStandIn()
        hetzner.answer("DELETE", "/v1/servers/101", 200, "{\"action\":{\"id\":601,\"command\":\"delete_server\",\"status\":\"running\"}}")
        hetzner.answer("GET", "/v1/actions/601", 200, "{\"action\":{\"id\":601,\"status\":\"running\"}}")
        hetzner.answer("GET", "/v1/actions/601", 200, "{\"action\":{\"id\":601,\"status\":\"success\"}}")
        let deleted = try await Self.servers(.hetzner, hetzner).deleteServer(id: "101")
        #expect(deleted == .deleted)
        #expect(Self.deletes(hetzner) == ["/v1/servers/101"])
        // Hetzner's deletion is an action: it is read until it ends.
        #expect(hetzner.calls("GET", "/v1/actions/601").count == 2)
        #expect(hetzner.call("DELETE", "/v1/servers/101")?.headers["Authorization"] == "Bearer \(Self.token)")
        // A server that the provider does not have for this token is not said to be deleted: the answer says "not
        // there", with the provider's own words, and the caller decides (the server is gone, or it is another
        // project's).
        hetzner.answer("DELETE", "/v1/servers/999", 404, "{\"error\":{\"code\":\"not_found\",\"message\":\"server with ID '999' not found\"}}")
        let missing = try await Self.servers(.hetzner, hetzner).deleteServer(id: "999")
        #expect(missing == .notThere(.refused(.hetzner, "server with ID '999' not found")))
        // Each provider by its own path.
        for (provider, path) in [(CloudProvider.digitalOcean, "/v2/droplets/7"), (.vultr, "/v2/instances/7"), (.akamai, "/v4/linode/instances/7")] {
            let stand = ProviderStandIn()
            stand.answer("DELETE", path, 204, "")
            let deleted = try await Self.servers(provider, stand).deleteServer(id: "7")
            #expect(deleted == .deleted && Self.deletes(stand) == [path], "\(provider)")
        }
    }

    @Test func aServersDeletionThatFailsSaysSo() async throws {
        // The token is not taken.
        let refused = ProviderStandIn()
        refused.answer("DELETE", "/v1/servers/101", 401, "{\"error\":{\"code\":\"unauthorized\",\"message\":\"unable to authenticate\"}}")
        await #expect(throws: CloudError.tokenNotAccepted(.hetzner)) { try await Self.servers(.hetzner, refused).deleteServer(id: "101") }
        // This Mac holds no token of the provider.
        await #expect(throws: CloudError.noToken(.hetzner)) {
            try await Self.servers(.hetzner, ProviderStandIn(), shelf: MemoryShelf()).deleteServer(id: "101")
        }
        // No connection.
        let offline = ProviderStandIn()
        offline.offline = true
        await #expect(throws: CloudError.unreachable(.hetzner)) { try await Self.servers(.hetzner, offline).deleteServer(id: "101") }
        // Hetzner's action ended with an error: its own words.
        let failed = ProviderStandIn()
        failed.answer("DELETE", "/v1/servers/101", 200, "{\"action\":{\"id\":601,\"status\":\"running\"}}")
        failed.answer("GET", "/v1/actions/601", 200, "{\"action\":{\"id\":601,\"status\":\"error\",\"error\":{\"code\":\"action_failed\",\"message\":\"the server is locked\"}}}")
        await #expect(throws: CloudError.refused(.hetzner, "the server is locked")) { try await Self.servers(.hetzner, failed).deleteServer(id: "101") }
        // **The caller knows a deletion from the moment the provider takes it**, also when the wait for its end fails
        // or is cut off; a refusal and a 404 are no deletion that the provider took.
        final class Count: @unchecked Sendable { private let lock = NSLock(); private var n = 0
            func add() { lock.withLock { n += 1 } }; var value: Int { lock.withLock { n } } }
        let taken = Count()
        _ = try? await Self.servers(.hetzner, failed).deleteServer(id: "101") { taken.add() }
        #expect(taken.value == 1)
        _ = try? await Self.servers(.hetzner, refused).deleteServer(id: "101") { taken.add() }
        _ = try? await Self.servers(.hetzner, ProviderStandIn()).deleteServer(id: "404") { taken.add() }
        _ = try? await Self.servers(.hetzner, offline).deleteServer(id: "101") { taken.add() }
        #expect(taken.value == 1)
        // An action that still runs after every read is settled by the server itself: gone, or not.
        let slow = ProviderStandIn()
        slow.answer("DELETE", "/v1/servers/101", 200, "{\"action\":{\"id\":601,\"status\":\"running\"}}")
        slow.answer("GET", "/v1/actions/601", 200, "{\"action\":{\"id\":601,\"status\":\"running\"}}")
        let settled = try await Self.servers(.hetzner, slow).deleteServer(id: "101")
        #expect(settled == .deleted)
        #expect(slow.calls("GET", "/v1/actions/601").count == CloudServers.waitReads && slow.calls("GET", "/v1/servers/101").count == 1)
        slow.answer("GET", "/v1/servers/101", 200, "{\"server\":{\"id\":101}}")
        await #expect(throws: CloudError.notUnderstood(.hetzner)) { try await Self.servers(.hetzner, slow).deleteServer(id: "101") }
    }

    @Test func nothingThatIsNoIdOfAProviderReachesAPath() async throws {
        let stand = ProviderStandIn()
        for id in ["", "101/actions", "../firewalls/77", "101?force=true", "10 1", "101\n", "101\r\n", String(repeating: "1", count: 65)] {
            await #expect(throws: CloudError.notUnderstood(.hetzner)) { try await Self.servers(.hetzner, stand).deleteServer(id: id) }
            await #expect(throws: CloudError.notUnderstood(.hetzner)) { try await Self.servers(.hetzner, stand).deleteFirewall(id: id) }
        }
        #expect(stand.calls.isEmpty)
        #expect(CloudServers.isID("101") && CloudServers.isID("cb676a46-66fd-4dfb-b839-443f2e6c0b60"))
        #expect(TailscaleFleetKey.isDeviceID("nWORKER1CNTRL") && !TailscaleFleetKey.isDeviceID("nWORKER1CNTRL\n")
            && !TailscaleFleetKey.isDeviceID("n-1") && !TailscaleFleetKey.isDeviceID(""))
    }

    // MARK: - The firewalls of one server's name

    @Test func aFirewallIsAServersOnlyByTheExactFormOfItsName() {
        func mine(_ candidate: String, _ name: String = "worker-1", at provider: CloudProvider = .hetzner) -> Bool {
            CloudServers.isFirewallName(candidate, ofServer: name, at: provider)
        }
        #expect(mine("founderizer-worker-1-ab12cd"))
        #expect(mine(CloudServers.firewallName("worker-1")))
        // Another server whose name only starts the same, more or fewer characters of chance, other characters.
        #expect(!mine("founderizer-worker-10-ab12cd") && !mine("founderizer-worker-1-ab12cd", "worker-10"))
        #expect(!mine("founderizer-worker-1-ab12c") && !mine("founderizer-worker-1-ab12cde") && !mine("founderizer-worker-1-AB12CD"))
        #expect(!mine("founderizer-worker-1-ab12c_") && !mine("worker-1-ab12cd") && !mine("founderizer-worker-1"))
        // Akamai's shorter form, with a long name cut as the app cuts it.
        #expect(mine("fz-worker-1-ab12cd", at: .akamai) && !mine("founderizer-worker-1-ab12cd", at: .akamai))
        let long = "a-server-with-a-very-long-name"
        #expect(mine(CloudServers.firewallName(long, at: .akamai), long, at: .akamai))
    }

    @Test func hetznersFirewallsAreFoundByNameAndLabelAndAskedAgainWhileInUse() async throws {
        let hetzner = ProviderStandIn()
        hetzner.answer("GET", "/v1/firewalls", 200, """
        {"firewalls":[
          {"id":77,"name":"founderizer-worker-1-ab12cd","labels":{"founderizer":"hub"},"applied_to":[{"type":"server","server":{"id":101}}]},
          {"id":78,"name":"founderizer-worker-10-ab12cd","labels":{"founderizer":"agent"},"applied_to":[]},
          {"id":79,"name":"founderizer-worker-1-zz99zz","labels":{},"applied_to":[]},
          {"id":80,"name":"founderizer-worker-1-qq11qq","labels":{"founderizer":"agent"},"applied_to":[{"type":"label_selector","label_selector":{"selector":"env=prod"}}]}
        ],"meta":{"pagination":{"page":1,"next_page":null}}}
        """)
        let servers = Self.servers(.hetzner, hetzner)
        let found = try await servers.firewalls(ofServer: "worker-1")
        // Only the two with the exact name and the app's label; each with what it stands in front of.
        #expect(found == [CloudFirewall(id: "77", servers: ["101"], other: false), CloudFirewall(id: "80", servers: [], other: true)])
        #expect(hetzner.call("GET", "/v1/firewalls")?.query.contains("label_selector=founderizer") == true)
        #expect(found[0].isFree(of: ["101"]) && !found[0].isFree(of: ["102"]) && !found[1].isFree(of: ["101"]))
        // Hetzner refuses to delete a firewall in use: it is asked again while the server's deletion runs.
        hetzner.answer("DELETE", "/v1/firewalls/77", 422, "{\"error\":{\"code\":\"resource_in_use\",\"message\":\"firewall still applied\"}}")
        hetzner.answer("DELETE", "/v1/firewalls/77", 204, "")
        hetzner.answer("DELETE", "/v1/firewalls/80", 422, "{\"error\":{\"code\":\"resource_in_use\",\"message\":\"firewall still applied\"}}")
        // One that stays in use after every ask is a failed step, in Hetzner's words; nothing else was deleted.
        await #expect(throws: CloudError.refused(.hetzner, "firewall still applied")) {
            try await servers.deleteFirewalls(ofServer: "worker-1", deleted: ["101"])
        }
        #expect(hetzner.calls("DELETE", "/v1/firewalls/77").count == 2)
        #expect(hetzner.calls("DELETE", "/v1/firewalls/80").count == CloudServers.removeReads)
        #expect(Set(Self.deletes(hetzner)) == ["/v1/firewalls/77", "/v1/firewalls/80"])
        // A name that is no server's name asks for nothing.
        #expect(try await servers.firewalls(ofServer: "Worker 1").isEmpty)
        // Every firewall that may go is asked, also after one that failed: a firewall that another server holds, and
        // that the list names first, does not keep this server's own firewall at the provider.
        let two = ProviderStandIn()
        two.answer("GET", "/v1/firewalls", 200, """
        {"firewalls":[
          {"id":80,"name":"founderizer-worker-1-qq11qq","labels":{"founderizer":"agent"},"applied_to":[{"type":"server","server":{"id":555}}]},
          {"id":77,"name":"founderizer-worker-1-ab12cd","labels":{"founderizer":"hub"},"applied_to":[]}
        ],"meta":{"pagination":{"page":1,"next_page":null}}}
        """)
        two.answer("DELETE", "/v1/firewalls/80", 422, "{\"error\":{\"code\":\"resource_in_use\",\"message\":\"firewall still applied\"}}")
        two.answer("DELETE", "/v1/firewalls/77", 204, "")
        await #expect(throws: CloudError.refused(.hetzner, "firewall still applied")) {
            try await Self.servers(.hetzner, two).deleteFirewalls(ofServer: "worker-1", deleted: ["101"])
        }
        #expect(two.calls("DELETE", "/v1/firewalls/77").count == 1)
    }

    @Test func digitalOceanAndAkamaiKeepAFirewallThatAnotherServerUses() async throws {
        // DigitalOcean deletes a firewall that is in use, so the app reads its droplets first.
        let ocean = ProviderStandIn()
        ocean.answer("GET", "/v2/firewalls", 200, """
        {"firewalls":[
          {"id":"fw-own","name":"founderizer-worker-1-ab12cd","droplet_ids":[101],"tags":[]},
          {"id":"fw-other","name":"founderizer-worker-1-cd34ef","droplet_ids":[101,555],"tags":[]},
          {"id":"fw-tag","name":"founderizer-worker-1-ef56gh","droplet_ids":[],"tags":["web"]},
          {"id":"fw-odd","name":"founderizer-worker-1-gh78ij"},
          {"id":"fw-free","name":"founderizer-worker-1-ij90kl","droplet_ids":[],"tags":[]},
          {"id":"fw-name","name":"founderizer-worker-11-ab12cd","droplet_ids":[],"tags":[]}
        ]}
        """)
        for id in ["fw-own", "fw-free"] { ocean.answer("DELETE", "/v2/firewalls/\(id)", 204, "") }
        try await Self.servers(.digitalOcean, ocean).deleteFirewalls(ofServer: "worker-1", deleted: ["101"])
        #expect(Self.deletes(ocean) == ["/v2/firewalls/fw-own", "/v2/firewalls/fw-free"])
        // Akamai too: the firewall's own devices say what it stands in front of.
        let akamai = ProviderStandIn()
        akamai.answer("GET", "/v4/networking/firewalls", 200, """
        {"data":[{"id":31,"label":"fz-worker-1-ab12cd"},{"id":32,"label":"fz-worker-1-cd34ef"},{"id":33,"label":"fz-worker-1-ef56gh"},
                 {"id":34,"label":"fz-worker-2-ab12cd"}],"page":1,"pages":1}
        """)
        akamai.answer("GET", "/v4/networking/firewalls/31/devices", 200, "{\"data\":[{\"id\":1,\"entity\":{\"id\":101,\"type\":\"linode\"}}]}")
        akamai.answer("GET", "/v4/networking/firewalls/32/devices", 200, "{\"data\":[{\"id\":2,\"entity\":{\"id\":555,\"type\":\"linode\"}}]}")
        akamai.answer("GET", "/v4/networking/firewalls/33/devices", 200, "{\"data\":[{\"id\":3,\"entity\":{\"id\":9,\"type\":\"nodebalancer\"}}]}")
        akamai.answer("DELETE", "/v4/networking/firewalls/31", 200, "{}")
        try await Self.servers(.akamai, akamai).deleteFirewalls(ofServer: "worker-1", deleted: ["101"])
        #expect(Self.deletes(akamai) == ["/v4/networking/firewalls/31"])
        #expect(akamai.calls("GET", "/v4/networking/firewalls/34/devices").isEmpty)
    }

    /// Vultr's list says only how many servers a group has. This app relies on no refusal of Vultr's: a group that
    /// has a server is never asked to go.
    @Test func vultrsGroupsGoOnlyWhenTheyHaveNoServer() async throws {
        let own = "cb676a46-66fd-4dfb-b839-443f2e6c0b60", used = "3b8066a7-b438-455a-9688-44afc9a3597f"
        func groups(_ count: Int) -> String {
            """
            {"firewall_groups":[{"id":"\(own)","description":"founderizer-worker-1-ab12cd","instance_count":\(count)},
                                {"id":"1f5b0b2e-7c5f-4c5c-9c36-0d3c1e7b9a10","description":"my own group","instance_count":0}]}
            """
        }
        // The group still counts the server whose deletion runs: it is read again, and goes once it has none.
        let vultr = ProviderStandIn()
        vultr.answer("GET", "/v2/firewalls", 200, groups(1))
        vultr.answer("GET", "/v2/firewalls", 200, groups(1))
        vultr.answer("GET", "/v2/firewalls", 200, groups(0))
        vultr.answer("DELETE", "/v2/firewalls/\(own)", 204, "")
        try await Self.servers(.vultr, vultr).deleteFirewalls(ofServer: "worker-1", deleted: ["7"])
        #expect(vultr.calls("GET", "/v2/firewalls").count == 3 && Self.deletes(vultr) == ["/v2/firewalls/\(own)"])
        // A group that has a server after every read is another server's now: it stays, and it is not asked. A group
        // whose count the answer does not give is not known to be free.
        let held = ProviderStandIn()
        held.answer("GET", "/v2/firewalls", 200, """
        {"firewall_groups":[{"id":"\(used)","description":"founderizer-worker-1-cd34ef","instance_count":1},
                            {"id":"\(own)","description":"founderizer-worker-1-ab12cd"}]}
        """)
        try await Self.servers(.vultr, held).deleteFirewalls(ofServer: "worker-1", deleted: ["7"])
        #expect(held.calls("GET", "/v2/firewalls").count == CloudServers.removeReads && Self.deletes(held).isEmpty)
        let found = try await Self.servers(.vultr, held).firewalls(ofServer: "worker-1")
        #expect(found == [CloudFirewall(id: used, servers: [], other: true), CloudFirewall(id: own, servers: [], other: true)])
    }

    // MARK: - The app's own SSH key

    @Test func theAppsOwnKeyIsFoundByItsFingerprintAndDeletedByItsId() async throws {
        let hetzner = ProviderStandIn()
        hetzner.answer("GET", "/v1/ssh_keys", 200, "{\"ssh_keys\":[{\"id\":9,\"name\":\"founderizer\",\"fingerprint\":\"\(Self.fingerprint)\"}]}")
        hetzner.answer("DELETE", "/v1/ssh_keys/9", 204, "")
        try await Self.servers(.hetzner, hetzner).deleteKey(publicKey: Self.publicKey)
        #expect(hetzner.call("GET", "/v1/ssh_keys")?.query.contains("fingerprint=") == true)
        #expect(Self.deletes(hetzner) == ["/v1/ssh_keys/9"])
        // A key of another fingerprint in the answer is not the app's: nothing is deleted.
        let other = ProviderStandIn()
        other.answer("GET", "/v1/ssh_keys", 200, "{\"ssh_keys\":[{\"id\":5,\"name\":\"laptop\",\"fingerprint\":\"aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99\"}]}")
        try await Self.servers(.hetzner, other).deleteKey(publicKey: Self.publicKey)
        #expect(Self.deletes(other).isEmpty)

        let ocean = ProviderStandIn()
        ocean.answer("GET", "/v2/account/keys/\(Self.fingerprint)", 200, "{\"ssh_key\":{\"id\":512190,\"fingerprint\":\"\(Self.fingerprint)\"}}")
        ocean.answer("DELETE", "/v2/account/keys/512190", 204, "")
        try await Self.servers(.digitalOcean, ocean).deleteKey(publicKey: Self.publicKey)
        #expect(Self.deletes(ocean) == ["/v2/account/keys/512190"])
        // No such key at the provider: it is gone already.
        let none = ProviderStandIn()
        try await Self.servers(.digitalOcean, none).deleteKey(publicKey: Self.publicKey)
        #expect(Self.deletes(none).isEmpty)

        let vultr = ProviderStandIn()
        vultr.answer("GET", "/v2/ssh-keys", 200, """
        {"ssh_keys":[{"id":"3b8066a7-b438-455a-9688-44afc9a3597f","name":"laptop","ssh_key":"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherKeyOtherKeyOtherKeyOtherKeyOtherKeyOther laptop"},
                     {"id":"cb676a46-66fd-4dfb-b839-443f2e6c0b60","name":"founderizer","ssh_key":"\(Self.publicKey)"}]}
        """)
        vultr.answer("DELETE", "/v2/ssh-keys/cb676a46-66fd-4dfb-b839-443f2e6c0b60", 204, "")
        try await Self.servers(.vultr, vultr).deleteKey(publicKey: Self.publicKey)
        #expect(Self.deletes(vultr) == ["/v2/ssh-keys/cb676a46-66fd-4dfb-b839-443f2e6c0b60"])
        // Akamai keeps no key of its own: nothing is asked.
        let akamai = ProviderStandIn()
        try await Self.servers(.akamai, akamai).deleteKey(publicKey: Self.publicKey)
        #expect(akamai.calls.isEmpty)
        // What is no public key deletes nothing.
        await #expect(throws: CloudError.notAPublicKey) { try await Self.servers(.hetzner, hetzner).deleteKey(publicKey: "not a key") }
    }

    // MARK: - The private network's devices

    private static let held = FleetClient(id: "kFLEET1234CNTRL", secret: "tskey-client-kFLEET1234CNTRL-notarealsecret")!
    private static let devices = "/api/v2/tailnet/-/devices"

    private static func tailscale() -> ProviderStandIn {
        let tailscale = ProviderStandIn()
        tailscale.answer("POST", "/api/v2/oauth/token", 200, "{\"access_token\":\"tskey-api-kMINTED1CNTRL-short-lived\",\"token_type\":\"Bearer\","
                         + "\"expires_in\":3600,\"scope\":\"auth_keys devices:core\"}")
        return tailscale
    }

    private static func key(_ tailscale: ProviderStandIn, shelf: MemoryShelf? = nil) -> TailscaleFleetKey {
        TailscaleFleetKey(exchange: tailscale.exchange, shelf: shelf ?? MemoryShelf(held.stored))
    }

    @Test func theDevicesOfTheTailnetComeWithWhatTheRuleNeeds() async throws {
        let tailscale = Self.tailscale()
        tailscale.answer("GET", Self.devices, 200, """
        {"devices":[
          {"id":"12345","nodeId":"nWORKER1CNTRL","name":"Worker-1.example.ts.net.","hostname":"worker-1","authorized":true,
           "created":"2026-11-13T21:00:30Z","addresses":["100.64.0.9","fd7a:115c:a1e0::9"],"tags":["tag:founderizer"],
           "connectedToControl":true},
          {"id":"12346","name":"laptop.example.ts.net","hostname":"laptop","authorized":false,"created":"","addresses":["100.64.0.2"],
           "isExternal":true},
          {"name":"no-id.example.ts.net","hostname":"no-id"}
        ]}
        """)
        let found = try await Self.key(tailscale).devices()
        #expect(found.map(\.id) == ["nWORKER1CNTRL", "12346"])
        #expect(found[0] == FleetDevice(id: "nWORKER1CNTRL", hostname: "worker-1", name: "worker-1.example.ts.net",
                                        addresses: ["100.64.0.9", "fd7a:115c:a1e0::9"], tags: ["tag:founderizer"],
                                        created: ISO8601DateFormatter().date(from: "2026-11-13T21:00:30Z"), authorized: true, external: false,
                                        connected: true))
        #expect(found[1].authorized == false && found[1].external && found[1].created == nil && found[1].tags.isEmpty)
        #expect(!found[1].connected)
        // The list is read with a token of the fleet key, never with the key itself.
        #expect(tailscale.call("GET", Self.devices)?.headers["Authorization"] == "Bearer tskey-api-kMINTED1CNTRL-short-lived")
        // No fleet key, an ended key, and an answer that is no list each say so.
        await #expect(throws: FleetKeyError.noFleetKey) { _ = try await Self.key(ProviderStandIn(), shelf: MemoryShelf()).devices() }
        let ended = Self.tailscale()
        ended.answer("GET", Self.devices, 401, "{\"message\":\"invalid\"}")
        await #expect(throws: FleetKeyError.fleetKeyEnded) { _ = try await Self.key(ended).devices() }
        let odd = Self.tailscale()
        odd.answer("GET", Self.devices, 200, "[]")
        await #expect(throws: FleetKeyError.notUnderstood) { _ = try await Self.key(odd).devices() }
    }

    @Test func aDeviceIsRemovedByItsIdAndOneThatIsGoneIsRemoved() async throws {
        let tailscale = Self.tailscale()
        tailscale.answer("DELETE", "/api/v2/device/nWORKER1CNTRL", 200, "")
        try await Self.key(tailscale).deleteDevice(id: "nWORKER1CNTRL")
        let call = try #require(tailscale.call("DELETE", "/api/v2/device/nWORKER1CNTRL"))
        #expect(call.headers["Authorization"] == "Bearer tskey-api-kMINTED1CNTRL-short-lived")
        // A device that Tailscale no longer has (the stand-in's 404) is removed already.
        try await Self.key(tailscale).deleteDevice(id: "nGONE1CNTRL")
        // Nothing that is no id reaches a path: not a name, not an address.
        for id in ["", "worker-1", "100.64.0.9", "nWORKER1CNTRL/routes", "../tailnet/-/devices"] {
            await #expect(throws: FleetKeyError.notUnderstood) { try await Self.key(tailscale).deleteDevice(id: id) }
        }
        #expect(tailscale.calls.filter { $0.method == "DELETE" }.map(\.path) == ["/api/v2/device/nWORKER1CNTRL", "/api/v2/device/nGONE1CNTRL"])
        // Tailscale's refusal in its own words, and a Mac with no fleet key.
        let refused = Self.tailscale()
        refused.answer("DELETE", "/api/v2/device/nWORKER1CNTRL", 501, "{\"message\":\"device not owned by tailnet\"}")
        await #expect(throws: FleetKeyError.self) { try await Self.key(refused).deleteDevice(id: "nWORKER1CNTRL") }
        await #expect(throws: FleetKeyError.noFleetKey) {
            try await Self.key(ProviderStandIn(), shelf: MemoryShelf()).deleteDevice(id: "nWORKER1CNTRL")
        }
    }
}
#endif
