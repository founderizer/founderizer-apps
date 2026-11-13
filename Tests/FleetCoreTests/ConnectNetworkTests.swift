import Foundation
import Testing
@testable import FleetCore

/// What the owner's access token does in his Tailscale network before connected apps turn on
/// (`TailscaleFleetKey.connectNetwork`): the two policy lines, the tag on the hub's device, MagicDNS and HTTPS
/// certificates. Every request is proved against a stand-in for Tailscale. The shapes of the answers, and the policy
/// file of `plain`, are those of a real network (the real Funnel test of 13 November 2026), with example names.
struct ConnectNetworkTests {
    private static let token = "tskey-api-kTEST1234CNTRL-notarealsecretvalue0000"
    private static let settings = "/api/v2/tailnet/-/settings"
    private static let acl = "/api/v2/tailnet/-/acl"
    private static let validate = "/api/v2/tailnet/-/acl/validate"
    private static let devices = "/api/v2/tailnet/-/devices"
    private static let dns = "/api/v2/tailnet/-/dns/preferences"
    private static let tags = "/api/v2/device/nHUB1234CNTRL/tags"

    /// A policy file as Tailscale gives a new network, with the fleet's own tag line in it.
    private static let plain = """
    // Example/default ACLs for unrestricted connections.
    {
    \t"tagOwners": {
    \t\t"tag:founderizer": ["autogroup:admin"],
    \t},
    \t// Define grants that govern access for users, groups, autogroups, tags,
    \t"grants": [
    \t\t// Allow all connections.
    \t\t{"src": ["*"], "dst": ["*"], "ip": ["*"]},
    \t],
    }
    """
    private static let tagInsert = "\n\t\t\"tag:founderizer-hub\": [\"autogroup:admin\"],"
    private static let attributeLine = "{\"target\": [\"tag:founderizer-hub\"], \"attr\": [\"funnel\"]}"

    private static func device(_ id: String, _ name: String, _ address: String, tags: [String]?) -> String {
        let tagged = tags.map { ",\"tags\":[" + $0.map { "\"\($0)\"" }.joined(separator: ",") + "]" } ?? ""
        return "{\"nodeId\":\"\(id)\",\"name\":\"\(name).tail1234.ts.net\",\"hostname\":\"\(name)\","
            + "\"addresses\":[\"\(address)\",\"fd7a:115c:a1e0::1\"]\(tagged)}"
    }

    /// A tailnet with a hub (`hub-1`, 100.64.0.2) and one more machine, and this policy file.
    private static func tailnet(policy: String = plain, managed: Bool = false, hubTags: [String]? = ["tag:founderizer"],
                                https: String = "false", magicDNS: String = "true") -> ProviderStandIn {
        let tailscale = ProviderStandIn()
        tailscale.answer("GET", settings, 200, "{\"aclsExternallyManagedOn\":\(managed),\"httpsEnabled\":\(https)}")
        tailscale.answer("PATCH", settings, 200, "{}")
        tailscale.answer("GET", acl, 200, policy, headers: ["ETag": "\"v1\""])
        tailscale.answer("POST", validate, 200, "{}")
        tailscale.answer("POST", acl, 200, "{}")
        tailscale.answer("GET", devices, 200, "{\"devices\":[" + device("nHUB1234CNTRL", "hub-1", "100.64.0.2", tags: hubTags)
            + "," + device("nAPP1234CNTRL", "app-1", "100.64.0.3", tags: ["tag:founderizer"]) + "]}")
        tailscale.answer("POST", tags, 200, "{}")
        tailscale.answer("GET", dns, 200, "{\"magicDNS\":\(magicDNS)}")
        tailscale.answer("POST", dns, 200, "{\"magicDNS\":true}")
        return tailscale
    }

    private static func connect(_ tailscale: ProviderStandIn, hub: String = "100.64.0.2") async throws -> ConnectNetworkAnswer {
        try await TailscaleFleetKey(exchange: tailscale.exchange, shelf: MemoryShelf())
            .connectNetwork(accessToken: token, hub: hub)
    }

    // MARK: - The whole step

    @Test func aNewNetworkGetsTheTwoLinesTheTagAndHTTPS() async throws {
        let tailscale = Self.tailnet()
        #expect(try await Self.connect(tailscale) == .done)
        // The policy: checked by Tailscale first, then set against the version that was read, with every byte kept.
        let written = try #require(tailscale.call("POST", Self.acl)).body
        #expect(tailscale.call("POST", Self.validate)?.body == written)
        #expect(tailscale.call("POST", Self.acl)?.headers["If-Match"] == "\"v1\"")
        #expect(tailscale.call("POST", Self.acl)?.headers["Content-Type"] == "application/hujson")
        #expect(written.contains("// Example/default ACLs for unrestricted connections."))
        #expect(written.contains("\t\"tagOwners\": {" + Self.tagInsert + "\n\t\t\"tag:founderizer\": [\"autogroup:admin\"],"))
        #expect(written.contains("{\n\t\"nodeAttrs\": [\n\t\t" + Self.attributeLine + ",\n\t],"))
        var without = written
        for added in [Self.tagInsert, "\n\t\"nodeAttrs\": [\n\t\t" + Self.attributeLine + ",\n\t],"] {
            let range = try #require(without.range(of: added))
            without.removeSubrange(range)
        }
        #expect(without == Self.plain)
        // The tag goes on the hub's device beside the tag that it has, and on no other device.
        #expect(tailscale.call("POST", Self.tags)?.object?["tags"] as? [String] == ["tag:founderizer", "tag:founderizer-hub"])
        #expect(tailscale.calls.filter { $0.method == "POST" && $0.path.hasSuffix("/tags") }.count == 1)
        // HTTPS was off and is turned on; MagicDNS was on and is not written.
        #expect(tailscale.call("PATCH", Self.settings)?.object?["httpsEnabled"] as? Bool == true)
        #expect(tailscale.calls("POST", Self.dns).isEmpty)
        // The token goes only to Tailscale's API, in the header.
        for call in tailscale.calls {
            #expect(call.url.host == "api.tailscale.com")
            #expect(call.headers["Authorization"] == "Bearer " + Self.token)
            #expect(!call.url.absoluteString.contains("tskey") && !call.body.contains("tskey"))
        }
    }

    @Test func aNetworkThatIsReadyIsNotWrittenTo() async throws {
        let ready = try #require(FunnelPolicy.writing(.everything, into: Self.plain))
        let tailscale = Self.tailnet(policy: ready, hubTags: ["tag:founderizer", "tag:founderizer-hub"], https: "true")
        #expect(try await Self.connect(tailscale) == .done)
        #expect(tailscale.calls.allSatisfy { $0.method == "GET" })
    }

    @Test func magicDNSThatIsOffIsTurnedOnAndAnAnswerWithoutTheFieldsChangesNothing() async throws {
        let off = Self.tailnet(magicDNS: "false")
        #expect(try await Self.connect(off) == .done)
        #expect(off.call("POST", Self.dns)?.object?["magicDNS"] as? Bool == true)
        let silent = Self.tailnet()
        silent.clear("GET", Self.settings)
        silent.answer("GET", Self.settings, 200, "{\"aclsExternallyManagedOn\":false}")
        silent.clear("GET", Self.dns)
        silent.answer("GET", Self.dns, 200, "{}")
        #expect(try await Self.connect(silent) == .done)
        #expect(silent.calls("PATCH", Self.settings).isEmpty && silent.calls("POST", Self.dns).isEmpty)
    }

    @Test func aFileAnotherToolKeepsIsNeverWrittenAndNothingElseChangesBeforeItsLines() async throws {
        let tailscale = Self.tailnet(managed: true)
        let lines = "\"tagOwners\": {\n\t\"tag:founderizer-hub\": [\"autogroup:admin\"],\n},\n"
            + "\"nodeAttrs\": [\n\t" + Self.attributeLine + ",\n],"
        #expect(try await Self.connect(tailscale) == .addLines(lines))
        #expect(tailscale.calls.allSatisfy { $0.method == "GET" })
        // He added the lines there: the next paste goes on, and writes no policy.
        let added = Self.tailnet(policy: try #require(FunnelPolicy.writing(.everything, into: Self.plain)), managed: true)
        #expect(try await Self.connect(added) == .done)
        #expect(added.calls("POST", Self.acl).isEmpty)
        #expect(added.calls("POST", Self.tags).count == 1)
    }

    // MARK: - The hub's device

    @Test func theHubIsFoundByItsAddressOrItsFullName() async throws {
        for hub in ["100.64.0.2", "hub-1.tail1234.ts.net", "HUB-1.tail1234.ts.net."] {
            let tailscale = Self.tailnet()
            #expect(try await Self.connect(tailscale, hub: hub) == .done, "\(hub)")
            #expect(tailscale.calls("POST", Self.tags).count == 1, "\(hub)")
        }
    }

    @Test func aTokenOfAnotherNetworkChangesNothing() async throws {
        // A short name is no proof: another network can have a machine with the same first label.
        for hub in ["100.64.0.9", "other-1", "", "tail1234.ts.net", "hub-1"] {
            let tailscale = Self.tailnet()
            await #expect(throws: ConnectNetworkError.hubNotFound) { try await Self.connect(tailscale, hub: hub) }
            #expect(tailscale.calls.allSatisfy { $0.method == "GET" }, "\(hub)")
        }
        // Two devices with the hub's address: this app does not choose one.
        let two = Self.tailnet()
        two.clear("GET", Self.devices)
        two.answer("GET", Self.devices, 200, "{\"devices\":[" + Self.device("nHUB1234CNTRL", "hub-1", "100.64.0.2", tags: ["tag:a"])
            + "," + Self.device("nOLD1234CNTRL", "old-1", "100.64.0.2", tags: ["tag:a"]) + "]}")
        await #expect(throws: ConnectNetworkError.hubNotFound) { try await Self.connect(two) }
        // A device that another network shares in is not this network's, whatever its address is.
        let shared = Self.tailnet()
        shared.clear("GET", Self.devices)
        shared.answer("GET", Self.devices, 200, "{\"devices\":[{\"nodeId\":\"nEXT1234CNTRL\",\"name\":"
            + "\"hub-1.tail0.ts.net\",\"addresses\":[\"100.64.0.2\"],\"tags\":[\"tag:a\"],\"isExternal\":true}]}")
        await #expect(throws: ConnectNetworkError.hubNotFound) { try await Self.connect(shared) }
        #expect(shared.calls.allSatisfy { $0.method == "GET" })
    }

    /// The tag list is the device's tags at the moment of the write, so a tag that it got after the first read stays.
    @Test func aTagThatTheDeviceGotMeanwhileIsNotDropped() async throws {
        let tailscale = Self.tailnet()
        tailscale.clear("GET", Self.devices)
        tailscale.answer("GET", Self.devices, 200, "{\"devices\":[" + Self.device("nHUB1234CNTRL", "hub-1", "100.64.0.2",
                                                                              tags: ["tag:founderizer"]) + "]}")
        tailscale.answer("GET", Self.devices, 200, "{\"devices\":[" + Self.device("nHUB1234CNTRL", "hub-1", "100.64.0.2",
                                                                              tags: ["tag:founderizer", "tag:door"]) + "]}")
        #expect(try await Self.connect(tailscale) == .done)
        #expect(tailscale.call("POST", Self.tags)?.object?["tags"] as? [String]
                == ["tag:founderizer", "tag:door", "tag:founderizer-hub"])
        // Another device at the hub's address at the second read: no tag is written.
        let moved = Self.tailnet()
        moved.clear("GET", Self.devices)
        moved.answer("GET", Self.devices, 200, "{\"devices\":[" + Self.device("nHUB1234CNTRL", "hub-1", "100.64.0.2",
                                                                          tags: ["tag:founderizer"]) + "]}")
        moved.answer("GET", Self.devices, 200, "{\"devices\":[" + Self.device("nNEW1234CNTRL", "hub-1", "100.64.0.2",
                                                                          tags: ["tag:founderizer"]) + "]}")
        await #expect(throws: ConnectNetworkError.hubNotFound) { try await Self.connect(moved) }
        #expect(moved.calls.filter { $0.method == "POST" && $0.path.hasSuffix("/tags") }.isEmpty)
    }

    @Test func aHubWithNoTagIsLeftAsItIs() async throws {
        let tailscale = Self.tailnet(hubTags: nil)
        await #expect(throws: ConnectNetworkError.hubNotTagged) { try await Self.connect(tailscale) }
        #expect(tailscale.calls.allSatisfy { $0.method == "GET" })
        #expect(ConnectNetworkError.hubNotTagged.errorDescription
                == "Your hub's server has no tag in Tailscale, so Founderizer cannot let it publish an address.")
        #expect(ConnectNetworkError.hubNotFound.errorDescription
                == "Founderizer did not find your hub's server in this access token's Tailscale network.")
    }

    @Test func aRefusalOfTailscaleIsSaidAsTheNetworkSetupSaysIt() async throws {
        let ended = Self.tailnet()
        ended.clear("GET", Self.settings)
        ended.answer("GET", Self.settings, 401, "{\"message\":\"API token invalid\"}")
        await #expect(throws: FleetKeyError.tokenNotAccepted) { try await Self.connect(ended) }
        let member = Self.tailnet()
        member.clear("POST", Self.tags)
        member.answer("POST", Self.tags, 403, "{\"message\":\"forbidden\"}")
        await #expect(throws: FleetKeyError.roleCannotWrite) { try await Self.connect(member) }
        await #expect(throws: FleetKeyError.notAnAccessToken) {
            try await TailscaleFleetKey(exchange: Self.tailnet().exchange, shelf: MemoryShelf())
                .connectNetwork(accessToken: "tskey-auth-kAbc1234CNTRL-xyz", hub: "100.64.0.2")
        }
    }

    // MARK: - The two lines

    @Test func whatAFileMissesIsReadAsTailscaleReadsIt() throws {
        func needs(_ text: String) -> FunnelPolicy.Needs? { FunnelPolicy.needs(in: text) }
        #expect(needs(Self.plain) == .everything)
        #expect(needs("{}") == .everything)
        #expect(needs("{\"TagOwners\": {\"TAG:Founderizer-Hub\": []}}") == FunnelPolicy.Needs(tag: false, attribute: true))
        // The attribute for the tag, or for every machine; not for the members, because a machine with a tag is none.
        #expect(needs("{\"nodeAttrs\": [{\"target\": [\"tag:founderizer-hub\"], \"attr\": [\"funnel\"]}]}")?.attribute == false)
        #expect(needs("{\"NodeAttrs\": [{\"Target\": [\"*\"], \"Attr\": [\"other\", \"Funnel\"]}]}")?.attribute == false)
        #expect(needs("{\"nodeAttrs\": [{\"target\": [\"autogroup:member\"], \"attr\": [\"funnel\"]}]}")?.attribute == true)
        #expect(needs("{\"nodeAttrs\": [{\"target\": [\"tag:founderizer-hub\"], \"attr\": [\"mullvad\"]}]}")?.attribute == true)
        #expect(needs("{\"nodeAttrs\": [{\"target\": [\"tag:founderizer\"], \"attr\": [\"funnel\"]}]}")?.attribute == true)
        #expect(needs("{ not a policy") == nil)
    }

    @Test func eachLineGoesIntoTheSectionThatTheFileHas() throws {
        let has = "{\n\t\"nodeAttrs\": [\n\t\t{\"target\": [\"autogroup:member\"], \"attr\": [\"funnel\"]},\n\t],\n}"
        let written = try #require(FunnelPolicy.writing(.everything, into: has))
        #expect(written == "{\n\t\"tagOwners\": {" + Self.tagInsert + "\n\t},\n\t\"nodeAttrs\": [\n\t\t" + Self.attributeLine
                + ",\n\t\t{\"target\": [\"autogroup:member\"], \"attr\": [\"funnel\"]},\n\t],\n}")
        #expect(FunnelPolicy.needs(in: written)?.isEmpty == true)
        #expect(FunnelPolicy.writing(FunnelPolicy.Needs(tag: false, attribute: false), into: has) == nil)
        // A section of another shape than Tailscale's is not guessed at.
        #expect(FunnelPolicy.writing(.everything, into: "{\"nodeAttrs\": {}}") == nil)
        #expect(FunnelPolicy.writing(.everything, into: "{\"tagOwners\": []}") == nil)
        #expect(FunnelPolicy.lines(for: FunnelPolicy.Needs(tag: false, attribute: false)) == nil)
        #expect(FunnelPolicy.lines(for: FunnelPolicy.Needs(tag: false, attribute: true))
                == "\"nodeAttrs\": [\n\t" + Self.attributeLine + ",\n],")
    }

    @Test func aChangeMadeMeanwhileIsReadAgainOnce() async throws {
        let tailscale = Self.tailnet()
        tailscale.clear("POST", Self.acl)
        tailscale.answer("POST", Self.acl, 412, "{}")
        await #expect(throws: FleetKeyError.policyChangedMeanwhile) { try await Self.connect(tailscale) }
        #expect(tailscale.calls("POST", Self.acl).count == 2)
        #expect(tailscale.calls("POST", Self.tags).isEmpty)
    }
}
