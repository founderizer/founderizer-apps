import Foundation

public struct AgentUsage: Decodable, Sendable {
    public let tokens: TokenUsage?
    public let limits: AccountLimits?
    public let screen: ScreenUsage?
    /// `runtime_switch`: the last token reading of the agent's runtime before its latest switch.
    public let previous: PreviousUsage?
    public var isValid: Bool { tokens?.isValid != false && limits?.isValid != false && screen?.isValid != false }
    enum CodingKeys: String, CodingKey { case tokens, limits, screen, previous }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tokens = try values.decodeIfPresent(TokenUsage.self, forKey: .tokens)
        limits = try values.decodeIfPresent(AccountLimits.self, forKey: .limits)
        screen = try values.decodeIfPresent(ScreenUsage.self, forKey: .screen)
        // An earlier runtime's reading that cannot be read is left out: it never hides the live reading.
        let previous = (try? values.decodeIfPresent(PreviousUsage.self, forKey: .previous)) ?? nil
        self.previous = previous?.isValid == true ? previous : nil
    }
    /// The agent's recorded tokens: its runtime's sessions, its Codex screen tasks and its earlier runtime's total. The
    /// time and the error of the reading come from the live readings when there is one: the earlier total is history
    /// of a runtime that no longer runs, so its reading time never makes a current reading look old.
    public var combinedTokens: TokenUsage? {
        let live = [tokens, screen?.tokens].compactMap { $0 }
        let parts = live + [previous?.tokens].compactMap { $0 }
        guard parts.count > 1 else { return parts.first }
        let clock = live.isEmpty ? parts : live
        let source = live.count > 1 ? "Workspace sessions and Codex screen events" : clock[0].source
        return TokenUsage(input: parts.map(\.input).reduce(0, +), output: parts.map(\.output).reduce(0, +),
            cache_read: parts.map(\.cache_read).reduce(0, +), cache_write: parts.map(\.cache_write).reduce(0, +),
            total: parts.map(\.total).reduce(0, +), sessions: parts.map(\.sessions).reduce(0, +),
            since: parts.compactMap(\.since).min(), last_activity: parts.compactMap(\.last_activity).max(),
            collected_at: clock.map(\.collected_at).min()!, source: previous?.tokens == nil ? source : "\(source), with the earlier runtime's total",
            scope: "Work recorded by Founderizer", error: clock.compactMap(\.error).first)
    }
}

/// The token total of an agent's runtime before its latest switch (`runtime_switch`), from the transcripts that its
/// machine keeps, so it can still take that runtime's final turn after the switch. It is history: it has no account
/// and no allowance, and a switch back replaces it, so nothing counts twice.
public struct PreviousUsage: Decodable, Sendable {
    public let runtime: String
    public let tokens: TokenUsage?
    public let until: Double
    public var isValid: Bool { !runtime.isEmpty && tokens?.isValid != false && validUsageTime(until) }
}

public struct ScreenUsage: Decodable, Sendable {
    public let tokens: TokenUsage?
    public let limits: AccountLimits?
    public var isValid: Bool { tokens?.isValid != false && limits?.isValid != false }
}

public struct TokenUsage: Decodable, Sendable {
    public let input: Int64
    public let output: Int64
    public let cache_read: Int64
    public let cache_write: Int64
    public let total: Int64
    public let sessions: Int
    public let since: Double?
    public let last_activity: Double?
    public let collected_at: Double
    public let source: String
    public let scope: String
    public let error: String?

    public var isValid: Bool {
        let counts = [input, output, cache_read, cache_write, total]
        guard counts.allSatisfy({ (0...1_000_000_000_000_000).contains($0) }) else { return false }
        return total == input + output + cache_read + cache_write && sessions >= 0 &&
            validUsageTime(collected_at) && validUsageTime(since) && validUsageTime(last_activity) &&
            !source.isEmpty && !scope.isEmpty
    }

    public func isStale(at time: Double) -> Bool {
        error != nil || time < collected_at - 60 || time - collected_at > 600
    }
}

public struct AccountLimits: Decodable, Sendable {
    public let collected_at: Double?
    public let source: String
    public let plan: String?
    public let account_key: String?
    public let windows: [UsageWindow]
    public let error: String?
    private let email: String?
    enum CodingKeys: String, CodingKey { case collected_at, source, plan, account_key, windows, error, email = "account_email" }

    /// The owner feature that adds `account_email` to an account reading and to `/ui/capacity`.
    public static let emailFeature = "account_email"

    /// The email of the provider account that this route is signed in to, as its runtime gave it in this reading. nil:
    /// unknown (an older helper, an API key, a local model, Grok, or no reading of the new provider after a switch).
    /// It is the identity only: routes share an allowance by `account_key`, never by an email, and an owner's account
    /// label is not an email. This is the last reading's value; `currentEmail(at:)` says if it is current.
    public var account_email: String? { collected_at == nil ? nil : email.flatMap(reportedEmail) }

    public var isValid: Bool {
        validUsageTime(collected_at) && !source.isEmpty && windows.count <= 24 &&
            Set(windows.map(\.id)).count == windows.count && windows.allSatisfy(\.isValid) &&
            (windows.isEmpty || collected_at != nil)
    }

    /// No reading time, a time more than 10 minutes before `time`, or one more than a minute after it.
    private func isOld(at time: Double) -> Bool {
        guard let collected_at else { return true }
        return time < collected_at - 60 || time - collected_at > 600
    }

    public func isStale(at time: Double) -> Bool { error != nil || isOld(at: time) }

    /// The account email while this reading is current at `time`; nil for an unknown email and for an old reading,
    /// which must not look current. An allowance error and missing windows do not hide it: a reading can name its
    /// account when the provider gave no allowance.
    public func currentEmail(at time: Double) -> String? { isOld(at: time) ? nil : account_email }
}

/// An account email in the hub's format (`account_email`): at most 254 characters, exactly one "@", no white space and
/// no control character; here also with a text on each side of the "@". Any other value counts as unknown, so a bad
/// identity never hides its reading.
func reportedEmail(_ value: String) -> String? {
    let parts = value.split(separator: "@", omittingEmptySubsequences: false)
    guard value.unicodeScalars.count <= 254, parts.count == 2, !parts.contains(where: \.isEmpty),
          !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) })
    else { return nil }
    return value
}

public struct UsageWindow: Decodable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let used_percent: Double
    public let resets_at: Double?
    public let window_minutes: Int?
    public var remainingPercent: Double { max(0, 100 - used_percent) }
    public var isValid: Bool {
        !id.isEmpty && !label.isEmpty && used_percent.isFinite && (0...1_000_000).contains(used_percent) &&
            validUsageTime(resets_at) && (window_minutes == nil || window_minutes! > 0)
    }
    public func resetIsPast(at time: Double) -> Bool { resets_at.map { $0 <= time } ?? false }
}

private func validUsageTime(_ time: Double?) -> Bool {
    time.map { $0.isFinite && $0 > 0 && $0 < 32_503_680_000 } ?? true
}
