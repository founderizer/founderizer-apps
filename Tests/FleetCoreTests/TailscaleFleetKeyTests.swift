import Foundation
import Testing
@testable import FleetCore

/// The fleet's own key to the owner's private network: the one access token he pastes, the lines this app adds to his
/// policy file, the fleet key it makes and keeps, and the key it mints for each machine. Every request is proved against
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
        + "\"ip\": [\"tcp:22\", \"tcp:8765\"]},\n\t\t{\"src\": [\"tag:founderizer\"], \"dst\": [\"tag:founderizer\"], "
        + "\"ip\": [\"tcp:22\", \"tcp:8765\"]},"

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
        #expect(setup == FleetKeySetup(keyMade: true, wrotePolicy: true, linesToAdd: nil, managedAt: nil))
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
        #expect(needs == .everything)
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
        // One that gives less does not.
        let less = "{\"tagOwners\": {\"tag:founderizer\": []}, \"acls\": [], \"grants\": ["
            + "{\"src\": [\"autogroup:admin\"], \"dst\": [\"tag:founderizer\"], \"ip\": [\"tcp:22\"]}]}"
        #expect(try #require(FleetPolicy.needs(in: less)).grants == FleetPolicy.grants)
    }

    @Test func aNetworkThatIsReadyIsNotWrittenTo() async throws {
        let ready = "{\"tagOwners\": {\"tag:founderizer\": [\"autogroup:admin\"]}}"
        let tailscale = Self.tailnet(policy: ready)
        let setup = try await Self.connect(tailscale)
        #expect(setup == FleetKeySetup(keyMade: true, wrotePolicy: false, linesToAdd: nil, managedAt: nil))
        #expect(tailscale.calls("POST", Self.acl).isEmpty && tailscale.calls("POST", Self.validate).isEmpty)
        #expect(tailscale.calls("POST", Self.keys).count == 1)
    }

    @Test func aFileAnotherToolKeepsIsNeverWritten() async throws {
        let link = "https://github.com/example/tailnet-policy"
        let tailscale = Self.tailnet(policy: Self.restrictive, managed: true, link: link)
        let setup = try await Self.connect(tailscale)
        // The owner gets the exact lines, and where to put them; and no key yet, for a tag nobody owns yet.
        #expect(setup == FleetKeySetup(keyMade: false, wrotePolicy: false, linesToAdd: """
        "tagOwners": {
        \t"tag:founderizer": ["autogroup:admin"],
        },
        "grants": [
        \t{"src": ["autogroup:owner", "autogroup:admin"], "dst": ["tag:founderizer"], "ip": ["tcp:22", "tcp:8765"]},
        \t{"src": ["tag:founderizer"], "dst": ["tag:founderizer"], "ip": ["tcp:22", "tcp:8765"]},
        ],
        """, managedAt: URL(string: link)))
        #expect(!tailscale.calls.contains { $0.method == "POST" })
        // Once he has added the tag there, the key is made, and only the lines still missing are left for him.
        let tagged = "{\"tagOwners\": {\"tag:founderizer\": [\"autogroup:admin\"]}, \"acls\": []}"
        let later = Self.tailnet(policy: tagged, managed: true, link: link)
        let second = try await Self.connect(later)
        #expect(second.keyMade && !second.wrotePolicy)
        #expect(second.linesToAdd?.hasPrefix("\"grants\": [") == true)
        #expect(later.calls("POST", Self.acl).isEmpty && later.calls("POST", Self.validate).isEmpty)
        // A link that is not a web page of its own is not passed on.
        let odd = Self.tailnet(policy: tagged, managed: true, link: "javascript:alert(1)")
        #expect(try await Self.connect(odd).managedAt == nil)
    }

    @Test func aFileThisAppCannotReadIsLeftAloneAndSaidInFull() async throws {
        for file in ["// a file with no object in it at all", "{\"acls\": [", "{\"acls\": \"never ends}", "[]"] {
            let tailscale = Self.tailnet(policy: file)
            let setup = try await Self.connect(tailscale)
            #expect(!setup.keyMade && !setup.wrotePolicy)
            #expect(setup.linesToAdd == FleetPolicy.lines(for: .everything))
            #expect(!tailscale.calls.contains { $0.method == "POST" })
        }
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
        await #expect(throws: FleetKeyError.refused("test(s) failed: address \"tag:founderizer:22\": want: Drop, got: Accept")) {
            try await Self.connect(tailscale)
        }
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
