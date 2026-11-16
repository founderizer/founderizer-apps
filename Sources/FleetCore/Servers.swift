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
    /// The hub's own server takes agents (owner API 1.168, `hub_shared`); nil from a hub before it.
    public let hub_shared: Bool?
    /// The step of the fleet's shape that the hub keeps (owner feature `fleet_shape`); nil from a hub before it, and
    /// for a fleet that never kept one. `keptStep` reads it.
    public let shape: KeptShape?

    /// **The kept step of the fleet's shape**, or nil: no step is kept, the hub does not say, or it says a step that
    /// this app does not know.
    public var keptStep: ServersStep? { shape?.step }
    /// The hub's own row.
    public var hubRow: ServerEntry? { servers.first { $0.hub } }

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
            (String(l10n: "Private network"), security.tailscale, Servers.onOffWords(security.tailscale)),
            (String(l10n: "Firewall"), security.firewall.map { $0 == "active" }, security.firewall?.capitalized ?? String(l10n: "Not reported"))]
        if kind != "mac" {
            let stalled = security.unattended_upgrades == true
                && (security.upgraded_at.map { time - $0 > Servers.updatesStalled } ?? false)
            parts.append((String(l10n: "Security updates"), stalled ? false : security.unattended_upgrades,
                          stalled ? Servers.stalled : security.unattended_upgrades == true ? String(l10n: "Automatic")
                            : security.unattended_upgrades == false ? String(l10n: "Off") : String(l10n: "Not reported")))
        }
        return parts
    }

    /// The server's newest job when it prepares a provider for this agent (`prepare`), or nil.
    public func preparation(of agent: String) -> ServerJob? {
        guard let job, job.kind == "prepare", job.agent == agent else { return nil }
        return job
    }
}

/// `shape` of `GET /ui/servers`: `{"step": "one" | "two" | "each"}`. A value of another form, and a step that this
/// app does not know, read as no kept step: they never fail the read of the list of servers.
public struct KeptShape: Decodable, Sendable, Equatable {
    public let step: ServersStep?

    public init(step: ServersStep?) { self.step = step }

    private enum Keys: String, CodingKey { case step }
    public init(from decoder: Decoder) throws {
        let values = try? decoder.container(keyedBy: Keys.self)
        step = (try? values?.decodeIfPresent(String.self, forKey: .step)).flatMap { $0 }.flatMap(ServersStep.init(rawValue:))
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
    /// On the hub's own row, the hub's own reading of its server's SSH and npm (owner API 1.170); nil on every other
    /// row, on a hub that runs on a Mac, and from a hub before it. `ServerHardening` reads it, and no page does.
    public let hardening: HubHardening?
    /// How the fleet reaches this server, by its own record (owner API 1.173); nil from a hub before it, whose rows do
    /// not say. `reach` reads it.
    public let access: ServerAccess?
    /// **The providers of an account with a kind that this server can take now** (owner API 1.186, `model_accounts`):
    /// each of them for a Linux server whose service's reading has `model_accounts`, else none. nil from a hub before
    /// it. Add agent offers its Other models card only for a server that has them, so it shows no card that the hub
    /// would refuse (spec 9.4).
    public let model_providers: [String]?
    public var id: String { name }
    public var isMac: Bool { kind == "mac" }
    /// Add agent's Other models card: a Linux server that the hub says takes such an agent.
    public var takesModelAccounts: Bool { !isMac && !(model_providers ?? []).isEmpty }
    public var symbol: String { isMac ? "desktopcomputer" : "server.rack" }

    /// **What this row says of the fleet's record of how it reaches this server**, read as `MachineReach` reads a
    /// machine's, with the row's own address. A record that is none (the hub's `ssh` is null) is a reach with no user.
    /// Nil when the row says nothing, which is another answer (`OwnerKeyPlan.record`): a row without the key (a hub
    /// before owner API 1.173), and a row whose value this app cannot use as a connection (a user, a port or an
    /// address that `ssh` cannot take: `InstallTarget.isValid`). The hub masks a text that holds a registered login
    /// in this page also (`scrub`), and a later hub can send another shape: such a value is no word that the fleet
    /// has no record, so the pages after the row still decide.
    public var reach: MachineReach? {
        guard let access, access.isRead else { return nil }
        let said = MachineReach(address: address, user: access.ssh?.user, port: access.ssh?.port)
        if access.ssh == nil { return said }
        guard let whole = said.onRecord,
              InstallTarget(host: whole.address, user: whole.user, port: whole.port).isValid else { return nil }
        return said
    }
}

/// **How the fleet reaches one server, by its own record** (owner API 1.173; the `access` entry of the fleet's file, of
/// which the list of machines has the copy for a server that an agent runs on). A server need run no agent: one that
/// joined and has none yet, and a hub's own server. Then the list of machines does not name it, and its row of the
/// list of servers is the page with its record. `ServerEntry.user` is another thing: the OS user of the server's
/// service and its agents, which is not the record's SSH user and can differ from it.
///
/// The hub sends an object on every row, also for a server with no record (`ssh` is then null), so a row without the
/// key is a hub from before it. A value that cannot be read loses its facts and never the list.
public struct ServerAccess: Decodable, Sendable, Equatable {
    /// The SSH user and port of the record; nil when the fleet has none for this server, and when `isRead` is false.
    public let ssh: VaultHub.SSH?
    /// The value has the shape that this app reads: an object whose `ssh` is null, or an object that can hold a user
    /// and a port. A value of another shape says nothing, and so does a user and a port that make no connection
    /// (`ServerEntry.reach`).
    public let isRead: Bool

    private enum Keys: String, CodingKey { case ssh }
    public init(from decoder: Decoder) throws {
        guard let keys = try? decoder.container(keyedBy: Keys.self) else {
            ssh = nil; isRead = false
            return
        }
        // An object without the key is no null: `decodeNil` throws for it, and so does the read after it.
        if (try? keys.decodeNil(forKey: .ssh)) == true {
            ssh = nil; isRead = true
        } else {
            ssh = try? keys.decode(VaultHub.SSH.self, forKey: .ssh)
            isRead = ssh != nil
        }
    }
}

/// **The hub's own reading of its own server** (owner API 1.170): that server has no server service, so the hub reads
/// the two facts of the join's hardening there itself, as its own user and with the function that a server's service
/// reads them with, about once a minute. A value that cannot be read is nil, and a key that cannot be read at all
/// loses its facts and never the list.
public struct HubHardening: Decodable, Sendable, Equatable {
    /// SSH takes keys only; nil where OpenSSH does not run there, where its files cannot say, and where the hub's read
    /// got no answer from systemctl (the hub then leaves the key out).
    public let ssh_keys_only: Bool?
    /// npm holds back a package version newer than seven days; nil where the server has no npm.
    public let npm_rule: Bool?
    /// When the hub read them, by its own clock.
    public let at: Double?
    /// When the owner's Mac that the hub's team names claimed the hub (its install's claim, or a second one), or when
    /// the hub's records were restored, if that is later; nil while the hub has not kept it.
    public let claimed_at: Double?

    public init(ssh_keys_only: Bool?, npm_rule: Bool?, at: Double?, claimed_at: Double?) {
        self.ssh_keys_only = ssh_keys_only; self.npm_rule = npm_rule; self.at = at; self.claimed_at = claimed_at
    }

    private enum Keys: String, CodingKey { case ssh_keys_only, npm_rule, at, claimed_at }
    public init(from decoder: Decoder) throws {
        let keys = try? decoder.container(keyedBy: Keys.self)
        func fact(_ key: Keys) -> Bool? { (try? keys?.decodeIfPresent(Bool.self, forKey: key)).flatMap { $0 } }
        func time(_ key: Keys) -> Double? {
            (try? keys?.decodeIfPresent(Double.self, forKey: key)).flatMap { $0 }.flatMap { $0.isFinite ? $0 : nil }
        }
        self.init(ssh_keys_only: fact(.ssh_keys_only), npm_rule: fact(.npm_rule), at: time(.at),
                  claimed_at: time(.claimed_at))
    }

    /// Read in the last ten minutes, as a server's reading counts (`ServerReading.isCurrent`).
    public func isCurrent(at time: Double) -> Bool {
        guard let at else { return false }
        return time - at >= -5 && time - at < 600
    }
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
        return String(l10n: "\(words(min(max(used, 0), total))) of \(words(total)) \(units[unit]) used")
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
        /// The join's hardening (`hubsetup.py harden`), as the server reads it: SSH takes keys only, and npm holds back
        /// a package version newer than seven days. nil when it cannot say (no OpenSSH, no npm) and from a helper
        /// before 3 November 2026. `ServerHardening` reads them.
        public let ssh_keys_only: Bool?
        public let npm_rule: Bool?
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
    /// **The rows of the install of an agent on a key or a model server** (owner API 1.186), in the order that the
    /// server's service runs them: user, checkout, runtime, service, with no sign-in. nil for every other job, which
    /// keeps its rows, and from a hub before it.
    public let steps: [String]?
    /// The AI that the owner picked for such an agent (Gemini, Grok, OpenCode Go, OpenRouter, Ollama Cloud, or Model
    /// server), which the app names in the place of the program (his answer 12 of 14 November 2026). nil otherwise.
    public let provider_label: String?
    /// The stable name of `detail`'s words for such an install's four lines that name its AI (`install_looking`,
    /// `install_installing`, `install_offline`, `install_failed`), and the names that fill them (`provider`,
    /// `server`): the app shows its own string in the device's language (`shownDetail`).
    public let code: String?
    public let names: [String: String]?
    /// `"none"` on every job of an agent on a key or a model server (owner API 1.186, as `GET /server/<name>/jobs` has
    /// it): it has no sign-in. nil on every other job, and from a hub before it.
    public let sign_in: String?

    private enum CodingKeys: String, CodingKey {
        case id, kind, agent, runtime, state, step, detail, prompt, created, updated, timed_out, steps, provider_label, code,
             names, sign_in
    }

    /// The fields of before as before; **the five of the AI providers build each read apart** (review M12): one of
    /// another type from a later hub is nil, and never costs the read of the servers.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int.self, forKey: .id); kind = try values.decode(String.self, forKey: .kind)
        agent = try values.decodeIfPresent(String.self, forKey: .agent)
        runtime = try values.decodeIfPresent(String.self, forKey: .runtime)
        state = try values.decode(String.self, forKey: .state); step = try values.decodeIfPresent(String.self, forKey: .step)
        detail = try values.decodeIfPresent(String.self, forKey: .detail)
        prompt = try values.decodeIfPresent(Prompt.self, forKey: .prompt)
        created = try values.decode(Double.self, forKey: .created); updated = try values.decode(Double.self, forKey: .updated)
        timed_out = try values.decodeIfPresent(Bool.self, forKey: .timed_out)
        steps = (try? values.decodeIfPresent([String].self, forKey: .steps)) ?? nil
        provider_label = (try? values.decodeIfPresent(String.self, forKey: .provider_label)) ?? nil
        code = (try? values.decodeIfPresent(String.self, forKey: .code)) ?? nil
        names = (try? values.decodeIfPresent([String: String].self, forKey: .names)) ?? nil
        sign_in = (try? values.decodeIfPresent(String.self, forKey: .sign_in)) ?? nil
    }

    /// The install of an agent on a key or on a model server.
    public var hasNoSignIn: Bool {
        sign_in == "none" || (kind == "install" && steps.map { !$0.contains("sign_in") } == true)
    }

    /// **The job's detail in the app's own words** where its code says which line it is, else as the hub gave it.
    public var shownDetail: String? {
        guard let code, let words = Servers.installLine(code, names: names ?? [:]) else { return detail }
        return words
    }

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

/// The answer of `POST /ui/team/accounts`: the account and the version of team.json after the write.
public struct ModelAccountReceipt: Decodable, Sendable {
    public let account: String
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
            return String(l10n: "Use 2 to 31 characters: a-z, 0-9 and -, starting with a letter.")
        }
        return taken.contains(name) ? String(l10n: "A server has this name.") : nil
    }

    /// What stops a new agent on a server, in words.
    public static func reason(_ code: String) -> String {
        switch code {
        case "hub_machine": return String(l10n: "It is the hub's server.")
        // Since a server takes a second agent (hub of 3 November 2026), this says that its Founderizer is older than the
        // hub's and cannot install one yet; it updates itself.
        case "has_agent": return String(l10n: "It takes another agent once Founderizer there is updated.")
        case "no_service": return String(l10n: "It did not join with a join line, so it has no server service.")
        case "no_reading": return String(l10n: "Its server service sent no reading yet.")
        case "offline": return String(l10n: "Its server service sent no reading in the last 10 minutes.")
        // An install or a deleted agent's removal: one job at a time.
        case "busy": return String(l10n: "It works on an agent now.")
        case "fix_holder": return String(l10n: "An agent there has full control of it.")
        // The agent there holds servers through the door, which knows it by its server's address.
        case "door_caller": return String(l10n: "The agent there manages your servers, so it runs alone.")
        default: return String(l10n: "It cannot take an agent now.")
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
            case "needs_owner": return (String(l10n: "Sign-in needed"), true)
            case "queued", "running": return (String(l10n: "Installing \(agent)…"), false)
            case "failed" where server.agents.contains(job.agent ?? ""): return (String(l10n: "Install of \(agent) failed"), true)
            default: break
            }
        }
        // **A deleted agent's removal** (the owner's yes of 7 November 2026 to Delete…): the agent is gone from the
        // fleet, so a removal that stopped is the server's to show, with Try again on its page.
        if let job = server.job, job.kind == "remove", let agent = job.agent?.agentLabel {
            switch job.state {
            case "queued", "running": return (String(l10n: "Removing \(agent)…"), false)
            case "failed": return (String(l10n: "Removal of \(agent) failed"), true)
            default: break
            }
        }
        // A failed preparation changes nothing for the agent: its Change provider shows it, with Try again.
        if let job = server.job, job.kind == "prepare", let agent = job.agent?.agentLabel {
            switch job.state {
            case "needs_owner": return (String(l10n: "Sign-in needed"), true)
            case "queued", "running": return (String(l10n: "Preparing \(providerName(job.runtime ?? "")) for \(agent)…"), false)
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
            return (String(l10n: "Not answering"), true)
        }
        // **No "Free"** (the owner, 3 November 2026: "this is confusing, since we allow multiple agents per server"): a
        // server with agents takes one more, so room for an agent is no news on any row; the row names its agents.
        if let reading = server.reading, reading.isCurrent(at: time), reading.current == false {
            return (Self.updateAvailable, false)
        }
        return (Self.connected, false)
    }

    /// The state of a server on a reading that the hub has not confirmed since: unknown.
    public static let lastReading = String(l10n: "Last reading")

    /// The state of a server that is well, which its card shows as no mark at all (`Servers.mark`).
    public static let connected = String(l10n: "Connected")
    /// The words of a server whose Fleet is older than the hub's, which `mark` compares as `connected` is compared.
    public static let updateAvailable = String(l10n: "Update available")

    /// **The hub's label of the AI that the owner picked, in the app's own words**: "Model server" is a word of the
    /// app (Spanish too); the providers' names are names.
    public static func providerLabel(_ label: String) -> String {
        label == "Model server" ? ModelProvider.own.label : label
    }

    /// The words of a job: its step, then its own detail.
    public static func jobWords(_ job: ServerJob) -> String {
        let agent = job.agent?.agentLabel ?? String(l10n: "The agent")
        let prepare = job.kind == "prepare", provider = job.provider_label.map(providerLabel) ?? providerName(job.runtime ?? "")
        if job.kind == "remove" { return removalWords(job, agent: agent) }
        switch job.state {
        case "queued": return prepare ? String(l10n: "The server starts to prepare \(provider) in a few seconds.") :
            String(l10n: "The server starts the install of \(agent) in a few seconds.")
        case "done": return job.detail ?? (prepare ? String(l10n: "\(provider) is ready for \(agent).") : String(l10n: "\(agent) runs on its server."))
        case "canceled": return prepare ? String(l10n: "The preparation of \(provider) ended: the server left Founderizer.")
            : String(l10n: "The install of \(agent) ended: the server left Founderizer.")
        default: break
        }
        if let detail = job.shownDetail, !detail.isEmpty { return detail }
        switch job.step {
        case "user": return String(l10n: "The OS user of \(agent) on the server.")
        case "runtime": return prepare ? String(l10n: "\(provider) on the server.") : String(l10n: "The provider of \(agent).")
        case "checkout": return String(l10n: "The checkout of \(agent).")
        case "service": return String(l10n: "The service of \(agent).")
        case "sign_in": return String(l10n: "The sign-in of \(prepare ? provider : agent).")
        default: return prepare ? String(l10n: "The preparation of \(provider).") : String(l10n: "The install of \(agent).")
        }
    }

    /// The words of a deleted agent's removal: its step, then its own detail.
    private static func removalWords(_ job: ServerJob, agent: String) -> String {
        switch job.state {
        case "queued": return String(l10n: "The server starts to remove \(agent) in a few seconds.")
        case "done": return job.detail ?? String(l10n: "\(agent) is removed from its server.")
        case "canceled": return String(l10n: "The removal of \(agent) ended: the server left Founderizer.")
        default: break
        }
        if let detail = job.detail, !detail.isEmpty { return detail }
        switch job.step {
        case "service": return String(l10n: "The service of \(agent).")
        case "files": return String(l10n: "The files of \(agent).")
        case "user": return String(l10n: "The OS user of \(agent) on the server.")
        default: return String(l10n: "The removal of \(agent).")
        }
    }

    /// The steps of an install, in order, with the title of each. The first one is the agent's own OS user, which
    /// a Linux server makes before it installs anything, so that no agent's home is readable by another agent's
    /// user (PRODUCT.md P2).
    public static let installSteps: [(id: String, title: String)] = [
        ("user", String(l10n: "User")), ("runtime", String(l10n: "AI provider")), ("checkout", String(l10n: "Checkout")),
        ("service", String(l10n: "Service")), ("sign_in", String(l10n: "Sign-in")),
    ]
    /// The steps of a preparation: the install's provider and sign-in. The agent's checkout and service stay.
    public static let prepareSteps: [(id: String, title: String)] = [("runtime", String(l10n: "AI provider")), ("sign_in", String(l10n: "Sign-in"))]
    /// The steps of a deleted agent's removal: its service stops, its files go, then its own OS user, which only a
    /// Linux server has.
    public static let removeSteps: [(id: String, title: String)] = [
        ("service", String(l10n: "Its service")), ("files", String(l10n: "Its files")), ("user", String(l10n: "Its account")),
    ]

    /// **The steps of the install of an agent on a key or a model server** (picture 10, his "Yes, as shown"): its
    /// program comes from Founderizer's own copy, which needs the agent's folder first, and it has no sign-in.
    public static let accountInstallSteps: [(id: String, title: String)] = [
        ("user", String(l10n: "User")), ("checkout", String(l10n: "Checkout")), ("runtime", String(l10n: "AI provider")),
        ("service", String(l10n: "Service")),
    ]

    /// **The four lines of the install of an agent on a key or a model server that name its AI** (owner API 1.186:
    /// lane C's lines, with the provider that the owner picked, his answer 12), by their code; nil for another code.
    public static func installLine(_ code: String, names: [String: String]) -> String? {
        let provider = names["provider"].map(providerLabel) ?? "", server = names["server"] ?? ""
        switch code {
        case "install_looking": return String(l10n: "Looking for \(provider).")
        case "install_installing": return String(l10n: "Installing \(provider).")
        case "install_offline": return String(l10n: "\(provider) did not install: \(server) could not reach the internet. Try again when it can.")
        case "install_failed": return String(l10n: "\(provider) did not install. Try again.")
        default: return nil
        }
    }

    /// The steps of this job, in order. A Mac makes no user of its own for an agent — its agents are one Mac user's
    /// LaunchAgents — so that step is not among a Mac install's, and the screen does not mark it as done.
    public static func steps(_ job: ServerJob, onMac: Bool = false) -> [(id: String, title: String)] {
        if job.kind == "prepare" { return prepareSteps }
        // An install or a rename of such an agent (review M8): item 10's rows, with no Sign-in row.
        if job.hasNoSignIn, job.kind == "install" || job.kind == "rename" {
            // The hub's own order of the rows, each with its title here; without `steps`, the order of picture 10.
            let titles = Dictionary(uniqueKeysWithValues: accountInstallSteps.map { ($0.id, $0.title) })
            let rows = job.steps.map { ids in ids.compactMap { id in titles[id].map { (id: id, title: $0) } } } ?? accountInstallSteps
            return onMac ? rows.filter { $0.id != "user" } : rows
        }
        let steps = job.kind == "remove" ? removeSteps : installSteps
        return onMac ? steps.filter { $0.id != "user" } : steps
    }

    /// A provider on a server in a few words: not installed, its version and sign-in.
    public static func providerWords(_ runtime: ServerReading.Runtime?) -> String {
        guard let runtime, let version = runtime.version, !version.isEmpty else { return String(l10n: "Not installed") }
        switch runtime.signed_in {
        case true?: return String(l10n: "\(version) · Signed in")
        case false?: return String(l10n: "\(version) · Not signed in")
        case nil: return String(l10n: "\(version) · Sign-in not reported")
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
        value.map { $0 ? String(l10n: "On") : String(l10n: "Off") } ?? String(l10n: "Not reported")
    }

    /// What is off, by name: "Private network, Firewall off".
    public static func offWords(_ names: [String]) -> String { String(l10n: "\(names.joined(separator: ", ")) off") }

    /// The same for the parts of a Security row that are not on, where security updates that stopped are said as
    /// what they are: "Firewall off, Security updates stalled".
    public static func offWords(_ parts: [(name: String, on: Bool?, words: String)]) -> String {
        let off = parts.filter { $0.on == false }
        let plain = off.filter { $0.words != stalled }.map(\.name)
        return ((plain.isEmpty ? [] : [offWords(plain)]) + off.filter { $0.words == stalled }.map { String(l10n: "\($0.name) stalled") })
            .joined(separator: ", ")
    }

    /// The words of automatic security updates that have not ended well for `updatesStalled` seconds, which the hub
    /// also tells the manager of (`server_watch_sweep`).
    public static let stalled = String(l10n: "Stalled")
    public static let updatesStalled: Double = 3 * 86400

    /// How old a reading is, in a few words.
    public static func age(_ at: Double, now: Double) -> String {
        let seconds = max(0, now - at)
        // One of a unit is said in the singular (fix round 3, item 33: "1 seconds ago").
        if seconds < 90 {
            let count = Int(seconds)
            return count == 1 ? String(l10n: "1 second ago") : String(l10n: "\(count) seconds ago")
        }
        if seconds < 5400 {
            let count = Int(seconds / 60)
            return count == 1 ? String(l10n: "1 minute ago") : String(l10n: "\(count) minutes ago")
        }
        if seconds < 172_800 {
            let count = Int(seconds / 3600)
            return count == 1 ? String(l10n: "1 hour ago") : String(l10n: "\(count) hours ago")
        }
        let days = Int(seconds / 86_400)
        return days == 1 ? String(l10n: "1 day ago") : String(l10n: "\(days) days ago")
    }

    /// Why Add agent cannot go now, or nil. The hub checks everything again.
    public static func agentProblem(name: String, server: ServerEntry?, existing: [String]) -> String? {
        guard let server else { return String(l10n: "Select a server.") }
        // The server he picked can no longer take one: why, in the words of its own row.
        guard server.available else { return server.why.first.map(reason) ?? String(l10n: "It cannot take an agent now.") }
        return agentNameProblem(name: name, existing: existing)
    }

    /// **Why the name on Add agent's first step cannot go**, or nil: that step comes before the server (the owner, 16
    /// November 2026: "agent onboarding should ask first for the name and AI provider before the server page").
    public static func agentNameProblem(name: String, existing: [String]) -> String? {
        guard name.range(of: AgentPlacement.namePattern, options: .regularExpression) != nil, name != "owner" else {
            return String(l10n: "Use a name of 2 to 31 characters: a-z, 0-9 and -, starting with a letter.")
        }
        return existing.contains(name) ? String(l10n: "An agent with this name exists.") : nil
    }

    /// **The servers of Add agent's server step**, for the AI that he chose on the step before it, in the order of
    /// `open`: every server that can take one more agent, for an AI on a plan; only a Linux server that takes an agent
    /// on a key or a model server, for Other models (`onAccount`); and only such a server with no agent yet, for his own
    /// model server at a loopback address with no key, which only an agent alone on its server may reach (`alone`).
    public static func offered(_ open: [ServerEntry], onAccount: Bool, alone: Bool) -> [ServerEntry] {
        open.filter { (!onAccount || $0.takesModelAccounts) && (!alone || $0.agents.isEmpty) }
    }
}

// MARK: The cards of the Servers list

extension Servers {
    /// **The one mark at the end of a server's card** (the owner's yes of 13 November 2026 to the clean Servers page,
    /// and his answer "Nothing" for a server that is well): nil while the server is connected, so a well server has no
    /// mark; else one mark for the kind of its state, whose words are its hover text and its accessibility label.
    public enum Mark: Equatable, Sendable {
        /// The hub has a newer Fleet for the server. Muted: nothing is wrong.
        case update
        /// A job runs on the server: an install, a removal or a preparation.
        case working
        /// The server needs the owner, or a job of it failed, or it does not answer. Orange.
        case attention
        /// The last reading of a hub that does not answer, or a state with no mark of its own. Muted.
        case unknown
    }

    /// The mark of a state of `state(_:helpers:time:fresh:)`.
    public static func mark(_ state: (words: String, attention: Bool)) -> Mark? {
        // **The named words, never English text** (the words go through the Spanish table since 13 November 2026).
        if state.words == connected { return nil }
        if state.attention { return .attention }
        if state.words == updateAvailable { return .update }
        if state.words != lastReading, state.words.hasSuffix("…") { return .working }
        return .unknown
    }
}

/// **The columns of the server cards** (the owner's choice C1 of 13 November 2026: a card for each server, its CPU,
/// memory and disk in columns whose heads stand once over the cards, and each agent on one line with its role, the
/// provider's logo in one column, its account and a bar for each window). Every card takes the same columns, so that a
/// column stands at one place in every card, and the view draws each line from these widths.
///
/// **Wide** while the account has room beside the role: the account's column holds the server's CPU, memory and disk on
/// the server's line, the windows' heads stand once over the cards, and the account's column is as wide as its widest
/// address and no wider, so that the bars stand beside the accounts and the room that is left goes before the mark at
/// the line's end (a render at 1,180 points put 600 points between them); with less room, the role and the account
/// take their least. Else **compact**: the account goes behind the provider's logo (its words on hover), each cell
/// names its own window, the role takes the room that is left, the server's figures stand at the end of its line, and
/// the bars go before the role is cut. No column is cut to a few letters (T-17: "fo", "v", "s" at 960 pt).
public struct ServerCardLayout: Equatable, Sendable {
    public enum Mode: Equatable, Sendable { case wide, compact }

    /// The fixed parts of the lines, in points. The view measures the words; the rest are the app's sizes.
    public struct Parts: Equatable, Sendable {
        public var tile = 34.0, glyph = 16.0, logo = 14.0, mark = 22.0
        public var gap = 12.0, small = 6.0, logoGap = 8.0
        public var meter = 44.0, meterGap = 8.0
        /// "100%" in the cells' figures.
        public var percent: Double
        /// The widest name of a window, for a compact cell ("7 d").
        public var label: Double
        /// CPU, Memory and Disk with the gaps between them.
        public var figures: Double
        /// The least that an account shows: eight characters.
        public var accountLeast: Double
        public var roleLeast = 96.0

        public init(percent: Double, label: Double, figures: Double, accountLeast: Double) {
            self.percent = percent; self.label = label; self.figures = figures; self.accountLeast = accountLeast
        }

        /// The line's start before the role: the room of the server's mark, the gap, the agent's glyph and its gap.
        public var beforeRole: Double { tile + gap + glyph + small }
        /// From the role's end to the account: the gap, the provider's logo and its gap.
        public var roleToAccount: Double { gap + logo + logoGap }
        /// The end of a line after the cells: the gap and the mark's column.
        public var end: Double { gap + mark }

        /// All the cells of a line, with the gap before them; nothing without a window.
        public func cells(_ windows: Int, cell: Double) -> Double {
            windows == 0 ? 0 : gap + Double(windows) * cell + Double(windows - 1) * gap
        }
        /// A cell of a wide line: the bar and the share.
        public var wideCell: Double { meter + meterGap + percent }
        /// A cell of a compact line: the window's name, the bar where it fits, and the share.
        public func compactCell(meters: Bool) -> Double { label + small + (meters ? meter + meterGap : 0) + percent }
    }

    public let mode: Mode
    /// The role's column of a wide line; nil on a compact one, where the role takes what is left.
    public let role: Double?
    /// The account's column of a wide line, which holds the server's figures on its line; nil on a compact one.
    public let account: Double?
    /// The cells draw their bars.
    public let meters: Bool

    /// **The layouts to try, the widest first**, for roles of at most `role` points and accounts of at most `account`:
    /// the view draws the first whose lines fit the page (`ViewThatFits`), and the last where none fits, whose role then
    /// gives way to "…". The width is the page's own: a view that measured the cards kept a wide layout wide, because
    /// lines of fixed columns made the cards as wide as their columns (670 points on a page of 420, 13 November 2026).
    public static func candidates(role: Double, account: Double, parts: Parts) -> [ServerCardLayout] {
        let least = max(parts.figures, parts.accountLeast)
        var list = [ServerCardLayout(mode: .wide, role: role, account: max(account, least), meters: true)]
        if role > parts.roleLeast || account > least {
            list.append(ServerCardLayout(mode: .wide, role: min(role, parts.roleLeast), account: least, meters: true))
        }
        return list + [ServerCardLayout(mode: .compact, role: nil, account: nil, meters: true),
                       ServerCardLayout(mode: .compact, role: nil, account: nil, meters: false)]
    }
}
