import Foundation
import Testing
@testable import FleetCore

/// **The vectors of Tailscale's API as FleetCore calls it** (`app/vectors/tailscale-requests.json`; windows-app-plan-v2.md,
/// section 5.6, piece L2): for each fixed case, the answers that a stand-in for Tailscale gives, each request that
/// `TailscaleFleetKey` sends (method, address, headers, body), what it gives back or the error it throws, and what it
/// keeps. Beside them the pure rules: the policy file's reading and writing (`FleetPolicy`), this Mac's own Tailscale
/// (`MacNetwork.reading`, `device(of:in:)`, `FleetOnTailscale`), `FleetReach.keeps`, and the English words of each error
/// and line. The Windows app's library (`windows/Founderizer.Setup/Network`) sends the same requests and reads the same
/// answers: its tests hold them equal to this file.
///
/// A secret of a case (the access token, the fleet key's secret, a one-hour access token) stands in a request by its
/// name in braces, so the file shows which secret went where and never needs one. Every value is an example.
///
/// With `FOUNDERIZER_VECTORS_OUT` set, the test writes the file into that folder (`app/vectors/make_vectors.py` does,
/// and its `--check` compares); without it, the test holds the committed file equal to what FleetCore gives now.
struct TailscaleVectorsTests {
    static let file = "tailscale-requests.json"

    static let token = "tskey-api-kEXAMPLE1CNTRL-notarealsecretvalue0000"
    static let clientID = "kFLEET1234CNTRL"
    static let clientSecret = "tskey-client-kFLEET1234CNTRL-notarealsecret"
    static let oldID = "kOLDKEY123CNTRL"
    static let oldSecret = "tskey-client-kOLDKEY123CNTRL-notarealoldsecret"
    static let access = "notarealaccesstoken-0123456789abcdef"
    static let authKey = "tskey-auth-kAUTH1234CNTRL-notarealkey"
    static let secrets = ["{access token}": token, "{fleet secret}": clientSecret, "{old fleet secret}": oldSecret,
                          "{fleet access}": access]

    static let settings = "/api/v2/tailnet/-/settings"
    static let acl = "/api/v2/tailnet/-/acl"
    static let validate = "/api/v2/tailnet/-/acl/validate"
    static let keys = "/api/v2/tailnet/-/keys"
    static let oauth = "/api/v2/oauth/token"
    static let devices = "/api/v2/tailnet/-/devices"

    static let clientAnswer = "{\"id\":\"\(clientID)\",\"key\":\"\(clientSecret)\",\"keyType\":\"client\","
        + "\"scopes\":[\"auth_keys\",\"devices:core\"],\"tags\":[\"tag:founderizer\"]}"
    static let accessAnswer = "{\"access_token\":\"\(access)\",\"token_type\":\"Bearer\",\"expires_in\":3600}"

    // MARK: - Policy files

    static let allowAll = """
    // The owner's own rules. This comment must still be here afterwards.
    {
    \t"tagOwners": {
    \t\t"tag:server": ["owner@example.com"],
    \t},
    \t"acls": [
    \t\t{"action": "accept", "src": ["*"], "dst": ["*:*"]},
    \t],
    }
    """

    static let restrictive = """
    {
    \t// Only my laptop reaches my servers.
    \t"acls": [
    \t\t{"action": "accept", "src": ["owner@example.com"], "dst": ["tag:server:22"]},
    \t],
    \t"tagOwners": {"tag:server": ["owner@example.com"]},
    }
    """

    static let tagged = """
    {
    \t"tagOwners": {"tag:founderizer": ["autogroup:admin"]},
    \t"acls": [{"action": "accept", "src": ["owner@example.com"], "dst": ["*:22"]}],
    }
    """

    /// Files for the pure rules: each kind that `FleetPolicy` reads differently.
    static let policies: [String] = [
        allowAll, restrictive, tagged, "{}", "", "not json at all", "{\"tagOwners\": {\"tag:founderizer\": []}}",
        // The name in a comment and in a string is no member.
        "{\n\t// \"tagOwners\": {}\n\t\"note\": \"grants tagOwners\",\n}",
        // A member named twice: the file is not this app's to guess at.
        "{\"tagOwners\": {}, \"TagOwners\": {\"tag:x\": []}}",
        "{\"grants\": [], \"Grants\": []}",
        // A section of another shape.
        "{\"tagOwners\": [], \"acls\": []}", "{\"grants\": {}, \"acls\": []}",
        // Keys in another case, trailing commas, and a block comment.
        "{\n\t/* the owner's */ \"TAGOWNERS\": {\"Tag:Founderizer\": [\"autogroup:admin\",],},\n\t\"ACLs\": [],\n}",
        // Grants that cover what the fleet needs, one that covers only part, and a grant from everyone to everyone.
        "{\"tagOwners\": {\"tag:founderizer\": []}, \"grants\": [{\"src\": [\"autogroup:owner\", \"autogroup:admin\"], "
            + "\"dst\": [\"tag:founderizer\"], \"ip\": [\"*\"]}, {\"src\": [\"*\"], \"dst\": [\"tag:founderizer\"], \"ip\": [\"tcp:*\"]}]}",
        "{\"grants\": [{\"src\": [\"autogroup:owner\"], \"dst\": [\"tag:founderizer\"], \"ip\": [\"22\", \"8765\", \"9418\"]}]}",
        "{\"grants\": [{\"src\": [\"*\"], \"dst\": [\"*\"], \"ip\": [\"*\"]}]}",
        "{\"grants\": [{\"src\": [\"*\"], \"dst\": [\"*\"], \"ip\": [\"*\"], \"srcPosture\": [\"posture:x\"]}]}",
        "{\"acls\": [{\"action\": \"accept\", \"users\": [\"*\"], \"ports\": [\"*:*\"]}]}",
        "{\"acls\": [{\"action\": \"accept\", \"src\": [\"*\"], \"dst\": [\"*:*\"], \"proto\": \"tcp\"}]}",
        "{\"acls\": null, \"grants\": null}",
        // A string that never ends, a block comment that never ends, an escaped quote, and text outside ASCII.
        "{\"tagOwners\": {\"tag:x\": [\"a]}", "{/* never ends", "{\"note\": \"a \\\"quoted\\\" grants\", \"acls\": []}",
        "{\n\t// Café, naïve: the owner's words\n\t\"acls\": [],\n}",
        // Two commas in a row, and a value that is not an object.
        "{\"acls\": [],, }", "[]",
    ]

    // MARK: - Cases with the stand-in

    /// A tailnet that answers everything, with this policy file in it.
    static func tailnet(policy: String, etag: String = "\"v1\"", managed: Bool = false, link: String? = nil) -> VectorStand {
        let tailscale = VectorStand()
        let place = link.map { ",\"aclsExternalLink\":\"\($0)\"" } ?? ""
        tailscale.answer("GET", settings, 200, "{\"aclsExternallyManagedOn\":\(managed)\(place),\"devicesApprovalOn\":false}")
        tailscale.answer("GET", acl, 200, policy, headers: ["ETag": etag])
        tailscale.answer("POST", validate, 200, "{}")
        tailscale.answer("POST", acl, 200, "{}")
        tailscale.answer("POST", keys, 200, clientAnswer)
        return tailscale
    }

    /// The fleet key held, and a tailnet whose OAuth gives the one-hour access token.
    static func held() -> VectorStand {
        let tailscale = VectorStand()
        tailscale.answer("POST", oauth, 200, accessAnswer)
        return tailscale
    }

    static let heldValue = clientID + "\n" + clientSecret

    static let devicesAnswer = """
    {"devices":[
    {"id":"1001","nodeId":"nAAAA1CNTRL","hostname":"worker-3","name":"worker-3.tail1234.ts.net.","addresses":["100.64.0.20","fd7a:115c:a1e0::30"],"tags":["tag:founderizer"],"authorized":true,"created":"2026-11-13T09:00:00Z","isExternal":false,"connectedToControl":false},
    {"id":"1002","nodeId":"nBBBB2CNTRL","hostname":"Worker-3","name":"worker-3-1.tail1234.ts.net","addresses":["100.64.0.31"],"tags":["tag:founderizer"],"authorized":true,"created":"2026-11-13T10:00:00.123456Z","isExternal":false,"connectedToControl":true,"tailnetLockError":""},
    {"id":"1003","hostname":"worker-3","name":"worker-3-2.tail1234.ts.net.","addresses":["100.64.0.32"],"tags":[],"authorized":true,"created":"2026-11-13T11:00:00Z"},
    {"id":"1004","hostname":"worker-3","name":"worker-3-3.tail1234.ts.net.","addresses":["100.64.0.41"],"tags":["tag:founderizer"],"authorized":false,"created":"2026-11-13T12:00:00Z"},
    {"id":"1005","hostname":"worker-4","name":"worker-4.tail1234.ts.net.","addresses":["100.64.0.40"],"tags":["tag:founderizer"],"authorized":true,"created":"2026-11-13T10:30:00Z","tailnetLockError":"not signed"},
    {"id":"bad id!","hostname":"shared","name":"shared.example.ts.net.","addresses":["100.64.1.4"],"tags":[],"created":"not a time","isExternal":true},
    {"nodeId":"nCCCC3CNTRL","hostname":"laptop","name":"laptop.tail1234.ts.net.","addresses":["100.64.1.6"],"created":"2026-01-01T00:00:00Z","connectedToControl":true}
    ]}
    """

    struct Case {
        let name: String
        let call: [String: Any]
        var held: String? = nil
        var refuses = false
        let stand: VectorStand
    }

    static func cases() -> [Case] {
        var cases: [Case] = []
        cases.append(Case(name: "A file that lets everything through gets the tag alone, and the key is made",
                          call: ["do": "connect", "token": token], stand: tailnet(policy: allowAll)))
        cases.append(Case(name: "A file that lets less through gets the tag and the two grants",
                          call: ["do": "connect", "token": "  \(token)\n"], stand: tailnet(policy: restrictive)))
        cases.append(Case(name: "A file that another tool keeps, with no tag: one line is asked and nothing is written",
                          call: ["do": "connect", "token": token],
                          stand: tailnet(policy: restrictive, managed: true,
                                         link: "https://github.com/example/tailnet-policy/blob/main/policy.hujson?x=1")))
        cases.append(Case(name: "A file that another tool keeps, with the tag: the key, and no write",
                          call: ["do": "connect", "token": token], stand: tailnet(policy: tagged, managed: true)))
        cases.append(Case(name: "A file with the tag that Tailscale keeps gets the grants where they go",
                          call: ["do": "connect", "token": token], stand: tailnet(policy: tagged)))
        let raced = VectorStand()
        raced.answer("GET", settings, 200, "{\"aclsExternallyManagedOn\":false}")
        raced.answer("GET", acl, 200, allowAll, headers: ["ETag": "\"v1\""])
        raced.answer("GET", acl, 200, allowAll + "\n// changed\n", headers: ["ETag": "\"v2\""])
        raced.answer("POST", validate, 200, "{}")
        raced.answer("POST", acl, 412, "{\"message\":\"precondition failed\"}")
        raced.answer("POST", acl, 200, "{}")
        raced.answer("POST", keys, 200, clientAnswer)
        cases.append(Case(name: "A file that changed meanwhile is read once more and written against its new version",
                          call: ["do": "connect", "token": token], stand: raced))
        let twice = VectorStand()
        twice.answer("GET", settings, 200, "{\"aclsExternallyManagedOn\":false}")
        twice.answer("GET", acl, 200, allowAll, headers: ["ETag": "\"v1\""])
        twice.answer("POST", validate, 200, "{}")
        twice.answer("POST", acl, 412, "{\"message\":\"precondition failed\"}")
        cases.append(Case(name: "A file that changes twice while it is written stops the step",
                          call: ["do": "connect", "token": token], stand: twice))
        let tests = VectorStand()
        tests.answer("GET", settings, 200, "{\"aclsExternallyManagedOn\":false}")
        tests.answer("GET", acl, 200, restrictive, headers: ["ETag": "\"v1\""])
        tests.answer("POST", validate, 200, "{\"message\":\"test(s) failed\",\"data\":[{\"user\":\"owner@example.com\","
                     + "\"errors\":[\"owner@example.com cannot reach tag:founderizer:22\"]}]}")
        tests.answer("POST", validate, 200, "{}")
        tests.answer("POST", acl, 200, "{}")
        tests.answer("POST", keys, 200, clientAnswer)
        cases.append(Case(name: "A file whose own tests refuse the grants gets the tag alone",
                          call: ["do": "connect", "token": token], stand: tests))
        let warned = VectorStand()
        warned.answer("GET", settings, 200, "{\"aclsExternallyManagedOn\":false}")
        warned.answer("GET", acl, 200, allowAll, headers: ["ETag": "\"v1\""])
        warned.answer("POST", validate, 200, "{\"message\":\"warnings\",\"data\":[{\"warnings\":[\"a rule is unused\"]}]}")
        warned.answer("POST", acl, 200, "{}")
        warned.answer("POST", keys, 200, clientAnswer)
        cases.append(Case(name: "Warnings alone are no refusal of the file",
                          call: ["do": "connect", "token": token], stand: warned))
        let refusedTag = VectorStand()
        refusedTag.answer("GET", settings, 200, "{\"aclsExternallyManagedOn\":false}")
        refusedTag.answer("GET", acl, 200, allowAll, headers: ["ETag": "\"v1\""])
        refusedTag.answer("POST", validate, 200, "{\"message\":\"parse error\",\"data\":[{\"errors\":[\"line 3: "
                          + "unknown tag owner autogroup:admin\"]}]}")
        cases.append(Case(name: "A check that refuses the tag's line too is said in Tailscale's words",
                          call: ["do": "connect", "token": token], stand: refusedTag))
        let replaced = tailnet(policy: tagged, managed: true)
        replaced.answer("DELETE", keys + "/" + oldID, 200, "")
        cases.append(Case(name: "A fleet key held before is replaced, and ended in Tailscale",
                          call: ["do": "connect", "token": token], held: oldID + "\n" + oldSecret, stand: replaced))
        let refusing = tailnet(policy: tagged, managed: true)
        refusing.answer("DELETE", keys + "/" + clientID, 200, "")
        cases.append(Case(name: "A fleet key that cannot be kept is ended at once",
                          call: ["do": "connect", "token": token], refuses: true, stand: refusing))
        let notAccepted = VectorStand()
        notAccepted.answer("GET", settings, 401, "{\"message\":\"API token invalid\"}")
        cases.append(Case(name: "A token that Tailscale does not take", call: ["do": "connect", "token": token],
                          stand: notAccepted))
        let role = tailnet(policy: restrictive)
        role.clear("POST", acl)
        role.answer("POST", acl, 403, "{\"message\":\"forbidden\"}")
        cases.append(Case(name: "A role that may not write the file", call: ["do": "connect", "token": token], stand: role))
        let echo = VectorStand()
        echo.answer("GET", settings, 500, "{\"message\":\"token \(token) failed\\non two lines\"}")
        cases.append(Case(name: "A refusal in Tailscale's words, with the token taken out",
                          call: ["do": "connect", "token": token], stand: echo))
        let silent = VectorStand()
        silent.answer("GET", settings, 502, "")
        cases.append(Case(name: "A refusal with no words", call: ["do": "connect", "token": token], stand: silent))
        let wait = VectorStand()
        wait.answer("GET", settings, 200, "{\"aclsExternallyManagedOn\":true}")
        wait.answer("GET", acl, 429, "{\"message\":\"rate limited\"}")
        cases.append(Case(name: "Tailscale asks to wait", call: ["do": "connect", "token": token], stand: wait))
        let offline = VectorStand()
        offline.answer("GET", settings, ProviderStandIn.dropped, "")
        cases.append(Case(name: "Tailscale cannot be reached", call: ["do": "connect", "token": token], stand: offline))
        let odd = VectorStand()
        odd.answer("GET", settings, 200, "not json")
        cases.append(Case(name: "An answer that this app does not understand", call: ["do": "connect", "token": token],
                          stand: odd))
        let noClient = tailnet(policy: tagged, managed: true)
        noClient.clear("POST", keys)
        noClient.answer("POST", keys, 200, "{\"id\":\"kNEW1234CNTRL\",\"key\":\"not a client secret\"}")
        noClient.answer("DELETE", keys + "/kNEW1234CNTRL", 200, "")
        cases.append(Case(name: "A fleet key whose secret is not one is ended and not kept",
                          call: ["do": "connect", "token": token], stand: noClient))
        for pasted in ["", "tskey-auth-kAbc1234CNTRL-xyz", "tskey-client-kAbc1234CNTRL-xyz", "tskey-api-has space",
                       "tskey-api-" + String(repeating: "a", count: 300)] {
            cases.append(Case(name: "Not an access token: \(pasted.prefix(24))", call: ["do": "connect", "token": pasted],
                              stand: VectorStand()))
        }

        let mint = held()
        mint.answer("POST", keys, 200, "{\"id\":\"kKEY1CNTRL\",\"key\":\"\(authKey)\"}")
        cases.append(Case(name: "One key for one machine, for an hour", call: ["do": "mint", "hostname": "worker-3", "life": 3600],
                          held: heldValue, stand: mint))
        let named = held()
        named.answer("POST", keys, 200, "{\"key\":\"\(authKey)\"}")
        cases.append(Case(name: "A machine's name in the key's description, cut to Tailscale's length",
                          call: ["do": "mint", "hostname": "a-very-long-server-name_with.dots-and-more-0123456789", "life": 900],
                          held: heldValue, stand: named))
        let notAKey = held()
        notAKey.answer("POST", keys, 200, "{\"key\":\"tskey-api-wrong\"}")
        cases.append(Case(name: "An answer that is no auth key", call: ["do": "mint", "hostname": "hub-1", "life": 900],
                          held: heldValue, stand: notAKey))
        for status in [400, 401] {
            let ended = VectorStand()
            ended.answer("POST", oauth, status, "{\"error\":\"invalid_client\"}")
            cases.append(Case(name: "A fleet key that Tailscale ended (\(status))",
                              call: ["do": "mint", "hostname": "hub-1", "life": 900], held: heldValue, stand: ended))
        }
        let down = VectorStand()
        down.answer("POST", oauth, 503, "{\"error_description\":\"try later\"}")
        cases.append(Case(name: "A Tailscale that is down says nothing about the fleet key",
                          call: ["do": "mint", "hostname": "hub-1", "life": 900], held: heldValue, stand: down))
        let keyEnded = held()
        keyEnded.answer("POST", keys, 401, "{\"message\":\"unauthorized\"}")
        cases.append(Case(name: "A key refused with 401 after the access token: the fleet key ended",
                          call: ["do": "mint", "hostname": "hub-1", "life": 900], held: heldValue, stand: keyEnded))
        let keyRefused = held()
        keyRefused.answer("POST", keys, 400, "{\"message\":\"tags are invalid\"}")
        cases.append(Case(name: "A key refused in Tailscale's words",
                          call: ["do": "mint", "hostname": "hub-1", "life": 900], held: heldValue, stand: keyRefused))
        let badAccess = VectorStand()
        badAccess.answer("POST", oauth, 200, "{\"access_token\":\"two\\nlines\"}")
        cases.append(Case(name: "An access token on two lines is not one",
                          call: ["do": "mint", "hostname": "hub-1", "life": 900], held: heldValue, stand: badAccess))
        cases.append(Case(name: "No fleet key held", call: ["do": "mint", "hostname": "hub-1", "life": 900],
                          stand: VectorStand()))
        cases.append(Case(name: "A held value that is not a fleet key", call: ["do": "mint", "hostname": "hub-1", "life": 900],
                          held: "only one line", stand: VectorStand()))

        let joined = held()
        joined.answer("GET", devices, 200, devicesAnswer)
        cases.append(Case(name: "The newest tagged device of the name, made since the server was",
                          call: ["do": "joined", "hostname": "worker-3", "since": 1_794_560_000.0], held: heldValue, stand: joined))
        let lockedJoin = held()
        lockedJoin.answer("GET", devices, 200, devicesAnswer)
        cases.append(Case(name: "A device that Tailnet Lock keeps out",
                          call: ["do": "joined", "hostname": "WORKER-4", "since": 1_794_560_000.0], held: heldValue, stand: lockedJoin))
        let slack = held()
        slack.answer("GET", devices, 200, devicesAnswer)
        cases.append(Case(name: "A device made a little before the server, by a clock that is off, is it",
                          call: ["do": "joined", "hostname": "worker-3", "since": 1_794_564_100.0], held: heldValue, stand: slack))
        let late = held()
        late.answer("GET", devices, 200, devicesAnswer)
        cases.append(Case(name: "A device older than the server is not it",
                          call: ["do": "joined", "hostname": "worker-3", "since": 1_794_600_000.0], held: heldValue, stand: late))
        let listed = held()
        listed.answer("GET", devices, 200, devicesAnswer)
        cases.append(Case(name: "The tailnet's devices, each by its id", call: ["do": "devices"], held: heldValue, stand: listed))
        let unread = held()
        unread.answer("GET", devices, 200, "{\"devices\":\"no list\"}")
        cases.append(Case(name: "A list of devices that is no list", call: ["do": "devices"], held: heldValue, stand: unread))
        let gone = held()
        gone.answer("DELETE", "/api/v2/device/nBBBB2CNTRL", 200, "")
        cases.append(Case(name: "One device removed by its id", call: ["do": "delete_device", "id": "nBBBB2CNTRL"],
                          held: heldValue, stand: gone))
        let already = held()
        already.answer("DELETE", "/api/v2/device/nBBBB2CNTRL", 404, "{\"message\":\"not found\"}")
        cases.append(Case(name: "A device that Tailscale no longer has is removed already",
                          call: ["do": "delete_device", "id": "nBBBB2CNTRL"], held: heldValue, stand: already))
        let refusedDelete = held()
        refusedDelete.answer("DELETE", "/api/v2/device/nBBBB2CNTRL", 403, "{\"message\":\"cannot delete\"}")
        cases.append(Case(name: "A removal that Tailscale refuses", call: ["do": "delete_device", "id": "nBBBB2CNTRL"],
                          held: heldValue, stand: refusedDelete))
        cases.append(Case(name: "An id that may not stand in a path", call: ["do": "delete_device", "id": "../keys"],
                          held: heldValue, stand: held()))
        return cases
    }

    /// Runs one case against FleetCore's own code, and answers what it gave or threw.
    static func run(_ one: Case) async -> (result: Any, error: [String: Any]?, kept: String?) {
        let shelf = MemoryShelf(one.held.map { Data($0.utf8) })
        shelf.refuses = one.refuses
        let key = TailscaleFleetKey(exchange: one.stand.stand.exchange, shelf: shelf)
        var result: Any = NSNull()
        var thrown: [String: Any]?
        do {
            switch one.call["do"] as! String {
            case "connect":
                let setup = try await key.connect(accessToken: one.call["token"] as! String)
                result = ["key_made": setup.keyMade, "wrote_policy": setup.wrotePolicy,
                          "lines_to_add": setup.linesToAdd as Any? ?? NSNull(), "place": place(setup.place),
                          "asks": setup.asks as Any? ?? NSNull()]
            case "mint":
                result = ["key": try await key.mintAuthKey(hostname: one.call["hostname"] as! String,
                                                           life: one.call["life"] as! Int)]
            case "joined":
                let since = Date(timeIntervalSince1970: one.call["since"] as! Double)
                if let device = try await key.joined(hostname: one.call["hostname"] as! String, since: since) {
                    result = ["name": device.name, "addresses": device.addresses, "locked": device.locked]
                }
            case "devices":
                result = try await key.devices().map { device -> [String: Any] in
                    ["id": device.id, "hostname": device.hostname, "name": device.name, "addresses": device.addresses,
                     "tags": device.tags, "created": device.created.map { $0.timeIntervalSince1970 } as Any? ?? NSNull(),
                     "authorized": device.authorized, "external": device.external, "connected": device.connected]
                }
            case "delete_device":
                try await key.deleteDevice(id: one.call["id"] as! String)
                result = "removed"
            default: Issue.record("no such call")
            }
        } catch let error as FleetKeyError {
            thrown = fleetKeyError(error)
        } catch {
            thrown = ["case": "kept_nowhere"]
        }
        return (result, thrown, shelf.held.map { String(decoding: $0, as: UTF8.self) })
    }

    static func place(_ place: PolicyPlace) -> String {
        switch place {
        case .tailscale: "tailscale"
        case .tool(let link): link.map { "tool " + $0.absoluteString } ?? "tool"
        }
    }

    static func fleetKeyError(_ error: FleetKeyError) -> [String: Any] {
        var named: [String: Any] = ["words": error.errorDescription ?? ""]
        switch error {
        case .notAnAccessToken: named["case"] = "not_an_access_token"
        case .tokenNotAccepted: named["case"] = "token_not_accepted"
        case .roleCannotWrite: named["case"] = "role_cannot_write"
        case .rateLimited: named["case"] = "rate_limited"
        case .unreachable: named["case"] = "unreachable"
        case .refused(let says): named["case"] = "refused"; named["says"] = says
        case .notUnderstood: named["case"] = "not_understood"
        case .policyChangedMeanwhile: named["case"] = "policy_changed_meanwhile"
        case .noFleetKey: named["case"] = "no_fleet_key"
        case .fleetKeyEnded: named["case"] = "fleet_key_ended"
        }
        return named
    }

    // MARK: - The pure rules

    static func needs(_ needs: FleetPolicy.Needs?) -> Any {
        guard let needs else { return NSNull() }
        return ["tag": needs.tag, "grants": needs.grants.map { grant in FleetPolicy.grants.firstIndex(of: grant)! }]
    }

    static func policyRules() -> [[String: Any]] {
        policies.map { text in
            let found = FleetPolicy.needs(in: text)
            return ["text": text, "needs": needs(found),
                    "written": found.flatMap { FleetPolicy.writing($0, into: text) } as Any? ?? NSNull(),
                    "written_tag": FleetPolicy.writing(FleetPolicy.Needs(tag: true, grants: []), into: text) as Any? ?? NSNull(),
                    "written_all": FleetPolicy.writing(FleetPolicy.Needs(tag: true, grants: FleetPolicy.grants), into: text)
                        as Any? ?? NSNull()]
        }
    }

    static let statuses: [String] = [
        "", "not json", "{}", "{\"BackendState\": \"NeedsLogin\"}", "{\"BackendState\": \"NoState\"}",
        "{\"BackendState\": \"Stopped\", \"Self\": {\"TailscaleIPs\": [\"100.101.100.180\"]}}",
        "{\"BackendState\": \"Starting\"}",
        "{\"BackendState\": \"Running\", \"Self\": {\"TailscaleIPs\": [\"fd7a:115c:a1e0::1\"]}}",
        """
        {"BackendState": "Running", "CurrentTailnet": {"Name": "owner@example.com"},
         "Self": {"DNSName": "owner-pc.tail1234.ts.net.", "HostName": "Owner-PC", "TailscaleIPs": ["fd7a:115c:a1e0::1", "100.101.100.180"], "Online": true},
         "Peer": {
           "a": {"DNSName": "worker-1.tail1234.ts.net.", "HostName": "worker-1", "TailscaleIPs": ["100.96.100.130"], "Online": false},
           "b": {"DNSName": "worker-2-1.tail1234.ts.net.", "HostName": "Worker-2", "TailscaleIPs": ["fd7a:115c:a1e0::2", "100.96.10.20"], "Online": true},
           "c": {"DNSName": "iphone.tail1234.ts.net.", "TailscaleIPs": ["100.101.100.90"], "Online": true},
           "d": {"DNSName": "", "TailscaleIPs": ["100.64.0.9"], "Online": true},
           "e": {"DNSName": "twin.tail1234.ts.net.", "TailscaleIPs": ["100.64.1.7"]},
           "f": {"DNSName": "twin-2.example.ts.net.", "TailscaleIPs": ["100.64.1.9"]}
         }}
        """,
        "{\"BackendState\": \"Running\", \"CurrentTailnet\": {\"Name\": \"\"}, \"Self\": {\"TailscaleIPs\": [\"100.64.0.2\"], \"Online\": false}}",
        "warning: a newer version is out\n{\"BackendState\": \"Running\", \"Self\": {\"DNSName\": \"owner-pc.tail1234.ts.net.\", \"Online\": true}, \"Peer\": {}}",
    ]

    static let hosts = ["100.96.10.20", "worker-2-1", "WORKER-2-1.tail1234.ts.net", "[100.96.10.20]", "worker-1", "worker-2",
                        "twin", "owner-pc", "100.101.100.180", "nothing", ""]

    static func networkRules() -> [[String: Any]] {
        statuses.map { json in
            let standing = MacNetwork.reading(json)
            let devices = FleetOnTailscale.devices(in: json).map { device -> [String: Any] in
                ["name": device.name, "address": device.address, "online": device.online, "host": device.host]
            }
            var of: [String: Any] = [:]
            for host in hosts { of[host] = MacNetwork.device(of: host, in: json) as Any? ?? NSNull() }
            return ["status": json, "step": standing.step.rawValue, "address": standing.address as Any? ?? NSNull(),
                    "tailnet": standing.tailnet as Any? ?? NSNull(), "says": standing.says as Any? ?? NSNull(),
                    "devices": devices, "live": FleetOnTailscale.live(in: json).map { $0.map(\.name) } as Any? ?? NSNull(),
                    "own_name": FleetOnTailscale.ownName(in: json) as Any? ?? NSNull(), "device_of": of]
        }
    }

    static let reachStatus = """
    {"BackendState": "Running", "Self": {"DNSName": "owner-pc.tail1234.ts.net.", "Online": true},
     "Peer": {"a": {"DNSName": "worker-1.tail1234.ts.net.", "TailscaleIPs": ["100.96.100.130"]}}}
    """

    static func reachRules() -> [[String: Any]] {
        let devices: [(String, [String], Bool)] = [
            ("worker-3.tail1234.ts.net", ["100.64.0.31"], false), ("worker-1.tail1234.ts.net", ["100.64.0.99"], false),
            ("worker-9.tail1234.ts.net", ["100.96.100.130"], false), ("worker-3.tail0.ts.net", ["100.64.0.31"], false),
            ("worker-3.tail1234.ts.net", ["100.64.0.31"], true), ("", ["100.64.0.31"], false), ("worker-3", ["100.64.0.31"], false),
        ]
        let statuses = [reachStatus, reachStatus.replacingOccurrences(of: "\"Running\"", with: "\"Stopped\""),
                        reachStatus.replacingOccurrences(of: "\"Online\": true", with: "\"Online\": false"), "not json"]
        var rules: [[String: Any]] = []
        for status in statuses {
            for (name, addresses, locked) in devices {
                let device = JoinedDevice(name: name, addresses: addresses, locked: locked)
                rules.append(["status": status, "name": name, "addresses": addresses, "locked": locked,
                              "keeps": FleetReach.keeps(device, from: status)])
            }
        }
        return rules
    }

    static func words() -> [String: Any] {
        let errors: [FleetKeyError] = [.notAnAccessToken, .tokenNotAccepted, .roleCannotWrite, .rateLimited, .unreachable,
                                       .refused("an example refusal"), .notUnderstood, .policyChangedMeanwhile, .noFleetKey,
                                       .fleetKeyEnded]
        let places: [(String, PolicyPlace?)] = [
            ("none", nil), ("tailscale", .tailscale), ("tool", .tool(nil)),
            ("tool https://github.com/example/tailnet-policy/", .tool(URL(string: "https://github.com/example/tailnet-policy/"))),
            ("tool https://user:pw@git.example.com:8443/a/b.hujson?x=1#y",
             .tool(URL(string: "https://user:pw@git.example.com:8443/a/b.hujson?x=1#y"))),
            ("tool https://example.com/a%20b", .tool(URL(string: "https://example.com/a%20b"))),
            ("tool https://example.com/" + String(repeating: "a", count: 90),
             .tool(URL(string: "https://example.com/" + String(repeating: "a", count: 90)))),
        ]
        return [
            "errors": errors.map(fleetKeyError),
            "places": places.map { name, place -> [String: Any] in
                ["place": name, "address": place?.address as Any? ?? NSNull(), "tag_ask": place?.tagAsk as Any? ?? NSNull(),
                 "hidden": FleetReach.hidden("worker-3", hub: false, place: place),
                 "hidden_hub": FleetReach.hidden("hub-1", hub: true, place: place),
                 "unreached": FleetReach.unreached("worker-3", port: "22", place: place)]
            },
            "unseen": FleetReach.unseen("worker-3"),
            "tokens": ["", "  \(token)\n", "tskey-api-has space", "tskey-auth-kAbc1234CNTRL-xyz", "tskey-api-a",
                       "tskey-api-" + String(repeating: "a", count: 246), "tskey-api-" + String(repeating: "a", count: 246) + "b"]
                .map { pasted -> [String: Any] in
                    ["pasted": pasted, "token": (try? TailscaleFleetKey.checkedToken(pasted)) as Any? ?? NSNull()]
                },
            "descriptions": ["worker-3", "", "émile_é.x", "a-very-long-server-name-with-more-than-fifty-characters-in-it"]
                .map { ["hostname": $0, "description": TailscaleFleetKey.keyDescription($0)] },
            "auth_keys": [authKey, "tskey-auth-", "tskey-auth-x y", "tskey-client-x", "tskey-auth-" + String(repeating: "a", count: 502)]
                .map { ["key": $0, "is": TailscaleFleetKey.isAuthKey($0)] },
            "device_ids": ["nBBBB2CNTRL", "1002", "", "../keys", "a b", String(repeating: "a", count: 64),
                           String(repeating: "a", count: 65), "ünicode"]
                .map { ["id": $0, "is": TailscaleFleetKey.isDeviceID($0)] },
            "constants": ["tag": TailscaleFleetKey.tag, "keys_page": TailscaleFleetKey.keysPage.absoluteString,
                          "ports": TailscaleFleetKey.ports, "hub_ports": TailscaleFleetKey.hubPorts,
                          "owners": TailscaleFleetKey.owners, "scopes": TailscaleFleetKey.scopes,
                          "client_description": TailscaleFleetKey.clientDescription,
                          "key_life_seconds": TailscaleFleetKey.keyLifeSeconds, "join_key_life": CloudServers.joinKeyLife,
                          "tag_line": FleetPolicy.tagLine, "grants": FleetPolicy.grants.map(\.text)],
        ]
    }

    static func document() async throws -> Data {
        var made: [[String: Any]] = []
        for one in cases() {
            let (result, error, kept) = await run(one)
            made.append(["name": one.name, "call": one.call, "held": one.held as Any? ?? NSNull(), "refuses": one.refuses,
                         "answers": one.stand.answers, "requests": one.stand.requests(hiding: secrets),
                         "result": result, "error": error as Any? ?? NSNull(), "kept": kept as Any? ?? NSNull()])
        }
        let document: [String: Any] = [
            "about": "Tailscale's API as FleetCore's TailscaleFleetKey calls it: for each case the stand-in's answers (by method "
                + "and path, in order, the last one again for each later request, and 404 for a path that has none; status "
                + "-1 is a connection that fails), each request sent (its secrets by name), what it gave or threw, and what "
                + "it kept. Then the policy file's rules (FleetPolicy), this Mac's own Tailscale (MacNetwork.reading, "
                + "device(of:in:), FleetOnTailscale), FleetReach.keeps, and the English words.",
            "made_by": "app/Tests/FleetCoreTests/TailscaleVectorsTests.swift", "secrets": secrets, "cases": made,
            "policies": policyRules(), "network": networkRules(), "reach": reachRules(), "words": words(),
        ]
        return try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            + Data("\n".utf8)
    }

    @Test("Tailscale's vectors are what FleetCore gives now")
    func theTailscaleVectorsAreTheCommittedFile() async throws {
        let made = try await Localized.$bundle.withValue(WordsVectorsTests.noTable) { try await Self.document() }
        try VectorStand.writeOrCompare(made, Self.file)
    }
}

/// **A stand-in for a provider whose answers are kept in order**, for the vectors of `TailscaleVectorsTests` and
/// `CloudVectorsTests`: the answers it was given, and the requests that reached it as the vectors hold them.
final class VectorStand: @unchecked Sendable {
    let stand = ProviderStandIn()
    private(set) var answers: [[String: Any]] = []

    /// One more answer for `method` and `path`, as `ProviderStandIn.answer` gives it.
    func answer(_ method: String, _ path: String, _ status: Int, _ body: String = "{}", headers: [String: String] = [:]) {
        stand.answer(method, path, status, body, headers: headers)
        answers.append(["method": method, "path": path, "status": status, "body": body, "headers": headers])
    }

    /// No answers for `method` and `path` any more, here and in the stand-in, so the next ones given are the only ones.
    func clear(_ method: String, _ path: String) {
        stand.clear(method, path)
        answers.removeAll { $0["method"] as? String == method && $0["path"] as? String == path }
    }

    /// Each request that reached the stand-in: its method, its address, its headers and its body as text, with each
    /// secret by its name and each part made of chance by its own name (`chance`: a pattern and what stands for it).
    func requests(hiding secrets: [String: String], chance: [(String, String)] = []) -> [[String: Any]] {
        stand.calls.map { call in
            func shown(_ text: String) -> String { VectorStand.shown(text, hiding: secrets, chance: chance) }
            return ["method": call.method, "url": shown(call.url.absoluteString),
                    "headers": call.headers.mapValues(shown), "body": shown(call.body)]
        }
    }

    /// A text with each secret by its name, the longest first, and each part made of chance by its name.
    static func shown(_ text: String, hiding secrets: [String: String], chance: [(String, String)] = []) -> String {
        var shown = text
        for (name, secret) in secrets.sorted(by: { $0.value.count > $1.value.count }) where !secret.isEmpty {
            shown = shown.replacingOccurrences(of: secret, with: name)
        }
        for (pattern, name) in chance {
            shown = shown.replacingOccurrences(of: pattern, with: name, options: .regularExpression)
        }
        return shown
    }

    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("vectors")

    /// With `FOUNDERIZER_VECTORS_OUT` set, writes the file there; without it, holds the committed file equal to `made`.
    static func writeOrCompare(_ made: Data, _ file: String) throws {
        if let out = ProcessInfo.processInfo.environment["FOUNDERIZER_VECTORS_OUT"] {
            try made.write(to: URL(fileURLWithPath: out).appendingPathComponent(file))
            return
        }
        let committed = try Data(contentsOf: folder.appendingPathComponent(file))
        #expect(committed == made, "app/vectors/\(file) is not what FleetCore gives: run app/vectors/make_vectors.py")
    }
}
