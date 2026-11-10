import Foundation

private let entryID = "^[a-z][a-z0-9-]{1,30}$"
private let agentName = "^[a-z][a-z0-9_-]{0,63}$"
private let loginRef = "^bws://[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$"
private let tag = "^[a-z0-9-]{1,30}$"
private func matches(_ value: String, _ pattern: String) -> Bool { value.range(of: pattern, options: .regularExpression) != nil }

/// The owner's label of one paid account. Counting follows the provider's identity, not this label.
public struct TeamAccount: Codable, Equatable, Sendable {
    public var provider: String
    public var title: String
    public init(provider: String = "", title: String = "") { self.provider = provider; self.title = title }
    enum CodingKeys: String, CodingKey { case provider, title }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = try values.decode(String.self, forKey: .provider); title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
    }
}

/// One line of `GET /ui/team` with its identity fields. Logical identity (title, expertise, account) is apart from
/// placement (machine, address, runtime).
public struct TeamMember: Decodable, Identifiable, Sendable {
    /// Where the agent runs. `shared_with` (owner API 1.12): the other agents on that machine.
    public struct Placement: Decodable, Equatable, Sendable {
        public let machine: String?; public let address: String?; public let runtime: String?
        public let shared_with: [String]?
    }
    public let agent: String
    public let role: String
    public let title: String?
    public let expertise: [String]?
    public let account: String?
    public let placement: Placement?
    /// False while the agent is in setup; an older hub may leave it out.
    public let active: Bool?
    public var id: String { agent }
    public var identity: AgentIdentityInput { AgentIdentityInput(title: title, expertise: expertise ?? [], account: account) }
    /// True when other agents run on the same machine, and so share its OS user.
    public var sharesMachine: Bool { placement?.shared_with?.isEmpty == false }
    /// The compact member line: the setup state, the identity (expertise, account label), then the placement,
    /// with the other agents of a shared machine.
    public var summary: String {
        var parts = [String]()
        if active == false { parts.append("in setup") }
        if let tags = expertise, !tags.isEmpty { parts.append(tags.joined(separator: ", ")) }
        parts.append("account \(account ?? "not labelled")")
        if let place = placement {
            parts.append([place.machine, place.runtime].compactMap { $0 }.joined(separator: " · "))
            if let others = place.shared_with, !others.isEmpty {
                parts.append("shares \(place.machine ?? "its server") with \(others.joined(separator: ", "))")
            }
        }
        return parts.joined(separator: " · ")
    }
}

public struct AccountInput: Codable, Equatable, Sendable {
    public var account: String
    public var entry: TeamAccount
    public init(account: String, entry: TeamAccount) { self.account = account; self.entry = entry }
    public var normalized: Self { var value = self; value.entry.title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines); return value }
    public var isValid: Bool {
        matches(account, entryID) && matches(entry.provider, "^[a-z0-9-]{1,30}$") && normalized.entry.title.count <= 60 && !entry.title.contains("\n")
    }
    public func payload() throws -> String { String(decoding: try JSONEncoder().encode(normalized), as: UTF8.self) }
}

/// An agent's logical identity (`POST /ui/team/agents/<agent>`, owner API 1.10): its title, its expertise tags and the
/// label of the paid account that it uses.
public struct AgentIdentityInput: Codable, Equatable, Sendable {
    public var title: String?
    public var expertise: [String]
    public var account: String?
    public init(title: String? = nil, expertise: [String] = [], account: String? = nil) {
        self.title = title; self.expertise = expertise; self.account = account
    }
    public var normalized: Self {
        let text = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        let tags = expertise.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty && seen.insert($0).inserted }
        return Self(title: text?.isEmpty == false ? text : nil, expertise: tags, account: account?.isEmpty == false ? account : nil)
    }
    public func isValid(accounts: Set<String>) -> Bool {
        let value = normalized
        return (value.title.map { $0.count <= 60 && !$0.contains("\n") } ?? true) && value.expertise.count <= 8 &&
            value.expertise.allSatisfy { matches($0, tag) } && (value.account.map(accounts.contains) ?? true)
    }
    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(title, forKey: .title); try fields.encode(expertise, forKey: .expertise); try fields.encode(account, forKey: .account)
    }
    public func payload() throws -> String { String(decoding: try JSONEncoder().encode(normalized), as: UTF8.self) }
}

extension TeamSnapshot {
    /// The id rules of the account labels, checked on what the hub returns.
    func accountsAreValid() -> Bool {
        (accounts ?? [:]).keys.allSatisfy { matches($0, entryID) } && Set(members.map(\.agent)) == Set(lines.map(\.agent))
    }
}
