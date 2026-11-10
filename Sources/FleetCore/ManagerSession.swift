import Foundation

/// The owner starts the manager's standing session again (`manager_start`, UI-API.md "Start the manager session").
///
/// The manager is the one agent whose session always stands, so its availability is the fleet's: while it is down
/// nothing of the fleet moves. The hub says so with the `manager_down` warning — "The manager session is not
/// running. Start it again." — and until 19 October 2026 the app could offer nothing but that agent's own page,
/// which is a place to look, not a thing to press (the owner, that day: "I also don't understand these messages
/// that offer no CTA").
///
/// Two things changed together. The machine's own helper now watches that window and starts a session that went by
/// itself, within ten seconds, so this warning is rare (`fleet.Helper.manager_gone`). And when a start keeps
/// failing, or the owner does not want to wait for the next round, `POST /ui/machines/<agent>/manager` is his hand
/// on the same switch: it asks the helper to make the start due, and nothing else. A session that runs is never
/// closed, replaced or fought over, so pressing it twice, or pressing it after the session came back, changes
/// nothing.
///
/// Only `down` carries it. The manager's other warnings are not about a session that is missing — a usage limit, a
/// question on its own screen, a silence, a switch that has not finished — and for each of those the thing to do is
/// on that agent's page, where its session and its machine are. A button that would not help is worse than no
/// button.
public enum ManagerSession {
    public static let feature = "manager_start"

    /// The `manager_warning` kind whose fix is a start.
    public static let downKind = "down"

    /// Whether this warning kind is one the start settles. `kind` is the hub's `manager_warning.kind`, or the
    /// `manager_<kind>` name of a `/ui/health` warning with its prefix already taken off.
    public static func startable(kind: String?) -> Bool { kind == downKind }

    /// The `manager_warning` kind of a manager whose machine reports it signed out.
    public static let signedOutKind = "signed_out"

    /// **No "not signed in" band over the manager's own sign-in** (the owner's yes of 5 November 2026 to hiding it
    /// there). In the second proof run of a new fleet, "The manager is not signed in" with Open Manager stood over the
    /// "Sign in to Claude Code" step: the page under it was that sign-in, and Open Manager opened the page that was
    /// already open. `overItsSetup`: the page under the band is the manager's own setup or its sign-in. Every other
    /// warning, and this one over every other page, stands as before.
    public static func bandShows(kind: String?, overItsSetup: Bool) -> Bool { !(overItsSetup && kind == signedOutKind) }
}
