import Foundation
import Network

public struct MachineList: Decodable, Sendable {
    public let db: String
    public let desired_revision: String?
    public let machines: [MachineStatus]
    public func validate(database: String) throws {
        guard db == database, machines.count <= 1000, Set(machines.map(\.agent)).count == machines.count,
              machines.allSatisfy({ ($0.reported_at == nil || ($0.reported_at!.isFinite && $0.reported_at! > 0)) && $0.check?.isValid != false }) else { throw HubError.invalidResponse }
    }
}

public struct MachineStatus: Decodable, Identifiable, Sendable {
    public let agent: String
    public let machine: String
    public let role: String
    public let address: String?
    public let access: Access?
    public let revision: String?
    public let update: Update
    public let check: MachineCheck?
    public let security: Security
    /// What its server needs, from the agents on it: nil from a hub before `server_ai_choice`.
    public let needs: Needs?
    public struct Needs: Decodable, Sendable { public let browser: Bool; public let chatgpt: Bool }
    public let runtime: Runtime
    public let os: System
    public let reported_at: Double?
    public let stale: Bool?
    public let features: [String]?
    public let models: RuntimeModels?
    public let screen_models: RuntimeModels?
    public let settings: AgentSettingsInput?
    public let settings_pending: Bool?
    public let verify: MachineVerification?
    /// `runtime_switch`: each runtime on this machine (Codex and Claude Code) as its helper reads it.
    public let runtimes: Runtimes?
    /// `machine_signin`: the sign-in the owner is driving for this machine, or nil. The link and the code it shows
    /// are there only while it waits, because the hub keeps them nowhere.
    public let login: MachineLogin?
    /// The CPU and memory of this agent's own sessions, as its helper read them, or nil from a helper before the
    /// load readings (4 November 2026).
    public let use: AgentUse?
    public var id: String { agent }
    /// An entry that cannot be read is left out, and the rest of the reading stays.
    public struct Runtimes: Decodable, Sendable {
        public let byName: [String: Runtime]
        public init(from decoder: Decoder) throws {
            let entries = try? decoder.singleValueContainer().decode([String: Failable<Runtime>].self)
            byName = entries?.compactMapValues(\.value) ?? [:]
        }
    }
    public struct Access: Decodable, Sendable {
        public let ssh: SSH?
        public let screen_sharing: ScreenSharing?
        public struct SSH: Decodable, Sendable { public let user: String; public let port: Int; public let available: Bool? }
        public struct ScreenSharing: Decodable, Sendable { public let available: Bool? }
    }
    public var sshURL: URL? {
        guard let ssh = access?.ssh, (1...65535).contains(ssh.port),
              ssh.user.range(of: "^[A-Za-z_][A-Za-z0-9_.-]{0,63}$", options: .regularExpression) != nil else { return nil }
        return connectionURL(scheme: "ssh", user: ssh.user, port: ssh.port)
    }
    public var screenSharingURL: URL? {
        guard access?.screen_sharing != nil else { return nil }
        return connectionURL(scheme: "vnc")
    }
    public var screenSharingConnection: ScreenSharingConnection? {
        guard screenSharingURL != nil, sshURL != nil, let address, let ssh = access?.ssh else { return nil }
        return ScreenSharingConnection(address: address, user: ssh.user, port: ssh.port)
    }
    private func connectionURL(scheme: String, user: String? = nil, port: Int? = nil) -> URL? {
        guard let address, IPv4Address(address) != nil || IPv6Address(address) != nil else { return nil }
        var parts = URLComponents()
        parts.scheme = scheme; parts.host = address.contains(":") ? "[\(address)]" : address
        parts.user = user; parts.port = port
        return parts.url
    }
    public struct Update: Decodable, Sendable {
        public let state: String?
        public let detail: String?
        public let requested_at: Double?
        public let finished_at: Double?
    }
    public struct Security: Decodable, Sendable {
        public let unattended_upgrades: Bool?
        public let pending_security: Int?
        public let reboot_required: Bool?
        public let firewall: String?
        public let tailscale: Bool?
        public let vault: Vault?
        /// What only hands at a Mac can put right, nil from a Linux server.
        public let desktop: Desktop?
        public struct Desktop: Decodable, Sendable {
            public let locked: Bool?
            public let chrome: Bool?
            public let `extension`: Bool?
            public let browser: Bool?
            /// The sign-in of the ChatGPT app on this Mac, which Computer Use runs through.
            public let chatgpt: Bool?
        }
        public struct Vault: Decodable, Sendable {
            public let mode: String?
            public let isolated: Bool?
            /// Shared broker callers: true when this machine's broker serves several agents, false for an older
            /// broker, null when it did not answer.
            public let callers: Bool?
            /// `login_create`: true when this machine's vault is set up to save new logins, false when not, null
            /// when it did not answer.
            public let creates: Bool?
        }
    }
    public struct Runtime: Decodable, Sendable { public let name: String?; public let version: String?; public let signed_in: Bool? }
    public struct System: Decodable, Sendable { public let name: String?; public let kernel: String? }
    public func isCurrent(at time: Double) -> Bool {
        guard stale != true, let reported_at else { return false }
        return time - reported_at >= -5 && time - reported_at < 600
    }
    public var updatePending: Bool { ["requested", "waiting_idle", "updating"].contains(update.state ?? "") }
    /// This helper runs a revision that is not the fleet's own, and nothing it does by itself will change that: a
    /// helper reports the revision it loaded when it started, so a restart of its service is what moves it.
    public var isBehind: Bool { update.state == "behind" }
    /// Whether the hub's own update route takes this helper: `POST /ui/machines/<agent>/update`, which is the
    /// better way, because the hub can hold the helper's gate and wait for it to be idle.
    ///
    /// It is one function because it is asked in the three places that must never disagree: the machine page's own
    /// button, the Update button a `machine_behind` warning carries on the Health page, and the row that stands in
    /// for them on a machine the hub will not take. One helper then never has two ways to do one thing, and no
    /// screen draws a button the hub refuses. `leads` is the owner's `leads` feature.
    ///
    /// **The manager is in since 19 October 2026** (UI-API 1.2, "Hub routes for machines"). It was out while the
    /// agent on the hub machine shared the hub's own user and checkout; each agent of a Linux machine now has its
    /// own home, its own clone and its own systemd user service, so its kit update needs no root and no owner Mac.
    /// Until then a release left the hub machine behind and the Health page drew an Update button that was refused.
    public func updatesThroughHub(leads: Bool) -> Bool {
        role == "manager" || role == "worker" || (role == "lead" && leads)
    }
    /// The broker's `callers` answer in a current reading; nil (unknown) for a stale reading or no answer.
    public func brokerCallers(at time: Double) -> Bool? { isCurrent(at: time) ? security.vault?.callers : nil }
    /// The vault's `creates` answer in a current reading; nil (unknown) for a stale reading or no answer.
    public func brokerCreates(at time: Double) -> Bool? { isCurrent(at: time) ? security.vault?.creates : nil }
}

/// Only the configured SSH endpoint is variable. The remote desktop target is always loopback:5900.
private struct Failable<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

public struct ScreenSharingConnection: Codable, Hashable, Sendable {
    public let address: String
    public let user: String
    public let port: Int

    public init(address: String, user: String, port: Int) {
        self.address = address; self.user = user; self.port = port
    }

    public var isValid: Bool {
        (IPv4Address(address) != nil || IPv6Address(address) != nil) &&
        user.range(of: "^[A-Za-z_][A-Za-z0-9_.-]{0,63}$", options: .regularExpression) != nil &&
        (1...65535).contains(port)
    }

    public func masterArguments(controlPath: String) -> [String]? {
        guard isValid else { return nil }
        return ["-N", "-n", "-T", "-S", controlPath,
                "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                "-o", "ExitOnForwardFailure=yes", "-o", "ConnectTimeout=10",
                "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2",
                "-o", "PermitLocalCommand=no", "-o", "RemoteCommand=none",
                "-o", "ClearAllForwardings=yes", "-o", "ForwardAgent=no", "-o", "ForwardX11=no",
                "-o", "ControlMaster=yes", "-o", "ControlPersist=no", "-o", "ForkAfterAuthentication=no",
                "-p", String(port), "-l", user, address]
    }

    public func forwardArguments(controlPath: String, localPort: Int) -> [String]? {
        guard isValid, (1024...65535).contains(localPort) else { return nil }
        // The master keeps existing identity/host-trust settings but clears configured forwards.
        // This control request adds exactly one forward and fails if another process owns the port.
        return ["-F", "/dev/null", "-S", controlPath, "-O", "forward",
                "-L", "127.0.0.1:\(localPort):127.0.0.1:5900",
                "-p", String(port), "-l", user, address]
    }
}

public struct MachineCheck: Decodable, Equatable, Sendable {
    public let id: Int
    public let state: String
    public let requested_at: Double
    public let completed_at: Double?
    public let detail: String?
    public var isPending: Bool { state == "requested" }
    public var isValid: Bool {
        id > 0 && requested_at.isFinite && requested_at > 0 &&
            ["requested", "completed", "failed", "offline"].contains(state) &&
            (isPending ? completed_at == nil : completed_at.map { $0.isFinite && $0 >= requested_at } == true)
    }
}

/// **What one agent's own sessions use** (the owner's yes of 4 November 2026: "Each agent's own use"): its helper and the
/// panes of its tmux session, with all they started, as its helper read them. It shows which agent loads a server that
/// several share. A figure that cannot be read is nil, and never loses the machine's reading.
public struct AgentUse: Decodable, Sendable, Equatable {
    /// Its share of the server's processors since the helper's reading before, in percent; nil on a helper's first one.
    public let cpu_percent: Double?
    /// The memory its processes hold, in bytes.
    public let memory: Double?

    public init(cpu_percent: Double?, memory: Double?) { self.cpu_percent = cpu_percent; self.memory = memory }

    private enum Keys: String, CodingKey { case cpu_percent, memory }
    public init(from decoder: Decoder) throws {
        let keys = try? decoder.container(keyedBy: Keys.self)
        func figure(_ key: Keys) -> Double? {
            (try? keys?.decodeIfPresent(Double.self, forKey: key)).flatMap { $0 }.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        }
        self.init(cpu_percent: figure(.cpu_percent), memory: figure(.memory))
    }

    /// Its share of the processors, at most 100.
    public var cpu: Double? { cpu_percent.map { min($0, 100) } }
}
