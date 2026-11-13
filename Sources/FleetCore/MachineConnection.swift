import Foundation

/// **Is this machine connected?** — and nothing else.
///
/// The owner's words, 20 October 2026: "I only care about connected or not connected, and if I need to do
/// something! I dont care about internal commands."
///
/// The hub already answers this, for every machine, every few minutes, and it costs nothing: `/ui/health` carries
/// each helper with `offline` and the time it was last heard from, and `/ui/servers` carries each machine's own
/// last reading. So the page asks the hub, not the machine. Nothing here opens an SSH connection, runs a command
/// on his machine or waits for him to press anything: a page that has to connect before it can say whether a
/// machine is up is a page that can hang before it says anything at all.
///
/// The deeper look over his own SSH connection (`verify`) is what it always was — a closer look for when
/// something is wrong or he asks for one — and it never again stands between him and this one word.
public enum MachineConnection: Equatable, Sendable {
    /// Its helpers are reporting to the hub. `lastSeen` is the newest of them, for the one line under the word.
    case connected(lastSeen: Double?)
    /// The hub has heard nothing from this machine. `says` is the hub's own line about it where it wrote one
    /// (`/ui/health` `detail`), because the hub's words are better than ours about the hub's own reading.
    case notConnected(says: String?)
    /// This Mac's own reading of the hub is old, so nothing here can say either way. A screen that says
    /// "Connected" from a reading of ten minutes ago is worse than one that says it does not know.
    case unknown
    /// This Mac has not read the hub's answer yet. It is the state for a second when the page opens, and the
    /// page waits in it rather than flashing "Not connected" at a machine that is perfectly well.
    case waiting

    public var isConnected: Bool { if case .connected = self { return true }; return false }

    /// The one word the page says.
    public var words: String {
        switch self {
        case .connected: return String(l10n: "Connected")
        case .notConnected: return String(l10n: "Not answering")       // the app's one word for it (T-25, fix round 2)
        case .unknown: return String(l10n: "Not known")
        case .waiting: return String(l10n: "Reading…")
        }
    }

    /// The one line under that word, in the hub's own words where it wrote one.
    public func says(_ machine: String, now: Double) -> String {
        switch self {
        case .connected(let lastSeen):
            guard let lastSeen, lastSeen > 0 else { return String(l10n: "Founderizer on \(machine) reports to the hub.") }
            return String(l10n: "Founderizer on \(machine) reported \(activityAge(lastSeen, now: now).lowercased()).")
        case .notConnected(let says):
            return says ?? String(l10n: "The hub has heard nothing from \(machine).")
        case .unknown:
            return String(l10n: "Founderizer cannot reach your hub, so it cannot say whether \(machine) is connected.")
        case .waiting:
            return String(l10n: "Founderizer is asking the hub about \(machine).")
        }
    }

    /// **The hub's own answer for one server.** The helpers of its agents say it; a server that runs no agent is
    /// answered by its own service's reading instead, and a machine with neither has never reported at all.
    ///
    /// `fresh` is whether this Mac's reading of the hub is current. Without it there is no answer, only an old
    /// one, and this says so.
    public static func of(_ server: ServerEntry, helpers: [FleetHealth.Helper],
                          warnings: [FleetHealth.Warning] = [], time: Double, fresh: Bool) -> MachineConnection {
        guard fresh else { return .unknown }
        let mine = server.agents.compactMap { agent in helpers.first { $0.agent == agent } }
        if !mine.isEmpty {
            let quiet = mine.filter(\.offline)
            guard quiet.isEmpty else { return .notConnected(says: hubSaid(quiet.map(\.agent), in: warnings)) }
            return .connected(lastSeen: mine.compactMap(\.last_seen).max())
        }
        // **The hub's own machine with no agent and no service answers through the hub itself** (4 November 2026: the
        // owner's hub server said "Not answering" in orange on Servers while the hub, which runs there, answered
        // and measured it): this Mac has a current reading of the hub, so it heard from that machine just now.
        // A hub server that joined has a service of its own, and its silence is news.
        if server.hub, !server.joined, server.reading == nil { return .connected(lastSeen: time) }
        guard let reading = server.reading else { return .notConnected(says: nil) }
        guard reading.isCurrent(at: time) else {
            return .notConnected(says: hubSaid(server.agents, in: warnings))
        }
        return .connected(lastSeen: reading.reported_at)
    }

    /// What the hub itself wrote about one of these agents being quiet, or nil. Only the two kinds that are about
    /// exactly this — a helper that stopped answering, and a machine that sent no status — because a warning about
    /// something else would read here as the reason and is not.
    private static func hubSaid(_ agents: [String], in warnings: [FleetHealth.Warning]) -> String? {
        warnings.first { warning in
            ["helper_offline", "machine_stale"].contains(warning.kind) && warning.agent.map(agents.contains) == true
        }?.detail
    }
}
