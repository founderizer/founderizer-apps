import Foundation

/// What a page that reads one list of the hub again and again reports while it waits, and after a read that failed.
///
/// `UI-PATTERNS.md`: such a page keeps four states apart — loading, current, an old reading and failed — and never
/// shows a failed read as an empty list or an old reading as current. Both readings here carry one more thing: **the
/// hub's own sentence for the read that failed**. Every owner route writes `{"error": "<one line for the owner>"}`
/// beside the status, and a page that kept its last reading out of a `try?` threw that line away, so the owner read
/// a fixed warning whether his Mac was refused, the hub was not serving or its generation had moved.
public enum FleetReading {
    /// The one line a failed or an old reading reports.
    ///
    /// `reason` is `HubError.said(error)`: the hub's own sentence where it wrote one, and nil where it wrote none —
    /// then the screen's own words for the same fact (`ours`) take its place, because a status number is never shown
    /// on its own. `rest` is what the screen must say whatever the cause: that the rows can be old, and that Fleet
    /// reads again. An old reading must still not read as current, so `rest` is never dropped.
    public static func line(_ reason: String?, instead ours: String = "", then rest: String) -> String {
        let said = (reason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? reason! : ours)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return rest }
        let closed = said.hasSuffix(".") || said.hasSuffix("!") || said.hasSuffix("?") ? said : said + "."
        return rest.isEmpty ? closed : closed + " " + rest
    }

    /// One read of a page that polls: its value, or the hub's own words for the refusal.
    ///
    /// `try?` keeps the value and drops the error, which is exactly the reason the two polling readings said nothing
    /// about why. A page that keeps a last reading uses this instead.
    public static func read<T: Sendable>(_ read: @Sendable () async throws -> T) async -> (value: T?, reason: String?) {
        do { return (try await read(), nil) } catch { return (nil, HubError.said(error)) }
    }
}

/// **When the fleet's state on the screen is current, and when it is the last reading** (`FleetStore.isFresh`): the
/// rule that draws the old-reading notice over the page and the last-reading look of every mark.
///
/// **A reading that is being read again is not old until that read fails or takes more than eight seconds**, at a
/// launch and while the app runs. It was one second, from when a read of the state took 80 ms. A read of the owner's
/// fleet takes 0.7 s now, and one in ten more than a second, so the notice came and went: over a running app once in
/// 150 s, and at a launch whose first read took 1.4 s from 1.2 to 1.6 s after the window opened, with the agents' dots
/// gone from the sidebar for that time (10 November 2026: "loading certain screens like Servers flicker before they
/// are fully loaded"). The rule is here, so that a test can hold it.
public enum StateReading {
    /// How long a read of the fleet's state goes before its reading is old.
    public static let patience: TimeInterval = 8
    /// A reading is old this long after the hub's last answer, whatever the reads did since.
    public static let limit: TimeInterval = 12

    /// The state is current.
    /// - Parameters:
    ///   - held: a read has taken more than its patience, and none has answered since.
    ///   - sinceAnswer: the seconds since the hub's last answer of this launch; nil before the first one, when the
    ///     state is the reading that this Mac kept from its last launch.
    ///   - firstReadEnded: the launch's first read has ended, with an answer or without one.
    public static func isCurrent(held: Bool, sinceAnswer: TimeInterval?, firstReadEnded: Bool) -> Bool {
        if held { return false }
        // The kept reading is current while the launch's first read is on its way, and old once that read failed.
        guard let sinceAnswer else { return !firstReadEnded }
        return sinceAnswer < limit
    }
}

/// **The readings that a page judges against the hub's clock stay current while the app runs** (the owner, 10 November
/// 2026: "loading certain screens like Servers flicker before they are fully loaded"): the servers, the machines'
/// readings, the hub's health and his own devices. A page read them only while it showed, and drew what it kept
/// against the hub's clock of now when it opened again: a list of the servers more than ten minutes old said "Not
/// answering" for every server until the page's own read came, half a second later. The app now reads them again in
/// rounds, on every page. The rule of a round is here, so that a test can hold it.
public enum LiveReadings {
    /// A round every 15 seconds, as a page that shows reads them.
    public static let every: TimeInterval = 15

    /// A round goes out now: none is on its way, and the last one was asked for a round ago, or never. **A round reads
    /// every one of them**, also one that a page read itself a moment ago: a round that left those out read them
    /// again only a round later, 33 seconds after the page's read, and the hub's health speaks for the helpers for 45
    /// (`FleetHealth.currentHelpers`). A read that a page has on its way is shared, so it costs no second request.
    public static func roundDue(sinceAsked: TimeInterval?, running: Bool) -> Bool {
        guard !running else { return false }
        return sinceAsked.map { $0 >= every } ?? true
    }
}

/// The schedule rules that a page reads from the hub again and again. A read that fails never looks like an empty
/// list or like a current one, and says why where the hub wrote a reason.
public enum RuleReading: Equatable, Sendable {
    case loading
    case current([FleetTrigger])
    /// The last good list, after a read that failed, with the hub's own words for that failure.
    case stale([FleetTrigger], String?)
    /// No list: the first read failed, with the hub's own words for it.
    case failed(String?)

    public var rules: [FleetTrigger]? {
        switch self {
        case .current(let rules), .stale(let rules, _): rules
        case .loading, .failed: nil
        }
    }
    public var isStale: Bool { if case .stale = self { true } else { false } }
    /// The hub's own sentence for the read that failed, or nil when it wrote none — and nil for a reading that is
    /// simply old because this Mac has no current hub state: nothing was refused there.
    public var reason: String? {
        switch self {
        case .stale(_, let reason), .failed(let reason): reason
        case .loading, .current: nil
        }
    }
    /// The reading as it shows without a current hub state: a current list is then the last reading.
    public var aged: RuleReading { if case .current(let rules) = self { .stale(rules, nil) } else { self } }

    /// The orange warning of the "Schedules not read" row: the hub's own sentence where it wrote one, and then the
    /// retry, which the owner needs whatever the cause.
    public var notReadWarning: String {
        FleetReading.line(reason, instead: "The schedules could not be read.", then: "Founderizer tries again every 15 seconds.")
    }
    /// The orange warning of the "Last reading" row. It keeps saying that these rows can be old: that is what stops
    /// an old reading from reading as a current one.
    public var lastReadingWarning: String {
        FleetReading.line(reason, instead: "The schedules could not be read.",
                          then: "These rows can be old; Founderizer tries again every 15 seconds.")
    }

    /// The state after one more read; nil is a read that failed, and `reason` is the hub's words for it.
    public func after(_ list: [FleetTrigger]?, reason: String? = nil) -> RuleReading {
        if let list { return .current(list) }
        return rules.map { .stale($0, reason) } ?? .failed(reason)
    }

    public func filter(_ isIncluded: (FleetTrigger) -> Bool) -> RuleReading {
        switch self {
        case .current(let rules): .current(rules.filter(isIncluded))
        case .stale(let rules, let reason): .stale(rules.filter(isIncluded), reason)
        case .loading, .failed: self
        }
    }
}

/// The profiles as the agent pages read them last. A read that fails keeps the last list as an old reading, and says
/// why where the hub wrote a reason.
public enum ProfileReading: Sendable {
    case loading
    case current(ProfileList)
    /// The last good list, after a read that failed, with the hub's own words for that failure.
    case stale(ProfileList, String?)
    /// No list: the first read failed, with the hub's own words for it.
    case failed(String?)

    public var list: ProfileList? {
        switch self {
        case .current(let list), .stale(let list, _): list
        case .loading, .failed: nil
        }
    }
    /// The hub's own sentence for the read that failed, or nil when it wrote none.
    public var reason: String? {
        switch self {
        case .stale(_, let reason), .failed(let reason): reason
        case .loading, .current: nil
        }
    }
    /// The orange line under an old reading of a profile. It keeps saying that this is the last reading, which is
    /// what stops it from reading as a current one.
    public var lastReadingLine: String {
        FleetReading.line(reason, then: "Last reading. Founderizer reads the profile again every 15 seconds.")
    }
    /// The detail under "Profile not read": the hub's own sentence where it wrote one, and then the retry.
    public var notReadDetail: String {
        FleetReading.line(reason, then: "Founderizer reads the profile again every 15 seconds.")
    }

    /// The state after one more read; nil is a read that failed, and `reason` is the hub's words for it.
    public func after(_ list: ProfileList?, reason: String? = nil) -> ProfileReading {
        if let list { return .current(list) }
        return self.list.map { .stale($0, reason) } ?? .failed(reason)
    }
}

/// A reading that names the hub generation it was read in.
public protocol GenerationReading: Sendable {
    var db: String { get }
}

extension FleetHealth: GenerationReading {}
extension ReleaseState: GenerationReading {}

/// **A reading this Mac kept from its last launch, until this launch's own read of it answers** (the polish and the
/// reviews of 30 October 2026): the Settings dot draws from the health (`FleetHealth`), and the sidebar's Update row
/// from the releases (`ReleaseState`) and from the build of this app that waited (`WaitingBuild`), in the launch's first
/// frame, where they came after the launch's reads. **A read of this launch that fails takes it away**: what it says is
/// not known to be true now, and the next read can be minutes away (the releases: 300 s; the channel: an hour), or come
/// only when a page that reads it opens (the health).
public struct KeptReading<Value: Sendable>: Sendable {
    public private(set) var reading: Value?

    public init(_ reading: Value? = nil) { self.reading = reading }

    /// A read of it in this launch failed.
    public mutating func readFailed() { reading = nil }
}

extension KeptReading where Value: GenerationReading {
    /// The kept reading, for the hub generation that draws now.
    public func reading(of database: String?) -> Value? { reading.flatMap { $0.db == database ? $0 : nil } }
}
