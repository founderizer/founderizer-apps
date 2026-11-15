import Foundation

/// **The facts of `setup_diagnosis`** (the plan "Facts to diagnose a setup that stopped", steps 1 and 2): why the hub does
/// not answer, where the app's window stands, where the app's own builds and install stand, and what the app's kept
/// records say of the last install and of servers that never joined, as fixed names,
/// booleans and counts. This library does not link FleetCore, so the
/// lists are strings here; a test holds each list to the raw values of `ReachFacts` and of the records in FleetCore.
///
/// `SetupBoard` compares this value to move the diagnosis's own change number. The seconds (since the hub's last
/// answer, in a build's stage, in an install's step, since the last install's record changed) and the Tailscale facts
/// are not in it: they are read only when the answer is written, so they never move a number.
public struct SetupDiagnosis: Equatable, Sendable {
    /// The kinds of a failed read (`ReachFacts.ReadKind`).
    public static let failures = ["none", "invalid_address", "refused_this_mac", "not_a_hub", "hub_error", "refused",
                                  "unreadable", "timed_out", "no_connection", "host_not_found", "no_network",
                                  "blocked_by_app", "not_secure", "other"]
    /// Tailscale on this Mac (`ReachFacts.Tailscale`).
    public static let tailscales = ["not_installed", "not_running", "not_signed_in", "not_connected", "connected",
                                    "not_read"]
    /// The hub's device (`ReachFacts.HubDevice`).
    public static let hubDevices = ["online", "offline", "not_in_network", "this_mac", "not_known", "not_read"]
    /// Where the window stands (`ReachFacts.Window`).
    public static let windows = ["first_run", "agent_setup", "add_server", "add_agent", "fleet"]
    /// The stages of a build at a provider (`ReachFacts.BuildStage`, and `FleetCloudModel.Stage` in the app).
    public static let buildStages = ["token", "choosing", "making", "joining"]
    /// What a build's server is for (`CloudServerUse`).
    public static let uses = ["hub", "agent"]
    /// The VPS providers in the order of their cards (`CloudProvider`; `SetupFacts.providers` as a list).
    public static let providers = ["hetzner", "digitalocean", "vultr", "akamai"]
    /// Where an install stands (`ReachFacts.InstallState`).
    public static let installStates = ["none", "running", "stopped", "done"]
    /// What an install installs (`ReachFacts.InstallKind`).
    public static let installKinds = ["hub", "server", "mac"]
    /// The step of an install (`ReachFacts.InstallStepName`): the ids of the two plans, then a Mac's order, `other`
    /// and `none`.
    public static let installSteps = ["read", "network", "code", "plan", "start", "wait_claim", "claim", "wait_ready",
                                      "verify", "join", "order", "other", "none"]
    /// Why an install stopped: `none`, then the app's own kinds of the error that ended it (`InstallRecord.Stop`, in
    /// its order). A kind that this list does not have is given as `other`.
    public static let installStops = ["none", "cannot_start", "installer_stopped", "server_unreached", "login_refused",
                                      "step_failed", "hub_not_ours", "not_root", "timed_out", "no_claim_code",
                                      "no_checklist", "check_stopped", "needs_sudo_password", "needs_ssh_password",
                                      "network_key_refused", "hub_refused", "hub_unreached", "mac_refused",
                                      "mac_unreachable", "mac_unreadable", "other"]
    /// What a kept record of an install is of (`InstallRecord.Kind`): `join` is a server that joins the fleet, which
    /// `installKinds` names `server`.
    public static let lastInstallKinds = ["hub", "join", "mac"]
    /// How a kept record of an install stands or ended (`InstallRecord.Outcome`).
    public static let lastInstallOutcomes = ["running", "done", "stopped", "cancelled", "interrupted"]
    /// What an unjoined build left at its provider (`BuildRecord.AtProvider` without `nothing`, which is no unjoined
    /// build), in the order of the answer's counts.
    public static let unjoinedBuilds = ["server", "left_behind", "not_known"]
    /// The steps of the longest plan (`ReachFacts.longestPlan`): no count is given above it.
    public static let longestPlan = 9

    /// An agent's setup that shows: whether it is the manager, has its server, and has a server that joined for it.
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

    public var hub: SetupFacts.Hub
    /// A name of `failures`.
    public var failure: String
    /// The launch's first read of the hub ended.
    public var readEnded: Bool
    /// The hub answered a read at this launch.
    public var answeredThisLaunch: Bool
    /// This hub's address answered this Mac before, at this launch or an earlier one.
    public var answeredBefore: Bool
    /// The app holds a reading of the fleet, a kept one too.
    public var hasReading: Bool
    /// A name of `windows`.
    public var window: String
    public var agentSetup: AgentSetup?
    /// The first run's build at a provider, and Add server's: nil while that model told nothing.
    public var firstRunBuild: SetupBuild?
    public var addServerBuild: SetupBuild?
    /// This app's own install of a server, nil when the install model has no work and no result.
    public var install: SetupInstall?
    /// **The last install of this fleet that this Mac kept a record of** (`last_install`), or nil with no record. The
    /// answer gives it only while `install` is nil: an install that the model holds is the same install's live
    /// facts, in other names, and two objects for one install would read as two installs. The app's side gives nil
    /// here while `install` is not nil, so that a record's change that no answer shows moves no number.
    public var lastInstall: SetupLastInstall?
    /// The servers that this app asked a provider for and that this Mac never saw join (`builds`).
    public var builds: SetupUnjoinedBuilds
    /// The app's own build and the update channel's offer (`app_build`).
    public var appBuild: SetupAppBuild

    public init(hub: SetupFacts.Hub, failure: String, readEnded: Bool, answeredThisLaunch: Bool, answeredBefore: Bool,
                hasReading: Bool, window: String, agentSetup: AgentSetup?, firstRunBuild: SetupBuild? = nil,
                addServerBuild: SetupBuild? = nil, install: SetupInstall? = nil, lastInstall: SetupLastInstall? = nil,
                builds: SetupUnjoinedBuilds = .none, appBuild: SetupAppBuild = .unknown) {
        self.lastInstall = lastInstall
        self.builds = builds
        self.appBuild = appBuild
        self.hub = hub
        self.failure = failure
        self.readEnded = readEnded
        self.answeredThisLaunch = answeredThisLaunch
        self.answeredBefore = answeredBefore
        self.hasReading = hasReading
        self.window = window
        self.agentSetup = agentSetup
        self.firstRunBuild = firstRunBuild
        self.addServerBuild = addServerBuild
        self.install = install
    }

    /// No store yet: no hub, and the first run.
    public static let unknown = SetupDiagnosis(hub: .none, failure: "none", readEnded: false, answeredThisLaunch: false,
                                               answeredBefore: false, hasReading: false, window: "first_run",
                                               agentSetup: nil)

    /// **The answer of `setup_diagnosis`.** Each value is filtered by its list, as `SetupFacts.json` does, so no free
    /// text can pass: a failure outside its list is `other`, a Tailscale fact `not_read`, a window null, and an agent's
    /// setup is given only with the window `agent_setup`. With no hub the
    /// failure is `none` (the store then holds the failed read of a stand-in address); Tailscale is given only while a
    /// `hub` is `set`; the hub's device only while Tailscale is connected. A name of a build or an install outside its
    /// list is null, and a step or a stop outside its list is `other`; the counts are capped, and the seconds are given
    /// only while a build is past `token` or an install runs. `last_install` is given only while `install` is null.
    /// `diskBuild`: the build of the app's bundle on the disk,
    /// read when the answer is written, or nil.
    public func json(change: Int64, noChange: Bool = false, network: SetupNetwork = .notRead,
                     secondsSinceAnswer: Int? = nil, workSeconds: SetupWorkSeconds = .none,
                     diskBuild: Int? = nil) -> JSONValue {
        let failure = hub == .none ? "none" : Self.failures.contains(self.failure) ? self.failure : "other"
        let read = hub == .set ? network : .notRead
        let tailscale = Self.tailscales.contains(read.tailscale) ? read.tailscale : "not_read"
        let device = tailscale == "connected" && Self.hubDevices.contains(read.hubDevice) ? read.hubDevice : "not_read"
        let seconds = answeredThisLaunch ? secondsSinceAnswer.flatMap { $0 >= 0 ? JSONValue.int(Int64($0)) : nil } : nil
        var answer: [String: JSONValue] = [
            "change": .int(change),
            "hub": .string(hub.rawValue),
            "hub_read": .object([
                "failure": .string(failure),
                "read_ended": .bool(readEnded),
                "answered_this_launch": .bool(answeredThisLaunch),
                "answered_before": .bool(answeredBefore),
                "has_reading": .bool(hasReading),
                "seconds_since_answer": seconds ?? .null,
            ]),
            "tailscale": .string(tailscale),
            "hub_device": .string(device),
            "window": Self.windows.contains(window) ? .string(window) : .null,
            "agent_setup": window != "agent_setup" ? .null : agentSetup.map { .object(["manager": .bool($0.manager), "placed": .bool($0.placed),
                                                     "server_joined": .bool($0.serverJoined)]) } ?? .null,
            "first_run_build": firstRunBuild.map { $0.json(seconds: workSeconds.firstRunBuild) } ?? .null,
            "add_server_build": addServerBuild.map { $0.json(seconds: workSeconds.addServerBuild) } ?? .null,
            "install": install.map { $0.json(seconds: workSeconds.install) } ?? .null,
            "last_install": install != nil ? .null
                : lastInstall.map { $0.json(seconds: workSeconds.lastInstall) } ?? .null,
            "builds": builds.json(seconds: workSeconds.unjoinedBuild),
            "app_build": appBuild.json(onDisk: diskBuild),
        ]
        if noChange { answer["no_change"] = .bool(true) }
        return .object(answer)
    }
}

/// A name of `list`, or null.
private func named(_ value: String?, in list: [String]) -> JSONValue {
    value.flatMap { list.contains($0) ? .string($0) : nil } ?? .null
}

/// A count of seconds of 0 or more, or null.
private func seconds(_ value: Int?) -> JSONValue {
    value.flatMap { $0 >= 0 ? .int(Int64($0)) : nil } ?? .null
}

/// **A build at a provider, as the app's model of it stands**: names of `SetupDiagnosis`'s lists. `stoppedAt` is kept
/// after the page cleared its stop, until a new try starts; `stopShows` says whether the model still holds it (its page can be closed).
public struct SetupBuild: Equatable, Sendable {
    public var stage: String
    public var stoppedAt: String?
    public var stopShows: Bool
    public var use: String
    public var provider: String?

    public init(stage: String, stoppedAt: String?, stopShows: Bool, use: String, provider: String?) {
        self.stage = stage
        self.stoppedAt = stoppedAt
        self.stopShows = stopShows
        self.use = use
        self.provider = provider
    }

    func json(seconds given: Int?) -> JSONValue {
        let stage = named(stage, in: SetupDiagnosis.buildStages)
        let stopped = named(stoppedAt, in: SetupDiagnosis.buildStages)
        return .object([
            "stage": stage,
            "stopped_at": stopped,
            // A stop that shows is a stop that is known.
            "stop_shows": .bool(stopShows && stopped != .null),
            "use": named(use, in: SetupDiagnosis.uses),
            "provider": named(provider, in: SetupDiagnosis.providers),
            "seconds_in_stage": stage == .null || stage == .string("token") ? .null : seconds(given),
        ])
    }
}

/// A count of an install's steps: 0 to the longest plan.
private func steps(_ count: Int) -> JSONValue {
    .int(Int64(min(max(count, 0), SetupDiagnosis.longestPlan)))
}

/// **This app's own install of a server**: names of `SetupDiagnosis`'s lists, a boolean and two counts. The stop is
/// the app's own kind of the error that ended the install; the stop's words stay in the app and are not in it.
public struct SetupInstall: Equatable, Sendable {
    public var state: String
    public var kind: String
    public var step: String
    public var stop: String
    /// The install stopped only because the server is not on the owner's private network, and its page asks for the
    /// network's connection.
    public var waitsForNetwork: Bool
    public var stepsDone: Int
    public var stepsPlanned: Int

    public init(state: String, kind: String, step: String, stop: String, waitsForNetwork: Bool = false,
                stepsDone: Int, stepsPlanned: Int) {
        self.state = state
        self.kind = kind
        self.step = step
        self.stop = stop
        self.waitsForNetwork = waitsForNetwork
        self.stepsDone = stepsDone
        self.stepsPlanned = stepsPlanned
    }

    func json(seconds given: Int?) -> JSONValue {
        let state = named(state, in: SetupDiagnosis.installStates)
        return .object([
            "state": state,
            "kind": named(kind, in: SetupDiagnosis.installKinds),
            "step": .string(SetupDiagnosis.installSteps.contains(step) ? step : "other"),
            // Only an install that stopped has a stop's kind, and only a stop waits for the network.
            "stop": .string(state != .string("stopped") ? "none"
                            : SetupDiagnosis.installStops.contains(stop) ? stop : "other"),
            "waits_for_network": .bool(waitsForNetwork && state == .string("stopped")),
            "steps_done": steps(stepsDone),
            "steps_planned": steps(stepsPlanned),
            "seconds_in_step": state == .string("running") ? seconds(given) : .null,
        ])
    }
}

/// **The last install of this fleet that this Mac kept a record of** (`InstallRecord`, by the rule
/// `ReachFacts.lastRecord`): names of `SetupDiagnosis`'s lists, a boolean and two counts. Never the record's hub, its
/// addresses, its server's name, its id or its page's line.
public struct SetupLastInstall: Equatable, Sendable {
    /// A name of `lastInstallKinds`.
    public var kind: String
    /// A name of `lastInstallOutcomes`.
    public var outcome: String
    /// The step where it stood, a name of `installSteps`.
    public var step: String
    /// A name of `installStops`.
    public var stop: String
    public var waitsForNetwork: Bool
    public var stepsDone: Int
    public var stepsPlanned: Int

    public init(kind: String, outcome: String, step: String, stop: String, waitsForNetwork: Bool = false,
                stepsDone: Int, stepsPlanned: Int) {
        self.kind = kind
        self.outcome = outcome
        self.step = step
        self.stop = stop
        self.waitsForNetwork = waitsForNetwork
        self.stepsDone = stepsDone
        self.stepsPlanned = stepsPlanned
    }

    func json(seconds given: Int?) -> JSONValue {
        let outcome = named(outcome, in: SetupDiagnosis.lastInstallOutcomes)
        // Only a record that says stopped has a stop.
        let stopped = outcome == .string("stopped")
        return .object([
            "kind": named(kind, in: SetupDiagnosis.lastInstallKinds),
            "outcome": outcome,
            "step": .string(SetupDiagnosis.installSteps.contains(step) ? step : "other"),
            "stop": .string(!stopped ? "none" : SetupDiagnosis.installStops.contains(stop) ? stop : "other"),
            "waits_for_network": .bool(waitsForNetwork && stopped),
            "steps_done": steps(stepsDone),
            "steps_planned": steps(stepsPlanned),
            "seconds_ago": seconds(given),
        ])
    }
}

/// **The servers that this app asked a provider for and that this Mac never saw join** (`BuildRecord.isUnjoined`, by
/// the rule `ReachFacts.unjoined`), as counts by what each build left at its provider. Never a server's name, the
/// provider's id, a provider or a hub.
public struct SetupUnjoinedBuilds: Equatable, Sendable {
    /// The most that one count says: the app keeps the newest 40 records.
    public static let most = 99

    /// The provider answered with the server.
    public var server: Int
    /// A step failed after the provider made something, and the app could not delete all of it.
    public var leftBehind: Int
    /// The app does not know what the call for the server left.
    public var notKnown: Int

    public init(server: Int, leftBehind: Int, notKnown: Int) {
        self.server = server
        self.leftBehind = leftBehind
        self.notKnown = notKnown
    }

    public static let none = SetupUnjoinedBuilds(server: 0, leftBehind: 0, notKnown: 0)

    /// `seconds`: since the last change of the newest of these records, given only with a count above 0.
    func json(seconds: Int? = nil) -> JSONValue {
        let counts = [server, leftBehind, notKnown].map { min(max($0, 0), Self.most) }
        let all = counts.reduce(0, +)
        var answer: [String: JSONValue] = ["unjoined": .int(Int64(all))]
        for (name, count) in zip(SetupDiagnosis.unjoinedBuilds, counts) { answer[name] = .int(Int64(count)) }
        answer["newest_seconds_ago"] = all > 0 ? seconds.flatMap { $0 >= 0 ? .int(Int64($0)) : nil } ?? .null : .null
        return .object(answer)
    }
}

/// **The app's own build, and whether a newer one waits** (`app_build` of `setup_diagnosis`). `running`, `offered` and
/// `installing` come from the app's memory and move the diagnosis's number; the build on the disk is read when the
/// answer is written (`SetupBoard`'s `diskBuild`), as the seconds are, so it moves no number.
public struct SetupAppBuild: Equatable, Sendable {
    /// The states, in the order of the rule.
    public static let states = ["waits_for_restart", "installing", "offered", "current"]

    /// The build number of the process that runs, or nil when its bundle does not say.
    public var running: Int?
    /// A build that the update channel offers (the one that installs itself, the one that the channel's last read
    /// offered, or the one that waited when the app last quit), or nil.
    public var offered: Int?
    /// The app's own update downloads, checks or installs a build now.
    public var installing: Bool

    public init(running: Int?, offered: Int?, installing: Bool) {
        self.running = running
        self.offered = offered
        self.installing = installing
    }

    public static let unknown = SetupAppBuild(running: nil, offered: nil, installing: false)

    /// The offered build only while it is newer than the one that runs.
    public var newerOffered: Int? {
        guard let offered, let running, running > 0, offered > running else { return nil }
        return offered
    }

    /// **The rule**: `waits_for_restart` when the build on the disk is newer than the one that runs (an update is in
    /// place and the app still runs the old build); else `installing` while the update that the owner started with
    /// the window of the sidebar's Update works (`UpdateDialog`, `AppAutoUpdate.pressInstall`). The app's side gives no
    /// more: its automatic install and the press in the window of Check for Updates… (`UpdateCheck`) are not readable
    /// from the store, so they show as `offered`
    /// while they install, and as `waits_for_restart` when the build is in place; else `offered`
    /// when the channel offers a newer build; else `current`.
    public static func state(running: Int?, onDisk: Int?, offered: Int?, installing: Bool) -> String {
        // A build number of 0 or less says no build.
        let running = running.flatMap { $0 > 0 ? $0 : nil }, onDisk = onDisk.flatMap { $0 > 0 ? $0 : nil }
        if let running, let onDisk, onDisk > running { return "waits_for_restart" }
        if installing { return "installing" }
        if SetupAppBuild(running: running, offered: offered, installing: false).newerOffered != nil { return "offered" }
        return "current"
    }

    func json(onDisk: Int?) -> JSONValue {
        let number = { (value: Int?) in value.flatMap { $0 > 0 ? JSONValue.int(Int64($0)) : nil } ?? .null }
        return .object([
            "running": number(running),
            "on_disk": number(onDisk),
            "offered": number(newerOffered),
            "state": .string(Self.state(running: running, onDisk: onDisk, offered: offered, installing: installing)),
        ])
    }
}

/// **The seconds of the app's own work**, read when the answer is written and never compared, as the seconds since
/// the hub's last answer are.
public struct SetupWorkSeconds: Equatable, Sendable {
    public var firstRunBuild: Int?
    public var addServerBuild: Int?
    public var install: Int?
    /// Since the last change of the last install's record (`last_install.seconds_ago`).
    public var lastInstall: Int?
    /// Since the last change of the newest record of a server that did not join (`builds.newest_seconds_ago`).
    public var unjoinedBuild: Int?

    public init(firstRunBuild: Int? = nil, addServerBuild: Int? = nil, install: Int? = nil, lastInstall: Int? = nil,
                unjoinedBuild: Int? = nil) {
        self.firstRunBuild = firstRunBuild
        self.addServerBuild = addServerBuild
        self.install = install
        self.lastInstall = lastInstall
        self.unjoinedBuild = unjoinedBuild
    }

    public static let none = SetupWorkSeconds()
}

/// **What Tailscale on this Mac says**, read at the answer and never compared: names of `SetupDiagnosis.tailscales` and
/// `SetupDiagnosis.hubDevices`.
public struct SetupNetwork: Equatable, Sendable {
    public var tailscale: String
    public var hubDevice: String

    public init(tailscale: String, hubDevice: String) {
        self.tailscale = tailscale
        self.hubDevice = hubDevice
    }

    public static let notRead = SetupNetwork(tailscale: "not_read", hubDevice: "not_read")
}
