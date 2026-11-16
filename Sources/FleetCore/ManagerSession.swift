import Foundation

/// The manager's standing session, as the owner's apps show it when it is not running.
///
/// The manager is the one agent whose session always stands, so its availability is the fleet's: while it is down
/// nothing of the fleet moves. The hub says so with the `manager_down` warning, and the machine's own helper starts a
/// session that went by itself within ten seconds (`fleet.Helper.manager_gone`) and tries again at every round while
/// its start fails; the owner's phone is told only after two of its starts failed in a row.
///
/// **No button starts it** (the owner, 16 November 2026: "remove the 2 buttons on that banner because they are
/// useless", of Start the session and the Open button of the manager's page, while tmux refused every start of its
/// helper with "command too long"). Start the session asked that helper for the start that it was already making
/// every round, so it could never help when the warning stood; the agent's page was a place to look, not a cause.
/// The band's one button is **Report a problem**: it opens the report form with this problem in the box
/// (`reportText`), and the form's "What Founderizer can see" carries what the hub knows of why, the helper's own
/// words of its failed start included. Its row in System status has the same button, as every row that nothing on
/// the owner's side repairs.
/// `POST /ui/machines/<agent>/manager` stays for the owner's own agent (`start_manager_session`).
///
/// The manager's other warnings are not about a session that is missing — a usage limit, a question on its own
/// screen, a silence, a switch that has not finished, a sign-in — and for each of those the thing to do is on that
/// agent's page, where its session and its machine are: their band keeps its Open button.
public enum ManagerSession {
    public static let feature = "manager_start"

    /// The `manager_warning` kind of a session that is not running, and of a server that went silent with a message
    /// waiting: its `cause` says which.
    public static let downKind = "down"

    /// The `cause` of a `down` whose helper answers and whose window is gone: the one whose band reports it.
    public static let notRunningCause = "not_running"

    /// **Whether the band reports this warning** (Report a problem) rather than open the manager's page: only a
    /// session that is not running while its helper answers, which that helper starts again by itself. A server that
    /// went silent has no helper to start anything, so its band keeps the manager's page, where its server is; and so
    /// does a hub that names no cause, whose `down` could be either.
    public static func reports(_ warning: ManagerWarning?) -> Bool {
        warning?.kind == downKind && warning?.cause == notRunningCause
    }

    /// **The band's words without a step that no button takes**: a hub from before 16 November 2026 says "The manager
    /// session is not running. Start it again.", and no app has that start now.
    public static func bandWords(_ flag: String) -> String {
        let tail = " Start it again."
        return flag.hasSuffix(tail) ? String(flag.dropLast(tail.count)) : flag
    }

    /// **What the report form holds when the band's Report a problem opens it**: the problem and since when, in the
    /// owner's own clock ("12:45" today, "15 Nov, 22:10" before). `since`: the hub's `manager_warning.since`; `now`:
    /// the reading's own time. The owner reads it, can add to it, and sends it.
    public static func reportText(since: Double?, now: Double, zone: TimeZone = .current) -> String {
        guard let since, since.isFinite, since > 0 else {
            return String(l10n: "The manager session is not running") + "."
        }
        let time = FleetTrouble.since(since, now: now, zone: zone)
        return String(l10n: "The manager session is not running, since \(time).")
    }

    /// The `manager_warning` kind of a manager whose machine reports it signed out.
    public static let signedOutKind = "signed_out"

    /// **No "not signed in" band over the manager's own sign-in** (the owner's yes of 5 November 2026 to hiding it
    /// there). In the second proof run of a new fleet, "The manager is not signed in" with Open Manager stood over the
    /// "Sign in to Claude Code" step: the page under it was that sign-in, and Open Manager opened the page that was
    /// already open. `overItsSetup`: the page under the band is the manager's own setup or its sign-in. Every other
    /// warning, and this one over every other page, stands as before.
    public static func bandShows(kind: String?, overItsSetup: Bool) -> Bool { !(overItsSetup && kind == signedOutKind) }
}
