import Foundation
import Testing
@testable import FleetCore

/// **The vectors of the cloud providers' APIs as FleetCore calls them** (`app/vectors/cloud-requests.json`;
/// windows-app-plan-v2.md, section 5.6, piece L2): for Hetzner, DigitalOcean, Vultr and Akamai, each fixed case with the
/// answers that a stand-in for the provider gives, each request that `CloudServers` sends, what it gives back or the
/// error it throws, and the token it keeps. Beside them the pure rules: the first boot's cloud-init (`userData`), the
/// locations nearest a time zone, a pasted token, this app's SSH key and its fingerprint, the names and ids, the words
/// of each error, of an offer and of a server, and which stop asks for the token again. The Windows app's library
/// (`windows/Founderizer.Setup/Cloud`) sends the same requests and reads the same answers: its tests hold them equal to
/// this file.
///
/// The token and the auth key stand in a request by their names in braces. A firewall's six letters of chance and
/// Akamai's root password are made of chance, so they stand by their names too. Every value is an example.
///
/// With `FOUNDERIZER_VECTORS_OUT` set, the test writes the file into that folder (`app/vectors/make_vectors.py` does,
/// and its `--check` compares); without it, the test holds the committed file equal to what FleetCore gives now.
struct CloudVectorsTests {
    static let file = "cloud-requests.json"

    static let token = "notarealtoken0123456789notarealtoken0123456789notarealtoken0123"
    /// A key made with `ssh-keygen -t ed25519`, whose private half was thrown away (`CloudServersTests`).
    static let publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAo/DN+NoNbdAzU3DYGLTD7ne5vXT9bm+oEyoiacxwWg founderizer-test"
    static let fingerprint = "72:10:e7:12:0f:70:ca:e3:25:aa:b4:7c:4c:b1:75:24"
    static let authKey = "tskey-auth-kAUTH1234CNTRL-notarealkey"
    static let secrets = ["{token}": token, "{auth key}": authKey]
    /// The parts made of chance: a firewall's six letters, and Akamai's root password.
    static let chance = [("(founderizer|fz)-(hub-1|worker-1)-[a-z0-9]{6}", "$1-$2-{chance}"),
                         ("\"root_pass\":\"[^\"]{32}\"", "\"root_pass\":\"{root password}\"")]
    /// Berlin's time: one hour from UTC in standard time.
    static let zone = TimeZone(identifier: "Europe/Berlin")!

    struct Case {
        let name: String
        let provider: CloudProvider
        let call: [String: Any]
        var held: String? = CloudVectorsTests.token
        let stand: VectorStand
    }

    static func make(_ name: String = "hub-1", use: String = "hub", key: String = publicKey, auth: String = authKey,
                     offer: [String: Any]? = nil) -> [String: Any] {
        ["do": "make", "name": name, "use": use, "public_key": key, "auth_key": auth, "offer": offer as Any? ?? NSNull()]
    }

    // MARK: - Hetzner

    static let hetznerKeys = "{\"ssh_keys\":[{\"id\":42,\"name\":\"founderizer-7210e7120f70\",\"fingerprint\":\"\(fingerprint)\","
        + "\"public_key\":\"\(publicKey)\",\"labels\":{}}],\"meta\":{\"pagination\":{\"page\":1}}}"

    static func hetznerType(_ name: String, free: [String], taken: [String] = [], memory: Double = 4, disk: Int = 40,
                            architecture: String = "x86", monthly: String = "4.1531", deprecated: Bool = false,
                            cpuType: String = "shared") -> String {
        let locations = (free.map { "{\"id\":1,\"name\":\"\($0)\",\"deprecation\":null,\"available\":true}" }
            + taken.map { "{\"id\":2,\"name\":\"\($0)\",\"deprecation\":null,\"available\":false}" }).joined(separator: ",")
        let prices = ["fsn1", "nbg1", "hel1"].map {
            "{\"location\":\"\($0)\",\"price_monthly\":{\"net\":\"3.4900\",\"gross\":\"\(monthly)\"}}"
        }.joined(separator: ",")
        let deprecation = deprecated ? "{\"announced\":\"2026-01-01T00:00:00+00:00\"}" : "null"
        return "{\"id\":114,\"name\":\"\(name)\",\"cores\":2,\"memory\":\(memory),\"disk\":\(disk),\"cpu_type\":\"\(cpuType)\","
            + "\"architecture\":\"\(architecture)\",\"deprecation\":\(deprecation),\"prices\":[\(prices)],\"locations\":[\(locations)]}"
    }

    static func hetznerTypes(_ types: String...) -> String {
        "{\"server_types\":[\(types.joined(separator: ","))],\"meta\":{\"pagination\":{\"page\":1}}}"
    }

    static let hetznerPricing = "{\"pricing\":{\"currency\":\"EUR\",\"primary_ips\":["
        + "{\"type\":\"ipv4\",\"prices\":[{\"location\":\"fsn1\",\"price_monthly\":{\"net\":\"0.5000\",\"gross\":\"0.5950\"}},"
        + "{\"location\":\"nbg1\",\"price_monthly\":{\"net\":\"0.5000\",\"gross\":\"0.5950\"}},"
        + "{\"location\":\"hel1\",\"price_monthly\":{\"net\":\"0.5000\",\"gross\":\"0.6100\"}}]},"
        + "{\"type\":\"ipv6\",\"prices\":[{\"location\":\"fsn1\",\"price_monthly\":{\"net\":\"0.4200\",\"gross\":\"0.4998\"}},"
        + "{\"location\":\"nbg1\",\"price_monthly\":{\"net\":\"0.4200\",\"gross\":\"0.4998\"}},"
        + "{\"location\":\"hel1\",\"price_monthly\":{\"net\":\"0.4200\",\"gross\":\"0.5100\"}}]}]}}"

    static let hetznerServer = "{\"server\":{\"id\":1001,\"name\":\"hub-1\",\"status\":\"initializing\",\"public_net\":"
        + "{\"ipv4\":{\"id\":5,\"ip\":\"203.0.113.10\"},\"ipv6\":null}},"
        + "\"action\":{\"id\":501,\"command\":\"create_server\",\"status\":\"running\",\"error\":null}}"

    static let manyTypes = hetznerTypes(
        hetznerType("cx23", free: [], taken: ["fsn1", "nbg1", "hel1"], monthly: "5.4900"),
        hetznerType("cpx22", free: ["fsn1", "nbg1", "hel1"], monthly: "19.4900"),
        hetznerType("cpx12", free: ["hel1", "nbg1"], memory: 2, monthly: "11.4900"),
        hetznerType("cpx02", free: ["hel1", "nbg1"], memory: 1, disk: 20, monthly: "5.9900"),
        hetznerType("small", free: ["fsn1"], memory: 0.5, monthly: "1.0000"),
        hetznerType("old", free: ["fsn1"], monthly: "2.0000", deprecated: true),
        hetznerType("other", free: ["fsn1"], architecture: "riscv", monthly: "3.0000"),
        hetznerType("tiny-disk", free: ["fsn1"], disk: 19, monthly: "2.5000"),
        hetznerType("ccx13", free: ["nbg1"], memory: 8, monthly: "36.4900", cpuType: "dedicated"))

    /// A Hetzner project that answers everything, with cx23 free in Falkenstein and Nuremberg.
    static func hetzner(keys: String? = hetznerKeys) -> VectorStand {
        let hetzner = VectorStand()
        if let keys { hetzner.answer("GET", "/v1/ssh_keys", 200, keys) }
        hetzner.answer("GET", "/v1/pricing", 200, hetznerPricing)
        hetzner.answer("GET", "/v1/server_types", 200, hetznerTypes(
            hetznerType("cx23", free: ["fsn1", "nbg1"], taken: ["hel1"]),
            hetznerType("cax11", free: ["fsn1"], architecture: "arm", monthly: "4.7600")))
        hetzner.answer("POST", "/v1/firewalls", 201, "{\"firewall\":{\"id\":77,\"name\":\"x\",\"rules\":[]},\"actions\":[]}")
        return hetzner
    }

    static func hetznerMade(_ hetzner: VectorStand) {
        hetzner.answer("POST", "/v1/servers", 201, hetznerServer)
        hetzner.answer("GET", "/v1/actions/501", 200, "{\"action\":{\"id\":501,\"status\":\"running\"}}")
        hetzner.answer("GET", "/v1/actions/501", ProviderStandIn.dropped)
        hetzner.answer("GET", "/v1/actions/501", 429, "{\"error\":{\"code\":\"rate_limit_exceeded\",\"message\":\"limit\"}}")
        hetzner.answer("GET", "/v1/actions/501", 200, "{\"action\":{\"id\":501,\"status\":\"success\",\"error\":null}}")
    }

    static func hetznerCases() -> [Case] {
        var cases: [Case] = []
        func add(_ name: String, _ call: [String: Any], held: String? = token, _ stand: VectorStand) {
            cases.append(Case(name: "Hetzner: " + name, provider: .hetzner, call: call, held: held, stand: stand))
        }
        let checked = VectorStand()
        checked.answer("GET", "/v1/locations", 200, "{\"locations\":[{\"id\":1,\"name\":\"fsn1\"}]}")
        checked.answer("POST", "/v1/ssh_keys", 422, "{\"error\":{\"code\":\"invalid_input\",\"message\":\"invalid input\"}}")
        add("a token that may write is kept", ["do": "check_token", "token": "  \(token)\n"], held: nil, checked)
        for (status, code) in [(403, "forbidden"), (401, "token_readonly")] {
            let reader = VectorStand()
            reader.answer("GET", "/v1/locations", 200, "{\"locations\":[]}")
            reader.answer("POST", "/v1/ssh_keys", status, "{\"error\":{\"code\":\"\(code)\",\"message\":\"insufficient permissions\"}}")
            add("a token that may only read (\(code))", ["do": "check_token", "token": token], held: nil, reader)
        }
        let wrong = VectorStand()
        wrong.answer("GET", "/v1/locations", 401, "{\"error\":{\"code\":\"unauthorized\",\"message\":\"unable to authenticate\"}}")
        add("a token that Hetzner does not take", ["do": "check_token", "token": token], held: nil, wrong)
        let busy = VectorStand()
        busy.answer("GET", "/v1/locations", 429, "{\"error\":{\"code\":\"rate_limit_exceeded\",\"message\":\"limit\"}}")
        add("Hetzner asks to wait", ["do": "check_token", "token": token], held: nil, busy)
        let down = VectorStand()
        down.answer("GET", "/v1/locations", ProviderStandIn.dropped)
        add("Hetzner cannot be reached", ["do": "check_token", "token": token], held: nil, down)
        for pasted in ["", "short", "has spaces in it that make it no token", authKey] {
            add("not a token: \(pasted.prefix(12))", ["do": "check_token", "token": pasted], held: nil, VectorStand())
        }

        let offers = hetzner()
        offers.clear("GET", "/v1/server_types")
        offers.answer("GET", "/v1/server_types", 200, manyTypes)
        add("every type that fits a hub, cheapest first and nearest at one price", ["do": "offers", "use": "hub", "except": [String]()], offers)
        let agents = hetzner()
        agents.clear("GET", "/v1/server_types")
        agents.answer("GET", "/v1/server_types", 200, manyTypes)
        add("a taken place gives its type's next place", ["do": "offers", "use": "agent", "except": ["cpx12@nbg1"]], agents)
        let noRoom = hetzner()
        noRoom.clear("GET", "/v1/server_types")
        noRoom.answer("GET", "/v1/server_types", 200, hetznerTypes(hetznerType("cx23", free: [], taken: ["fsn1"])))
        add("no type free", ["do": "offers", "use": "hub", "except": [String]()], noRoom)

        let made = hetzner()
        hetznerMade(made)
        add("a server near this computer behind a firewall that lets nothing in", make(), made)
        let registered = hetzner(keys: "{\"ssh_keys\":[],\"meta\":{\"pagination\":{\"page\":1}}}")
        registered.answer("POST", "/v1/ssh_keys", 201, "{\"ssh_key\":{\"id\":43,\"fingerprint\":\"\(fingerprint)\"}}")
        hetznerMade(registered)
        add("this app's key is registered once", make(use: "agent"), registered)
        let race = hetzner(keys: nil)
        race.answer("GET", "/v1/ssh_keys", 200, "{\"ssh_keys\":[]}")
        race.answer("GET", "/v1/ssh_keys", 200, hetznerKeys)
        race.answer("POST", "/v1/ssh_keys", 409, "{\"error\":{\"code\":\"uniqueness_error\",\"message\":\"same fingerprint\"}}")
        hetznerMade(race)
        add("a key registered meanwhile is found again", make(), race)
        let raced = hetzner()
        raced.answer("POST", "/v1/servers", 412, "{\"error\":{\"code\":\"resource_unavailable\",\"message\":\"server type unavailable\"}}")
        raced.answer("POST", "/v1/servers", 201, hetznerServer)
        raced.answer("GET", "/v1/actions/501", 200, "{\"action\":{\"id\":501,\"status\":\"success\"}}")
        add("a place taken since it was read: the next offer behind the same firewall", make(), raced)
        let failed = hetzner()
        failed.answer("POST", "/v1/servers", 201, hetznerServer)
        failed.answer("GET", "/v1/actions/501", 200, "{\"action\":{\"id\":501,\"status\":\"error\","
                      + "\"error\":{\"code\":\"action_failed\",\"message\":\"the server could not be started\"}}}")
        failed.answer("DELETE", "/v1/servers/1001", 200, "{\"action\":{\"id\":601,\"command\":\"delete_server\",\"status\":\"running\"}}")
        failed.answer("GET", "/v1/actions/601", 200, "{\"action\":{\"id\":601,\"status\":\"success\"}}")
        failed.answer("DELETE", "/v1/firewalls/77", 422, "{\"error\":{\"code\":\"resource_in_use\",\"message\":\"firewall still applied\"}}")
        failed.answer("DELETE", "/v1/firewalls/77", 204, "")
        add("a server that fails is taken back, and the key stays", make(), failed)
        // A fault answer of Hetzner's own: the servers behind the call's firewall are read first, and the one there goes,
        // then the firewall.
        let fault = hetzner()
        fault.answer("POST", "/v1/servers", 503, "{\"error\":{\"code\":\"unavailable\",\"message\":\"service unavailable\"}}")
        fault.answer("GET", "/v1/firewalls/77", 200, "{\"firewall\":{\"id\":77,\"applied_to\":[{\"type\":\"server\","
                     + "\"server\":{\"id\":1001}},{\"type\":\"server\",\"server\":{\"id\":1002}}]}}")
        fault.answer("GET", "/v1/servers", 200, "{\"servers\":[{\"id\":1001,\"name\":\"hub-1\"},{\"id\":1002,\"name\":\"hub-10\"}]}")
        fault.answer("DELETE", "/v1/servers/1001", 200, "{\"action\":{\"id\":601,\"command\":\"delete_server\",\"status\":\"running\"}}")
        fault.answer("GET", "/v1/actions/601", 200, "{\"action\":{\"id\":601,\"status\":\"success\"}}")
        fault.answer("DELETE", "/v1/firewalls/77", 204, "")
        add("a fault answer to the server: the server behind the call's firewall goes, then the firewall", make(), fault)
        // A success to the call for the server with no id that this app reads: read as after a fault answer.
        let noID = hetzner()
        noID.answer("POST", "/v1/servers", 201, "{\"server\":{\"name\":\"hub-1\"}}")
        noID.answer("GET", "/v1/firewalls/77", 200, "{\"firewall\":{\"id\":77,\"applied_to\":[{\"type\":\"server\","
                    + "\"server\":{\"id\":1001}}]}}")
        noID.answer("GET", "/v1/servers", 200, "{\"servers\":[{\"id\":1001,\"name\":\"hub-1\"}]}")
        noID.answer("DELETE", "/v1/servers/1001", 200, "{\"action\":{\"id\":601,\"command\":\"delete_server\",\"status\":\"running\"}}")
        noID.answer("GET", "/v1/actions/601", 200, "{\"action\":{\"id\":601,\"status\":\"success\"}}")
        noID.answer("DELETE", "/v1/firewalls/77", 204, "")
        add("a success with no id to the server: the server of its name behind the call's firewall goes, then the firewall",
            make(), noID)
        // No answer at all to the call for the server: none behind its firewall now, nor in the reads after it, so
        // nothing is taken back and the firewall stays.
        let lost = hetzner()
        lost.answer("POST", "/v1/servers", ProviderStandIn.dropped)
        lost.answer("GET", "/v1/firewalls/77", 200, "{\"firewall\":{\"id\":77,\"applied_to\":[]}}")
        add("no answer to the server and none behind its firewall: nothing is taken back", make(), lost)
        // Hetzner refuses to delete a server that it is still making (locked): the deletion is asked again.
        let locked = hetzner()
        locked.answer("POST", "/v1/servers", 503, "{\"error\":{\"code\":\"unavailable\",\"message\":\"service unavailable\"}}")
        locked.answer("GET", "/v1/firewalls/77", 200, "{\"firewall\":{\"id\":77,\"applied_to\":[{\"type\":\"server\","
                      + "\"server\":{\"id\":1001}}]}}")
        locked.answer("GET", "/v1/servers", 200, "{\"servers\":[{\"id\":1001,\"name\":\"hub-1\"}]}")
        locked.answer("DELETE", "/v1/servers/1001", 423, "{\"error\":{\"code\":\"locked\",\"message\":\"server is locked\"}}")
        locked.answer("DELETE", "/v1/servers/1001", 200, "{\"action\":{\"id\":601,\"command\":\"delete_server\",\"status\":\"running\"}}")
        locked.answer("GET", "/v1/actions/601", 200, "{\"action\":{\"id\":601,\"status\":\"success\"}}")
        locked.answer("DELETE", "/v1/firewalls/77", 204, "")
        add("a server found while Hetzner still makes it: its deletion is asked again while locked", make(), locked)
        // A gateway's own page of HTML is said by its status, not as its text.
        let page = hetzner()
        page.answer("POST", "/v1/servers", 502, "<html><body><h1>502 Bad Gateway</h1></body></html>")
        page.answer("GET", "/v1/firewalls/77", 200, "{\"firewall\":{\"id\":77,\"applied_to\":[]}}")
        add("a gateway's page of HTML is said by its status", make(), page)
        let full = hetzner()
        full.answer("POST", "/v1/servers", 422, "{\"error\":{\"code\":\"placement_error\",\"message\":\"no capacity\"}}")
        full.answer("DELETE", "/v1/firewalls/77", 204, "")
        add("none free anywhere: the firewall goes", make(), full)
        let limit = hetzner()
        limit.answer("POST", "/v1/servers", 403, "{\"error\":{\"code\":\"resource_limit_exceeded\",\"message\":\"server limit reached\"}}")
        limit.answer("DELETE", "/v1/firewalls/77", 204, "")
        add("the account's limit of servers", make(), limit)
        let left = hetzner()
        left.answer("POST", "/v1/servers", 201, hetznerServer)
        left.answer("GET", "/v1/actions/501", 200, "{\"action\":{\"id\":501,\"status\":\"error\",\"error\":{\"message\":\"boom\"}}}")
        left.answer("DELETE", "/v1/servers/1001", 500, "{\"error\":{\"code\":\"server_error\",\"message\":\"later\"}}")
        left.answer("DELETE", "/v1/firewalls/77", 422, "{\"error\":{\"code\":\"resource_in_use\",\"message\":\"still applied\"}}")
        add("what cannot be deleted is said", make(), left)
        let chosen = hetzner()
        chosen.answer("POST", "/v1/servers", 412, "{\"error\":{\"code\":\"resource_unavailable\",\"message\":\"unavailable\"}}")
        chosen.answer("DELETE", "/v1/firewalls/77", 204, "")
        add("the server that the owner said yes to is taken",
            make(offer: ["type": "cx23", "location": "nbg1", "price": "4.7481", "currency": "EUR", "cores": 2, "memory_gb": 4.0,
                         "disk_gb": 40, "dedicated": false]), chosen)
        let gone = hetzner()
        add("the server that the owner said yes to is no longer offered",
            make(offer: ["type": "cx99", "location": "fsn1", "price": "1", "currency": "EUR", "cores": NSNull(),
                         "memory_gb": NSNull(), "disk_gb": NSNull(), "dedicated": false]), gone)
        add("a name that is not one", make("Hub_1"), VectorStand())
        add("a key that is not one", make(key: "ssh-dss AAAA x"), VectorStand())
        add("an auth key that is not one", make(auth: "tskey-client-x"), VectorStand())
        add("no token held", make(), held: nil, VectorStand())

        let listed = VectorStand()
        listed.answer("GET", "/v1/servers", 200, "{\"servers\":["
            + "{\"id\":11,\"name\":\"web-1\",\"status\":\"running\",\"public_net\":{\"ipv4\":{\"ip\":\"203.0.113.20\"}},"
            + "\"server_type\":{\"name\":\"cpx22\",\"cores\":2,\"memory\":4.0,\"disk\":80},"
            + "\"image\":{\"os_flavor\":\"ubuntu\",\"os_version\":\"24.04\"},\"location\":{\"name\":\"nbg1\",\"city\":\"Nuremberg\"},"
            + "\"labels\":{}},"
            + "{\"id\":12,\"name\":\"old\",\"status\":\"off\",\"public_net\":{\"ipv4\":null},\"server_type\":{\"name\":\"cx11\","
            + "\"memory\":1.5},\"image\":null,\"datacenter\":{\"location\":{\"city\":\"Falkenstein\"}},\"labels\":{}},"
            + "{\"name\":\"no id\"}],"
            + "\"meta\":{\"pagination\":{\"page\":1,\"next_page\":2}}}")
        listed.answer("GET", "/v1/servers", 200, "{\"servers\":["
            + "{\"id\":13,\"name\":\"worker-1\",\"status\":\"running\",\"public_net\":{\"ipv4\":{\"ip\":\"203.0.113.300\"}},"
            + "\"server_type\":{\"name\":\"cx23\",\"memory\":4},\"image\":{\"os_flavor\":\"Ubuntu\",\"os_version\":\"24.04\"},"
            + "\"location\":{\"city\":\"Nuremberg\"},\"labels\":{\"founderizer\":\"hub\"}}],"
            + "\"meta\":{\"pagination\":{\"page\":2,\"next_page\":null}}}")
        add("the project's servers, page by page", ["do": "servers"], listed)

        let deleted = VectorStand()
        deleted.answer("DELETE", "/v1/servers/1001", 200, "{\"action\":{\"id\":601,\"status\":\"running\"}}")
        deleted.answer("GET", "/v1/actions/601", 200, "{\"action\":{\"id\":601,\"status\":\"running\"}}")
        deleted.answer("GET", "/v1/actions/601", 200, "{\"action\":{\"id\":601,\"status\":\"success\"}}")
        add("one server deleted by its id, its action read to its end", ["do": "delete_server", "id": "1001"], deleted)
        let notThere = VectorStand()
        notThere.answer("DELETE", "/v1/servers/1001", 404, "{\"error\":{\"code\":\"not_found\",\"message\":\"server not found\"}}")
        add("a server that the token does not see", ["do": "delete_server", "id": "1001"], notThere)
        let actionError = VectorStand()
        actionError.answer("DELETE", "/v1/servers/1001", 200, "{\"action\":{\"id\":601}}")
        actionError.answer("GET", "/v1/actions/601", 200, "{\"action\":{\"id\":601,\"status\":\"error\",\"error\":{\"code\":\"locked\"}}}")
        add("a deletion whose action ends with an error", ["do": "delete_server", "id": "1001"], actionError)
        let stillThere = VectorStand()
        stillThere.answer("DELETE", "/v1/servers/1001", 200, "{\"action\":{\"id\":601}}")
        stillThere.answer("GET", "/v1/actions/601", 200, "{\"action\":{\"id\":601,\"status\":\"running\"}}")
        stillThere.answer("GET", "/v1/servers/1001", 404, "{\"error\":{\"code\":\"not_found\"}}")
        add("a deletion still running after every read, settled by one read of the server",
            ["do": "delete_server", "id": "1001"], stillThere)
        add("an id that may not stand in a path", ["do": "delete_server", "id": "10/01"], VectorStand())

        let walls = VectorStand()
        walls.answer("GET", "/v1/firewalls", 200, "{\"firewalls\":["
            + "{\"id\":77,\"name\":\"founderizer-hub-1-abc123\",\"labels\":{\"founderizer\":\"hub\"},"
            + "\"applied_to\":[{\"type\":\"server\",\"server\":{\"id\":1001}}]},"
            + "{\"id\":78,\"name\":\"founderizer-hub-1-zzz999\",\"labels\":{\"founderizer\":\"hub\"},"
            + "\"applied_to\":[{\"type\":\"label_selector\",\"label_selector\":{\"selector\":\"x\"}}]},"
            + "{\"id\":79,\"name\":\"founderizer-hub-10-abc123\",\"labels\":{\"founderizer\":\"hub\"},\"applied_to\":[]},"
            + "{\"id\":80,\"name\":\"founderizer-hub-1-abc123\",\"labels\":{},\"applied_to\":[]}],"
            + "\"meta\":{\"pagination\":{\"page\":1,\"next_page\":null}}}")
        add("the firewalls that this app made for a server", ["do": "firewalls", "name": "hub-1"], walls)
        let wallsGo = VectorStand()
        for answer in walls.answers {
            wallsGo.answer(answer["method"] as! String, answer["path"] as! String, answer["status"] as! Int, answer["body"] as! String)
        }
        wallsGo.answer("DELETE", "/v1/firewalls/77", 422, "{\"error\":{\"code\":\"resource_in_use\",\"message\":\"in use\"}}")
        wallsGo.answer("DELETE", "/v1/firewalls/77", 204, "")
        wallsGo.answer("DELETE", "/v1/firewalls/78", 204, "")
        add("each firewall of a deleted server goes, asked again while in use",
            ["do": "delete_firewalls", "name": "hub-1", "deleted": ["1001"]], wallsGo)
        let keyGone = VectorStand()
        keyGone.answer("GET", "/v1/ssh_keys", 200, hetznerKeys)
        keyGone.answer("DELETE", "/v1/ssh_keys/42", 204, "")
        add("this app's key deleted by its fingerprint", ["do": "delete_key", "public_key": publicKey], keyGone)
        let noKey = VectorStand()
        noKey.answer("GET", "/v1/ssh_keys", 200, "{\"ssh_keys\":[]}")
        add("no key of this app's: nothing is deleted", ["do": "delete_key", "public_key": publicKey], noKey)

        // Ids above 32 bits: Hetzner gives them since 1 September 2023 (an action id of 504538401287250 was reported in
        // September 2024), and Swift's Int is 64 bits.
        let wide = VectorStand()
        wide.answer("GET", "/v1/ssh_keys", 200, hetznerKeys.replacingOccurrences(of: "\"id\":42", with: "\"id\":3000000042"))
        wide.answer("GET", "/v1/pricing", 200, hetznerPricing)
        wide.answer("GET", "/v1/server_types", 200, hetznerTypes(hetznerType("cx23", free: ["fsn1"])))
        wide.answer("POST", "/v1/firewalls", 201, "{\"firewall\":{\"id\":4294967373,\"name\":\"x\",\"rules\":[]}}")
        wide.answer("POST", "/v1/servers", 201, "{\"server\":{\"id\":504538401287250,\"name\":\"hub-1\",\"public_net\":"
                    + "{\"ipv4\":{\"ip\":\"203.0.113.10\"}}},\"action\":{\"id\":504538401287251,\"status\":\"running\"}}")
        wide.answer("GET", "/v1/actions/504538401287251", 200, "{\"action\":{\"id\":504538401287251,\"status\":\"success\"}}")
        add("a server, a firewall, a key and an action with ids above 32 bits", make(), wide)
        let wideList = VectorStand()
        wideList.answer("GET", "/v1/servers", 200, "{\"servers\":[{\"id\":504538401287250,\"name\":\"hub-1\",\"status\":\"running\","
                        + "\"public_net\":{\"ipv4\":{\"ip\":\"203.0.113.10\"}},\"server_type\":{\"name\":\"cx23\",\"memory\":4},"
                        + "\"labels\":{\"founderizer\":\"hub\"}}],\"meta\":{\"pagination\":{\"page\":1,\"next_page\":null}}}")
        add("a server with an id above 32 bits is listed", ["do": "servers"], wideList)
        let wideDelete = VectorStand()
        wideDelete.answer("DELETE", "/v1/servers/504538401287250", 200, "{\"action\":{\"id\":504538401287252,\"status\":\"running\"}}")
        wideDelete.answer("GET", "/v1/actions/504538401287252", 200, "{\"action\":{\"id\":504538401287252,\"status\":\"running\"}}")
        wideDelete.answer("GET", "/v1/actions/504538401287252", 200, "{\"action\":{\"id\":504538401287252,\"status\":\"success\"}}")
        add("a deletion whose action has an id above 32 bits is read to its end", ["do": "delete_server", "id": "504538401287250"], wideDelete)
        let wideWalls = VectorStand()
        wideWalls.answer("GET", "/v1/firewalls", 200, "{\"firewalls\":[{\"id\":4294967373,\"name\":\"founderizer-hub-1-abc123\","
                         + "\"labels\":{\"founderizer\":\"hub\"},\"applied_to\":[{\"type\":\"server\",\"server\":{\"id\":504538401287250}}]}],"
                         + "\"meta\":{\"pagination\":{\"page\":1,\"next_page\":null}}}")
        add("a firewall and its server with ids above 32 bits", ["do": "firewalls", "name": "hub-1"], wideWalls)
        return cases
    }

    // MARK: - DigitalOcean

    static let droplet = "/v2/droplets/3164444"
    static let oceanFirewall = "bb4b2611-3d72-467b-8602-280330ecd65c"
    static let oceanSizes = "{\"sizes\":["
        + "{\"slug\":\"s-1vcpu-1gb\",\"memory\":1024,\"vcpus\":1,\"disk\":25,\"price_monthly\":6,\"regions\":[\"ams3\",\"fra1\",\"lon1\",\"nyc3\",\"sfo3\",\"sgp1\"],\"available\":true},"
        + "{\"slug\":\"s-1vcpu-1gb-amd\",\"memory\":1024,\"vcpus\":1,\"disk\":25,\"price_monthly\":6,\"regions\":[\"fra1\"],\"available\":true},"
        + "{\"slug\":\"s-1vcpu-2gb\",\"memory\":2048,\"vcpus\":1,\"disk\":50,\"price_monthly\":12,\"regions\":[\"ams3\",\"lon1\"],\"available\":true},"
        + "{\"slug\":\"s-2vcpu-4gb\",\"memory\":4096,\"vcpus\":2,\"disk\":80,\"price_monthly\":24.5,\"regions\":[\"fra1\",\"nyc3\"],\"available\":true},"
        + "{\"slug\":\"gpu-h100x1-80gb\",\"memory\":245760,\"vcpus\":20,\"disk\":720,\"price_monthly\":2500,\"regions\":[\"fra1\"],\"available\":true},"
        + "{\"slug\":\"s-1vcpu-512mb-10gb\",\"memory\":512,\"vcpus\":1,\"disk\":10,\"price_monthly\":4,\"regions\":[\"fra1\"],\"available\":true},"
        + "{\"slug\":\"s-old\",\"memory\":2048,\"vcpus\":1,\"disk\":50,\"price_monthly\":1,\"regions\":[\"fra1\"],\"available\":false}"
        + "],\"links\":{},\"meta\":{\"total\":7}}"

    static func digitalOcean() -> VectorStand {
        let ocean = VectorStand()
        ocean.answer("GET", "/v2/account/keys/\(fingerprint)", 404, "{\"id\":\"not_found\",\"message\":\"The resource you were accessing could not be found.\"}")
        ocean.answer("POST", "/v2/account/keys", 201, "{\"ssh_key\":{\"id\":512190,\"fingerprint\":\"\(fingerprint)\",\"name\":\"x\"}}")
        ocean.answer("GET", "/v2/sizes", 200, oceanSizes)
        return ocean
    }

    static func digitalOceanMade(_ ocean: VectorStand) {
        ocean.answer("POST", "/v2/firewalls", 202, "{\"firewall\":{\"id\":\"\(oceanFirewall)\",\"status\":\"waiting\"}}")
        ocean.answer("GET", droplet, 200, "{\"droplet\":{\"id\":3164444,\"status\":\"new\",\"networks\":{\"v4\":[],\"v6\":[]}}}")
        ocean.answer("GET", droplet, 200, "{\"droplet\":{\"id\":3164444,\"status\":\"active\",\"networks\":{\"v4\":["
                     + "{\"ip_address\":\"10.114.0.2\",\"type\":\"private\"},{\"ip_address\":\"198.51.100.7\",\"type\":\"public\"}]}}}")
    }

    static func digitalOceanCases() -> [Case] {
        var cases: [Case] = []
        func add(_ name: String, _ call: [String: Any], held: String? = token, _ stand: VectorStand) {
            cases.append(Case(name: "DigitalOcean: " + name, provider: .digitalOcean, call: call, held: held, stand: stand))
        }
        let checked = VectorStand()
        checked.answer("GET", "/v2/account", 200, "{\"account\":{\"droplet_limit\":10,\"status\":\"active\",\"status_message\":\"\"}}")
        checked.answer("POST", "/v2/account/keys", 422, "{\"id\":\"unprocessable_entity\",\"message\":\"Name is required\"}")
        add("a token that may write is kept", ["do": "check_token", "token": token], held: nil, checked)
        let reader = VectorStand()
        reader.answer("GET", "/v2/account", 200, "{\"account\":{\"status\":\"active\"}}")
        reader.answer("POST", "/v2/account/keys", 403, "{\"id\":\"forbidden\",\"message\":\"You do not have access for the attempted action.\"}")
        add("a token that may only read", ["do": "check_token", "token": token], held: nil, reader)
        let locked = VectorStand()
        locked.answer("GET", "/v2/account", 200, "{\"account\":{\"status\":\"locked\",\"status_message\":\"Billing is overdue.\"}}")
        add("a locked account", ["do": "check_token", "token": token], held: nil, locked)
        let silent = VectorStand()
        silent.answer("GET", "/v2/account", 200, "{\"account\":{\"status\":\"locked\",\"status_message\":\"  \"}}")
        add("a locked account that says nothing", ["do": "check_token", "token": token], held: nil, silent)
        let echo = VectorStand()
        echo.answer("GET", "/v2/account", 500, "{\"id\":\"server_error\",\"message\":\"token \(token) failed\"}")
        add("a refusal in the provider's words, with the token taken out", ["do": "check_token", "token": token], held: nil, echo)

        add("every size that fits a hub", ["do": "offers", "use": "hub", "except": [String]()], digitalOcean())
        add("every size that fits a server for agents", ["do": "offers", "use": "agent", "except": ["s-1vcpu-2gb@ams3"]],
            digitalOcean())
        let made = digitalOcean()
        made.answer("POST", "/v2/droplets", 202, "{\"droplet\":{\"id\":3164444,\"name\":\"hub-1\",\"status\":\"new\"}}")
        digitalOceanMade(made)
        add("a droplet near this computer behind a firewall with no inbound rule", make(), made)
        let busy = digitalOcean()
        busy.clear("GET", "/v2/account/keys/\(fingerprint)")
        busy.answer("GET", "/v2/account/keys/\(fingerprint)", 200, "{\"ssh_key\":{\"id\":512189}}")
        busy.answer("POST", "/v2/droplets", 422, "{\"id\":\"unprocessable_entity\",\"message\":\"Size is not available in this region.\"}")
        busy.answer("POST", "/v2/droplets", 202, "{\"droplet\":{\"id\":3164444,\"status\":\"new\"}}")
        digitalOceanMade(busy)
        add("a size that a region cannot take now: the next offer", make(use: "agent"), busy)
        let none = digitalOcean()
        none.answer("POST", "/v2/droplets", 422, "{\"id\":\"unprocessable_entity\",\"message\":\"Size is not available in this region.\"}")
        add("no region can take any size now", make(), none)
        let chosen = digitalOcean()
        chosen.answer("POST", "/v2/droplets", 422, "{\"id\":\"unprocessable_entity\",\"message\":\"Size is not available in this region.\"}")
        add("the size that the owner said yes to cannot be taken now",
            make(offer: ["type": "s-1vcpu-1gb", "location": "fra1", "price": "6", "currency": "USD", "cores": 1,
                         "memory_gb": 1.0, "disk_gb": 25, "dedicated": false]), chosen)
        let limit = digitalOcean()
        limit.answer("POST", "/v2/droplets", 422, "{\"id\":\"unprocessable_entity\",\"message\":\"creating this droplet will exceed your droplet limit\"}")
        add("the account's limit of droplets", make(), limit)
        let wall = digitalOcean()
        wall.answer("POST", "/v2/droplets", 202, "{\"droplet\":{\"id\":3164444,\"status\":\"new\"}}")
        wall.answer("POST", "/v2/firewalls", 422, "{\"id\":\"unprocessable_entity\",\"message\":\"name is invalid\"}")
        wall.answer("DELETE", droplet, 204, "")
        add("a firewall that is refused takes the droplet back", make(), wall)
        let stuck = digitalOcean()
        stuck.answer("POST", "/v2/droplets", 202, "{\"droplet\":{\"id\":3164444,\"status\":\"new\"}}")
        stuck.answer("POST", "/v2/firewalls", 202, "{\"firewall\":{\"id\":\"\(oceanFirewall)\"}}")
        stuck.answer("GET", droplet, 200, "{\"droplet\":{\"id\":3164444,\"status\":\"new\",\"networks\":{\"v4\":[]}}}")
        stuck.answer("DELETE", droplet, 204, "")
        stuck.answer("DELETE", "/v2/firewalls/\(oceanFirewall)", 204, "")
        add("a droplet that never runs is deleted with its firewall", make(), stuck)
        // A fault answer of DigitalOcean's own: the droplets with the call's tag are read, and the one there goes.
        let gateway = digitalOcean()
        gateway.answer("POST", "/v2/droplets", 502, "{\"id\":\"bad_gateway\",\"message\":\"502 Bad Gateway\"}")
        gateway.answer("GET", "/v2/droplets", 200, "{\"droplets\":[{\"id\":3164444,\"name\":\"hub-1\"}]}")
        gateway.answer("DELETE", droplet, 204, "")
        add("a 502 to the droplet: the droplet with the call's tag goes", make(), gateway)
        // The droplet with the call's tag and another name is not the call's: it stays, and the end is not known.
        let renamed = digitalOcean()
        renamed.answer("POST", "/v2/droplets", 502, "{\"id\":\"bad_gateway\",\"message\":\"502 Bad Gateway\"}")
        renamed.answer("GET", "/v2/droplets", 200, "{\"droplets\":[{\"id\":3164445,\"name\":\"shop\"}]}")
        add("a 502 to the droplet and one with its tag of another name: it stays", make(), renamed)
        // A success with no id: read as after a fault answer, and the droplet with the call's tag goes.
        let noID = digitalOcean()
        noID.answer("POST", "/v2/droplets", 202, "{\"droplet\":{\"name\":\"hub-1\"}}")
        noID.answer("GET", "/v2/droplets", 200, "{\"droplets\":[{\"id\":3164444,\"name\":\"hub-1\"}]}")
        noID.answer("DELETE", droplet, 204, "")
        add("a success with no id to the droplet: the droplet with the call's tag goes", make(), noID)
        // None with its tag yet: the end is not known, and the droplet that comes at a later read goes.
        let late = digitalOcean()
        late.answer("POST", "/v2/droplets", 500, "{\"id\":\"server_error\",\"message\":\"try again\"}")
        late.answer("GET", "/v2/droplets", 200, "{\"droplets\":[]}")
        late.answer("GET", "/v2/droplets", 200, "{\"droplets\":[]}")
        late.answer("GET", "/v2/droplets", 200, "{\"droplets\":[{\"id\":3164444,\"name\":\"hub-1\"}]}")
        late.answer("DELETE", droplet, 204, "")
        add("a 500 to the droplet and none with its tag yet: the one that comes later goes", make(), late)

        let droplets = "{\"droplets\":["
            + "{\"id\":31,\"name\":\"api\",\"status\":\"active\",\"memory\":2048,\"size_slug\":\"s-1vcpu-2gb\","
            + "\"image\":{\"distribution\":\"Ubuntu\",\"name\":\"24.04 (LTS) x64\"},\"region\":{\"slug\":\"fra1\",\"name\":\"Frankfurt 1\"},"
            + "\"networks\":{\"v4\":[{\"ip_address\":\"10.0.0.2\",\"type\":\"private\"},{\"ip_address\":\"198.51.100.31\",\"type\":\"public\"}]}},"
            + "{\"id\":32,\"name\":\"db\",\"status\":\"off\",\"memory\":1024,\"size_slug\":\"s-1vcpu-1gb\","
            + "\"image\":{\"distribution\":\"Debian\",\"name\":\"12 x64\"},\"region\":{\"slug\":\"ams3\",\"name\":\"Amsterdam 3\"},"
            + "\"networks\":{\"v4\":[]}}]}"
        let listed = VectorStand()
        listed.answer("GET", "/v2/droplets", 200, droplets)
        listed.answer("GET", "/v2/projects", 200, "{\"projects\":[{\"id\":\"p1\",\"name\":\"Web\"},{\"id\":\"p2\",\"name\":\"Data\"}]}")
        listed.answer("GET", "/v2/projects/p1/resources", 200, "{\"resources\":[{\"urn\":\"do:droplet:31\"}]}")
        listed.answer("GET", "/v2/projects/p2/resources", 200, "{\"resources\":[{\"urn\":\"do:droplet:32\"},{\"urn\":\"do:volume:abc\"}]}")
        add("the team's droplets, each with its project", ["do": "servers"], listed)
        let unread = VectorStand()
        unread.answer("GET", "/v2/droplets", 200, droplets)
        unread.answer("GET", "/v2/projects", 403, "{\"id\":\"forbidden\",\"message\":\"no\"}")
        add("projects that the token may not read", ["do": "servers"], unread)

        let deleted = VectorStand()
        deleted.answer("DELETE", "/v2/droplets/31", 204, "")
        add("one droplet deleted by its id", ["do": "delete_server", "id": "31"], deleted)
        let walls = VectorStand()
        walls.answer("GET", "/v2/firewalls", 200, "{\"firewalls\":["
            + "{\"id\":\"f-1\",\"name\":\"founderizer-worker-1-abc123\",\"droplet_ids\":[31],\"tags\":[]},"
            + "{\"id\":\"f-2\",\"name\":\"founderizer-worker-1-def456\",\"droplet_ids\":[31,99],\"tags\":[]},"
            + "{\"id\":\"f-3\",\"name\":\"founderizer-worker-1-ghi789\",\"droplet_ids\":[],\"tags\":[\"web\"]},"
            + "{\"id\":\"f-4\",\"name\":\"founderizer-worker-1-jkl012\"},"
            + "{\"id\":\"f-5\",\"name\":\"founderizer-worker-10-abc123\",\"droplet_ids\":[]}]}")
        walls.answer("DELETE", "/v2/firewalls/f-1", 204, "")
        add("only a firewall that no other server uses goes", ["do": "delete_firewalls", "name": "worker-1", "deleted": ["31"]], walls)
        let keyGone = VectorStand()
        keyGone.answer("GET", "/v2/account/keys/\(fingerprint)", 200, "{\"ssh_key\":{\"id\":512190}}")
        keyGone.answer("DELETE", "/v2/account/keys/512190", 204, "")
        add("this app's key deleted by its fingerprint", ["do": "delete_key", "public_key": publicKey], keyGone)

        let wide = digitalOcean()
        wide.clear("GET", "/v2/account/keys/\(fingerprint)")
        wide.answer("GET", "/v2/account/keys/\(fingerprint)", 200, "{\"ssh_key\":{\"id\":3000000190}}")
        wide.answer("POST", "/v2/droplets", 202, "{\"droplet\":{\"id\":4294967396,\"status\":\"new\"}}")
        wide.answer("POST", "/v2/firewalls", 202, "{\"firewall\":{\"id\":\"\(oceanFirewall)\"}}")
        wide.answer("GET", "/v2/droplets/4294967396", 200, "{\"droplet\":{\"id\":4294967396,\"status\":\"active\",\"networks\":{\"v4\":["
                    + "{\"ip_address\":\"198.51.100.7\",\"type\":\"public\"}]}}}")
        add("a droplet and a key with ids above 32 bits", make(), wide)
        return cases
    }

    // MARK: - Vultr

    static let vultrInstance = "cb676a46-66fd-4dfb-b839-443f2e6c0b60"
    static let vultrFirewall = "1234abcd-5678-4ef0-9abc-def012345678"

    static func vultrPlan(_ id: String, type: String = "vc2", ram: Int, disk: Int, monthly: Double, locations: [String],
                          local: String = "{}") -> String {
        "{\"id\":\"\(id)\",\"vcpu_count\":1,\"ram\":\(ram),\"disk\":\(disk),\"monthly_cost\":\(monthly),\"type\":\"\(type)\","
            + "\"deploy_ondemand\":true,\"locations\":[\(locations.map { "\"\($0)\"" }.joined(separator: ","))],\"location_cost\":\(local)}"
    }

    static func vultr() -> VectorStand {
        let vultr = VectorStand()
        vultr.answer("GET", "/v2/ssh-keys", 200, "{\"ssh_keys\":[{\"id\":\"k-laptop\",\"name\":\"laptop\",\"ssh_key\":"
                     + "\"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherKeyOtherKeyOtherKeyOtherKeyOtherKey00 laptop\"}]}")
        vultr.answer("POST", "/v2/ssh-keys", 201, "{\"ssh_key\":{\"id\":\"k-app\",\"name\":\"founderizer-7210e7120f70\"}}")
        vultr.answer("GET", "/v2/os", 200, "{\"os\":[{\"id\":1743,\"name\":\"Ubuntu 22.04 LTS x64\",\"arch\":\"x64\",\"family\":\"ubuntu\"},"
                     + "{\"id\":2285,\"name\":\"Ubuntu 24.04 LTS arm\",\"arch\":\"arm64\",\"family\":\"ubuntu\"},"
                     + "{\"id\":2284,\"name\":\"Ubuntu 24.04 LTS x64\",\"arch\":\"x64\",\"family\":\"ubuntu\"}]}")
        vultr.answer("GET", "/v2/plans", 200, "{\"plans\":[" + [
            vultrPlan("vc2-1c-0.5gb-v6", ram: 512, disk: 10, monthly: 2.5, locations: ["fra"]),
            vultrPlan("vc2-1c-1gb", ram: 1024, disk: 25, monthly: 5, locations: ["fra", "ams", "lhr"],
                      local: "{\"ams\":{\"monthly_cost\":5.5}}"),
            vultrPlan("vc2-1c-2gb", ram: 2048, disk: 55, monthly: 10, locations: ["fra", "ams", "lhr"]),
            vultrPlan("vhp-1c-2gb-amd", type: "vhp", ram: 2048, disk: 50, monthly: 12, locations: ["fra"]),
            vultrPlan("vx1-g-2c-8g", type: "vx1", ram: 8192, disk: 1, monthly: 4, locations: ["fra"]),
        ].joined(separator: ",") + "]}")
        vultr.answer("GET", "/v2/regions/fra/availability", 200, "{\"available_plans\":[\"vc2-1c-1gb\",\"vhp-1c-2gb-amd\",\"vx1-g-2c-8g\"]}")
        vultr.answer("GET", "/v2/regions/ams/availability", 200, "{\"available_plans\":[\"vc2-1c-1gb\",\"vc2-1c-2gb\"]}")
        for region in ["lhr", "ewr", "sjc", "sgp"] {
            vultr.answer("GET", "/v2/regions/\(region)/availability", 200, "{\"available_plans\":[]}")
        }
        return vultr
    }

    static func vultrCases() -> [Case] {
        var cases: [Case] = []
        func add(_ name: String, _ call: [String: Any], held: String? = token, _ stand: VectorStand) {
            cases.append(Case(name: "Vultr: " + name, provider: .vultr, call: call, held: held, stand: stand))
        }
        let checked = VectorStand()
        checked.answer("POST", "/v2/ssh-keys", 400, "{\"error\":\"Missing ssh_key\",\"status\":400}")
        add("a key that may write is kept", ["do": "check_token", "token": token], held: nil, checked)
        let user = VectorStand()
        user.answer("POST", "/v2/ssh-keys", 403, "{\"error\":\"You are not allowed to perform that action.\",\"status\":403}")
        add("a user's key that may not add things", ["do": "check_token", "token": token], held: nil, user)
        let wrong = VectorStand()
        wrong.answer("POST", "/v2/ssh-keys", 401, "{\"error\":\"Invalid API token.\",\"status\":401}")
        add("a key that Vultr does not take", ["do": "check_token", "token": token], held: nil, wrong)
        let elsewhere = VectorStand()
        elsewhere.answer("POST", "/v2/ssh-keys", 401, "{\"error\":\"Unauthorized IP address: 203.0.113.9\",\"status\":401}")
        add("a key that Vultr takes only from other addresses", ["do": "check_token", "token": token], held: nil, elsewhere)

        add("every plan that fits a hub where it is free", ["do": "offers", "use": "hub", "except": [String]()], vultr())
        add("every plan that fits a server for agents", ["do": "offers", "use": "agent", "except": [String]()], vultr())
        let made = vultr()
        made.answer("POST", "/v2/firewalls", 201, "{\"firewall_group\":{\"id\":\"\(vultrFirewall)\",\"rule_count\":0}}")
        made.answer("POST", "/v2/instances", 202, "{\"instance\":{\"id\":\"\(vultrInstance)\",\"main_ip\":\"0.0.0.0\","
                    + "\"status\":\"pending\",\"default_password\":\"notarealpassword\"}}")
        made.answer("GET", "/v2/instances/\(vultrInstance)", 200, "{\"instance\":{\"main_ip\":\"0.0.0.0\",\"status\":\"pending\"}}")
        made.answer("GET", "/v2/instances/\(vultrInstance)", 200, "{\"instance\":{\"main_ip\":\"192.0.2.44\",\"status\":\"active\"}}")
        add("an instance behind a firewall group with no rule", make(), made)
        let refused = vultr()
        refused.answer("POST", "/v2/firewalls", 201, "{\"firewall_group\":{\"id\":\"\(vultrFirewall)\"}}")
        refused.answer("POST", "/v2/instances", 400, "{\"error\":\"Server add failed: plan is sold out\",\"status\":400}")
        refused.answer("DELETE", "/v2/firewalls/\(vultrFirewall)", 204, "")
        add("an instance that Vultr refuses: the firewall goes", make(), refused)
        // A fault answer of Vultr's own: the instance of that name behind the call's own group goes, with the group, and
        // another of that name behind another group stays.
        let timeout = vultr()
        timeout.answer("POST", "/v2/firewalls", 201, "{\"firewall_group\":{\"id\":\"\(vultrFirewall)\"}}")
        timeout.answer("POST", "/v2/instances", 504, "{\"error\":\"Gateway Timeout\"}")
        timeout.answer("GET", "/v2/instances", 200, "{\"instances\":[{\"id\":\"\(vultrInstance)\",\"label\":\"hub-1\","
                       + "\"firewall_group_id\":\"\(vultrFirewall)\"},{\"id\":\"another\",\"label\":\"hub-1\","
                       + "\"firewall_group_id\":\"another-group\"},{\"id\":\"shop\",\"label\":\"shop\","
                       + "\"firewall_group_id\":\"\(vultrFirewall)\"}]}")
        timeout.answer("DELETE", "/v2/instances/\(vultrInstance)", 204, "")
        timeout.answer("DELETE", "/v2/firewalls/\(vultrFirewall)", 204, "")
        add("a 504 to the instance: the one behind the call's own group goes, with the group", make(), timeout)
        let noID = vultr()
        noID.answer("POST", "/v2/firewalls", 201, "{\"firewall_group\":{\"id\":\"\(vultrFirewall)\"}}")
        noID.answer("POST", "/v2/instances", 202, "{\"instance\":{\"label\":\"hub-1\"}}")
        noID.answer("GET", "/v2/instances", 200, "{\"instances\":[{\"id\":\"\(vultrInstance)\",\"label\":\"hub-1\","
                    + "\"firewall_group_id\":\"\(vultrFirewall)\"}]}")
        noID.answer("DELETE", "/v2/instances/\(vultrInstance)", 204, "")
        noID.answer("DELETE", "/v2/firewalls/\(vultrFirewall)", 204, "")
        add("a success with no id to the instance: the one of its name behind the call's group goes, with the group", make(), noID)
        let stuck = vultr()
        stuck.answer("POST", "/v2/firewalls", 201, "{\"firewall_group\":{\"id\":\"\(vultrFirewall)\"}}")
        stuck.answer("POST", "/v2/instances", 202, "{\"instance\":{\"id\":\"\(vultrInstance)\"}}")
        stuck.answer("GET", "/v2/instances/\(vultrInstance)", 200, "{\"instance\":{\"status\":\"pending\",\"main_ip\":\"0.0.0.0\"}}")
        stuck.answer("DELETE", "/v2/instances/\(vultrInstance)", 204, "")
        stuck.answer("DELETE", "/v2/firewalls/\(vultrFirewall)", 400, "{\"error\":\"Firewall group is still attached\",\"status\":400}")
        stuck.answer("DELETE", "/v2/firewalls/\(vultrFirewall)", 204, "")
        add("an instance that never comes up is deleted, and its firewall when it lets go", make(), stuck)

        let listed = VectorStand()
        listed.answer("GET", "/v2/instances", 200, "{\"instances\":["
            + "{\"id\":\"i-1\",\"label\":\"web\",\"main_ip\":\"192.0.2.10\",\"ram\":2048,\"plan\":\"vc2-1c-2gb\","
            + "\"os\":\"Ubuntu 24.04 LTS x64\",\"region\":\"fra\",\"status\":\"active\",\"power_status\":\"running\",\"tags\":[]},"
            + "{\"id\":\"i-2\",\"label\":\"old\",\"main_ip\":\"0.0.0.0\",\"ram\":1024,\"plan\":\"vc2-1c-1gb\","
            + "\"os\":\"Debian 12 x64 (bookworm)\",\"region\":\"zzz\",\"status\":\"active\",\"power_status\":\"stopped\","
            + "\"tags\":[\"founderizer-agent\"]}]}")
        listed.answer("GET", "/v2/regions", 200, "{\"regions\":[{\"id\":\"fra\",\"city\":\"Frankfurt\",\"country\":\"DE\"}]}")
        add("the account's instances, each with its city", ["do": "servers"], listed)
        let deleted = VectorStand()
        deleted.answer("DELETE", "/v2/instances/\(vultrInstance)", 204, "")
        add("one instance deleted by its id", ["do": "delete_server", "id": vultrInstance], deleted)
        let walls = VectorStand()
        walls.answer("GET", "/v2/firewalls", 200, "{\"firewall_groups\":[{\"id\":\"g-1\",\"description\":\"founderizer-worker-1-abc123\",\"instance_count\":1},"
                     + "{\"id\":\"g-2\",\"description\":\"founderizer-worker-1-def456\",\"instance_count\":0}]}")
        walls.answer("GET", "/v2/firewalls", 200, "{\"firewall_groups\":[{\"id\":\"g-1\",\"description\":\"founderizer-worker-1-abc123\",\"instance_count\":0},"
                     + "{\"id\":\"g-2\",\"description\":\"founderizer-worker-1-def456\",\"instance_count\":0}]}")
        walls.answer("DELETE", "/v2/firewalls/g-1", 204, "")
        walls.answer("DELETE", "/v2/firewalls/g-2", 204, "")
        add("a group read again while its server's deletion runs, then each goes",
            ["do": "delete_firewalls", "name": "worker-1", "deleted": [vultrInstance]], walls)
        let keyGone = vultr()
        keyGone.clear("GET", "/v2/ssh-keys")
        keyGone.answer("GET", "/v2/ssh-keys", 200, "{\"ssh_keys\":[{\"id\":\"k-app\",\"ssh_key\":\"\(publicKey.replacingOccurrences(of: " founderizer-test", with: " other comment"))\"}]}")
        keyGone.answer("DELETE", "/v2/ssh-keys/k-app", 204, "")
        add("this app's key deleted by the key itself, whatever its comment", ["do": "delete_key", "public_key": publicKey], keyGone)
        return cases
    }

    // MARK: - Akamai

    static let linode = 54748754
    static let akamaiFirewall = 88712

    static func akamaiType(_ id: String, kind: String, memory: Int, disk: Int, monthly: String, successor: String = "null",
                           regionPrices: String = "[]") -> String {
        "{\"id\":\"\(id)\",\"label\":\"x\",\"class\":\"\(kind)\",\"vcpus\":1,\"memory\":\(memory),\"disk\":\(disk),"
            + "\"price\":{\"hourly\":0.0075,\"monthly\":\(monthly)},\"region_prices\":\(regionPrices),\"successor\":\(successor)}"
    }

    static func availability(_ region: String, free: [String], taken: [String] = []) -> String {
        "[" + (free.map { "{\"region\":\"\(region)\",\"plan\":\"\($0)\",\"available\":true}" }
            + taken.map { "{\"region\":\"\(region)\",\"plan\":\"\($0)\",\"available\":false}" }).joined(separator: ",") + "]"
    }

    static func akamai() -> VectorStand {
        let akamai = VectorStand()
        akamai.answer("GET", "/v4/linode/types", 200, "{\"data\":[" + [
            akamaiType("g6-nanode-1", kind: "nanode", memory: 1024, disk: 25600, monthly: "5.0"),
            akamaiType("g6-standard-1", kind: "standard", memory: 2048, disk: 51200, monthly: "12.0",
                       regionPrices: "[{\"id\":\"nl-ams\",\"hourly\":0.0252,\"monthly\":16.8}]"),
            akamaiType("g6-standard-old", kind: "standard", memory: 2048, disk: 51200, monthly: "1.0", successor: "\"g6-standard-1\""),
            akamaiType("g1-gpu-rtx6000-1", kind: "gpu", memory: 32768, disk: 655360, monthly: "null"),
            akamaiType("g6-dedicated-2", kind: "dedicated", memory: 4096, disk: 81920, monthly: "2.0"),
        ].joined(separator: ",") + "],\"page\":1,\"pages\":1}")
        akamai.answer("GET", "/v4/regions/eu-central/availability", 200,
                      availability("eu-central", free: ["g6-nanode-1", "g6-standard-old", "g6-dedicated-2"], taken: ["g6-standard-1"]))
        akamai.answer("GET", "/v4/regions/nl-ams/availability", 200, availability("nl-ams", free: ["g6-nanode-1", "g6-standard-1"]))
        for region in ["eu-west", "us-east", "us-west", "ap-south"] {
            akamai.answer("GET", "/v4/regions/\(region)/availability", 200, availability(region, free: []))
        }
        return akamai
    }

    static func akamaiCases() -> [Case] {
        var cases: [Case] = []
        func add(_ name: String, _ call: [String: Any], held: String? = token, _ stand: VectorStand) {
            cases.append(Case(name: "Akamai: " + name, provider: .akamai, call: call, held: held, stand: stand))
        }
        let checked = VectorStand()
        checked.answer("GET", "/v4/profile", 200, "{\"username\":\"owner\"}")
        checked.answer("POST", "/v4/linode/instances", 400, "{\"errors\":[{\"reason\":\"type is required\",\"field\":\"type\"}]}")
        checked.answer("POST", "/v4/networking/firewalls", 400, "{\"errors\":[{\"reason\":\"label is required\",\"field\":\"label\"}]}")
        add("a token for Linodes and Firewalls is kept", ["do": "check_token", "token": token], held: nil, checked)
        let half = VectorStand()
        half.answer("GET", "/v4/profile", 200, "{}")
        half.answer("POST", "/v4/linode/instances", 400, "{\"errors\":[{\"reason\":\"type is required\"}]}")
        half.answer("POST", "/v4/networking/firewalls", 401, "{\"errors\":[{\"reason\":\"You are not authorized to use this endpoint\"}]}")
        add("a token with no Firewalls", ["do": "check_token", "token": token], held: nil, half)
        let wrong = VectorStand()
        wrong.answer("GET", "/v4/profile", 401, "{\"errors\":[{\"reason\":\"Invalid Token\"}]}")
        add("a token that Akamai does not take", ["do": "check_token", "token": token], held: nil, wrong)

        add("every shared plan that fits a hub where it is free", ["do": "offers", "use": "hub", "except": [String]()], akamai())
        add("every shared plan that fits a server for agents", ["do": "offers", "use": "agent", "except": [String]()], akamai())
        let made = akamai()
        made.answer("POST", "/v4/networking/firewalls", 200, "{\"id\":\(akamaiFirewall),\"label\":\"x\",\"status\":\"enabled\"}")
        made.answer("POST", "/v4/linode/instances", 200, "{\"id\":\(linode),\"label\":\"hub-1\",\"status\":\"provisioning\"}")
        made.answer("GET", "/v4/linode/instances/\(linode)", 200, "{\"id\":\(linode),\"status\":\"booting\",\"ipv4\":[\"198.51.100.88\"]}")
        made.answer("GET", "/v4/linode/instances/\(linode)", 200, "{\"id\":\(linode),\"status\":\"running\","
                    + "\"ipv4\":[\"192.168.140.2\",\"10.0.0.3\",\"172.20.0.1\",\"198.51.100.88\"]}")
        add("a Linode behind a firewall that drops all that comes in", make(), made)
        // A fault answer of Akamai's own, and its firewall's devices cannot be read: nothing is taken back, the firewall
        // least of all, because Akamai deletes a firewall that a Linode uses.
        let unread = akamai()
        unread.answer("POST", "/v4/networking/firewalls", 200, "{\"id\":\(akamaiFirewall)}")
        unread.answer("POST", "/v4/linode/instances", 500, "{\"errors\":[{\"reason\":\"Please try again\"}]}")
        unread.answer("GET", "/v4/networking/firewalls/\(akamaiFirewall)/devices", 500, "{\"errors\":[{\"reason\":\"x\"}]}")
        add("a 500 to the Linode and devices that cannot be read: nothing is taken back", make(), unread)
        let blank = akamai()
        blank.answer("POST", "/v4/networking/firewalls", 200, "{\"id\":\(akamaiFirewall)}")
        blank.answer("POST", "/v4/linode/instances", 200, "{\"label\":\"hub-1\"}")
        blank.answer("GET", "/v4/networking/firewalls/\(akamaiFirewall)/devices", 500, "{\"errors\":[{\"reason\":\"x\"}]}")
        add("a success with no id to the Linode and devices that cannot be read: nothing is taken back", make(), blank)
        // A Linode that does not go keeps its firewall, which Akamai would delete in front of it.
        let stays = akamai()
        stays.answer("POST", "/v4/networking/firewalls", 200, "{\"id\":\(akamaiFirewall)}")
        stays.answer("POST", "/v4/linode/instances", 500, "{\"errors\":[{\"reason\":\"Please try again\"}]}")
        stays.answer("GET", "/v4/networking/firewalls/\(akamaiFirewall)/devices", 200,
                     "{\"data\":[{\"entity\":{\"id\":\(linode),\"type\":\"linode\",\"label\":\"hub-1\"}},"
                     + "{\"entity\":{\"id\":4242,\"type\":\"linode\",\"label\":\"shop\"}}]}")
        stays.answer("DELETE", "/v4/linode/instances/\(linode)", 500, "{\"errors\":[{\"reason\":\"busy\"}]}")
        add("a Linode found that does not go keeps its firewall", make(), stays)
        let refused = akamai()
        refused.answer("POST", "/v4/networking/firewalls", 200, "{\"id\":\(akamaiFirewall)}")
        refused.answer("POST", "/v4/linode/instances", 400, "{\"errors\":[{\"reason\":\"Region is not available\",\"field\":\"region\"}]}")
        refused.answer("DELETE", "/v4/networking/firewalls/\(akamaiFirewall)", 200, "{}")
        add("a Linode that Akamai refuses: the firewall goes", make(), refused)

        let listed = VectorStand()
        listed.answer("GET", "/v4/regions", 200, "{\"data\":[{\"id\":\"eu-central\",\"label\":\"Frankfurt, DE\"}],\"pages\":1}")
        listed.answer("GET", "/v4/linode/instances", 200, "{\"data\":[{\"id\":11,\"label\":\"api\",\"status\":\"running\","
            + "\"ipv4\":[\"192.168.130.4\",\"198.51.100.11\"],\"type\":\"g6-standard-1\",\"specs\":{\"memory\":2048},"
            + "\"image\":\"linode/ubuntu24.04\",\"region\":\"eu-central\",\"tags\":[]}],\"page\":1,\"pages\":2}")
        listed.answer("GET", "/v4/linode/instances", 200, "{\"data\":[{\"id\":12,\"label\":\"hub\",\"status\":\"offline\","
            + "\"ipv4\":[],\"type\":\"g6-nanode-1\",\"specs\":{\"memory\":1024},\"image\":\"private/123\",\"region\":\"us-east\","
            + "\"tags\":[\"founderizer-hub\"]}],\"page\":2,\"pages\":2}")
        add("the account's Linodes, page by page", ["do": "servers"], listed)
        let deleted = VectorStand()
        deleted.answer("DELETE", "/v4/linode/instances/11", 200, "{}")
        add("one Linode deleted by its id", ["do": "delete_server", "id": "11"], deleted)
        let walls = VectorStand()
        walls.answer("GET", "/v4/networking/firewalls", 200, "{\"data\":[{\"id\":5,\"label\":\"fz-hub-1-abc123\"},"
                     + "{\"id\":6,\"label\":\"fz-hub-1-def456\"},{\"id\":7,\"label\":\"founderizer-hub-1-abc123\"}],\"pages\":1}")
        walls.answer("GET", "/v4/networking/firewalls/5/devices", 200, "{\"data\":[{\"entity\":{\"id\":11,\"type\":\"linode\"}}]}")
        walls.answer("GET", "/v4/networking/firewalls/6/devices", 200, "{\"data\":[{\"entity\":{\"id\":3,\"type\":\"nodebalancer\"}}]}")
        walls.answer("DELETE", "/v4/networking/firewalls/5", 200, "{}")
        add("a firewall that stands in front of a NodeBalancer stays", ["do": "delete_firewalls", "name": "hub-1", "deleted": ["11"]], walls)
        add("Akamai keeps no key of its own", ["do": "delete_key", "public_key": publicKey], VectorStand())

        let wide = akamai()
        wide.answer("POST", "/v4/networking/firewalls", 200, "{\"id\":3000000001}")
        wide.answer("POST", "/v4/linode/instances", 200, "{\"id\":3000000002}")
        wide.answer("GET", "/v4/linode/instances/3000000002", 200, "{\"id\":3000000002,\"status\":\"running\",\"ipv4\":[\"198.51.100.88\"]}")
        add("a Linode and its firewall with ids above 32 bits", make(), wide)
        let wideWalls = VectorStand()
        wideWalls.answer("GET", "/v4/networking/firewalls", 200, "{\"data\":[{\"id\":3000000001,\"label\":\"fz-hub-1-abc123\"}],\"pages\":1}")
        wideWalls.answer("GET", "/v4/networking/firewalls/3000000001/devices", 200,
                         "{\"data\":[{\"entity\":{\"id\":3000000002,\"type\":\"linode\"}}]}")
        add("a firewall of a Linode, both with ids above 32 bits", ["do": "firewalls", "name": "hub-1"], wideWalls)
        return cases
    }

    // MARK: - Running a case

    static func run(_ one: Case) async -> (result: Any, error: [String: Any]?, kept: String?) {
        let shelf = MemoryShelf(one.held.map { Data($0.utf8) })
        // The reads that a call starts after it ended are in the case's requests: the case waits for them.
        let follows = Follows()
        let servers = CloudServers(provider: one.provider, exchange: one.stand.stand.exchange, shelf: shelf, zone: zone,
                                   pause: { _ in }, follow: follows.follow)
        var result: Any = NSNull()
        var thrown: [String: Any]?
        do {
            switch one.call["do"] as! String {
            case "check_token":
                try await servers.connect(token: one.call["token"] as! String)
                result = "kept"
            case "offers":
                let use = CloudServerUse(rawValue: one.call["use"] as! String)!
                result = try await servers.offers(use: use, except: Set(one.call["except"] as! [String])).map(offer)
            case "make":
                let use = CloudServerUse(rawValue: one.call["use"] as! String)!
                let chosen = (one.call["offer"] as? [String: Any]).map { given in
                    CloudOffer(provider: one.provider, type: given["type"] as! String, location: given["location"] as! String,
                               cores: given["cores"] as? Int, memoryGB: given["memory_gb"] as? Double,
                               diskGB: given["disk_gb"] as? Int, monthlyPrice: Decimal(string: given["price"] as! String)!,
                               currency: given["currency"] as! String, dedicated: given["dedicated"] as! Bool)
                }
                let server = try await servers.createServer(name: one.call["name"] as! String, use: use,
                                                            publicKey: one.call["public_key"] as! String,
                                                            authKey: one.call["auth_key"] as! String, offer: chosen)
                result = ["id": server.id, "name": server.name, "ipv4": server.ipv4, "type": server.type,
                          "location": server.location, "price": "\(server.monthlyPrice)", "currency": server.currency,
                          "firewall_id": server.firewallID]
            case "servers":
                result = try await servers.servers().map { existing -> [String: Any] in
                    ["id": existing.id, "name": existing.name, "ipv4": existing.ipv4 as Any? ?? NSNull(), "type": existing.type,
                     "memory_mb": existing.memoryMB as Any? ?? NSNull(), "system": existing.system as Any? ?? NSNull(),
                     "version": existing.version as Any? ?? NSNull(), "place": existing.place as Any? ?? NSNull(),
                     "running": existing.running, "project": existing.project as Any? ?? NSNull(),
                     "made_for": existing.madeFor as Any? ?? NSNull(), "summary": existing.summary]
                }
            case "delete_server":
                let accepted = Flag()
                let deletion = try await servers.deleteServer(id: one.call["id"] as! String, accepted: { accepted.set() })
                switch deletion {
                case .deleted: result = ["deleted": true, "accepted": accepted.value]
                case .notThere(let error): result = ["deleted": false, "accepted": accepted.value, "not_there": cloudError(error)]
                }
            case "firewalls":
                result = try await servers.firewalls(ofServer: one.call["name"] as! String).map { firewall -> [String: Any] in
                    ["id": firewall.id, "servers": firewall.servers, "other": firewall.other]
                }
            case "delete_firewalls":
                try await servers.deleteFirewalls(ofServer: one.call["name"] as! String,
                                                  deleted: Set(one.call["deleted"] as! [String]))
                result = "done"
            case "delete_key":
                try await servers.deleteKey(publicKey: one.call["public_key"] as! String)
                result = "done"
            default: Issue.record("no such call")
            }
        } catch let error as CloudError {
            thrown = cloudError(error)
        } catch let error as FleetKeyError {
            thrown = TailscaleVectorsTests.fleetKeyError(error)
        } catch {
            thrown = ["case": "other"]
        }
        await follows.done()
        return (result, thrown, shelf.held.map { String(decoding: $0, as: UTF8.self) })
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var on = false
        func set() { lock.withLock { on = true } }
        var value: Bool { lock.withLock { on } }
    }

    static func offer(_ offer: CloudOffer) -> [String: Any] {
        ["type": offer.type, "location": offer.location, "price": "\(offer.monthlyPrice)", "currency": offer.currency,
         "cores": offer.cores as Any? ?? NSNull(), "memory_gb": offer.memoryGB as Any? ?? NSNull(),
         "disk_gb": offer.diskGB as Any? ?? NSNull(), "dedicated": offer.dedicated, "key": offer.key, "kind": offer.kind,
         "size": offer.size, "choice": offer.choice, "place": offer.place]
    }

    static func cloudError(_ error: CloudError) -> [String: Any] {
        func shown(_ text: String) -> String { VectorStand.shown(text, hiding: secrets, chance: chance) }
        var named: [String: Any] = ["words": shown(error.errorDescription ?? "")]
        switch error {
        case .notAToken: named["case"] = "not_a_token"
        case .noToken: named["case"] = "no_token"
        case .tokenNotAccepted: named["case"] = "token_not_accepted"
        case .readOnlyToken: named["case"] = "read_only_token"
        case .rateLimited: named["case"] = "rate_limited"
        case .unreachable: named["case"] = "unreachable"
        case .refused(_, let says): named["case"] = "refused"; named["says"] = shown(says)
        case .takenBack(_, let says, let server):
            named["case"] = "taken_back"; named["says"] = says.map(shown) as Any? ?? NSNull(); named["server"] = server
        case .unsure(_, let says, let server, let mark):
            named["case"] = "unsure"; named["says"] = says.map(shown) as Any? ?? NSNull(); named["server"] = server
            named["mark"] = shown(mark)
        case .unread(_, let server, let mark):
            named["case"] = "unread"; named["server"] = server; named["mark"] = shown(mark)
        case .unreadTakenBack(_, let server): named["case"] = "unread_taken_back"; named["server"] = server
        case .notUnderstood: named["case"] = "not_understood"
        case .noRoom: named["case"] = "no_room"
        case .full: named["case"] = "full"
        case .taken: named["case"] = "taken"
        case .notReady: named["case"] = "not_ready"
        case .notAServerName: named["case"] = "not_a_server_name"
        case .notAPublicKey: named["case"] = "not_a_public_key"
        case .notAnAuthKey: named["case"] = "not_an_auth_key"
        case .leftBehind(_, let reason, let left):
            named["case"] = "left_behind"; named["says"] = shown(reason); named["left"] = left.map(shown)
        case .noPaymentMethod: named["case"] = "no_payment_method"
        case .paymentPending: named["case"] = "payment_pending"
        case .paidNotReady(_, let name, _): named["case"] = "paid_not_ready"; named["says"] = shown(name)
        }
        return named
    }

    // MARK: - The pure rules

    static func rules() -> [String: Any] {
        // The providers whose cards the apps show: a provider joins the vectors, and so the PC's twin, with its card.
        let providers = CloudProvider.shown
        let offsets: [Double] = [-11, -8, -5, -3.5, 0, 1, 2, 5.5, 8, 9, 12]
        let tokens = ["", "  \(token)\n", "short", String(repeating: "a", count: 20), String(repeating: "a", count: 257),
                      "has spaces in it that make it no token", authKey, "tskey-api-0123456789abcdefghij", "abc_DEF-0123456789xyz"]
        let keys = [publicKey, publicKey + "\n", "", "ssh-dss AAAAB3NzaC1kc3MAAACBAP= x",
                    publicKey.replacingOccurrences(of: "ssh-ed25519", with: "ssh-rsa"), publicKey + "\n" + publicKey,
                    "ssh-ed25519 not-base64!", "ssh-ed25519 AAAA"]
        let errors: (CloudProvider) -> [CloudError] = { provider in
            [.notAToken(provider), .noToken(provider), .tokenNotAccepted(provider), .readOnlyToken(provider),
             .rateLimited(provider), .unreachable(provider), .refused(provider, "an example refusal"),
             .unsure(provider, says: "an example fault", server: "worker-3", mark: "founderizer-worker-3-k3j9x2"),
             .unsure(provider, says: nil, server: "worker-3", mark: "fz-worker-3-k3j9x2"),
             .takenBack(provider, says: "an example fault", server: "worker-3"), .takenBack(provider, says: nil, server: "worker-3"),
             .unread(provider, server: "worker-3", mark: "founderizer-worker-3-k3j9x2"), .unreadTakenBack(provider, server: "worker-3"),
             .notUnderstood(provider),
             .noRoom(provider), .full(provider), .taken(provider), .notReady(provider),
             .leftBehind(provider, reason: "It failed.", left: ["the server hub-1"]),
             .leftBehind(provider, reason: "It failed.", left: ["the server hub-1", "the firewall founderizer-hub-1-abc123"])]
        }
        let stops: [(Error, String)] = [(CloudError.taken(.hetzner), "taken"), (CloudError.noRoom(.vultr), "no_room"),
                                        (CloudError.notReady(.akamai), "not_ready"), (CloudError.rateLimited(.hetzner), "rate_limited"),
                                        (CloudError.full(.digitalOcean), "full"), (CloudError.refused(.hetzner, "x"), "refused"),
                                        (CloudError.tokenNotAccepted(.hetzner), "token_not_accepted"),
                                        (CloudError.readOnlyToken(.vultr), "read_only_token"), (CloudError.noToken(.akamai), "no_token"),
                                        (CloudError.notAToken(.hetzner), "not_a_token"),
                                        (FleetKeyError.fleetKeyEnded, "fleet_key_ended"), (FleetKeyError.noFleetKey, "no_fleet_key"),
                                        (FleetKeyError.unreachable, "fleet_unreachable")]
        let existing = [
            CloudExisting(id: "1", name: "a", ipv4: nil, type: "cx23", memoryMB: 4096, system: "ubuntu", version: "24.04",
                          place: nil, running: true, project: nil, madeFor: nil),
            CloudExisting(id: "2", name: "b", ipv4: nil, type: "s-1vcpu-2gb", memoryMB: 1536, system: "debian", version: "12",
                          place: nil, running: true, project: "Web", madeFor: nil),
            CloudExisting(id: "3", name: "c", ipv4: nil, type: "", memoryMB: 512, system: "rocky", version: "9",
                          place: nil, running: true, project: nil, madeFor: nil),
            CloudExisting(id: "4", name: "d", ipv4: nil, type: "vc2-1c-1gb", memoryMB: nil, system: nil, version: "1",
                          place: nil, running: true, project: nil, madeFor: nil),
        ]
        return [
            "user_data": [["auth_key": authKey, "hostname": "hub-1", "text": CloudServers.userData(authKey: authKey, hostname: "hub-1")],
                          ["auth_key": authKey, "hostname": "worker-12",
                           "text": CloudServers.userData(authKey: authKey, hostname: "worker-12")]],
            "near": offsets.map { hours -> [String: Any] in
                let zone = TimeZone(secondsFromGMT: Int(hours * 3600))!
                var near: [String: Any] = ["hours": hours]
                for provider in providers { near[provider.rawValue] = provider.near(zone) }
                return near
            },
            "tokens": tokens.map { pasted -> [String: Any] in
                ["pasted": pasted, "token": (try? CloudProvider.hetzner.token(pasted)) as Any? ?? NSNull()]
            },
            "public_keys": keys.map { text -> [String: Any] in
                let key = SSHPublicKey(text)
                return ["text": text, "line": key?.line as Any? ?? NSNull(), "fingerprint": key?.fingerprint as Any? ?? NSNull(),
                        "name": key?.name as Any? ?? NSNull()]
            },
            "names": ["hub-1", "worker-12", "a", "ab", "hub-", "Hub-1", "1hub", "hub_1", "h" + String(repeating: "a", count: 30),
                      "h" + String(repeating: "a", count: 31), ""].map { ["name": $0, "is": CloudServers.isName($0)] },
            "ids": ["1001", "cb676a46-66fd-4dfb-b839-443f2e6c0b60", "", "10/01", "a b", String(repeating: "1", count: 64),
                    String(repeating: "1", count: 65), "ü"].map { ["id": $0, "is": CloudServers.isID($0)] },
            "firewall_names": [("founderizer-hub-1-abc123", "hub-1", "hetzner"), ("founderizer-hub-1-ABC123", "hub-1", "hetzner"),
                               ("founderizer-hub-10-abc123", "hub-1", "hetzner"), ("founderizer-hub-1-abc12", "hub-1", "vultr"),
                               ("fz-hub-1-abc123", "hub-1", "akamai"), ("founderizer-hub-1-abc123", "hub-1", "akamai"),
                               ("fz-a-very-long-name-of-a-ser-abc123", "a-very-long-name-of-a-server-x", "akamai"),
                               ("fz-ab-cdefgh-ijklmnopqrstuv-abc123", "ab-cdefgh-ijklmnopqrstuv-wxyz", "akamai")]
                .map { candidate, name, provider -> [String: Any] in
                    ["candidate": candidate, "server": name, "provider": provider,
                     "is": CloudServers.isFirewallName(candidate, ofServer: name, at: CloudProvider(rawValue: provider)!)]
                },
            "ipv4": ["203.0.113.10", "0.0.0.0", "1.2.3", "a.b.c.d", "1234.1.1.1", "fd7a::1"].map { ["address": $0, "is": CloudServers.isIPv4($0)] },
            "public_ipv4": [["10.0.0.3", "198.51.100.88"], ["192.168.1.2", "172.16.0.1", "172.31.255.255"], ["172.32.0.1"],
                            ["127.0.0.1", "203.0.113.8"], []].map { (addresses: [String]) -> [String: Any] in
                ["addresses": addresses, "public": CloudServers.publicIPv4(addresses) as Any? ?? NSNull()]
            },
            "providers": providers.map { provider -> [String: Any] in
                ["provider": provider.rawValue, "name": provider.name, "api": provider.api.absoluteString, "image": provider.image,
                 "write_probes": provider.writeProbes, "locations": provider.locations.map(\.name),
                 "places": Dictionary(uniqueKeysWithValues: (provider.locations.map(\.name) + ["xyz"]).map { ($0, provider.place($0)) }),
                 "server_path": provider.serverPath("1001"), "firewall_path": provider.firewallPath("77"),
                 "tag_hub": CloudServers.tag(.hub), "tag_agent": CloudServers.tag(.agent),
                 "errors": errors(provider).map(cloudError)]
            },
            "sizes": ["hub": CloudProvider.digitalOceanSize(for: .hub), "agent": CloudProvider.digitalOceanSize(for: .agent)],
            "existing": existing.map { ["id": $0.id, "summary": $0.summary] },
            "megabytes": [512, 1024, 1536, 2048, 4096, 1000, 1800, 1280, 1331].map { ["megabytes": $0, "words": CloudExisting.size($0)] },
            "stops": stops.flatMap { error, name -> [[String: Any]] in
                [false, true].map { called -> [String: Any] in
                    ["error": name, "called": called, "reads_list_again": CloudStop.readsListAgain(after: error, called: called),
                     "refuses_token": CloudStop.refusesToken(error)]
                }
            },
            "not_joined": CloudServers.notJoined("worker-3", at: .hetzner),
            "constants": ["ubuntu": CloudServers.ubuntu, "join_key_life": CloudServers.joinKeyLife,
                          "wait_reads": CloudServers.waitReads, "remove_reads": CloudServers.removeReads,
                          "hub_memory_mb": ServerCheck.hubMemory.megabytes, "agent_memory_mb": ServerCheck.agentMemory.megabytes,
                          "apt_lock_wait": InstallPlan.aptLockWait, "follow_reads": CloudServers.followReads,
                          "follow_step": Int(CloudServers.followStep.components.seconds)],
        ]
    }

    static func document() async throws -> Data {
        var made: [[String: Any]] = []
        for one in hetznerCases() + digitalOceanCases() + vultrCases() + akamaiCases() {
            let (result, error, kept) = await run(one)
            made.append(["name": one.name, "provider": one.provider.rawValue, "call": one.call, "held": one.held as Any? ?? NSNull(),
                         "answers": one.stand.answers, "requests": one.stand.requests(hiding: secrets, chance: chance),
                         "result": result, "error": error as Any? ?? NSNull(), "kept": kept as Any? ?? NSNull()])
        }
        let document: [String: Any] = [
            "about": "The cloud providers' APIs as FleetCore's CloudServers calls them, at a computer in Berlin's time zone: for "
                + "each case the stand-in's answers (by method and path, in order, the last one again for each later request, "
                + "and 404 for a path that has none; status -1 is a connection that fails), each request sent (the token, the "
                + "auth key, a firewall's chance and Akamai's root password by name), what it gave or threw, and the token it "
                + "kept. Then the pure rules and the English words.",
            "made_by": "app/Tests/FleetCoreTests/CloudVectorsTests.swift", "secrets": secrets,
            "chance": chance.map { ["pattern": $0.0, "name": $0.1] }, "zone_hours": 1, "cases": made, "rules": rules(),
        ]
        return try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            + Data("\n".utf8)
    }

    @Test("The cloud providers' vectors are what FleetCore gives now")
    func theCloudVectorsAreTheCommittedFile() async throws {
        let made = try await Localized.$bundle.withValue(WordsVectorsTests.noTable) { try await Self.document() }
        try VectorStand.writeOrCompare(made, Self.file)
    }
}
