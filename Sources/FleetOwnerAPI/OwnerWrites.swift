import CryptoKit
import Darwin
import Foundation

/// **The nine tools that write, as `owner_mcp.py` writes them** (slice A2): `save_profile` (`with_profile_base`),
/// `attach_file`, `read_attachment`, `take_backup`, `grant_access` (with `_one_moved`, `_one_moved_map`,
/// `_team_command`, `secret_reaches`, `vault_read`, `vault_reading` and `made_by_an_agent`), `share_resource` (with
/// `standing_reaches`), `send_message` (`write_message`),
/// `answer_needs_you` (`answer_need`) and `decline_secret_request` (`decline_secret`). Each makes the same requests in
/// the same order, with the same refusals in the same words and the same result; the parity check
/// (`OwnerParityTests`, `test_owner_mcp.Parity`) holds them to that function by function.
extension OwnerTools {
    /// The tools of the table's kind `swift` that this program has. A table of a newer `owner_mcp.py` can name a
    /// `swift` tool that this code has not: that tool is refused in words, as one of a later version (`init`).
    public static let written: Set<String> = [
        "fleet_overview", "fleet_read", "search_history", "see_costs",
        "save_profile", "attach_file", "read_attachment", "take_backup", "grant_access", "share_resource",
        "send_message", "answer_needs_you", "decline_secret_request",
        // design 9's tools of a cloud (piece B2), in OwnerCloud.swift: no hub
        "cloud_look", "cloud_step", "cloud_remove",
    ]

    func runWritten(_ name: String, _ args: [String: JSONValue], on hub: OwnerHub) throws -> JSONValue? {
        switch name {
        case "fleet_overview": return try overview(args, on: hub)
        case "fleet_read": return try readPage(args, on: hub)
        case "search_history": return try history(args, on: hub)
        case "see_costs": return try costs(args, on: hub)
        case "save_profile": return try saveProfile(args, on: hub)
        case "attach_file": return try attachFile(args, on: hub)
        case "read_attachment": return try readAttachment(args, on: hub)
        case "take_backup": return try takeBackup(args, on: hub)
        case "grant_access": return try grantAccess(args, on: hub)
        case "share_resource": return try shareResource(args, on: hub)
        case "send_message": return try sendMessage(args, on: hub)
        case "answer_needs_you": return try answerNeed(args, on: hub)
        case "decline_secret_request": return try declineSecret(args, on: hub)
        default: throw OwnerRefusal(Self.notYet(name))
        }
    }

    // ------------------------------------------------------------ messages and Needs-you

    /// `send_message`: `POST /ui/messages`.
    func sendMessage(_ args: [String: JSONValue], on hub: OwnerHub) throws -> JSONValue? {
        var body: [String: JSONValue] = ["text": args["text"] ?? .null]
        for key in ["recipient", "attachments", "replaces_request_id"] {
            if let value = args[key], !value.isNull { body[key] = value }
        }
        return try hub.command("/ui/messages", body, "the message", requestID: args["request_id"])
    }

    /// `answer_needs_you`: `POST /ui/needs/<need>`, with the files of `attachments` beside an answer in words or
    /// alone (`OwnerTools.filesWithAChoice` refused them beside a choice before any request).
    func answerNeed(_ args: [String: JSONValue], on hub: OwnerHub) throws -> JSONValue? {
        var body: [String: JSONValue] = [:]
        for key in ["answer", "choice", "choices", "attachments"] {
            if let value = args[key], !value.isNull { body[key] = value }
        }
        let need = try Self.wholeNumber(args, "need")
        return try hub.command("/ui/needs/\(need)", body, "the answer", requestID: args["request_id"])
    }

    /// `decline_secret_request`: `POST /ui/needs/<need>/secret` with the decline alone. No value comes in or goes out.
    func declineSecret(_ args: [String: JSONValue], on hub: OwnerHub) throws -> JSONValue? {
        let need = try Self.wholeNumber(args, "need")
        let reason = args["reason"].flatMap { $0.truthy ? $0 : nil } ?? .string("")
        return try hub.command("/ui/needs/\(need)/secret", ["decline": reason], "the decline",
                               requestID: args["request_id"])
    }

    // ------------------------------------------------------------ the profile

    /// `save_profile`: one agent's profile, with the digest of the profile that the client made its sections from, in
    /// its own `fleet_read(page="profiles")` (`base_sha256`, null for an agent with no profile yet), as
    /// `owner_mcp.py`'s `with_profile_base`: the sections replace the whole profile, and a digest read here would hold
    /// a change made after the client's read. The read of `GET /ui/profiles` here only finds the agent.
    func saveProfile(_ args: [String: JSONValue], on hub: OwnerHub) throws -> JSONValue? {
        let agent = PyText.strip(Self.text(args["agent"]))
        guard !agent.isEmpty else { throw OwnerRefusal("agent must be the name of the agent whose profile this is.") }
        try Self.onePart("agent", agent)
        guard let base = args["base_sha256"] else { throw OwnerRefusal(Self.profileBaseNeeded) }
        let page = try hub.get("/ui/profiles", "the profiles").data
        let profiles = (page?["profiles"]).flatMap { $0.truthy ? $0.array : nil } ?? []
        guard profiles.contains(where: { PyText.same($0["agent"]?.string, agent) }) else {
            throw OwnerRefusal("There is no agent \(agent). Read fleet_read(page=\"profiles\") for the ones there are.")
        }
        return try hub.command("/ui/profiles/\(OwnerHub.quote(agent, safe: ""))",
                               ["sections": args["sections"] ?? .null, "base_sha256": base],
                               "the profile of \(agent)", requestID: args["request_id"])
    }

    // ------------------------------------------------------------ access

    static let grantRoutes = ["repo": "/ui/team/repos", "tool": "/ui/team/tools", "secret": "/ui/secrets/grant",
                              "drive": "/ui/team/google", "gmail": "/ui/team/google"]

    /// `grant_access`: one agent's hold of one resource that the fleet already has. Each kind is its own owner route,
    /// and the three that take a whole map are read from `GET /ui/team` first, so only the named agent moves. A give of
    /// a secret that the hub's reading of the central vault shows as one that brings its value to no server is not
    /// sent (`secretReaches`); an end of a hold always goes, with no read before it.
    func grantAccess(_ args: [String: JSONValue], on hub: OwnerHub) throws -> JSONValue? {
        let resource = args["resource"] ?? .null, agent = args["agent"] ?? .null, level = args["level"] ?? .null
        let (kind, what) = PyText.partition(Self.text(resource), ":")
        if PyText.same(kind, "server") {
            throw OwnerRefusal("A server goes with its business: the owner's app gives each server that carries a "
                               + "business's Tailscale tag to that business's DevOps agent (or the manager while it has "
                               + "none), puts the host's parts in place and writes the door's access file. Nothing here "
                               + "gives it.")
        }
        guard Self.grantRoutes.keys.contains(where: { PyText.same($0, kind) }), !what.isEmpty else {
            throw OwnerRefusal("resource must be <kind>:<what>, with a kind of "
                               + Self.grantRoutes.keys.sorted(by: JSONValue.pythonOrder).joined(separator: ", ")
                               + " — for example repo:acme/web, secret:bws://<uuid>, gmail:a@b.com or tool:github.")
        }
        guard case .string(let name) = agent, !name.isEmpty else {
            throw OwnerRefusal("agent must be the name of the agent that holds this resource.")
        }
        if let folder = args["folder"], !folder.isNull {
            return try grantFolder(what, kind: kind, agent: name, level: level, folder: folder, args, on: hub)
        }
        let whatFor = "the grant of \(resource.pythonText) to \(name)"
        if PyText.same(kind, "secret") {
            if !level.isNull, try !secretReaches(what, name, level, on: hub) {
                throw OwnerRefusal(Self.grantNotSigned)
            }
            return try hub.command("/ui/secrets/grant", ["login": .string(what), "agent": agent, "grant": level],
                                   whatFor, requestID: args["request_id"])
        }
        // The map and the base come from this one read (`owner_mcp.py`'s grant_access), so a grant made after it is
        // the hub's 409 and not lost.
        let page = try hub.get("/ui/team", "a read of the team").data
        let lines = try Self.teamLines(page)
        func moved(_ map: [String: JSONValue]) -> [String: JSONValue] {
            var map = map
            map[name] = nil
            if !level.isNull { map[name] = level }
            return map
        }
        if PyText.same(kind, "repo") {
            var access: [String: JSONValue] = [:]
            for (agentName, line) in lines {
                let repos = try Self.teamPart(line, "repos", object: true).object ?? [:]
                if let found = repos.first(where: { PyText.same($0.key, what) }) { access[agentName] = found.value }
            }
            return try teamCommand("/ui/team/repos", ["repo": .string(what), "access": .object(moved(access))],
                                   whatFor, args, page: page, on: hub)
        }
        if PyText.same(kind, "tool") {
            var names: [String: JSONValue] = [:]
            for (agentName, line) in lines {
                let tools = try Self.teamPart(line, "tools", object: false).array ?? []
                if tools.contains(where: { PyText.same($0.string, what) }) { names[agentName] = .string("use") }
            }
            let agents = moved(names).keys.sorted(by: JSONValue.pythonOrder).map(JSONValue.string)
            return try teamCommand("/ui/team/tools", ["tool": .string(what), "agents": .array(agents)], whatFor, args,
                                   page: page, on: hub)
        }
        var access: [String: JSONValue] = [:]
        for (agentName, line) in lines {
            let google = try Self.teamPart(line, "google", object: true).object ?? [:]
            let service = try Self.teamPart(google, kind, object: true).object ?? [:]
            if PyText.same(service["account"]?.string, what) {
                guard let found = service["level"] else { throw OwnerRefusal(Self.teamShape) }
                access[agentName] = found
            }
        }
        return try teamCommand("/ui/team/google", ["account": .string(what), "service": .string(kind),
                                                   "access": .object(moved(access))], whatFor, args, page: page,
                               on: hub)
    }

    /// `owner_mcp.py`'s FOLDER_KIND.
    static let folderKind = "folder goes with drive:<email> only: the link or the ID of one folder of that Drive."

    /// `owner_mcp.py` `grant_folder`: one agent's hold of one folder of a Drive account (owner API 1.255,
    /// `drive_folders`), by its link or its ID, which the hub reads with the account. The folder's other agents come
    /// from `GET /ui/resources` first, so only the named agent moves; a folder that no agent holds yet has none.
    func grantFolder(_ what: String, kind: String, agent name: String, level: JSONValue, folder given: JSONValue,
                     _ args: [String: JSONValue], on hub: OwnerHub) throws -> JSONValue? {
        guard PyText.same(kind, "drive"), case .string(let raw) = given, !PyText.strip(raw).isEmpty else {
            throw OwnerRefusal(Self.folderKind)
        }
        let folder = PyText.strip(raw)
        let found = folder.firstMatch(of: Self.folderIn.matchingSemantics(.unicodeScalar)).map { String($0.output.1) }
        let folderID = found ?? folder, account = PyText.asciiLower("drive:" + what)
        let page = try hub.get("/ui/resources", "a read of the resources").data
        var held: [String: JSONValue] = [:]
        for item in page?["resources"]?.array ?? [] {
            guard let map = item.object, PyText.asciiLower(Self.text(map["id"])) == account else { continue }
            for entry in map["folders"]?.array ?? [] {
                guard let folderMap = entry.object, case .string(let id)? = folderMap["id"], id == folderID else { continue }
                held = [:]
                for holder in folderMap["holders"]?.array ?? [] {
                    if let holderMap = holder.object { held[Self.text(holderMap["agent"])] = holderMap["level"] ?? .null }
                }
            }
        }
        held[name] = nil
        if !level.isNull { held[name] = level }
        // The base is the version of team.json that this page read, not of a second read (`owner_mcp.py`).
        return try hub.command("/ui/team/google", ["account": .string(what), "service": .string("drive"),
                                                   "folder": .string(folder), "access": .object(held),
                                                   "base_sha256": page?["sha256"] ?? .null],
                               "the grant of the Drive folder \(folder) to \(name)", requestID: args["request_id"])
    }

    /// `owner_mcp.py`'s DRIVE_FOLDER_IN (hub.py's): a folder's ID in a link of it.
    nonisolated(unsafe) static let folderIn = /(?:\/folders\/|\/drives\/|[?&]id=)([A-Za-z0-9_-]{10,200})/

    /// `owner_mcp.py`'s TEAM_SHAPE: nothing is sent when the read of the team has another shape.
    static let teamShape = "The hub's answer to the read of the team does not have the shape that grant_access reads, "
        + "so nothing was sent. Read fleet_read(page=\"team\") and tell the owner."

    /// `team_lines`: `lines` of `GET /ui/team`, a list of objects, each with its agent's name as a text.
    static func teamLines(_ held: JSONValue?) throws -> [(String, [String: JSONValue])] {
        guard let lines = held?["lines"]?.array else { throw OwnerRefusal(teamShape) }
        return try lines.map { line in
            guard let map = line.object, case .string(let name)? = map["agent"] else { throw OwnerRefusal(teamShape) }
            return (name, map)
        }
    }

    /// `team_part`: one part of a line, empty when it is absent or empty (Python's truth), and a refusal when it is of
    /// another kind than an object (`object`) or a list.
    static func teamPart(_ map: [String: JSONValue], _ key: String, object: Bool) throws -> JSONValue {
        let found = map.first(where: { PyText.same($0.key, key) })?.value
        guard let value = found, value.truthy else { return object ? .object([:]) : .array([]) }
        guard object ? value.object != nil : value.array != nil else { throw OwnerRefusal(teamShape) }
        return value
    }

    /// `owner_mcp.py`'s GRANT_NOT_SIGNED: the words when `grant_access` does not send a give of a secret
    /// (`secretReaches`). One fixed sentence, which quotes no reference, no agent's name and no word of the hub. It
    /// names `grant_secret` (`GrantSecret`), the link tool with which the app signs the grant, by where it is (the
    /// Mac where the app runs, with the whole command): the same words are the Python server's, which has no such
    /// tool, so they say no "from here". Its end names only the pool: a give that the app signed is in the list
    /// already, so a second call of `grant_access` after it would add nothing, and could change the level that was
    /// chosen.
    static let grantNotSigned = "On this fleet the central vault sends a secret's value to a server only for a grant "
        + "that the owner's app signed for an agent on that server, or for a secret that the owner signed into the "
        + "grantable pool. By the hub's last reading, this secret is not in the pool, the owner signed no grant of it "
        + "for this agent's server, and that server's vault holds no copy of it. A grant from here would show the "
        + "secret as given in the fleet's list and, by that reading, bring its value to no server, so nothing was "
        + "sent. On the Mac where the Founderizer app runs, its program gives the secret with the owner's signature "
        + "(~/.founderizer/cli write grant_secret): the app signs the grant with the owner's key and writes it into "
        + "the list, as the owner's own Give on Secrets does, and the owner can also give it there. After either, "
        + "grant_access needs no second call. If the owner put the secret into the grantable pool a moment ago, call "
        + "grant_access again in a minute: the hub reads the vault at least once a minute."

    /// `vault_reading`: what `secretReaches` and `standingReaches` read of `GET /ui/vault` (`hub.py` `vault_view`),
    /// with each reference in lower case.
    struct VaultReading {
        /// The references that the owner signed into the grantable pool (`central.pool`).
        let pool: [String]
        /// Each grant that the owner signed, as its reference and its machine (`central.grants`).
        let grants: [(login: String, machine: String)]
        /// Each machine with a worker or a lead (`machines`), and whether it takes deliveries now: its `missing` is an
        /// empty list (the page adds `not_pinned` and `pin_mismatch` to it).
        let machines: [(machine: String, takes: Bool)]
        /// For each machine, the references that its vault holds by the hub's own records (`held`, which counts a copy
        /// only when it was sealed to the machine's pin).
        let held: [(machine: String, references: [String])]
    }

    /// `vault_reading`: the reading of the page, or nil when the answer does not say it: a fleet with no central vault
    /// (`central` null or absent), a vault with no good reading (`central.ok` not true, or the page's `error` is set:
    /// the hub's newest read of the vault failed, and the page still has the last good `central`, however old), and
    /// an answer of any other shape than this one. Text of the hub is data: nothing here stops on it.
    static func vaultReading(_ page: JSONValue?) -> VaultReading? {
        guard let page = page?.object, let central = page["central"]?.object,
              central["ok"] == JSONValue.bool(true) else { return nil }
        if let error = page["error"], !error.isNull { return nil }
        guard let pool = central["pool"]?.array, let grants = central["grants"]?.array,
              let machines = page["machines"]?.array, let held = page["held"]?.object else { return nil }
        /// A list of texts as lower-case references, or nil when an element is no text.
        func references(_ list: [JSONValue]) -> [String]? {
            var out: [String] = []
            for item in list {
                guard case .string(let text) = item else { return nil }
                out.append(PyText.asciiLower(text))
            }
            return out
        }
        guard let pooled = references(pool) else { return nil }
        var signed: [(login: String, machine: String)] = []
        for grant in grants {
            guard case .string(let login)? = grant.object?["login"],
                  case .string(let machine)? = grant.object?["machine"] else { return nil }
            signed.append((PyText.asciiLower(login), machine))
        }
        var takes: [(machine: String, takes: Bool)] = []
        for entry in machines {
            guard case .string(let machine)? = entry.object?["machine"],
                  let missing = entry.object?["missing"]?.array else { return nil }
            takes.append((machine, missing.isEmpty))
        }
        var holds: [(machine: String, references: [String])] = []
        for (machine, list) in held {
            guard let list = list.array, let copies = references(list) else { return nil }
            holds.append((machine, copies))
        }
        return VaultReading(pool: pooled, grants: signed, machines: takes, held: holds)
    }

    /// `vault_read`: the read that both rules make first (`secretReaches`, `standingReaches`): `GET /ui/vault`, and
    /// what `vaultReading` reads of its answer, or nil when the page cannot judge: the hub has no such page or refuses
    /// the read, the answer has another shape, the fleet has no central vault, or the vault has no good reading. A hub
    /// that does not answer, and a generation that moved two times, are this program's own errors, as for each of its
    /// reads: the caller sends nothing then.
    func vaultRead(on hub: OwnerHub) throws -> VaultReading? {
        let answer = try hub.answered("/ui/vault")
        if hub.stale(answer) { throw hub.refusal(answer, "a read of the vault") }   // a second new generation
        return answer.status == 200 ? Self.vaultReading(answer.data) : nil
    }

    /// `made_by_an_agent`: step 3b of both rules, on the team's page and a reference in lower case: true when an agent
    /// made this secret, which is when `created_logins` names it (the agents' `create_login` and `save_key`). Such a
    /// value is in the own store of the maker's server, which the page of the vault does not show, so no rule here
    /// judges it. True also for a page with no such list of objects, which cannot say.
    static func madeByAnAgent(_ page: JSONValue?, _ reference: String) -> Bool {
        guard let made = page?.object?["created_logins"]?.array, made.allSatisfy({ $0.object != nil }) else {
            return true
        }
        return made.contains { one in
            guard case .string(let login)? = one.object?["login"] else { return false }
            return PyText.same(PyText.asciiLower(login), reference)
        }
    }

    /// `secret_reaches`: **a give of a secret is sent unless the hub's own reading shows that its value would reach no
    /// server.** On a fleet with a central vault, a machine's vault gets a secret only when the owner signed a grant
    /// of it for an agent of that machine, or signed it into the grantable pool, and only the owner's app signs;
    /// `POST /ui/secrets/grant` writes the grant into the fleet's list with no signature. This refuses only what the
    /// reading shows as never delivered, and it sends each give that it cannot judge. True when the give is sent,
    /// which is each of these, in this order:
    ///
    /// 1. The hub's page of the vault (`GET /ui/vault`) cannot judge: the hub has no such page or refuses the read,
    ///    the answer has another shape, the fleet has no central vault, or the vault has no good reading
    ///    (`vaultReading`).
    /// 2. The reference is in the grantable pool. No read of the team is made for it.
    /// 3. After the read of the fleet's list (`GET /ui/team`):
    ///    a. The catalog (`logins`) does not have the secret, or the level does not fit it: it is not `use` or `read`,
    ///       or it is `read` for an entry whose `kind` is not `api_key`. The hub then answers in its own words. A page
    ///       with no `logins` object is sent too.
    ///    b. An agent made the secret: `created_logins` names it (the agents' `create_login` and `save_key`). Such a
    ///       value is in the own store of the maker's server, which the page of the vault does not show, so this
    ///       program does not judge it. A page with no such list is sent too.
    ///    c. The lines have no such agent, or the agent has no machine. The program sends the give: the hub refuses an
    ///       agent that it does not have, and writes the grant for one with no machine. The door is no agent of the
    ///       lines, so a give to it is sent.
    ///    d. The agent is no worker and no lead (its `role`): the fleet manager, also on a server that it shares with
    ///       workers. The hub's reconciler counts only what workers and leads hold.
    ///    e. The agent's machine is not in `machines` of the vault's page, or it does not take deliveries now (it has
    ///       no pin, or another one): `held` then shows no copy of that machine.
    /// 4. The owner signed a grant of the secret for an agent of that machine: this agent or another one.
    /// 5. That machine's vault holds a copy of the secret already, by the hub's own records.
    ///
    /// False for every other give (6): nothing is sent, and `grantAccess` says `grantNotSigned`.
    ///
    /// The page of the vault is read first, and the team only when the page and the pool did not settle the give, so
    /// a give that is sent makes as few reads as it can. The hub reads the vault at least once a minute, and soon
    /// after a signed statement, so its reading can be that much older than the owner's last signature. A hub that
    /// does not answer, and a generation that moved two times, are this program's own errors, as for each of its
    /// reads, and lines of the team of another shape are `teamShape`: nothing is sent then. This is the program's own
    /// check and no gate (OWNER-MCP-BOUNDARY.md section 7).
    func secretReaches(_ what: String, _ agent: String, _ level: JSONValue, on hub: OwnerHub) throws -> Bool {
        guard let reading = try vaultRead(on: hub) else { return true }                                    // 1
        let reference = PyText.asciiLower(what)
        if reading.pool.contains(where: { PyText.same($0, reference) }) { return true }     // 2: needs no machine
        let page = try hub.get("/ui/team", "a read of the team").data
        // 3a: the hub answers in its own words for a secret that the catalog does not have, and for a level that does
        // not fit it.
        let catalog = page?.object?["logins"]?.object
        let use = PyText.same(level.string, "use"), read = PyText.same(level.string, "read")
        guard let entry = catalog?.first(where: { PyText.same($0.key, reference) })?.value.object, use || read,
              !read || PyText.same(entry["kind"]?.string, "api_key") else { return true }
        if Self.madeByAnAgent(page, reference) { return true }      // 3b: a secret that an agent made is not judged
        let lines = try Self.teamLines(page)
        guard let line = lines.first(where: { PyText.same($0.0, agent) })?.1 else { return true }          // 3c
        // `team_part(line, "machine", str)`: no machine when it is absent or empty, a refusal when it is no text.
        guard let found = line.first(where: { PyText.same($0.key, "machine") })?.value, found.truthy else {
            return true                                                                                    // 3c
        }
        guard case .string(let machine) = found else { throw OwnerRefusal(Self.teamShape) }
        let role = line.first(where: { PyText.same($0.key, "role") })?.value.string
        guard PyText.same(role, "worker") || PyText.same(role, "lead") else { return true }                // 3d
        guard reading.machines.first(where: { PyText.same($0.machine, machine) })?.takes == true else {
            return true                                                                                    // 3e
        }
        if reading.grants.contains(where: { PyText.same($0.login, reference) && PyText.same($0.machine, machine) }) {
            return true                                                                                    // 4
        }
        let copies = reading.held.first(where: { PyText.same($0.machine, machine) })?.references ?? []
        return copies.contains(where: { PyText.same($0, reference) })                                      // 5, else 6
    }

    /// `_team_command`: one command that moves `team.json`, with the SHA-256 of the file that it is built on: that of
    /// `page`, the read of the team that the command's map was made from. A second read would hold a grant that came
    /// after that read, and the map, which does not hold it, would go over it.
    func teamCommand(_ route: String, _ body: [String: JSONValue], _ what: String, _ args: [String: JSONValue],
                     page: JSONValue?, on hub: OwnerHub) throws -> JSONValue? {
        var body = body
        body["base_sha256"] = try OwnerHub.teamSHA256(of: page)
        return try hub.command(route, body, what, requestID: args["request_id"])
    }

    /// `owner_mcp.py`'s SHARE_NOT_SIGNED: the words when `share_resource` does not send a standing for a secret
    /// (`standingReaches`). One fixed sentence, which quotes no reference and no word of the hub. It names
    /// `share_secret` (`ShareSecret`), the link tool with which the app signs the secret into the pool and writes the
    /// standing, by where it is (the Mac where the app runs, with the whole command): the same words are the Python
    /// server's, which has no such tool, so they say no "from here" of it. Its end asks for no second call: the app
    /// writes the standing itself, as its own control does.
    static let shareNotSigned = "On this fleet the central vault sends a secret's value to a server only for a grant "
        + "that the owner's app signed for an agent on that server, or for a secret that the owner signed into the "
        + "grantable pool. By the hub's last reading, this secret is not in the signed pool, the owner signed no grant "
        + "of it for a server, and no server's vault holds a copy of it. A standing from here would let the fleet "
        + "manager give the secret and, by that reading, bring its value to no server, so nothing was sent. On the "
        + "Mac where the Founderizer app runs, its program sets it with the owner's signature (~/.founderizer/cli "
        + "write share_secret): the app signs the secret into the grantable pool and writes the standing, as the "
        + "owner's own Who may give it on Secrets does, and the owner can also set it there. After either, "
        + "share_resource needs no second call."

    /// `DOOR_MACHINE`: the name under which the owner's signed grant for the door stands in the central vault
    /// (`hub.py` `DOOR_PIN`). The door is no server that an agent of the fleet works on, so such a grant brings no
    /// give of the manager to a server.
    static let doorMachine = "door"

    /// `standing_reaches`: **a standing for a secret is sent unless the hub's own reading shows that no give from it
    /// could bring the value to a server.** `POST /ui/resources` writes the standing into the fleet's list with no
    /// signature, and the fleet manager can then give the secret to a worker or a lead. But on a fleet with a central
    /// vault, a server's vault gets a secret only when the owner signed it into the grantable pool, or signed a grant
    /// of it for an agent of that server, and only the owner's app signs: its own control, and `share_secret` of its
    /// program, sign the pool statement first and write the standing after. This is the twin of `secretReaches`, for
    /// every server at once, because a standing names no agent: it refuses only what the reading shows as useless,
    /// and it sends each standing that it cannot judge. `shareResource` makes the two reads: `reading` is the page of
    /// the vault (`vaultRead`; 1: a page that cannot judge is sent), and `page` is the team's (`GET /ui/team`), the
    /// one read that also gives the command its base. True when the standing is sent, which is each of these, in this
    /// order:
    ///
    /// 2. The reference is in the grantable pool that the owner signed.
    /// 3. a. The catalog (`logins`) has no entry for the secret, `most` is not `use` or `read`, or the page has no
    ///       `logins` object. The hub then answers in its own words.
    ///    b. An agent made the secret, or the page has no list of such secrets (`madeByAnAgent`).
    /// 4. The owner signed a grant of the secret for an agent of any server: a give of the manager to an agent on
    ///    that server is delivered. A grant for the door (`doorMachine`) does not count: no give of the manager
    ///    reaches it.
    /// 5. The vault of any server holds a copy of the secret already, by the hub's own records.
    /// 6. A server's entry has something missing (no pin or another one, no access to its vault, an older vault or
    ///    helper, no fresh report): for such a server the hub itself does not say what its vault holds.
    ///
    /// False for every other standing (7): nothing is sent, and `shareResource` says `shareNotSigned`. A fleet with no
    /// worker and no lead has no server in the page of the vault, so with nothing signed its standing is refused too.
    /// References are compared in lower case, as the vault compares them. This is the program's own check and no gate
    /// (OWNER-MCP-BOUNDARY.md section 7).
    static func standingReaches(_ reading: VaultReading, _ page: JSONValue?, _ what: String,
                                _ most: JSONValue) -> Bool {
        let reference = PyText.asciiLower(what)
        if reading.pool.contains(where: { PyText.same($0, reference) }) { return true }                    // 2
        // 3a: the hub answers in its own words.
        let catalog = page?.object?["logins"]?.object
        guard catalog?.first(where: { PyText.same($0.key, reference) })?.value.object != nil,
              PyText.same(most.string, "use") || PyText.same(most.string, "read") else { return true }
        if madeByAnAgent(page, reference) { return true }           // 3b: a secret that an agent made is not judged
        return reading.grants.contains(where: {                                                            // 4
            PyText.same($0.login, reference) && !PyText.same($0.machine, doorMachine)
        })
            || reading.held.contains(where: { $0.references.contains(where: { PyText.same($0, reference) }) })     // 5
            || reading.machines.contains(where: { !$0.takes })                                             // 6, else 7
    }

    /// `share_resource`: `POST /ui/resources`, the owner's standing for one resource. It changes no grant. A standing
    /// for a secret that the hub's reading of the central vault shows as one from which no give could bring the value
    /// to a server is not sent (`standingReaches`). Only a `max` for a resource that the hub reads as a secret is
    /// judged: the hub takes a resource with spaces around it and in any case (`hub.py` `ui_resource`), so the kind is
    /// read here as the hub reads it. Then the page of the vault is read first, and the one read of the team that
    /// every standing makes for its base serves the rule too. Taking the entry back (no `max`) is never refused and
    /// makes no read of the vault, and neither does a standing for a resource of another kind.
    func shareResource(_ args: [String: JSONValue], on hub: OwnerHub) throws -> JSONValue? {
        let resource = args["resource"] ?? .null, most = args["max"] ?? .null
        var policy: JSONValue = .null
        if !most.isNull {
            policy = .object(["max": most, "to": args["to"].flatMap { $0.truthy ? $0 : nil } ?? .string("workers")])
        }
        var reading: VaultReading?, what = ""
        if !policy.isNull, case .string(let text) = resource {
            let (kind, rest) = PyText.partition(PyText.asciiLower(PyText.strip(text)), ":")
            if PyText.same(kind, "secret") {
                what = rest
                reading = try vaultRead(on: hub)    // 1: nil when the page cannot judge, and then the standing is sent
            }
        }
        let page = try hub.get("/ui/team", "a read of the team").data
        if let reading, !Self.standingReaches(reading, page, what, most) {
            throw OwnerRefusal(Self.shareNotSigned)
        }
        return try hub.command("/ui/resources", ["resource": resource, "policy": policy,
                                                 "base_sha256": try OwnerHub.teamSHA256(of: page)],
                               "the standing of this resource", requestID: args["request_id"])
    }


    // ------------------------------------------------------------ files on this Mac

    /// `attach_file`: one file of this Mac to the hub (`POST /ui/attachments`). The body is the file itself, so its
    /// request id and its name are headers; the upload holds the lock for its one request, and a new generation is
    /// read again once with the same request id.
    func attachFile(_ args: [String: JSONValue], on hub: OwnerHub) throws -> JSONValue? {
        guard case .string(let given)? = args["path"], !PyText.strip(given).isEmpty
        else { throw OwnerRefusal("path must be the file on this Mac to send.") }
        let place = try localPlace(given)              // a NUL first, before "~" is expanded
        guard LocalFile.isFile(place) else { throw OwnerRefusal("\(place) is not a file on this Mac.") }
        let most = Transfer.attachment.limit
        let tooLarge = { (size: Int) in
            OwnerRefusal("\(place) is \(size) bytes; an attachment is at most \(most / (1024 * 1024)) MiB.")
        }
        let data: Data
        do {
            let size = try LocalFile.size(place)
            if size > most { throw tooLarge(size) }
            data = try LocalFile.read(place)
        } catch let failure as LocalFile.Failure {
            throw OwnerRefusal("\(place) could not be read on this Mac: \(failure.reason).")
        }
        if data.count > most { throw tooLarge(data.count) }
        let rid = (args["request_id"].flatMap { $0.truthy ? $0.pythonText : nil } ?? UUID().uuidString).lowercased()
        let named = PyText.strip(args["mime"].flatMap { $0.truthy ? $0.pythonText : nil } ?? "")
        let fileName = LocalFile.name(place)
        let mime = named.isEmpty ? MediaType.guess(fileName, table.mediaTypes) : named
        let header = String(String.UnicodeScalarView(fileName.unicodeScalars.map {
            (0x20...0x7E).contains($0.value) ? $0 : "_"
        }))
        func once(_ db: String) throws -> HubAnswer {
            try CommandLock.holding(hub.lockFile) {
                try hub.call("POST", "/ui/attachments?db=\(OwnerHub.quote(db, safe: "/"))",
                             file: (data, mime, [("X-Fleet-Request-Id", rid), ("X-Fleet-Name", header)]),
                             transfer: Transfer(limit: Transfer.call.limit, file: true))
            }
        }
        var answer = try once(try hub.generation())
        if hub.stale(answer) { answer = try once(try hub.generation(fresh: true)) }
        guard answer.status == 200 else { throw hub.refusal(answer, "the upload of \(fileName)") }
        var result = answer.data?.object ?? [:]
        result["path"] = .string(place)
        return .object(result)
    }

    /// `read_attachment`: `GET /ui/attachments/<id>` into a file on this Mac, checked against the hub's own SHA-256.
    /// It writes the bytes and opens none of them.
    func readAttachment(_ args: [String: JSONValue], on hub: OwnerHub) throws -> JSONValue? {
        guard case .int(let number)? = args["attachment"], number >= 1 else {
            throw OwnerRefusal("attachment must be the number of an attachment (A-<id> without the A-).")
        }
        guard case .string(let given)? = args["path"], !PyText.strip(given).isEmpty
        else { throw OwnerRefusal("path must be where on this Mac the file is written.") }
        var place = try localPlace(given)
        let answer = try hub.get("/ui/attachments/\(number)", "attachment A-\(number)", transfer: .attachment)
        let digest = Self.sha256(answer.raw)
        if let said = answer.headers["x-fleet-sha256"], !said.isEmpty, !PyText.same(said, digest) {
            throw OwnerRefusal("the file did not arrive whole: the hub's SHA-256 is not the one of the bytes received.")
        }
        var folder: String?
        if LocalFile.isFolder(place) {
            folder = place
            place = try Self.intoFolder(place, Self.hubFileName(answer, fallback: "attachment-\(number)"))
        }
        try Self.write(answer.raw, to: place, newIn: folder)
        let mime = PyText.strip(PyText.partition(answer.headers["content-type"] ?? "", ";").0)
        return .object(["attachment": .int(number), "path": .string(place), "bytes": .int(Int64(answer.raw.count)),
                        "sha256": .string(digest), "mime": .string(mime)])
    }

    /// `take_backup`: `GET /ui/backup` into a file on this Mac, then `POST /ui/backups/confirm` once the bytes are
    /// checked against the hub's own SHA-256. No copy stays on the hub machine.
    ///
    /// The copy goes into a new file of mode 600 in the folder where it is kept, as it arrives (`Transfer.copy(into:)`),
    /// so a copy of any size takes no more of this Mac's memory than one part; the file gets its name only once its
    /// SHA-256 is the hub's, and goes on every other way out (`owner_mcp.py`'s `take_backup` and `kept_as`).
    func takeBackup(_ args: [String: JSONValue], on hub: OwnerHub) throws -> JSONValue? {
        guard case .string(let given)? = args["path"], !PyText.strip(given).isEmpty
        else { throw OwnerRefusal("path must be where on this Mac the copy is written.") }
        var place = try localPlace(given)
        let folder: String? = LocalFile.isFolder(place) ? place : nil
        let coming: String
        do {
            try LocalFile.makeFolders(folder ?? LocalFile.parent(place))
            coming = try LocalFile.made(in: folder ?? LocalFile.parent(place), prefix: "founderizer-copy-",
                                        suffix: ".part")
        } catch let failure as LocalFile.Failure {
            throw OwnerRefusal("\(place) could not be written on this Mac: \(failure.reason).")
        }
        defer { LocalFile.remove(coming) }
        let started = ProcessInfo.processInfo.systemUptime
        let answer: HubAnswer
        do {
            answer = try hub.get("/ui/backup", "a copy of this fleet", transfer: .copy(into: coming))
        } catch let refused as OwnerRefusal {
            if ProcessInfo.processInfo.systemUptime - started >= Transfer.copyTotal { throw OwnerRefusal(Self.copySlow) }
            throw refused
        }
        let (bytes, digest): (Int, String)
        do { (bytes, digest) = try LocalFile.digest(coming) } catch let failure as LocalFile.Failure {
            throw OwnerRefusal("\(place) could not be written on this Mac: \(failure.reason).")
        }
        if let said = answer.headers["x-fleet-backup-sha256"], !said.isEmpty, !PyText.same(said, digest) {
            throw OwnerRefusal("the copy did not arrive whole: the hub's SHA-256 is not the one of the bytes received.")
        }
        if let folder {
            let fallback = "founderizer-\(Int(context.now().timeIntervalSince1970)).zip"
            place = try Self.intoFolder(folder, Self.hubFileName(answer, fallback: fallback))
        }
        try Self.keep(coming, as: place, newIn: folder)     // before the confirmation: a refusal confirms nothing
        let receipt = try hub.command("/ui/backups/confirm", ["sha256": .string(digest), "bytes": .int(Int64(bytes))],
                                      "the confirmation of the copy", requestID: args["request_id"])
        var result = receipt?.object ?? [:]
        result["path"] = .string(place)
        result["bytes"] = .int(Int64(bytes))
        result["sha256"] = .string(digest)
        return .object(result)
    }

    /// `owner_mcp.py`'s COPY_SLOW: a copy that did not arrive within one tool call's time.
    static let copySlow = "The copy did not arrive in \(Int(Transfer.copyTotal) / 60) minutes, the most that one tool "
        + "call waits, so nothing was kept. Save copy in Settings \u{203A} Backup of the Founderizer app has no such "
        + "limit of time."

    /// `owner_mcp.py`'s `kept_as`: the file `coming` under its name `place`, in one step (`rename`). In a folder that
    /// the agent named, the name is made new and only new first (`O_CREAT|O_EXCL`, which follows no link at its last
    /// part), so a file, a link or a folder of that name stays as it is and nothing is kept; a file that the agent named
    /// is replaced.
    static func keep(_ coming: String, as place: String, newIn folder: String?) throws {
        do {
            guard LocalFile.callable(place) else { throw LocalFile.Failure(EINVAL) }
            if let folder {
                let made = open(place, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
                if made < 0 {
                    let code = errno
                    if code == EEXIST {
                        throw OwnerRefusal("\(LocalFile.name(place)) is there already in \(LocalFile.normal(folder)), so "
                                           + "nothing was written. Name the file itself in path to replace it, or name "
                                           + "another folder.")
                    }
                    throw LocalFile.Failure(code)
                }
                close(made)
            }
            guard rename(coming, place) == 0 else { throw LocalFile.Failure(errno) }
        } catch let failure as LocalFile.Failure {
            throw OwnerRefusal("\(place) could not be written on this Mac: \(failure.reason).")
        }
    }

    // ------------------------------------------------------------ the parts that the tools share

    /// Python's `str(value or "")`.
    static func text(_ value: JSONValue?) -> String {
        guard let value, value.truthy else { return "" }
        return value.pythonText
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// **The hub's name of a file counts only as one new, plain file name** (`owner_mcp.py`'s `hub_file_name`): what
    /// follows `filename=` in `Content-Disposition`, with its quotes taken off and cut at its first NUL. A name that is
    /// empty, that starts with "." (".", "..", a dot file), that holds "/", or that holds a character outside printable
    /// ASCII is not used, and the fallback is.
    static func hubFileName(_ answer: HubAnswer, fallback: String) -> String {
        let said = answer.headers["content-disposition"] ?? ""
        var name = PyText.strip(PyText.partition(said, "filename=").1, only: "\"")
        name = PyText.partition(name, "\u{0}").0
        let bad = name.unicodeScalars.contains { $0 == "/" || !(0x20...0x7E).contains($0.value) }
        if name.isEmpty || name.unicodeScalars.first == "." || bad { return fallback }
        return name
    }

    /// `owner_mcp.py`'s `local_place`: the path that the agent named, refused when it holds a NUL, which no system call
    /// can take (a C call would cut the path there).
    func localPlace(_ given: String) throws -> String {
        guard !given.unicodeScalars.contains("\u{0}") else {
            throw OwnerRefusal("path cannot hold a NUL character: name a file or a folder of this Mac.")
        }
        return localPath(PyText.strip(given))
    }

    /// `owner_mcp.py`'s `into_folder`: the folder and the name, refused unless the file's own folder is that folder.
    static func intoFolder(_ folder: String, _ name: String) throws -> String {
        let place = LocalFile.join(folder, name)
        guard PyText.same(LocalFile.parent(place), LocalFile.normal(folder)) else {
            throw OwnerRefusal("the hub's name of the file would put it outside \(LocalFile.normal(folder)), so "
                               + "nothing was written.")
        }
        return place
    }

    /// The bytes into a file on this Mac, its folders made; a file that cannot be written is a refusal in words with
    /// the system's reason, as `owner_mcp.py`'s `write_here` says it. `newIn`: the agent named that folder, so the file
    /// is made new and only new, and follows no link (`O_CREAT|O_EXCL|O_NOFOLLOW`): a file, a link or a folder of that
    /// name stays as it is, and nothing is written.
    static func write(_ data: Data, to place: String, newIn folder: String? = nil) throws {
        var creating = false
        do {
            try LocalFile.makeFolders(LocalFile.parent(place))
            creating = true
            try LocalFile.write(data, to: place, new: folder != nil)
        } catch let failure as LocalFile.Failure {
            // Only the create's own EEXIST: a file in the way of the folders is the system's words below.
            if let folder, creating, failure.code == EEXIST {
                throw OwnerRefusal("\(LocalFile.name(place)) is there already in \(LocalFile.normal(folder)), so "
                                   + "nothing was written. Name the file itself in path to replace it, or name another "
                                   + "folder.")
            }
            throw OwnerRefusal("\(place) could not be written on this Mac: \(failure.reason).")
        }
    }

    /// `str(pathlib.Path(os.path.expanduser(text)))`: "~" is the home of this process (`$HOME`), "~user" that user's
    /// home, and the path as `pathlib` writes it. On Unicode scalars, as Python reads a text.
    func localPath(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        guard scalars.first == "~" else { return LocalFile.normal(text) }
        let slash = scalars.firstIndex(of: "/") ?? scalars.count
        let user = PyText.string(scalars[1..<slash])
        let rest = PyText.string(scalars[slash...])
        var home: String
        if user.isEmpty {
            home = context.home.path
        } else {
            let expanded = ("~" + user as NSString).expandingTildeInPath
            guard expanded.unicodeScalars.first != "~" else { return LocalFile.normal(text) }
            home = expanded
        }
        while home.unicodeScalars.count > 1 && home.unicodeScalars.last == "/" { home.unicodeScalars.removeLast() }
        if PyText.same(home, "/") { home = "" }
        let path = home + rest
        return LocalFile.normal(path.isEmpty ? "/" : path)
    }
}

/// **Python's own reading of a text, on Unicode scalars**: Swift compares and splits `String` by characters, with
/// canonical equivalence, and Python by code points, so a combining mark after ":" or "/" (`"repo:\u{301}x"`) is one
/// character in Swift and two code points in Python. Each split, strip and compare of a text that `owner_mcp.py` makes
/// is made here the way Python makes it.
enum PyText {
    /// The characters of Python's `str.isspace`, which `str.strip()` takes off.
    static let space: Set<UInt32> = Set([0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E, 0x1F, 0x20, 0x85, 0xA0,
                                          0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000] + Array(0x2000...0x200A))
    /// The characters that Python's `int()` takes off a text: `space` without U+001C to U+001F (measured with
    /// Python 3.12 over every code point: `int("\x1c5")` is a ValueError); `owner_mcp.py` INT_SPACE. Both programs
    /// read a whole number by one rule (`OwnerTools.wholeNumber`), which takes ASCII digits alone.
    static let intSpace: Set<UInt32> = space.subtracting([0x1C, 0x1D, 0x1E, 0x1F])

    static func string<S: Sequence>(_ scalars: S) -> String where S.Element == Unicode.Scalar {
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars)
        return String(out)
    }

    /// `text.strip()`, `text.strip(only)` with `only`, or a strip of the characters of `set`.
    static func strip(_ text: String, only: String? = nil, set: Set<UInt32>? = nil) -> String {
        let taken = only.map { Set($0.unicodeScalars.map(\.value)) } ?? set ?? space
        let scalars = Array(text.unicodeScalars)
        guard let first = scalars.firstIndex(where: { !taken.contains($0.value) }),
              let last = scalars.lastIndex(where: { !taken.contains($0.value) }) else { return "" }
        return string(scalars[first...last])
    }

    /// `text.partition(separator)`: the part before the first separator and the part after it. With no separator, the
    /// text and "", as Python's `[0]` and `[2]`.
    static func partition(_ text: String, _ separator: String) -> (String, String) {
        let scalars = Array(text.unicodeScalars), mark = Array(separator.unicodeScalars)
        guard !mark.isEmpty, scalars.count >= mark.count else { return (text, "") }
        for start in 0...(scalars.count - mark.count) where Array(scalars[start..<start + mark.count]) == mark {
            return (string(scalars[..<start]), string(scalars[(start + mark.count)...]))
        }
        return (text, "")
    }

    /// Python's `==` of two texts: the same code points, not only the same characters.
    static func same(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return a.unicodeScalars.elementsEqual(b.unicodeScalars)
    }

    static func contains(_ text: String, _ scalar: Unicode.Scalar) -> Bool { text.unicodeScalars.contains(scalar) }

    /// `owner_mcp.py`'s `lower_reference`: a text with A to Z in lower case, and every other code point as it is. A
    /// secret's reference is ASCII, and the two programs must lower each text the same way: `lowercased()` and
    /// Python's `str.lower()` do not agree on every letter.
    static func asciiLower(_ text: String) -> String {
        string(text.unicodeScalars.map { (0x41...0x5A).contains($0.value) ? Unicode.Scalar($0.value + 32)! : $0 })
    }
}

/// **The media type of a file that the agent attaches with no `mime`**, by its ending in lower case, from the table
/// (`owner_mcp.py` MEDIA_TYPES, which `--dump-tools` carries): the hub's own types and their other endings. Every
/// other file is `application/octet-stream`. The program keeps no table of its own.
public enum MediaType {
    public static func guess(_ name: String, _ types: [String: String]) -> String {
        types[LocalFile.suffix(name).lowercased()] ?? "application/octet-stream"
    }
}

/// **A file on this Mac, with the system's own words for what went wrong** (`strerror`, as Python's `OSError.strerror`
/// gives them), and paths written as Python's `pathlib` writes them, on Unicode scalars.
enum LocalFile {
    struct Failure: Error {
        let code: Int32
        let reason: String
        init(_ code: Int32) {
            self.code = code
            reason = String(cString: strerror(code))
        }
    }

    /// A path that a C call would cut at a NUL never reaches one: the tools refuse it before (`localPlace`), and each
    /// call here refuses it too.
    static func callable(_ path: String) -> Bool { !path.unicodeScalars.contains("\u{0}") }

    static func parts(_ path: String) -> [String] {
        Array(path.unicodeScalars).split(separator: "/").map { PyText.string($0) }
    }

    /// The path as `pathlib.PurePosixPath` writes it: no empty part, no ".", no "/" at the end; two "/" at the start
    /// stay two, as POSIX lets them.
    static func normal(_ path: String) -> String {
        let scalars = Array(path.unicodeScalars)
        let slashes = scalars.prefix { $0 == "/" }.count
        let root = slashes == 2 ? "//" : slashes > 0 ? "/" : ""
        let kept = parts(path).filter { !PyText.same($0, ".") }
        if kept.isEmpty { return root.isEmpty ? "." : root }
        return root + kept.joined(separator: "/")
    }

    /// `place / name` of `pathlib`: nothing is added after a root ("/", "//"), and "." or "" is no place at all.
    /// Checked against `PurePosixPath` (`OwnerWriteTests.pathsAreWrittenAsPathlibWritesThem`).
    static func join(_ place: String, _ name: String) -> String {
        if name.unicodeScalars.first == "/" { return normal(name) }
        let base = normal(place)
        if PyText.same(base, ".") { return normal(name) }
        if base.unicodeScalars.last == "/" { return normal(base + name) }        // the root "/" or "//"
        return normal(base + "/" + name)
    }

    /// `Path.name`: the last part.
    static func name(_ path: String) -> String { parts(normal(path)).last ?? "" }

    /// `Path.parent`.
    static func parent(_ path: String) -> String {
        let normal = Array(normal(path).unicodeScalars)
        guard let slash = normal.lastIndex(of: "/") else { return "." }
        let head = PyText.string(normal[..<slash])
        if head.isEmpty || PyText.same(head, "/") { return normal.starts(with: ["/", "/"]) ? "//" : "/" }
        return head
    }

    /// The ending of a name as Python's `os.path.splitext` finds it: after the last ".", where a run of "." at the
    /// start of the name does not count (".png" has none).
    static func suffix(_ name: String) -> String {
        let rest = Array(name.unicodeScalars.drop { $0 == "." })
        guard let dot = rest.lastIndex(of: ".") else { return "" }
        return PyText.string(rest[(dot + 1)...])
    }

    /// `Path.is_file()`: false for a path with a NUL, as in Python.
    static func isFile(_ path: String) -> Bool {
        var info = stat()
        return callable(path) && stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    static func isFolder(_ path: String) -> Bool {
        var info = stat()
        return callable(path) && stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    static func size(_ path: String) throws -> Int {
        var info = stat()
        guard callable(path) else { throw Failure(EINVAL) }
        guard stat(path, &info) == 0 else { throw Failure(errno) }
        return Int(info.st_size)
    }

    static func read(_ path: String) throws -> Data {
        guard callable(path) else { throw Failure(EINVAL) }
        let handle = open(path, O_RDONLY | O_CLOEXEC)
        guard handle >= 0 else { throw Failure(errno) }
        defer { close(handle) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let count = Darwin.read(handle, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw Failure(errno)
            }
            if count == 0 { return data }
            data.append(buffer, count: count)
        }
    }

    /// `tempfile.mkstemp(prefix:suffix:dir:)`: a new file of mode 600 in `folder`, with a name of its own between
    /// `prefix` and `suffix` (`mkstemps`), and its path.
    static func made(in folder: String, prefix: String, suffix: String) throws -> String {
        guard callable(folder) else { throw Failure(EINVAL) }
        var template = Array(join(folder, prefix + "XXXXXXXX" + suffix).utf8CString)
        let handle = mkstemps(&template, Int32(suffix.utf8.count))
        guard handle >= 0 else { throw Failure(errno) }
        close(handle)
        return String(cString: template)
    }

    /// The file at `path` goes, when it is there.
    static func remove(_ path: String) {
        guard callable(path) else { return }
        unlink(path)
    }

    /// (the size, the SHA-256) of the file at `path`, read in parts of 1 MiB: never whole in memory.
    static func digest(_ path: String) throws -> (Int, String) {
        guard callable(path) else { throw Failure(EINVAL) }
        let handle = open(path, O_RDONLY | O_CLOEXEC)
        guard handle >= 0 else { throw Failure(errno) }
        defer { close(handle) }
        var hash = SHA256(), size = 0
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let count = Darwin.read(handle, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw Failure(errno)
            }
            if count == 0 { return (size, hash.finalize().map { String(format: "%02x", $0) }.joined()) }
            hash.update(data: buffer[0..<count])
            size += count
        }
    }

    /// `Path.mkdir(parents=True, exist_ok=True)`.
    static func makeFolders(_ path: String) throws {
        guard callable(path) else { throw Failure(EINVAL) }
        if mkdir(path, 0o777) == 0 { return }
        let first = errno
        if first == ENOENT, !PyText.same(parent(path), path) {
            try makeFolders(parent(path))
            if mkdir(path, 0o777) == 0 { return }
            let again = errno
            if isFolder(path) { return }
            throw Failure(again)
        }
        if isFolder(path) { return }
        throw Failure(first)
    }

    /// `Path.write_bytes`: the file made or emptied, then the bytes. `new`: `open(path, "xb")`, made new and only new,
    /// following no link at its last part; EEXIST when anything of that name is there.
    static func write(_ data: Data, to path: String, new: Bool = false) throws {
        guard callable(path) else { throw Failure(EINVAL) }
        let flags = new ? O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC : O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC
        let handle = open(path, flags, 0o666)
        guard handle >= 0 else { throw Failure(errno) }
        defer { close(handle) }
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var done = 0
            while done < bytes.count {
                let count = Darwin.write(handle, bytes.baseAddress! + done, bytes.count - done)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw Failure(errno)
                }
                done += count
            }
        }
    }
}
