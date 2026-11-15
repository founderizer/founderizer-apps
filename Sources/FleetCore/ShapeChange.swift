import Foundation

// A change of the fleet's shape after its first run: the slider "Lower cost / More secure" of Settings › Servers, and
// the page that it opens (the owner's yes of 15 November 2026 to the pictures in
// `~/dev/founderizer-plans/shape-change-later/`, "Yes, new sizes (1)", then "Yes, build it"). This file is the change's
// rules, with no view and no call: where each agent goes at the chosen step, which servers the change makes, which it
// empties, and what the hub of this fleet cannot do yet. The views draw what this gives (`ShapeChangeViews.swift`),
// and the run carries it out (`ShapeChangeRun.swift`).

/// **One machine of the fleet as a change of its shape sees it**: its name, whether it is the hub's own server or a
/// Mac, its agents, and whether its agent runs alone there by a rule of the hub.
public struct ShapePlace: Equatable, Sendable {
    public var name: String
    public var hub: Bool
    public var mac: Bool
    public var agents: [String]
    /// Its agents stay here at every step, and the change does not move them: an agent that holds servers through the
    /// door, which the door knows by this server's address (`door_caller`), and an agent that this app cannot move.
    public var alone: Bool
    /// The hub takes a new agent here now (`available`): an empty server that the change may use.
    public var available: Bool

    public init(name: String, hub: Bool = false, mac: Bool = false, agents: [String] = [], alone: Bool = false,
                available: Bool = true) {
        self.name = name; self.hub = hub; self.mac = mac; self.agents = agents; self.alone = alone
        self.available = available
    }

    /// A server of the hub's list (`GET /ui/servers`). `stays`: agents that this app cannot move.
    public init(_ entry: ServerEntry, stays: Set<String> = []) {
        self.init(name: entry.name, hub: entry.hub, mac: entry.isMac, agents: entry.agents,
                  alone: entry.why.contains("door_caller") || entry.agents.contains(where: stays.contains),
                  available: entry.available)
    }

    /// The agents here that the slider moves: those of a Linux server, where no rule keeps an agent alone. An agent on
    /// a Mac stays: a Mac runs one agent, which uses its browser or its screen.
    public var movable: [String] { mac || alone ? [] : agents }
}

/// **A change of the fleet's shape, as its page shows it before the press**: the servers after the change, each with
/// what runs on it; the moves, in the order in which the run makes them; the servers that the change leaves with no
/// agent; and what this fleet's hub cannot do yet, when the change needs it.
public struct ShapeChangePlan: Equatable, Sendable {
    /// A server after the change: an existing one by its name, or one that the change makes (`server` nil).
    public struct Box: Equatable, Sendable {
        public var server: String?
        public var hub: Bool
        public var mac: Bool
        public var agents: [String]
        public init(server: String?, hub: Bool = false, mac: Bool = false, agents: [String] = []) {
            self.server = server; self.hub = hub; self.mac = mac; self.agents = agents
        }
    }

    /// One agent to the server of one box.
    public struct Move: Equatable, Sendable {
        public var agent: String
        public var box: Int
        public init(agent: String, box: Int) { self.agent = agent; self.box = box }
    }

    /// What the hub of this fleet cannot do yet, for this change.
    public enum Blocked: String, Equatable, Sendable {
        /// A move onto a server that has an agent: the hub moves an agent only to an empty server today (`move_agent`).
        case joins
        /// An agent on the hub's own server: only a hub whose first install took the word `shared` takes one.
        case hubTakesNone
        /// The change leaves a server with no agent, which this app does not delete at its provider yet.
        case empties
    }

    public var step: ServersStep
    public var boxes: [Box]
    public var moves: [Move]
    /// The servers that hold an agent now and none after the change. The hub's own server is never one of them.
    public var emptied: [String]
    public var blocked: Blocked?

    public init(step: ServersStep, boxes: [Box], moves: [Move], emptied: [String] = [], blocked: Blocked? = nil) {
        self.step = step; self.boxes = boxes; self.moves = moves; self.emptied = emptied; self.blocked = blocked
    }

    /// How many servers the change makes.
    public var newServers: Int { boxes.filter { $0.server == nil && !$0.hub }.count }
    /// The change moves an agent.
    public var changes: Bool { !moves.isEmpty }
    /// The agents that sign in again after their move, in the order of the moves.
    public var signIns: [String] { moves.map(\.agent) }
}

public enum ShapeChange {
    /// **The plan of a change to `step`**, from where the agents run now (`places`, the hub's list in its order).
    /// `manager` is the manager's agent name: it keeps its server where it can, and it moves last. `hubShared`: the
    /// hub's own server takes agents (`hub_shared`). `joins`: the hub moves an agent onto a server that has agents.
    ///
    /// - **1 server**: every agent that the slider moves goes to the hub's own server.
    /// - **2 servers**: the hub alone; every such agent on one server: the manager's, else the one with most agents,
    ///   else a new one.
    /// - **1 per agent**: the hub alone; each such agent alone. A server that has several keeps the manager, else its
    ///   first agent; each other agent goes to an empty server of the fleet, else to a new one. It never needs `joins`.
    ///
    /// A Mac and an agent that runs alone by a rule stay as they are, as boxes after the others.
    public static func plan(_ places: [ShapePlace], manager: String, to step: ServersStep, hubShared: Bool,
                            joins: Bool) -> ShapeChangePlan {
        let hub = places.first { $0.hub }
        let servers = places.filter { !$0.hub && !$0.mac && !$0.alone }
        let fixed = places.filter { !$0.hub && ($0.mac || $0.alone) }
            .map { ShapeChangePlan.Box(server: $0.name, mac: $0.mac, agents: $0.agents) }
        let onHub = hub?.movable ?? []
        let everyone = (onHub + servers.flatMap(\.movable)).managerFirst(manager)
        // The hub's own agents that stay (on a hub that is a Mac, or alone by a rule) stand in its box at every step.
        let hubStays = (hub?.agents ?? []).filter { !onHub.contains($0) }
        let hubBox = { (agents: [String]) in ShapeChangePlan.Box(server: hub?.name, hub: true, agents: hubStays + agents) }
        var boxes: [ShapeChangePlan.Box] = []
        var moves: [ShapeChangePlan.Move] = []
        var blocked: ShapeChangePlan.Blocked?
        // An agent goes onto a server that has one: a move that the hub may not make yet.
        var joined = false

        switch step {
        case .one:
            boxes = [hubBox(everyone)]
            var there = onHub.count
            for agent in everyone where !onHub.contains(agent) {
                moves.append(.init(agent: agent, box: 0))
                if there > 0 { joined = true }
                there += 1
            }
            if !moves.isEmpty && !hubShared { blocked = .hubTakesNone }
        case .two:
            let target = servers.first { $0.movable.contains(manager) }
                ?? servers.filter { !$0.movable.isEmpty }.max { $0.movable.count < $1.movable.count }
            boxes = [hubBox([]), .init(server: target?.name, agents: everyone)]
            var there = target?.movable.count ?? 0
            for agent in everyone where !(target?.movable.contains(agent) ?? false) {
                moves.append(.init(agent: agent, box: 1))
                if there > 0 { joined = true }
                there += 1
            }
        case .each:
            boxes = [hubBox([])]
            var free = servers.filter { $0.agents.isEmpty && $0.available }.map(\.name)
            var leaving: [String] = onHub
            for place in servers where !place.movable.isEmpty {
                let stays = place.movable.contains(manager) ? manager : place.movable[0]
                boxes.append(.init(server: place.name, agents: [stays]))
                leaving += place.movable.filter { $0 != stays }
            }
            for agent in leaving.managerFirst(manager) {
                boxes.append(.init(server: free.isEmpty ? nil : free.removeFirst(), agents: [agent]))
                moves.append(.init(agent: agent, box: boxes.count - 1))
            }
        }
        if blocked == nil && joined && !joins { blocked = .joins }
        // The manager moves last: a move restarts it, and it is the one that tells him what goes on.
        moves = moves.filter { $0.agent != manager } + moves.filter { $0.agent == manager }
        let emptied = servers.filter { place in !place.movable.isEmpty && !boxes.contains { $0.server == place.name } }
            .map(\.name)
        if blocked == nil && !emptied.isEmpty { blocked = .empties }
        return ShapeChangePlan(step: step, boxes: boxes + fixed, moves: moves, emptied: emptied, blocked: blocked)
    }
}

private extension Array where Element == String {
    /// The manager first, the others in their order.
    func managerFirst(_ manager: String) -> [String] { filter { $0 == manager } + filter { $0 != manager } }
}

extension CloudOffer {
    /// **What `count` servers of this offer cost a month**, in the words of `monthly`: "€11.98 a month".
    public func monthly(times count: Int) -> String {
        let format = NumberFormatter()
        format.numberStyle = .currency
        format.currencyCode = currency
        format.maximumFractionDigits = 2
        let total = monthlyPrice * Decimal(count)
        let amount = format.string(from: total as NSDecimalNumber) ?? "\(total) \(currency)"
        return String(l10n: "\(amount) a month")
    }
}
