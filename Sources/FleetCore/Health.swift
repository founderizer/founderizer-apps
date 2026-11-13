import Foundation

public struct FleetHealth: Codable, Sendable {
    public let db: String
    public let ok: Bool
    public let time: Double
    public let revision: String?
    public let hub: Hub
    public let helpers: [Helper]
    public let warnings: [Warning]
    /// Whether this hub serves the owner's own copy at all. A fleet that set `"backup": {"enabled": false}` in its
    /// team file raises no copy warning and refuses both routes, so the screen offers no button it cannot press.
    public let backups_enabled: Bool?
    /// The last copy the owner saved and the hub confirmed, or nil while there is none.
    public let backup: Backup?
    public struct Hub: Codable, Sendable {
        public let started_at: Double?
        public let python: String?
        public let sqlite: String?
        public let db_bytes: Int64?
        public let disk_free_bytes: Int64?
        /// The size of that disk, and the server it is on: nil from a hub before the load readings (4 November 2026).
        public let disk_total_bytes: Int64?
        public let machine: String?
        public let integrity: Integrity
    }
    public struct Integrity: Codable, Sendable { public let result: String?; public let at: Double? }
    public struct Backup: Codable, Sendable {
        public let at: Double
        public let bytes: Int64
        public let sha256: String
        /// How old it is, as the hub measured it against its own clock.
        public let age: Double?
    }
    public struct Helper: Codable, Sendable { public let agent: String; public let last_seen: Double?; public let offline: Bool }

    /// One thing the hub reports as wrong, with the one line that puts it right (owner API 1.5, 19 October 2026).
    ///
    /// `fix` is the hub's own words, the way `verify` writes a `fix` for a check, and `agent` is the agent the
    /// warning is about when it is about one. The app reads those two and `kind`; it never parses `detail`.
    public struct Warning: Codable, Sendable {
        public let kind: String
        public let detail: String
        public let fix: String?
        public let agent: String?
        public init(kind: String, detail: String, fix: String? = nil, agent: String? = nil) {
            self.kind = kind; self.detail = detail; self.fix = fix; self.agent = agent
        }
    }
    public func validate(database: String) throws {
        guard db == database, time.isFinite, time > 0, helpers.count <= 1000, warnings.count <= 1000,
              Set(helpers.map(\.agent)).count == helpers.count,
              hub.db_bytes.map({ $0 >= 0 }) != false, hub.disk_free_bytes.map({ $0 >= 0 }) != false,
              hub.disk_total_bytes.map({ $0 >= 0 }) != false,
              backup.map({ $0.at.isFinite && $0.at > 0 && $0.bytes > 0 && Backup.isDigest($0.sha256) }) != false,
              !ok || warnings.isEmpty else { throw HubError.invalidResponse }
    }

    /// Whether the owner can take a copy from this screen: a hub that has the routes and has not turned them off.
    /// A hub from before owner API 1.5 answers neither field and raises no copy warning either.
    public var takesCopies: Bool { backups_enabled == true }

    /// **The helpers this reading can still speak for**, on a list that reads the health every 15 seconds: a read or two
    /// that failed change no word. An older reading, from another page or kept by reads that fail, gives none, so a
    /// server's row goes by the server's own reading (`Servers.state`), which corrects itself.
    public func currentHelpers(at now: Double) -> [Helper] { now - time < 45 ? helpers : [] }

    /// **The reading this Mac kept with the fleet's last one** (the polish of 30 October 2026), for the hub generation the
    /// launch's kept reading is of, or nil: the Settings dot draws from it in a launch's first frame, where it came with
    /// the launch's own health read, 0.2–0.3 s later. The launch reads the health again as before.
    public static func kept(_ data: Data, database: String) -> FleetHealth? {
        guard let health = try? JSONDecoder().decode(FleetHealth.self, from: data),
              (try? health.validate(database: database)) != nil else { return nil }
        return health
    }
}

extension FleetHealth.Backup {
    static func isDigest(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

extension FleetHealth.Warning {
    /// The one thing the owner presses for this warning.
    ///
    /// The owner, all through 18 and 19 October 2026: a screen that reports something wrong must carry the way to
    /// put it right. So every warning gets exactly one button, and never one that does nothing — which is why
    /// `tellUs` exists: a corrupt database and a schema step this hub's records refused are ours, not his, and
    /// saying so with the report window beside it is the honest action, not an invented command.
    public enum Act: Equatable, Sendable {
        /// Take the copy, save it on this Mac, and confirm it: `GET /ui/backup`, then `POST /ui/backups/confirm`.
        case saveCopy
        /// `ui/machines/<agent>/update`, the command the machine's own page sends.
        case update(agent: String)
        /// That agent's own page, where its session is: the manager's warnings are about its session.
        case openAgent(String)
        /// `ui/machines/<agent>/manager`: start that agent's standing manager session again. Only `manager_down`
        /// gets it, because only a missing session is put right by a start (`ManagerSession`).
        case startManager(agent: String)
        /// That machine's page, where its checks and its controls are.
        case openMachine(String)
        /// Nothing here settles it. The report window carries the whole reading to us.
        case tellUs
        /// `ui/machines/<agent>/update` for each of these agents: the one button of the agents that run an older
        /// version (the owner, 4 November 2026: "why woudl we want to update one but not the others? there should be
        /// a button to update the fleet").
        case updateFleet([String])
    }

    public var act: Act { act(manager: nil) }

    /// The button, with the manager's name where the warning's line tells him to tell the manager: **a worker's usage
    /// line ("tell Manager what must not wait") opens Manager's chat** (fix round 3, item 35); it opened that worker's
    /// server page.
    public func act(manager: String?) -> Act {
        if kind.hasPrefix("allowance_"), let manager, agent != manager { return .openAgent(manager) }
        switch kind {
        case "backup_missing", "backup_old": return .saveCopy
        case "machine_behind", "machine_failed": return agent.map { .update(agent: $0) } ?? .tellUs
        case _ where kind.hasPrefix("manager_"):
            guard let agent else { return .tellUs }
            return ManagerSession.startable(kind: String(kind.dropFirst("manager_".count)))
                ? .startManager(agent: agent) : .openAgent(agent)
        default: return agent.map { Act.openMachine($0) } ?? .tellUs
        }
    }

    /// The row's own title. Short, because `detail` says the rest in the hub's words.
    public var title: String {
        let who = (agent ?? "").agentLabel
        switch kind {
        case "backup_missing": return String(l10n: "No copy of your fleet")
        case "backup_old": return String(l10n: "Your copy is old")
        case "integrity": return String(l10n: "The hub's own records")
        case "schema": return String(l10n: "The hub runs without a step")
        case "disk_low": return String(l10n: "The hub's disk is nearly full")
        case "helper_offline": return who.isEmpty ? String(l10n: "An agent is not answering") : String(l10n: "\(who) is not answering")
        // His words, not the hub's kind: "Allowance Pace" was the hub's own name for this warning on his screen.
        case "allowance_pace": return who.isEmpty ? String(l10n: "An agent nears its usage limit") : String(l10n: "\(who) nears its usage limit")
        case "machine_stale": return who.isEmpty ? String(l10n: "A server sent no status") : String(l10n: "\(who) sent no status")
        case "machine_behind": return who.isEmpty ? String(l10n: "A server is behind") : String(l10n: "\(who) is behind")
        case "machine_failed": return who.isEmpty ? String(l10n: "An update failed") : String(l10n: "The update of \(who) failed")
        case "manager_down": return who.isEmpty ? String(l10n: "The manager session is not running") : String(l10n: "\(who)'s session is not running")
        case _ where kind.hasPrefix("manager_"): return String(l10n: "The manager needs you")
        // His words for the kinds that fell to the hub's own name in Title Case ("Timers Stalled", fix round 2, T-37).
        case "allowance_spent": return who.isEmpty ? String(l10n: "An agent reached its usage limit") : String(l10n: "\(who) reached its usage limit")
        case "timers_stalled": return String(l10n: "The hub's timers stopped")
        case "vault_behind": return who.isEmpty ? String(l10n: "A server's vault is out of date") : String(l10n: "\(who)'s vault is out of date")
        case "tasks_stuck": return String(l10n: "Some tasks are stuck")
        case "circles_stuck": return String(l10n: "Some work runs in circles")
        case "reports_undecided": return String(l10n: "Reports wait for a decision")
        default: return kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

extension FleetHealth {
    /// **A size of the hub's storage in a few words, with one decimal** (fix round 3b): "830 KB", "12,4 MB", "829,8 GB",
    /// in his Mac's own numbers, as an attachment's size is written. The system's formatter wrote gigabytes with two
    /// and dropped a last zero, so the size of a disk that writes logs changed its words between two reads.
    public static func storageWords(_ bytes: Int64) -> String {
        let units = ["KB", "MB", "GB", "TB", "PB"]
        guard bytes >= 1024 else { return "\(max(bytes, 0).formatted()) B" }
        var size = Double(bytes) / 1024, unit = 0
        while size >= 1024, unit < units.count - 1 { size /= 1024; unit += 1 }
        let words = unit == 0 ? Int(size).formatted() : size.formatted(.number.precision(.fractionLength(1)))
        return "\(words) \(units[unit])"
    }

    /// **One block for the warnings about one agent's server, and every other warning a block of its own** (D-2 and D-4,
    /// the owner's yes of 28 October 2026: "Mini's two become one"): the first one's title, what the hub said, each
    /// line that puts it right and each button, once. System status and Report a problem draw the same blocks.
    ///
    /// **Only a silent helper and its server's own warnings are one block** (review A1, fix round 2). The hub's `agent`
    /// names the page a warning's button opens, not always what it is about: the manager's limit, its spent allowance,
    /// stuck tasks and undecided reports all name the manager, and the hub's stalled timers and full disk name the agent
    /// on the hub's server. Merged by that name, they were one block under the first one's title, with two buttons that
    /// both said "Open Manager".
    public struct Block: Sendable {
        /// The warnings of the block, in the hub's order. Never empty.
        public let warnings: [Warning]
        public let title: String
        /// What the hub said, **each fact once** (fix round 2, T-37): a server that sent no status beside a helper
        /// that is silent is the same fact, so the block says "Silent since 23:06." and not also "No status for ten
        /// minutes.".
        public let detail: String
        /// The lines that put it right, each once.
        public let fixes: [String]
        /// The buttons, each once.
        public let acts: [Warning.Act]

        public var first: Warning { warnings[0] }
        /// The agent the block is about, or nil for a warning about the fleet.
        public var agent: String? { first.agent }
        /// The agents that run an older version, for the block of them all (`updateFleet`); empty for every other.
        public var updates: [String] {
            if case .updateFleet(let agents)? = acts.first { return agents }
            return []
        }
    }

    /// The warnings in blocks, in the order the hub gave the first of each; `manager` names the buttons that open the
    /// manager's chat (`Warning.act(manager:)`).
    public static func blocks(_ warnings: [Warning], manager: String? = nil) -> [Block] {
        var order: [String] = [], groups: [String: [Warning]] = [:]
        for (index, warning) in warnings.enumerated() {
            let key = warning.agent.flatMap { _ in isUpdate(warning.kind) ? "update" : nil }
                ?? warning.agent.flatMap { aboutServer(warning.kind) ? "server \($0)" : nil } ?? "warning \(index)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(warning)
        }
        return order.compactMap { key -> Block? in
            guard let group = groups[key], !group.isEmpty else { return nil }
            if key == "update" { return updateBlock(group) }
            // A silent helper is why its server sent no status: that second warning says the same fact again.
            let silent = group.contains { $0.kind == "helper_offline" }
            let said = group.filter { !(silent && $0.kind == "machine_stale") }
            // Each button once, and no two with one label.
            let acts = group.map { $0.act(manager: manager) }.reduce(into: [Warning.Act]()) { acts, act in
                if !acts.contains(where: { $0.label == act.label }) { acts.append(act) }
            }
            return Block(warnings: group, title: group[0].title, detail: once(said.map(\.detail)).joined(separator: " "),
                         fixes: once(said.compactMap(\.fix).filter { !$0.isEmpty }), acts: acts)
        }
    }

    /// **The agents that run an older version are one block, with one button** (the owner, 4 November 2026, of eleven
    /// blocks that each said "It runs an older version than the hub." over its own Update button: "this should be a
    /// table and why woudl we want to update one but not the others? there should be a button to update the fleet, and
    /// simplify this!"). System status draws its agents as a table; Report a problem and the Settings dot read the
    /// title and the names.
    static func updateBlock(_ group: [Warning]) -> Block {
        let agents = once(group.compactMap(\.agent))
        let failed = Set(group.filter { $0.kind == "machine_failed" }.compactMap(\.agent))
        let title = agents.count == 1 ? String(l10n: "\(agents[0].agentLabel) runs an older version")
            : String(l10n: "\(agents.count) agents run an older version")
        let names = agents.map { failed.contains($0) ? String(l10n: "\($0.agentLabel) (its update failed)") : $0.agentLabel }
        return Block(warnings: group, title: title, detail: names.joined(separator: ", ") + ".", fixes: [],
                     acts: [.updateFleet(agents)])
    }

    /// An agent's machine runs an older version than the hub, or its update failed: the block of `updateFleet`.
    public static func isUpdate(_ kind: String) -> Bool { kind == "machine_behind" || kind == "machine_failed" }

    /// A warning about an agent's server: its helper is silent, or its machine is stale.
    static func aboutServer(_ kind: String) -> Bool { kind == "helper_offline" || kind.hasPrefix("machine_") }

    private static func once<Item: Equatable>(_ items: [Item]) -> [Item] {
        items.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
}

extension FleetHealth.Warning.Act {
    /// What the button says. One short line, and it names what it acts on.
    public var label: String {
        switch self {
        case .saveCopy: String(l10n: "Save copy")
        case .update(let agent): String(l10n: "Update \(agent.agentLabel)")
        case .startManager: String(l10n: "Start the session")
        case .openAgent(let name): String(l10n: "Open \(name.agentLabel)")
        case .openMachine(let name): String(l10n: "Open \(name.capitalized)")
        case .tellUs: String(l10n: "Report a problem")
        case .updateFleet: String(l10n: "Update fleet")
        }
    }

    /// **What stands in the place of Update fleet while its requests go**, one for each agent, one after the other:
    /// the agent whose request is on its way, of them all ("Updating 3 of 11…"), so that a fleet of many agents does
    /// not look stuck (the owner, 13 November 2026: "other long actions where we actually know the progress"). One
    /// agent has no count.
    public static func updatingWords(_ at: Int, of total: Int) -> String {
        total > 1 ? String(l10n: "Updating \(at) of \(total)…") : String(l10n: "Updating…")
    }
}
