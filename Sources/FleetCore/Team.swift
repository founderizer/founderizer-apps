import Foundation

public struct ReportingLine: Codable, Equatable, Identifiable, Sendable {
    public let agent: String
    public var role: String
    public var reports_to: String?
    public var active: Bool?
    public var model: String?
    public var effort: String?
    public var screen: ScreenSettingsInput?
    public var can: [String]?
    public var settings_pending: Bool?
    public var reported_model: ReportedModel?
    public var reported_screen_model: ReportedModel?
    /// Owner API 1.12: "file", "broker" or "none", and (with `vault_access`) whether a grant is possible now. Read only:
    /// a reporting-lines save never sends them.
    public var vault: String?
    public var vault_grant: VaultGrant?
    /// `login_create`: the agent may make new logins with `create_login`, and whether the hub can give that
    /// permission now (null for the fleet manager and for an agent that has it). Read only.
    public var vault_create: Bool?
    public var vault_create_grant: VaultGrant?
    /// `runtime_switch`: whether the hub can switch this agent to its other provider now. Read only.
    public var runtime_switch: RuntimeSwitch?
    public var id: String { agent }
    public init(agent: String, role: String, reports_to: String?) {
        self.agent = agent; self.role = role; self.reports_to = reports_to
    }
    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(agent, forKey: .agent); try fields.encode(role, forKey: .role)
        try fields.encode(reports_to, forKey: .reports_to)
    }
}

public struct TeamLinesInput: Codable, Equatable, Sendable {
    public var lines: [ReportingLine]
    public init(lines: [ReportingLine]) { self.lines = lines }
    public var isValid: Bool { Self.problem(lines) == nil }
    public func payload() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }

    public static func problem(_ lines: [ReportingLine]) -> String? {
        guard !lines.isEmpty, lines.count <= 1000, Set(lines.map(\.agent)).count == lines.count,
              lines.allSatisfy({ $0.agent.range(of: "^[a-z][a-z0-9_-]{0,63}$", options: .regularExpression) != nil })
        else { return String(l10n: "The team contains an invalid or repeated agent.") }
        let managers = lines.filter { $0.role == "manager" }
        guard managers.count == 1, let manager = managers.first, manager.reports_to == nil else { return String(l10n: "The team must have one manager.") }
        let members = Dictionary(uniqueKeysWithValues: lines.map { ($0.agent, $0) })
        for line in lines where line.agent != manager.agent {
            guard ["lead", "worker"].contains(line.role), let parent = line.reports_to,
                  parent != line.agent, let recipient = members[parent], ["manager", "lead"].contains(recipient.role)
            else { return String(l10n: "Each agent must report to the manager or a lead.") }
            var seen: Set<String> = [line.agent]
            var next: String? = parent
            while let name = next, name != manager.agent {
                guard seen.insert(name).inserted, let member = members[name] else { return String(l10n: "Reporting lines cannot form a loop.") }
                next = member.reports_to
            }
            guard next == manager.agent else { return String(l10n: "Each reporting line must reach the manager.") }
        }
        return nil
    }

    public func problem(against original: TeamSnapshot, allowsLeads: Bool) -> String? {
        if let issue = Self.problem(lines) { return issue }
        guard Set(lines.map(\.agent)) == Set(original.lines.map(\.agent)),
              lines.first(where: { $0.role == "manager" })?.agent == original.lines.first(where: { $0.role == "manager" })?.agent
        else { return String(l10n: "Refresh the team before saving.") }
        for line in lines {
            guard let before = original.lines.first(where: { $0.agent == line.agent }) else { return String(l10n: "Refresh the team before saving.") }
            if before.role != line.role {
                if !allowsLeads { return String(l10n: "Update the hub to change agent roles.") }
                if (original.open_tasks[line.agent] ?? 0) > 0 { return String(l10n: "\(line.agent.agentLabel) has open tasks. Change its role when those tasks end.") }
            }
        }
        return nil
    }

    public var tree: [(line: ReportingLine, depth: Int)] {
        guard isValid, let manager = lines.first(where: { $0.role == "manager" }) else { return lines.map { ($0, 0) } }
        let children = Dictionary(grouping: lines.filter { $0.reports_to != nil }, by: { $0.reports_to! })
        var result: [(ReportingLine, Int)] = [], stack = [(manager, 0)]
        while let (line, depth) = stack.popLast() {
            result.append((line, depth))
            stack.append(contentsOf: (children[line.agent] ?? []).reversed().map { ($0, depth + 1) })
        }
        return result
    }
}

public struct TeamSnapshot: Decodable, Sendable {
    public let db: String
    public let revision: String
    public let sha256: String
    public let lines: [ReportingLine]
    public let open_tasks: [String: Int]
    /// The account labels, and the same lines with their identity fields.
    public let accounts: [String: TeamAccount]?
    public let members: [TeamMember]
    /// Owner API 1.12 (`agent_auth`): each machine, for Add agent. An entry that cannot be read never hides the team.
    public let machines: [String: TeamMachine]?
    /// Owner feature `secrets`: the owner's titles of login references, by `bws://<uuid>` in lower case. nil on a hub
    /// without the feature. A catalog that cannot be read never hides the team.
    public let logins: [String: TeamLogin]?
    /// `login_create`: every login that an agent made, newest first. nil on a hub without the feature.
    public let created_logins: [CreatedLogin]?
    /// Owner feature `default_models` (API 1.108): the owner's default model and reasoning of each provider that has
    /// one, for an agent's first option. Empty on a hub without the feature.
    public let default_models: [String: ModelDefault]
    enum CodingKeys: String, CodingKey {
        case db, revision, sha256, lines, open_tasks, accounts, machines, logins, created_logins, default_models
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        db = try values.decode(String.self, forKey: .db); revision = try values.decode(String.self, forKey: .revision)
        sha256 = try values.decode(String.self, forKey: .sha256); lines = try values.decode([ReportingLine].self, forKey: .lines)
        members = try values.decode([TeamMember].self, forKey: .lines)
        open_tasks = try values.decode([String: Int].self, forKey: .open_tasks)
        accounts = try values.decodeIfPresent([String: TeamAccount].self, forKey: .accounts)
        machines = (try? values.decodeIfPresent([String: TeamMachine].self, forKey: .machines)) ?? nil
        logins = (try? values.decodeIfPresent([String: TeamLogin].self, forKey: .logins)) ?? nil
        created_logins = (try? values.decodeIfPresent([CreatedLogin].self, forKey: .created_logins)) ?? nil
        default_models = ((try? values.decodeIfPresent([String: ModelDefault].self, forKey: .default_models)) ?? nil) ?? [:]
    }
    public func validate(database: String) throws {
        guard db == database, revision.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
              sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              TeamLinesInput(lines: lines).isValid, accountsAreValid(),
              open_tasks.values.allSatisfy({ $0 >= 0 }) else { throw HubError.invalidResponse }
        guard Set(open_tasks.keys).isSubset(of: Set(lines.map(\.agent))) else { throw HubError.invalidResponse }
    }
}

public struct ReportingChange: Decodable, Sendable {
    public struct Position: Decodable, Sendable {
        public let role: String
        public let reports_to: String?
    }
    public let agent: String
    public let before: Position
    public let after: Position
}

public enum ReceiptChanges: Decodable, Sendable {
    case flag(Bool), lines([ReportingChange]), settings([AgentSettingChange])
    public init(from decoder: Decoder) throws {
        let field = try decoder.singleValueContainer()
        if let value = try? field.decode(Bool.self) { self = .flag(value) }
        else if let lines = try? field.decode([ReportingChange].self) { self = .lines(lines) }
        else { self = .settings(try field.decode([AgentSettingChange].self)) }
    }
    public var flag: Bool? { if case .flag(let value) = self { value } else { nil } }
    public var settingChanges: [AgentSettingChange]? {
        switch self {
        case .settings(let values): values
        case .lines(let values) where values.isEmpty: []
        default: nil
        }
    }
}
