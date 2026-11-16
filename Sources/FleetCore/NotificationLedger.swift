import Foundation

public struct ManagerWarning: Codable, Equatable, Sendable {
    public let kind: String
    public let since: Double
    /// Which `down` it is (hub, 16 November 2026): `not_running` (its helper answers and its window is gone) or
    /// `server_silent` (its server went silent with a message waiting); nil for another kind or an older hub.
    public let cause: String?
    public var episode: String? {
        guard since.isFinite, since > 0,
              kind.range(of: "^[a-z][a-z0-9_-]{0,63}$", options: .regularExpression) != nil else { return nil }
        return "\(kind)/\(since)"
    }
}

/// Needs-you IDs are monotonic within a hub generation. First contact establishes a baseline.
public struct NotificationLedger: Codable, Sendable {
    private var seen: [String: Int] = [:]
    private var warnings: [String: String]?
    public init() {}
    /// The new open requests of the manager, which is `manager` by the name that the reading gives it
    /// (`HubState.managerName`): a manager with a name of its own notifies as one named `manager` does.
    public mutating func observe(context: String, needs: [OwnerNeed], manager: String = "manager") -> [Int] {
        let previous = seen[context]
        seen[context] = max(previous ?? 0, needs.map(\.id).max() ?? 0)
        guard let previous else { return [] }
        return needs.filter { $0.id > previous && $0.isOpen && $0.by == manager }.map(\.id)
    }

    public mutating func observeWarning(context: String, warning: ManagerWarning?) -> String? {
        let previous = warnings?[context]
        if warnings == nil { warnings = [:] }
        guard let episode = warning?.episode else {
            if previous == nil { warnings?[context] = "" }
            return nil
        }
        warnings?[context] = episode
        guard let previous, previous != episode else { return nil }
        return episode
    }
}
