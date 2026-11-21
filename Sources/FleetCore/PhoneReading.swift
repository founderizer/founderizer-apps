import Foundation

/// **A reading made of the parts that the iPhone holds**, so FleetCore's own rules read them as they read the Mac's
/// `GET /ui/state`: the phone reads `GET /ui/mobile` (task heads, requests, holds, outcomes, agents) and each chat on
/// its own page, never the whole snapshot. The first rule that needs it is what he asked for in a chat
/// (`HubState.asks`, `ChatAskRow`, `ChatAskPlaces`; the owner, 16 November 2026: "the Mac and the iPhone"), so both apps
/// say the same of one ask: one rule, not a copy of it on the phone. Every part that the phone does not read is empty.
extension HubState {
    public init(phoneTime time: Double, db: String, agents: [FleetAgent], tasks: [FleetTask], needs: [OwnerNeed],
                messages: [OwnerMessage], holds: [TaskHold], outcomes: [TaskOutcome]) {
        schema_version = 1
        self.db = db
        self.time = time
        manager_flag = nil
        manager_warning = nil
        goals = nil
        ui_features = nil
        // `knowledge` is an optional var: nil by itself.
        secrets = nil
        self.agents = agents
        self.tasks = tasks
        notes = []
        self.needs = needs
        permissions = []
        self.messages = messages
        reports = []
        steers = nil
        self.holds = holds
        self.outcomes = outcomes
        chat_apps = nil
        token = nil
    }
}

extension FleetAgent {
    /// An agent as the phone knows it for the rules of a task's mark: its name, its role, its runtime, its Tools boxes
    /// (`can`, which decides who checks an unknown outcome: `TaskOutcome.shellOff`) and the usage limit that holds its
    /// work. Everything else is unknown.
    public init(phoneName name: String, role: String, runtime: String, limit: RuntimeLimit?, can: [String] = []) {
        self.name = name
        self.role = role
        title = nil
        self.runtime = runtime
        active = nil
        direct_chat = nil
        local_model = nil
        reports_to = nil
        self.can = can
        last_seen = nil
        alive_ts = nil
        client_seen = nil
        alive = nil
        client = nil
        usage = nil
        self.limit = limit
        usageError = nil
        signed_in = nil
        chat_ready = nil
        placed = true
        turn_ended_after = nil
        chat_undelivered = nil
        model_account = nil
        account_problem = nil
        kpis = nil
    }
}
