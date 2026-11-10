import Foundation

/// The usage limit of one agent in the Agents table, as one bar: the window with the highest used share in the newest
/// reading of the agent's provider account (`agents[].usage.limits`). Agents that share an account (`account_key`)
/// show the same bar, and shares are never added up. A missing reading stays unknown, never 0%; an old reading says
/// that it is old; and a usage-limit hold of the hub (`agents[].limit`) puts its end in the place of the window.
public struct UsageBar: Sendable {
    /// The color of the bar: neutral below 80%, orange from 80%, red at the limit, 100% (the lead's call on T-08,
    /// 28 October 2026: each colour one meaning — green is an agent at work, orange what needs attention, red what
    /// failed or is used up). It follows the whole percent that the words show, so that the bar and its number always
    /// agree.
    public enum Level: Sendable, Equatable {
        case low, high, full
        public init(percent: Int) { self = percent >= 100 ? .full : percent >= 80 ? .high : .low }
    }

    /// The shown window; nil without a reading that has a window, and for a local model.
    public let window: UsageWindow?
    /// The reading of the shown window, or the agent's own reading when no reading has a window.
    public let reading: AccountLimits?
    /// The hold of the agent's work until its usage limit resets; nil without a hold.
    public let limit: RuntimeLimit?
    /// The other agents whose bar shows the same account, in the hub's order.
    public let sharedWith: [String]
    public let isLocalModel: Bool
    /// Why the reading is missing or old, in the hub's words: an invalid reading, or the reading's own error.
    public let problem: String?
    /// The hub state is current. Without it, every reading and every hold is the last one known.
    public let isFresh: Bool
    private let serverTime: Double

    /// The used share of the window in whole percent, as the words show it.
    public var percent: Int? { window.map { Int($0.used_percent.rounded()) } }
    public var level: Level? { percent.map(Level.init(percent:)) }
    /// The full part of the bar, from 0 to 1. A provider can report more than 100%.
    public var fill: Double { Double(min(100, max(0, percent ?? 0))) / 100 }
    /// The share is the last value known, not the current one: no current hub state, an old reading or one with an
    /// error, or a reset that has passed since the reading. Fleet never assumes that a reset happened.
    public var isStale: Bool {
        guard let window, let reading else { return false }
        return !isFresh || reading.isStale(at: serverTime) || window.resetIsPast(at: serverTime)
    }
    /// The words are the last fact known: an old window, or a hold in a hub state that is not current.
    public var wordsAreOld: Bool { limit == nil ? isStale : !isFresh }

    /// The words beside the bar: "Usage limit until 14:30" while the hub holds the agent's work, "5 h · 40%" for a
    /// window, else "Local model" or "Not reported". `time` writes a coming time in few characters.
    public func words(time: (Double) -> String) -> String {
        if let limit { return "Usage limit until \(time(limit.until))" }
        if let window, let percent { return "\(window.shortLabel) · \(percent)%" }
        return isLocalModel ? "Local model" : "Not reported"
    }

    /// The hover text: the hold; the window's full name, its share and its reset; the time of an old reading; the
    /// reason for a missing or old reading; and the agents on the same account. `date` writes a date and a time.
    public func help(date: (Double) -> String) -> String {
        var lines: [String] = []
        if let limit {
            lines.append(limit.reset_known ? "Usage limit reached. The hub holds this agent's work until \(date(limit.until))."
                : "Usage limit reached. The hub holds this agent's work until about \(date(limit.until)). The provider gave no reset time.")
        }
        if let window, let percent {
            lines.append("\(window.label): \(percent)% used · " + (window.resets_at.map { "resets \(date($0))" } ?? "reset not reported"))
            if isStale { lines.append("Last reading: " + (reading?.collected_at.map(date) ?? "time not reported")) }
        } else if isLocalModel {
            lines.append("A local model has no account limits.")
        } else if problem == nil {
            lines.append("No usage reading yet.")
        }
        if let problem { lines.append(problem) }
        if !sharedWith.isEmpty { lines.append("Same account as \(sharedWith.map(\.agentLabel).formatted(.list(type: .and))).") }
        return lines.joined(separator: "\n")
    }
}

extension UsageBar {
    /// The errors with which the hub keeps a reading of an account that the agent's runtime is no longer signed in to.
    /// Such a reading is history, never the allowance of the runtime's account now ("Account email" in UI-API.md): it
    /// gives no other agent its bar, and it takes no bar of its account.
    public static let identityErrors: Set<String> = ["CLI sign-in is required.", "The signed-in account changed."]

    /// The bar of each agent, by name. `time` is the hub's time of the state.
    public static func bars(for agents: [FleetAgent], time: Double, isFresh: Bool) -> [String: UsageBar] {
        func account(_ reading: AccountLimits?) -> String? {
            guard let reading, !identityErrors.contains(reading.error ?? "") else { return nil }
            return reading.account_key
        }
        // The newest reading of each account, from each route of each agent: a desktop route can use the account of
        // another agent's own route.
        var newest: [String: AccountLimits] = [:]
        for reading in agents.flatMap({ [$0.accountLimits, $0.usage?.screen?.limits] }) {
            guard let reading, let key = account(reading) else { continue }
            if let known = newest[key], (known.collected_at ?? 0) >= (reading.collected_at ?? 0) { continue }
            newest[key] = reading
        }
        return Dictionary(agents.map { agent in
            let key = account(agent.accountLimits)
            let reading = key.flatMap { newest[$0] } ?? agent.accountLimits
            let shared = key == nil ? [] : agents.filter { $0.name != agent.name && account($0.accountLimits) == key }.map(\.name)
            return (agent.name, UsageBar(window: reading?.windows.max { $0.used_percent < $1.used_percent }, reading: reading,
                                         limit: agent.limit, sharedWith: shared, isLocalModel: agent.local_model == true,
                                         problem: agent.usageError ?? reading?.error, isFresh: isFresh, serverTime: time))
        }, uniquingKeysWith: { first, _ in first })
    }
}

extension UsageBar {
    /// **The columns of the Usage page**: the short name of each window that the bars' readings show their owner
    /// (`AccountLimits.ownWindows`), once, so that one window of every row stands under one head ("5 h", "7 d"). The
    /// shorter window comes first, as every provider gives it; windows of one length, such as a week and the week of
    /// one model, keep the order in which the readings first give them, and a window with no length comes last.
    public static func columns(_ bars: [UsageBar], at time: Double) -> [String] {
        var found: [(title: String, minutes: Int)] = []
        for window in bars.flatMap({ $0.reading?.ownWindows(at: time) ?? [] }) where !found.contains(where: { $0.title == window.shortTitle }) {
            found.append((window.shortTitle, window.window_minutes ?? .max))
        }
        return found.enumerated().sorted { ($0.element.minutes, $0.offset) < ($1.element.minutes, $1.offset) }.map(\.element.title)
    }
}

extension UsageWindow {
    /// The length of the window in few characters ("5 h", "7 d", "45 min"), or the hub's label without a length.
    public var shortLabel: String {
        guard let minutes = window_minutes, minutes > 0 else { return label }
        if minutes % 1440 == 0 { return "\(minutes / 1440) d" }
        if minutes % 60 == 0 { return "\(minutes / 60) h" }
        return "\(minutes) min"
    }
}
