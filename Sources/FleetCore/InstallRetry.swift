#if os(macOS)
import Foundation
import Synchronization

/// **An install that tries again by itself after an error that passes** (the owner, 16 November 2026: "we need to
/// think of ways so these errors can be auto repaired when detected!", and "Yes, build it" to
/// `~/dev/founderizer-plans/install-auto-repair-plan.md`, part 1).
///
/// Some stops pass by themselves in seconds or minutes, and the owner's only move was Try again, which the app now makes
/// for him: the hub could not save the server at that moment, the hub could not read the server's name in Tailscale
/// yet, the join code expired before the join reached it, the hub restarted for a release, a package mirror or
/// Tailscale's installer failed for a moment, or this Mac lost a new hub's server over SSH while it fetched the code or
/// read the plan.
/// **Nothing new shows**: the page stays the running page while the install runs again (while a retry waits, its
/// phases stand at the plan's first step, counted from the plan), and only the last try's stop shows. The kept record
/// counts the tries (`InstallRecord.tries`), so the owner's agent can say what happened.
///
/// **One table, by the stop's kind and then its cause** (`decision`); anything not in it stops as before. Each row was
/// read against the code that gives the stop (the plan's fresh reader, 16 November 2026):
/// - A join code that was **not valid** adds a row to the hub's `join_failures`, so a retry brings the server's address
///   nearer to the hub's lock; one **already used** comes from another address or another server key (the hub replays
///   this server's own repeat), so the owner must see it; one that **a newer code replaced** means that another install
///   runs, and a new code would stop it. Only an **expired** code is tried again.
/// - `server_unreached` is tried again only at the hub's `code` and `plan`: a command that SSH lost can run on with no
///   connection, and only there does a second run beside it do no harm (`plan` changes nothing; at `code` apt waits for
///   its lock, and beside a clone that runs on, the second run pulls into its folder or stops with git's words). Never
///   at `network`, whose `tailscale up` (the
///   keyed step's, or the sign-in's) a second one beside it would meet with a new key; nor after `start` or `join`:
///   `hub.sh` runs detached and neither installer takes a lock. A `read` that failed waited for the server already.
/// - **A join's retry runs the same join line** (`freshCode` false): the hub takes the same server's repeat of a used
///   code, and its own words say "the code stays valid" (`hub_busy`, `server_name_unread`), while a new code ends every
///   other open code of the hub (one open code), and with it any other join that has not sent its code yet. Only an
///   expired code gets a new one, and a code that has less than `codeLeftAtLeast` left (`keepsCode`).
/// - `hub_no_answer` also reads `join.sh`'s first words, when the server did not reach the hub (`reach`): this Mac's hub
///   answers then, so the wait ends at its first read, and the retry gives a server whose Tailscale came up a moment
///   before the time to reach the hub.
/// - A stop that needs the owner's Tailscale key (`needsNetworkKey`), and a press that used a sudo password (which the
///   install holds for its own length and no longer, `PasswordOnce`), are never tried again.
public struct InstallRetry: Equatable, Sendable {
    /// What a retry waits for before the install runs again.
    public enum Wait: Equatable, Sendable {
        /// Nothing: the install's own first step waits for the server over SSH (`InstallPlan.readAction`), and the
        /// installers wait for the package lock (`InstallPlan.aptLockWait`).
        case nothing
        /// `count` reads of this Mac's hub, one every `ServerCheck.waitEvery`. `untilAnswer`: the first read that the
        /// hub answers ends the wait (the hub restarted); else every read is made, because the hub answers while it is
        /// busy (its 409 and 503 say "run the line again in a few minutes"): a count of reads, never a clock.
        case reads(Int, untilAnswer: Bool)
    }

    public let wait: Wait
    /// A join asks the hub for a new code before the next try; else it runs the same line again.
    public let freshCode: Bool

    init(wait: Wait, freshCode: Bool = false) {
        self.wait = wait
        self.freshCode = freshCode
    }

    /// The retries after the owner's press: three tries in all. His own Try again starts a new count.
    public static let most = 2

    /// The pace of `.reads`: the pace of the wait for a server that a provider made (`ServerCheck.waitEvery`).
    public static let readEvery = ServerCheck.waitEvery

    /// **A join's retry keeps its code only while the code has this many seconds left** (a review of 16 November 2026):
    /// a try sends the code only at its `join` step, after `read`, `network` and the installer's own package step, and a
    /// code that ends before then costs a try (`join_code_expired`). The hub gives a server's code 30 minutes
    /// (`JOIN_LIFE`).
    public static let codeLeftAtLeast: Double = 600

    /// Whether a join's next try runs the code that it has: by the code's own end, which the hub gave with it
    /// (`expiresAt`), at `now`. It reads a known end and waits for nothing; a Mac whose clock runs ahead of the hub's
    /// asks for a new code sooner, as every try did before.
    public static func keepsCode(expiresAt: Double, now: Double) -> Bool {
        expiresAt - now >= codeLeftAtLeast
    }

    /// The steps (of the hub's plan, `InstallPlan.hub`) that run again after SSH lost the server: what the lost run
    /// left running on the server does no harm beside a second run (the type's words).
    static let againAfterALostServer: Set<String> = ["code", "plan"]

    /// **Whether the install runs again**, and what it waits for first; nil: it stops as before. `tries`: the tries
    /// that this press made, the one that just stopped included. `step`: the id of the step that failed.
    public static func decision(stop: InstallRecord.Stop, cause: InstallCause?, job: InstallJob, step: String?,
                                tries: Int, needsNetworkKey: Bool, usedSudoPassword: Bool) -> InstallRetry? {
        guard tries <= most, !needsNetworkKey, !usedSudoPassword else { return nil }
        switch stop {
        case .installerStopped:
            guard let cause else { return nil }
            switch cause {
            case .hubBusy where job == .join: return InstallRetry(wait: .reads(8, untilAnswer: false))
            case .serverNameUnread where job == .join: return InstallRetry(wait: .reads(4, untilAnswer: false))
            case .joinCodeExpired where job == .join: return InstallRetry(wait: .nothing, freshCode: true)
            case .hubNoAnswer where job == .join: return InstallRetry(wait: .reads(20, untilAnswer: true))
            case .privateNetwork, .packages, .agentProgram: return InstallRetry(wait: .nothing)
            // A join's code comes from the hub's port 9418, or over the hub's own port when 9418 does not answer (hub
            // feature code_over_hub_port): a join that got it from neither meets a policy or the hub's code service,
            // which no retry repairs. A hub's own code comes from its repository's address (and its agents' from
            // itself), which can fail for a moment.
            case .codeNotFetched where job == .hub: return InstallRetry(wait: .nothing)
            default: return nil
            }
        case .serverUnreached:
            guard let step, againAfterALostServer.contains(step) else { return nil }
            return InstallRetry(wait: .nothing)
        case .hubUnreached where job == .join:
            return InstallRetry(wait: .reads(20, untilAnswer: true))
        default:
            return nil
        }
    }

    /// **What a decision reads of the error that ended a try**, read as `MachineInstallModel.finish` reads it: the
    /// stop's kind (`networkKeyRefused`: the app's own error for a key that Tailscale refused, which FleetCore does not
    /// know), the installer's own cause, and whether the stop waits for the owner's Tailscale key.
    public struct Stopped: Equatable, Sendable {
        public let stop: InstallRecord.Stop
        public let cause: InstallCause?
        public let needsNetworkKey: Bool
    }

    public static func stopped(by error: Error, networkKeyRefused: Bool, authKeyEmpty: Bool) -> Stopped {
        let says = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return Stopped(stop: networkKeyRefused ? .networkKeyRefused : .of(error), cause: InstallCause.of(error),
                       needsNetworkKey: networkKeyRefused || (InstallPlan.needsNetworkKey(says) && authKeyEmpty))
    }

    /// **The wait before a retry**, with what it does given to it, so that a test reaches it: `pause` waits one step
    /// of `readEvery`; `read` reads the hub and says whether it answered; `cancelled` ends the wait at once. `.reads`
    /// makes its count of reads, and ends at the first answer when `untilAnswer`. It runs on its caller's actor (the
    /// install's model is the main actor's), so the closures stay there.
    public static func wait(_ wait: Wait, isolation: isolated (any Actor)? = #isolation, pause: () async -> Void,
                            read: () async -> Bool, cancelled: () -> Bool) async {
        guard case .reads(let count, let untilAnswer) = wait else { return }
        for _ in 0..<count {
            await pause()
            if cancelled() { return }
            if await read(), untilAnswer { return }
        }
    }

    /// **The step that a run of a plan stopped at**, noted where the installer reports it: in the installer's own
    /// context, just before it throws (`MachineInstaller.run`). The report's own task to the main actor can run after the
    /// stop's decision, which then read no step or an older one (a review of 16 November 2026).
    public final class FailedStep: Sendable {
        private let step = Mutex<String?>(nil)

        public init() {}

        public func note(_ progress: InstallProgress) {
            if progress.state == .failed { step.withLock { $0 = progress.step } }
        }

        public var value: String? { step.withLock { $0 } }
    }

    /// The name that a retry keeps in the record (`InstallRecord.retried`): the cause when the installer gave one, else
    /// the stop's kind. Both are fixed lists.
    public static func name(stop: InstallRecord.Stop, cause: InstallCause?) -> String {
        cause?.rawValue ?? stop.rawValue
    }
}
#endif
