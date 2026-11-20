import Foundation

/// **What the row of a runtime's error says in a task's thread** (the owner, 18 November 2026, of the orange line
/// "workspace routing discovery unauthorized (401)" on a paused screen task: "I dont know what it means or what I can
/// do about it", and "Yes, build it" to the words here). The row showed the provider's own words, which are written for
/// the people who build the provider's program.
///
/// - **"Codex is signed out on box", with "Sign in again"**: while the reading of the agent's server says that the
///   provider of that attempt is signed out there, on the error that the current attempt of a task that is still
///   open stops at. The server says it of the Codex program that the task runs (for the screen tasks of an agent on
///   another provider, the copy that those tasks run): by that program's own status, and, when the status says signed
///   in, by the account read that asks the provider; an agent on a local model has no such read
///   (`lifecycle.Lifecycle.runtime` and `usage.Collector.sign_in_ended` of the kit). For Codex nothing else says it:
///   the error's code comes from Codex's own name for the failure ("other", "http_connection_failed"), and its words
///   are the provider's.
///   A server that says nothing of that provider leaves the row its plain words. The link is there only for a provider
///   whose sign-in the app can start (`MachineLogin.canSignIn`).
/// - **Never for the own provider of an agent on a local model or on the owner's model server**: it signs in nowhere,
///   its server's status says "not signed in", and its sessions work (`needs_sign_in` of the hub).
/// - **"Codex reported an error"**: every other error. An error that the thread does not stop at says this too,
///   because "is signed out" is about now, and one line of the thread says it.
/// - **Orange only while the thread stops at the error** (`stands`; the owner, 19 November 2026, after his sign-in from
///   the row: "I signed in but that task still shows an orange error label, probably not updated"): the last row of the
///   current attempt of a task that is still open (`ActivityTimeline.stands`). An error that the session went on from,
///   an error of an attempt before, an error of a child's thread and each error of a task that is over are grey: they
///   are a record. The row of the usage limit that holds the task now is orange for that time, whatever its session
///   wrote after it: the newest limit record of the current attempt, when it is of that limit. A record of a limit that
///   ended is grey, also at a later limit of the agent, and so is each limit record while a hold or an unknown outcome
///   comes first, as in the task's own mark.
/// - **After a sign-in ends, the hub resumes the task by itself** (`sign_in_resumes` of the kit, his "Yes, build it"):
///   each task that it paused because a session of that provider ended there with an error, if no turn of that
///   provider ended there by itself since the pause. The row then turns grey and the task works again with no press on
///   Resume. Each check of a Resume stands: a task with an unknown outcome, with a stop that nobody confirmed, of a
///   paused goal, under a task that he holds or with subtasks that are held with it keeps its Resume, and so does one
///   that he stopped.
/// - **The provider's own words** go to the pointer (`raw`), for whoever needs them.
/// - **A usage limit keeps its own words**, as before: they are plain already, and the task's own mark says the limit.
/// - **An attempt with no provider in its record, or with two, keeps the provider's words**, as before: the row cannot
///   name a provider that it does not know.
///
/// **Known** (the two reviews of 18 November 2026; the kit's change `1bbc2aa0` of that day took two more away: the
/// sign-in from the row and the reading now ask the copy of Codex that the screen tasks run, and after a sign-in the hub
/// asks each agent beside it for its status at once):
/// - Codex's status command reads as signed out when it prints words without "Logged in", whatever they are.
/// - When the hub knows of a sign-in before the page has read it, the first page of a named provider can show the
///   hub's refusal "... Use another account signs it out first.", a control that this page does not have. The page's
///   next read shows "is signed in".
///
/// **Checked live on 19 November 2026** in the owner's installed app (0.1.329), before the hub resumed a task by itself
/// and before a record was grey: with Codex signed out on a Mac, a new screen task stopped with the provider's 401, the
/// row said "is signed out" with its link, the page signed Codex in, and, after a press on Resume, the task's next
/// attempt ran its screen steps. Not seen there: the provider's words under the pointer.
public struct RuntimeErrorLine: Equatable, Sendable {
    /// The row's words.
    public let says: String
    /// The provider's own words, for the pointer; nil when the row's words are those words, or when it gave none.
    public let raw: String?
    /// The provider that "Sign in again" signs in on the agent's server, or nil when the row has no link.
    public let signIn: String?
    /// True while the thread stops at this error: the row is orange. False for a record of what happened: grey.
    public let stands: Bool
}

extension RuntimeErrorLine {
    /// The code of a usage limit's error record (`threads.py` of the kit).
    public static let limit = "usage_limit"

    /// - Parameters:
    ///   - error: the thread's `error` record.
    ///   - runtimes: the providers of the sessions of that record's attempt (`ActivityTimeline.runtimes`).
    ///   - machine: the reading of the server of the task's agent, or nil when the app has none.
    ///   - standsLast: the thread of the current attempt of a task that is still open stops at this record, or the
    ///     record is of the usage limit that holds the task now (`ActivityTimeline.stands`).
    ///   - time: the hub's time, against which the reading is current or old.
    ///   - own: the own provider of the task's agent, and `localModel`: that agent runs a local model or the owner's
    ///     model server (`FleetAgent.local_model`).
    public init(error: RuntimeEvent, runtimes: Set<String>, machine: MachineStatus?, standsLast: Bool, time: Double,
                own: String? = nil, localModel: Bool = false) {
        let words = error.message.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        stands = standsLast
        guard error.code != Self.limit, runtimes.count == 1, let runtime = runtimes.first else {
            says = words ?? String(l10n: "Runtime error"); raw = nil; signIn = nil
            return
        }
        raw = words
        if standsLast, !(localModel && runtime == own), let machine, machine.isCurrent(at: time), machine.signedOut(runtime) {
            says = String(l10n: "\(providerName(runtime)) is signed out on \(machine.machine)")
            signIn = MachineLogin.canSignIn(runtime) ? runtime : nil
        } else {
            says = String(l10n: "\(providerName(runtime)) reported an error")
            signIn = nil
        }
    }
}

extension MachineStatus {
    /// True when this server's reading says that this provider is signed out on it: the agent's own provider, or
    /// another one that the server has, such as Codex for the screen tasks of an agent on Claude Code. A provider that
    /// the reading does not name, or whose sign-in it does not know, is not signed out.
    public func signedOut(_ name: String) -> Bool { signedIn(name) == false }

    /// What this server's reading says of this provider's sign-in: true, false, or nil when it does not name the
    /// provider or does not know.
    public func signedIn(_ name: String) -> Bool? {
        (runtimes?.byName[name] ?? (runtime.name == name ? runtime : nil))?.signed_in
    }
}
