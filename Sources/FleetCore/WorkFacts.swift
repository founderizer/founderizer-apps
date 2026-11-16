import Foundation

/// **The app's own work, as fixed kinds** (the plan "Facts to diagnose a setup that stopped", step 2): a server that a
/// provider makes, and an install that this app drives, for `setup_diagnosis`. Each is a case of a fixed list, never
/// the page's words, an address or a name: the words of a stop stay in the app, and only the fixed kind of the stop,
/// which the install model holds beside its words, leaves it. The same holds for what the app's kept records say of
/// an install and of a server that never joined. The link's program does not link this library: its lists are strings
/// in `FleetOwnerAPI`, and a test holds each one to the raw values here.
extension ReachFacts {
    // ------------------------------------------------------------ a server that a provider makes

    /// **The stage of a build at a provider**, one for each case of `FleetCloudModel.Stage` in the app (a test reads the
    /// app's source).
    public enum BuildStage: String, CaseIterable, Sendable {
        case token, choosing, making, joining
    }

    /// **One build model's facts, as the store keeps them by their writer** (the first run's, or Add server's).
    public struct BuildFacts: Equatable, Sendable {
        public var stage: BuildStage
        /// The stage at which the last try stopped. It is kept after the page cleared its stop, until a new try starts.
        public var stoppedAt: BuildStage?
        /// The model's own stop is still there (its page shows it while that page is open).
        public var stopShows: Bool
        public var use: CloudServerUse
        public var provider: CloudProvider?
        /// When the model reached `stage`: for the seconds only, which are read when an answer is written.
        public var since: Date

        public init(stage: BuildStage, stoppedAt: BuildStage?, stopShows: Bool, use: CloudServerUse,
                    provider: CloudProvider?, since: Date) {
            self.stage = stage
            self.stoppedAt = stoppedAt
            self.stopShows = stopShows
            self.use = use
            self.provider = provider
            self.since = since
        }
    }

    /// **The next facts of a build, from the model's four values.** The model tells each change of one of them, so one
    /// change of the page comes as several calls, and the last one is the settled one.
    ///
    /// - The model's own stop wins: it is the stage that the last try reached when it stopped, and it is set before
    ///   `stage` moves.
    /// - With no stop of the model, a move to a stage other than `token` is a new try, and the kept stop goes.
    /// - Else the kept stop stays: Add server's `opened()` calls `cancel()` on a stopped build, which takes the model's
    ///   stop away, and the owner's agent must still read where the last try stopped. `stopShows` then says false.
    public static func build(after old: BuildFacts?, stage: BuildStage, stopped: BuildStage?, use: CloudServerUse,
                             provider: CloudProvider?, now: Date) -> BuildFacts {
        let moved = old.map { $0.stage != stage } ?? true
        let stoppedAt: BuildStage?
        if let stopped {
            stoppedAt = stopped
        } else if moved && stage != .token {
            stoppedAt = nil
        } else {
            stoppedAt = old?.stoppedAt
        }
        return BuildFacts(stage: stage, stoppedAt: stoppedAt, stopShows: stopped != nil, use: use, provider: provider,
                          since: moved ? now : old?.since ?? now)
    }

    /// **What the store keeps of one writer's build, when more than one model writes it** (each first-run view has a
    /// model of its own): `new` is this model's facts, `mine` the facts that this model told before, and `stored` the
    /// store's value. A value that this model wrote itself is always replaced, so a build that ends well leaves
    /// `token`. A value that ANOTHER model wrote stays in two cases, while this model's own stop is not there: that
    /// other build runs (`making`, `joining`) and this model only waits for a token or shows its list (`token`,
    /// `choosing`): the other build still goes on; or that other model left a kept stop and this model is at `token`
    /// with none: a server of that stop can still be at the provider, and an idle page must not take that away.
    public static func kept(_ new: BuildFacts, over stored: BuildFacts?, mine: BuildFacts?) -> BuildFacts {
        guard let stored, stored != mine, !new.stopShows else { return new }
        let runs = stored.stage == .making || stored.stage == .joining
        if runs, new.stage == .token || new.stage == .choosing { return stored }
        if stored.stoppedAt != nil, new.stage == .token, new.stoppedAt == nil { return stored }
        return new
    }

    /// **The seconds in the build's stage**, or nil at `token`, where nothing of the build runs.
    public static func seconds(in build: BuildFacts?, now: Date) -> Int? {
        guard let build, build.stage != .token else { return nil }
        return max(0, Int(now.timeIntervalSince(build.since)))
    }

    // ------------------------------------------------------------ an install that this app drives

    /// Where the install stands. `none`: it has steps, and it neither runs, nor stopped, nor ended (a page ended it).
    public enum InstallState: String, CaseIterable, Sendable {
        case none, running, stopped, done
    }

    /// What is installed: the hub (its plan has the claim), a server that joins the hub, or a Mac through its
    /// installer.
    public enum InstallKind: String, CaseIterable, Sendable {
        case hub, server, mac
    }

    /// **The step of an install**: each id of `InstallPlan.hub` and `.join`, a Mac's order, `other` for an id that no
    /// plan of this app has (a Mac's installer names its own), and `none`.
    public enum InstallStepName: String, CaseIterable, Sendable {
        case read, network, code, plan, start
        case waitClaim = "wait_claim"
        case claim
        case waitReady = "wait_ready"
        case verify, join, order, other, none
    }

    /// The steps of the longest plan (`InstallPlan.hub`): a count from another Mac is never given above it.
    public static let longestPlan = 9
    /// The steps of a server's join (`InstallPlan.join`).
    public static let joinPlan = 4

    /// The step of an id: an id that no plan has is `other`, so another Mac's names never pass.
    public static func installStep(_ id: String?) -> InstallStepName {
        guard let id else { return .none }
        guard let step = InstallStepName(rawValue: id), step != .other, step != .none else { return .other }
        return step
    }
}

#if os(macOS)
extension ReachFacts {
    /// **One install's facts, as fixed kinds.** Why it stopped is the app's own kind of the error that ended it
    /// (`InstallRecord.Stop`, which `MachineInstallModel.stop` holds): the words of a stop are not read here, and no
    /// fact of this type is made from them.
    public struct InstallFacts: Equatable, Sendable {
        public var state: InstallState
        public var kind: InstallKind
        public var step: InstallStepName
        /// nil unless the install stands stopped.
        public var stop: InstallRecord.Stop?
        /// Why the installer stopped itself, as a fixed name (`InstallCause`): nil unless the install stands stopped
        /// with the installer's own reason.
        public var cause: InstallCause?
        /// The install stopped only because the server is not on the owner's private network, and its page asks for
        /// the network's connection in place of "Try again" (`MachineInstallModel.needsNetworkKey`).
        public var waitsForNetwork: Bool
        public var stepsDone: Int
        public var stepsPlanned: Int
        /// When the running step began, while one runs: for the seconds only.
        public var since: Date?
        /// The tries of this press so far (`InstallRetry`): 1 until the app ran the install again by itself.
        public var tries: Int

        public init(state: InstallState, kind: InstallKind, step: InstallStepName, stop: InstallRecord.Stop?,
                    cause: InstallCause? = nil, waitsForNetwork: Bool = false, stepsDone: Int, stepsPlanned: Int,
                    since: Date?, tries: Int = 1) {
            self.state = state
            self.kind = kind
            self.step = step
            self.stop = stop
            self.cause = cause
            self.waitsForNetwork = waitsForNetwork
            self.stepsDone = stepsDone
            self.stepsPlanned = stepsPlanned
            self.since = since
            self.tries = tries
        }
    }

    /// **The plain facts of the install model** (`MachineInstallModel.linkFacts` in the app): its way by name, whether
    /// it runs, stopped or ended, its steps' ids and states, and the fixed kind of its stop. The stop's words are not
    /// in it.
    public struct InstallLink: Equatable, Sendable {
        public struct Step: Equatable, Sendable {
            public var id: String
            public var state: InstallProgress.State

            public init(id: String, state: InstallProgress.State) {
                self.id = id
                self.state = state
            }
        }

        /// A name of `MachineInstallModel.Way`: `linux`, `mac` or `line`.
        public var way: String
        public var running: Bool
        public var failed: Bool
        /// The install ran to its end: its checklist came, or its task ended with no stop (a Mac's installer that said
        /// done gives no checklist when it has none).
        public var ended: Bool
        /// A name of `InstallJob` from the install's start on (`hub`, `join`), or nil before any.
        public var job: String?
        public var steps: [Step]
        public var planned: [String]
        public var runningStep: String?
        public var since: Date
        /// The fixed kind of the stop (`MachineInstallModel.stop`): nil exactly when the install did not stop.
        public var stop: InstallRecord.Stop?
        /// The install's page asks for the private network's connection (`MachineInstallModel.needsNetworkKey`).
        public var waitsForNetwork: Bool
        /// The fixed name of the installer's own reason (`MachineInstallModel.cause`), or nil.
        public var cause: InstallCause?
        /// The tries of the press (its record's `tries`): 1 until the app ran the install again by itself.
        public var tries: Int

        public init(way: String, running: Bool, failed: Bool, ended: Bool, job: String? = nil,
                    steps: [InstallProgress], planned: [String], runningStep: String?, since: Date,
                    stop: InstallRecord.Stop?, waitsForNetwork: Bool, cause: InstallCause? = nil, tries: Int = 1) {
            self.way = way
            self.running = running
            self.failed = failed
            self.ended = ended
            self.job = job
            self.steps = steps.map { Step(id: $0.step, state: $0.state) }
            self.planned = planned
            self.runningStep = runningStep
            self.since = since
            self.stop = stop
            self.waitsForNetwork = waitsForNetwork
            self.cause = cause
            self.tries = tries
        }
    }

    /// **The install's facts**, or nil when the model has no work and no result.
    ///
    /// - The kind: `mac` for the way `mac`; else the job, which the model keeps from the install's start, so that a
    ///   stop before the plan says it too; with no job, a plan with the claim is the hub's and any other a server's.
    /// - For a Mac, the steps come from that Mac over the network: its ids pass the fixed list or are `other`, and
    ///   its counts are capped. The kind of its stop is this app's own, by the type of the error that ended the link
    ///   (`InstallRecord.Stop.of`), and never by a word that the Mac sent.
    /// - The stop: the model's own kind while the install stands stopped, and `other` for a stop with no kind (the
    ///   model gives one with each stop). An install that runs, that ended or that its page ended has none. The wait
    ///   for the network and the installer's own reason (`cause`) count only with a stop.
    public static func install(_ link: InstallLink) -> InstallFacts? {
        guard link.running || link.failed || link.ended || !link.steps.isEmpty else { return nil }
        let state: InstallState = link.running ? .running : link.failed ? .stopped : link.ended ? .done : .none
        let kind: InstallKind
        if link.way == "mac" {
            kind = .mac
        } else if let job = link.job.flatMap(InstallJob.init(rawValue:)) {
            kind = job == .hub ? .hub : .server
        } else {
            kind = link.planned.contains(InstallStepName.claim.rawValue) ? .hub : .server
        }
        let step: InstallStepName
        switch state {
        case .running:
            step = installStep(link.runningStep ?? link.steps.last(where: { $0.state == .running })?.id
                               ?? link.steps.last?.id)
        case .stopped: step = installStep(link.steps.first(where: { $0.state == .failed })?.id)
        case .none: step = installStep(link.steps.last(where: { $0.state == .running })?.id)
        case .done: step = .none
        }
        let stopped = state == .stopped
        let done = link.steps.filter { $0.state == .done }.count
        let planned = link.planned.isEmpty ? link.steps.count : link.planned.count
        return InstallFacts(state: state, kind: kind, step: step, stop: stopped ? link.stop ?? .other : nil,
                            cause: stopped ? link.cause : nil,
                            waitsForNetwork: stopped && link.waitsForNetwork, stepsDone: min(done, longestPlan),
                            stepsPlanned: min(planned, longestPlan),
                            // Only while a step runs: an install that waits for its first step has no step's seconds.
                            since: state == .running && link.runningStep != nil ? link.since : nil,
                            tries: min(max(link.tries, 1), InstallRetry.most + 1))
    }

    /// **The seconds in the running step**, or nil when no step runs.
    public static func seconds(in install: InstallFacts?, now: Date) -> Int? {
        guard let since = install?.since else { return nil }
        return max(0, Int(now.timeIntervalSince(since)))
    }

    // ------------------------------------------------------------ the kept records

    /// **The last install of this fleet that this Mac kept a record of, as fixed kinds** (`last_install` of
    /// `setup_diagnosis`): after a restart of the app the install model is empty, and the record is what still says
    /// where an install stood. Never the record's addresses, its server's name or its page's line.
    public struct LastInstall: Equatable, Sendable {
        public var kind: InstallRecord.Kind
        public var outcome: InstallRecord.Outcome
        /// nil unless the outcome is `stopped`.
        public var stop: InstallRecord.Stop?
        /// The installer's own reason as a fixed name (`InstallRecord.cause`): nil unless the outcome is `stopped`.
        public var cause: InstallCause?
        /// The install stopped only because the server was not on the owner's private network.
        public var waitsForNetwork: Bool
        /// The step where it stood: the one that failed, else the one that ran; `none` for an install that ended
        /// well or that had no step yet.
        public var step: InstallStepName
        public var stepsDone: Int
        public var stepsPlanned: Int
        /// The newest time in the record (its end, or its last step's change): for the seconds only.
        public var lastChange: Date
        /// The tries of the record's press, and why each earlier one stopped, as fixed names (`InstallRecord.tries`,
        /// `retried`): a name that is neither a cause nor a stop's kind is not passed on.
        public var tries: Int
        public var retried: [String]

        public init(kind: InstallRecord.Kind, outcome: InstallRecord.Outcome, stop: InstallRecord.Stop?,
                    cause: InstallCause? = nil, waitsForNetwork: Bool, step: InstallStepName, stepsDone: Int,
                    stepsPlanned: Int, lastChange: Date, tries: Int = 1, retried: [String] = []) {
            self.kind = kind
            self.outcome = outcome
            self.stop = stop
            self.cause = cause
            self.waitsForNetwork = waitsForNetwork
            self.step = step
            self.stepsDone = stepsDone
            self.stepsPlanned = stepsPlanned
            self.lastChange = lastChange
            self.tries = tries
            self.retried = retried
        }
    }

    /// **Which record is the last install of the fleet that the app shows.** `records`: newest first, as
    /// `InstallRecords.all()` gives them. `hub`: the hub's address in the app's own form
    /// (`FleetStore.hub.absoluteString`), or nil while the app has no hub's address.
    ///
    /// - With a hub: the newest record for that hub's address, as `InstallRecords.newest(hub:)` finds it: the hub's
    ///   own install after its claim, a server that joined it, a Mac's link. An install for another hub is another
    ///   fleet's, and is passed over.
    /// - With no hub (a first run): the newest install of a hub, whatever its address, as
    ///   `InstallRecords.newest(kind:)` finds it: one that stopped before its claim has no address, and one that
    ///   stopped after it has an address that the app never went to.
    public static func lastRecord(in records: [InstallRecord], hub: String?) -> InstallRecord? {
        guard let hub else { return records.first { $0.kind == .hub } }
        return records.first { $0.hub == hub }
    }

    /// **A record's facts.** The stop, its cause and the wait for the network count only for a record that says
    /// `stopped`. The planned steps are the plan's own count for a hub and for a join, and never less than the steps
    /// that the record has; a Mac's installer names its own steps, so its count is the record's steps. Each count is
    /// capped at the longest plan, as an install's counts are.
    public static func lastInstall(_ record: InstallRecord) -> LastInstall {
        let stopped = record.outcome == .stopped
        let stood: InstallRecord.StepID?
        switch record.outcome {
        case .running: stood = record.steps.last { $0.state == .running }?.id
        case .done: stood = nil
        case .stopped, .cancelled, .interrupted: stood = record.stoppedAt
        }
        let plan: Int
        switch record.kind {
        case .hub: plan = longestPlan
        case .join: plan = joinPlan
        case .mac: plan = 0
        }
        return LastInstall(kind: record.kind, outcome: record.outcome, stop: stopped ? record.stop ?? .other : nil,
                           cause: stopped ? record.cause : nil, waitsForNetwork: stopped && record.waitsForNetwork,
                           step: stood.map { installStep($0.rawValue) } ?? .none,
                           stepsDone: min(record.steps.filter { $0.state == .done }.count, longestPlan),
                           stepsPlanned: min(max(plan, record.steps.count), longestPlan),
                           lastChange: record.lastChange,
                           tries: min(max(record.tries ?? 1, 1), InstallRetry.most + 1),
                           retried: (record.retried ?? []).filter { name in
                               InstallCause(rawValue: name) != nil || InstallRecord.Stop(rawValue: name) != nil
                           }.suffix(InstallRetry.most).map { $0 })
    }

    /// **The seconds since the record's last change**: since the install ended, or since its last step changed for
    /// one that was cut off.
    public static func seconds(since last: LastInstall?, now: Date) -> Int? {
        last.flatMap { seconds(from: $0.lastChange, to: now) }
    }

    /// The most seconds that an age says: about 126 years. A record's date is a number in a file of the owner's
    /// user, so it can be any number.
    public static let mostSeconds = 4_000_000_000

    /// **Whole seconds from a record's date to now**: 0 for a date after now, `mostSeconds` at most, and nil for a
    /// date that is no number. The bounds come BEFORE the whole number: `Int` of a number that is too large stops
    /// the app, and a damaged record's date can be one (`1e300`).
    public static func seconds(from date: Date, to now: Date) -> Int? {
        let interval = now.timeIntervalSince(date)
        guard !interval.isNaN else { return nil }
        return Int(min(max(interval, 0), Double(mostSeconds)))
    }

    /// **The servers that this app asked a provider for and that this Mac never saw join** (`builds` of
    /// `setup_diagnosis`), by what each build left at its provider (`BuildRecord.AtProvider`). Each one that stands at
    /// its provider is billed, and after a restart of the app only the kept records say that one can exist. Counts
    /// only: never a server's name, the provider's id, the provider or a hub's address.
    public struct UnjoinedBuilds: Equatable, Sendable {
        /// The provider answered with the server.
        public var server: Int
        /// A step failed after the provider made something, and the app could not delete all of it.
        public var leftBehind: Int
        /// The call for the server has no answer that this Mac knows.
        public var notKnown: Int

        public init(server: Int = 0, leftBehind: Int = 0, notKnown: Int = 0) {
            self.server = server
            self.leftBehind = leftBehind
            self.notKnown = notKnown
        }

        public var total: Int { server + leftBehind + notKnown }
    }

    /// **The count of the records that are unjoined** (`BuildRecord.isUnjoined`), of every hub: a first run's server
    /// is made before any hub exists and its record never gets a hub's address, and a server costs the same
    /// whichever fleet it was made for. The switch has no default, so a new case of `AtProvider` fails the build here.
    public static func unjoined(_ records: [BuildRecord]) -> UnjoinedBuilds {
        var counts = UnjoinedBuilds()
        for record in records where record.isUnjoined {
            switch record.atProvider {
            case .server: counts.server += 1
            case .leftBehind: counts.leftBehind += 1
            case .notKnown: counts.notKnown += 1
            // `isUnjoined` is false for a build that left nothing.
            case .nothing: break
            }
        }
        return counts
    }

    /// **The last change of the newest record that is unjoined**, for its age only (`builds.newest_seconds_ago`):
    /// nil with none. It is no part of the counts, so that no date enters the facts that the diagnosis compares.
    /// The owner knows by the age which try a count is of: a record stays after its server is gone.
    public static func newestUnjoined(_ records: [BuildRecord]) -> Date? {
        records.filter(\.isUnjoined).map(\.lastChange).max()
    }
}
#endif
