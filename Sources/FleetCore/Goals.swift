import Foundation

public struct MoneyLimit: Codable, Equatable, Sendable {
    public var amount: Decimal
    public var currency: String
    public init(amount: Decimal, currency: String) { self.amount = amount; self.currency = currency }
    public var isValid: Bool {
        var value = amount, rounded = Decimal()
        NSDecimalRound(&rounded, &value, 2, .plain)
        return !amount.isNaN && amount >= 0 && amount <= 1_000_000_000 && rounded == amount &&
            currency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil
    }
}

public struct GoalLimits: Codable, Equatable, Sendable {
    public var money: MoneyLimit?
    public var tokens: Int?
    public var deadline: Double?
    public var not_to_do: [String]
    public init(money: MoneyLimit? = nil, tokens: Int? = nil, deadline: Double? = nil, not_to_do: [String] = []) {
        self.money = money; self.tokens = tokens; self.deadline = deadline; self.not_to_do = not_to_do
    }
    // Null fields are part of the write contract; synthesized Encodable would omit them.
    enum CodingKeys: String, CodingKey { case money, tokens, deadline, not_to_do }
    public func encode(to encoder: Encoder) throws {
        var data = encoder.container(keyedBy: CodingKeys.self)
        try data.encode(money, forKey: .money); try data.encode(tokens, forKey: .tokens)
        try data.encode(deadline, forKey: .deadline); try data.encode(not_to_do, forKey: .not_to_do)
    }
    public var isValid: Bool {
        money?.isValid != false && (tokens == nil || (1...1_000_000_000_000).contains(tokens!)) &&
        (deadline == nil || (deadline!.isFinite && deadline! > 0 && deadline! < 100_000_000_000)) && not_to_do.count <= 20 &&
        not_to_do.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 500 }
    }
}

func normalizedOwnerText(_ text: String) -> String {
    text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

public enum GoalAction: String, Codable, Sendable { case pause, resume, done, drop, reopen
    public var resultingState: String { switch self { case .pause: "paused"; case .done: "done"; case .drop: "dropped"; case .resume, .reopen: "active" } }
}

public struct FleetGoal: Codable, Identifiable, Equatable, Sendable {
    public let id: Int
    public let title: String
    public let text: String
    public let state: String
    public let paused_by: String?
    public let revision: Int
    public let limits: GoalLimits
    public let spent: Decimal
    public let tokens_used: Int?
    public let tokens_measured_at: Double?
    public let next_step: NextStep?
    public let wake_at: Double?
    public let result: String?
    public let created: Double
    public let updated: Double
    public let read_at: Double?
    public let reviewed_at: Double?
    public let marker: Marker?
    public let request_id: String
    public let project: String?
    public struct NextStep: Codable, Equatable, Sendable { public let text: String; public let task: Int?; public let set_at: Double }
    public struct Marker: Codable, Equatable, Sendable { public let kind: String; public let since: Double; public let detail: String }
    public var isOpen: Bool { state == "active" || state == "paused" }
    public var isValid: Bool {
        id > 0 && revision > 0 && !title.isEmpty && !text.isEmpty && limits.isValid && !spent.isNaN && spent >= 0 &&
            ["active", "paused", "done", "dropped"].contains(state)
    }
}

public struct GoalDetail: Decodable, Sendable {
    public let db: String
    public let goal: FleetGoal
    public let spends: [Spend]
    public let history: [History]
    public struct Spend: Decodable, Identifiable, Sendable { public let id: Int; public let amount: Decimal; public let currency: String; public let what: String; public let task: Int?; public let by: String; public let created: Double }
    public struct History: Decodable, Identifiable, Sendable { public let id: Int; public let ts: Double; public let by: String; public let kind: String; public let detail: String }
    public func validate(database: String, goalID: Int) throws {
        guard db == database, goal.id == goalID, goal.isValid,
              Set(spends.map(\.id)).count == spends.count, Set(history.map(\.id)).count == history.count else { throw HubError.invalidResponse }
    }
}

func payloadFields<T: Encodable>(_ value: T) throws -> [String: Any] {
    guard let fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] else { throw HubError.invalidResponse }
    return fields
}
