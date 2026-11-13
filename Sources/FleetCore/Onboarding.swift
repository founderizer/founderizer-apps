import Foundation

public struct ServerConfiguration: Codable, Sendable {
    public var host = ""
    public var port = 22
    public var login = "root"
    public var name = ""
    public var runtime = "codex"
    public var auth = "agent"
    public var hub = HubClient.defaultAddress
    public var identityFile: String?
    public var resume = false
    /// Owner API 1.12: add a new agent to this existing machine. The executor takes host, port and login from the hub.
    public var existingMachine: String?
    /// `prepare_runtime` (executor 1.3.0): install and sign in `runtime` for this existing agent on the machine that this
    /// Mac enrolled, before an explicit provider switch. The hub's generation and the agent's machine bind the run. A
    /// retry is the same command, which continues its own saved run.
    public var prepareRuntime: String?
    public var generation: String?
    public var machine: String?
    public init() {}

    public func validate() throws {
        func matches(_ value: String, _ pattern: String) -> Bool {
            value.range(of: pattern, options: .regularExpression) != nil
        }
        if let prepareRuntime {
            guard matches(prepareRuntime, "^[a-z][a-z0-9_-]{0,63}$"), ["codex", "claude"].contains(runtime), auth == "agent",
                  !resume, existingMachine == nil, identityFile == nil,
                  let generation, matches(generation, "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"),
                  let machine, matches(machine, AgentPlacement.machinePattern) else { throw SetupError.invalidConfiguration }
            _ = try HubClient.address(hub)
            return
        }
        guard matches(name, AgentPlacement.namePattern),
              ["agent", "identity", "password"].contains(auth),
              ["codex", "claude"].contains(runtime) else { throw SetupError.invalidConfiguration }
        if let existingMachine {
            guard matches(existingMachine, AgentPlacement.machinePattern) else { throw SetupError.invalidConfiguration }
        } else {
            guard resume || (matches(host, "^[a-zA-Z0-9][a-zA-Z0-9.:-]{0,252}$") &&
                             matches(login, "^[a-z_][a-z0-9_-]{0,31}$") && (1...65535).contains(port)) else {
                throw SetupError.invalidConfiguration
            }
        }
        _ = try HubClient.address(hub)
        if auth == "identity" && identityFile == nil { throw SetupError.invalidConfiguration }
        if let identityFile {
            guard identityFile.hasPrefix("/"), !identityFile.contains("\0"), identityFile.count <= 4096 else {
                throw SetupError.invalidConfiguration
            }
        }
    }
    public var arguments: [String] {
        let hubURL = try! HubClient.address(hub)
        var gitURL = URLComponents()
        // The repository of a hub made before the name founderizer. The executor clones the one that the hub names
        // itself (onboard.py `Onboarding.repo`), and this one only from a hub that names none.
        gitURL.scheme = "git"; gitURL.host = hubURL.host; gitURL.path = "/fleet-pilot.git"
        var values = ["run", "--json", "--auth", auth, "--hub", hubURL.absoluteString, "--repo", gitURL.url!.absoluteString]
        if let prepareRuntime, let generation, let machine {
            return values + ["--prepare-runtime", prepareRuntime, "--runtime", runtime, "--generation", generation, "--machine", machine]
        }
        if resume { values += ["--resume", name] }
        else if let existingMachine { values += ["--existing-machine", existingMachine, "--name", name, "--runtime", runtime] }
        else { values += ["--host", host, "--port", String(port), "--login", login, "--name", name, "--runtime", runtime] }
        if auth == "identity", let identityFile { values += ["--identity-file", identityFile] }
        return values
    }
}

public enum SetupError: Error, LocalizedError {
    case invalidConfiguration, invalidEvent, unsafeLink
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: String(l10n: "Check the agent name, server address and SSH user.")
        case .invalidEvent: String(l10n: "Setup returned an invalid status. Reconnect before continuing.")
        case .unsafeLink: String(l10n: "This sign-in link is not from a supported provider.")
        }
    }
}

public struct SetupEvent: Codable, Identifiable, Equatable, Sendable {
    public let v: Int
    public let run: String
    public let seq: Int
    public let type: String
    public let id: String?
    public let status: String?
    public let title: String?
    public let detail: String?
    public let kind: String?
    public let data: PromptData?
    public let level: String?
    public let text: String?
    public let machine: Machine?
    /// Owner API 1.12: the agent that an existing-machine run added. It is inactive and has no credential access.
    public let agent: AddedAgent?
    public struct AddedAgent: Codable, Equatable, Sendable {
        public let name: String
        public let machine: String?
        public let runtime: String?
        public let checkout: String?
        public let service: String?
        public let registration_commit: String?
        public let active: Bool?
        public let vault: String?
    }
    public struct Machine: Codable, Equatable, Sendable {
        public let name: String?
        public let host: String?
        public let port: Int?
        public let login: String?
        public let os: String?
        public let runtime: String?
        public let worker_user: String?
        public let tailscale_ip: String?
        public let registration_commit: String?
        public let security: Security?
        public struct Security: Codable, Equatable, Sendable {
            public let pending_security: Int?
            public let reboot_required: Bool?
        }
    }
    public let summary: String?

    public struct PromptData: Codable, Equatable, Sendable {
        public let host: String?
        public let port: Int?
        public let fingerprints: [Fingerprint]?
        public let label: String?
        public let url: String?
        public let code: String?
        public let purpose: String?
        public let question: String?
        public let options: [Option]?
        public let command: String?
    }
    public struct Fingerprint: Codable, Equatable, Sendable { public let algorithm: String; public let sha256: String }
    public struct Option: Codable, Equatable, Sendable { public let value: String; public let label: String }

    public var loginURL: URL? {
        guard kind == "open_url", let data, let raw = data.url, let url = URL(string: raw),
              url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              let host = url.host?.lowercased() else { return nil }
        let allowed: [String: Set<String>] = [
            "tailscale_login": ["login.tailscale.com"],
            "codex_login": ["auth.openai.com"],
            "claude_login": ["claude.ai", "platform.claude.com", "console.anthropic.com"]
        ]
        return allowed[data.purpose ?? ""]?.contains(host) == true ? url : nil
    }

    /// Whether an owner answer fits this pending prompt. The setup service sends only such an answer to the executor;
    /// a secret travels apart from the answer, and only for a secret prompt.
    public func accepts(_ answer: Any, secret: Data?) -> Bool {
        switch kind {
        case "secret":
            guard ["provider_password", "tailscale_auth_key"].contains(data?.label ?? ""), let secret, !secret.isEmpty,
                  secret.count <= 2048, !secret.contains(10), !secret.contains(13), !secret.contains(0) else { return false }
            return answer as? String == "sent"
        case "confirm_host_key": return secret == nil && answer is Bool
        case "open_url": return secret == nil && loginURL != nil && answer as? String == "opened"
        case "choice":
            guard secret == nil, let value = answer as? String else { return false }
            return data?.options?.contains(where: { $0.value == value }) == true
        case "terminal": return secret == nil && terminalCommand != nil && answer as? String == "copied"
        default: return false
        }
    }

    /// `terminal` (executor 1.2.0): the one command that the owner runs in Terminal for Claude's first sign-in, which
    /// Claude documents on a server only in its own terminal screen. The app shows and copies it and never runs it.
    /// One line without control characters that starts with `ssh -F `, or nil.
    public var terminalCommand: String? {
        guard kind == "terminal", data?.purpose == "claude_login", let command = data?.command, command.hasPrefix("ssh -F "),
              command.utf8.count <= 4096, !command.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return command
    }
}

/// `onboard.py version`: the protocol of the bundled executor and, from executor 1.1.0, what it supports.
public struct SetupExecutor: Codable, Equatable, Sendable {
    public let v: Int
    public let type: String
    public let executor: String
    public let capabilities: [String]?
    public var supportsExistingMachine: Bool {
        v == 1 && type == "version" && capabilities?.contains(AgentPlacement.capability) == true
    }
    /// Executor 1.3.0: set up another provider for an existing agent (`--prepare-runtime`).
    public var supportsRuntimePreparation: Bool {
        v == 1 && type == "version" && capabilities?.contains("prepare_runtime") == true
    }
}

public struct SetupTimeline: Sendable {
    public private(set) var run: String?
    public private(set) var sequence = 0
    public private(set) var steps: [SetupEvent] = []
    public private(set) var prompt: SetupEvent?
    public private(set) var signIn: SetupEvent?
    public private(set) var result: SetupEvent?
    public init() {}
    public mutating func append(_ event: SetupEvent) throws {
        guard event.v == 1, !event.run.isEmpty, event.seq == sequence + 1, result == nil,
              run == nil || run == event.run else { throw SetupError.invalidEvent }
        switch event.type {
        case "step":
            guard event.id != nil, ["running", "done", "skipped", "failed"].contains(event.status ?? "") else { throw SetupError.invalidEvent }
            signIn = nil
            if let index = steps.firstIndex(where: { $0.id == event.id }) { steps[index] = event }
            else { steps.append(event) }
        case "prompt":
            guard event.id != nil, event.data != nil,
                  ["confirm_host_key", "secret", "open_url", "choice", "terminal"].contains(event.kind ?? "") else { throw SetupError.invalidEvent }
            prompt = event; signIn = nil
        case "result":
            // The app opens agent setup with this name, so it must be a valid agent name.
            guard ["ok", "failed", "needs_owner"].contains(event.status ?? ""),
                  event.agent.map({ $0.name.range(of: AgentPlacement.namePattern, options: .regularExpression) != nil }) != false
            else { throw SetupError.invalidEvent }
            result = event; prompt = nil; signIn = nil
        case "log": break
        default: throw SetupError.invalidEvent
        }
        run = event.run; sequence = event.seq
    }
    public mutating func answered(_ id: String) {
        guard let prompt, prompt.id == id else { return }
        if prompt.loginURL != nil || prompt.terminalCommand != nil { signIn = prompt }     // shown while the step waits
        self.prompt = nil
    }
}
