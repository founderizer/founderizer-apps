import Foundation

/// **Where each part of the card "Your fleet" stands** (pictures 07 to 10 of 14 November 2026): a box for each
/// machine, the hub, the manager, a row for each agent, a solid line from the manager to each agent and a dotted line
/// from an agent to the one thing it uses. All values are points in a graph of `width`, from its top left. No view is
/// here: `FleetGraph` draws these values, and a test reads them.
public struct FleetGraphLayout: Equatable, Sendable {
    public struct Island: Equatable, Sendable {
        public let rect: CGRect
        public let kind: FleetPlace.Kind
    }

    public struct Row: Equatable, Sendable {
        /// The agent's place in the plan's list.
        public let agent: Int
        /// The one axis of the row: the line from the manager ends on it, the agent's mark and its name are centred
        /// on it, and the dotted line runs on it.
        public let y: CGFloat
        /// The start and the end of the dotted line, for an agent that uses something and has the room for the line.
        public let dotted: ClosedRange<CGFloat>?
    }

    public static let width: CGFloat = 688
    /// An island's inner margin, the room between two rows, and between two islands.
    static let pad: CGFloat = 16, rowGap: CGFloat = 24, islandGap: CGFloat = 14, edge: CGFloat = 8
    /// The height of an agent's row: its mark, or its name with one line under it (its role, or what it asks first),
    /// or with both.
    static let row: CGFloat = 28, rowWithLine: CGFloat = 39, rowWithTwoLines: CGFloat = 55
    /// The least height of the island that holds the manager: its mark and its two lines of words.
    static let managerIsland: CGFloat = 112, ownIsland: CGFloat = 108
    /// The x of each column: the hub's tile, the agents' islands, an agent's mark and its words, and what it uses.
    public static let hubX: CGFloat = 44, islandsX: CGFloat = 240, islandsEnd: CGFloat = 472
    public static let markX: CGFloat = 254, wordsX: CGFloat = 292, usesX: CGFloat = 492, usesWordsX: CGFloat = 530
    public static let lineEnd: CGFloat = 244, dottedEnd: CGFloat = 484
    /// The sides of the marks: the manager's, an agent's, the hub's tile and the tile of what an agent uses.
    public static let manager: CGFloat = 36, agentMark: CGFloat = 28, hubTile: CGFloat = 36, usesTile: CGFloat = 28

    public let islands: [Island]
    public let rows: [Row]
    /// The middle of the manager's mark and of the hub's tile.
    public let managerAt: CGPoint
    public let hubAt: CGPoint
    public let height: CGFloat

    /// `nameWidth` gives the width of an agent's name's words in the card's type, so the dotted line, on the name's
    /// axis, starts after them.
    public init(plan: FleetPlan, step: ServersStep, nameWidth: (String) -> CGFloat) {
        let places = plan.places(step)
        let together = step != .each
        // The agents' groups, one for each island of agents. At the first two steps the first group shares its island
        // with the manager, and it is there with no agent too.
        var groups: [(kind: FleetPlace.Kind, agents: [Int])] = places.compactMap { place in
            let agents = place.parts.compactMap { part -> Int? in if case .agent(let index) = part { index } else { nil } }
            return agents.isEmpty && !(together && place.parts.contains(.manager)) ? nil : (place.kind, agents)
        }
        if together, groups.isEmpty { groups = [(.server, [])] }

        var islands: [Island] = [], anchors: [(agent: Int, y: CGFloat)] = []
        var y = Self.edge, middle: CGFloat = 0
        for (number, group) in groups.enumerated() {
            let top = y, withManager = together && number == 0
            var inner = y + Self.pad, own: [(agent: Int, y: CGFloat)] = []
            for agent in group.agents {
                own.append((agent, inner + Self.agentMark / 2))
                inner += Self.height(plan.agents[agent]) + Self.rowGap
            }
            var bottom = group.agents.isEmpty ? top + 2 * Self.pad : inner - Self.rowGap + Self.pad
            if withManager, bottom - top < Self.managerIsland {
                let lift = ((Self.managerIsland - (bottom - top)) / 2).rounded(.down)
                own = own.map { ($0.agent, $0.y + lift) }
                bottom = top + Self.managerIsland
            }
            anchors += own
            let x = withManager ? (step == .one ? 0 : 108) : Self.islandsX
            islands.append(Island(rect: CGRect(x: x, y: top, width: Self.islandsEnd - x, height: bottom - top), kind: group.kind))
            if withManager { middle = ((top + bottom) / 2).rounded(.down) - 16 }
            y = bottom + Self.islandGap
        }
        var height = groups.isEmpty ? 2 * Self.edge : y - Self.islandGap + Self.edge
        if !together {
            // The manager and the hub each have an island of their own, at the middle of the agents' islands. A team
            // of one agent, or of none, is lower than those two islands: the graph takes their height, and the
            // agents' islands move down to its middle.
            let least = Self.ownIsland + 2 * Self.edge
            if height < least {
                let down = ((least - height) / 2).rounded(.down)
                islands = islands.map { Island(rect: $0.rect.offsetBy(dx: 0, dy: down), kind: $0.kind) }
                anchors = anchors.map { ($0.agent, $0.y + down) }
                height = least
            }
            middle = (height / 2).rounded(.down) - 16
            let top = middle - 36
            islands.append(Island(rect: CGRect(x: 108, y: top, width: 100, height: Self.ownIsland), kind: .server))
            islands.append(Island(rect: CGRect(x: 0, y: top, width: 88, height: Self.ownIsland), kind: .server))
        } else if step == .two {
            // The hub's own island follows the hub's tile: with the picture's team its top is the team's island's top.
            islands.append(Island(rect: CGRect(x: 0, y: middle - 45, width: 88, height: 92), kind: .server))
        }
        self.islands = islands
        self.height = height
        managerAt = CGPoint(x: together ? 160 : 158, y: middle)
        hubAt = CGPoint(x: Self.hubX, y: middle)
        rows = anchors.map { anchor in
            let agent = plan.agents[anchor.agent]
            let start = Self.wordsX + nameWidth(agent.label) + 12
            return Row(agent: anchor.agent, y: anchor.y,
                       dotted: agent.uses != nil && start + 12 <= Self.dottedEnd ? start...Self.dottedEnd : nil)
        }
    }

    /// The height of an agent's row, by the lines under its name: its role beside the name, and what it asks first.
    static func height(_ agent: FleetPlan.Agent) -> CGFloat {
        switch [agent.roleBeside, agent.asksFirst].compactMap({ $0 }).count {
        case 0: row
        case 1: rowWithLine
        default: rowWithTwoLines
        }
    }

    /// The line from the manager to a row: it leaves the manager level, and it arrives at the row level.
    public func line(to row: Row) -> (from: CGPoint, control1: CGPoint, control2: CGPoint, to: CGPoint) {
        let leave = managerAt.x + 26, bend = (leave + Self.lineEnd) / 2
        return (CGPoint(x: leave, y: managerAt.y), CGPoint(x: bend + 6, y: managerAt.y), CGPoint(x: bend - 6, y: row.y),
                CGPoint(x: Self.lineEnd, y: row.y))
    }
}
