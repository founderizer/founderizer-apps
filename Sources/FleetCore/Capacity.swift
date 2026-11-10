import Foundation

/// One window of a provider allowance, as the provider reported it. A value that it did not report is nil, never zero.
public struct CapacityWindow: Decodable, Equatable, Sendable {
    public let label: String
    public let used_percent: Double?
    public let remaining_percent: Double?
    public let resets_at: Double?
    public let window_minutes: Int?
    public init(label: String, used_percent: Double?, remaining_percent: Double?, resets_at: Double?, window_minutes: Int?) {
        self.label = label; self.used_percent = used_percent; self.remaining_percent = remaining_percent
        self.resets_at = resets_at; self.window_minutes = window_minutes
    }
    public var isValid: Bool {
        !label.isEmpty && label.count <= 120 && [used_percent, remaining_percent, resets_at].allSatisfy { $0 == nil || $0!.isFinite } &&
            (used_percent == nil || (0...1_000_000).contains(used_percent!)) && (remaining_percent == nil || (0...100).contains(remaining_percent!)) &&
            (window_minutes == nil || window_minutes! > 0)
    }
    public func resetIsPast(at time: Double) -> Bool { resets_at.map { $0 <= time } ?? false }
}

/// What the latest reading says about an allowance now.
public enum AllowanceState: Equatable, Sendable {
    /// No reading, or no window with a reported use.
    case unknown
    /// The reading is old or failed, or a used-up window's reset has passed: a new reading is needed first.
    case awaitingReading
    case available
    /// A current reading shows a used-up window. `until`: when every used-up window resets; nil when one has no reset time.
    case usedUp(until: Double?)
}

/// `GET /ui/capacity` (owner API 1.10): the facts that the manager and the owner plan with. Eligibility (projects,
/// expertise, access) comes first; availability and allowance are secondary. An agent has a primary route and, when it
/// has a screen runtime, a screen route; each route can use another provider account. The hub groups routes by the
/// provider's account identity, so an allowance that several routes share is one entry. A route without that identity
/// is a group of its own (`unknown:<agent>:<route>`), never merged by an owner label. Nothing here stops or buys anything.
public struct CapacityReport: Decodable, Sendable {
    public let db: String
    public let time: Double
    public let stale_after: Double
    public let accounts: [Account]
    public let agents: [Agent]

    public struct RouteRef: Decodable, Equatable, Sendable { public let agent: String; public let route: String }
    public struct Sample: Decodable, Hashable, Sendable {
        public let agent: String
        public let route: String
        public let read_at: Double?
        public let stale: Bool
        public let error: String?
    }
    /// One provider account, shown with its newest reading; `samples` gives the time and staleness of every reading.
    public struct Account: Decodable, Identifiable, Sendable {
        public let group: String
        public let provider: String?
        public let label: String?
        public let labels: [String]
        public let routes: [RouteRef]
        public let plan: String?
        public let read_at: Double?
        public let stale: Bool?
        public let error: String?
        public let windows: [CapacityWindow]
        public let samples: [Sample]
        public let mismatch: String?
        /// The hub's allowance of the account at the report time (`available`, `limited` or `unknown`), with its
        /// reason. A session's usage-limit hold makes it `limited` also while the last window is below 100%.
        /// `until` is a known reset; `retry_at` is only the hub's estimate.
        public let state: String
        public let reason: String?
        public let until: Double?
        public let retry_at: Double?
        private let reported: [String]?
        enum CodingKeys: String, CodingKey {
            case group, provider, label, labels, routes, plan, read_at, stale, error, windows, samples, mismatch, state, reason, until, retry_at
            case reported = "emails"
        }
        public var id: String { group }
        public var isIdentified: Bool { !group.hasPrefix("unknown:") }
        /// Feature `account_email`: the emails that the account's routes reported, sorted, each one time; empty when
        /// unknown. The account is one entry by its identity (`group`), never by an email or an owner label.
        public var emails: [String] { (reported ?? []).compactMap(reportedEmail) }
        /// The hub's allowance, aged to `time`. A limit whose known reset has passed, and an available reading that is
        /// older than `staleAfter` now, stale, failed, or from before a reset that has passed, await a new reading.
        public func allowance(at time: Double, staleAfter: Double) -> AllowanceState {
            switch state {
            case "limited":
                if let until { return until > time ? .usedUp(until: until) : .awaitingReading }    // a known reset
                if retry_at != nil { return .usedUp(until: nil) }      // a hold without a reset: its estimate is no reset
                // A window at 100% without a reset time is certain only while its reading is fresh.
                guard let read_at, stale != true, time - read_at <= staleAfter, time >= read_at - 60 else { return .awaitingReading }
                return .usedUp(until: nil)
            case "available":
                guard let read_at else { return .unknown }
                if stale == true || error != nil || time - read_at > staleAfter || time < read_at - 60 ||
                    windows.contains(where: { $0.resetIsPast(at: time) }) { return .awaitingReading }
                return .available
            default:
                return read_at == nil ? .unknown : .awaitingReading
            }
        }
    }
    /// One route of an agent. `until` is a reset time that the provider or the session gave; `retry_at` is only the
    /// hub's estimate when no reset time is known.
    public struct Route: Decodable, Equatable, Sendable {
        public let route: String
        public let runtime: String?
        public let group: String?
        public let read_at: Double?
        public let stale: Bool
        public let state: String
        public let reason: String?
        public let until: Double?
        public let retry_at: Double?
        private let email: String?
        /// The time of this route's own reading that gave its email; nil without an email. `read_at` and `stale` are
        /// those of the account's shared allowance, which another route can have read later: they never age the email.
        public let account_email_read_at: Double?
        enum CodingKeys: String, CodingKey {
            case route, runtime, group, read_at, stale, state, reason, until, retry_at, email = "account_email", account_email_read_at
        }
        /// Feature `account_email`: the email of the provider account that this route is signed in to; nil when unknown.
        public var account_email: String? { email.flatMap(reportedEmail) }
    }
    /// The hub's scheduling hold over all of an agent's work (a session reached its usage limit), apart from any
    /// account allowance: while it lasts, a route with unused allowance takes no new work.
    public struct Hold: Decodable, Equatable, Sendable {
        public let reason: String?
        public let until: Double?
        public let retry_at: Double?
        public let task: Int?
        public let route: String?
    }
    public struct Membership: Decodable, Equatable, Sendable { public let project: String; public let role: String }
    public struct Workload: Decodable, Equatable, Sendable { public let open: Int; public let tasks: [Int]? }
    public struct Agent: Decodable, Identifiable, Sendable {
        public let agent: String
        public let title: String?
        public let role: String?
        public let active: Bool?
        public let expertise: [String]?
        public let projects: [Membership]?
        public let reports_to: String?
        public let account: String?
        public let seen_at: Double?
        public let hold: Hold?
        public let routes: [Route]
        public let workload: Workload?
        public let eligible: Bool?
        public let why_not: [String]?
        public var id: String { agent }
    }

    public func account(_ group: String?) -> Account? { group.flatMap { g in accounts.first { $0.group == g } } }

    public func validate(database: String) throws {
        let routeNames: Set<String> = ["primary", "screen"]
        guard db == database, time.isFinite, stale_after.isFinite, stale_after > 0, accounts.count <= 1000, agents.count <= 1000,
              Set(accounts.map(\.group)).count == accounts.count, Set(agents.map(\.agent)).count == agents.count,
              accounts.allSatisfy({ !$0.group.isEmpty && !$0.state.isEmpty && $0.windows.count <= 24 && $0.windows.allSatisfy(\.isValid) &&
                                    [$0.until, $0.retry_at].allSatisfy { $0 == nil || $0!.isFinite } &&
                                    ($0.read_at == nil || $0.read_at!.isFinite) && $0.routes.allSatisfy { routeNames.contains($0.route) } &&
                                    ($0.isIdentified || $0.provider == nil) }),
              agents.allSatisfy({ a in
                  (a.workload?.open ?? 0) >= 0 && Set(a.routes.map(\.route)).count == a.routes.count &&
                  [a.hold?.until, a.hold?.retry_at].allSatisfy { $0 == nil || $0!.isFinite } &&
                  a.routes.allSatisfy { r in routeNames.contains(r.route) &&
                                         [r.read_at, r.until, r.retry_at, r.account_email_read_at].allSatisfy { $0 == nil || $0!.isFinite } &&
                                         (r.group == nil || accounts.contains { $0.group == r.group }) } })
        else { throw HubError.invalidResponse }
    }
}

/// What a route of an agent can take now. A state of the agent itself (offline, in setup, a helper never seen) wins;
/// a local model's primary route has no account; any other route has its account's allowance, aged like the account
/// row, so the two never disagree.
public enum RouteAvailability: Equatable, Sendable {
    case agent(String)
    case localModel
    case account(AllowanceState)
}

/// The app's view of `/ui/capacity` over time: the last report, and whether the latest fetch failed. A reading is shown
/// as current only while Fleet itself is fresh, the latest fetch succeeded and that report is at most `maxAge` seconds
/// old at the hub's current time; else it is the last reading, awaiting a new one.
public struct CapacityFeed: Sendable {
    public private(set) var report: CapacityReport?
    public private(set) var error: String?
    public static let maxAge = 90.0
    public init() {}
    public mutating func received(_ report: CapacityReport) { self.report = report; error = nil }
    public mutating func failed(_ error: Error) { self.error = (error as? LocalizedError)?.errorDescription ?? "Capacity could not be read." }
    public func isCurrent(at now: Double, fresh: Bool) -> Bool {
        guard fresh, error == nil, let report else { return false }
        return now - report.time <= Self.maxAge && now >= report.time - 60
    }
    public func availability(of route: CapacityReport.Route, at now: Double, fresh: Bool) -> RouteAvailability {
        guard let group = route.group else { return route.state == "available" ? .localModel : .agent(route.state) }
        guard let account = report?.account(group), route.state == account.state else { return .agent(route.state) }
        return .account(allowance(account, at: now, fresh: fresh))
    }
    public func allowance(_ account: CapacityReport.Account, at now: Double, fresh: Bool) -> AllowanceState {
        guard isCurrent(at: now, fresh: fresh), let report else { return account.read_at == nil ? .unknown : .awaitingReading }
        return account.allowance(at: now, staleAfter: report.stale_after)
    }
    /// The account email of a route, from a current report and from the route's own reading while that reading is not
    /// old: an old identity must not look current. Without the time of that reading the email is unknown. The age of
    /// the shared allowance, a limit, an allowance error and missing windows do not change it.
    public func email(of route: CapacityReport.Route, at now: Double, fresh: Bool) -> String? {
        guard isCurrent(at: now, fresh: fresh), let report, let read = route.account_email_read_at,
              now - read <= report.stale_after, now >= read - 60 else { return nil }
        return route.account_email
    }
    /// The emails of an account that its routes give now: one route's new reading does not make another route's old
    /// email current.
    public func emails(of account: CapacityReport.Account, at now: Double, fresh: Bool) -> [String] {
        let current = Set((report?.agents ?? []).flatMap(\.routes).filter { $0.group == account.group }
            .compactMap { email(of: $0, at: now, fresh: fresh) })
        return account.emails.filter(current.contains)
    }
}
