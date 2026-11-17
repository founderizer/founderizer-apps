import Foundation

// The fleet that the first run proposes, before any of it exists: the manager's name, the team, and the servers that
// the team runs on. The owner approved the ten pictures of these pages on 14 November 2026 ("Yes, as shown") and said
// "build it!" the same day. This file is the pages' rules, with no view: which step the slider opens on, what runs
// where at each step, and the count that the card shows. A view draws what these give (`FleetShapeViews.swift`).

/// The owner's answer to "Is this fleet for personal use or for a business?".
public enum FleetUse: String, Codable, Sendable, CaseIterable {
    case personal, business
}

/// **A step of the slider of the page "Your fleet's servers"**, from the lower cost to the more secure: one server for
/// all; one for the hub and one for the team; one for the hub and one for each agent, the manager too.
public enum ServersStep: String, Codable, Sendable, CaseIterable {
    case one, two, each

    /// The step that the page opens on: the middle one for personal use, the last one for a business.
    public static func opens(for use: FleetUse) -> ServersStep { use == .personal ? .two : .each }

    /// The first sentence of the step, as the pictures have it: what runs where.
    public var fact: String {
        switch self {
        case .one: String(l10n: "Everything runs on one server.")
        case .two: String(l10n: "The hub and its keys have a server of their own.")
        case .each: String(l10n: "The hub and each agent have a server of their own.")
        }
    }

    /// The second sentence of the step, as the pictures have it: what an agent that breaks out of its account reaches.
    public var risk: String {
        switch self {
        case .one: String(l10n: "An agent that breaks out of its account can reach every key of your fleet.")
        case .two: String(l10n: "An agent that breaks out of its account can reach the other agents, but not those keys.")
        case .each: String(l10n: "An agent that breaks out of its account finds nothing else there.")
        }
    }

    /// The two sentences of the step.
    public var means: String { "\(fact) \(risk)" }
}

extension ServersStep {
    /// **What the first run's one press makes** (slice 2 of the one wizard; the owner's "that is brilliant!" of 16
    /// November 2026 to the build page's picture, where one press made every server of the fleet): the hub's server,
    /// and with 2 servers or 1 per agent the manager's own server too. On 1 server the manager runs on the hub's server.
    public var managersOwnServer: Bool { self != .one }

    /// That press, in the picture's words: "Make the server" or "Make 2 servers".
    public var firstPress: String { managersOwnServer ? String(l10n: "Make 2 servers") : String(l10n: "Make the server") }
}

extension ServersStep {
    /// **The step where a fleet stands now**, from where its agents run (`places`, the hub's list): every agent that
    /// the slider moves on the hub's own server is 1 server; the hub alone and all of them on one other server is 2
    /// servers; the hub alone and each of them alone is 1 per agent. A fleet whose one such agent is alone on its
    /// server fits 2 servers and 1 per agent: `kept`, the step that the owner chose last, settles it, and with none
    /// the first run's default, 2 servers. Any other fleet stands between two steps, and gets nil.
    public static func now(_ places: [ShapePlace], kept: ServersStep? = nil) -> ServersStep? {
        let onHub = places.first { $0.hub }?.movable ?? []
        let others = places.filter { !$0.hub && !$0.movable.isEmpty }
        if !onHub.isEmpty { return others.isEmpty ? .one : nil }
        switch others.count {
        case 0: return nil
        case 1: return others[0].movable.count > 1 || kept != .each ? .two : .each
        default: return others.allSatisfy { $0.movable.count == 1 } ? .each : nil
        }
    }
}

/// **The page "Your fleet's servers" before a team exists**: the first run asks for the servers after the manager's
/// name, when the fleet is the hub and the manager. The page then draws the agents to come too, so that the three steps
/// differ in the drawing: without them the last two steps are the same two servers.
public enum ServersSketch {
    public enum Part: Hashable, Sendable {
        case hub, manager
        /// An agent to come: no name and no mark yet.
        case next
    }

    /// How many agents to come the drawing shows.
    public static let next = 2

    /// The servers of a step, the hub's first, each with what runs on it.
    public static func servers(_ step: ServersStep) -> [[Part]] {
        let agents = Array(repeating: Part.next, count: next)
        switch step {
        case .one: return [[.hub, .manager] + agents]
        case .two: return [[.hub], [.manager] + agents]
        case .each: return [[.hub], [.manager]] + agents.map { [$0] }
        }
    }

    /// The words under a step of the slider: a count where the step has one, and no count for the step whose count
    /// follows the team.
    public static func words(_ step: ServersStep) -> String {
        switch step {
        case .one: FleetCount(servers: 1, macs: 0).serverWords
        case .two: FleetCount(servers: 2, macs: 0).serverWords
        case .each: String(l10n: "1 per agent")
        }
    }
}

/// **The steps of the manager's own setup**, on Back's line of each of its pages while it gets its first server (the
/// owner, 15 November 2026, of a fleet whose manager had no server: "If i click on the manager I only see the choice
/// between VPS and mac mini/studio, nothing else! no progress steps ... very bad", and "they look good" to their
/// pictures in `~/dev/founderizer-plans/manager-setup-steps/`): its name, its AI provider, the servers, its sign-in.
/// The AI provider comes before the servers (the owner, 16 November 2026: "agent onboarding should ask first for the
/// name and AI provider before the server page"). "Servers" is the step of each page that gives the manager its
/// server, of the page of the fleet's shape, and of the provider's install on that server.
public enum ManagerSetupSteps: Int, CaseIterable, Sendable {
    case manager, provider, servers, signIn

    public var name: String {
        switch self {
        case .manager: String(l10n: "Manager")
        case .provider: String(l10n: "AI provider")
        case .servers: String(l10n: "Servers")
        case .signIn: String(l10n: "Sign in")
        }
    }

    public static var names: [String] { allCases.map(\.name) }

    /// **The step of a page of an agent's setup** (`AgentSetupPage`), as the place of the step in the line: the wait
    /// for the provider's install on its server and a switch of provider are the step Servers, and after the sign-in
    /// each step is done (`names.count`), while the machine check and the activation run by themselves.
    public static func current(_ page: AgentSetupPage) -> Int {
        switch page {
        case .name: manager.rawValue
        case .provider: provider.rawValue
        case .servers, .server, .installing, .switching: servers.rawValue
        case .signIn: signIn.rawValue
        case .activate: allCases.count
        }
    }
}

/// **The steps of the first run**, which each of its pages after the welcome page shows on Back's line
/// (`SetupProgress`): the manager's name, its AI provider, the servers of the fleet, this Mac on the private network,
/// the VPS of the fleet's server, and the build. The AI provider comes after the name and before the servers (the
/// owner, 16 November 2026: "agent onboarding should ask first for the name and AI provider before the server page",
/// and his yes of the same day to the pictures of one wizard in `~/dev/founderizer-plans/one-wizard-build-page/`).
/// "VPS" is the step that was "Provider", so that "AI provider" and "Provider" never stand in one line.
public enum FirstRunSteps: Int, CaseIterable, Sendable {
    case manager, aiProvider, servers, network, vps, build

    public var name: String {
        switch self {
        case .manager: String(l10n: "Manager")
        case .aiProvider: String(l10n: "AI provider")
        case .servers: String(l10n: "Servers")
        case .network: String(l10n: "Network")
        case .vps: String(l10n: "VPS")
        case .build: String(l10n: "Build")
        }
    }

    public static var names: [String] { allCases.map(\.name) }

    /// **The steps that the first run has now**: all six, since the page of the manager's AI provider is in it. A step
    /// that has no page is never in this list.
    public static let inFlow: [FirstRunSteps] = [.manager, .aiProvider, .servers, .network, .vps, .build]

    /// **The step of a page**, by the page's name of `setup_state`, or nil for a page that shows no steps: the welcome
    /// page and the page of the owner's own agent; a build and an install, which show their own steps and their minutes
    /// under their title; and the pages after them. The pages after "Name your manager" show the steps only when the
    /// owner came through that page (`named`): in a first run that opens on a later page with no name
    /// (`-firstRunStep`), a step "Manager" would say a thing that did not happen. The way of the owner's own agent
    /// passes "Name your manager" too, since 15 November 2026.
    public static func of(page: String, named: Bool) -> FirstRunSteps? {
        switch page {
        case "name": .manager
        case "aiProvider": named ? .aiProvider : nil
        case "servers": named ? .servers : nil
        case "network", "key": named ? .network : nil
        case "cloud", "token", "vps", "machine": named ? .vps : nil
        default: nil
        }
    }
}

/// **What the first run does with the manager's AI provider when it hands the window over** (`FirstRunView.finish`):
/// the owner chose it on the first run's page, so the manager's setup does not ask for it a second time.
public enum FirstRunHandover: Equatable, Sendable {
    /// The manager has no server yet: its setup gets the provider with its server (`FleetStore.noteProvider`).
    case keep(String)
    /// This first run's installer put the manager on the hub's own server with that program: the first run asks for
    /// its sign-in, and hands the window over when that request has its answer.
    case signIn(String)
    /// Nothing to give: the window goes on at once.
    case none

    /// `chosen`: the provider of this first run (`FirstRunModel.chosenAI`), or nil. `placed` and `runtime`: the hub's
    /// manager as its state gives it, or nil with no manager there. `installedOneServer`: this first run installed the
    /// hub with "1 server". `writes`: the hub takes a write now (`FleetStore.canWrite`), so that the request has its
    /// answer within the hub client's own limit; a hub that does not take one is no reason to hold the window.
    /// `asked`: the sign-in is on its way already, so a second call hands over at once.
    public static func of(chosen: String?, placed: Bool?, runtime: String?, installedOneServer: Bool, writes: Bool,
                          asked: Bool) -> FirstRunHandover {
        guard let chosen, let placed else { return .none }
        if !placed { return .keep(chosen) }
        guard installedOneServer, runtime == chosen, writes, !asked else { return .none }
        return .signIn(chosen)
    }
}

/// The team that the card "Your fleet" shows: the manager by its name, and each agent by its role.
public struct FleetPlan: Equatable, Codable, Sendable {
    /// The one thing that an agent uses, at the end of its dotted line.
    public struct Use: Equatable, Codable, Sendable {
        public enum Kind: String, Codable, Sendable { case mailbox, repository, key, login }
        public var kind: Kind
        /// Its name as the card shows it: an address, a repository, "Stripe key".
        public var name: String
        public init(kind: Kind, name: String) { self.kind = kind; self.name = name }
    }

    public struct Agent: Equatable, Codable, Sendable, Identifiable {
        /// The name that the agent gets in the hub. Its mark comes from it.
        public var name: String
        /// Its role, which is how every page names an agent.
        public var role: String
        /// What it does, in one sentence: the card shows it under the pointer.
        public var does: String?
        /// What it asks the owner before it does it: "before it sends".
        public var asksFirst: String?
        public var uses: Use?
        /// An agent that needs a browser runs on a Mac.
        public var needsBrowser: Bool
        public var id: String { name }
        public init(name: String, role: String, does: String? = nil, asksFirst: String? = nil, uses: Use? = nil,
                    needsBrowser: Bool = false) {
            self.name = name; self.role = role; self.does = does; self.asksFirst = asksFirst; self.uses = uses
            self.needsBrowser = needsBrowser
        }
    }

    /// The manager's name as the owner typed it.
    public var manager: String
    public var agents: [Agent]
    public init(manager: String, agents: [Agent]) { self.manager = manager; self.agents = agents }

    /// The names of the team in the hub's order, the manager first: the order that gives each agent its mark.
    public var names: [String] { [ManagerName.agentName(manager) ?? ManagerName.fallback] + agents.map(\.name) }
}

/// One machine of the fleet, and what runs on it.
public struct FleetPlace: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case server, mac }
    public enum Part: Equatable, Sendable {
        case hub, manager
        /// An agent, by its place in the plan's list.
        case agent(Int)
    }
    public let kind: Kind
    public let parts: [Part]
    public init(kind: Kind, parts: [Part]) { self.kind = kind; self.parts = parts }
}

/// How many machines a step needs: the words under the slider's steps and in the card's foot.
public struct FleetCount: Equatable, Sendable {
    public let servers: Int
    public let macs: Int
    public init(servers: Int, macs: Int) { self.servers = servers; self.macs = macs }

    /// "1 server", "4 servers": the words under a step of the slider.
    public var serverWords: String { servers == 1 ? String(l10n: "1 server") : String(l10n: "\(servers) servers") }

    /// "2 servers", "6 servers and 1 Mac": the words in the foot of the card "Your fleet".
    public var words: String {
        switch macs {
        case 0: serverWords
        case 1: String(l10n: "\(serverWords) and 1 Mac")
        default: String(l10n: "\(serverWords) and \(macs) Macs")
        }
    }
}

extension FleetPlan {
    /// **What runs where at a step.** The hub's server is first, then the servers of the team, then the Macs. An agent
    /// that needs a browser never runs on a server, and **a Mac runs one agent, at each step** (the owner's answer of
    /// 10 November 2026 in the plan "One OS user per agent": "one agent on each Mac"; on a Mac every agent would run as
    /// the desktop account, so the hub refuses a second one). The slider moves the agents on servers only.
    public func places(_ step: ServersStep) -> [FleetPlace] {
        let onServers = agents.indices.filter { !agents[$0].needsBrowser }.map(FleetPlace.Part.agent)
        let macs = agents.indices.filter { agents[$0].needsBrowser }.map { FleetPlace(kind: .mac, parts: [.agent($0)]) }
        switch step {
        case .one:
            return [FleetPlace(kind: .server, parts: [.hub, .manager] + onServers)] + macs
        case .two:
            return [FleetPlace(kind: .server, parts: [.hub]), FleetPlace(kind: .server, parts: [.manager] + onServers)] + macs
        case .each:
            return [FleetPlace(kind: .server, parts: [.hub]), FleetPlace(kind: .server, parts: [.manager])]
                + onServers.map { FleetPlace(kind: .server, parts: [$0]) } + macs
        }
    }

    public func count(_ step: ServersStep) -> FleetCount {
        let places = places(step)
        return FleetCount(servers: places.count { $0.kind == .server }, macs: places.count { $0.kind == .mac })
    }
}

/// The manager's name on the page "Name your manager".
public enum ManagerName {
    /// The name that stands in the field when the page opens.
    public static let suggested = "Juno"
    /// The name of a manager whose owner gave none that the hub takes: the hub's own, as before this page.
    public static let fallback = "manager"

    /// The names that the fleet uses itself on a server, and the starts of such names: the installer refuses them for
    /// a manager (`hub.sh --manager-name`, and `manager_name` of `hubsetup.py`: `RESERVED_AGENT_NAMES`,
    /// `FLEET_OWN_NAMES`, `FLEET_OWN_STARTS`). A change there is a change here.
    static let taken: Set<String> = ["owner", "hub", "agents", "channels", "chats", "checks", "git", "pilot", "server",
                                     "vault", "watch", "work"]
    static let takenStarts = ["login-", "vault-"]

    /// **The name that the hub gets**: the typed words in lower case, when they are one name by the installer's rule
    /// for a manager's name (a letter first, then letters, digits and "-", 2 to 26 characters, and no name that the
    /// fleet uses itself). nil for any other words, so a name with a space or an accent is asked again and never
    /// changed for the owner. The hub lets nobody rename the manager afterwards, so a name that the installer refuses
    /// must stop here, before a server is paid for.
    public static func agentName(_ typed: String) -> String? {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard name.range(of: "^[a-z][a-z0-9-]{1,25}$", options: .regularExpression) != nil, !taken.contains(name),
              !takenStarts.contains(where: name.hasPrefix) else { return nil }
        return name
    }

    /// The name as each page shows it: the typed words, with no space around them.
    public static func shown(_ typed: String) -> String { typed.trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: the hub's part: the kept step, one server later, the manager's name

/// **The hub's three feature words for the fleet's shape** (owner API 1.175; the owner, 15 November 2026, to "Start the
/// hub work for the name page and the slider in a fleet that exists?": "Yes, start it"). Each part is used only on a
/// hub that says its word in `ui_features`.
public enum FleetShapeHub {
    /// The hub keeps the step of the slider: `shape` of `GET /ui/servers`, and `POST /ui/servers/shape`.
    public static let kept = "fleet_shape"
    /// The own server of a hub that runs can take agents: the step `one` of `POST /ui/servers/shape`, and the root
    /// step of `OneServerRemote`.
    public static let later = "hub_shared_later"
    /// `POST /ui/team/agents/<agent>/rename` takes the manager while it has no server.
    public static let rename = "manager_rename"

    /// The word of the hub's installer for the kept step at a first install, with its value: `FLEET_SHAPE_STEP=two`.
    /// The step `one` has no such word: `FLEET_HUB_SERVER=shared` writes it, and the installer refuses the two
    /// together with another value.
    public static func installWord(_ step: ServersStep) -> String? {
        step == .one ? nil : "FLEET_SHAPE_STEP=\(step.rawValue)"
    }
}

/// The answer of `POST /ui/servers/shape`.
public struct ShapeReceipt: Decodable, Sendable {
    public let ok: Bool
    public let request_id: String
    /// The step that the hub keeps now.
    public let step: String
    /// The hub's own server takes agents after this command.
    public let hub_shared: Bool
    /// The hub knows no server service of its own server: the owner's Mac runs the root step (`OneServerRemote`).
    public let root_step: Bool?
    public let revision: String
    public let sha256: String
}

/// The answer of the rename of a manager with no server: no server has anything of it, so it names no server and no
/// job, which the rename of each other agent does (`AgentRenameReceipt`).
public struct ManagerNameReceipt: Decodable, Sendable {
    public let ok: Bool
    public let request_id: String
    /// The new name.
    public let agent: String
    /// The name that the manager had.
    public let was: String
    public let revision: String
    public let sha256: String
}

extension HubClient {
    /// `POST /ui/servers/shape` (owner feature `fleet_shape`): the hub keeps this step of the slider, against the
    /// team.json that the app read. With `one` on a hub whose own server takes no agents yet (`hub_shared_later`), the
    /// same commit lets it take them, and `root_step` says that this Mac's root step is still to do. With `two` or
    /// `each`, a hub whose own server runs no agent stops taking them.
    public func keepShape(hub: URL, database: String, client: String, requestID: UUID = UUID(), sha256: String,
                          step: ServersStep) async throws -> ShapeReceipt {
        guard sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw HubError.invalidResponse }
        let receipt = try JSONDecoder().decode(ShapeReceipt.self, from: await ownerCommand(
            "ui/servers/shape", hub: hub, database: database, client: client, requestID: requestID,
            fields: ["base_sha256": sha256, "step": step.rawValue]))
        guard receipt.ok, receipt.request_id.lowercased() == requestID.uuidString.lowercased(),
              receipt.step == step.rawValue else { throw HubError.invalidResponse }
        return receipt
    }

    /// `POST /ui/team/agents/<agent>/rename` for the manager while it has no server (owner feature `manager_rename`):
    /// its new name, by the rule of the installer for a manager's name (`ManagerName.agentName`). The hub refuses the
    /// rename of a manager that has a server, so the name's page comes before the move.
    public func nameManager(hub: URL, database: String, client: String, requestID: UUID = UUID(), agent: String,
                            sha256: String, name: String) async throws -> ManagerNameReceipt {
        guard agent.range(of: AgentPlacement.namePattern, options: .regularExpression) != nil,
              ManagerName.agentName(name) == name, name != agent,
              sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw HubError.invalidResponse }
        let receipt = try JSONDecoder().decode(ManagerNameReceipt.self, from: await ownerCommand(
            "ui/team/agents/\(agent)/rename", hub: hub, database: database, client: client, requestID: requestID,
            fields: ["base_sha256": sha256, "name": name]))
        guard receipt.ok, receipt.request_id.lowercased() == requestID.uuidString.lowercased(), receipt.agent == name,
              receipt.was == agent else { throw HubError.invalidResponse }
        return receipt
    }
}

/// **The root step of one server later**, which this Mac runs on the hub's own server over the owner's connection, as
/// it runs the central vault's install (`CentralVaultRemote`, with its strict check of the host key): the hub's server
/// gets its vault broker and its server service, so that it takes agents. It restarts no service of the hub, and it is
/// safe to run again.
public enum OneServerRemote {
    /// **The run, as root on the hub's machine**, in the pattern of `ConnectGate.program`: the bridge across the key
    /// change of 4 November 2026 and `kit-clone` first, and when one of them fails the run stops there; then
    /// `hubsetup.py one-server` of root's own clone, with the default hub user. The text has no "$" and no value that
    /// the hub gave: a user who is not root runs it through `sudo -n -i`.
    public static func program(in kit: String = CentralVaultRemote.rootKit) -> String {
        let step = "python3 \(kit)/hubsetup.py"
        return CentralVaultRemote.bridge(in: kit) + "; \(step) kit-clone || exit 1; \(step) one-server"
    }

    public enum Outcome: Equatable, Sendable {
        /// The hub's server has its vault and its server service, made now or there before.
        case done
        /// It stopped, with the step's own sentence, or the run's last line when it printed no answer.
        case stopped(String)
    }

    /// **The outcome in what the run printed.** `one-server` ends with one JSON object on standard output, `{"ok":
    /// true, ...}` or `{"ok": false, "error": "<one sentence>"}`; each line before it is progress. The app reads
    /// standard output and standard error as one, so the answer is the last line that is such an object. A run with
    /// none (`sudo` refused, `kit-clone` stopped) is read by its own last line.
    public static func outcome(_ output: String) -> Outcome {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for line in lines.reversed() where line.hasPrefix("{") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let ok = object["ok"] as? Bool else { continue }
            if ok { return .done }
            let said = (object["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .stopped(said.isEmpty ? String(l10n: "It gave no reason.") : String(said.prefix(300)))
        }
        return .stopped(lines.last.map { String($0.prefix(300)) } ?? String(l10n: "It gave no reason."))
    }
}

/// **What the manager's first setup shows before its server's page**, in a fleet whose first run did not ask: its
/// name, then the fleet's servers (the owner's pictures 1 and 2 in `~/dev/founderizer-plans/manager-setup-steps/`, and
/// his "Yes, start it" of 15 November 2026 to the hub's part). The hub's kept step says that the two pages are done: a
/// fleet from a first run that asked has one from its install, and the slider's Continue keeps one. So the setup can
/// be left and opened again on each page, as its other pages can.
public enum ManagerSetupStart: Equatable, Sendable {
    /// "Name your manager".
    case name
    /// "Your fleet's servers".
    case servers
    /// "1 server" is kept, and the hub's own server is not ready for the manager: this Mac's root step when the
    /// server has no server service (`rootStep`), which only his press on Continue starts, then the hub's reading
    /// of it.
    case sharing(rootStep: Bool)
    /// "1 server" is kept, and the hub's own server takes the manager: it gets that server with the AI provider that he
    /// chose.
    case onHub(String)
    /// Nothing comes before its server's page: the pages of before.
    case server
    /// The hub has the parts and no read of its servers answered yet: nothing says which page it is, so the setup
    /// waits for the read and shows none of them.
    case unread

    /// **For the agent of a setup**: only a manager with no server gets these pages, on a visit that read the hub's
    /// features (`features`, nil before that read), and not once a server joined for it on this Mac (`joined`), which
    /// gets it with its provider. `role` and `placed` are nil for an agent that the state does not list.
    public static func page(role: String?, placed: Bool?, joined: Bool, features: [String]?, named: Bool,
                            list: ServerList?) -> ManagerSetupStart {
        guard role == "manager", placed == false, !joined, let features else { return .server }
        return page(features: features, named: named, list: list)
    }

    /// `named`: he went on from the name's page on this run of the app. `list`: the hub's list of servers, or nil
    /// while no read answered.
    public static func page(features: [String], named: Bool, list: ServerList?) -> ManagerSetupStart {
        // The slider has the step "1 server", so its page needs both parts. A hub with one of them shows neither page.
        guard features.contains(FleetShapeHub.kept), features.contains(FleetShapeHub.later) else { return .server }
        guard let list else { return .unread }
        switch list.keptStep {
        case nil: return features.contains(FleetShapeHub.rename) && !named ? .name : .servers
        case .two?, .each?: return .server
        case .one?:
            guard list.hub_shared == true, let hub = list.hubRow else { return .sharing(rootStep: false) }
            if hub.joined, hub.available { return .onHub(hub.name) }
            return .sharing(rootStep: !hub.joined)
        }
    }

    /// **The page of the manager's own setup while it has no server**, in the owner's order of 16 November 2026 ("agent
    /// onboarding should ask first for the name and AI provider before the server page"): its name, its AI provider,
    /// the fleet's servers, its server. `provider`: the AI that he chose on this Mac (`FleetStore.chosenProvider`), or
    /// nil. `placeOn`: the server that it goes on now (the hub's own with "1 server", or the one that joined for it), or
    /// nil. Once both are there, the setup gives it that server and that provider by itself, and the page is the install
    /// that this command starts. A command that the hub refused (`refused`) shows the provider's page again, with the
    /// hub's words, where a press tries again.
    public func page(renaming: Bool, provider: String?, placeOn: String?, refused: Bool) -> AgentSetupPage {
        if renaming { return .name }
        switch self {
        case .name: return .name
        case .unread: return .servers
        default: break
        }
        guard let provider, !refused else { return .provider }
        switch self {
        case .servers, .sharing: return .servers
        default: return placeOn == nil ? .server : .installing(runtime: provider)
        }
    }
}
