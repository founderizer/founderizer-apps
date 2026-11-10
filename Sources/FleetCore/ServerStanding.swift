import Foundation

/// What one server's page says at a glance, and the one thing to do about it.
///
/// The owner's words, 20 October 2026: "I only care about connected or not connected, and if I need to do
/// something! I dont care about internal commands." So the state is **`MachineConnection`** — the hub's own live
/// answer, which needs neither his SSH nor a button — and under it the page carries only what he must do: the
/// restart a machine is waiting for, the helper the hub will not update, and, when he asked for a closer look
/// himself, what that look found.
///
/// Three things that used to be here are gone with those words. "Checks" was the name of a procedure of ours.
/// "This Mac has not read the checks of <machine> yet" was a state that meant only that nobody had pressed a
/// button. And a `fix` that is a command for a terminal is not his work: those stay behind Details, where the
/// closer look itself lives.
///
/// The order below is deliberate, as `ReleaseState.stand`'s is: what is going on now, then the one word about the
/// machine, and only a machine the hub hears from can read as connected.
public struct ServerStanding: Equatable, Sendable {
    /// The state in one word, which the page says once. When the machine is connected the page says nothing else.
    public let words: String
    /// One line under it: what the state means, or what is left to do.
    public let says: String
    /// The one thing that puts this state right, when the state names one thing. nil when it does not.
    public let fix: String?
    /// The state is one to act on, so the page says it in orange.
    public let attention: Bool
    /// Something is going on, so a spinner stands in for the page's button.
    public let working: Bool
    /// This machine installed security updates that take effect after a restart, and the page offers one.
    public let needsRestart: Bool
    /// A helper on this machine runs an old revision and the hub will not update it, so the page offers to.
    public let needsUpdate: Bool
    /// What a closer look the owner asked for **in this session** found wrong, each with its own line. Empty on
    /// every other page: a look from a week ago is a reading and lives behind Details, and a look nobody asked for
    /// never happens at all.
    public let failing: [VerifyCheck]
    /// The machine is connected, so the page offers no button for it.
    public let settled: Bool

    /// The mark of the state, for the one row that carries it.
    public var symbol: String {
        working ? "clock.arrow.circlepath" : attention ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }

    /// Why this machine asks for a restart, in its own numbers. What a restart costs is said once, by the
    /// confirmation that asks for it, and never again here: the owner read the same sentence twice on this page
    /// and on the Sign-in card, and once is what a line is worth.
    public static func restartSays(_ pending: Int?) -> String {
        guard let pending, pending > 0 else {
            return "Its system installed security updates that take effect after a restart."
        }
        return "\(pending) security update\(pending == 1 ? " is" : "s are") installed and waiting for a restart."
    }

    /// Why a helper on this machine asks to be updated, in the hub's own terms: it does not run the revision the
    /// fleet runs. What an update costs is said once, by the confirmation that asks for it, as a restart's is.
    public static func updateSays(_ agents: [String]) -> String {
        guard agents.count == 1, let only = agents.first else {
            return "Founderizer on it is behind for \(agents.count) agents."
        }
        return "Founderizer on it is behind for \(only.agentLabel)."
    }

    /// **The one word about this machine, and the things the owner has to do about it.**
    ///
    ///   - `connected`: the hub's own answer (`MachineConnection.of`). It is the state unless something is going
    ///     on right now, and it is reached without SSH, without a command on his machine and without a button.
    ///   - `checklist`: what a closer look last answered there, over the owner's own SSH connection.
    ///   - `lookedNow`: that look was asked for in this session, so what it found belongs on the face. A look
    ///     this app remembers from an earlier launch is a reading and stays behind Details.
    ///   - `looking`: a closer look is running now.
    ///   - `restarting` / `updating`: the step this Mac is driving now, in the owner's words, or nil.
    ///   - `restartedAt`: when a restart this Mac drove finished. A reading from before it says nothing about the
    ///     machine after it, so the restart is not offered again until the machine has reported since.
    ///   - `failure`: the closer look could not be run at all — a connection this Mac cannot make. It never
    ///     changes the one word, because the hub's answer about the machine stands whatever this Mac can reach.
    ///   - `behind`: the agents here whose helper runs an old revision and which the hub will not update
    ///     (`ServerEntry.behindHelpers`), so this Mac is the only way. Empty on every machine that updates itself.
    public static func of(_ server: ServerEntry, connected: MachineConnection, now: Double,
                          checklist: VerifyChecklist? = nil, lookedNow: Bool = false, looking: Bool = false,
                          restarting: String? = nil, restartedAt: Double? = nil, failure: String? = nil,
                          behind: [String] = [], updating: String? = nil) -> ServerStanding {
        let reported = server.reading?.reported_at ?? 0
        let pending = server.reading?.security?.pending_security
        let restart = !server.isMac && server.reading?.security?.reboot_required == true
            && (restartedAt.map { reported > $0 } ?? true)
        let update = !behind.isEmpty
        func made(_ words: String, _ says: String, fix: String? = nil, attention: Bool = false,
                  working: Bool = false, failing: [VerifyCheck] = [], settled: Bool = false) -> ServerStanding {
            ServerStanding(words: words, says: says, fix: fix, attention: attention, working: working,
                           needsRestart: restart, needsUpdate: update, failing: failing, settled: settled)
        }
        if let restarting { return made("Restarting", restarting, working: true) }
        if let updating { return made("Updating", updating, working: true) }
        if looking { return made(connected.words, "Founderizer is looking closer at \(server.name)…", working: true) }
        // The hub has not answered this Mac yet. The page waits for it: a machine that is perfectly well must
        // never read as "Not connected" for the second before the first reading lands.
        if connected == .waiting { return made(connected.words, connected.says(server.name, now: now), working: true) }
        // What the closer look found, but only where the owner asked for it himself and only where it found
        // something: that is the answer to the button he pressed, and it belongs where he pressed it.
        let found = VerifyChecklist.found(checklist, lookedNow: lookedNow)?.failing ?? []
        if connected.isConnected {
            guard found.isEmpty else {
                guard found.count > 1 else {
                    return made(connected.words, found[0].says, fix: found[0].fix, attention: true)
                }
                return made(connected.words, foundWords(found), attention: true, failing: found)
            }
            return made(connected.words, connected.says(server.name, now: now), settled: true)
        }
        // Not connected, or not known. What this Mac could not do is said under the word, never instead of it.
        let says = [connected.says(server.name, now: now), failure].compactMap { $0 }.joined(separator: " ")
        return made(connected.words, says, attention: true, failing: found)
    }

    /// What a closer look found, counted. The sentences themselves are the rows under it.
    private static func foundWords(_ found: [VerifyCheck]) -> String {
        "Founderizer looked closer and found \(found.count) things to put right."
    }

}

extension ServerEntry {
    /// The agents of this server whose helper runs an old revision and which the hub's own update route will not
    /// take, each with its machine's own reading, in the server's order of agents. These are the helpers for which
    /// the owner's Mac is the only way, and the only ones a server's page offers an update for.
    ///
    /// Everything else here updates itself through the hub, which waits for the helper to be idle, so a second way
    /// from this page would be the noise the page exists to remove; `MachineStatus.updatesThroughHub(leads:)` is
    /// that one rule. A machine that does not say it is Linux is left out: the update drives the per-agent OS users
    /// and user services both Linux installers make, and a Mac's agents are one Mac user's own LaunchAgents. A name
    /// the hub would not give an agent is left out too, because it goes into a command on that machine.
    ///
    /// `updatedAt` is when an update this Mac drove finished: a reading from before it says nothing about the
    /// helper after it, so nothing is offered again until that helper has reported since.
    public func behindHelpers(_ readings: [MachineStatus], leads: Bool, updatedAt: Double? = nil) -> [MachineStatus] {
        guard kind == "linux" else { return [] }
        return agents.compactMap { agent in readings.first { $0.agent == agent } }.filter { reading in
            reading.isBehind && !reading.updatesThroughHub(leads: leads)
                && reading.agent.range(of: AgentPlacement.namePattern, options: .regularExpression) != nil
                && (updatedAt.map { (reading.reported_at ?? 0) > $0 } ?? true)
        }
    }
}
