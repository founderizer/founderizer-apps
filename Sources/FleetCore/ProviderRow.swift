import Foundation

/// **What the page of a Mac says while Codex of its screen tasks cannot run** (the owner's "Yes, both rows" of 19
/// November 2026 to the drawing of the two rows). Until then the page said nothing of it: its sign-in card reads only
/// an agent's own provider, and the only sign-in of this Codex was on the page of a screen task that had failed
/// (`RuntimeErrorLine`). The row stands where the sign-in of an agent's own provider stands (`ServerEntry.signIns`),
/// and only while the fault is there.
///
/// - `signIn`: the Mac has the ChatGPT app with its copy of Codex, or does not say, and the row is this agent's: a
///   sign-in of Codex runs for it, or a current reading of it says that Codex is signed out there. That is the app's
///   own copy for an agent on another provider with a screen runtime: signed out at the Mac, or a sign-in that the
///   provider ended, which the Mac still keeps. The owner's sign-in of Codex for that agent puts it right for each
///   agent of the Mac, with no hands at the Mac (`Destination.signIn(agent, "codex")`). It reads the agent's own
///   reading, as the task's row and the sign-in page do, and not the Mac's `chatgpt`, which follows a sign-in by up to
///   five minutes: a row from that reading opened a page that said "Codex is signed in". The card has its own states,
///   as the card of a server's own provider has: the line of a sign-in that runs with Open, and the line of one that
///   failed with Try again.
/// - `noApp`: a current reading of the Mac says that it has no such app (`chatgpt_app`). A sign-in there does not help
///   its screen tasks, so the row has no button, and its words name the installer at that Mac, which brings the app.
///
/// **Known and left:**
/// - A Mac whose server service does not say `chatgpt_app` yet, with no ChatGPT app and with a `codex` program of its
///   own that is signed out, reads as `signIn`, and that sign-in signs the other program in.
/// - `chatgpt_app` reads the copy of Codex inside the app. A ChatGPT app with no such copy reads as no app, and the
///   installer, which looks for the app alone, then opens it and waits for its sign-in.
/// - The Mac sends its own reading about every five minutes. So `noApp` stays for up to that time after the installer
///   brought the app, and one reading taken while the app replaces itself shows it until the next one. The hub tells
///   the manager only at the second such reading.
/// - After a sign-in of Codex that began while its provider had ended the old one, a reading can say "signed out" once
///   more for the seconds until the account read answers: of the agent that signed in, or of a second agent of the
///   same Mac, and the row is then there again, for that agent. A press there starts no second sign-in when the
///   machine's account read answers that the stored one works (`fleet.Helper.sign_in_works`); with no answer it does.
///   The same seconds follow an install or a preparation that signed the Mac in: it is no sign-in job of an agent.
/// - While an agent's own sign-in of Codex waits on the Mac, the page has that agent's card alone. A sign-in of Codex
///   that runs for another agent of the Mac, from a task's row, does not show then, and the own card still offers one.
/// - An agent whose own provider is Codex and whose helper is off keeps its own card, with a button that cannot be
///   pressed, beside the row of a second agent with a current reading: two cards with the name "Codex".
public enum ScreenSignIn: Equatable, Sendable {
    case signIn(agent: String)
    case noApp

    /// The provider of every screen runtime.
    public static let provider = "codex"
    /// The name of Codex on a Mac, where it is the app that Computer Use runs through: a product's name, in no table.
    public static let chatGPT = "ChatGPT"
    /// The route that brings the ChatGPT app to a Mac.
    public static let atTheMac = String(l10n: "Open the installer on that Mac.")
    /// The line of `noApp`: a Mac that needs the ChatGPT app and says that it has none.
    public static let notInstalled = String(l10n: "Not installed. \(atTheMac)")
}

extension MachineStatus {
    /// A reading of an agent on another provider with a screen runtime says that Codex is signed out on its machine.
    /// An agent whose own provider is Codex has the row of its own sign-in, and an agent with no screen runtime reads
    /// a `codex` program that no screen task runs.
    public var screenCodexSignedOut: Bool {
        runtime.name != ScreenSignIn.provider && settings?.screen != nil && signedOut(ScreenSignIn.provider)
    }
}

extension ServerEntry {
    /// The row of Codex of the screen tasks on this server's page, or nil. `time` is the hub's time.
    ///
    /// No row for a server that is no Mac, for a Mac that needs no ChatGPT, and for one where no agent has a screen
    /// runtime: no screen task can exist there. **One sign-in serves each agent of the Mac's user**, so the rule reads
    /// the Mac's agents together. What an agent says of its sign-in counts only from a current reading. What the Mac
    /// needs and when a sign-in ended are the hub's own facts, and whether an agent has a screen runtime is its
    /// settings: these are read from a reading of any age.
    /// - No second card while an agent's own sign-in of Codex waits there: that card is the same sign-in.
    /// - A sign-in of Codex that runs for an agent of the Mac on another provider, with a current reading, is the row,
    ///   whoever started it (a task's row can), so the page offers no second one beside it.
    /// - An agent with a sign-in of another provider that runs is passed over: its sign-in page shows that one, and the
    ///   hub starts no second sign-in for it.
    /// - A reading from before the newest sign-in of Codex that ended well on this Mac says nothing of now: the hub
    ///   asks each agent of the Mac for a new one at that end (`hub.signed_in_beside`).
    /// - Of the agents that are left, the one whose own sign-in of Codex failed after that end comes first, so that
    ///   its line and Try again show; else the first in the server's order. A failure from before a sign-in that
    ///   ended well is history.
    public func screenSignIn(_ readings: [MachineStatus], at time: Double) -> ScreenSignIn? {
        let codex = ScreenSignIn.provider
        let mine = agents.compactMap { agent in readings.first { $0.agent == agent } }
        guard let first = mine.first, let desktop = first.security.desktop, first.needs?.chatgpt == true,
              mine.contains(where: { $0.settings?.screen != nil }) else { return nil }
        if desktop.chatgpt_app == false { return reading?.isCurrent(at: time) == true ? .noApp : nil }
        let current = mine.filter { $0.isCurrent(at: time) }
        guard !current.contains(where: { $0.signInRuntime == codex && $0.waitsForSignIn }) else { return nil }
        if let going = current.first(where: { $0.login(of: codex)?.isOpen == true }) { return .signIn(agent: going.agent) }
        let signedInAt = mine.compactMap { $0.login(of: codex) }.filter { $0.state == "done" }.map(\.updated_at).max() ?? 0
        let out = current.filter { $0.screenCodexSignedOut && $0.login?.isOpen != true && ($0.reported_at ?? 0) > signedInAt }
        let failed = out.first { $0.login(of: codex).map { $0.isFailure && $0.updated_at > signedInAt } == true }
        return (failed ?? out.first).map { .signIn(agent: $0.agent) }
    }
}
