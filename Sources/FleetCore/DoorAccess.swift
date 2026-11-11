import CryptoKit
import Foundation

/// **The door's access file, kept by this Mac by itself** (DevOps plan C5 and D8: "Servers go by business").
///
/// The door knows each caller by its address on the private network, and only root writes the file that names them
/// (`/etc/fleet-door/access.json`, through the root command `door-access`). Each business's DevOps agent holds every
/// server of its business at Fix, and no other agent holds a server. Both come from the tailnet policy, which the owner
/// sets and the hub cannot change: a server's business is its tag `tag:business-<name>`, and the business's DevOps agent
/// is the one agent alone on the box with the tag `tag:operator-<name>`, its name read from that box itself. So this
/// reads this Mac's own Tailscale (never the hub) for the door, the servers and the boxes, reads each server's second
/// sshd and each operator box over its own SSH, and writes the file again when that changes. Nothing waits for a press,
/// and nothing shows on a page.
///
/// The file holds more than this: the hub, the agents' other rights, the provider accounts, the pools, the windows and
/// the never list. A Mac session writes those once, when the owner says so, and this keeps every one of them. What this
/// writes is `hosts` (the servers whose second sshd answered), each Operator's address and `servers`, and no `servers`
/// for any other agent, and the owner key of this Mac with the fleet's id (`owner_keys`, `fleet`), which the door
/// checks the owner's signed yes to a door call against. The door checks the whole file again (`door.validate_access`).
public enum DoorAccess {
    /// The tag of the door's own device in the tailnet policy.
    public static let doorTag = "tag:door"
    /// A server's business: `tag:business-<name>`.
    public static let businessTag = "tag:business-"
    /// The box of a business's DevOps agent: `tag:operator-<name>`.
    public static let operatorTag = "tag:operator-"
    /// The door as a holder of the central vault: the agent and the machine of its grants, and the name of its pinned
    /// key. A secret that the door holds is sealed to that key, and only the door's own OS user opens it.
    public static let holder = "door"
    /// The second sshd's port on a managed host (`host/install.sh`).
    public static let sshdPort = 2244
    /// The file, as root reads it on the door.
    public static let readProgram = "cat /etc/fleet-door/access.json"
    /// The root command that takes the whole file on its standard input and checks it before it writes it.
    public static let writeProgram = "/usr/local/sbin/door-access"
    /// What a managed host says about its own parts: the second sshd's host key, ops-root's mode file, and whether the
    /// host is a machine of the fleet (`install.sh --fleet-kit`). A host without the parts prints no key, and so does a
    /// host whose second sshd does not run: an install that stopped after it made the key (7 November 2026, the canary's
    /// first install) has no parts.
    public static let hostProgram = "systemctl is-active --quiet ops-sshd.service && "
        + "cat /etc/ops-root/ssh_host_ed25519_key.pub 2>/dev/null; "
        + "echo \"mode=$(cat /etc/ops-root/mode 2>/dev/null)\"; test -e /etc/ops-root/fleet-kit && echo fleet=yes; true"
    /// The OS users of the agents on an operator box: the members of the group that every agent's user is in.
    public static let boxProgram = "getent group fleet-agents | cut -d: -f4"
    /// The door's service port on the private network, the default of its entry in the fleet's configuration.
    public static let doorPort = 8766

    /// What a door with no follow timer yet runs once (DevOps plan 13, item 2): the hub's signed release, which the
    /// door checks with its own pinned keys, through the door's own root command. That release's update writes the
    /// timer, and from then on the door takes each release by itself. A door with the timer only says so. nil when the
    /// hub's address is not one that the door's file can hold.
    public static func followProgram(hub: String, port: Int) -> String? {
        guard hub.range(of: "^[0-9a-f.:]{2,45}$", options: .regularExpression) != nil, (1...65535).contains(port) else { return nil }
        let host = hub.contains(":") ? "[\(hub)]" : hub
        return "if [ \"$(systemctl is-enabled fleet-door-follow.timer 2>/dev/null)\" = enabled ]; then echo follow=enabled; "
            + "else curl -fsS --max-time 30 'http://\(host):\(port)/door/release' | /usr/local/sbin/door-update; fi"
    }

    // MARK: this Mac's Tailscale

    /// One device of the private network, as this Mac's own Tailscale says.
    public struct Device: Equatable, Sendable {
        /// Its name in Tailscale: the first label of its MagicDNS name, lower case, which is its name in Fleet too.
        public let name: String
        /// Its first IPv4 address on the private network.
        public let address: String?
        public let tags: [String]

        public init(name: String, address: String?, tags: [String]) {
            self.name = name; self.address = address; self.tags = tags
        }

        /// The businesses of its `tag:business-<name>` tags.
        public var businesses: [String] { DoorAccess.names(tags, after: DoorAccess.businessTag) }
        /// The businesses of its `tag:operator-<name>` tags.
        public var operates: [String] { DoorAccess.names(tags, after: DoorAccess.operatorTag) }
    }

    /// Every device of `tailscale status --json`: this Mac and its peers. A device with no name is left out.
    public static func devices(status json: String) -> [Device] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let peers = (object["Peer"] as? [String: Any])?.values.compactMap { $0 as? [String: Any] } ?? []
        let nodes = [object["Self"] as? [String: Any]].compactMap { $0 } + peers
        return nodes.compactMap { node -> Device? in
            let full = ((node["DNSName"] as? String) ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard let name = full.split(separator: ".").first.map(String.init), isName(name) else { return nil }
            let address = ((node["TailscaleIPs"] as? [String]) ?? []).first { ClaimCode.isPrivateAddress($0) && !$0.contains(":") }
            return Device(name: name, address: address, tags: ((node["Tags"] as? [String]) ?? []).sorted())
        }.sorted { $0.name < $1.name }
    }

    /// The door: the one device with the door's tag. nil when there is none, or more than one.
    public static func door(in devices: [Device]) -> Device? {
        let doors = devices.filter { $0.tags.contains(doorTag) }
        return doors.count == 1 ? doors.first : nil
    }

    /// The box of each business's DevOps agent: the one device with that business's operator tag and no other operator
    /// tag. A business whose operator tag two devices carry, or whose box operates two businesses, has none.
    public static func operatorBoxes(devices: [Device]) -> [String: Device?] {
        var boxes: [String: Device?] = [:]
        for business in Set(devices.flatMap(\.operates)).sorted() {
            let carriers = devices.filter { $0.operates.contains(business) && !$0.tags.contains(doorTag) }
            boxes[business] = carriers.count == 1 && carriers[0].operates == [business] ? carriers[0] : nil
        }
        return boxes
    }

    /// The agent of an operator box, from the box itself: its one agent's OS user, `fleet-<agent>`. nil when the box
    /// holds no agent's user, or more than one.
    public static func operatorAgent(users: [String]) -> String? {
        guard users.count == 1, users[0].hasPrefix("fleet-") else { return nil }
        let agent = String(users[0].dropFirst("fleet-".count))
        return agent.range(of: "^[a-z][a-z0-9-]{1,30}$", options: .regularExpression) != nil ? agent : nil
    }

    // MARK: the file

    /// What a host's own parts said over SSH (`hostProgram`), or nil when it has no second sshd's key.
    public struct HostReading: Equatable, Sendable {
        /// `ssh-ed25519 <key>`, with no comment, as the door pins it.
        public let hostKey: String
        /// ops-root's own mode file: `fix`, or `rule-only` for anything else, as ops-root reads it.
        public let mode: String
        /// The host is a machine of the fleet: the door never places a key there.
        public let fleet: Bool

        public init(hostKey: String, mode: String, fleet: Bool) {
            self.hostKey = hostKey; self.mode = mode; self.fleet = fleet
        }

        public init?(output: String) {
            let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let key = lines.first(where: { $0.hasPrefix("ssh-ed25519 ") }) else { return nil }
            let words = key.split(separator: " ")
            let pinned = words.count >= 2 ? "ssh-ed25519 \(words[1])" : ""
            guard pinned.range(of: "^ssh-ed25519 [A-Za-z0-9+/=]{60,100}$", options: .regularExpression) != nil else { return nil }
            let mode = lines.first { $0.hasPrefix("mode=") }.map { String($0.dropFirst(5)) }
            self.init(hostKey: pinned, mode: mode == "fix" ? "fix" : "rule-only", fleet: lines.contains("fleet=yes"))
        }
    }

    /// The OS users that a box's `boxProgram` named.
    public static func boxUsers(output: String) -> [String] {
        output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.sorted()
    }

    /// One business's DevOps agent, as its operator box answered: the agent, and the box's address.
    public struct Operator: Equatable, Sendable {
        public let agent: String
        public let address: String

        public init(agent: String, address: String) { self.agent = agent; self.address = address }
    }

    /// What this Mac read for one round.
    /// The owner key that signs his yes to a door call (owner feature `door_calls`), and his fleet's id. One Mac at a
    /// time holds a fleet's owner key (`OwnerKeychain.make`), so the file names that one key.
    public struct OwnerPin: Equatable, Sendable {
        public let key: String
        public let fleet: String
        public init(key: String, fleet: String) { self.key = key; self.fleet = fleet }
    }

    /// The hub's view for keeping the door (owner feature `door_setup`, `GET /ui/door`, DevOps plan 13, items 1 and 3):
    /// the door's entry in the fleet's configuration, each credential of the door's rules that a key card asked for
    /// with the agents that use it, and each agent's machine address and OS user, as its own helper reports it.
    public struct HubDoor: Decodable, Equatable, Sendable {
        public struct Entry: Decodable, Equatable, Sendable {
            public let address: String
            public let port: Int
        }
        public struct Credential: Decodable, Equatable, Sendable {
            public let secret: String
            public let agents: [String]
        }
        public struct Agent: Decodable, Equatable, Sendable {
            public let address: String
            public let user: String?
            /// {owner/name: read, write or deploy}: the agent's GitHub grants, by which the door makes its tokens once
            /// the hub asks it for every token (plan 13, item 4). nil from a hub before that.
            public var repos: [String: String]? = nil
        }
        /// The hub's own GitHub App key, which the app moves to the door (plan 13, item 4): its id, and the path of its
        /// file on the hub machine, which only root and the hub's user read.
        public struct GitHubApp: Decodable, Equatable, Sendable {
            public let app_id: String
            public let path: String
        }
        public let door: Entry?
        public let credentials: [String: Credential]
        public let agents: [String: Agent]
        public let db: String
        /// nil when the hub holds no App key of its own, or is from before plan 13, item 4.
        public var github_app: GitHubApp? = nil
        /// The hub gets every GitHub token from the door.
        public var linked: Bool? = nil
        /// {account in lower case: App ID} of the Apps that this app made with GitHub's manifest flow, whose keys the
        /// door holds (API 1.94). nil from a hub before that.
        public var github_apps: [String: String]? = nil
        /// The key that the central vault holds pinned under the name door, to which alone the hub seals the door's
        /// keys, or nil (API 1.99). vault_read is false while the hub has no status of the central vault, and nil
        /// from a hub before that: then the app pins nothing.
        public var vault_pin: String? = nil
        public var vault_read: Bool? = nil
        /// The manager's `door_rollout` (API 1.100): the door's parts go on the servers after the first one. nil from a
        /// hub before that, which puts them on no server.
        public var rollout: Bool? = nil
        /// The servers that a plan step holds, from the manager's `door_hold` (API 1.101): `parts` (no door parts, and
        /// no entry in the door's file, so nobody gets the server through the door) or `rule-only` (its parts and its
        /// Operator, and the door's file holds it as rule-only, so only rule calls run there). `judged` is the old
        /// name of `rule-only`, which a hub still gives for a hold that it kept from before.
        public var holds: [String: String]? = nil
        /// A GitOps repository that the manager's `door_gitops` gives Operators through the door (API 1.111): its caller
        /// workflow, which the door dispatches to sync an app, and the agents that get it.
        public struct GitOps: Decodable, Equatable, Sendable {
            public let sync: String
            public let agents: [String]
        }
        /// {owner/name: GitOps}. nil from a hub before API 1.111, which leaves the file's GitOps targets as they are.
        public var gitops: [String: GitOps]? = nil

        /// The names of a hold that keeps a server's parts and makes it rule-only.
        public static let ruleOnlyHolds: Set<String> = ["rule-only", "judged"]

        /// The servers held at `parts`.
        public var heldOut: Set<String> { Set((holds ?? [:]).filter { !Self.ruleOnlyHolds.contains($0.value) }.keys) }

        /// The servers held at `rule-only`.
        public var ruleOnly: Set<String> { Set((holds ?? [:]).filter { Self.ruleOnlyHolds.contains($0.value) }.keys) }

        /// True when the hub reads the central vault and holds no pin of the door's own key under door.
        public func needsPin(of recipient: String) -> Bool { vault_read == true && vault_pin != recipient }

        /// The hub's name of an Operator that its box named by its OS user: the one agent whose machine has the box's
        /// address and whose own helper reports that OS user. nil when the hub shows none, or two: the box's own name
        /// then stays, so the hub gives a name only to the agent that the box itself shows.
        public func name(of found: Operator) -> String? {
            let names = agents.filter { $0.value.address == found.address && $0.value.user == "fleet-" + found.agent }.map(\.key)
            return names.count == 1 && DoorAccess.isName(names[0]) ? names[0] : nil
        }

        /// What decides, with the devices, whether a round must write the file again.
        public var digest: String {
            (credentials.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.secret) \($0.value.agents.sorted().joined(separator: ","))" }
                + agents.sorted { $0.key < $1.key }.map { name, agent in
                    "\(name) \(agent.address) \(agent.user ?? "-") "
                        + (agent.repos ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
                }
                + ["app \(github_app?.app_id ?? "-") linked \(linked == true)",
                   "pin \(vault_pin ?? "-") read \(vault_read == true) rollout \(rollout.map(String.init) ?? "-")",
                   "holds " + (holds ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","),
                   "gitops " + (gitops.map { $0.sorted { $0.key < $1.key }
                       .map { "\($0.key)=\($0.value.sync):\($0.value.agents.sorted().joined(separator: "+"))" }
                       .joined(separator: ",") } ?? "-")])
                .joined(separator: "\n")
        }
    }

    /// A credential of a provider account that a key card asks for the door (`request_secret` with `door`): the hub's
    /// view lists all of them. `aws:` (the door's own bot) and `github:` (the app's GitHub App rows) are not of them.
    /// `app:<app>:<NAME>` is the key of one setting of one app on a host (new-projects plan N4, UI-API 1.97), which the
    /// door's env-new puts in that app's settings: a name of any other shape is left out, because the door refuses a
    /// whole access file that has a name it does not know.
    static let cardProviders = ["backblaze:", "cloudflare:", "hetzner:", "azure:", "tailscale:"]
    static func cardCredential(_ name: String) -> Bool {
        cardProviders.contains { name.hasPrefix($0) }
            || name.range(of: "^app:[a-z][a-z0-9-]{0,23}:[A-Z][A-Z0-9_]{0,63}$", options: .regularExpression) != nil
    }

    public struct Facts: Sendable {
        public var devices: [Device]
        /// Each host's own parts, read over SSH. A host that did not answer is not in it.
        public var hosts: [String: HostReading]
        /// The hosts that answered this Mac's SSH with no second sshd running: an install that stopped, or one that was
        /// taken away. They leave the door's file, where a host that did not answer keeps its place.
        public var bare: Set<String> = []
        /// For each business whose operator box this round checked: its DevOps agent, or nil when there is none (no box,
        /// two boxes, or a box that holds no agent alone). A business that is not a key was not checked this round, so
        /// the agent that the file shows holding its servers keeps them.
        public var operators: [String: Operator?]
        /// This Mac's owner key and the fleet's id, or nil when this Mac holds no owner key for the fleet or the hub
        /// does not offer `door_calls`: the file then keeps what it has.
        public var owner: OwnerPin?
        /// The hub's view for keeping the door, or nil when the hub does not offer `door_setup`: the agents' names, the
        /// credentials and the providers then stay as the file has them.
        public var hub: HubDoor?
        /// The door's code takes an entry for an agent that only gets its GitHub tokens (no business, address, server
        /// or provider): the release of plan 13, item 4. Before it, only agents with an entry get their grants.
        public var tokensOnly: Bool

        public init(devices: [Device], hosts: [String: HostReading] = [:], operators: [String: Operator?] = [:],
                    owner: OwnerPin? = nil, hub: HubDoor? = nil, tokensOnly: Bool = false) {
            self.devices = devices; self.hosts = hosts; self.operators = operators; self.owner = owner; self.hub = hub
            self.tokensOnly = tokensOnly
        }
    }

    /// One round's decision: the file to write, and the Operators' servers, which the hub records too.
    public struct Plan: Sendable {
        /// The whole new file, as canonical JSON (sorted keys), which `door-access` takes on its standard input.
        public let file: Data
        /// The file differs from the one on the door.
        public let changed: Bool
        /// {agent: {server: "fix"}}: the holdings, which `POST /ui/servers/grant` records.
        public let holdings: [String: [String: String]]
        /// The servers of a business whose parts did not answer: not in the file until their second sshd does.
        public let waiting: [String]
    }

    /// The servers that this Mac's Tailscale shows, each with its businesses: every device with a business tag, except
    /// the door and the hosts of the file's never list.
    public static func servers(access: [String: Any], devices: [Device]) -> [String: [String]] {
        let never = Set(((access["never"] as? [String: Any])?["hosts"] as? [String]) ?? [])
        var found: [String: [String]] = [:]
        for device in devices where !device.tags.contains(doorTag) && !never.contains(device.name) && !device.businesses.isEmpty {
            found[device.name] = device.businesses
        }
        return found
    }

    /// The new file from the one on the door and what this Mac read.
    ///
    /// - A server of one business gets the mode that its own ops-root has. A server of two businesses is `rule-only`,
    ///   because the door refuses Fix across businesses on any other host, and a machine of the fleet is `rule-only`.
    /// - A server whose parts did not answer keeps its entry from the file, if it has one, so one failed SSH call cuts no
    ///   agent off; one that never answered waits. A server that lost its business tag, or went on the never list,
    ///   leaves the file, and so do its holdings.
    /// - Each business's servers go to its Operator at Fix, with the address of its operator box; no other agent holds a
    ///   server, and an agent that operates two businesses holds none. Another agent's entry with the Operator's address
    ///   loses it, because the box holds that one agent alone.
    ///
    /// With the hub's view (`Facts.hub`, plan 13, item 3):
    /// - An Operator takes the hub's name when the hub shows the box's own OS user at the box's address
    ///   (`HubDoor.name`), so the door's entries carry the names by which the hub asks the door for GitHub tokens and
    ///   records holdings. The box still decides who operates. Its entry under the OS user's name moves, with every field.
    /// - Each credential that a key card asked for the door is written with its secret (its other fields stay), one that
    ///   the hub no longer lists goes, and each agent's `providers` hold those that the hub gives it, beside its others.
    public static func plan(current: [String: Any], facts: Facts) -> Plan {
        var file = current
        var operators = facts.operators, renamed: [String: String] = [:]     // OS user's name: the hub's name
        if let hub = facts.hub {
            for (business, checked) in facts.operators {
                guard let found = checked, let name = hub.name(of: found), name != found.agent else { continue }
                renamed[found.agent] = name
                operators.updateValue(Operator(agent: name, address: found.address), forKey: business)
            }
        }
        let oldHosts = current["hosts"] as? [String: Any] ?? [:]
        let byName = Dictionary(facts.devices.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        // a server that a plan step holds at `parts` gets no entry, and so no holder (API 1.101)
        let owners = servers(access: current, devices: facts.devices).filter { !(facts.hub?.heldOut.contains($0.key) ?? false) }
        let ruleOnly = facts.hub?.ruleOnly ?? []
        var hosts: [String: Any] = [:], waiting: [String] = []
        for (name, names) in owners.sorted(by: { $0.key < $1.key }) {
            var entry: [String: Any]
            if let reading = facts.hosts[name], let address = byName[name]?.address {
                let old = oldHosts[name] as? [String: Any] ?? [:]
                entry = ["address": address, "port": (old["port"] as? Int) ?? sshdPort, "host_key": reading.hostKey,
                         "business": names[0],
                         "mode": names.count > 1 || reading.fleet || ruleOnly.contains(name) ? "rule-only" : reading.mode,
                         "kind": reading.fleet ? "fleet" : ((old["kind"] as? String).flatMap { $0 == "fleet" ? nil : $0 } ?? "app")]
            } else if let old = oldHosts[name] as? [String: Any], !facts.bare.contains(name) {
                entry = old
                entry["business"] = names.contains(old["business"] as? String ?? "") ? old["business"] : names[0]
                if names.count > 1 || ruleOnly.contains(name) { entry["mode"] = "rule-only" }
            } else {
                waiting.append(name)
                continue
            }
            hosts[name] = entry
        }
        file["hosts"] = hosts

        var oldAgents = current["agents"] as? [String: Any] ?? [:]
        for (osName, name) in renamed.sorted(by: { $0.key < $1.key }) {
            if oldAgents[name] == nil, let entry = oldAgents[osName] { oldAgents[name] = entry }
            oldAgents[osName] = nil
        }
        var holder: [String: String] = [:]          // business: its Operator
        for business in Set(owners.values.flatMap { $0 }).union(operators.keys).sorted() {
            if let checked = operators[business] {
                if let found = checked { holder[business] = found.agent }
            } else if let kept = oldAgents.keys.sorted().first(where: { agent in
                let entry = oldAgents[agent] as? [String: Any] ?? [:]
                return entry["business"] as? String == business && !((entry["servers"] as? [String: Any]) ?? [:]).isEmpty
            }) {
                holder[business] = kept
            }
        }
        for (_, businesses) in Dictionary(grouping: holder, by: { $0.value }) where businesses.count > 1 {
            for (business, _) in businesses { holder[business] = nil }
        }
        var held: [String: [String: String]] = [:]
        for (name, names) in owners where hosts[name] != nil {
            for business in names { if let agent = holder[business] { held[agent, default: [:]][name] = "fix" } }
        }
        var agents = oldAgents
        for (agent, value) in oldAgents {
            guard var entry = value as? [String: Any], entry["servers"] != nil else { continue }
            entry["servers"] = nil
            agents[agent] = entry
        }
        for (business, agent) in holder.sorted(by: { $0.key < $1.key }) {
            var entry = agents[agent] as? [String: Any] ?? [:]
            entry["business"] = business
            entry["servers"] = held[agent] ?? [:]
            if let found = operators[business] ?? nil {
                entry["address"] = found.address
                for (other, value) in agents where other != agent {
                    guard var taken = value as? [String: Any], taken["address"] as? String == found.address else { continue }
                    taken["address"] = nil
                    agents[other] = taken
                }
            }
            agents[agent] = entry
        }
        if let hub = facts.hub {
            var credentials = file["credentials"] as? [String: Any] ?? [:]
            for name in Array(credentials.keys) where cardCredential(name) && hub.credentials[name] == nil {
                credentials[name] = nil
            }
            for (name, credential) in hub.credentials where cardCredential(name) {
                var entry = credentials[name] as? [String: Any] ?? [:]
                entry["secret"] = credential.secret
                credentials[name] = entry
            }
            if credentials.isEmpty { file["credentials"] = nil } else { file["credentials"] = credentials }
            for (agent, value) in agents {
                guard var entry = value as? [String: Any] else { continue }
                let kept = ((entry["providers"] as? [String]) ?? []).filter { !cardCredential($0) }
                let given = hub.credentials.filter { cardCredential($0.key) && $0.value.agents.contains(agent) }.map(\.key)
                let providers = Array(Set(kept + given)).sorted()
                if providers.isEmpty { entry["providers"] = nil } else { entry["providers"] = providers }
                agents[agent] = entry
            }
            // plan 13, item 4: each agent's GitHub grants as the hub gives them, by which the door makes the tokens
            // once the hub asks it for every one. An agent with no entry gets one with its grants alone, when the
            // door's code takes such an entry (`Facts.tokensOnly`).
            for (name, agent) in hub.agents where isName(name) {
                guard let repos = agent.repos, agents[name] != nil || facts.tokensOnly else { continue }
                let grants = repos.filter { repoName($0.key) && ["read", "write", "deploy"].contains($0.value) }
                var entry = agents[name] as? [String: Any] ?? [:]
                if grants.isEmpty { entry["github"] = nil } else { entry["github"] = grants }
                if entry.isEmpty { agents[name] = nil } else { agents[name] = entry }
            }
            agents = operatorGitHub(agents, operators: Set(holder.values), hub: hub, apps: gitHubApps(file))
            agents = gitOpsTargets(agents, hub: hub)
        }
        file["agents"] = agents
        if let owner = facts.owner {
            file["owner_keys"] = [owner.key]
            file["fleet"] = owner.fleet
        }
        let data = canonical(file)
        return Plan(file: data, changed: data != canonical(current), holdings: held, waiting: waiting.sorted())
    }

    /// **Each Operator's GitHub entries, from the hub's grants** (new-projects plan, N8, in DevOps plan 5.12; the
    /// owner's "Yes, as written" of 6 November 2026): no Mac session writes them. `github:<owner>` goes in its
    /// `providers` for each account of which the door holds an App and the Operator holds a repository, so that its
    /// reads there work (`ops github:<owner>`). A commit target of kind `app` goes in its `repos` for each repository
    /// that it holds and that no other agent holds at write or deploy, its records repository among them; a records
    /// target of kind `devops` becomes `app`, so that its commits pass only as the door's checked forms or as the
    /// agent's own call, which the door's record names. A target that the app did not write stays as the file has it:
    /// one of another kind (`gitops`), and one with fields of its own (a deploy workflow, a branch). A repository that
    /// the door made gets its one target from the door's own record, not from here.
    static func operatorGitHub(_ agents: [String: Any], operators: Set<String>, hub: HubDoor,
                               apps: [(owner: String, login: String, appID: String)]) -> [String: Any] {
        var agents = agents
        let others: (String) -> Set<String> = { me in
            Set(hub.agents.filter { $0.key != me }.flatMap { ($0.value.repos ?? [:]).filter { ["write", "deploy"].contains($0.value) }.keys }
                .map { $0.lowercased() })
        }
        for agent in operators.sorted() {
            guard var entry = agents[agent] as? [String: Any], let grants = hub.agents[agent]?.repos else { continue }
            let held = grants.keys.filter(repoName).sorted()
            let accounts = Set(held.map { $0.split(separator: "/")[0].lowercased() })
            let providers = ((entry["providers"] as? [String]) ?? []).filter { !$0.lowercased().hasPrefix("github:") }
                + apps.filter { accounts.contains($0.owner.lowercased()) }.map { "github:\($0.owner)" }
            entry["providers"] = providers.isEmpty ? nil : Array(Set(providers)).sorted()
            let taken = others(agent)
            let wanted = Set(held.filter { !taken.contains($0.lowercased()) })
            var targets = entry["repos"] as? [String: Any] ?? [:]
            for (repo, value) in targets {
                guard var target = value as? [String: Any], let kind = target["kind"] as? String,
                      kind == "app" || kind == "devops" else { continue }
                if wanted.contains(repo) {
                    target["kind"] = "app"
                    targets[repo] = target
                } else if target.count == 1 {
                    targets[repo] = nil             // a plain target that the grants no longer give
                }
            }
            for repo in wanted where targets[repo] == nil { targets[repo] = ["kind": "app"] }
            entry["repos"] = targets.isEmpty ? nil : targets
            agents[agent] = entry
        }
        return agents
    }

    /// **Each Operator's GitOps targets, from the manager's `door_gitops`** (DevOps plan X3, API 1.111): no Mac session
    /// writes them. Each agent of the file that `HubDoor.gitops` names for a repository gets the target
    /// `repos[<owner/name>]` `{kind: gitops, sync}`, in place of a target of another kind for the same repository, and a
    /// GitOps target that the hub no longer gives goes. The door reads the repository through its filter and dispatches
    /// `sync` with its own App, so no GitHub grant comes with it. A hub before API 1.111 leaves the targets as they are.
    static func gitOpsTargets(_ agents: [String: Any], hub: HubDoor) -> [String: Any] {
        guard let gitops = hub.gitops else { return agents }
        var out = agents
        for (agent, value) in agents {
            guard var entry = value as? [String: Any] else { continue }
            var targets = entry["repos"] as? [String: Any] ?? [:]
            for (repo, target) in targets where (target as? [String: Any])?["kind"] as? String == "gitops" {
                targets[repo] = nil
            }
            for (repo, given) in gitops where given.agents.contains(agent) && repoName(repo) && workflowFile(given.sync) {
                for key in Array(targets.keys) where key.lowercased() == repo.lowercased() { targets[key] = nil }
                targets[repo] = ["kind": "gitops", "sync": given.sync]
            }
            entry["repos"] = targets.isEmpty ? nil : targets
            out[agent] = entry
        }
        return out
    }

    /// A workflow's file name, as a dispatch names it (door_targets.WORKFLOW_FILE).
    static func workflowFile(_ text: String) -> Bool {
        text.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,99}\\.ya?ml$", options: .regularExpression) != nil
    }

    /// The file as the door reads it: one JSON object, keys sorted.
    public static func canonical(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// The file that `readProgram` printed, or nil.
    public static func file(_ output: String) -> [String: Any]? {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["v"] as? Int == 1 else { return nil }
        return object
    }

    /// The holdings that the hub must record now: those that `wanted` has and `recorded` has not (at their level), and
    /// those that `recorded` has and `wanted` has not (level nil takes one back).
    public static func changes(wanted: [String: [String: String]], recorded: [String: [String: String]])
        -> [(agent: String, server: String, level: String?)] {
        var out: [(agent: String, server: String, level: String?)] = []
        for agent in Set(wanted.keys).union(recorded.keys).sorted() {
            let want = wanted[agent] ?? [:], have = recorded[agent] ?? [:]
            for server in Set(want.keys).union(have.keys).sorted() where want[server] != have[server] {
                out.append((agent: agent, server: server, level: want[server]))
            }
        }
        return out
    }

    /// The door's credential of one GitHub owner's App: the secret that holds its key, and its id. The door makes each
    /// token of that owner's repositories with it (`credentials["github:<owner>"]`).
    public static func withGitHubApp(_ access: [String: Any], owner: String, login: String, appID: String) -> [String: Any] {
        var file = access
        var credentials = access["credentials"] as? [String: Any] ?? [:]
        for key in credentials.keys where key.lowercased() == "github:\(owner.lowercased())" { credentials[key] = nil }
        // An App uses one key for all its installations: a new key of that App is the key of each of its accounts
        // (plan 13, item 4: the key that the hub held gets a successor, and then GitHub deletes the old one)
        for (key, value) in credentials where key.lowercased().hasPrefix("github:") {
            if var one = value as? [String: Any], "\(one["app_id"] ?? "")" == appID {
                one["secret"] = login
                credentials[key] = one
            }
        }
        credentials["github:\(owner)"] = ["secret": login, "app_id": appID]
        file["credentials"] = credentials
        return file
    }

    static func names(_ tags: [String], after prefix: String) -> [String] {
        tags.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
            .filter { $0.range(of: "^[a-z][a-z0-9-]{1,30}$", options: .regularExpression) != nil }.sorted()
    }

    static func isName(_ text: String) -> Bool { text.range(of: "^[a-z0-9][a-z0-9-]{0,62}$", options: .regularExpression) != nil }

    /// A repository name that the door's file takes (door_targets.REPO): owner/name.
    static func repoName(_ text: String) -> Bool {
        text.range(of: "^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$", options: .regularExpression) != nil
    }

    /// What tells whether the door's code takes an entry for an agent that only gets its GitHub tokens (plan 13,
    /// item 4): its own words for that entry, in the code that runs.
    public static let tokensProbe = "grep -qs tokens_only /opt/fleet-door/current/door.py && echo tokens=yes; true"

    /// Whether the door holds the sealed copy of one secret: the file that only its own OS user reads, named by the
    /// SHA-256 of the reference. nil when the reference is not one.
    /// The door's own vault key, its public half only, which the central vault must hold pinned under door before the
    /// hub seals a key for the door (API 1.99): age-keygen prints a recipient from the identity, as root on the door.
    public static let recipientProgram = "age-keygen -y /var/lib/fleet-door/vault.key"

    /// The one age recipient of recipientProgram's output, or nil.
    public static func recipient(_ output: String) -> String? {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count == 1, lines[0].range(of: "^age1[0-9a-z]{58}$", options: .regularExpression) != nil else {
            return nil
        }
        return lines[0]
    }

    public static func heldProgram(login: String) -> String? {
        guard login.range(of: "^bws://[0-9a-f-]{36}$", options: .regularExpression) != nil else { return nil }
        return "test -s /var/lib/fleet-door/secrets/\(sha256Hex(login)) && echo held=yes; true"
    }

    /// The door makes the hub's two secrets and prints them, once: only the app runs it, over its own SSH, and gives
    /// them to the hub (`POST /ui/door/secrets`). A second run makes new ones, and the old ones stop.
    public static let hubSecretsProgram = "/usr/local/sbin/door-hub-secrets"

    /// The secret and the App id of a GitHub App in the door's file (`credentials["github:<owner>"]`), for any owner.
    public static func gitHubApps(_ access: [String: Any]) -> [(owner: String, login: String, appID: String)] {
        ((access["credentials"] as? [String: Any]) ?? [:]).compactMap { key, value in
            guard key.lowercased().hasPrefix("github:"), let entry = value as? [String: Any],
                  let login = entry["secret"] as? String, let appID = entry["app_id"] as? String else { return nil }
            return (owner: String(key.dropFirst("github:".count)), login: login, appID: appID)
        }.sorted { $0.owner < $1.owner }
    }

    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: this Mac's SSH

    /// **The arguments of this Mac's `ssh` for one program as root on a device of the round**: the connection that the
    /// app keeps for that machine (`kept`: its user, port and key), else root at the address that this Mac's Tailscale
    /// gives it, with the host key checked strictly (`CentralVaultRemote`). nil when `ssh` cannot take the target.
    ///
    /// With no kept connection, `ssh` offers only the key files that this Mac's `~/.ssh/config` names
    /// (`IdentitiesOnly`), and not every key of the SSH agent before them (7 November 2026): four Teleport keys there and
    /// the four files of `Host *` made eight tries, and a server whose sshd stops at six (`MaxAuthTries`) logged
    /// "maximum authentication attempts exceeded" each round, until its fail2ban shut this Mac out for an hour. `key`:
    /// one more key file for a device with no kept connection, offered before those files (`LoginKeys`).
    public static func sshArguments(kept: InstallTarget?, address: String, program: String, key: String? = nil) -> [String]? {
        var target = kept ?? InstallTarget(host: address, user: "root", identityFile: key)
        target.host = address
        target.becomeRoot = target.user != "root"
        guard target.isValid else { return nil }
        let arguments = CentralVaultRemote.arguments(target: target, program: program)
        return kept == nil ? ["-o", "IdentitiesOnly=yes"] + arguments : arguments
    }

    /// **The one key file, besides those of `~/.ssh/config`, that the round offers a device with no kept connection**
    /// (7 November 2026: two servers of another business take root only with the key of the app's kept
    /// connections to the fleet's servers, which no line of `Host *` names). It is a key that this Mac already uses for
    /// root: one of its kept root connections' key files (`candidates`). One a try, so that a try offers at most five
    /// keys with the four files of `Host *`, fewer than an sshd's MaxAuthTries of 6. The first one, and after a
    /// refusal the next one: the refusal's hour (`Refusals`) still comes first. A key that let this Mac in stays.
    public struct LoginKeys: Equatable, Sendable {
        /// The key file that each device, by its line, refused last.
        public var refused: [String: String] = [:]

        public init() {}

        public func key(for device: Device, candidates: [String]) -> String? {
            guard !candidates.isEmpty else { return nil }
            guard let last = refused[DoorAccess.line(device)], let i = candidates.firstIndex(of: last) else {
                return candidates[0]
            }
            return candidates[(i + 1) % candidates.count]
        }

        /// A refusal of the device with this key: its next try offers the next one.
        public mutating func refused(_ device: Device, key: String) { refused[DoorAccess.line(device)] = key }

        static func key(hub: URL) -> String { "doorLoginKeys|\(hub.absoluteString)" }

        public static func read(hub: URL, in defaults: UserDefaults = .standard) -> LoginKeys {
            var keys = LoginKeys()
            keys.refused = defaults.dictionary(forKey: key(hub: hub)) as? [String: String] ?? [:]
            return keys
        }

        public func save(hub: URL, in defaults: UserDefaults = .standard) {
            defaults.set(refused, forKey: Self.key(hub: hub))
        }
    }

    /// A device as the round's fingerprint holds it: its name, its address and its tags.
    public static func line(_ device: Device) -> String {
        "\(device.name) \(device.address ?? "-") \(device.tags.joined(separator: ","))"
    }

    /// Whether `ssh` says that the device did not let this Mac in: it took none of the keys that this Mac offered, or
    /// its host key is not one that this Mac knows. 255 is `ssh`'s own status, where a program that ran ends with its
    /// own. A device that `ssh` did not reach is not one: nothing there counted a try.
    public static func loginRefused(status: Int32, output: String) -> Bool {
        let said = output.lowercased()
        return status == 255 && (said.contains("permission denied (") || said.contains("too many authentication failures")
                                 || said.contains("host key verification failed"))
    }

    /// **The devices that refused this Mac's SSH login, and when** (7 November 2026: the round tried one such server
    /// again every five minutes and at each start of the app, with keys that it does not take). A device that refused
    /// is tried again an hour later, or sooner when its line (`line`) changes: another name, address or tags. The record
    /// is kept between runs of the app, so that a new build tries it no sooner.
    public struct Refusals: Equatable, Sendable {
        public static let wait: TimeInterval = 3600
        /// When each device, by its line, refused last.
        public var at: [String: Date] = [:]

        public init() {}

        /// The device refused under this same line less than an hour ago.
        public func waits(_ device: Device, now: Date) -> Bool {
            at[DoorAccess.line(device)].map { (0..<Self.wait).contains(now.timeIntervalSince($0)) } ?? false
        }

        /// One answer of `ssh` from the device: a refusal starts its hour, and any other answer ends it.
        public mutating func note(_ device: Device, refused: Bool, now: Date) {
            at = at.filter { (0..<Self.wait).contains(now.timeIntervalSince($0.value)) }
            at[DoorAccess.line(device)] = refused ? now : nil
        }

        static func key(hub: URL) -> String { "doorRefusals|\(hub.absoluteString)" }

        public static func read(hub: URL, in defaults: UserDefaults = .standard) -> Refusals {
            var refusals = Refusals()
            refusals.at = defaults.dictionary(forKey: key(hub: hub)) as? [String: Date] ?? [:]
            return refusals
        }

        public func save(hub: URL, in defaults: UserDefaults = .standard) {
            defaults.set(at, forKey: Self.key(hub: hub))
        }
    }
}

/// `POST /ui/servers/grant` (owner feature `server_access`): one agent's holding of one server, which the app records as
/// the door's access file gives it. Level nil takes it back.
public enum ServerGrantCommand {
    public static let feature = "server_access"

    public static func body(requestID: UUID, database: String, agent: String, server: String, level: String?) throws -> Data {
        guard DoorAccess.isName(agent), DoorAccess.isName(server), level == nil || level == "read" || level == "fix" else {
            throw HubError.invalidResponse
        }
        return try JSONSerialization.data(withJSONObject: [
            "request_id": requestID.uuidString.lowercased(), "db": database, "agent": agent, "server": server,
            "level": level.map { $0 as Any } ?? NSNull()], options: [.sortedKeys])
    }
}

/// The hub's record of the holdings that the door's access file gives (`POST /ui/servers/grant`).
public struct ServerGrantClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func grant(hub: URL, database: String, client: String, agent: String, server: String, level: String?) async throws {
        var request = URLRequest(url: hub.appendingPathComponent("ui/servers/grant"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client, forHTTPHeaderField: "X-Fleet-Client")
        request.httpBody = try ServerGrantCommand.body(requestID: UUID(), database: database, agent: agent, server: server, level: level)
        let (data, response) = try await session.data(for: request)
        HubWrites.note(request)
        guard let response = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        guard response.statusCode == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "Unexpected HTTP response."
            throw HubError.refusal(response.statusCode, String(message.prefix(500)))
        }
    }
}

/// The hub's side of keeping the door (owner feature `door_setup`, DevOps plan 13, items 1 and 3): `GET /ui/door`,
/// which the round reads, and `POST /ui/door`, by which it writes the door's entry when its own Tailscale shows the door
/// at another address than the hub has. Nothing of it is on a page.
public struct DoorSetupClient: Sendable {
    public static let feature = "door_setup"
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func view(hub: URL, database: String) async throws -> DoorAccess.HubDoor {
        var parts = URLComponents(url: hub.appendingPathComponent("ui/door"), resolvingAgainstBaseURL: false)!
        // renew=form: this build's GitHub App rows take the new key of the App that the hub held, so the hub may ask for
        // it (plan 13, item 4; an older app shows no form, and the hub raises nothing while only such an app reads)
        parts.queryItems = [.init(name: "db", value: database), .init(name: "renew", value: "form")]
        var request = URLRequest(url: parts.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        guard response.statusCode == 200 else { throw HubError.refusal(response.statusCode, Self.words(data)) }
        guard data.count <= 1_048_576 else { throw HubError.invalidResponse }
        let view = try JSONDecoder().decode(DoorAccess.HubDoor.self, from: data)
        guard view.db == database else { throw HubError.invalidResponse }
        return view
    }

    public func save(hub: URL, database: String, client: String, address: String, port: Int) async throws {
        var request = URLRequest(url: hub.appendingPathComponent("ui/door"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client, forHTTPHeaderField: "X-Fleet-Client")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "request_id": UUID().uuidString.lowercased(), "db": database, "address": address, "port": port], options: [.sortedKeys])
        let (data, response) = try await session.data(for: request)
        HubWrites.note(request)
        guard let response = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        guard response.statusCode == 200 else { throw HubError.refusal(response.statusCode, Self.words(data)) }
    }

    /// `POST /ui/door/secrets` (plan 13, item 4): the hub's two secrets, which the door made. The hub keeps them only
    /// when the door then mints for every owner, and only then it stops using its own App key; its refusal says why.
    public func link(hub: URL, database: String, client: String, token: String, record: String) async throws {
        var request = URLRequest(url: hub.appendingPathComponent("ui/door/secrets"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client, forHTTPHeaderField: "X-Fleet-Client")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "request_id": UUID().uuidString.lowercased(), "db": database, "token": token, "record": record], options: [.sortedKeys])
        let (data, response) = try await session.data(for: request)
        HubWrites.note(request)
        guard let response = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        guard response.statusCode == 200 else { throw HubError.refusal(response.statusCode, Self.words(data)) }
    }

    /// `POST /ui/door/host` (API 1.100): what this Mac's round did on one server, `installed`, `passed` or `failed`,
    /// with one line. The hub tells the manager of the first server that passed, and of each failure.
    public func hostReport(hub: URL, database: String, client: String, host: String, state: String, said: String) async throws {
        var request = URLRequest(url: hub.appendingPathComponent("ui/door/host"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client, forHTTPHeaderField: "X-Fleet-Client")
        let line = String(said.replacingOccurrences(of: "\n", with: " ").prefix(600))
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "request_id": UUID().uuidString.lowercased(), "db": database, "host": host, "state": state, "said": line],
                                                      options: [.sortedKeys])
        let (data, response) = try await session.data(for: request)
        HubWrites.note(request)
        guard let response = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        guard response.statusCode == 200 else { throw HubError.refusal(response.statusCode, Self.words(data)) }
    }

    /// `POST /ui/door/github-app` (API 1.94): the ID of an App that this app made with GitHub's manifest flow, once the
    /// door holds its key, for the account that owns it. The key never goes to the hub.
    public func recordApp(hub: URL, database: String, client: String, owner: String, appID: String) async throws {
        var request = URLRequest(url: hub.appendingPathComponent("ui/door/github-app"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client, forHTTPHeaderField: "X-Fleet-Client")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "request_id": UUID().uuidString.lowercased(), "db": database, "owner": owner, "app_id": appID],
                                                      options: [.sortedKeys])
        let (data, response) = try await session.data(for: request)
        HubWrites.note(request)
        guard let response = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        guard response.statusCode == 200 else { throw HubError.refusal(response.statusCode, Self.words(data)) }
    }

    private static func words(_ data: Data) -> String {
        let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
        return String((message ?? "Unexpected HTTP response.").prefix(500))
    }
}
