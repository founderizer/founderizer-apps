import Foundation

/// **Where each part of the Reporting lines graph stands** (the owner's yes of 14 November 2026 to its three pictures:
/// "Yes, build it"): the owner, the manager, the agents that report to it, and each lead's own agents in a box, from
/// left to right, with one line for each reporting line. All values are points in a graph of `width`, from its top
/// left. No view is here: `ReportingGraph` draws these values, and a test reads them.
///
/// The lines can be wrong while the owner changes them (an agent whose lead became a worker, two leads that report to
/// each other). Such an agent has no way to the manager: it stands in the first column with no line, and the page's
/// own orange line says what is wrong (`TeamLinesInput.problem`).
public struct ReportingTree: Equatable, Sendable {
    public struct Node: Equatable, Sendable {
        public let agent: String
        /// The column: 1 for an agent that reports to the manager, 2 for an agent of such a lead.
        public let depth: Int
        /// The row's axis: the agent's mark and its words are centred on it.
        public let y: CGFloat
        /// False for an agent with no way to the manager: it has no line.
        public let linked: Bool
    }

    public struct Line: Equatable, Sendable {
        /// The agent that reports, at the line's end. nil for the line from the owner to the manager.
        public let agent: String?
        public let from: CGPoint
        public let to: CGPoint
    }

    /// The card's width on a form page, which the graph has with a team of up to three columns.
    public static let least: CGFloat = 680
    /// The room of a row, the room over the first row and under the last, and the room before and after a team's box.
    static let row: CGFloat = 46, edge: CGFloat = 44, teamGap: CGFloat = 12, boxInset: CGFloat = 20
    /// The middle of the owner's mark and of the manager's, the left edge of the first column's marks, and the step
    /// from a column to the next.
    public static let youX: CGFloat = 42, managerX: CGFloat = 150, firstX: CGFloat = 238, columnStep: CGFloat = 224
    /// The sides of the marks, and what a node's words can take at most, so that a line always has room to bend.
    public static let managerMark: CGFloat = 36, mark: CGFloat = 28, wordsGap: CGFloat = 8, wordsMost: CGFloat = 150

    public let nodes: [Node]
    /// The box of each team, around the agents of one lead.
    public let boxes: [CGRect]
    public let lines: [Line]
    /// The middle of the manager's mark; the owner's stands on the same axis.
    public let managerAt: CGPoint
    public let youAt: CGPoint
    public let width: CGFloat
    public let height: CGFloat
    public let manager: String?

    /// The left edge of a column's marks, and of its words.
    public static func markX(_ depth: Int) -> CGFloat { firstX + columnStep * CGFloat(depth - 1) }
    public static func wordsX(_ depth: Int) -> CGFloat { markX(depth) + mark + wordsGap }

    /// `wordsWidth` gives the width of an agent's words (its name and the line under it) in the graph's type, so that
    /// the line to a lead's agents starts after the lead's words.
    public init(lines: [ReportingLine], wordsWidth: (String) -> CGFloat) {
        let manager = lines.first { $0.role == "manager" }?.agent
        let known = Dictionary(lines.map { ($0.agent, $0) }, uniquingKeysWith: { first, _ in first })
        // A reporting line counts only when it ends at the manager or at a lead, and not at the agent itself.
        var kids: [String: [String]] = [:]
        for line in lines where line.agent != manager {
            guard let parent = line.reports_to, parent != line.agent, let above = known[parent],
                  ["manager", "lead"].contains(above.role) else { continue }
            kids[parent, default: []].append(line.agent)
        }

        var nodes: [Node] = [], seen: Set<String> = [], deepest = 1
        // A team's box: its left edge, its top and its height, and the column of its lead.
        var teams: [(left: CGFloat, top: CGFloat, height: CGFloat, level: Int)] = []
        var y = Self.edge
        func lay(_ parent: String, depth: Int) {
            for child in kids[parent] ?? [] where seen.insert(child).inserted {
                deepest = max(deepest, depth)
                let own = (kids[child] ?? []).filter { !seen.contains($0) }
                guard !own.isEmpty else {
                    nodes.append(Node(agent: child, depth: depth, y: y, linked: true))
                    y += Self.row
                    continue
                }
                // A team: the room before its box, its agents' rows, and the lead at the middle of them.
                if y != Self.edge || depth > 1 { y += Self.teamGap }
                let top = y, first = nodes.count
                lay(child, depth: depth + 1)
                let rows = nodes[first...].filter { $0.depth == depth + 1 }.map(\.y)
                teams.append((Self.markX(depth + 1) - 10, top - Self.boxInset, y - Self.row - top + 2 * Self.boxInset, depth))
                nodes.append(Node(agent: child, depth: depth, y: (((rows.first ?? top) + (rows.last ?? top)) / 2).rounded(.down), linked: true))
                y += Self.teamGap
            }
        }
        if let manager {
            seen.insert(manager)
            lay(manager, depth: 1)
        }
        // An agent with no way to the manager: in the first column, under the others, with no line.
        for line in lines where line.agent != manager && seen.insert(line.agent).inserted {
            nodes.append(Node(agent: line.agent, depth: 1, y: y, linked: false))
            y += Self.row
        }

        let width = max(Self.least, Self.markX(deepest) + Self.columnStep - 6)
        // A box ends 18 points before the graph's right edge, and a box in a box 8 points before that one.
        boxes = teams.map {
            CGRect(x: $0.left, y: $0.top, width: width - 18 - 8 * CGFloat($0.level - 1) - $0.left, height: $0.height)
        }
        let firsts = nodes.filter { $0.depth == 1 }.map(\.y)
        let middle = firsts.isEmpty ? Self.edge : (((firsts.min() ?? 0) + (firsts.max() ?? 0)) / 2).rounded(.down)
        let low = max(nodes.map(\.y).max() ?? Self.edge, boxes.map { $0.maxY - Self.boxInset }.max() ?? 0)
        height = max(low + Self.edge + 6, middle + 62)
        self.width = width
        self.manager = manager
        managerAt = CGPoint(x: Self.managerX, y: middle)
        youAt = CGPoint(x: Self.youX, y: middle)
        self.nodes = nodes

        var drawn: [Line] = manager == nil ? [] : [Line(agent: nil, from: CGPoint(x: Self.youX + 26, y: middle),
                                                        to: CGPoint(x: Self.managerX - 26, y: middle))]
        let at = Dictionary(nodes.map { ($0.agent, $0) }, uniquingKeysWith: { first, _ in first })
        for node in nodes where node.linked {
            guard let parent = known[node.agent]?.reports_to else { continue }
            if parent == manager {
                drawn.append(Line(agent: node.agent, from: CGPoint(x: Self.managerX + 26, y: middle),
                                  to: CGPoint(x: Self.firstX - 10, y: node.y)))
            } else if let lead = at[parent] {
                let leave = Self.wordsX(lead.depth) + min(wordsWidth(parent), Self.wordsMost) + 14
                drawn.append(Line(agent: node.agent, from: CGPoint(x: leave, y: lead.y),
                                  to: CGPoint(x: Self.markX(node.depth) - 14, y: node.y)))
            }
        }
        self.lines = drawn
    }
}

extension ReportingTree.Line {
    /// The two points that bend the line: it leaves level, and it arrives level.
    public var controls: (CGPoint, CGPoint) {
        let bend = (from.x + to.x) / 2
        return (CGPoint(x: bend + 6, y: from.y), CGPoint(x: bend - 6, y: to.y))
    }
}
