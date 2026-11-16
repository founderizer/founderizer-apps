#if os(macOS)
import Foundation

/// **One install that this Mac ran, kept after its page is gone** (the owner's report of 14 November 2026: a new user's
/// second server was made, its install stopped, and after Back, a restart and an update of the app nobody could say
/// where or why, because the install lived in the page's memory only). A record says which install it was, each step
/// by a fixed name with its state and its times, and how it ended, with the stop as a fixed kind.
///
/// **What it never holds**: a whole line that the server or its installer printed, the machine's own words of a
/// failure (`MachineInstallModel.failureDetail`), a join code, a key, a password or a path of a key. It has no field
/// for a user or a port. It holds addresses and a server's name, so it stays on this Mac, in the app's own folder, and only
/// the app's own process reads it: the folder is read one time, and another process would read an install that runs
/// as one that was cut off.
///
/// **`says` is for the owner's own eyes on this Mac.** It is the one orange line that the install's page showed, kept
/// only where the words are this app's own (`words(of:host:)`): never the installer's own reason for its stop, which
/// the server printed, and never the words of a hub, of Tailscale or of a Mac's installer. The app's own line can
/// carry single values: the server's address, and what the check of the server read there, as the server gave it
/// (the user of the login, "The user ada is not root on that server"; the kind of machine). No reader of the app's
/// link and no log may print it: a reader for another program gives the fixed names, the counts and the times, and
/// never `says`, `hub`, `host`, `server` or `id`.
public struct InstallRecord: Codable, Equatable, Sendable, Identifiable {
    /// Which install: the hub's own (`InstallPlan.hub`), a server that joins (`InstallPlan.join`), or the link to a
    /// Mac's own installer.
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case hub, join, mac
    }

    /// How the install stands or ended. **`interrupted` is never written**: `InstallRecords` gives it for a record that
    /// says `running` and that another start of the app wrote, so an install that a quit, a crash or an update of the
    /// app cut off never reads as one that runs.
    public enum Outcome: String, Codable, CaseIterable, Sendable {
        case running, done, stopped, cancelled, interrupted
    }

    public enum StepState: String, Codable, CaseIterable, Sendable {
        case running, done, failed
    }

    /// **The steps by their fixed names**: the ids of the two plans (`InstallPlan.hub`, `InstallPlan.join`; a test holds
    /// them to this list), `order` for a Mac's installer that has no step yet, and `other` for every id that is not
    /// here, which a Mac's installer sends over the network.
    public enum StepID: String, Codable, CaseIterable, Sendable {
        case read, network, code, plan, start
        case waitClaim = "wait_claim"
        case claim
        case waitReady = "wait_ready"
        case verify, join, order, other

        public init(named id: String) { self = StepID(rawValue: id) ?? .other }

        /// A name that a later version of the app wrote reads as `other`, so that its record stays readable.
        public init(from decoder: Decoder) throws {
            self.init(named: try decoder.singleValueContainer().decode(String.self))
        }
    }

    /// The fixed names of the steps, for a reader that holds its own list to them.
    public static let stepIDs = StepID.allCases.map(\.rawValue)

    public struct Step: Codable, Equatable, Sendable {
        public let id: StepID
        public var state: StepState
        public var began: Date
        public var ended: Date?
    }

    /// **Why an install stopped, as a fixed kind**: the kind of the error that ended it (`of`).
    public enum Stop: String, Codable, CaseIterable, Sendable {
        /// It could not begin: the hub gave no join line, or the installer on that Mac is too old.
        case cannotStart = "cannot_start"
        /// The installer on the server stopped itself, with its own stop mark (`InstallPlan.stopMarks`).
        case installerStopped = "installer_stopped"
        /// `ssh` did not reach the server.
        case serverUnreached = "server_unreached"
        /// The server took none of this Mac's keys.
        case loginRefused = "login_refused"
        /// A step failed for another reason.
        case stepFailed = "step_failed"
        /// A hub at the server's address has its owner and refused this Mac's reads (`MachineInstaller.notThisMacs`):
        /// the hub of another computer, or this Mac's own hub for which this Mac's key is gone. Another try from this
        /// Mac ends the same way.
        case hubNotOurs = "hub_not_ours"
        case notRoot = "not_root"
        case timedOut = "timed_out"
        case noClaimCode = "no_claim_code"
        case noChecklist = "no_checklist"
        /// The check of the server stopped the install before anything changed on it.
        case checkStopped = "check_stopped"
        case needsSudoPassword = "needs_sudo_password"
        case needsSSHPassword = "needs_ssh_password"
        /// Tailscale gave this Mac no key for the server.
        case networkKeyRefused = "network_key_refused"
        case hubRefused = "hub_refused"
        case hubUnreached = "hub_unreached"
        /// The installer on a Mac said that it stopped, or refused the order.
        case macRefused = "mac_refused"
        case macUnreachable = "mac_unreachable"
        case macUnreadable = "mac_unreadable"
        case other

        /// A kind that a later version of the app wrote reads as `other`, so that its record stays readable.
        public init(from decoder: Decoder) throws {
            self = Stop(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
        }

        /// **The kind of the error that ended an install.** A step's words are read as `InstallError.plain` reads
        /// them, in its order (the installer's stop mark with a reason after it, then a server not reached, then a key
        /// not taken), so the kind and the page's line agree. An error of the app's own target that this library does
        /// not know (Tailscale's refusal of a key) is given by its caller.
        public static func of(_ error: Error) -> Stop {
            if let error = error as? InstallError {
                switch error {
                case .cannotStart: return .cannotStart
                case .step(_, let says):
                    if says == MachineInstaller.notThisMacs { return .hubNotOurs }
                    let said = says.lowercased()
                    if let mark = InstallPlan.stopMarks.first(where: says.contains),
                       let reason = says.components(separatedBy: mark).last?.trimmingCharacters(in: .whitespaces),
                       !reason.isEmpty { return .installerStopped }
                    if InstallError.unreached(said) { return .serverUnreached }
                    if InstallError.keyRefused(said) { return .loginRefused }
                    return .stepFailed
                case .notRoot: return .notRoot
                case .timedOut: return .timedOut
                case .noClaimCode: return .noClaimCode
                case .noChecklist: return .noChecklist
                case .checkStopped: return .checkStopped
                case .needsPassword(.sudo): return .needsSudoPassword
                case .needsPassword(.ssh): return .needsSSHPassword
                }
            }
            if let error = error as? MacLinkError {
                switch error {
                case .notAnAddress: return .cannotStart
                case .refused: return .macRefused
                case .unreachable: return .macUnreachable
                case .unreadable: return .macUnreadable
                }
            }
            if let error = error as? HubError {
                switch error {
                case .unavailable: return .hubUnreached
                case .invalidAddress, .invalidResponse, .refusal: return .hubRefused
                }
            }
            // A request of the install that got no answer: its requests go to the hub (the join line).
            if error is URLError { return .hubUnreached }
            return .other
        }
    }

    /// The most characters that `says` keeps.
    public static let saysLimit = 300
    /// The most steps that a record keeps: the two plans have 9 and 4, and a Mac's installer names its own.
    public static let mostSteps = 64
    /// The most characters of a server's name: the hub's names are shorter.
    public static let nameLimit = 64

    /// **The line that a record keeps for a stop**: the page's own line (`InstallError.plain`) where its words are
    /// this app's own, else none. None for the installer's own stop, whose reason the server printed; none for an
    /// error that is no `InstallError` (a hub's refusal, Tailscale's words, a Mac's installer), whose words are
    /// another program's. The fixed kind (`Stop.of`) says those.
    public static func words(of error: Error, host: String) -> String? {
        guard let error = error as? InstallError, Stop.of(error) != .installerStopped else { return nil }
        return error.plain(host: host)
    }

    public let id: UUID
    public let kind: Kind
    /// The start of the app that wrote this record (`AppLaunch.id`).
    public let launch: String
    /// The hub's address in the app's own form, with its last slash (`FleetStore.hub.absoluteString`,
    /// `http://100.64.0.7:8765/`): a reader compares it as text. nil for a hub's own install until its claim step
    /// ended well: a first run has no hub to keep an install by. A hub's install that stopped after its claim has the
    /// claimed address, which the app is not connected to: `newest(kind:)` finds it.
    public internal(set) var hub: String?
    /// The address that the install reached the machine at: the one given, then the one on the private network.
    public internal(set) var host: String
    /// The server's name in the fleet, once it is known. nil for a stop before that: the hub's list has the server
    /// by `host` then.
    public internal(set) var server: String?
    public internal(set) var steps: [Step]
    public let began: Date
    /// nil while it runs, and for an install that was cut off (`interrupted`): `lastChange` is its last sign.
    public internal(set) var ended: Date?
    public internal(set) var outcome: Outcome
    public internal(set) var stop: Stop?
    /// The install stopped only because the machine is not on the private network and no key was given
    /// (`InstallPlan.needsNetworkKey`).
    public internal(set) var waitsForNetwork: Bool
    /// The page's one orange line, for the owner's own eyes on this Mac (see the type's own words): the plan's
    /// redactions applied again, and `saysLimit` characters at most.
    public internal(set) var says: String?
    /// **Why the installer stopped itself, as a fixed name** (`InstallCause`), read from its own stop sentence and
    /// never kept in its words: only for a stop of the kind `installerStopped`, or a Mac's stop that its sealed state
    /// gave. nil for every other record, and for a record that an app from before this field wrote.
    public internal(set) var cause: InstallCause?
    /// **How many tries the owner's press made** (`InstallRetry`): 2 or 3 when the app ran the install again by itself
    /// after an error that passes; nil for one try, and for a record that an app from before this field wrote.
    public internal(set) var tries: Int?
    /// **Why each earlier try of the press stopped**, oldest first, at most `InstallRetry.most`: the fixed name of its
    /// cause (`InstallCause`) or of its stop's kind (`Stop`), never its words. nil with no retry.
    public internal(set) var retried: [String]?

    public init(id: UUID = UUID(), kind: Kind, hub: String?, host: String, launch: String = AppLaunch.id,
                at began: Date = Date()) {
        self.id = id
        self.kind = kind
        self.launch = launch
        self.hub = hub
        self.host = host
        server = nil
        steps = []
        self.began = began
        ended = nil
        outcome = .running
        stop = nil
        waitsForNetwork = false
        says = nil
        cause = nil
        tries = nil
        retried = nil
    }

    /// **The step that the install stopped at**: the one that failed, else the one that ran. nil for an install that
    /// runs or that ended well.
    public var stoppedAt: StepID? {
        switch outcome {
        case .running, .done: nil
        case .stopped, .cancelled, .interrupted:
            steps.first { $0.state == .failed }?.id ?? steps.last { $0.state == .running }?.id
        }
    }

    /// The newest time in the record: the last sign of an install that was cut off and has no end.
    public var lastChange: Date {
        steps.reduce(max(began, ended ?? began)) { max($0, max($1.began, $1.ended ?? $1.began)) }
    }

}

/// **The record of the install that a model runs now**, with each step under the name that its installer gave it: two
/// steps of a Mac's installer whose names are not on the list are two steps `other` of the record, each with its own
/// times. Every change says whether the record changed, so that the model writes only then: never for a line that a
/// step printed.
public struct InstallLog: Sendable {
    public private(set) var record: InstallRecord
    /// Where each step stands in the record, by the name that the installer gave it.
    private var places: [String: Int] = [:]
    /// What no kept word may hold: the plan's own list (`InstallPlan.redactions`), and a Mac's link code.
    private var hides: [String] = []

    public init(kind: InstallRecord.Kind, hub: String?, host: String, launch: String = AppLaunch.id,
                at began: Date = Date()) {
        record = InstallRecord(kind: kind, hub: hub, host: host, launch: launch, at: began)
    }

    /// The strings that the install's plan takes out of every line, for the one line that the record keeps. Only
    /// while the install runs: its end lets go of them.
    public mutating func hide(_ secrets: [String]) {
        guard record.outcome == .running else { return }
        hides += secrets.filter { $0.count >= 8 }
    }

    /// The hub's address, the address that the install reached, and the server's name, each as soon as it is known.
    @discardableResult
    public mutating func place(hub: String? = nil, host: String? = nil, server: String? = nil) -> Bool {
        let before = record
        if let hub, !hub.isEmpty { record.hub = hub }
        if let host, !host.isEmpty { record.host = host }
        if let server, !server.isEmpty { record.server = String(server.prefix(InstallRecord.nameLimit)) }
        return record != before
    }

    /// A step began, or its state changed. False for a report that changes nothing (a line that the step printed).
    @discardableResult
    public mutating func note(step name: String, state: InstallRecord.StepState, at time: Date = Date()) -> Bool {
        let ends = state == .running ? nil : time
        guard let place = places[name] else {
            // A Mac's installer names its own steps: past the limit a new name is not kept.
            guard record.steps.count < InstallRecord.mostSteps else { return false }
            places[name] = record.steps.count
            record.steps.append(.init(id: .init(named: name), state: state, began: time, ended: ends))
            return true
        }
        guard record.steps[place].state != state else { return false }
        record.steps[place].state = state
        record.steps[place].ended = ends
        return true
    }

    /// The install ended well: every step that still says that it runs is done (the last report of a step can come
    /// after the end, and a Mac's installer reports no end of its order). Only an install that runs ends well: one
    /// that stopped or that its page ended keeps its end.
    @discardableResult
    public mutating func done(at time: Date = Date()) -> Bool {
        guard record.outcome == .running else { return false }
        record.outcome = .done
        record.ended = time
        for place in record.steps.indices where record.steps[place].state == .running {
            record.steps[place].state = .done
            record.steps[place].ended = time
        }
        hides = []
        return true
    }

    /// **The install stopped.** `says` is the line that its caller chose to keep (`InstallRecord.words(of:host:)`: the
    /// app's own words, or none); here it loses the plan's secrets again and is cut. `cause`: the fixed name of the
    /// installer's own reason (`InstallCause`), or nil. An install that its page ended (`cancel`) stays `cancelled`:
    /// the error of the work that it cut off is no stop. The secrets that this log held for that line go with the end,
    /// as the install's own key does.
    @discardableResult
    public mutating func stop(_ stop: InstallRecord.Stop, says: String?, cause: InstallCause? = nil,
                              waitsForNetwork: Bool = false, at time: Date = Date()) -> Bool {
        guard record.outcome != .cancelled else { return false }
        let before = record
        record.outcome = .stopped
        record.ended = time
        record.stop = stop
        record.cause = cause
        record.waitsForNetwork = waitsForNetwork
        record.says = says.map(kept)
        hides = []
        return record != before
    }

    /// **The install runs again by itself** (`InstallRetry`): the try that stopped is counted and the name of its stop
    /// kept, and the steps start again for the next try, which this same record follows. Only an install that runs: a
    /// stop, an end and a cancel come after the last try.
    @discardableResult
    public mutating func retry(after stop: InstallRecord.Stop, cause: InstallCause?) -> Bool {
        guard record.outcome == .running else { return false }
        record.tries = (record.tries ?? 1) + 1
        record.retried = Array(((record.retried ?? []) + [InstallRetry.name(stop: stop, cause: cause)])
            .suffix(InstallRetry.most))
        record.steps = []
        places = [:]
        return true
    }

    /// The page ended an install that ran. One that ended already keeps its end.
    @discardableResult
    public mutating func cancel(at time: Date = Date()) -> Bool {
        guard record.outcome == .running else { return false }
        record.outcome = .cancelled
        record.ended = time
        hides = []
        return true
    }

    /// A Mac's installer went on after its stop (a Try again at that Mac): the same install runs again, from the
    /// step that failed, so that step runs again and a later stop names the step that it stopped at then.
    @discardableResult
    public mutating func goOn() -> Bool {
        guard record.outcome == .stopped else { return false }
        record.outcome = .running
        record.ended = nil
        record.stop = nil; record.says = nil; record.cause = nil; record.waitsForNetwork = false
        for place in record.steps.indices where record.steps[place].state == .failed {
            record.steps[place].state = .running
            record.steps[place].ended = nil
        }
        return true
    }

    /// The line as the record keeps it: without the plan's secrets, on one line, `saysLimit` characters at most.
    private func kept(_ words: String) -> String {
        var line = words
        for secret in hides { line = line.replacingOccurrences(of: secret, with: "(not shown)") }
        line = line.split(whereSeparator: \.isNewline).joined(separator: " ")
        return String(line.prefix(InstallRecord.saysLimit))
    }
}

/// **The records of this Mac's installs** (`KeptRecords`): `Application Support/Founderizer/installs`, one small file
/// for each install.
public typealias InstallRecords = KeptRecords<InstallRecord>

extension InstallRecord: KeptRecord {
    public static let changed = Notification.Name("FleetInstallRecordsChanged")
    public var runs: Bool { outcome == .running }
    public func cutOff() -> InstallRecord {
        var record = self
        record.outcome = .interrupted
        return record
    }
}

private let appInstallRecords = InstallRecords(folder: KeptRecordsPlace.folder("installs"))

extension KeptRecords where Record == InstallRecord {
    /// The app's own records of its installs.
    public static var shared: InstallRecords { appInstallRecords }

    /// The newest install for this hub; with nil, the newest that has no hub's address (a hub's own install that
    /// stopped before its claim: the first run's case).
    public func newest(hub: String?) -> InstallRecord? {
        all().first { $0.hub == hub }
    }

    /// The newest install of this kind, whatever its hub. For a first run: `newest(kind: .hub)` is the last install of
    /// a hub from this Mac, also one that stopped after its claim and so has an address that the app never went to.
    public func newest(kind: InstallRecord.Kind) -> InstallRecord? {
        all().first { $0.kind == kind }
    }

    /// The newest install for this hub that reached the machine at this address.
    public func newest(hub: String?, host: String) -> InstallRecord? {
        all().first { $0.hub == hub && $0.host == host }
    }
}
#endif
