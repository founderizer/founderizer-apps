import Foundation
import Testing
@testable import FleetCore

/// The fleet's own key to the owner's private network: the one access token he pastes, the lines this app adds to a
/// policy file that it may write, the one line it asks of a file that it may not, the fleet key it makes and keeps, the
/// key it mints for each machine, and the words for a connection that the policy does not let through. Every request is proved against
/// a stand-in for Tailscale, so none of this needs a network, an account or a real token.
struct TailscaleFleetKeyTests {
    private static let token = "tskey-api-kTEST1234CNTRL-notarealsecretvalue0000"
    private static let clientAnswer = "{\"id\":\"kFLEET1234CNTRL\",\"key\":\"tskey-client-kFLEET1234CNTRL-notarealsecret\","
        + "\"keyType\":\"client\",\"scopes\":[\"auth_keys\",\"devices:core\"],\"tags\":[\"tag:founderizer\"]}"
    private static let settings = "/api/v2/tailnet/-/settings"
    private static let acl = "/api/v2/tailnet/-/acl"
    private static let validate = "/api/v2/tailnet/-/acl/validate"
    private static let keys = "/api/v2/tailnet/-/keys"
    private static let oauth = "/api/v2/oauth/token"

    /// The one tag line, and the two grant lines, as this app writes them into a file.
    private static let tagInsert = "\n\t\t\"tag:founderizer\": [\"autogroup:admin\"],"
    private static let grantLines = "\n\t\t{\"src\": [\"autogroup:owner\", \"autogroup:admin\"], \"dst\": [\"tag:founderizer\"], "
        + "\"ip\": [\"tcp:22\", \"tcp:8765\", \"tcp:9418\"]},\n\t\t{\"src\": [\"tag:founderizer\"], \"dst\": [\"tag:founderizer\"], "
        + "\"ip\": [\"tcp:8765\", \"tcp:9418\"]},"
    /// The one line that the owner adds himself to a file that this app does not write.
    private static let tagLine = "\"tag:founderizer\": [\"autogroup:admin\"],"
    private static let everything = FleetPolicy.Needs(tag: true, grants: FleetPolicy.grants)

    /// A tailnet that answers everything, with this policy file in it.
    private static func tailnet(policy: String, etag: String = "\"v1\"", managed: Bool = false,
                                link: String? = nil) -> ProviderStandIn {
        let tailscale = ProviderStandIn()
        let place = link.map { ",\"aclsExternalLink\":\"\($0)\"" } ?? ""
        tailscale.answer("GET", settings, 200, "{\"aclsExternallyManagedOn\":\(managed)\(place),\"devicesApprovalOn\":false}")
        tailscale.answer("GET", acl, 200, policy, headers: ["ETag": etag])
        tailscale.answer("POST", validate, 200, "{}")
        tailscale.answer("POST", acl, 200, "{}")
        tailscale.answer("POST", keys, 200, clientAnswer)
        return tailscale
    }

    private static func connect(_ tailscale: ProviderStandIn, shelf: MemoryShelf = MemoryShelf()) async throws -> FleetKeySetup {
        try await TailscaleFleetKey(exchange: tailscale.exchange, shelf: shelf).connect(accessToken: token)
    }

    // MARK: - The token

    @Test func onlyAnAccessTokenReachesTailscale() async throws {
        // An auth key and a client secret are the likely mistakes: the Keys page makes all three.
        for pasted in ["", "tskey-auth-kAbc1234CNTRL-xyz", "tskey-client-kAbc1234CNTRL-xyz", "tskey-api-has space",
                       "not a token", "tskey-api-" + String(repeating: "a", count: 300)] {
            let tailscale = ProviderStandIn()
            await #expect(throws: FleetKeyError.notAnAccessToken) {
                try await TailscaleFleetKey(exchange: tailscale.exchange, shelf: MemoryShelf()).connect(accessToken: pasted)
            }
            #expect(tailscale.calls.isEmpty)
        }
        #expect(try TailscaleFleetKey.checkedToken("  \(Self.token)\n") == Self.token)
        #expect(TailscaleFleetKey.keysPage.absoluteString == "https://login.tailscale.com/admin/settings/keys")
    }

    // MARK: - The policy file

    private static let allowAll = """
    // The owner's own rules. This comment must still be here afterwards.
    {
    \t"tagOwners": {
    \t\t"tag:server": ["me@example.com"],
    \t},
    \t"acls": [
    \t\t{"action": "accept", "src": ["*"], "dst": ["*:*"]},
    \t],
    }
    """

    @Test func theTagIsAddedAndEveryByteOfTheFileStays() async throws {
        let tailscale = Self.tailnet(policy: Self.allowAll)
        let shelf = MemoryShelf()
        let setup = try await Self.connect(tailscale, shelf: shelf)
        #expect(setup == FleetKeySetup(keyMade: true, wrotePolicy: true, linesToAdd: nil, place: .tailscale))
        #expect(tailscale.calls.map { "\($0.method) \($0.path)" } == ["GET \(Self.settings)", "GET \(Self.acl)",
                                                                       "POST \(Self.validate)", "POST \(Self.acl)", "POST \(Self.keys)"])
        let posted = try #require(tailscale.call("POST", Self.acl))
        // One line, inserted where it belongs: take it out again and the owner's own file is back, byte for byte. A file
        // that lets everything reach everything needs no grant.
        #expect(posted.body.replacingOccurrences(of: Self.tagInsert, with: "") == Self.allowAll)
        #expect(posted.body.contains("\"tagOwners\": {" + Self.tagInsert))
        #expect(!posted.body.contains("grants"))
        // Checked by Tailscale first, and set against the version that was read.
        #expect(tailscale.call("POST", Self.validate)?.body == posted.body)
        #expect(tailscale.call("POST", Self.validate)?.headers["Content-Type"] == "application/hujson")
        #expect(posted.headers["Content-Type"] == "application/hujson")
        #expect(posted.headers["If-Match"] == "\"v1\"")
        #expect(tailscale.call("GET", Self.acl)?.headers["Accept"] == "application/hujson")
        // The fleet key: an OAuth client of the tailnet, which may make keys for its one tag.
        let made = try #require(tailscale.call("POST", Self.keys)?.object)
        #expect(made["keyType"] as? String == "client")
        #expect(made["description"] as? String == "Founderizer fleet")
        #expect(made["scopes"] as? [String] == ["auth_keys", "devices:core"])
        #expect(made["tags"] as? [String] == ["tag:founderizer"])
        #expect(made["capabilities"] == nil && made["expirySeconds"] == nil)
        // Its id and secret are kept, and the token the owner pasted is not: not on the shelf, and in no address.
        #expect(shelf.held.map { String(decoding: $0, as: UTF8.self) } == "kFLEET1234CNTRL\ntskey-client-kFLEET1234CNTRL-notarealsecret")
        #expect(TailscaleFleetKey(exchange: tailscale.exchange, shelf: shelf).isHeld)
        for call in tailscale.calls {
            #expect(call.headers["Authorization"] == "Bearer \(Self.token)")
            #expect(call.url.host == "api.tailscale.com" && call.url.scheme == "https")
            #expect(!call.url.absoluteString.contains("notarealsecret"))
        }
    }

    private static let restrictive = """
    {
    \t// Only my laptop reaches my servers.
    \t"acls": [
    \t\t{"action": "accept", "src": ["me@example.com"], "dst": ["tag:server:22"]},
    \t],
    \t"tagOwners": {"tag:server": ["me@example.com"]},
    }
    """

    @Test func aFileThatDoesNotAllowEverythingGetsTheGrantsToo() async throws {
        let tailscale = Self.tailnet(policy: Self.restrictive)
        let setup = try await Self.connect(tailscale)
        #expect(setup.wrotePolicy && setup.keyMade && setup.linesToAdd == nil)
        let posted = try #require(tailscale.call("POST", Self.acl)).body
        // A section the file lacks is added at the start of its object; the tag goes into the one it has.
        let grants = "\n\t\"grants\": [" + Self.grantLines + "\n\t],"
        #expect(posted.hasPrefix("{" + grants))
        #expect(posted.replacingOccurrences(of: grants, with: "").replacingOccurrences(of: Self.tagInsert, with: "")
            == Self.restrictive)
        #expect(FleetPolicy.needs(in: posted)?.isEmpty == true)
        #expect(posted.contains("Only my laptop reaches my servers."))
        // What the fleet uses, and no more: his devices reach its machines on SSH, on the hub's port and on the port
        // of the fleet's code (a Mac that stays on is one of his devices, and its join fetches the code), and its
        // machines reach the hub on its port and on the port of the code (join.sh stops without 9418). No machine
        // opens SSH to another one.
        #expect(FleetPolicy.grants.map(\.ip) == [["tcp:22", "tcp:8765", "tcp:9418"], ["tcp:8765", "tcp:9418"]])
        #expect(FleetPolicy.grants.map(\.src) == [["autogroup:owner", "autogroup:admin"], ["tag:founderizer"]])
        #expect(FleetPolicy.grants.allSatisfy { $0.dst == ["tag:founderizer"] })
    }

    @Test func theGrantsGoIntoTheGrantsTheFileHas() throws {
        let file = """
        {
        \t"grants": [
        \t\t// The owner's laptop reaches everything tagged server.
        \t\t{"src": ["me@example.com"], "dst": ["tag:server"], "ip": ["*"]},
        \t],
        }
        """
        let needs = try #require(FleetPolicy.needs(in: file))
        #expect(needs == Self.everything)
        let written = try #require(FleetPolicy.writing(needs, into: file))
        #expect(written.contains("\"grants\": [" + Self.grantLines + "\n\t\t// The owner's laptop"))
        #expect(written.hasPrefix("{\n\t\"tagOwners\": {" + Self.tagInsert + "\n\t},"))
        #expect(FleetPolicy.needs(in: written)?.isEmpty == true)
    }

    @Test func aFileWithNoRulesAllowsEverythingAndGetsNoGrant() throws {
        // Tailscale's own rule: a file with neither acls nor grants lets everything through. A grants section added to it
        // would end that for every device the owner has, so none is.
        for file in ["{}", "{\n\t\"tagOwners\": {},\n}", "{\"acls\": null}"] {
            let needs = try #require(FleetPolicy.needs(in: file))
            #expect(needs == FleetPolicy.Needs(tag: true, grants: []), "file \(file)")
            let written = try #require(FleetPolicy.writing(needs, into: file))
            #expect(!written.contains("grants"))
            #expect(FleetPolicy.parsed(written).map(FleetPolicy.needs)?.isEmpty == true)
        }
        // An empty acls is no rule at all, which lets nothing through: the fleet gets its grants.
        #expect(FleetPolicy.needs(in: "{\"acls\": []}")?.grants == FleetPolicy.grants)
    }

    @Test func whatLetsEverythingThroughIsReadAsTailscaleReadsIt() {
        func all(_ text: String) -> Bool { FleetPolicy.parsed(text).map { FleetPolicy.allowsAll(FleetPolicy.lowered($0)) } ?? false }
        #expect(all("{\"acls\": [{\"action\": \"accept\", \"src\": [\"*\"], \"dst\": [\"*:*\"]}]}"))
        // The older words for the same rule, and Tailscale's case-blind keys.
        #expect(all("{\"ACLs\": [{\"Action\": \"accept\", \"users\": [\"*\"], \"ports\": [\"*:*\"]}]}"))
        #expect(all("{\"grants\": [{\"src\": [\"*\"], \"dst\": [\"*\"], \"ip\": [\"*\"]}]}"))
        // A rule narrowed by protocol, posture or destination is not everything.
        #expect(!all("{\"acls\": [{\"action\": \"accept\", \"proto\": \"tcp\", \"src\": [\"*\"], \"dst\": [\"*:*\"]}]}"))
        #expect(!all("{\"grants\": [{\"src\": [\"*\"], \"dst\": [\"*\"], \"ip\": [\"*\"], \"srcPosture\": [\"posture:x\"]}]}"))
        #expect(!all("{\"acls\": [{\"action\": \"accept\", \"src\": [\"*\"], \"dst\": [\"tag:server:*\"]}]}"))
    }

    @Test func aGrantTheFileAlreadyHasIsNotAddedAgain() throws {
        // What this app wrote once, and an owner's own grant that gives as much, both cover the fleet's need.
        let mine = "{\"tagOwners\": {\"tag:founderizer\": []}, \"acls\": [], \"grants\": ["
            + "{\"src\": [\"autogroup:admin\", \"autogroup:owner\"], \"dst\": [\"tag:founderizer\"], \"ip\": [\"22\", \"tcp:8765\"]},"
            + "{\"src\": [\"*\"], \"dst\": [\"tag:founderizer\"], \"ip\": [\"tcp:*\"]}]}"
        #expect(try #require(FleetPolicy.needs(in: mine)).isEmpty)
        // The lines that this app wrote until 13 November 2026 gave no machine a way to the port of the fleet's
        // code: such a file gets both grants as they are now, and keeps its own.
        let before = "{\"tagOwners\": {\"tag:founderizer\": []}, \"acls\": [], \"grants\": ["
            + "{\"src\": [\"autogroup:owner\", \"autogroup:admin\"], \"dst\": [\"tag:founderizer\"], \"ip\": [\"tcp:22\", \"tcp:8765\"]},"
            + "{\"src\": [\"tag:founderizer\"], \"dst\": [\"tag:founderizer\"], \"ip\": [\"tcp:22\", \"tcp:8765\"]}]}"
        #expect(try #require(FleetPolicy.needs(in: before)) == FleetPolicy.Needs(tag: false, grants: FleetPolicy.grants))
        // One that gives less does not.
        let less = "{\"tagOwners\": {\"tag:founderizer\": []}, \"acls\": [], \"grants\": ["
            + "{\"src\": [\"autogroup:admin\"], \"dst\": [\"tag:founderizer\"], \"ip\": [\"tcp:22\"]}]}"
        #expect(try #require(FleetPolicy.needs(in: less)).grants == FleetPolicy.grants)
    }

    @Test func aNetworkThatIsReadyIsNotWrittenTo() async throws {
        let ready = "{\"tagOwners\": {\"tag:founderizer\": [\"autogroup:admin\"]}}"
        let tailscale = Self.tailnet(policy: ready)
        let setup = try await Self.connect(tailscale)
        #expect(setup == FleetKeySetup(keyMade: true, wrotePolicy: false, linesToAdd: nil, place: .tailscale))
        #expect(tailscale.calls("POST", Self.acl).isEmpty && tailscale.calls("POST", Self.validate).isEmpty)
        #expect(tailscale.calls("POST", Self.keys).count == 1)
    }

    @Test func aFileAnotherToolKeepsIsNeverWrittenAndIsAskedForTheTagAlone() async throws {
        let link = "https://github.com/example/tailnet-policy/"
        let tailscale = Self.tailnet(policy: Self.restrictive, managed: true, link: link)
        let setup = try await Self.connect(tailscale)
        // The owner gets the one line that a key cannot exist without, and where his file is kept; and no key yet, for
        // a tag nobody owns yet. No grant is asked of him: no reading of a file says what the fleet may reach.
        #expect(setup == FleetKeySetup(keyMade: false, wrotePolicy: false, linesToAdd: Self.tagLine,
                                       place: .tool(URL(string: link))))
        #expect(setup.asks == "Your Tailscale policy has no tag:founderizer. Add this line to tagOwners in "
            + "github.com/example/tailnet-policy, then paste a key again.")
        #expect(!tailscale.calls.contains { $0.method == "POST" })
        // Once he has added the tag there, the key is made and nothing is left for him, whatever the file's rules are.
        let tagged = "{\"tagOwners\": {\"tag:founderizer\": [\"autogroup:admin\"]}, \"acls\": []}"
        let later = Self.tailnet(policy: tagged, managed: true, link: link)
        let second = try await Self.connect(later)
        #expect(second == FleetKeySetup(keyMade: true, wrotePolicy: false, linesToAdd: nil, place: .tool(URL(string: link))))
        #expect(second.asks == nil)
        #expect(later.calls("POST", Self.acl).isEmpty && later.calls("POST", Self.validate).isEmpty)
        #expect(later.calls("POST", Self.keys).count == 1)
        // A link that is not a web page of its own is not passed on, and the words then name the tool.
        let odd = Self.tailnet(policy: Self.restrictive, managed: true, link: "javascript:alert(1)")
        let unnamed = try await Self.connect(odd)
        #expect(unnamed.place == .tool(nil) && unnamed.linesToAdd == Self.tagLine)
        #expect(unnamed.asks == "Your Tailscale policy has no tag:founderizer. Add this line to tagOwners in the file of "
            + "the tool that keeps your policy, then paste a key again.")
    }

    /// A policy of the kind that stopped the owner on 13 November 2026, with example values: another tool keeps it, the
    /// tag stands, and narrow rules give the fleet its reach (one device's address to the tag on SSH, the tag to the
    /// hub's host on its two ports), with tests that refuse the grants this app would write.
    private static let narrow = """
    {
    \t"hosts": {"fleet-hub": "100.64.0.10", "owner-mac": "100.64.0.2"},
    \t"grants": [
    \t\t// Lateral ports between the servers are left out on purpose.
    \t\t{"src": ["100.64.0.2"], "dst": ["tag:founderizer"], "ip": ["tcp:22", "icmp:*"]},
    \t\t{"src": ["owner-mac", "tag:founderizer"], "dst": ["fleet-hub"], "ip": ["tcp:8765", "tcp:9418"]},
    \t],
    \t"tagOwners": {
    \t\t"tag:founderizer": ["autogroup:admin"],
    \t},
    \t"tests": [
    \t\t{"src": "tag:founderizer", "proto": "tcp", "accept": ["fleet-hub:8765", "fleet-hub:9418"],
    \t\t "deny": ["fleet-hub:22", "tag:founderizer:22", "tag:founderizer:8765"]},
    \t\t{"src": "100.64.0.2", "proto": "tcp", "accept": ["tag:founderizer:22"], "deny": ["tag:founderizer:8765"]},
    \t],
    }
    """

    @Test func aPolicyThatWorksWithNarrowRulesIsAskedNothing() async throws {
        // Another tool keeps it: the key is made, and the file is neither written nor checked.
        let kept = Self.tailnet(policy: Self.narrow, managed: true)
        let setup = try await Self.connect(kept)
        #expect(setup == FleetKeySetup(keyMade: true, wrotePolicy: false, linesToAdd: nil, place: .tool(nil)))
        #expect(kept.calls.map { "\($0.method) \($0.path)" } == ["GET \(Self.settings)", "GET \(Self.acl)", "POST \(Self.keys)"])
        // Tailscale keeps it, and its own tests refuse the grants: the file stays as it is, and the key is made.
        let own = Self.tailnet(policy: Self.narrow)
        own.clear("POST", Self.validate)
        own.answer("POST", Self.validate, 200, "{\"message\":\"test(s) failed\",\"data\":[{\"user\":\"tag:founderizer\","
                   + "\"errors\":[\"address \\\"tag:founderizer:8765\\\": want: Drop, got: Accept\"]}]}")
        let second = try await Self.connect(own)
        #expect(second == FleetKeySetup(keyMade: true, wrotePolicy: false, linesToAdd: nil, place: .tailscale))
        #expect(own.calls("POST", Self.validate).count == 1 && own.calls("POST", Self.acl).isEmpty)
        #expect(own.calls("POST", Self.keys).count == 1)
        // The file that lets everything through, which is every new tailnet's: the tag is all it gets
        // (`theTagIsAddedAndEveryByteOfTheFileStays`), and with the tag in it, nothing.
        let open = Self.allowAll.replacingOccurrences(of: "\"tag:server\"", with: "\"tag:founderizer\"")
        let all = Self.tailnet(policy: open)
        let third = try await Self.connect(all)
        #expect(third == FleetKeySetup(keyMade: true, wrotePolicy: false, linesToAdd: nil, place: .tailscale))
        #expect(!all.calls.contains { $0.method == "POST" && $0.path != Self.keys })
    }

    @Test func aFileWhoseOwnTestsRefuseTheGrantsGetsTheTagAlone() async throws {
        let tailscale = Self.tailnet(policy: Self.restrictive)
        tailscale.clear("POST", Self.validate)
        tailscale.answer("POST", Self.validate, 200, "{\"message\":\"test(s) failed\",\"data\":[{\"user\":\"me@example.com\","
                         + "\"errors\":[\"address \\\"tag:founderizer:22\\\": want: Drop, got: Accept\"]}]}")
        tailscale.answer("POST", Self.validate, 200, "{}")
        let setup = try await Self.connect(tailscale)
        #expect(setup == FleetKeySetup(keyMade: true, wrotePolicy: true, linesToAdd: nil, place: .tailscale))
        // The first check had the grants, the second the tag alone, and the second is the file that was set.
        let checks = tailscale.calls("POST", Self.validate)
        #expect(checks.count == 2 && checks[0].body.contains("\"grants\"") && !checks[1].body.contains("\"grants\""))
        let posted = try #require(tailscale.call("POST", Self.acl)).body
        #expect(posted == checks[1].body)
        #expect(posted.replacingOccurrences(of: Self.tagInsert, with: "") == Self.restrictive)
        #expect(posted.contains("\"tagOwners\": {" + Self.tagInsert))
        // A check that Tailscale did not make at all is no word about the file: nothing is set, and no key is made.
        let down = Self.tailnet(policy: Self.restrictive)
        down.clear("POST", Self.validate)
        down.answer("POST", Self.validate, 500, "{\"message\":\"internal server error\"}")
        await #expect(throws: FleetKeyError.refused("internal server error")) { try await Self.connect(down) }
        #expect(down.calls("POST", Self.validate).count == 1)
        #expect(down.calls("POST", Self.acl).isEmpty && down.calls("POST", Self.keys).isEmpty)
    }

    @Test func aFileThisAppCannotReadIsLeftAloneAndTailscaleSaysWhetherTheTagStands() async throws {
        // A file that names `tagOwners` twice is one of them: which of the two a reader takes is not this app's to
        // guess, so it asks for no line that may stand in the other one.
        let twice = "{\"tagOwners\": {\"tag:server\": []}, \"acls\": [], \"TagOwners\": {\"tag:founderizer\": []}}"
        #expect(FleetPolicy.needs(in: twice) == nil)
        for file in ["// a file with no object in it at all", "{\"acls\": [", "{\"acls\": \"never ends}", "[]", twice] {
            // Tailscale makes the key: the tag stands, and nothing is asked. The file is neither checked nor set.
            let tailscale = Self.tailnet(policy: file)
            let setup = try await Self.connect(tailscale)
            #expect(setup == FleetKeySetup(keyMade: true, wrotePolicy: false, linesToAdd: nil, place: .tailscale))
            #expect(tailscale.calls.filter { $0.method == "POST" }.map(\.path) == [Self.keys])
            // Tailscale refuses the key: its own words say why, and this app guesses at no line for a file it
            // cannot read.
            let untagged = Self.tailnet(policy: file)
            untagged.clear("POST", Self.keys)
            untagged.answer("POST", Self.keys, 400, "{\"message\":\"requested tags [tag:founderizer] are invalid or not permitted\"}")
            await #expect(throws: FleetKeyError.refused("requested tags [tag:founderizer] are invalid or not permitted")) {
                try await Self.connect(untagged)
            }
            #expect(untagged.calls("POST", Self.acl).isEmpty && untagged.calls("POST", Self.validate).isEmpty)
        }
    }

    @Test func withTheTagInTheFileAWriteOfTheGrantsThatDoesNotGoThroughIsNoStop() async throws {
        // Tailscale keeps the file, the tag stands, and the file lets little through: the grants go in.
        let tagged = "{\"tagOwners\": {\"tag:founderizer\": [\"autogroup:admin\"]}, \"acls\": []}"
        let plain = Self.tailnet(policy: tagged)
        let setup = try await Self.connect(plain)
        #expect(setup == FleetKeySetup(keyMade: true, wrotePolicy: true, linesToAdd: nil, place: .tailscale))
        let posted = try #require(plain.call("POST", Self.acl)).body
        #expect(posted.contains("\"grants\": [" + Self.grantLines) && FleetPolicy.needs(in: posted)?.isEmpty == true)
        // The same for a file with narrow rules of its own and no tests: no reading of it says that they are enough,
        // so only a file whose own tests refuse the grants is left as it is (`aPolicyThatWorksWithNarrowRulesIsAskedNothing`).
        let untested = Self.narrow.components(separatedBy: "\t\"tests\": [")[0] + "}"
        #expect(FleetPolicy.needs(in: untested) == FleetPolicy.Needs(tag: false, grants: FleetPolicy.grants))
        #expect(try await Self.connect(Self.tailnet(policy: untested)).wrotePolicy)
        // Each way in which the write does not go through leaves the file as it is, and the key is made: a role that
        // may not write the file, a change somebody made meanwhile (no second try), a check that Tailscale did not
        // make, and a file with no version to set it against.
        for (path, status) in [(Self.acl, 403), (Self.acl, 412), (Self.validate, 500)] {
            let tailscale = Self.tailnet(policy: tagged)
            tailscale.clear("POST", path)
            tailscale.answer("POST", path, status, "{\"message\":\"no\"}")
            let made = try await Self.connect(tailscale)
            #expect(made == FleetKeySetup(keyMade: true, wrotePolicy: false, linesToAdd: nil, place: .tailscale), "\(path) \(status)")
            // A change meanwhile gets one more try from the file as it then is, and no third.
            #expect(tailscale.calls("POST", Self.acl).count == (path == Self.acl ? (status == 412 ? 2 : 1) : 0))
            #expect(tailscale.calls("GET", Self.acl).count == (status == 412 ? 2 : 1))
            #expect(tailscale.calls("POST", Self.keys).count == 1)
        }
        let unversioned = ProviderStandIn()
        unversioned.answer("GET", Self.settings, 200, "{\"aclsExternallyManagedOn\":false}")
        unversioned.answer("GET", Self.acl, 200, tagged)
        unversioned.answer("POST", Self.keys, 200, Self.clientAnswer)
        #expect(try await Self.connect(unversioned).keyMade)
        #expect(unversioned.calls.filter { $0.method == "POST" }.map(\.path) == [Self.keys])
        // With the tag missing, a file with no version cannot be set: the tag is the owner's line, and no key is made.
        let untagged = ProviderStandIn()
        untagged.answer("GET", Self.settings, 200, "{\"aclsExternallyManagedOn\":false}")
        untagged.answer("GET", Self.acl, 200, Self.restrictive)
        let asked = try await Self.connect(untagged)
        #expect(asked == FleetKeySetup(keyMade: false, wrotePolicy: false, linesToAdd: Self.tagLine, place: .tailscale))
        #expect(asked.asks == "Your Tailscale policy has no tag:founderizer. Add this line to tagOwners on the Access "
            + "controls page of Tailscale, then paste a key again.")
        #expect(!untagged.calls.contains { $0.method == "POST" })
    }

    @Test func aFileThatNeedsOnlyTheTagAndThatTailscaleRefusesSaysTailscalesWords() async throws {
        // The file lets everything through, so the tag is all it misses: a check that refuses that file is said, on
        // one line, and nothing is set and no key is made. No second file is tried, because there is none.
        let tailscale = Self.tailnet(policy: Self.allowAll)
        tailscale.clear("POST", Self.validate)
        tailscale.answer("POST", Self.validate, 200, "{\"message\":\"test(s) failed\\nagain\",\"data\":[{\"user\":\"x\","
                         + "\"errors\":[\"" + String(repeating: "e", count: 400) + "\"]}]}")
        var said = ""
        do { _ = try await Self.connect(tailscale) } catch FleetKeyError.refused(let words) { said = words }
        #expect(said.hasPrefix("test(s) failed again: eee") && said.count == 301 && said.hasSuffix("…"))
        #expect(tailscale.calls("POST", Self.validate).count == 1)
        #expect(tailscale.calls("POST", Self.acl).isEmpty && tailscale.calls("POST", Self.keys).isEmpty)
    }

    @Test func aFileThatStillMissesWhatWasAskedAfterTheWriteIsNotGivenBack() {
        // A file that names a section twice: a line in one of them may say nothing to the reader that takes the
        // other. Such a file is not written into, whatever the case of the two names.
        for twice in ["{\"tagOwners\": {\"tag:server\": []}, \"tagOwners\": {}}", "{\"TagOwners\": {}, \"acls\": [], \"tagowners\": {}}"] {
            #expect(FleetPolicy.writing(FleetPolicy.Needs(tag: true, grants: []), into: twice) == nil, "file \(twice)")
        }
        let grants = "{\"tagOwners\": {}, \"grants\": [], \"Grants\": []}"
        #expect(FleetPolicy.writing(FleetPolicy.Needs(tag: false, grants: FleetPolicy.grants), into: grants) == nil)
        #expect(FleetPolicy.writing(FleetPolicy.Needs(tag: true, grants: []), into: grants) != nil)
        #expect(FleetPolicy.scan(Array(grants.utf8))?.twice == ["grants"])
        // The tag alone goes into a file that still misses the grants: that is what was asked.
        let tagged = FleetPolicy.writing(FleetPolicy.Needs(tag: true, grants: []), into: Self.restrictive)
        #expect(tagged.flatMap(FleetPolicy.needs(in:)) == FleetPolicy.Needs(tag: false, grants: FleetPolicy.grants))
        // And the grants alone go into a file that still misses the tag.
        let granted = FleetPolicy.writing(FleetPolicy.Needs(tag: false, grants: FleetPolicy.grants), into: Self.restrictive)
        #expect(granted.flatMap(FleetPolicy.needs(in:)) == FleetPolicy.Needs(tag: true, grants: []))
    }

    @Test func aChangeMadeMeanwhileIsReadAgainOnce() async throws {
        let tailscale = Self.tailnet(policy: Self.restrictive)
        let meanwhile = Self.restrictive.replacingOccurrences(of: "\"tag:server\": [\"me@example.com\"]",
                                                              with: "\"tag:server\": [\"me@example.com\", \"you@example.com\"]")
        tailscale.answer("GET", Self.acl, 200, meanwhile, headers: ["ETag": "\"v2\""])
        tailscale.clear("POST", Self.acl)
        tailscale.answer("POST", Self.acl, 412, "{\"message\":\"precondition failed, invalid old hash\"}")
        tailscale.answer("POST", Self.acl, 200)
        let setup = try await Self.connect(tailscale)
        #expect(setup.wrotePolicy && setup.keyMade)
        let sets = tailscale.calls("POST", Self.acl)
        #expect(sets.map { $0.headers["If-Match"] } == ["\"v1\"", "\"v2\""])
        // The second time from the file as it then was, so the other change is kept.
        #expect(sets[1].body.contains("you@example.com"))
        #expect(tailscale.calls("POST", Self.validate).count == 2)
        // Twice is somebody else at work: this app stops and says so, and makes no key.
        let busy = Self.tailnet(policy: Self.restrictive)
        busy.clear("POST", Self.acl)
        busy.answer("POST", Self.acl, 412, "{\"message\":\"precondition failed, invalid old hash\"}")
        await #expect(throws: FleetKeyError.policyChangedMeanwhile) { try await Self.connect(busy) }
        #expect(busy.calls("POST", Self.acl).count == 2)
        #expect(busy.calls("POST", Self.keys).isEmpty)
    }

    @Test func aFileTailscaleWouldRefuseIsNotSet() async throws {
        let tailscale = Self.tailnet(policy: Self.restrictive)
        tailscale.clear("POST", Self.validate)
        tailscale.answer("POST", Self.validate, 200, "{\"message\":\"test(s) failed\",\"data\":[{\"user\":\"me@example.com\","
                         + "\"errors\":[\"address \\\"tag:founderizer:22\\\": want: Drop, got: Accept\"]}]}")
        // The file with the grants is refused, and so is the file with the tag alone: Tailscale's words, and no key.
        await #expect(throws: FleetKeyError.refused("test(s) failed: address \"tag:founderizer:22\": want: Drop, got: Accept")) {
            try await Self.connect(tailscale)
        }
        #expect(tailscale.calls("POST", Self.validate).count == 2)
        #expect(tailscale.calls("POST", Self.acl).isEmpty && tailscale.calls("POST", Self.keys).isEmpty)
        // Warnings alone are Tailscale taking the file, and saying something about it.
        let warned = Self.tailnet(policy: Self.restrictive)
        warned.clear("POST", Self.validate)
        warned.answer("POST", Self.validate, 200, "{\"message\":\"warning(s) found\",\"data\":[{\"user\":\"group:x\","
                      + "\"warnings\":[\"group is not syncing from SCIM\"]}]}")
        #expect(try await Self.connect(warned).wrotePolicy)
    }

    // MARK: - What the owner is told

    @Test func eachRefusalIsSaidInPlainWords() async throws {
        let cases: [(Int, String, FleetKeyError)] = [
            (401, "{\"message\":\"API token invalid\"}", .tokenNotAccepted),
            (403, "{\"message\":\"forbidden\"}", .roleCannotWrite),
            (429, "{\"message\":\"too many requests\"}", .rateLimited),
            (500, "{\"message\":\"internal server error\"}", .refused("internal server error")),
            (502, "", .refused("it answered 502 and said nothing.")),
        ]
        for (status, body, error) in cases {
            let tailscale = ProviderStandIn()
            tailscale.answer("GET", Self.settings, status, body)
            await #expect(throws: error) { try await Self.connect(tailscale) }
            #expect(tailscale.calls.count == 1)
        }
        // A role that may read the file and not write it is refused where it writes.
        let member = Self.tailnet(policy: Self.restrictive)
        member.clear("POST", Self.acl)
        member.answer("POST", Self.acl, 403, "{\"message\":\"forbidden\"}")
        await #expect(throws: FleetKeyError.roleCannotWrite) { try await Self.connect(member) }
        let away = ProviderStandIn()
        away.offline = true
        await #expect(throws: FleetKeyError.unreachable) { try await Self.connect(away) }
        // Tailscale's words never carry the token back to the screen.
        let echo = ProviderStandIn()
        echo.answer("GET", Self.settings, 400, "{\"message\":\"bad token \(Self.token)\"}")
        await #expect(throws: FleetKeyError.refused("bad token (not shown)")) { try await Self.connect(echo) }
        let all: [FleetKeyError] = [.notAnAccessToken, .tokenNotAccepted, .roleCannotWrite, .rateLimited, .unreachable,
                                    .refused("x"), .notUnderstood, .policyChangedMeanwhile, .noFleetKey, .fleetKeyEnded]
        for error in all {
            let words = try #require(error.errorDescription)
            #expect(!words.isEmpty && !words.contains("tskey-api-k"))
        }
    }

    // MARK: - The fleet key on this Mac

    @Test func aKeyTheKeychainWillNotKeepIsEndedAtOnce() async throws {
        let tailscale = Self.tailnet(policy: Self.allowAll)
        tailscale.answer("DELETE", Self.keys + "/kFLEET1234CNTRL", 200)
        let shelf = MemoryShelf()
        shelf.refuses = true
        await #expect(throws: FleetKeychainItem.Failure.self) { try await Self.connect(tailscale, shelf: shelf) }
        // A credential that never expires and that nobody holds would be one too many.
        #expect(tailscale.calls("DELETE", Self.keys + "/kFLEET1234CNTRL").count == 1)
        #expect(shelf.held == nil)
    }

    @Test func aNewFleetKeyEndsTheOneItReplaces() async throws {
        let tailscale = Self.tailnet(policy: Self.allowAll)
        let old = try #require(FleetClient(id: "kOLD1234CNTRL", secret: "tskey-client-kOLD1234CNTRL-notarealsecret"))
        let shelf = MemoryShelf(old.stored)
        _ = try await Self.connect(tailscale, shelf: shelf)
        #expect(shelf.held.flatMap(FleetClient.init(stored:))?.id == "kFLEET1234CNTRL")
        #expect(tailscale.calls.filter { $0.method == "DELETE" }.map(\.path) == [Self.keys + "/kOLD1234CNTRL"])
        // An answer that is not a fleet key is not kept, and the credential it names is ended.
        let odd = Self.tailnet(policy: Self.allowAll)
        odd.clear("POST", Self.keys)
        odd.answer("POST", Self.keys, 200, "{\"id\":\"kODD1234CNTRL\",\"key\":\"not a secret\"}")
        let empty = MemoryShelf()
        await #expect(throws: FleetKeyError.notUnderstood) { try await Self.connect(odd, shelf: empty) }
        #expect(empty.held == nil)
        #expect(odd.calls.filter { $0.method == "DELETE" }.map(\.path) == [Self.keys + "/kODD1234CNTRL"])
    }

    @Test func theFleetKeyNeverPrintsItsSecret() throws {
        let client = try #require(FleetClient(id: "kFLEET1234CNTRL", secret: "tskey-client-kFLEET1234CNTRL-notarealsecret"))
        for said in [String(describing: client), String(reflecting: client), "\(client)", "\(Mirror(reflecting: client).children.map(\.value))"] {
            #expect(!said.contains("notarealsecret"), "printed: \(said)")
        }
        #expect(FleetClient(stored: client.stored) == client)
        #expect(FleetClient(stored: Data("one line only".utf8)) == nil)
        #expect(FleetClient(id: "kFLEET1234CNTRL", secret: "tskey-auth-kFLEET1234CNTRL-x") == nil)
        #expect(FleetClient(id: "has space", secret: "tskey-client-x-y") == nil)
    }

    // MARK: - One key for one machine

    private static let held = FleetClient(id: "kFLEET1234CNTRL", secret: "tskey-client-kFLEET1234CNTRL-notarealsecret")!

    private static func minting() -> ProviderStandIn {
        let tailscale = ProviderStandIn()
        tailscale.answer("POST", oauth, 200, "{\"access_token\":\"tskey-api-kMINTED1CNTRL-short-lived\",\"token_type\":\"Bearer\","
                         + "\"expires_in\":3600,\"scope\":\"auth_keys devices:core\"}")
        tailscale.answer("POST", keys, 200, "{\"id\":\"kAUTH1234CNTRL\",\"key\":\"tskey-auth-kAUTH1234CNTRL-notarealkey\","
                         + "\"expires\":\"2026-11-04T12:15:00Z\"}")
        return tailscale
    }

    @Test func oneKeyForOneMachine() async throws {
        let tailscale = Self.minting()
        let key = try await TailscaleFleetKey(exchange: tailscale.exchange, shelf: MemoryShelf(Self.held.stored))
            .mintAuthKey(hostname: "hub-1")
        #expect(key == "tskey-auth-kAUTH1234CNTRL-notarealkey")
        // The fleet key goes to the token endpoint, in the body only, by the client-credentials grant.
        let grant = try #require(tailscale.call("POST", Self.oauth))
        #expect(grant.headers["Content-Type"] == "application/x-www-form-urlencoded")
        #expect(grant.body == "grant_type=client_credentials&client_id=kFLEET1234CNTRL"
            + "&client_secret=tskey-client-kFLEET1234CNTRL-notarealsecret")
        #expect(grant.headers["Authorization"] == nil)
        let minted = try #require(tailscale.call("POST", Self.keys))
        #expect(minted.headers["Authorization"] == "Bearer tskey-api-kMINTED1CNTRL-short-lived")
        #expect(!minted.body.contains("notarealsecret"))
        let body = try #require(minted.object)
        let create = try #require(((body["capabilities"] as? [String: Any])?["devices"] as? [String: Any])?["create"]
            as? [String: Any])
        // Used once, for one machine, approved already, and never ephemeral: ephemeral minutes are metered.
        #expect(create["reusable"] as? Bool == false)
        #expect(create["ephemeral"] as? Bool == false)
        #expect(create["preauthorized"] as? Bool == true)
        #expect(create["tags"] as? [String] == ["tag:founderizer"])
        #expect(body["expirySeconds"] as? Int == 900)
        #expect(body["description"] as? String == "Founderizer hub-1")
        #expect(tailscale.calls.allSatisfy { $0.url.host == "api.tailscale.com" && !$0.url.absoluteString.contains("secret") })
    }

    /// **A cloud server's join key lives as long as the app waits for its server, one hour**, where a bare Mac's lives
    /// two hours and every other key fifteen minutes (the owner's choice of 11 November 2026). It stands in the provider's metadata until the
    /// server's first boot uses it, which a boot that meets the server's first updates does after about ten minutes.
    @Test func aCloudServersJoinKeyLivesAsLongAsTheAppWaits() async throws {
        let tailscale = Self.minting()
        let key = try await CloudServers.joinKey(
            for: "worker-3", from: TailscaleFleetKey(exchange: tailscale.exchange, shelf: MemoryShelf(Self.held.stored)))
        #expect(key == "tskey-auth-kAUTH1234CNTRL-notarealkey")
        let body = try #require(tailscale.call("POST", Self.keys)?.object)
        #expect(body["expirySeconds"] as? Int == 3600 && CloudServers.joinKeyLife == 3600)
        #expect(body["description"] as? String == "Founderizer worker-3")
        let create = ((body["capabilities"] as? [String: Any])?["devices"] as? [String: Any])?["create"] as? [String: Any]
        #expect(create?["reusable"] as? Bool == false && create?["preauthorized"] as? Bool == true)
    }

    /// **A machine's key lives as long as its install asks, from the fleet key too**: two hours for a bare Mac
    /// (`PrivateNetwork.macKeyLifeSeconds`: its installer first installs what Tailscale needs, in minutes that nobody
    /// can name), and fifteen minutes for every other install. Until 11 November 2026 a key from the fleet key lived
    /// fifteen minutes whatever the install asked; only the credential of before gave a Mac its two hours. With neither
    /// the fleet key nor a credential there is no key, and the machine signs in by Tailscale's own link.
    @Test func aMachinesKeyLivesAsLongAsItsInstallAsks() async throws {
        let fleet = Self.minting()
        let fleetKey = TailscaleFleetKey(exchange: fleet.exchange, shelf: MemoryShelf(Self.held.stored))
        for (asked, life) in [(PrivateNetwork.macKeyLifeSeconds, 7200), (PrivateNetwork.keyLifeSeconds, 900)] {
            let key = try await PrivateNetwork.joinKey(for: "studio", life: asked, fleetKey: fleetKey, credential: nil)
            #expect(key == "tskey-auth-kAUTH1234CNTRL-notarealkey")
            #expect(fleet.call("POST", Self.keys)?.object?["expirySeconds"] as? Int == life)
        }
        // A fleet that has only the credential of before: the same life, from that credential.
        let older = Self.minting()
        let none = TailscaleFleetKey(exchange: older.exchange, shelf: MemoryShelf())
        let credential = NetworkCredential(clientID: "kAbCd1234CNTRL", secret: "tskey-client-kAbCd1234CNTRL-secretpart")
        let key = try await PrivateNetwork.joinKey(for: "studio", life: PrivateNetwork.macKeyLifeSeconds, fleetKey: none,
                                                   credential: credential, client: NetworkClient(exchange: older.exchange))
        #expect(key == "tskey-auth-kAUTH1234CNTRL-notarealkey")
        #expect(older.call("POST", Self.keys)?.object?["expirySeconds"] as? Int == 7200)
        let calls = older.calls.count
        #expect(try await PrivateNetwork.joinKey(for: "studio", fleetKey: none, credential: nil,
                                                 client: NetworkClient(exchange: older.exchange)) == nil)
        #expect(older.calls.count == calls)
    }

    @Test func aMachinesNameIsFitForTailscalesOwnScreen() {
        #expect(TailscaleFleetKey.keyDescription("hub-1") == "Founderizer hub-1")
        #expect(TailscaleFleetKey.keyDescription("") == "Founderizer server")
        // Letters, digits, hyphens and spaces only, in at most 50 characters, as Tailscale's API says.
        #expect(TailscaleFleetKey.keyDescription("a b\"c;d:é") == "Founderizer abcd")
        #expect(TailscaleFleetKey.keyDescription(String(repeating: "m", count: 200)).count == 50)
    }

    @Test func aMintWithNoFleetKeyOrAnEndedOneSaysSo() async throws {
        let unused = ProviderStandIn()
        await #expect(throws: FleetKeyError.noFleetKey) {
            try await TailscaleFleetKey(exchange: unused.exchange, shelf: MemoryShelf()).mintAuthKey(hostname: "hub-1")
        }
        #expect(unused.calls.isEmpty)
        // OAuth's own two answers for a client that is no more; a Tailscale that is down is not one of them.
        for status in [400, 401] {
            let ended = ProviderStandIn()
            ended.answer("POST", Self.oauth, status, "{\"error\":\"invalid_client\"}")
            await #expect(throws: FleetKeyError.fleetKeyEnded) {
                try await TailscaleFleetKey(exchange: ended.exchange, shelf: MemoryShelf(Self.held.stored)).mintAuthKey(hostname: "x")
            }
        }
        let down = ProviderStandIn()
        down.answer("POST", Self.oauth, 503, "{\"message\":\"try later\"}")
        await #expect(throws: FleetKeyError.refused("try later")) {
            try await TailscaleFleetKey(exchange: down.exchange, shelf: MemoryShelf(Self.held.stored)).mintAuthKey(hostname: "x")
        }
        // An answer that is not an auth key is not passed on.
        let odd = Self.minting()
        odd.clear("POST", Self.keys)
        odd.answer("POST", Self.keys, 200, "{\"id\":\"k1\",\"key\":\"tskey-client-not-an-auth-key\"}")
        await #expect(throws: FleetKeyError.notUnderstood) {
            try await TailscaleFleetKey(exchange: odd.exchange, shelf: MemoryShelf(Self.held.stored)).mintAuthKey(hostname: "x")
        }
    }

    // MARK: - The connections that the install proves

    private static let devices = "/api/v2/tailnet/-/devices"
    private static func device(name: String = "worker-5", hostname: String = "worker-5", created: String = "2026-11-13T21:00:30Z",
                               authorized: Bool = true, tag: String = "tag:founderizer", address: String = "100.64.0.9",
                               lock: String = "") -> String {
        "{\"name\":\"\(name).example.ts.net\",\"hostname\":\"\(hostname)\",\"authorized\":\(authorized),\"created\":\"\(created)\","
            + "\"addresses\":[\"\(address)\",\"fd7a:115c:a1e0::9\"],\"tags\":[\"\(tag)\"],\"tailnetLockError\":\"\(lock)\"}"
    }
    /// When the build of the server began, in the tests' own time.
    private static let began = ISO8601DateFormatter().date(from: "2026-11-13T21:00:00Z")!

    @Test func tailscalesOwnListSaysWhichMachineAServerBecame() async throws {
        func listing(_ devices: String...) -> ProviderStandIn {
            let tailscale = Self.minting()
            tailscale.answer("GET", Self.devices, 200, "{\"devices\":[\(devices.joined(separator: ","))]}")
            return tailscale
        }
        func joined(_ tailscale: ProviderStandIn, _ name: String = "worker-5") async throws -> JoinedDevice? {
            try await TailscaleFleetKey(exchange: tailscale.exchange, shelf: MemoryShelf(Self.held.stored))
                .joined(hostname: name, since: Self.began)
        }
        let server = JoinedDevice(name: "worker-5.example.ts.net", addresses: ["100.64.0.9", "fd7a:115c:a1e0::9"])
        let tailscale = listing(Self.device())
        #expect(try await joined(tailscale) == server)
        #expect(try await joined(tailscale, "Worker-5") == server)
        // The list is read with a token of the fleet key, never with the key itself.
        let read = try #require(tailscale.call("GET", Self.devices))
        #expect(read.headers["Authorization"] == "Bearer tskey-api-kMINTED1CNTRL-short-lived")
        for other in ["worker-6", ""] {
            let found = try await joined(tailscale, other)
            #expect(found == nil, "name \(other)")
        }
        // The server is the device that gave itself the name, whatever Tailscale then called it: a tailnet that has a
        // worker-5 already calls the new one worker-5-1. A device that only Tailscale calls worker-5 is another one.
        let renamed = try await joined(listing(Self.device(name: "worker-5-1")))
        #expect(renamed?.name == "worker-5-1.example.ts.net")
        let other = try await joined(listing(Self.device(hostname: "ubuntu-4gb")))
        #expect(other == nil)
        // A device of that name from an earlier try is older than this build, and is not the server; of two, the
        // newest is. A time with fractions of a second is read too.
        let earlier = try await joined(listing(Self.device(created: "2026-11-13T20:40:00Z")))
        #expect(earlier == nil)
        // Five minutes of slack for a clock that is off, and no more.
        let slack = try await joined(listing(Self.device(created: "2026-11-13T20:57:00Z")))
        #expect(slack == server)
        let before = try await joined(listing(Self.device(created: "2026-11-13T20:54:00Z")))
        #expect(before == nil)
        let newest = try await joined(listing(Self.device(created: "2026-11-13T20:59:00Z", address: "100.64.0.7"),
                                              Self.device(created: "2026-11-13T21:01:02.345Z", address: "100.64.0.9")))
        #expect(newest?.addresses.first == "100.64.0.9")
        // A device that an admin has not approved, one that is no machine of the fleet, and one with no time are not it.
        for devices in [Self.device(authorized: false), Self.device(tag: "tag:server"), Self.device(created: "")] {
            let found = try await joined(listing(devices))
            #expect(found == nil, "devices \(devices)")
        }
        // A server that Tailnet Lock has not signed is listed, and says so.
        let locked = try await joined(listing(Self.device(lock: "node is not signed")))
        #expect(locked?.locked == true)
        // A Mac with no fleet key, an ended key and an answer that is no list each say so.
        let unused = ProviderStandIn()
        await #expect(throws: FleetKeyError.noFleetKey) {
            try await TailscaleFleetKey(exchange: unused.exchange, shelf: MemoryShelf()).joined(hostname: "worker-5", since: Self.began)
        }
        let ended = Self.minting()
        ended.answer("GET", Self.devices, 401, "{\"message\":\"invalid\"}")
        await #expect(throws: FleetKeyError.fleetKeyEnded) { _ = try await joined(ended) }
        let odd = Self.minting()
        odd.answer("GET", Self.devices, 200, "[]")
        await #expect(throws: FleetKeyError.notUnderstood) { _ = try await joined(odd) }
    }

    /// This Mac's `tailscale status --json`, as far as the proof reads it.
    private static func status(state: String = "Running", own: String = "owner-mac.example.ts.net.", online: Bool = true,
                               peers: String = "") -> String {
        "{\"BackendState\":\"\(state)\",\"Self\":{\"DNSName\":\"\(own)\",\"Online\":\(online),\"TailscaleIPs\":[\"100.64.0.2\"]},\"Peer\":{\(peers)}}"
    }

    @Test func onlyAServerThatThisMacsTailscaleDoesNotShowIsKeptFromItByThePolicy() {
        let server = JoinedDevice(name: "worker-5.example.ts.net", addresses: ["100.64.0.9", "fd7a:115c:a1e0::9"])
        let hub = "\"k1\":{\"DNSName\":\"fleet-hub.example.ts.net.\",\"TailscaleIPs\":[\"100.64.0.10\"],\"Online\":true}"
        // This Mac's Tailscale runs in the server's tailnet and shows other devices, and not the server.
        #expect(FleetReach.keeps(server, from: Self.status(peers: hub)))
        #expect(FleetReach.keeps(server, from: Self.status()))
        // It shows the server: by its address, also offline and under another name, or by its name.
        let offline = "\"k2\":{\"DNSName\":\"worker-5-1.example.ts.net.\",\"TailscaleIPs\":[\"100.64.0.9\"],\"Online\":false}"
        #expect(!FleetReach.keeps(server, from: Self.status(peers: hub + "," + offline)))
        let named = "\"k3\":{\"DNSName\":\"WORKER-5.example.ts.net.\",\"TailscaleIPs\":[\"100.64.0.99\"],\"Online\":true}"
        #expect(!FleetReach.keeps(server, from: Self.status(peers: named)))
        // Every other reason why this Mac does not see it is not the policy's: its Tailscale is stopped or signed
        // out, it is in another tailnet than the fleet key's, Tailnet Lock has not signed the server, or the answer
        // of this Mac's Tailscale cannot be read.
        for state in ["Stopped", "NeedsLogin", "Starting", "NoState"] {
            #expect(!FleetReach.keeps(server, from: Self.status(state: state, peers: hub)), "state \(state)")
        }
        #expect(!FleetReach.keeps(server, from: Self.status(own: "owner-mac.tail1234.ts.net.", peers: hub)))
        #expect(!FleetReach.keeps(server, from: Self.status(own: "", peers: hub)))
        // Cut off from its network, this Mac's Tailscale still says that it runs, with an old list of devices.
        #expect(!FleetReach.keeps(server, from: Self.status(online: false, peers: hub)))
        #expect(!FleetReach.keeps(server, from: Self.status(peers: hub).replacingOccurrences(of: "\"Online\":true,\"TailscaleIPs\":[\"100.64.0.2\"]", with: "\"TailscaleIPs\":[\"100.64.0.2\"]")))
        #expect(FleetReach.unseen("worker-5") == "worker-5 is on your Tailscale network, but Tailscale on this Mac does not show "
            + "it online. Check that Tailscale on this Mac is connected to the same network.")
        #expect(!FleetReach.keeps(JoinedDevice(name: server.name, addresses: server.addresses, locked: true), from: Self.status(peers: hub)))
        #expect(!FleetReach.keeps(JoinedDevice(name: "", addresses: server.addresses), from: Self.status(peers: hub)))
        #expect(!FleetReach.keeps(JoinedDevice(name: "worker-5", addresses: server.addresses), from: Self.status(peers: hub)))
        #expect(!FleetReach.keeps(server, from: "") && !FleetReach.keeps(server, from: "{}"))
    }

    @Test func aConnectionThatThePolicyStopsNamesItselfAndThePlaceOfThePolicy() throws {
        let tool = PolicyPlace.tool(URL(string: "https://github.com/example/tailnet-policy"))
        // A server that joined and that this Mac's Tailscale does not show: the one reach that is missing, by the
        // fleet's tag and in the words of a grant, and never a wider one. A hub is asked its own port with it.
        #expect(FleetReach.hidden("worker-5", place: tool) == "worker-5 is on your Tailscale network, but this Mac cannot "
            + "reach it. Change your Tailscale policy in github.com/example/tailnet-policy so that this Mac reaches "
            + "tag:founderizer on tcp:22.")
        #expect(FleetReach.hidden("worker-5", place: .tool(nil)).contains("your Tailscale policy, which another tool keeps, so that"))
        for place in [PolicyPlace.tailscale, nil] {
            #expect(FleetReach.hidden("worker-5", place: place) == "worker-5 is on your Tailscale network, but this Mac "
                + "cannot reach it. Change your Tailscale policy so that this Mac reaches tag:founderizer on tcp:22.")
        }
        #expect(FleetReach.hidden("worker-1", hub: true, place: nil).hasSuffix("so that this Mac reaches tag:founderizer on tcp:22, tcp:8765."))
        // An SSH connection to an address on the private network that nothing answered: Tailscale drops what its
        // policy does not allow. The line names the port that `ssh` used.
        let timeout = "ssh: connect to host 100.64.0.9 port 22: Operation timed out"
        // A server that is off gives the same line of `ssh`, so the words name both, as every server that did not
        // answer is said, with the policy in the place of the server's firewall.
        #expect(FleetReach.dropped(timeout, host: "100.64.0.9", place: tool) == "100.64.0.9 did not answer SSH on port 22. Check that "
            + "the server is on, and that your Tailscale policy in github.com/example/tailnet-policy lets this Mac reach it on tcp:22.")
        #expect(FleetReach.dropped(timeout, host: "100.64.0.9", place: .tool(nil))?.contains("policy, which another tool keeps, lets this Mac") == true)
        #expect(FleetReach.dropped("ssh: connect to host 100.64.0.9 port 2222: Connection timed out", host: "100.64.0.9", place: nil)
            == "100.64.0.9 did not answer SSH on port 2222. Check that the server is on, and that your Tailscale policy lets this "
            + "Mac reach it on tcp:2222.")
        // A server that refused the connection did get it; a public address is no matter of the policy; a line for
        // another host, or of another program on the server, is not this connection; and a connection that opened
        // and then went quiet was let through.
        #expect(FleetReach.dropped("ssh: connect to host 100.64.0.9 port 22: Connection refused", host: "100.64.0.9", place: tool) == nil)
        #expect(FleetReach.dropped("ssh: connect to host 203.0.113.9 port 22: Operation timed out", host: "203.0.113.9", place: tool) == nil)
        #expect(FleetReach.dropped("ssh: connect to host github.com port 22: Operation timed out", host: "100.64.0.9", place: tool) == nil)
        #expect(FleetReach.dropped("ssh: connect to host 100.64.0.99 port 22: Operation timed out", host: "100.64.0.9", place: tool) == nil)
        #expect(FleetReach.dropped("Connection timed out during banner exchange", host: "100.64.0.9", place: tool) == nil)
        // A stopped install says that line, and each other stop keeps its words.
        let dropped = InstallError.step("Read the server", timeout)
        #expect(dropped.plain(host: "100.64.0.9", place: tool) == FleetReach.dropped(timeout, host: "100.64.0.9", place: tool))
        let refused = InstallError.step("Read the server", "ssh: connect to host 100.64.0.9 port 22: Connection refused")
        #expect(refused.plain(host: "100.64.0.9", place: tool)
            == "100.64.0.9 refused SSH on port 22. Check that SSH runs on that port and lets this Mac in.")
        let open = InstallError.step("Read the server", "ssh: connect to host 203.0.113.9 port 22: Operation timed out")
        let unanswered = "203.0.113.9 did not answer SSH on port 22. Check that the server is on and that its firewall lets SSH in."
        #expect(open.plain(host: "203.0.113.9", place: tool) == unanswered)
        // The check of a server by its address says it too, for the server's own address only.
        let line = "100.64.0.9 did not answer SSH on port 22. Check that the server is on, and that your Tailscale policy"
        if case .stop(let why) = ServerCheck.sshRefused("Warning: Permanently added\n" + timeout + "\n", host: "100.64.0.9") {
            #expect(why.hasPrefix(line) && why.hasSuffix("lets this Mac reach it on tcp:22."))
        } else { Issue.record("no stop") }
        #expect(ServerCheck.sshRefused("ssh: connect to host 203.0.113.9 port 22: Operation timed out", host: "203.0.113.9")
            == .stop(unanswered))
    }

    @Test func thePlaceOfThePolicyIsKeptForALaterInstall() throws {
        let name = "FleetKeyTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(PolicyPlace.kept(in: defaults) == nil)
        let link = URL(string: "https://github.com/example/tailnet-policy?ref=main")
        for place in [PolicyPlace.tailscale, .tool(nil), .tool(link)] {
            place.keep(in: defaults)
            #expect(PolicyPlace.kept(in: defaults) == place)
        }
        // The address is said as he reads it: no scheme, no query, and no slash at its end; its port stays.
        #expect(PolicyPlace.tool(link).address == "github.com/example/tailnet-policy")
        #expect(PolicyPlace.tool(URL(string: "https://gitlab.example.com/ops/tailnet/")).address == "gitlab.example.com/ops/tailnet")
        #expect(PolicyPlace.tool(URL(string: "https://git.example.com:8443/ops/tailnet")).address == "git.example.com:8443/ops/tailnet")
        #expect(PolicyPlace.tool(nil).address == nil && PolicyPlace.tailscale.address == nil)
        // Nothing of a link's user shows, and an address too long for a line of the page is not said.
        #expect(PolicyPlace.tool(URL(string: "https://user:word@git.example.com/ops/tailnet#top")).address == "git.example.com/ops/tailnet")
        #expect(PolicyPlace.tool(URL(string: "https://git.example.com/" + String(repeating: "a", count: 90))).address == nil)
        // The link is any admin's setting, and its words stand in a sentence of this app's: an address that could
        // read as words of the app (a space, a line break, an escape, a letter outside ASCII) is not said at all,
        // and the sentence then names the tool.
        for odd in ["https://x.example/a.%20Send%20your%20key%20to%20evil.example", "https://x.example/a%0Ab",
                    "https://x.example/caf%C3%A9", "https://x.example/a%E2%80%AEb"] {
            let place = PolicyPlace.tool(URL(string: odd))
            #expect(place.address == nil, "link \(odd)")
            #expect(place.tagAsk.contains("in the file of the tool that keeps your policy"))
        }
        // A kept value that is no place of this app's is none.
        defaults.set("tool javascript:alert(1)", forKey: "tailscale.policy.place")
        #expect(PolicyPlace.kept(in: defaults) == .tool(nil))
        defaults.set("elsewhere", forKey: "tailscale.policy.place")
        #expect(PolicyPlace.kept(in: defaults) == nil)
    }

    // MARK: - Reading HuJSON

    @Test func commentsAndTrailingCommasAreReadAndStringsAreLeftAlone() throws {
        let file = """
        // "tagOwners": {"tag:founderizer": []},
        {
        \t/* "grants": [], */
        \t"hosts": {"a": "100.64.0.1", "b": "http://x//y/*z*/",},
        \t"acls": [{"action": "accept", "src": ["\\"*\\""], "dst": ["*:*"],},],
        }
        """
        let policy = try #require(FleetPolicy.parsed(file))
        #expect((policy["hosts"] as? [String: String])?["b"] == "http://x//y/*z*/")
        #expect(policy["grants"] == nil && policy["tagOwners"] == nil)
        // A member in a comment, a string or a nested object is no member of the file.
        let scan = try #require(FleetPolicy.scan(Array(file.utf8)))
        #expect(Set(scan.members.keys) == ["hosts", "acls"])
        #expect(FleetPolicy.scan(Array("{\"a\": {\"grants\": []}}".utf8))?.members.keys.contains("grants") == false)
        // A string or a comment that never ends, and a file that is no object, are not read.
        #expect(FleetPolicy.parsed("{\"a\": \"b}") == nil)
        #expect(FleetPolicy.parsed("{/* no end}") == nil)
        #expect(FleetPolicy.scan(Array("[]".utf8)) == nil)
        #expect(FleetPolicy.parsed("{\"a\": [1,,2]}") == nil)
    }

    @Test func aSectionOfTheWrongShapeIsNotGuessedAt() {
        for file in ["{\"tagOwners\": [], \"acls\": []}", "{\"grants\": {}, \"tagOwners\": {}}", "{\"tagOwners\": null}"] {
            #expect(FleetPolicy.needs(in: file).flatMap { FleetPolicy.writing($0, into: file) } == nil, "file \(file)")
        }
    }
}
