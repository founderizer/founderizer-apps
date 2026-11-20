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
    /// host has the mark of a machine of the fleet (`install.sh --fleet`, or the older `--fleet-kit`). A host without the
    /// parts prints no key, and so does a host whose second sshd does not run: an install that stopped after it made the
    /// key (7 November 2026, the canary's first install) has no parts.
    public static let hostProgram = "systemctl is-active --quiet ops-sshd.service && "
        + "cat /etc/ops-root/ssh_host_ed25519_key.pub 2>/dev/null; "
        + "echo \"mode=$(cat /etc/ops-root/mode 2>/dev/null)\"; "
        + "if test -e /etc/ops-root/fleet || test -e /etc/ops-root/fleet-kit; then echo fleet=yes; fi; true"
    /// **The fleet's own servers through the door** (the owner, 17 November 2026, after three of them ran out of memory
    /// and each time a card asked him for a root command: "someone should probably have root, I dont want to be doing
    /// devops work on the fleet!"). Each Linux server of the fleet, a server that runs agents or the hub's server, is a
    /// host of the door at rule-only: one agent holds all of them, reads why one failed and runs the fixed root forms
    /// there, with no command, file or script of its own, because root there opens every agent's keys. In the door's
    /// file they are the hosts of this business, which no tag gives: a tag `tag:business-fleet` names no business.
    public static let fleetBusiness = "fleet"
    /// What a server says, before it gets the door's parts, about being a machine of the fleet: Fleet's own root
    /// helper is there, which both installers write as root. The hub proposes the fleet's servers, and this is the
    /// server's own word, so a fault of the hub makes no other device of the network a host of the door.
    public static let fleetProgram = "test -x /usr/local/sbin/fleet-agent-user && echo fleet-machine=yes; true"
    /// What tells, on the door, whether the release that it runs installs a machine of the fleet (`install.sh
    /// --fleet`): its own install script's line for that option. Before that release, no fleet server gets parts, and
    /// none fails for an option that the script does not know.
    public static let fleetProbe = "grep -qs -- '--fleet) FLEET=1' /opt/fleet-door/current/host/install.sh && echo fleet=yes; true"
    /// Whether the door's check takes `--first` (API 1.241): the parser's line in the door's own `door.py`, which
    /// `test_door` checks is there. A door from before gets no flag, so it gives no refusal that would count as no step.
    public static let firstProbe = "grep -qs -- 'probing.add_argument(\"--first\"' /opt/fleet-door/current/door.py && echo first=yes; true"
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
        /// The fleet's own servers (API 1.210): each Linux server of the fleet with its address, the agent that the
        /// manager named for them (`door_fleet`), and the manager, which holds them in a fleet with no DevOps agent.
        /// The hub proposes: this Mac takes a server only by its own Tailscale and the server's own word, and an agent
        /// only when its server says that it runs alone there.
        public struct Fleet: Decodable, Equatable, Sendable {
            public let servers: [String: String]
            public let holder: String?
            public let manager: String?

            public init(servers: [String: String], holder: String? = nil, manager: String? = nil) {
                self.servers = servers; self.holder = holder; self.manager = manager
            }
        }
        /// nil from a hub before API 1.210: no machine of the fleet is a host of the door then, as before.
        public var fleet: Fleet? = nil
        /// What this view gives, as one mark (API 1.234), the same while it gives the same. Once the door's file holds
        /// what this view gives, each read of the hub's view says this mark (`held`), and only that word ends the
        /// hub's wait for a new grant. nil from a hub before that.
        public var mark: String? = nil

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
            var lines: [String] = credentials.sorted { $0.key < $1.key }.map { name, credential in
                "\(name) \(credential.secret) \(credential.agents.sorted().joined(separator: ","))"
            }
            for (name, agent) in agents.sorted(by: { $0.key < $1.key }) {
                let repos = (agent.repos ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
                lines.append("\(name) \(agent.address) \(agent.user ?? "-") " + repos.joined(separator: ","))
            }
            lines.append("app \(github_app?.app_id ?? "-") linked \(linked == true)")
            let rolled: String = rollout.map { String($0) } ?? "-"
            lines.append("pin \(vault_pin ?? "-") read \(vault_read == true) rollout \(rolled)")
            let held = (holds ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            lines.append("holds " + held.joined(separator: ","))
            let targets: [String]? = gitops.map { given in
                given.sorted { $0.key < $1.key }.map { repo, target in
                    "\(repo)=\(target.sync):\(target.agents.sorted().joined(separator: "+"))"
                }
            }
            lines.append("gitops " + (targets?.joined(separator: ",") ?? "-"))
            // the fleet's own servers, and who the hub proposes for them (API 1.210)
            let own: String? = fleet.map { given in
                let servers = given.servers.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
                return "\(given.holder ?? "-") \(given.manager ?? "-") " + servers.joined(separator: ",")
            }
            lines.append("fleet " + (own ?? "-"))
            return lines.joined(separator: "\n")
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
        /// Who holds the fleet's own servers, as this round found it (`fleetCandidate`, and the agent's own server for
        /// one that is no Operator). `.keep`: the round could not say, so the agent that the file shows stays.
        public var fleetHolder: FleetHolder = .keep

        public init(devices: [Device], hosts: [String: HostReading] = [:], operators: [String: Operator?] = [:],
                    owner: OwnerPin? = nil, hub: HubDoor? = nil, tokensOnly: Bool = false) {
            self.devices = devices; self.hosts = hosts; self.operators = operators; self.owner = owner; self.hub = hub
            self.tokensOnly = tokensOnly
        }
    }

    /// The holder of the fleet's own servers for one round.
    public enum FleetHolder: Equatable, Sendable {
        /// Not known this round (a box did not answer, or the hub gives no view): the file's holder stays.
        case keep
        case nobody
        case agent(Operator)
    }

    /// Whom the hub's view and this round's Operators give as the holder, before the agent's own server is asked.
    public enum FleetCandidate: Equatable, Sendable {
        case keep
        case nobody
        /// An Operator of this round: its box already said that it runs alone there.
        case agent(Operator)
        /// An agent that is no Operator (the one that the manager named, or the manager itself): its server at this
        /// address must say that this agent runs alone there (`boxProgram`), before it holds anything.
        case box(agent: String, address: String)
    }

    /// **Who holds the fleet's own servers**, by the owner's two decisions (the DevOps agent that he names; with no
    /// DevOps agent, the manager): the agent that the manager named with `door_fleet`; else the one DevOps agent,
    /// when exactly one business has an Operator; else, with no Operator, the manager; else, with several Operators
    /// and nobody named, nobody. An operator box of this Mac's Tailscale that was not read this round can hold the
    /// named agent, and without a name the round does not know how many Operators there are: the answer is then
    /// `.keep`. A named agent that this round's read boxes show, or whose server is no such box, is not held up by
    /// a box that does not answer.
    public static func fleetCandidate(hub: HubDoor?, devices: [Device], operators: [String: Operator?]) -> FleetCandidate {
        guard let hub, let fleet = hub.fleet else { return .keep }
        var unread: Set<String> = []                // the addresses of the operator boxes that this round did not read
        for (business, box) in operatorBoxes(devices: devices) where operators[business] == nil {
            if let address = box?.address { unread.insert(address) }
        }
        var found: [Operator] = []
        for checked in operators.sorted(by: { $0.key < $1.key }).compactMap(\.value) {
            let named = Operator(agent: hub.name(of: checked) ?? checked.agent, address: checked.address)
            if !found.contains(named) { found.append(named) }
        }
        func other(_ agent: String?) -> FleetCandidate {
            guard let agent, isName(agent), let address = hub.agents[agent]?.address else { return .nobody }
            return unread.contains(address) ? .keep : .box(agent: agent, address: address)
        }
        if let named = fleet.holder { return found.first { $0.agent == named }.map { .agent($0) } ?? other(named) }
        guard unread.isEmpty else { return .keep }
        if found.count == 1 { return .agent(found[0]) }
        return found.isEmpty ? other(fleet.manager) : .nobody
    }

    /// **The fleet's own servers that can be hosts of the door**, by name, the hub's own server last: each server of
    /// the hub's view that this Mac's own Tailscale shows under the same name at the same address, with no business
    /// tag (a server with one goes with its business), that is not the door, not on the never list, and that no plan
    /// step holds at `parts`. The hub's server is the one at the hub's address of the door's file.
    public static func fleetServers(access: [String: Any], devices: [Device], hub: HubDoor?) -> [String] {
        guard let hub, let fleet = hub.fleet else { return [] }
        let never = Set(((access["never"] as? [String: Any])?["hosts"] as? [String]) ?? [])
        let hubAddress = (access["hub"] as? [String: Any])?["address"] as? String
        let byName = Dictionary(devices.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let names = fleet.servers.filter { name, address in
            guard isName(name), let device = byName[name], device.address == address else { return false }
            return device.businesses.isEmpty && !device.tags.contains(doorTag) && !never.contains(name)
                && !hub.heldOut.contains(name)
        }
        return names.keys.sorted { (names[$0] == hubAddress ? 1 : 0, $0) < (names[$1] == hubAddress ? 1 : 0, $1) }
    }

    /// One round's decision: the file to write, and the Operators' servers, which the hub records too.
    public struct Plan: Sendable {
        /// The whole new file, as canonical JSON (sorted keys), which `door-access` takes on its standard input.
        public let file: Data
        /// The file differs from the one on the door.
        public let changed: Bool
        /// {agent: {server: level}}: the holdings, which `POST /ui/servers/grant` records. `fix` for a business's
        /// server, and `patch` for a machine of the fleet, which the door's file holds as `fix` on a rule-only host.
        public let holdings: [String: [String: String]]
        /// The servers of a business whose parts did not answer: not in the file until their second sshd does.
        public let waiting: [String]
        /// The agents whose GitHub grants the file does not hold: they have no entry, and the door's code takes no
        /// entry for an agent that only gets its tokens yet (`Facts.tokensOnly`). While one is left out, the round does
        /// not tell the hub that the file holds the hub's view (API 1.234).
        public var leftOut: [String] = []
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
        // The fleet's own servers: a host only with the mark of a machine of the fleet, which its install put there
        // after the server's own word (`fleetProgram`), always rule-only. One that did not answer keeps its place.
        var fleetHosts: [String] = []
        for name in fleetServers(access: current, devices: facts.devices, hub: facts.hub) where owners[name] == nil {
            if let reading = facts.hosts[name], let address = byName[name]?.address {
                guard reading.fleet else { waiting.append(name); continue }
                let old = oldHosts[name] as? [String: Any] ?? [:]
                hosts[name] = ["address": address, "port": (old["port"] as? Int) ?? sshdPort, "host_key": reading.hostKey,
                               "business": fleetBusiness, "mode": "rule-only", "kind": "fleet"] as [String: Any]
            } else if var old = oldHosts[name] as? [String: Any], old["kind"] as? String == "fleet", !facts.bare.contains(name) {
                old["business"] = fleetBusiness
                old["mode"] = "rule-only"
                hosts[name] = old
            } else {
                waiting.append(name)
                continue
            }
            fleetHosts.append(name)
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
        // The one holder of the fleet's own servers, its own server among them. The door knows a caller by its
        // address and refuses a file with an agent at the hub's address, so an agent on the hub's server holds none.
        let nowOperators = operators.values.compactMap { $0 }       // this round's, by the names of the file
        // the hosts that the file had as the fleet's own
        let were = Set(oldHosts.filter { ($0.value as? [String: Any])?["kind"] as? String == "fleet"
            && ($0.value as? [String: Any])?["business"] as? String == fleetBusiness }.keys)
        var fleetHolder: Operator? = nil
        var fleetKept = false
        switch facts.fleetHolder {
        case .agent(let found): fleetHolder = found
        case .nobody: break
        case .keep:
            // The round could not say: the agent that the file shows stays, at the address that this round gives it
            // when it is an Operator of this round, else at the file's own.
            fleetKept = true
            for agent in oldAgents.keys.sorted() {
                guard let entry = oldAgents[agent] as? [String: Any], let address = entry["address"] as? String,
                      !were.isDisjoint(with: ((entry["servers"] as? [String: Any]) ?? [:]).keys) else { continue }
                fleetHolder = nowOperators.first { $0.agent == agent } ?? Operator(agent: agent, address: address)
                break
            }
        }
        let own = [(current["hub"] as? [String: Any])?["address"] as? String, door(in: facts.devices)?.address]
        if let found = fleetHolder, own.contains(found.address) || !isName(found.agent) { fleetHolder = nil }
        // The hub proposes the holder with a name and an address, and an entry of the file under that name can hold
        // more than the fleet's servers: a business's servers at Fix, a database, a commit target, an account that
        // a Mac session wrote. Only the operator box of its business gives such an entry its address. Were the
        // proposed address taken for it, a fault of the hub would give the agent at that address all of that. So
        // where the holder's entry would get another address than the lines above give it, the entry may hold only
        // what this part and the hub give: the fleet's own hosts, its GitHub grants and the keys of key cards. Such
        // an entry gives the agent at the new address the fixed forms on the fleet's servers and no more, so a
        // holder that moved to another server still holds them. A holder that only stays (`.keep`) gets no address.
        if let found = fleetHolder, !fleetKept, let was = oldAgents[found.agent] as? [String: Any] {
            let operated = holder.first { $0.value == found.agent }.flatMap { operators[$0.key] ?? nil }?.address
            if (operated ?? was["address"] as? String) != found.address {
                let fleetOnly = Set(was.keys).isSubset(of: ["address", "business", "servers", "github", "providers"])
                    && (was["business"] == nil || was["business"] as? String == fleetBusiness)
                    && ((was["servers"] as? [String: Any]) ?? [:]).keys.allSatisfy { were.contains($0) }
                    && ((was["providers"] as? [String]) ?? []).allSatisfy(cardCredential)
                if !fleetOnly { fleetHolder = nil }
            }
        }
        if let found = fleetHolder {
            for name in fleetHosts { held[found.agent, default: [:]][name] = "fix" }
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
        if let found = fleetHolder, !fleetHosts.isEmpty {
            var entry = agents[found.agent] as? [String: Any] ?? [:]
            if entry["business"] == nil { entry["business"] = fleetBusiness }
            entry["servers"] = held[found.agent] ?? [:]
            // A holder that this round's own reads gave has that address alone, as an Operator has its box's. One
            // that only stays from the file (`.keep`) keeps what the lines above gave it, and takes no address away.
            if !fleetKept {
                entry["address"] = found.address
                for (other, value) in agents where other != found.agent {
                    guard var taken = value as? [String: Any], taken["address"] as? String == found.address else { continue }
                    taken["address"] = nil
                    agents[other] = taken
                }
            }
            agents[found.agent] = entry
        }
        var leftOut: [String] = []
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
                guard let repos = agent.repos else { continue }
                let grants = repos.filter { repoName($0.key) && ["read", "write", "deploy"].contains($0.value) }
                guard agents[name] != nil || facts.tokensOnly else {
                    if !grants.isEmpty { leftOut.append(name) }
                    continue
                }
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
        var recorded = held                     // the hub's record: patch for a machine of the fleet
        if let found = fleetHolder {
            for name in fleetHosts { recorded[found.agent]?[name] = "patch" }
        }
        return Plan(file: data, changed: data != canonical(current), holdings: recorded, waiting: waiting.sorted(),
                    leftOut: leftOut.sorted())
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
            .filter { $0.range(of: "^[a-z][a-z0-9-]{1,30}$", options: .regularExpression) != nil && $0 != fleetBusiness }
            .sorted()
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

    /// True when the door's file names another key of this App: a key that works. It stays the App's key in the file
    /// until the door holds the new one, because the door makes no token with a key that it does not hold yet, and
    /// its copy comes at its next minute (`door.py` `fetch_sealed`).
    public static func namesOtherKey(_ access: [String: Any], appID: String, login: String) -> Bool {
        gitHubApps(access).contains { $0.appID == appID && $0.login.lowercased() != login.lowercased() }
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
    /// one more key file for a device with no kept connection, offered before those files (`LoginKeys`). `port`: the
    /// port of that device's SSH, where this Mac's SSH configuration names one (`configured`).
    public static func sshArguments(kept: InstallTarget?, address: String, program: String, key: String? = nil,
                                    port: Int = 22) -> [String]? {
        var target = kept ?? InstallTarget(host: address, user: "root", port: port, identityFile: key)
        target.host = address
        target.becomeRoot = target.user != "root"
        guard target.isValid else { return nil }
        let arguments = CentralVaultRemote.arguments(target: target, program: program)
        return kept == nil ? ["-o", "IdentitiesOnly=yes"] + arguments : arguments
    }

    /// **What this Mac's SSH configuration gives the round's root login on a device with no kept connection**
    /// (19 November 2026: a business's server whose root SSH answers only on port 2222 got no door parts, because the
    /// round went to port 22, while an entry of `~/.ssh/config` with the server's address as its `HostName` named the
    /// port). The install reads a server's port in the same way (`InstallTarget.named`).
    public struct Configured: Equatable, Sendable {
        /// The port of the device's SSH.
        public var port: Int
        /// The entry's own key file for root, which `ssh` does not offer by itself at the device's address, or nil.
        public var key: String?

        public init(port: Int, key: String? = nil) { self.port = port; self.key = key }
    }

    #if os(macOS)
    /// **The entry of this Mac's SSH configuration for a device, read with the install's own read**
    /// (`SSHOptions.configured`, which connects to nothing), or nil when the configuration says nothing of its own
    /// for the device: the round then goes to port 22, as before.
    ///
    /// The entry is what the configuration says for the device's address: a `Host` line that names the address, else
    /// the entry that gives the address as its `HostName`. With none of these, and with `byName`, it is the entry
    /// for the device's name in Tailscale, when that entry's host is this device: its address, its name, or its name
    /// with the domain of the private network. An entry through another host (`ProxyJump`, `ProxyCommand`) is not
    /// used: the round's `ssh` goes straight to the address, and a `Host` line of the address with a proxy stays
    /// `ssh`'s own to read, at port 22 as before. `byName` is false for a device that this Mac's Tailscale did not
    /// name.
    ///
    /// **Only an entry for root counts**: its user is root, or it names no user. An entry for another user gives
    /// nothing, because its port can be the port of another program on that server (a second sshd for one user, a
    /// git server), where a root login fails at each try. For the same reason the port of the door's own second sshd
    /// (`sshdPort`) is never used: root has no login there. With several entries for one address, the read gives the
    /// one with user root, else the first one of the files.
    ///
    /// The port and the key are that one entry's. The key is the entry's own key file, one that the configuration
    /// does not give every host. A `Host` line that names the address gives no key here, because `ssh` reads that
    /// line itself and offers its key.
    ///
    /// Known and not changed: a `Host` line that names the address with a key of its own makes `ssh` offer that key
    /// beside the files of `Host *` and the one key of `LoginKeys`, which can be six keys in one try. An entry's
    /// `HostKeyAlias` is not used: the round knows a host key by the device's address, with or without the port
    /// (`ssh` takes a key that it knows for the address alone also at another port).
    public static func configured(_ device: Device, address: String, byName: Bool = true, ssh: String = "/usr/bin/ssh",
                                  home: String = NSHomeDirectory(), localUser: String = NSUserName(),
                                  run: ShellRunner = Shell.local,
                                  exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) async -> Configured? {
        guard let read = await SSHOptions.configured(for: address, aliases: true, ssh: ssh, home: home, run: run),
              let general = read.general else { return nil }
        func own(_ options: SSHOptions) -> Bool {
            options.user != general.user || options.port != general.port || options.identityFiles != general.identityFiles
        }
        var entry = read.mine.flatMap { own($0) ? $0 : nil }
        var offered = entry != nil && !read.alias        // ssh itself reads a Host line that names the address
        if entry == nil, byName,
           let named = await SSHOptions.configured(for: device.name, aliases: true, ssh: ssh, home: home, run: run)?.mine,
           own(named), names(named.hostname, device: device.name, address: address) {
            entry = named
            offered = false
        }
        // an entry for root only, never one through another host, and never the port of the door's own second sshd
        guard let entry, !entry.proxied, entry.user == "root" || entry.user == general.user, entry.port != sshdPort else {
            return nil
        }
        let target = InstallTarget.named("root@" + address, options: entry, general: general, localUser: localUser,
                                         home: home, exists: exists)
        return Configured(port: target.port, key: offered ? nil : target.identityFile)
    }

    /// Whether the host of an entry for a device's name is that device: its address on the private network, its name
    /// in Tailscale, or that name with the domain of the private network (`<name>.<tailnet>.ts.net`).
    static func names(_ hostname: String, device: String, address: String) -> Bool {
        var host = hostname.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        return host == address.lowercased() || host == device.lowercased()
            || (host.hasPrefix(device.lowercased() + ".") && host.hasSuffix(".ts.net"))
    }
    #endif

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

        /// The key files that a try can offer a device, in their order: the key that this Mac's SSH configuration
        /// gives root on that device (`Configured.key`) first, then the kept root connections' key files. It is
        /// still one key a try.
        public static func candidates(configured: String?, kept: [String]) -> [String] {
            guard let configured else { return kept }
            return [configured] + kept.filter { $0 != configured }
        }

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
/// the door's access file gives it: `read`, `fix`, or `patch` for a machine of the fleet. Level nil takes it back.
public enum ServerGrantCommand {
    public static let feature = "server_access"

    public static func body(requestID: UUID, database: String, agent: String, server: String, level: String?) throws -> Data {
        guard DoorAccess.isName(agent), DoorAccess.isName(server), [nil, "read", "patch", "fix"].contains(level) else {
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
        let (data, response) = try await session.hubData(for: request)
        HubWrites.note(request)
        guard let response = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        guard response.statusCode == 200 else { throw HubError.refusal(.read(status: response.statusCode, body: data)) }
    }
}

/// The hub's side of keeping the door (owner feature `door_setup`, DevOps plan 13, items 1 and 3): `GET /ui/door`,
/// which the round reads, and `POST /ui/door`, by which it writes the door's entry when its own Tailscale shows the door
/// at another address than the hub has. Nothing of it is on a page.
public struct DoorSetupClient: Sendable {
    public static let feature = "door_setup"
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    /// `held`: the mark of the newest view whose plan the door's file holds (API 1.234), empty when the caller names
    /// none, as the GitHub App flow's read does.
    public func view(hub: URL, database: String, held: String = "") async throws -> DoorAccess.HubDoor {
        var request = URLRequest(url: Self.viewURL(hub: hub, database: database, held: held))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.hubData(for: request)
        guard let response = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        guard response.statusCode == 200 else { throw HubError.refusal(.read(status: response.statusCode, body: data)) }
        guard data.count <= 1_048_576 else { throw HubError.invalidResponse }
        let view = try JSONDecoder().decode(DoorAccess.HubDoor.self, from: data)
        guard view.db == database else { throw HubError.invalidResponse }
        return view
    }

    /// The address of a read of `GET /ui/door`. renew=form: this build's GitHub App rows take the new key of the App
    /// that the hub held, so the hub may ask for it (plan 13, item 4; an older app shows no form, and the hub raises
    /// nothing while only such an app reads). held, also when empty (API 1.234): a read with no `held` is an app before
    /// that word, for which the hub takes two reads after a grant as the door having it, so this read would end a
    /// restart's wait while the door's file may not have the grant yet.
    public static func viewURL(hub: URL, database: String, held: String) -> URL {
        var parts = URLComponents(url: hub.appendingPathComponent("ui/door"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "db", value: database), .init(name: "renew", value: "form"),
                            .init(name: "held", value: held)]
        return parts.url!
    }

    public func save(hub: URL, database: String, client: String, address: String, port: Int) async throws {
        var request = URLRequest(url: hub.appendingPathComponent("ui/door"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client, forHTTPHeaderField: "X-Fleet-Client")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "request_id": UUID().uuidString.lowercased(), "db": database, "address": address, "port": port], options: [.sortedKeys])
        let (data, response) = try await session.hubData(for: request)
        HubWrites.note(request)
        guard let response = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        guard response.statusCode == 200 else { throw HubError.refusal(.read(status: response.statusCode, body: data)) }
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
        let (data, response) = try await session.hubData(for: request)
        HubWrites.note(request)
        guard let response = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        guard response.statusCode == 200 else { throw HubError.refusal(.read(status: response.statusCode, body: data)) }
    }

    /// `POST /ui/door/host` (API 1.100): what this Mac's round did on one server, `installed`, `passed` or `failed`, or
    /// (API 1.241) `unchecked`, with one line. The hub tells the manager of the first server that passed, of each
    /// failure, of each cause of `unchecked`, and of a pass after either.
    public func hostReport(hub: URL, database: String, client: String, host: String, state: String, said: String) async throws {
        var request = URLRequest(url: hub.appendingPathComponent("ui/door/host"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client, forHTTPHeaderField: "X-Fleet-Client")
        let line = String(said.replacingOccurrences(of: "\n", with: " ").prefix(600))
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "request_id": UUID().uuidString.lowercased(), "db": database, "host": host, "state": state, "said": line],
                                                      options: [.sortedKeys])
        let (data, response) = try await session.hubData(for: request)
        HubWrites.note(request)
        guard let response = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        guard response.statusCode == 200 else { throw HubError.refusal(.read(status: response.statusCode, body: data)) }
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
        let (data, response) = try await session.hubData(for: request)
        HubWrites.note(request)
        guard let response = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        guard response.statusCode == 200 else { throw HubError.refusal(.read(status: response.statusCode, body: data)) }
    }
}
