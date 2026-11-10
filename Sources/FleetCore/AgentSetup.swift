import Foundation

public struct ScreenSettingsInput: Codable, Equatable, Sendable {
    public var model: String?
    public var effort: String?
    public init(model: String? = nil, effort: String? = nil) { self.model = model; self.effort = effort }
    public var isValid: Bool { AgentSettingsInput(model: model, effort: effort, can: []).isValid }
    enum CodingKeys: String, CodingKey { case model, effort }
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        for key in [CodingKeys.model, .effort] where !fields.contains(key) {
            throw DecodingError.keyNotFound(key, .init(codingPath: decoder.codingPath, debugDescription: "Screen settings require model and effort."))
        }
        model = try fields.decodeIfPresent(String.self, forKey: .model)
        effort = try fields.decodeIfPresent(String.self, forKey: .effort)
    }
    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(model, forKey: .model); try fields.encode(effort, forKey: .effort)
    }
}

public struct AgentSettingsInput: Codable, Equatable, Sendable {
    public var model: String?
    public var effort: String?
    public var can: [String]
    public var screen: ScreenSettingsInput?
    public static let capabilities = ["shell", "web", "browser", "screen"]
    public init(model: String? = nil, effort: String? = nil, can: [String], screen: ScreenSettingsInput? = nil) {
        self.model = model; self.effort = effort; self.can = can; self.screen = screen
    }
    public var isValid: Bool {
        model.map { $0.range(of: "^[A-Za-z0-9._:/\\[\\]-]{1,120}$", options: .regularExpression) != nil } != false &&
        effort.map { $0.range(of: "^[a-z]{1,20}$", options: .regularExpression) != nil } != false &&
        Set(can).count == can.count && Set(can).isSubset(of: Set(Self.capabilities)) && screen?.isValid != false
    }
    public var normalized: Self { Self(model: model, effort: effort, can: Self.capabilities.filter(can.contains), screen: screen) }
    /// An older draft or client omits screen settings. Preserve the saved screen choice in that case.
    public func changes(from saved: Self) -> Self {
        var result = normalized
        if result.screen == saved.screen { result.screen = nil }
        return result
    }
    public func differs(from saved: Self) -> Bool {
        model != saved.model || effort != saved.effort || normalized.can != saved.normalized.can ||
            (screen != nil && screen != saved.screen)
    }
    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(model, forKey: .model); try fields.encode(effort, forKey: .effort)
        try fields.encode(can, forKey: .can)
        try fields.encodeIfPresent(screen, forKey: .screen)
    }
    public func payload() throws -> String {
        guard isValid else { throw HubError.invalidResponse }
        return String(decoding: try JSONEncoder().encode(normalized), as: UTF8.self)
    }
}

/// One change on an agent's Settings tab, where each control saves itself: one field and its new value. A save sends it
/// against the newest team.json, with every other value as that version has it. The model and its reasoning are one
/// field, so they are sent together.
public enum AgentSettingEdit: Equatable, Sendable {
    case role(String)
    case reportsTo(String?)
    case model(String?, effort: String?)
    case capabilities([String])
    /// The model and reasoning of desktop tasks (`screen_model`).
    case screen(ScreenSettingsInput)

    public enum Field: Hashable, Sendable { case role, reportsTo, model, capabilities, screen }

    public var field: Field {
        switch self {
        case .role: .role
        case .reportsTo: .reportsTo
        case .model: .model
        case .capabilities: .capabilities
        case .screen: .screen
        }
    }

    /// `line` already has this value: there is nothing to send. `can` stands for the line's capabilities when the hub
    /// gives none.
    public func isSaved(in line: ReportingLine, can: [String]) -> Bool {
        switch self {
        case .role(let role): line.role == role
        case .reportsTo(let parent): line.reports_to == parent
        case .model(let model, let effort): line.model == model && line.effort == effort
        case .capabilities(let list): Set(list) == Set(line.can ?? can)
        case .screen(let screen): line.screen == screen
        }
    }

    /// `field` has another value in `after` than in `before`: another save changed it.
    public static func changed(_ field: Field, from before: ReportingLine, to after: ReportingLine) -> Bool {
        switch field {
        case .role: before.role != after.role
        case .reportsTo: before.reports_to != after.reports_to
        case .model: before.model != after.model || before.effort != after.effort
        case .capabilities: Set(before.can ?? []) != Set(after.can ?? [])
        case .screen: before.screen != after.screen
        }
    }

    /// The command and its payload that save this edit against `team`, with only this field changed. The position goes
    /// with the reporting lines; each other field with the agent's settings, which carry the saved model, reasoning and
    /// capabilities again. Throws the reason in words when the hub would refuse the change.
    public func request(agent: String, team: TeamSnapshot, can: [String]) throws -> (command: OwnerCommand, payload: String) {
        guard let index = team.lines.firstIndex(where: { $0.agent == agent }) else {
            throw SettingProblem(words: "\(agent.agentLabel) is not in the team now.")
        }
        let line = team.lines[index]
        var settings = AgentSettingsInput(model: line.model, effort: line.effort, can: line.can ?? can)
        switch self {
        case .role, .reportsTo:
            var lines = team.lines
            if case .role(let role) = self { lines[index].role = role }
            if case .reportsTo(let parent) = self { lines[index].reports_to = parent }
            let change = TeamLinesInput(lines: lines)
            if let problem = change.problem(against: team, allowsLeads: true) { throw SettingProblem(words: problem) }
            return (.teamLines(sha256: team.sha256), try change.payload())
        case .model(let model, let effort): settings.model = model; settings.effort = effort
        case .capabilities(let list): settings.can = list
        case .screen(let screen): settings.screen = screen
        }
        guard settings.isValid else { throw SettingProblem(words: "The hub does not take this value.") }
        return (.agentSettings(agent: agent, sha256: team.sha256), try settings.payload())
    }
}

/// Why the hub would refuse a setting, in words.
public struct SettingProblem: Error, Equatable, Sendable {
    public let words: String
    public init(words: String) { self.words = words }
}

/// One agent's use of its machine's vault store (shared broker callers). The owner gives it or removes it in Fleet
/// with `POST /ui/team/agents/<agent>` and `vault` alone; `file` (the agent's own vault files) is never set from Fleet.
public enum VaultAccess: String, Codable, Sendable {
    case broker, none
    /// The hub feature of the owner grant interface.
    public static let feature = "vault_access"
}

/// `vault_grant` of a `GET /ui/team` line: whether the hub can give this agent its machine's vault now. The hub makes
/// it; it is null for the fleet manager and for an agent that already has broker access.
public struct VaultGrant: Decodable, Equatable, Sendable {
    public let ready: Bool
    public let missing: [String]
}

/// What the Knowledge & access step shows for the machine vault: the saved access, and one change only when the hub
/// offers it. Every worker or lead with broker access can lose it, also the store's own agent and the last one; the
/// hub keeps the store, so a later grant can give the access back. File mode stays as it is here.
public struct VaultAccessControl: Equatable, Sendable {
    public enum Action: Equatable, Sendable { case grant, revoke }
    public let status: String?
    public let action: Action?
    /// Why a grant is not possible now, in ordinary words, in the hub's order.
    public let reasons: [String]
    /// `role`, `vault` and `grant` come from the agent's team line; `offered`: the hub has `vault_access`; `callers`: the
    /// answer of this machine's broker in a current reading (nil: unknown). Without the feature, or without a readiness
    /// reading, the saved access stays and no vault field is sent.
    public init(role: String?, vault: String?, offered: Bool, grant: VaultGrant?, callers: Bool?) {
        let changeable = offered && ["worker", "lead"].contains(role ?? "")    // the manager's vault is set at installation
        // Grant and revoke come as a pair. An older or silent broker could not give back an access that this removes,
        // so without its explicit callers: true the access stays as it is and the step says why.
        let paired = changeable && callers == true
        let waiting = changeable && !paired && ["broker", "none"].contains(vault ?? "")
        switch vault {
        case "broker": status = "Uses this server's vault."; action = paired ? .revoke : nil
        case "none": status = "No credential access."; action = paired && grant?.ready == true ? .grant : nil
        case "file": status = "Uses its own vault files."; action = nil
        default: status = nil; action = nil
        }
        if waiting {
            reasons = [callers == false ? "This server's vault needs its update before this access can change here."
                                        : "Founderizer has no current answer from this server's vault, so this access cannot change here now."]
        } else {
            reasons = paired && vault == "none" && grant?.ready == false ? (grant?.missing ?? []).map(Self.reason) : []
        }
    }

    /// The hub's `vault_grant.missing` codes as facts. They ask for no permission or sign-in change.
    public static func reason(_ code: String) -> String {
        switch code {
        case "agent_without_key": return "This agent has no agent key yet."
        case "helper_without_broker_callers": return "Founderizer on its server is not updated for a shared vault yet."
        case "no_vault_store": return "Its server has no vault store."
        case "broker_status_unknown": return "Founderizer has no recent vault status from its server."
        case "vault_store_mismatch": return "The server's vault key is not the key that Founderizer recorded for it."
        case "broker_without_callers": return "The server's vault cannot serve more than one agent yet."
        default: return "Founderizer cannot give vault access now."
        }
    }
}

public struct RuntimeModels: Decodable, Sendable {
    public let runtime: String
    public let ok: Bool
    public let read_at: Double
    public let source: String
    public let other_names: Bool
    public let error: String?
    public let options: [Option]
    public struct Option: Decodable, Identifiable, Sendable {
        public let model: String
        public let display_name: String
        public let `default`: Bool
        public let efforts: [String]
        public let default_effort: String?
        public var id: String { model }
    }
    public func isCurrent(at time: Double) -> Bool {
        ok && read_at.isFinite && time - read_at >= -5 && time - read_at <= 86_400
    }
    /// The list of the runtime that an agent runs now (`runtime`, from team.json). A list of another runtime (for
    /// example the one before a switch) or for an unknown runtime offers and checks no choice.
    public func isFor(_ runtime: String?) -> Bool { ok && runtime != nil && self.runtime == runtime }
    public func efforts(for model: String?) -> [String] {
        let option = model.flatMap { name in options.first { $0.model == name } } ??
            (model == nil ? options.first(where: \.default) : nil)
        return option?.efforts ?? (other_names ? options.first?.efforts ?? [] : [])
    }
    public func supports(_ input: AgentSettingsInput, at time: Double) -> Bool {
        guard input.isValid else { return false }
        if input.model == nil && input.effort == nil { return true }
        guard isCurrent(at: time) else { return false }
        if let model = input.model, !options.contains(where: { $0.model == model }),
           !(other_names && runtime == "claude" && model.hasPrefix("claude-")) { return false }
        return input.effort.map { efforts(for: input.model).contains($0) } ?? true
    }
    public func supportsScreen(_ input: ScreenSettingsInput, at time: Double) -> Bool {
        runtime == "codex" && supports(.init(model: input.model, effort: input.effort, can: []), at: time)
    }
    /// The reasoning that goes with a new model: the current one when that model offers it, else the model's default
    /// (nil, the runtime's default for that model).
    public func effort(_ current: String?, with model: String?) -> String? {
        guard let current, efforts(for: model).contains(current) else { return nil }
        return current
    }
}

public struct MachineVerification: Decodable, Sendable {
    public let check: Int
    public let checked_at: Double
    public let revision: String
    /// The hub's own answer (owner API 1.80): its activation takes this check now. It also holds across commits that
    /// change nothing the check saw, such as a task output or another agent's activation, which only the hub can
    /// tell from the git history. Nil for an active agent, and from an older hub.
    public let holds: Bool?
    public let items: [Item]
    public struct Item: Decodable, Identifiable, Sendable {
        public let kind: String
        public let ref: String
        public let state: String
        public let detail: String
        public let required: Bool?
        public var id: String { kind + "/" + ref }
    }
    /// The hub's `holds` decides whether the check is still current; without it, the check must have run at the hub's
    /// revision or at the one its machine runs now.
    public func permitsActivation(machine: MachineStatus, desiredRevision: String?, at time: Double) -> Bool {
        guard machine.isCurrent(at: time), machine.update.state == "current", machine.settings_pending == false,
              machine.check?.id == check, machine.check?.state == "completed",
              holds ?? (revision == desiredRevision || revision == machine.revision),
              checked_at.isFinite, time - checked_at >= -5, time - checked_at <= 3600, !items.isEmpty,
              items.allSatisfy({ $0.required != nil && ($0.required == false || $0.state == "ok") }) else { return false }
        return true
    }
}

public struct ReportedModel: Codable, Equatable, Sendable {
    public let model: String?
    public let effort: String?
    public let at: Double
}

public struct RuntimeModelUse: Equatable, Identifiable, Sendable {
    public let id: Int
    public let attempt: Int
    public let session: String
    public let requestedModel: String?
    public let requestedEffort: String?
    public let model: String?
    public let effort: String?
    init(event: RuntimeEvent) {
        id = event.id; attempt = event.attempt; session = event.session
        requestedModel = event.requested_model; requestedEffort = event.requested_effort
        model = event.model; effort = event.effort
    }
    public var differs: Bool {
        (requestedModel != nil && model != nil && requestedModel != model) ||
        (requestedEffort != nil && effort != nil && requestedEffort != effort)
    }
}

public enum AgentSettingValue: Decodable, Equatable, Sendable {
    case none, flag(Bool), text(String), list([String]), screen(ScreenSettingsInput)
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .none }
        else if let flag = try? value.decode(Bool.self) { self = .flag(flag) }
        else if let text = try? value.decode(String.self) { self = .text(text) }
        else if let screen = try? value.decode(ScreenSettingsInput.self) { self = .screen(screen) }
        else { self = .list(try value.decode([String].self)) }
    }
}
public struct AgentSettingChange: Decodable, Sendable {
    public let field: String
    public let before: AgentSettingValue
    public let after: AgentSettingValue
}
