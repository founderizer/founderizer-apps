#if os(macOS)
import Foundation

/// **One server's line on the first run's build page** (slice 3 of the one wizard; the owner's "that is brilliant!" of
/// 16 November 2026 to the build page's picture in `~/dev/founderizer-plans/one-wizard-build-page/`): under each
/// server's box, what runs there now in a few words, the minutes left, and a bar of four parts (VPS, Network, Install,
/// Checks, as `InstallPhases.names`), each from 0 to 1. The owner's turn, the manager's sign-in, has its words in the
/// dot's orange and no minutes; a server that is ready shows none of the three.
public struct FleetBuildRow: Equatable, Sendable {
    public let words: String?
    public let minutes: Int?
    /// The four parts of the bar; nil for a server that is ready, which shows no bar.
    public let parts: [Double]?
    /// The owner's turn: the words in orange, and no minutes.
    public let ownersTurn: Bool

    /// The seconds of a provider's build before its install, as `CloudBuilding` counts them: about 75 from the press to
    /// the server on the private network (the proof run of 5 November 2026), and the last part of it, the server that
    /// starts and comes on that network.
    public static let buildSeconds = 75, startSeconds = 30
    /// The bar's first part once the provider's server starts: the install's first step fills the rest of it.
    public static let startShare = 0.6

    /// **The provider makes the server** (`FleetCloudModel`'s `making`), or the server starts and comes on the private
    /// network (`joining`): the bar's first part, and the minutes of the build and of the install plan after it.
    public static func building(joining: Bool, plan: [String]) -> FleetBuildRow {
        let build = joining ? startSeconds : buildSeconds
        return FleetBuildRow(words: joining ? String(l10n: "Starting your server") : String(l10n: "Making your server"),
                             minutes: minutes(build + seconds(plan)), parts: [joining ? startShare : 0.2, 0, 0, 0],
                             ownersTurn: false)
    }

    /// **The manager's own server is on the private network, and the hub does not answer yet**: its join starts as soon
    /// as the hub answers (the proof of 16 November 2026: about 20 seconds after the claim). Its minutes are the join's.
    public static func waitsForHub(plan: [String]) -> FleetBuildRow {
        FleetBuildRow(words: String(l10n: "Waiting for your hub"), minutes: minutes(seconds(plan)),
                      parts: [startShare, 0, 0, 0], ownersTurn: false)
    }

    /// **An install that began and has no step yet** (its key is minted, its plan not made): the words of its first
    /// step, the minutes of its plan, and the bar's first part where the provider's build left it, or empty for a
    /// server that no provider made in this try. So the part never goes back when the install's own steps come.
    public static func starting(plan: [String], afterBuild: Bool) -> FleetBuildRow {
        FleetBuildRow(words: String(l10n: "Starting your server"), minutes: minutes(seconds(plan)),
                      parts: [afterBuild ? startShare : 0, 0, 0, 0], ownersTurn: false)
    }

    /// **An install that runs** (`InstallPhases`): its words, minutes and parts. The join of an agent's server says what
    /// its long step does, the server's own first security updates, and its checks name the agent's server, where the
    /// hub's words name the hub. An install whose steps are all done has no words and no minutes. `afterBuild`: the
    /// provider made the server in this try, so the bar's first part goes on from where the build left it
    /// (`building`'s 0.6) and never back.
    public static func installing(_ phases: InstallPhases, joinFor agent: String? = nil,
                                  afterBuild: Bool = false) -> FleetBuildRow {
        var parts = phases.parts
        if afterBuild, !parts.isEmpty { parts[0] = startShare + (1 - startShare) * parts[0] }
        var words = phases.status
        if let agent {
            switch phases.step {
            case "join": words = String(l10n: "Installing security updates")
            case "verify": words = String(l10n: "Checking \(agent)'s server")
            default: break
            }
        }
        return FleetBuildRow(words: words, minutes: phases.step == nil ? nil : max(1, phases.minutesLeft),
                             parts: parts, ownersTurn: false)
    }

    /// **The hub puts the manager on its server with its AI program** (the move; about half a minute on the proof run
    /// of 16 November 2026): "Installing Claude Code".
    public static func settingUp(_ program: String) -> FleetBuildRow {
        FleetBuildRow(words: String(l10n: "Installing \(program)"), minutes: 1, parts: [1, 1, 1, 0.5], ownersTurn: false)
    }

    /// **The manager's sign-in is the owner's turn**: "Waiting for your sign-in", in orange, with no minutes.
    public static var signIn: FleetBuildRow {
        FleetBuildRow(words: String(l10n: "Waiting for your sign-in"), minutes: nil, parts: [1, 1, 1, 1], ownersTurn: true)
    }

    /// A server that is ready: no words, no minutes and no bar.
    public static let ready = FleetBuildRow(words: nil, minutes: nil, parts: nil, ownersTurn: false)

    static func seconds(_ plan: [String]) -> Int {
        plan.reduce(0) { $0 + (InstallPhases.seconds[$1] ?? InstallPhases.otherStep) }
    }

    static func minutes(_ seconds: Int) -> Int { max(1, Int((Double(seconds) / 60).rounded(.up))) }
}
#endif
