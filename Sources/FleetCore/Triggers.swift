import Foundation
import CryptoKit

public enum CheckArgument: Codable, Equatable, Sendable {
    case null, bool(Bool), integer(Int64), number(Double), string(String), array([CheckArgument]), object([String: CheckArgument])
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let item = try? value.decode(Bool.self) { self = .bool(item) }
        else if let item = try? value.decode(Int64.self) { self = .integer(item) }
        else if let item = try? value.decode(Double.self), item.isFinite { self = .number(item) }
        else if let item = try? value.decode(String.self) { self = .string(item) }
        else if let item = try? value.decode([CheckArgument].self) { self = .array(item) }
        else { self = .object(try value.decode([String: CheckArgument].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let item): try value.encode(item)
        case .integer(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .string(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .object(let item): try value.encode(item)
        }
    }
}

/// A trigger's check: a repository file that the owner pinned (owner API 1.8), or code that an agent saved, which the hub
/// keeps by its SHA-256 (owner corrections, 10 October 2026). A saved check has empty `path` and `commit`.
///
/// A check of a newer form (plan P4, `"form": "lines"`) prints the items that need the agent, one line each, so it has
/// no `condition` and no `repeat_minutes`. It reads like any other check: the page shows the rule, never its condition.
public struct TriggerCheck: Codable, Equatable, Sendable {
    public var path: String
    public var commit: String
    public var sha256: String
    public var args: [String: CheckArgument]
    public var timeout_seconds: Int
    /// nil for the value form, which compares the printed value with `condition`.
    public var form: String?
    public var condition: Condition?
    public var repeat_minutes: Int?
    public var code: String?
    public var bytes: Int?
    public var code_by: String?
    public var run_on: String?
    /// The hub's approval of this exact saved revision: who approved it, in which code prompt. Read only: only the hub
    /// creates one, so the app never sends it back.
    public var approval: CodeApproval?
    public struct CodeApproval: Codable, Equatable, Sendable {
        public let prompt: Int
        public let approver: String
    }
    public struct Condition: Codable, Equatable, Sendable {
        public var op: String
        public var value: Double
        public init(op: String, value: Double) { self.op = op; self.value = value }
    }
    public init(path: String, commit: String, sha256: String, args: [String: CheckArgument], timeout_seconds: Int = 30,
                condition: Condition?, repeat_minutes: Int?) {
        self.path = path; self.commit = commit; self.sha256 = sha256; self.args = args
        self.timeout_seconds = timeout_seconds; self.condition = condition; self.repeat_minutes = repeat_minutes
    }
    public var isSaved: Bool { code == "saved" }
    enum CodingKeys: String, CodingKey { case path, commit, sha256, args, timeout_seconds, form, condition, repeat_minutes, code, bytes, code_by, run_on, approval }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        code = try values.decodeIfPresent(String.self, forKey: .code)
        if code == "saved" {
            path = ""; commit = ""
            bytes = try values.decode(Int.self, forKey: .bytes); code_by = try values.decode(String.self, forKey: .code_by)
            run_on = try values.decodeIfPresent(String.self, forKey: .run_on)
            // Shown only: an approval that cannot be read is left out and never hides the rule.
            approval = ((try? values.decodeIfPresent(CodeApproval.self, forKey: .approval)) ?? nil).flatMap {
                $0.prompt > 0 && $0.approver.range(of: "^[a-z][a-z0-9_-]{0,63}$", options: .regularExpression) != nil ? $0 : nil
            }
        } else {
            path = try values.decode(String.self, forKey: .path); commit = try values.decode(String.self, forKey: .commit)
        }
        sha256 = try values.decode(String.self, forKey: .sha256)
        args = try values.decodeIfPresent([String: CheckArgument].self, forKey: .args) ?? [:]
        timeout_seconds = try values.decodeIfPresent(Int.self, forKey: .timeout_seconds) ?? 30
        form = try values.decodeIfPresent(String.self, forKey: .form)
        condition = try values.decodeIfPresent(Condition.self, forKey: .condition)
        repeat_minutes = try values.decodeIfPresent(Int.self, forKey: .repeat_minutes)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        if isSaved {        // the owner app never sends a saved check; this keeps a decoded one unchanged
            try values.encode(code, forKey: .code); try values.encode(bytes, forKey: .bytes)
            try values.encode(code_by, forKey: .code_by); try values.encode(run_on, forKey: .run_on)
        } else {
            try values.encode(path, forKey: .path); try values.encode(commit, forKey: .commit)
        }
        try values.encode(sha256, forKey: .sha256)
        try values.encode(args, forKey: .args); try values.encode(timeout_seconds, forKey: .timeout_seconds)
        try values.encodeIfPresent(form, forKey: .form)
        if form == nil {    // the value form, as owner API 1.8 has it: both fields, the repeat as null when none
            try values.encode(condition, forKey: .condition); try values.encode(repeat_minutes, forKey: .repeat_minutes)
        }
    }
    public var isValid: Bool {
        let agentName = "^[a-z][a-z0-9_-]{0,63}$"
        let source = isSaved ?
            (path.isEmpty && commit.isEmpty && bytes.map { (1...65536).contains($0) } == true &&
             code_by?.range(of: agentName, options: .regularExpression) != nil &&
             (run_on == nil || run_on!.range(of: agentName, options: .regularExpression) != nil)) :
            (code == nil && path.range(of: "^checks/[a-z0-9_]{1,64}\\.py$", options: .regularExpression) != nil &&
             commit.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil)
        // A condition is checked where the check has one; a check of a newer form has none.
        let compares = condition.map { [">", ">=", "<", "<=", "==", "!="].contains($0.op) && $0.value.isFinite } ?? true
        return source && sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil &&
            timeout_seconds >= 1 && compares &&
            (repeat_minutes == nil || repeat_minutes! >= 0) && (try? JSONEncoder().encode(args).count).map { $0 <= 4096 } == true
    }
    /// The agent whose machine runs the check.
    public func runner(target: String) -> String { run_on ?? target }
}

public struct TriggerCheckCatalog: Decodable, Sendable {
    public let db: String
    public let revision: String
    public let checks: [Source]
    public let skipped: [Skipped]?
    public struct Skipped: Decodable, Sendable { public let path: String; public let reason: String }
    public struct Source: Decodable, Identifiable, Sendable {
        public let path: String
        public let commit: String
        public let sha256: String
        public let bytes: Int
        public let source: String
        public var id: String { "\(commit):\(path)" }
        public var isValid: Bool {
            let data = Data(source.utf8)
            return bytes == data.count && bytes <= 65536 &&
                SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == sha256 &&
                TriggerCheck(path: path, commit: commit, sha256: sha256, args: [:], condition: .init(op: ">", value: 0), repeat_minutes: nil).isValid
        }
    }
    public func validate(database: String) throws {
        guard db == database, revision.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
              checks.allSatisfy({ $0.isValid && $0.commit == revision }), Set(checks.map(\.id)).count == checks.count else { throw HubError.invalidResponse }
    }
}

public struct TriggerSchedule: Codable, Equatable, Sendable {
    public var kind: String
    public var at: String?
    public var minutes: Int?
    public var time: String?
    public var days: [String]?
    public var day: Int?
    public var timezone: String?
    public static let weekdays = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
    public init(kind: String = "daily", at: String? = nil, minutes: Int? = nil, time: String? = "09:00",
                days: [String]? = nil, day: Int? = nil, timezone: String? = TimeZone.current.identifier) {
        self.kind = kind; self.at = at; self.minutes = minutes; self.time = time
        self.days = days; self.day = day; self.timezone = timezone
    }
    public var normalized: Self {
        var value = self
        if let days { value.days = Self.weekdays.filter { days.contains($0) } }
        return value
    }
    public var isValid: Bool {
        if kind == "every" {
            // Any whole number of minutes from 1: the hub keeps no fleet bound on a rule's own cadence (plan C12)
            return minutes.map { $0 >= 1 } == true && at == nil && time == nil && days == nil && day == nil && timezone == nil
        }
        guard let timezone, TimeZone(identifier: timezone) != nil, minutes == nil else { return false }
        if kind == "once" {
            return at?.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}$", options: .regularExpression) != nil && time == nil && days == nil && day == nil
        }
        guard at == nil, time?.range(of: "^([01][0-9]|2[0-3]):[0-5][0-9]$", options: .regularExpression) != nil else { return false }
        if kind == "monthly" { return day.map { (1...31).contains($0) } == true && days == nil }
        return kind == "daily" && day == nil && (days == nil || (!days!.isEmpty && Set(days!).count == days!.count && days!.allSatisfy(Self.weekdays.contains)))
    }
}

public struct TriggerTask: Codable, Equatable, Sendable {
    public var title: String
    public var details: String
    public var done_when: String
    public var needs: String
    public var goal_id: Int?
    public init(title: String = "", details: String = "", done_when: String = "", needs: String = "none", goal_id: Int? = nil) {
        self.title = title; self.details = details; self.done_when = done_when; self.needs = needs; self.goal_id = goal_id
    }
    enum CodingKeys: String, CodingKey { case title, details, done_when, needs, goal_id }
    public func encode(to encoder: Encoder) throws {
        var data = encoder.container(keyedBy: CodingKeys.self)
        try data.encode(title, forKey: .title); try data.encode(details, forKey: .details)
        try data.encode(done_when, forKey: .done_when); try data.encode(needs, forKey: .needs)
        try data.encode(goal_id, forKey: .goal_id)
    }
    public var normalized: Self {
        var value = self
        value.title = normalizedOwnerText(title); value.details = normalizedOwnerText(details); value.done_when = normalizedOwnerText(done_when)
        return value
    }
    public var isValid: Bool {
        !normalized.title.isEmpty && title.count <= 200 && !title.contains("\n") && !title.contains("\r") && details.count <= 8000 &&
        !normalized.done_when.isEmpty && done_when.count <= 2000 && ["none", "browser", "screen"].contains(needs) && (goal_id == nil || goal_id! > 0)
    }
}

public enum TriggerAction: String, Codable, Sendable {
    case pause, resume, delete, run_now, check_now
    /// The action's word in a waiting write's name: "Run", "Check", "Pause", "Resume", "Delete".
    public var word: String { self == .run_now ? "Run" : self == .check_now ? "Check" : rawValue.capitalized }
}

public struct TriggerRun: Codable, Identifiable, Equatable, Sendable {
    public let id: Int
    public let due: Double
    public let manual: Bool
    public let revision: Int
    public let state: String
    public let reason: String?
    public let task: Int?
    public let created: Double
    public let check_now: Bool?
    public let attempts: Int?
    public let retry_at: Double?
    public let value: Double?
    public let summary: String?
    public let error: String?
    public let detail: String?
    public let finished: Double?
    public let event_id: Int?
    public let parent_task: Int?
    public var isValid: Bool {
        id > 0 && revision > 0 && due.isFinite && created.isFinite && !state.isEmpty && (task == nil || task! > 0) &&
        (event_id == nil || event_id! > 0) && (parent_task == nil || parent_task! > 0) &&
        (check_now != true || (manual && task == nil)) && (attempts == nil || attempts! >= 0) &&
        [retry_at, value, finished].allSatisfy { $0 == nil || $0!.isFinite }
    }
}

public struct FleetTrigger: Codable, Identifiable, Equatable, Sendable {
    public let id: Int
    public let agent: String
    public let state: String
    public let revision: Int
    public let paused_by: String?
    public let paused_reason: String?
    public let schedule: TriggerSchedule
    public let task: TriggerTask
    /// The late window and the caps of a hub from before plan C12, which a newer hub no longer sends.
    public let late_minutes: Int?
    public let max_tasks_per_day: Int?
    public let next_due: Double?
    public let last_run: TriggerRun?
    public let last_task: Int?
    public let tasks_24h: Int?
    public let created: Double
    public let updated: Double
    public let request_id: String
    public let check: TriggerCheck?
    public let failures: Int?
    public let armed: Armed?
    /// The rule's project (owner API 1.10; nil for no project), and the agent that saved it last ("owner" for the owner's rules).
    public let project: String?
    public let created_by: String?
    public struct Armed: Codable, Equatable, Sendable { public let armed: Bool; public let reason: String? }
    public var author: String { created_by ?? "owner" }
    public var isAgentRule: Bool { author != "owner" }
    public var isValid: Bool {
        id > 0 && revision > 0 && agent.range(of: "^[a-z][a-z0-9_-]{0,63}$", options: .regularExpression) != nil &&
            schedule.isValid && task.isValid && (late_minutes ?? 0) >= 0 &&
            (max_tasks_per_day ?? 0) >= 0 && check?.isValid != false &&
            !state.isEmpty && (tasks_24h ?? 0) >= 0 && last_run?.isValid != false &&
        (project == nil || project!.range(of: "^[a-z][a-z0-9-]{1,30}$", options: .regularExpression) != nil) &&
        (author == "owner" || author.range(of: "^[a-z][a-z0-9_-]{0,63}$", options: .regularExpression) != nil) &&
        (check?.isSaved != true || isAgentRule)
    }
}

public struct TriggerList: Decodable, Sendable {
    public let db: String
    public let triggers: [FleetTrigger]
    /// The fleet's daily wake-up budget of a hub from before plan C12; a newer hub has none.
    public let fleet: Limits?
    public struct Limits: Decodable, Sendable { public let max_tasks_per_day: Int; public let tasks_24h: Int }
    public func validate(database: String) throws {
        guard db == database, triggers.allSatisfy(\.isValid), Set(triggers.map(\.id)).count == triggers.count,
              fleet.map({ $0.max_tasks_per_day >= 0 && $0.tasks_24h >= 0 }) ?? true else { throw HubError.invalidResponse }
    }
}

public struct TriggerChange: Codable, Equatable, Sendable {
    public let revision: Int
    public let ts: Double
    public let by: String
    public let action: String
}

public struct TriggerDetail: Decodable, Sendable {
    public let db: String
    public let trigger: FleetTrigger
    public let upcoming: [Double]
    public let runs: [TriggerRun]
    public let next: Int?
    /// Who changed the rule and when (newest first), and the saved check code. Both are optional: an older hub has none.
    public let history: [TriggerChange]?
    public let source: String?
    enum CodingKeys: String, CodingKey { case db, trigger, upcoming, runs, next, history, source }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        db = try values.decode(String.self, forKey: .db); trigger = try values.decode(FleetTrigger.self, forKey: .trigger)
        upcoming = try values.decode([Double].self, forKey: .upcoming); runs = try values.decode([TriggerRun].self, forKey: .runs)
        next = try values.decodeIfPresent(Int.self, forKey: .next)
        history = try values.decodeIfPresent([TriggerChange].self, forKey: .history)
        source = try values.decodeIfPresent(String.self, forKey: .source)
    }
    /// The saved code is shown only when it is exactly the version that the rule runs.
    public var verifiedSource: String? {
        guard let source, let check = trigger.check, check.isSaved, Data(source.utf8).count == check.bytes,
              SHA256.hash(data: Data(source.utf8)).map({ String(format: "%02x", $0) }).joined() == check.sha256 else { return nil }
        return source
    }
    public func validate(database: String, id: Int, before: Int?) throws {
        guard db == database, trigger.id == id, trigger.isValid, upcoming.count <= 5, upcoming.allSatisfy(\.isFinite),
              runs.count <= 50, runs.allSatisfy({ $0.isValid && (before == nil || $0.id < before!) }),
              runs.map(\.id) == runs.map(\.id).sorted(by: >), Set(runs.map(\.id)).count == runs.count,
              next == nil || (!runs.isEmpty && next == runs.last?.id),
              (history ?? []).allSatisfy({ $0.revision > 0 && $0.ts.isFinite && !$0.by.isEmpty && !$0.action.isEmpty }),
              source == nil || verifiedSource != nil else { throw HubError.invalidResponse }
    }
}
