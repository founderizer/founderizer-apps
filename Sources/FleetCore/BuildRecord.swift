#if os(macOS)
import Foundation

/// **One server that this Mac asked a provider to make, kept after its page is gone** (the owner's "Yes, build it" of
/// 15 November 2026 to "Do you want me to build the kept record of a server that the app made now?"). A server that
/// was made and never joined exists at its provider and is billed, and at the next try nothing said so: the model that
/// made it forgets a stop when its page opens again, and a first run kept nothing of it at all.
///
/// **A record exists only from the moment the call for the server begins.** A try that stopped before that (no SSH
/// key, no key of the private network) leaves none. What the call left at the provider is in the record
/// (`atProvider`): the server, something that the app could not delete after a failed step, nothing, or not known.
/// So each record that did not end in a join and that did not leave nothing (`isUnjoined`) is a server that can stand
/// at its provider.
///
/// The server's name and the provider's id stay on this Mac, for the owner's own eyes. A reader for another program
/// gives the fixed names, the counts and the times, and never `name`, `serverID`, `hub` or `id`. The record stands
/// beside `MadeServers`, which `CloudExisting.reuse` reads and which stays as it is.
public struct BuildRecord: Codable, Equatable, Sendable, Identifiable {
    /// The stage that the try reached (`FleetCloudModel.Stage`, the two of a build).
    public enum Stage: String, Codable, CaseIterable, Sendable {
        /// The provider was asked for the server.
        case making
        /// The provider made it, and this Mac waited for it on the private network.
        case joining
    }

    /// How the build stands or ended. **`interrupted` is never written**: `KeptRecords` gives it for a record that says
    /// `running` and that another start of the app wrote.
    public enum Outcome: String, Codable, CaseIterable, Sendable {
        case running, joined, stopped, cancelled, interrupted
    }

    /// **What the build left at the provider, as far as this Mac knows.**
    public enum AtProvider: String, Codable, CaseIterable, Sendable {
        /// The call for the server has no answer that this Mac knows: it runs, the app ended in it, the provider
        /// could not be reached, or its answer was not understood. A server can be there.
        case notKnown = "not_known"
        /// Nothing: the call was not sent, the provider refused it, or the app deleted what the provider had made
        /// (also when the build's page ended it while the app waited for the new server to come up). **One case is
        /// not told apart**: a provider's own fault answer (a 502) is a refusal to this app (`CloudError.refused`),
        /// and a provider can have made the server all the same.
        case nothing
        /// A step failed after the provider made something, and the app could not delete all of it: the server, its
        /// firewall, or both (`CloudError.leftBehind`).
        case leftBehind = "left_behind"
        /// The server is at the provider: the provider answered with its id, or an install from this Mac proved the
        /// server later (`noteJoined`; no id is known then).
        case server

        /// What a call that ended with this error left (`CloudServers.createServer`, which deletes what it made when a
        /// later step fails, and says `leftBehind` when it could not).
        public static func after(_ error: Error) -> AtProvider {
            // A build that its page ended leaves the call only from the wait for the new server to come up, and the
            // call then deletes what it made: it gives the cancel back only when nothing is left, else `leftBehind`.
            // A cancel while the request itself is on its way comes as `unreachable`.
            if error is CancellationError { return .nothing }
            guard let error = error as? CloudError else { return .notKnown }
            switch error {
            case .leftBehind: return .leftBehind
            case .unreachable, .notUnderstood: return .notKnown
            case .notAToken, .noToken, .tokenNotAccepted, .readOnlyToken, .rateLimited, .refused, .noRoom, .taken, .notReady,
                 .notAServerName, .notAPublicKey, .notAnAuthKey: return .nothing
            }
        }
    }

    public let id: UUID
    /// The start of the app that wrote this record (`AppLaunch.id`).
    public let launch: String
    public let provider: CloudProvider
    public let use: CloudServerUse
    /// The address of the hub that the server was made for, in the app's own form (`FleetStore.hub.absoluteString`).
    /// A first run's server is made before any hub exists: its record has none until the server is on the private
    /// network, and gets the hub's address to be there (`joined(at:hub:)`): the server's own address on that network
    /// at the hub's port, which is the address that the claim then gives the app.
    public internal(set) var hub: String?
    /// The server's name, for the owner's own eyes on this Mac.
    public let name: String
    /// The provider's own id of the server, once the provider answered with it.
    public internal(set) var serverID: String?
    public internal(set) var stage: Stage
    public internal(set) var atProvider: AtProvider
    /// The private network's own list had the server, and this Mac did not see it: a rule of the network keeps it from
    /// this Mac (`FleetReach.keeps`).
    public internal(set) var onNetwork: Bool
    public let began: Date
    /// When the provider answered with the server.
    public internal(set) var madeAt: Date?
    /// The provider's name of the server's type ("cx23"), and what it costs a month in which currency, as the
    /// provider said them when it made the server. For the owner's eyes, on the page that deletes the server.
    public internal(set) var type: String?
    public internal(set) var monthlyPrice: Decimal?
    public internal(set) var currency: String?
    /// nil while it runs, and for a build that was cut off (`interrupted`): `lastChange` is its last sign.
    public internal(set) var ended: Date?
    public internal(set) var outcome: Outcome

    /// The provider is asked for the server now.
    public init(id: UUID = UUID(), provider: CloudProvider, use: CloudServerUse, hub: String?, name: String,
                launch: String = AppLaunch.id, at began: Date = Date()) {
        self.id = id
        self.launch = launch
        self.provider = provider
        self.use = use
        self.hub = hub
        self.name = name
        serverID = nil
        stage = .making
        atProvider = .notKnown
        onNetwork = false
        self.began = began
        madeAt = nil
        ended = nil
        outcome = .running
    }

    /// The provider answered with the server: it exists there, and this Mac waits for it on the private network.
    public mutating func made(id: String, type: String? = nil, monthlyPrice: Decimal? = nil, currency: String? = nil,
                              at time: Date = Date()) {
        guard outcome == .running, stage == .making else { return }
        serverID = id
        stage = .joining
        atProvider = .server
        madeAt = time
        self.type = type; self.monthlyPrice = monthlyPrice; self.currency = currency
    }

    /// The call for the server ended with an error: what it left at the provider (`AtProvider.after`). Only for the
    /// call itself: a server that was made is there whatever fails after it.
    public mutating func callEnded(with error: Error) {
        guard outcome == .running, stage == .making else { return }
        atProvider = .after(error)
    }

    /// This Mac saw the server on the private network: its install goes on from here. Also for a server that a later
    /// install proved (`KeptRecords.noteJoined`): a server that joined is at the provider, whatever was known before.
    ///
    /// `hub`: for a first run's server, the address that its hub will have (the record had none). A record that has
    /// its hub keeps it.
    public mutating func joined(at time: Date = Date(), hub: String? = nil) {
        guard outcome != .joined else { return }
        outcome = .joined
        if atProvider != .server { atProvider = .server }
        if self.hub == nil, let hub, !hub.isEmpty { self.hub = hub }
        ended = time
    }

    /// The build ended with no join that this Mac saw: it stopped, or its page ended it (`cancelled`). `onNetwork`:
    /// the private network's own list had the server. A build that joined keeps its end.
    public mutating func end(cancelled: Bool = false, onNetwork: Bool = false, at time: Date = Date()) {
        guard outcome == .running else { return }
        outcome = cancelled ? .cancelled : .stopped
        self.onNetwork = onNetwork
        ended = time
    }

    /// **The server can stand at its provider with no place in a fleet**: this Mac never saw it join, and the build
    /// did not leave nothing there (`atProvider`).
    public var isUnjoined: Bool {
        switch outcome {
        case .stopped, .cancelled, .interrupted: atProvider != .nothing
        case .running, .joined: false
        }
    }

    /// The provider answered with the server's id, so the server exists there for sure (`atProvider` is `server`).
    /// False says no more than that: `atProvider` says whether something was left, nothing, or that it is not known.
    public var isMade: Bool { serverID != nil }

    /// The newest time in the record: the last sign of a build that was cut off and has no end.
    public var lastChange: Date { max(began, max(madeAt ?? began, ended ?? began)) }
}

extension BuildRecord: KeptRecord {
    public static let changed = Notification.Name("FleetBuildRecordsChanged")
    public var runs: Bool { outcome == .running }
    public func cutOff() -> BuildRecord {
        var record = self
        record.outcome = .interrupted
        return record
    }
}

/// **The records of the servers that this Mac asked a provider for** (`KeptRecords`): `Application
/// Support/Founderizer/builds`, one small file for each.
public typealias BuildRecords = KeptRecords<BuildRecord>

private let appBuildRecords = BuildRecords(folder: KeptRecordsPlace.folder("builds"))

extension KeptRecords where Record == BuildRecord {
    /// The app's own records of the servers that it asked a provider for.
    public static var shared: BuildRecords { appBuildRecords }

    /// The newest build for this hub; with nil, the newest of a first run, which has no hub yet.
    public func newest(hub: String?) -> BuildRecord? {
        all().first { $0.hub == hub }
    }

    /// **The servers made for this hub that this Mac never saw join**, newest first; with nil, the ones of a first
    /// run. Each can stand at its provider and be billed.
    public func unjoined(hub: String?) -> [BuildRecord] {
        all().filter { $0.hub == hub && $0.isUnjoined }
    }

    /// **An install from this Mac ended for a server of this name in this hub**: when the newest build of that name
    /// for that hub did not end in a join, it did join after all, and says so. Only the newest build of the name that
    /// left something at the provider is looked at, whatever its outcome: a new try gets the same name while the
    /// server of the try before it is not on the network, so an older build of the name is another server, which this
    /// install proves nothing of. A try that left nothing (the provider refused the name) is no server, so it is
    /// passed over. A name is all that links an install and a build (the private network gives the server the name
    /// that its build gave it, unless that name was taken there meanwhile: then no build is closed, and the record
    /// stays).
    public func noteJoined(name: String, hub: String?, at time: Date = Date()) {
        guard var record = all().first(where: {
            $0.hub == hub && $0.name.lowercased() == name.lowercased() && $0.atProvider != .nothing
        }), record.outcome != .joined, record.outcome != .running else { return }
        record.joined(at: time)
        write(record)
    }

    /// **An install from this Mac ended on a server that the owner took from its provider's list** ("Use this
    /// server"), by the provider's own id of that server: an exact proof, where `noteJoined(name:hub:)` has only a name
    /// and a hub. A first run's server that stopped before this Mac saw it on the private network has no hub in its
    /// record, so the install that took it later found no record by name and hub: the record stayed "never joined",
    /// and "Start again" never saw the server (found by the lane "Unfinished setup" on 15 November 2026). The newest
    /// record of that server says that it joined, with the hub that the install proved: the id proves the server, and
    /// the install proves the fleet that it is in now. A build that still runs is left to its own end.
    public func noteJoined(serverID: String, provider: CloudProvider, hub: String, at time: Date = Date()) {
        guard !serverID.isEmpty, !hub.isEmpty,
              var record = all().first(where: { $0.provider == provider && $0.serverID == serverID }),
              record.outcome != .running, record.outcome != .joined || record.hub != hub else { return }
        record.hub = hub
        record.joined(at: time)
        write(record)
    }
}
#endif
