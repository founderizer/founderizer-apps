import Foundation

/// **The facts of `setup_diagnosis`, as fixed kinds** (the plan "Facts to diagnose a setup that stopped", step 1): why
/// the last read of the hub failed, where Tailscale on this Mac stands, what Tailscale says of the hub's device, and
/// where the app's window stands. Each is a case of a fixed list, never a line of words, an address or a name, so that
/// the owner's own agent can read them and no free text reaches it. The link's program does not link this library: its
/// lists are strings in `FleetOwnerAPI`, and a test holds each one to the raw values here.
public enum ReachFacts {
    /// **Why the last read of the hub failed**, one kind for each line of `HubReach.words` that has its own words.
    public enum ReadKind: String, CaseIterable, Sendable {
        /// The last read answered, or there was none.
        case none
        /// The app refused a typed text as a hub's address and kept its old address.
        case invalidAddress = "invalid_address"
        /// The hub answered 403: it serves the owner's own address only, and this Mac is not it.
        case refusedThisMac = "refused_this_mac"
        /// Something answered 404: it is no Founderizer hub.
        case notAHub = "not_a_hub"
        /// The hub answered with a status of 500 to 599: it fails or starts.
        case hubError = "hub_error"
        /// The hub refused with any other status.
        case refused
        /// The hub's answer could not be read: the hub and the app are of different versions.
        case unreadable
        /// The read waited its whole limit.
        case timedOut = "timed_out"
        /// The connection was refused, lost, or never made.
        case noConnection = "no_connection"
        /// This Mac cannot find the hub's host.
        case hostNotFound = "host_not_found"
        /// This Mac has no network.
        case noNetwork = "no_network"
        /// The app itself refused a plain connection.
        case blockedByApp = "blocked_by_app"
        /// A secure connection failed.
        case notSecure = "not_secure"
        /// Any other failure, a cancelled read included.
        case other
    }

    /// **Tailscale on this Mac.** `notRead` when it was not read (no hub to find, a read that hung, output that is no
    /// status), so that a read that failed is never taken for a fact.
    public enum Tailscale: String, CaseIterable, Sendable {
        case notInstalled = "not_installed"
        case notRunning = "not_running"
        case notSignedIn = "not_signed_in"
        case notConnected = "not_connected"
        case connected
        case notRead = "not_read"
    }

    /// **The hub's device, as this Mac's Tailscale sees it.** `online` can be minutes old; `offline` is sure.
    public enum HubDevice: String, CaseIterable, Sendable {
        case online, offline
        /// No device of this Mac's network has the hub's address.
        case notInNetwork = "not_in_network"
        /// The hub's address is this Mac's own.
        case thisMac = "this_mac"
        /// The hub's host is no Tailscale address (a name, or an address outside 100.64.0.0/10).
        case notKnown = "not_known"
        /// Tailscale was not read, or this Mac is not connected.
        case notRead = "not_read"
    }

    /// **Tailscale's two facts**, as one value that a `KeptFlight` keeps.
    public struct NetworkFacts: Equatable, Sendable {
        public var tailscale: Tailscale
        public var hubDevice: HubDevice

        public init(tailscale: Tailscale, hubDevice: HubDevice) {
            self.tailscale = tailscale
            self.hubDevice = hubDevice
        }
    }

    /// **Where the app's window stands, or would open when it is closed.**
    public enum Window: String, CaseIterable, Sendable {
        case firstRun = "first_run"
        case agentSetup = "agent_setup"
        case addServer = "add_server"
        case addAgent = "add_agent"
        case fleet
    }

    // ------------------------------------------------------------ a failed read

    /// **The kind of a failed read**: an exhaustive switch over `HubError`, the `URLError` codes that `HubReach.words`
    /// names, and a `DecodingError` of the state's decode. A new case of `HubError` fails the build here.
    public static func readKind(_ error: Error?) -> ReadKind {
        guard let error else { return .none }
        if let refusal = error as? HubError {
            switch refusal {
            case .invalidAddress: return .invalidAddress
            case .invalidResponse: return .unreadable
            case .unavailable: return .noConnection
            case .refusal(let status, _):
                if status == 403 { return .refusedThisMac }
                if status == 404 { return .notAHub }
                return (500...599).contains(status) ? .hubError : .refused
            }
        }
        if error is DecodingError { return .unreadable }
        guard let reason = error as? URLError else { return .other }
        switch reason.code {
        case .appTransportSecurityRequiresSecureConnection: return .blockedByApp
        case .cannotFindHost, .dnsLookupFailed: return .hostNotFound
        case .cannotConnectToHost, .networkConnectionLost: return .noConnection
        case .notConnectedToInternet: return .noNetwork
        case .timedOut: return .timedOut
        case .secureConnectionFailed, .serverCertificateUntrusted: return .notSecure
        default: return .other
        }
    }

    // ------------------------------------------------------------ where the window stands

    /// The page that the window shows, from the store's plain values.
    public enum Page: Equatable, Sendable {
        case addServer, addAgent
        /// An agent's own setup (`AgentSetupWizard`) shows in place of its chat or its settings.
        case agentSetup(AgentSetup)
        /// Any other page of the fleet.
        case other
    }

    /// **An agent's setup**: whether the agent is the manager, has a server of its own, and has a server that joined
    /// for it on this Mac. With `placed` and `serverJoined` false the owner sees the page "Manager's server".
    public struct AgentSetup: Equatable, Sendable {
        public var manager: Bool
        public var placed: Bool
        public var serverJoined: Bool

        public init(manager: Bool, placed: Bool, serverJoined: Bool) {
            self.manager = manager
            self.placed = placed
            self.serverJoined = serverJoined
        }
    }

    /// **The window and the agent's setup**, by the rules that `FleetView` draws by. The first run fills the window,
    /// except while a page of Settings shows (`settings`: Add server and a server's page are pages of Settings too).
    /// Add agent needs a reading: with none the app shows its waiting page, which counts as `fleet`, as Settings does.
    /// `welcomeCovers`: the first run's welcome page stands in front of a manager's setup that never finished
    /// (`FleetStore.welcomeCovers`): the window shows that page of the first run and not the agent's setup behind it,
    /// also while the window is closed and no page of the first run tells the app that it shows.
    public static func window(firstRun: Bool, settings: Bool, hasReading: Bool, page: Page,
                              welcomeCovers: Bool = false) -> (window: Window, agentSetup: AgentSetup?) {
        if (firstRun && !settings) || welcomeCovers { return (.firstRun, nil) }
        switch page {
        case .addServer: return (.addServer, nil)
        case .addAgent: return hasReading ? (.addAgent, nil) : (.fleet, nil)
        case .agentSetup(let setup): return (.agentSetup, setup)
        case .other: return (.fleet, nil)
        }
    }
}

// ------------------------------------------------------------ one read for all callers

/// **One run for all callers, and its result kept for a time** (the Tailscale read of `setup_diagnosis`): a caller that
/// comes while a run for the same key is on its way waits for that run, and a result, a failed one too, is given again
/// for that key until `keep` seconds of `now` went by. So a caller in a loop starts one run in `keep` seconds at most.
/// The run gives the finished value (for Tailscale: the two facts for the hub's host), so a read is parsed once, not
/// once for each caller; a call for another key runs again. A caller whose task is cancelled gets nil: before a run,
/// it starts none. `now` is the uptime in the app; a test gives its own clock.
public actor KeptFlight<Key: Equatable & Sendable, Value: Sendable> {
    private let run: @Sendable (Key) async -> Value
    private let now: @Sendable () -> TimeInterval
    private let keep: TimeInterval
    private var kept: (key: Key, value: Value, at: TimeInterval)?
    private var running: (key: Key, task: Task<Value, Never>)?
    /// The runs that started: for a test.
    public private(set) var runs = 0

    public init(keep: TimeInterval = 10,
                now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                run: @escaping @Sendable (Key) async -> Value) {
        self.keep = keep
        self.now = now
        self.run = run
    }

    public func value(for key: Key) async -> Value? {
        if Task.isCancelled { return nil }
        if let kept, kept.key == key, now() - kept.at < keep { return kept.value }
        let task: Task<Value, Never>
        if let running, running.key == key {
            task = running.task
        } else {
            let run = self.run
            task = Task.detached { await run(key) }
            running = (key, task)
            runs += 1
        }
        let value = await task.value
        if running?.task == task {
            kept = (key, value, now())
            running = nil
        }
        return Task.isCancelled ? nil : value
    }
}

#if os(macOS)
extension ReachFacts {
    /// **How one read of `tailscale status --json` ended**, with its output (stdout and stderr in one pipe).
    public struct TailscaleRead: Equatable, Sendable {
        public enum End: Equatable, Sendable {
            /// No `tailscale` command on this Mac.
            case noCommand
            /// The command could not start.
            case cannotStart
            /// The read was ended at its limit.
            case ended
            /// The command exited with this status.
            case exited(Int32)
        }

        public var end: End
        public var output: String

        public init(end: End, output: String = "") {
            self.end = end
            self.output = output
        }
    }

    /// The limit of one read. With the 5 seconds after the end signal and the 5 for the reader, one read takes about 15
    /// seconds at most.
    public static let tailscaleLimit: Double = 5

    /// **One read of this Mac's Tailscale**: one local process, off the main thread (`LocalShell` runs it on a queue
    /// of its own). `run` and `now` stand in for a test.
    public static func readTailscale(limit: Double = tailscaleLimit,
                                     command: String? = MacNetwork.command(),
                                     now: @Sendable () -> Date = Date.init,
                                     run: @Sendable (String, [String], Double) async throws -> LocalShell.Answer = {
                                         try await LocalShell.run($0, $1, timeout: $2)
                                     }) async -> TailscaleRead {
        guard let command else { return TailscaleRead(end: .noCommand) }
        let start = now()
        guard let answer = try? await run("/usr/bin/env", ["TAILSCALE_BE_CLI=1", command, "status", "--json"],
                                          limit) else {
            return TailscaleRead(end: .cannotStart)
        }
        return ended(answer, took: now().timeIntervalSince(start), limit: limit)
    }

    /// **The two facts for the hub's host**, from one read and one parse: the run of the app's `KeptFlight`.
    public static func readNetwork(hubHost: String?) async -> NetworkFacts {
        let found = network(await readTailscale(), hubHost: hubHost)
        return NetworkFacts(tailscale: found.tailscale, hubDevice: found.hubDevice)
    }

    /// **A read that ran to its limit counts as ended there**, whatever status its kill gave. Its length is measured
    /// by `Date`, the clock by which `LocalShell` ends it, so that a Mac that slept during the read does not turn a
    /// killed read into one that failed by itself.
    public static func ended(_ answer: LocalShell.Answer, took: TimeInterval, limit: Double) -> TailscaleRead {
        if !answer.ok && took >= limit { return TailscaleRead(end: .ended, output: answer.output) }
        return TailscaleRead(end: .exited(answer.status), output: answer.output)
    }

    /// **Tailscale's state and the hub's device from one read**, for the hub's host. The output is parsed from its
    /// first `{`, because a warning line can stand before it. A read that was ended is `notRead`; another failed exit
    /// is `notRunning` (the command's own answer when its service does not run); an exit of 0 with no status in it is
    /// `notRead`. Never `notSignedIn` for a read that failed. The device is read only when this Mac is connected.
    public static func network(_ read: TailscaleRead, hubHost: String?) -> (tailscale: Tailscale, hubDevice: HubDevice) {
        switch read.end {
        case .noCommand: return (.notInstalled, .notRead)
        case .cannotStart, .ended: return (.notRead, .notRead)
        case .exited(let status) where status != 0: return (.notRunning, .notRead)
        case .exited: break
        }
        guard let brace = read.output.firstIndex(of: "{") else { return (.notRead, .notRead) }
        let json = String(read.output[brace...])
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["BackendState"] is String else { return (.notRead, .notRead) }
        let tailscale: Tailscale
        switch MacNetwork.reading(json).step {
        case .connected: tailscale = .connected
        case .notConnected: tailscale = .notConnected
        case .notSignedIn: tailscale = .notSignedIn
        case .notInstalled: tailscale = .notInstalled
        }
        guard tailscale == .connected else { return (tailscale, .notRead) }
        return (tailscale, device(of: hubHost, in: object))
    }

    /// The hub's device, matched against each node's own `TailscaleIPs` here: `FleetOnTailscale.devices` drops a node
    /// with no MagicDNS name, which would make a hub that is in the network `notInNetwork`. When this Mac's own node
    /// says that it is not online (a Mac with no network whose Tailscale still says Running), the peers' marks are old,
    /// so the device is `notRead`.
    private static func device(of host: String?, in object: [String: Any]) -> HubDevice {
        guard let host = host?.lowercased(), ClaimCode.isPrivateAddress(host) else { return .notKnown }
        let own = object["Self"] as? [String: Any]
        if own?["Online"] as? Bool == false { return .notRead }
        if ((own?["TailscaleIPs"] as? [String]) ?? []).map({ $0.lowercased() }).contains(host) { return .thisMac }
        let peers = (object["Peer"] as? [String: Any])?.values.compactMap { $0 as? [String: Any] } ?? []
        let found = peers.filter { (($0["TailscaleIPs"] as? [String]) ?? []).map { $0.lowercased() }.contains(host) }
        guard !found.isEmpty else { return .notInNetwork }
        return found.contains { $0["Online"] as? Bool == true } ? .online : .offline
    }
}
#endif
