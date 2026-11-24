#if os(macOS)
import Foundation

/// **The four steps that a server's install shows under its moving title, and the minutes left** (`SetupPhases`; the
/// owner's yes of 4 November 2026 to "Steps and minutes"). An install plan has more steps than a person needs to read,
/// so each one counts towards one of four: what stands before the private network is the server, the private network
/// is its own, the checks are the end, and everything between them is the install. A step that a later plan adds or
/// renames lands in one of the four by its place, so this needs no change for it.
public struct InstallPhases: Equatable, Sendable {
    public static let names = [String(l10n: "VPS"), String(l10n: "Network"), String(localized: "Install (a step)", defaultValue: "Install", bundle: Localized.bundle, locale: Localized.digits), String(l10n: "Checks")]

    /// The step that runs now, as an index of `names`; `names.count` once every step is done.
    public internal(set) var current: Int
    /// **The minutes left, only while they are true** (F4 of the owner's feedback of 22 November 2026: "show the real
    /// progress, so we know what the system is doing, otherwise it looks stuck"; before it, 5 November 2026: "It's been
    /// showing 1 minute for like 5 minutes"): the estimates of the steps that are not done, less the time of the step
    /// that runs. nil once that step has run longer than its estimate, because then no count of ours is true: a join of
    /// 14 minutes said "About 2 min" from its sixth minute to its end. A page shows no minutes for nil.
    public let minutesLeft: Int?
    /// **What runs now, in a few words**, for the line under the title of each server setup page (the owner's yes of 5
    /// November 2026: "some extra messages of status of what's actually doing would help, like a subheader"; for each
    /// page, his "Yes, as drawn" of 22 November 2026 to F4's pictures P2 and P7): one phrase of the app's own table for
    /// each plan step and each heading of an installer (`status(_:join:)`), never the server's words. nil once every
    /// step is done, and for a step that has no words of its own.
    public internal(set) var status: String?
    /// **This Mac's last three reads of the step that runs reached nothing** (`InstallProgress.unreachable`; F4 piece 5,
    /// the picture P4): its page says so under the bar, and no minutes show, since no count of ours is true then.
    public let unreachable: Bool
    /// The heading that the installer prints now is not in the app's table: the line stays the one that this step said
    /// last (`InstallHold`), and with no line before it, the step's own.
    var headingUnknown = false
    /// **How much of each of the four steps is done**, from 0 to 1: the bar of four parts under a server on the first
    /// run's build page (slice 3 of the one wizard; the owner's "that is brilliant!" of 16 November 2026 to its
    /// picture). A part is the units that ended of the units that it has (F4 of 22 November 2026, piece 3): one unit for
    /// each plan step, and one for each heading that the installer prints while a step reads its log
    /// (`installerHeadings`). It never counts time, so the same reported steps give the same parts at each moment, and
    /// a part is full only when its last step has ended. Until then, a part filled by the clock read full while its step
    /// still ran.
    public internal(set) var parts: [Double]
    /// The id of the plan's step that runs now or comes next; nil once every step is done.
    public let step: String?

    /// **Seconds that each step takes, as the proof run of 5 November 2026 measured them** on a new Hetzner CX23 with
    /// Ubuntu 24.04 (the owner: "It's been showing 1 minute for like 5 minutes... better timing"). "start" ends at once,
    /// because the installer then runs by itself on the server; the wait for its end ("wait_ready") holds the long part:
    /// the hub's own setup and the first security updates, about 11 minutes in all. A server that joins a fleet runs the
    /// same first updates in its join. A step that is not here counts `otherStep`.
    public static let seconds: [String: Int] = ["read": 15, "network": 45, "code": 15, "plan": 5, "start": 5,
                                                "wait_claim": 30, "claim": 10, "wait_ready": 650, "verify": 75,
                                                "join": 360]
    public static let otherStep = 30

    /// **The headings that an installer prints while a plan step reads its log**, as units of that step's part of the
    /// bar: `hub.sh` prints "Founderizer step N: words" before each part of its install, one for each `heading` line of
    /// the script (a path can leave some out), and "wait_ready" reads them until the installer's end. The headings that
    /// come out while "wait_claim" reads the log count as soon as "wait_ready" reads a later one, because a heading's
    /// number counts each heading before it. A step that is not here counts no heading: a heading that the app does not
    /// count (a join's, for one) holds the share where it stood.
    public static let installerHeadings: [String: Int] = ["wait_ready": 19]

    /// The steps of an install that has a private network step, which every install of a hub or a server has; a
    /// restart or an update of a server has none and shows no steps. `planned`: the ids of the plan's steps, in order.
    /// The installer reports a step only when it starts, so the steps it has not reached yet count from this list: the
    /// second proof run of 5 November 2026 said "About 1 min" with twelve minutes to go, because they were left out.
    /// `runningFor`: how long the step that runs now has run, so the minutes go down within a long step too, stand at
    /// its last half minute, and go when it takes longer than its estimate. It changes the minutes only, never `parts`.
    public init?(steps reported: [InstallProgress], planned: [String] = [], runningFor: TimeInterval = 0) {
        let known = Set(reported.map(\.step))
        let steps = reported + planned.filter { !known.contains($0) }
            .map { InstallProgress(step: $0, title: $0, says: "", state: .waiting) }
        guard let network = steps.firstIndex(where: { $0.step == "network" }) else { return nil }
        func phase(_ index: Int) -> Int {
            if index < network { return 0 }
            if index == network { return 1 }
            return steps[index].step == "verify" ? 3 : 2
        }
        let open = steps.indices.filter { steps[$0].state != .done }
        current = open.first.map(phase) ?? Self.names.count
        func estimate(_ index: Int) -> Int { Self.seconds[steps[index].step] ?? Self.otherStep }
        let left = open.reduce(0) { $0 + estimate($1) }
        let running = open.first.flatMap { steps[$0].state == .running ? estimate($0) : nil }
        unreachable = open.first.map { steps[$0].state == .running && steps[$0].unreachable } ?? false
        if let running, runningFor > Double(running) || unreachable {
            minutesLeft = nil
        } else {
            let ran = running.map { min(max(0, Int(runningFor)), max(0, $0 - 30)) } ?? 0
            minutesLeft = Int((Double(left - ran) / 60).rounded(.up))
        }
        let join = steps.contains { $0.step == "join" }
        status = open.first.flatMap { Self.status(steps[$0], join: join) }
        headingUnknown = open.first.map { Self.heading(of: steps[$0], join: join) == .unknown } ?? false
        var units = [Int](repeating: 0, count: Self.names.count)
        var ended = [Int](repeating: 0, count: Self.names.count)
        for index in steps.indices {
            let part = phase(index), headings = Self.installerHeadings[steps[index].step] ?? 0
            units[part] += 1 + headings
            switch steps[index].state {
            case .done: ended[part] += 1 + headings
            case .running:
                // The heading that runs has not ended; each one before it has. The step's own unit ends only with it.
                let newest = steps[index].lines.compactMap(Self.installerStepNumber).last ?? 0
                ended[part] += min(headings, max(0, newest - 1))
            case .waiting, .failed: break
            }
        }
        let current = current
        parts = units.indices.map { units[$0] > 0 ? Double(ended[$0]) / Double(units[$0]) : ($0 < current ? 1 : 0) }
        step = open.first.map { steps[$0].step }
    }

    /// **The line of each step that runs, from one table** (F4 of 22 November 2026, piece 4, and its table of lines):
    /// the plan's steps, and inside the long step of each install the heading that its installer prints now. A hub's
    /// headings before its security updates are part of starting the hub, the hardening and the network after them
    /// secure the server, and its own "verify" checks the hub. A join (`join.sh`) groups its headings as installing
    /// Founderizer, securing the server, its security updates and preparing it for agents; a join with no heading says
    /// that it installs Founderizer for the whole step. So the line never goes back to an earlier phrase inside one
    /// step: the hardening after the updates said "Starting your hub" again.
    static func status(_ step: InstallProgress, join: Bool) -> String? {
        switch step.step {
        case "read": return String(l10n: "Starting your server")
        case "network": return String(l10n: "Joining your private network")
        case "code", "plan": return String(l10n: "Copying the Founderizer code")
        case "start": return String(l10n: "Starting your hub")
        case "claim": return String(l10n: "Linking your hub to this Mac")
        case "verify": return join ? String(l10n: "Checking your server") : String(l10n: "Checking your hub")
        case "wait_claim", "wait_ready", "join":
            // No heading yet, or one that the table does not have: the step's own line.
            let known = heading(of: step, join: join).flatMap { $0 == .unknown ? nil : $0 }
            switch known ?? (join ? .installingFounderizer : .startingHub) {
            case .startingHub: return String(l10n: "Starting your hub")
            case .installingFounderizer: return String(l10n: "Installing Founderizer")
            case .securing: return String(l10n: "Securing your server")
            case .updates: return String(l10n: "Installing security updates")
            case .preparing: return String(l10n: "Preparing your server for agents")
            case .checkingHub: return String(l10n: "Checking your hub")
            case .checkingServer: return String(l10n: "Checking your server")
            case .unknown: return nil
            }
        default: return nil
        }
    }

    /// The group of an installer's heading, for the line of what runs.
    enum HeadingLine: Equatable, Sendable {
        case startingHub, installingFounderizer, securing, updates, preparing, checkingHub, checkingServer
        /// A heading that the table does not have: the line that the step said last, or the step's own.
        case unknown
    }

    /// **The headings of `hub.sh`, in the order of its `main`**, by the start of their fixed words, each with its line
    /// (a test holds each `heading` line of the script to one row here, and their count to `installerHeadings`).
    static let hubHeadings: [(words: String, line: HeadingLine)] = [
        ("this server and this copy of Founderizer", .startingHub), ("base packages", .startingHub),
        ("the user", .startingHub), ("the private network (Tailscale)", .startingHub),
        ("the firewall: the private network only", .startingHub),
        ("the Founderizer repository on this hub", .startingHub), ("the first team.json", .startingHub),
        ("the root helpers that make an agent's OS user", .startingHub),
        ("one OS user for each agent of this machine", .startingHub), ("this server's vault", .startingHub),
        ("the services fleet-hub", .startingHub), ("each agent of this machine, under its own OS user", .startingHub),
        ("the checks the owner can act on", .startingHub), ("this fleet's own id", .startingHub),
        ("the server service of this server", .startingHub), ("security updates", .updates),
        ("this server's own hardening", .securing), ("the network: a kept connection keeps its speed", .securing),
        ("verify", .checkingHub),
    ]

    /// **The headings of `join.sh`**: the parts that it has with `hub.sh` keep the same words (piece 1 of F4), in the
    /// order of a join: the system and the user, the firewall and the hardening, the security updates, then the root
    /// helpers, the agents' users and the vault. A heading of a join's own part (the join to the hub, the key swap, the
    /// outgoing gate) gets its row with the heading.
    static let joinHeadings: [(words: String, line: HeadingLine)] = [
        ("base packages", .installingFounderizer), ("the user", .installingFounderizer),
        ("the firewall: the private network only", .securing), ("this server's own hardening", .securing),
        ("security updates", .updates), ("the root helpers that make an agent's OS user", .preparing),
        ("one OS user for each agent of this machine", .preparing), ("this server's vault", .preparing),
        ("verify", .checkingServer),
    ]

    /// The group of the heading that `step` reports now: the newest heading in its lines, read in its install's table;
    /// nil for a step that reads no installer's log, and before its first heading.
    static func heading(of step: InstallProgress, join: Bool) -> HeadingLine? {
        guard ["wait_claim", "wait_ready", "join"].contains(step.step),
              let words = step.lines.compactMap(installerStep).last?.lowercased() else { return nil }
        return (join ? joinHeadings : hubHeadings).first { words.hasPrefix($0.words.lowercased()) }?.line ?? .unknown
    }

    /// What the hub's installer says it does now, from one line of its log: "Founderizer step 14: security updates"
    /// gives "security updates". nil for any other line.
    public static func installerStep(_ line: String) -> String? {
        guard let range = line.range(of: "^Founderizer step [0-9]+: ", options: .regularExpression) else { return nil }
        let words = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return words.isEmpty ? nil : words
    }

    /// The number of the installer's heading in one line of its log: "Founderizer step 14: security updates" gives 14.
    /// nil for any line that `installerStep` does not read as a heading.
    static func installerStepNumber(_ line: String) -> Int? {
        guard installerStep(line) != nil else { return nil }
        return Int(line.dropFirst("Founderizer step ".count).prefix { $0.isASCII && $0.isNumber }.prefix(9))
    }
}

/// **The bar of one press, which never goes back** (F4 of the owner's feedback of 22 November 2026, piece 3: "a part
/// never goes back while one press runs, also through a retry of the app", the rule of `AgentSetupFlow.barPart`). A
/// press runs up to three tries (`InstallRetry`), and each try reports its steps again from the first one: the bar
/// keeps the furthest share of each part that the press reached, and the part that runs where it stood. The line and
/// the minutes stay those of the step that runs now. A new press starts a new hold; a retry keeps it.
public struct InstallHold: Equatable, Sendable {
    /// The furthest share of each part in this press; nil before its first step.
    public private(set) var parts: [Double]?
    /// The line that the step which runs said last from a heading of the table, with that step's id (F4 piece 4: a
    /// heading that the table does not have, such as one of a newer installer, holds the line where it stood).
    private var line: (step: String, words: String)?

    public init() {}

    public static func == (lhs: InstallHold, rhs: InstallHold) -> Bool {
        lhs.parts == rhs.parts && lhs.line?.step == rhs.line?.step && lhs.line?.words == rhs.line?.words
    }

    /// Keeps each part of what the install reports now where it is further than before, and the line of a heading that
    /// the table has.
    public mutating func keep(_ phases: InstallPhases) {
        parts = parts.map { before in zip(before, phases.parts).map { max($0, $1) } } ?? phases.parts
        if !phases.headingUnknown, let step = phases.step, let words = phases.status { line = (step, words) }
    }

    /// `phases` with each part, and the part that runs, at the furthest that this press reached, and for a heading that
    /// the table does not have, the line that its step said last.
    public func applied(to phases: InstallPhases) -> InstallPhases {
        var held = phases
        if phases.headingUnknown, let line, line.step == phases.step { held.status = line.words }
        guard let parts, parts.count == phases.parts.count else { return held }
        held.parts = zip(parts, phases.parts).map { max($0, $1) }
        held.current = max(phases.current, held.parts.firstIndex { $0 < 1 } ?? phases.current)
        return held
    }
}
#endif
