import Foundation

public struct ProfileSection: Codable, Equatable, Sendable {
    public var key: String
    public var title: String
    public var text: String
    public init(key: String, title: String, text: String) { self.key = key; self.title = title; self.text = text }
}
public struct ProfileInput: Codable, Equatable, Sendable {
    public var sections: [ProfileSection]
    public init(sections: [ProfileSection]) { self.sections = sections }
    public var isValid: Bool {
        let required = ["character", "responsible_for", "may_do", "must_ask"]
        let optional = ["knowledge", "knowledge_files", "logins"]
        return (1...16).contains(sections.count) &&
            required.allSatisfy { key in sections.filter { $0.key == key }.count == 1 } &&
            optional.allSatisfy { key in sections.filter { $0.key == key }.count <= 1 } &&
            sections.allSatisfy { s in
                (required + optional + ["other"]).contains(s.key) && !s.title.isEmpty && s.title.count <= 80 &&
                !s.title.contains("*") && !s.title.contains("\n") && !s.title.contains("\r") &&
                !s.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && s.text.count <= 8000
            } && wireSize <= Self.wireLimit
    }
    /// The size that the profile can take, with a margin for the file's heading under the hub's 32 KiB.
    public static let wireLimit = 32_000
    /// The bytes of the titles and texts, with 12 for the marks and line ends of each section.
    public var wireSize: Int { sections.reduce(0) { $0 + $1.title.utf8.count + $1.text.utf8.count + 12 } }
    public func payload() throws -> String {
        guard isValid else { throw HubError.invalidResponse }
        return String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }
}
public struct AgentProfile: Decodable, Identifiable, Sendable {
    public let agent: String
    public let path: String
    public let sha256: String
    public let sections: [ProfileSection]
    public let text: String
    public var id: String { agent }
}
public struct ProfileList: Decodable, Sendable {
    public let db: String
    public let revision: String
    public let profiles: [AgentProfile]
    public func validate(database: String) throws {
        guard db == database, profiles.count <= 1000, Set(profiles.map(\.agent)).count == profiles.count,
              revision.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
              profiles.allSatisfy({ $0.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil && $0.text.utf8.count <= 32_768 }) else { throw HubError.invalidResponse }
    }
}
