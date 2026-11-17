import Foundation

/// The bundled installer's one kind of run (`onboard.py run`, executor 2.0.0): the runtime change of one existing agent
/// (`prepare_runtime`, executor 1.3.0) on the machine that this Mac set up, before an explicit provider switch. The
/// hub's generation and the agent's machine bind the run. A retry is the same command, which continues its own saved
/// run. Executor 2.0.0 removed the run of a new server and the run of an agent on an existing machine: no hub lets
/// either finish, and the app started neither.
public struct ServerConfiguration: Codable, Sendable {
    public var runtime = "codex"
    public var auth = "agent"
    public var hub = HubClient.defaultAddress
    /// The agent whose other runtime this run installs and signs in.
    public var prepareRuntime: String?
    public var generation: String?
    public var machine: String?
    public init() {}

    public func validate() throws {
        func matches(_ value: String, _ pattern: String) -> Bool {
            value.range(of: pattern, options: .regularExpression) != nil
        }
        guard let prepareRuntime, matches(prepareRuntime, "^[a-z][a-z0-9_-]{0,63}$"), ["codex", "claude"].contains(runtime),
              auth == "agent", let generation, matches(generation, "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"),
              let machine, matches(machine, AgentPlacement.machinePattern) else { throw SetupError.invalidConfiguration }
        _ = try HubClient.address(hub)
    }
    public var arguments: [String] {
        let hubURL = try! HubClient.address(hub)
        var gitURL = URLComponents()
        // The agreed command names the hub's repository, as a hub made before the name founderizer serves it; no step
        // of a preparation reads it (onboard.py `prepare_main`).
        gitURL.scheme = "git"; gitURL.host = hubURL.host; gitURL.path = "/fleet-pilot.git"
        var values = ["run", "--json", "--auth", auth, "--hub", hubURL.absoluteString, "--repo", gitURL.url!.absoluteString]
        if let prepareRuntime, let generation, let machine {
            values += ["--prepare-runtime", prepareRuntime, "--runtime", runtime, "--generation", generation, "--machine", machine]
        }
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
    public let summary: String?

    /// What a preparation asks the owner for: the Codex sign-in link and its code (`open_url`), or the one command for
    /// Claude's first sign-in (`terminal`).
    public struct PromptData: Codable, Equatable, Sendable {
        public let url: String?
        public let code: String?
        public let purpose: String?
        public let command: String?
    }

    public var loginURL: URL? {
        guard kind == "open_url", let data, let raw = data.url, let url = URL(string: raw),
              url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              let host = url.host?.lowercased() else { return nil }
        let allowed: [String: Set<String>] = ["codex_login": ["auth.openai.com"]]
        return allowed[data.purpose ?? ""]?.contains(host) == true ? url : nil
    }

    /// Whether an owner answer fits this pending prompt. The setup service sends only such an answer to the executor.
    public func accepts(_ answer: Any) -> Bool {
        switch kind {
        case "open_url": return loginURL != nil && answer as? String == "opened"
        case "terminal": return terminalCommand != nil && answer as? String == "copied"
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
            guard event.id != nil, event.data != nil, ["open_url", "terminal"].contains(event.kind ?? "") else {
                throw SetupError.invalidEvent
            }
            prompt = event; signIn = nil
        case "result":
            guard ["ok", "failed", "needs_owner"].contains(event.status ?? "") else { throw SetupError.invalidEvent }
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
