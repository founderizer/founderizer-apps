#if os(macOS)
import Foundation

/// **The four steps that a server's install shows under its moving title, and the minutes left** (`SetupPhases`; the
/// owner's yes of 4 November 2026 to "Steps and minutes"). An install plan has more steps than a person needs to read,
/// so each one counts towards one of four: what stands before the private network is the server, the private network
/// is its own, the checks are the end, and everything between them is the install. A step that a later plan adds or
/// renames lands in one of the four by its place, so this needs no change for it.
public struct InstallPhases: Equatable, Sendable {
    public static let names = ["VPS", "Network", "Install", "Checks"]

    /// The step that runs now, as an index of `names`; `names.count` once every step is done.
    public let current: Int
    public let minutesLeft: Int
    /// **What runs now, in a few words**, for the line under the first run's title (the owner's yes of 5 November 2026:
    /// "some extra messages of status of what's actually doing would help, like a subheader"). nil once every step is
    /// done, and for a step that has no words of its own.
    public let status: String?

    /// **Seconds that each step takes, as the proof run of 5 November 2026 measured them** on a new Hetzner CX23 with
    /// Ubuntu 24.04 (the owner: "It's been showing 1 minute for like 5 minutes... better timing"). "start" ends at once,
    /// because the installer then runs by itself on the server; the wait for its end ("wait_ready") holds the long part:
    /// the hub's own setup and the first security updates, about 11 minutes in all. A server that joins a fleet runs the
    /// same first updates in its join. A step that is not here counts `otherStep`.
    public static let seconds: [String: Int] = ["read": 15, "network": 45, "code": 15, "plan": 5, "start": 5,
                                                "wait_claim": 30, "claim": 10, "wait_ready": 650, "verify": 75,
                                                "join": 420]
    public static let otherStep = 30

    /// The steps of an install that has a private network step, which every install of a hub or a server has; a
    /// restart or an update of a server has none and shows no steps. `planned`: the ids of the plan's steps, in order.
    /// The installer reports a step only when it starts, so the steps it has not reached yet count from this list: the
    /// second proof run of 5 November 2026 said "About 1 min" with twelve minutes to go, because they were left out.
    /// `runningFor`: how long the step that runs now has run, so the minutes go down within a long step too, and stand
    /// at its last half minute when it takes longer than its estimate.
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
        var left = open.reduce(0) { $0 + (Self.seconds[steps[$1].step] ?? Self.otherStep) }
        if let now = open.first, steps[now].state == .running {
            let estimate = Self.seconds[steps[now].step] ?? Self.otherStep
            left -= min(max(0, Int(runningFor)), max(0, estimate - 30))
        }
        minutesLeft = Int((Double(left) / 60).rounded(.up))
        status = open.first.flatMap { Self.status(steps[$0]) }
    }

    /// The words of one step that runs, in the order the first run meets them. The long wait for the hub's own installer
    /// says what that installer prints it is doing: its security updates, then its own checks.
    static func status(_ step: InstallProgress) -> String? {
        switch step.step {
        case "read": return "Starting your server"
        case "network": return "Joining your private network"
        case "code", "plan": return "Copying the Founderizer code"
        case "start", "wait_claim": return "Starting your hub"
        case "claim": return "Linking your hub to this Mac"
        case "verify": return "Checking your hub"
        case "wait_ready":
            let doing = step.lines.compactMap(Self.installerStep).last?.lowercased() ?? ""
            if doing.contains("security updates") { return "Installing security updates" }
            if doing.hasPrefix("verify") { return "Checking your hub" }
            return "Starting your hub"
        default: return nil
        }
    }

    /// What the hub's installer says it does now, from one line of its log: "Founderizer step 14: security updates"
    /// gives "security updates". nil for any other line.
    public static func installerStep(_ line: String) -> String? {
        guard let range = line.range(of: "^Founderizer step [0-9]+: ", options: .regularExpression) else { return nil }
        let words = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return words.isEmpty ? nil : words
    }
}
#endif
