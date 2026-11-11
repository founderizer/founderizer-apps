import Foundation

/// `GET /ui/servers` (owner feature `servers`): every machine that runs agents or can run them, also one with no agent,
/// with its newest reading, whether a new agent can go on it, and its newest job; and the state of the newest join
/// code, never the code.
public struct ServerList: Decodable, Sendable {
    public let db: String
    public let time: Double
    public let desired_revision: String?
    public let servers: [ServerEntry]
    public let join: JoinState?

    public func validate(database: String) throws {
        guard db == database, time.isFinite, servers.count <= 1000, Set(servers.map(\.name)).count == servers.count,
              servers.allSatisfy({ $0.name.range(of: Servers.namePattern, options: .regularExpression) != nil ||
                                   $0.name.range(of: Servers.machinePattern, options: .regularExpression) != nil }) else {
            throw HubError.invalidResponse
        }
    }

    /// The servers on which a new agent can go now.
    public var available: [ServerEntry] { servers.filter(\.available) }

    /// The server of an agent, or nil.
    public func server(of agent: String) -> ServerEntry? { servers.first { $0.agents.contains(agent) } }
}

extension ServerEntry {
    /// What a server's Security row reads: the private network, the firewall and, on a server, its automatic security
    /// updates, each with its name, whether it is on (nil: not reported) and its words. Automatic updates whose last
    /// good run is older than three days at `time` are stalled, which is not on (Fleet 2026.11.173 reads that run).
    public func securityParts(_ security: ServerReading.Security, at time: Double) -> [(name: String, on: Bool?, words: String)] {
        var parts: [(name: String, on: Bool?, words: String)] = [
            ("Private network", security.tailscale, Servers.onOffWords(security.tailscale)),
            ("Firewall", security.firewall.map { $0 == "active" }, security.firewall?.capitalized ?? "Not reported")]
        if kind != "mac" {
            let stalled = security.unattended_upgrades == true
                && (security.upgraded_at.map { time - $0 > Servers.updatesStalled } ?? false)
            parts.append(("Security updates", stalled ? false : security.unattended_upgrades,
                          stalled ? Servers.stalled : security.unattended_upgrades == true ? "Automatic"
                            : security.unattended_upgrades == false ? "Off" : "Not reported"))
        }
        return parts
    }

    /// The server's newest job when it prepares a provider for this agent (`prepare`), or nil.
    public func preparation(of agent: String) -> ServerJob? {
        guard let job, job.kind == "prepare", job.agent == agent else { return nil }
        return job
    }
}

extension RuntimeSwitch {
    /// The server's preparation that Change provider shows: one of this switch's target provider, while it goes on,
    /// after a failure, and after its end until this readiness has the helper's new reading. A preparation of another
    /// provider is from before a switch.
    public func shows(_ job: ServerJob?) -> ServerJob? {
        guard let job, job.kind == "prepare", job.runtime == to else { return nil }
        return job.isOpen || job.state == "failed" || (job.state == "done" && needsSetup) ? job : nil
    }
}

public struct ServerEntry: Decodable, Identifiable, Sendable {
    public let name: String
    /// linux or mac; nil while no reading says it.
    public let kind: String?
    public let address: String?
    /// The OS user of its agents and its server service.
    public let user: String?
    /// The hub's own machine.
    public let hub: Bool
    /// It joined with a join code and has a server service.
    public let joined: Bool
    public let agents: [String]
    public let reading: ServerReading?
    public let available: Bool
    /// What stops a new agent, as codes: `Servers.reason(_:)` gives the words.
    public let why: [String]
    public let job: ServerJob?
    /// Its CPU, memory and disk, or nil from a hub before the load readings (4 November 2026) and while nothing
    /// has read them.
    public let load: ServerLoad?
    public var id: String { name }
    public var isMac: Bool { kind == "mac" }
    public var symbol: String { isMac ? "desktopcomputer" : "server.rack" }
}

/// **A server's CPU, memory and disk** (the owner's yes of 4 November 2026 to the mockup: "do we have data of
/// cpu/memory/disk usage for the different fleet servers? THAT would be useful for the Servers section"): what its server
/// service read last, or for the hub's own machine what the hub read at the request. A figure that cannot be read is
/// nil, and a reading that cannot be read at all loses the figures and never the list.
public struct ServerLoad: Decodable, Sendable, Equatable {
    /// The five-minute load average over the processors, in percent: over 100 while work waits for them.
    public let cpu_percent: Double?
    public let memory_used: Double?
    public let memory_total: Double?
    public let disk_used: Double?
    public let disk_total: Double?
    /// When it was read, by the server's own clock.
    public let at: Double?

    public init(cpu_percent: Double?, memory_used: Double?, memory_total: Double?, disk_used: Double?,
                disk_total: Double?, at: Double?) {
        self.cpu_percent = cpu_percent; self.memory_used = memory_used; self.memory_total = memory_total
        self.disk_used = disk_used; self.disk_total = disk_total; self.at = at
    }

    private enum Keys: String, CodingKey { case cpu_percent, memory_used, memory_total, disk_used, disk_total, at }
    public init(from decoder: Decoder) throws {
        let keys = try? decoder.container(keyedBy: Keys.self)
        func figure(_ key: Keys) -> Double? {
            (try? keys?.decodeIfPresent(Double.self, forKey: key)).flatMap { $0 }.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        }
        self.init(cpu_percent: figure(.cpu_percent), memory_used: figure(.memory_used), memory_total: figure(.memory_total),
                  disk_used: figure(.disk_used), disk_total: figure(.disk_total), at: figure(.at))
    }

    /// The share of the processors in use, at most 100.
    public var cpu: Double? { cpu_percent.map { min($0, 100) } }
    public var memory: Double? { Self.share(memory_used, memory_total) }
    public var disk: Double? { Self.share(disk_used, disk_total) }
    /// A figure at this share or over it is orange: the server runs short.
    public static let high: Double = 90
    /// The share as its words say it, at `high` or over: "90%" is orange as soon as it says 90.
    public static func isHigh(_ share: Double) -> Bool { share.rounded() >= high }

    /// Read in the last ten minutes: a server service reads every five.
    public func isCurrent(at time: Double) -> Bool {
        guard let at else { return false }
        return time - at >= -5 && time - at < 600
    }

    static func share(_ used: Double?, _ total: Double?) -> Double? {
        guard let used, let total, total > 0 else { return nil }
        return min(used / total * 100, 100)
    }
}

/// **The few words of a load figure**, the same on Servers, a server's page, Agents and System status.
public enum LoadWords {
    /// "14%": a share in whole percent.
    public static func percent(_ share: Double) -> String { "\(Int(share.rounded()))%" }

    /// "11,9 of 74,8 GB used": both in the unit of the total, with one decimal, in this Mac's own numbers.
    public static func used(_ used: Double, of total: Double) -> String {
        let units = ["KB", "MB", "GB", "TB", "PB"]
        var size = max(total, 0) / 1024, unit = 0
        while size >= 1024, unit < units.count - 1 { size /= 1024; unit += 1 }
        let scale = pow(1024, Double(unit + 1))
        func words(_ value: Double) -> String { (value / scale).formatted(.number.precision(.fractionLength(1))) }
        return "\(words(min(max(used, 0), total))) of \(words(total)) \(units[unit]) used"
    }

    /// "640 MB", "2,3 GB": the memory of an agent's own sessions, never more than three figures before the unit, so
    /// it stays in its column ("1012 MB" did not; review A, 4 November 2026).
    public static func memory(_ bytes: Double) -> String {
        let megabytes = max(bytes, 0) / 1024 / 1024
        if megabytes.rounded() < 1000 { return "\(Int(megabytes.rounded())) MB" }
        return "\((megabytes / 1024).formatted(.number.precision(.fractionLength(1)))) GB"
    }
}

public struct ServerReading: Decodable, Sendable {
    /// `server`: its own server service; `agent`: the helper of an agent on it (a machine from before servers).
    public let source: String
    public let revision: String?
    /// The reading's revision has the hub's Fleet files; nil when the hub cannot say.
    public let current: Bool?
    public let os: MachineStatus.System
    public let security: Security?
    public let runtimes: [String: Runtime]
    public let user: String?
    public let reported_at: Double
    public let stale: Bool
    public struct Runtime: Decodable, Sendable { public let version: String?; public let signed_in: Bool? }
    public struct Security: Decodable, Sendable {
        public let unattended_upgrades: Bool?
        public let pending_security: Int?
        public let reboot_required: Bool?
        public let firewall: String?
        public let tailscale: Bool?
        /// When apt's daily run last ended a security upgrade well, or nil: before its first, and from a hub before
        /// Fleet 2026.11.173.
        public let upgraded_at: Double?
    }

    public func isCurrent(at time: Double) -> Bool {
        !stale && reported_at.isFinite && time - reported_at >= -5 && time - reported_at < 600
    }
}

/// One job of a server's service: the install of an agent (`install`), the preparation of the other provider of an
/// agent on it before the owner switches it (`prepare`), or what was the own of an agent he deleted (`remove`).
public struct ServerJob: Decodable, Equatable, Sendable {
    public let id: Int
    public let kind: String
    public let agent: String?
    public let runtime: String?
    /// queued, running, needs_owner, done, failed or canceled.
    public let state: String
    /// user, runtime, checkout, service or sign_in; a preparation has only runtime and sign_in, and a removal service,
    /// files and user (`Servers.removeSteps`). `user` is the OS
    /// user of that agent on a Linux server, which the server makes before anything else; a Mac keeps one user for
    /// its agents, so a Mac install has no such step.
    public let step: String?
    public let detail: String?
    public let prompt: Prompt?
    public let created: Double
    public let updated: Double
    /// True on a `failed` job whose sign-in step only waited too long for the owner (owner API 1.88). nil from a hub
    /// before it.
    public let timed_out: Bool?

    public var isOpen: Bool { ["queued", "running", "needs_owner"].contains(state) }

    /// The owner's sign-in while the job waits: Codex's link and code, or the one command for Claude Code.
    public struct Prompt: Decodable, Equatable, Sendable {
        public let kind: String
        public let purpose: String
        public let url: String?
        public let code: String?
        public let command: String?

        /// Codex's device sign-in page, only on its own host and over HTTPS.
        public var signInURL: URL? {
            guard kind == "open_url", purpose == "codex_login", let url, let link = URL(string: url), link.scheme == "https",
                  link.host?.lowercased() == "auth.openai.com", link.user == nil, link.password == nil, link.port == nil
            else { return nil }
            return link
        }

        /// The one command for Claude Code's own sign-in in a terminal on the server: one line without control
        /// characters. The app shows it and copies it, and never runs it.
        public var terminalCommand: String? {
            guard kind == "terminal", purpose == "claude_login", let command, !command.isEmpty, command.utf8.count <= 1000,
                  !command.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
            return command
        }

        public var deviceCode: String? {
            guard let code, code.range(of: "^[A-Z0-9]{4}-[A-Z0-9]{4,6}$", options: .regularExpression) != nil else { return nil }
            return code
        }
    }
}

/// The newest join code, without the code.
public struct JoinState: Decodable, Equatable, Sendable {
    /// The code's label: the name typed for the server on a hub from before `server_names`, else "".
    public let name: String
    public let kind: String
    public let created: Double
    public let expires_at: Double
    /// open, joined, expired or canceled.
    public let state: String
    /// The name now of the server that joined with the code (nil until it joined).
    public let server: String?

    /// This is the join of the code that the hub made as `name`, `kind` and `expiresAt`. A code with a name is found by
    /// its name, as before `server_names`; a hub with `server_names` gives a code no name, and its kind and its end, which
    /// the hub wrote once for both answers, tell it from every other code.
    public func isOf(name: String, kind: String, expiresAt: Double) -> Bool {
        name.isEmpty ? self.kind == kind && abs(expires_at - expiresAt) < 0.001 : self.name == name
    }
}

/// The answer of `POST /ui/servers/join`: the code and its line, given once. A repeat of the request gives them null.
public struct JoinCode: Decodable, Sendable {
    public let ok: Bool
    public let request_id: String
    /// The code's label: the name sent for the server, or "" when none was sent (`server_names`).
    public let name: String
    public let kind: String
    public let expires_at: Double
    public let code: String?
    public let line: String?
    public let replayed: Bool

    /// The hub's newest join when it is this code's, or nil.
    public func state(in list: ServerList?) -> JoinState? {
        list?.join.flatMap { $0.isOf(name: name, kind: kind, expiresAt: expires_at) ? $0 : nil }
    }
}

/// The answer of `POST /ui/servers/<server>/agents`.
public struct ServerAgentReceipt: Decodable, Sendable {
    public let ok: Bool
    public let request_id: String
    public let agent: String
    public let server: String
    public let runtime: String
    public let job: Int
    public let revision: String
    public let sha256: String
}

/// The answer of `POST /ui/servers/<server>/prepare`.
public struct ServerPrepareReceipt: Decodable, Sendable {
    public let ok: Bool
    public let request_id: String
    public let agent: String
    public let server: String
    public let runtime: String
    public let job: Int
}

/// The answer of `POST /ui/servers/<server>/remove`.
public struct ServerRemoval: Decodable, Sendable {
    public let ok: Bool
    public let request_id: String
    public let server: String
    public let removed: Bool
}

/// The servers feature: names, words and the choices of Add server and Add agent.
public enum Servers {
    public static let feature = "servers"
    /// The hub takes `POST /ui/servers/<server>/prepare`: a joined server prepares a provider before a switch.
    public static let prepareFeature = "server_prepare"
    /// The hub names a server by its name in Tailscale, at its join and after a rename there (the owner, 30 October
    /// 2026: "can't we always use the actual machine names?"), so Add server asks for no name.
    public static let namesFeature = "server_names"
    /// The name of a new server, as the hub takes it.
    public static let namePattern = "^[a-z][a-z0-9-]{1,30}$"
    /// The name of a machine from before servers (team.json "addresses").
    static let machinePattern = "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"
    public static let kinds = ["linux", "mac"]

    /// Add server asks the owner for the new server's name: only a hub from before `server_names` takes one.
    public static func asksName(_ features: [String]?) -> Bool { features?.contains(namesFeature) != true }

    /// The hub carries a new Mac's setup by itself, and adds its first agent (`mac_setup`).
    public static func setsUpMacs(_ features: [String]?) -> Bool { features?.contains("mac_setup") == true }

    /// The hub keeps the owner's choice of AI for a new server (`server_ai_choice`).
    public static func choosesAI(_ features: [String]?) -> Bool { features?.contains("server_ai_choice") == true }

    /// A name for the next server that no machine has: server-2, server-3, … On a hub with `server_names` it is only
    /// the name a Mac's installer is sent, which its older copies refuse to go without.
    public static func suggestedName(taken: [String]) -> String {
        let names = Set(taken)
        return (2...(names.count + 2)).lazy.map { "server-\($0)" }.first { !names.contains($0) } ?? "server-new"
    }

    /// **The servers that came back under another name**, old name to new: a server renamed in Tailscale is renamed in
    /// Fleet by itself (`server_names`), and keeps its private address. `before` is each name this Mac knew with its
    /// address, `after` each name of the newest reading with its address. A name moves when it is gone, its address is
    /// one server's now, that server's name is a new one, and no other gone name had that address.
    public static func renames(before: [String: String], after: [String: String]) -> [String: String] {
        var now: [String: [String]] = [:], gone: [String: [String]] = [:]
        for (name, address) in after where !address.isEmpty { now[address, default: []].append(name) }
        for (name, address) in before where after[name] == nil && !address.isEmpty { gone[address, default: []].append(name) }
        var moves: [String: String] = [:]
        for (address, old) in gone where old.count == 1 {
            guard let new = now[address], new.count == 1, before[new[0]] == nil else { continue }
            moves[old[0]] = new[0]
        }
        return moves
    }

    /// Why the name cannot be the name of a new server, or nil.
    public static func nameProblem(_ name: String, taken: [String]) -> String? {
        guard name.range(of: namePattern, options: .regularExpression) != nil else {
            return "Use 2 to 31 characters: a-z, 0-9 and -, starting with a letter."
        }
        return taken.contains(name) ? "A server has this name." : nil
    }

    /// What stops a new agent on a server, in words.
    public static func reason(_ code: String) -> String {
        switch code {
        case "hub_machine": return "It is the hub's server."
        // Since a server takes a second agent (hub of 3 November 2026), this says that its Founderizer is older than the
        // hub's and cannot install one yet; it updates itself.
        case "has_agent": return "It takes another agent once Founderizer there is updated."
        case "no_service": return "It did not join with a join line, so it has no server service."
        case "no_reading": return "Its server service sent no reading yet."
        case "offline": return "Its server service sent no reading in the last 10 minutes."
        // An install or a deleted agent's removal: one job at a time.
        case "busy": return "It works on an agent now."
        case "fix_holder": return "An agent there has full control of it."
        // The agent there holds servers through the door, which knows it by its server's address.
        case "door_caller": return "The agent there manages your servers, so it runs alone."
        default: return "It cannot take an agent now."
        }
    }

    /// A server's state in a few words for its row, and whether the owner may act: a job first, then whether it answers.
    /// `helpers` is the hub's health of them, empty until it is read: the row then goes by the reading alone.
    public static func state(_ server: ServerEntry, helpers: [FleetHealth.Helper], time: Double, fresh: Bool)
        -> (words: String, attention: Bool) {
        // **While the hub does not answer, every row is the last reading** and says nothing it does not know: the
        // machine may be connected or not, an install may have gone on. It said "Not connected" in orange for 8 of 10
        // servers while only the hub was silent. The page says that it shows the last reading.
        if !fresh { return (Self.lastReading, false) }
        if let job = server.job, job.kind == "install", let agent = job.agent?.agentLabel {
            switch job.state {
            case "needs_owner": return ("Sign-in needed", true)
            case "queued", "running": return ("Installing \(agent)…", false)
            case "failed" where server.agents.contains(job.agent ?? ""): return ("Install of \(agent) failed", true)
            default: break
            }
        }
        // **A deleted agent's removal** (the owner's yes of 7 November 2026 to Delete…): the agent is gone from the
        // fleet, so a removal that stopped is the server's to show, with Try again on its page.
        if let job = server.job, job.kind == "remove", let agent = job.agent?.agentLabel {
            switch job.state {
            case "queued", "running": return ("Removing \(agent)…", false)
            case "failed": return ("Removal of \(agent) failed", true)
            default: break
            }
        }
        // A failed preparation changes nothing for the agent: its Change provider shows it, with Try again.
        if let job = server.job, job.kind == "prepare", let agent = job.agent?.agentLabel {
            switch job.state {
            case "needs_owner": return ("Sign-in needed", true)
            case "queued", "running": return ("Preparing \(providerName(job.runtime ?? "")) for \(agent)…", false)
            default: break
            }
        }
        // The row says the same word its own page says, and in the owner's own terms: connected, or not. He
        // reads the list and the page one after the other, and two vocabularies for one machine is the
        // inconsistency between screens he objects to ("I only care about connected or not connected",
        // 20 October 2026). "Update available" stays, because it is not about whether the hub hears from
        // the machine: it is something to do. **Three words at most** (fix round 3, item 36): "Scout waits for your
        // sign-in" is "Sign-in needed", as a task says it.
        // **"Not answering", as its chat and System status say it** (T-25, fix round 2): one state, one word.
        // **By the page's own rule** (`MachineConnection.of`): the row went by the reading alone, so a server whose helpers
        // had gone silent stayed "Connected" here, for as long as its server service reported, while its page said "Not
        // answering" (31 October 2026).
        guard case .connected = MachineConnection.of(server, helpers: helpers, time: time, fresh: fresh) else {
            return ("Not answering", true)
        }
        // **No "Free"** (the owner, 3 November 2026: "this is confusing, since we allow multiple agents per server"): a
        // server with agents takes one more, so room for an agent is no news on any row; the row names its agents.
        if let reading = server.reading, reading.isCurrent(at: time), reading.current == false {
            return ("Update available", false)
        }
        return ("Connected", false)
    }

    /// The state of a server on a reading that the hub has not confirmed since: unknown.
    public static let lastReading = "Last reading"

    /// The words of a job: its step, then its own detail.
    public static func jobWords(_ job: ServerJob) -> String {
        let agent = job.agent?.agentLabel ?? "The agent"
        let prepare = job.kind == "prepare", provider = providerName(job.runtime ?? "")
        if job.kind == "remove" { return removalWords(job, agent: agent) }
        let work = prepare ? "The preparation of \(provider)" : "The install of \(agent)"
        switch job.state {
        case "queued": return prepare ? "The server starts to prepare \(provider) in a few seconds." :
            "The server starts the install of \(agent) in a few seconds."
        case "done": return job.detail ?? (prepare ? "\(provider) is ready for \(agent)." : "\(agent) runs on its server.")
        case "canceled": return "\(work) ended: the server left Founderizer."
        default: break
        }
        if let detail = job.detail, !detail.isEmpty { return detail }
        switch job.step {
        case "user": return "The OS user of \(agent) on the server."
        case "runtime": return prepare ? "\(provider) on the server." : "The provider of \(agent)."
        case "checkout": return "The checkout of \(agent)."
        case "service": return "The service of \(agent)."
        case "sign_in": return "The sign-in of \(prepare ? provider : agent)."
        default: return "\(work)."
        }
    }

    /// The words of a deleted agent's removal: its step, then its own detail.
    private static func removalWords(_ job: ServerJob, agent: String) -> String {
        switch job.state {
        case "queued": return "The server starts to remove \(agent) in a few seconds."
        case "done": return job.detail ?? "\(agent) is removed from its server."
        case "canceled": return "The removal of \(agent) ended: the server left Founderizer."
        default: break
        }
        if let detail = job.detail, !detail.isEmpty { return detail }
        switch job.step {
        case "service": return "The service of \(agent)."
        case "files": return "The files of \(agent)."
        case "user": return "The OS user of \(agent) on the server."
        default: return "The removal of \(agent)."
        }
    }

    /// The steps of an install, in order, with the title of each. The first one is the agent's own OS user, which
    /// a Linux server makes before it installs anything, so that no agent's home is readable by another agent's
    /// user (PRODUCT.md P2).
    public static let installSteps: [(id: String, title: String)] = [
        ("user", "User"), ("runtime", "AI provider"), ("checkout", "Checkout"), ("service", "Service"), ("sign_in", "Sign-in"),
    ]
    /// The steps of a preparation: the install's provider and sign-in. The agent's checkout and service stay.
    public static let prepareSteps: [(id: String, title: String)] = [("runtime", "AI provider"), ("sign_in", "Sign-in")]
    /// The steps of a deleted agent's removal: its service stops, its files go, then its own OS user, which only a
    /// Linux server has.
    public static let removeSteps: [(id: String, title: String)] = [
        ("service", "Its service"), ("files", "Its files"), ("user", "Its account"),
    ]

    /// The steps of this job, in order. A Mac makes no user of its own for an agent — its agents are one Mac user's
    /// LaunchAgents — so that step is not among a Mac install's, and the screen does not mark it as done.
    public static func steps(_ job: ServerJob, onMac: Bool = false) -> [(id: String, title: String)] {
        if job.kind == "prepare" { return prepareSteps }
        let steps = job.kind == "remove" ? removeSteps : installSteps
        return onMac ? steps.filter { $0.id != "user" } : steps
    }

    /// A provider on a server in a few words: not installed, its version and sign-in.
    public static func providerWords(_ runtime: ServerReading.Runtime?) -> String {
        guard let runtime, let version = runtime.version, !version.isEmpty else { return "Not installed" }
        switch runtime.signed_in {
        case true?: return "\(version) · Signed in"
        case false?: return "\(version) · Not signed in"
        case nil: return "\(version) · Sign-in not reported"
        }
    }

    /// One provider on a machine, as a mark: installed and signed in, installed and not, or not installed. The
    /// version and the sign-in are behind the mark (`providerWords`), which is where the app keeps what it knows.
    public static func providerMark(_ runtime: ServerReading.Runtime?) -> MarkState {
        guard let runtime, let version = runtime.version, !version.isEmpty else { return .bad }
        switch runtime.signed_in {
        case true?: return .good
        case false?: return .bad
        case nil: return .unknown
        }
    }

    /// One reading of a machine's security, as a mark: on, off, or nothing reported. `true` is what should be,
    /// `false` is what he can act on, and a machine that said nothing is never drawn as a pass.
    public static func onOffMark(_ value: Bool?) -> MarkState {
        value.map { $0 ? MarkState.good : .bad } ?? .unknown
    }

    /// The words behind an on-or-off mark.
    public static func onOffWords(_ value: Bool?) -> String {
        value.map { $0 ? "On" : "Off" } ?? "Not reported"
    }

    /// What is off, by name: "Private network, Firewall off".
    public static func offWords(_ names: [String]) -> String { names.joined(separator: ", ") + " off" }

    /// The same for the parts of a Security row that are not on, where security updates that stopped are said as
    /// what they are: "Firewall off, Security updates stalled".
    public static func offWords(_ parts: [(name: String, on: Bool?, words: String)]) -> String {
        let off = parts.filter { $0.on == false }
        let plain = off.filter { $0.words != stalled }.map(\.name)
        return ((plain.isEmpty ? [] : [offWords(plain)]) + off.filter { $0.words == stalled }.map { "\($0.name) stalled" })
            .joined(separator: ", ")
    }

    /// The words of automatic security updates that have not ended well for `updatesStalled` seconds, which the hub
    /// also tells the manager of (`server_watch_sweep`).
    public static let stalled = "Stalled"
    public static let updatesStalled: Double = 3 * 86400

    /// How old a reading is, in a few words.
    public static func age(_ at: Double, now: Double) -> String {
        let seconds = max(0, now - at)
        // One of a unit is said in the singular (fix round 3, item 33: "1 seconds ago").
        func ago(_ count: Int, _ unit: String) -> String { "\(count) \(unit)\(count == 1 ? "" : "s") ago" }
        if seconds < 90 { return ago(Int(seconds), "second") }
        if seconds < 5400 { return ago(Int(seconds / 60), "minute") }
        if seconds < 172_800 { return ago(Int(seconds / 3600), "hour") }
        return ago(Int(seconds / 86_400), "day")
    }

    /// Why Add agent cannot go now, or nil. The hub checks everything again.
    public static func agentProblem(name: String, server: ServerEntry?, existing: [String]) -> String? {
        guard let server else { return "Select a server." }
        // The server he picked can no longer take one: why, in the words of its own row.
        guard server.available else { return server.why.first.map(reason) ?? "It cannot take an agent now." }
        guard name.range(of: AgentPlacement.namePattern, options: .regularExpression) != nil, name != "owner" else {
            return "Use a name of 2 to 31 characters: a-z, 0-9 and -, starting with a letter."
        }
        return existing.contains(name) ? "An agent with this name exists." : nil
    }
}
