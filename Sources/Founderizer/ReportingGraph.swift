import AppKit
import FleetCore
import SwiftUI

/// **The reporting lines as a graph** (Settings › Reporting lines; the owner, 14 November 2026, of the card "Your
/// fleet": "can we also apply the same idea to Reporting Lines page inside Settings? so it looks muuch better like
/// this!", and "Yes, build it" to its three pictures). From left to right: the owner, the manager, the agents that
/// report to it, and each lead's own agents in a box, with one line for each reporting line. A press on an agent
/// opens its menu: whom it reports to, and its role where the role can change now. A line that changed is in the
/// text's colour until it is saved. The page keeps its own rules, its Save and its lines about a team that changed
/// (`TeamEditor`): this view draws the lines and takes the choice, and no more.
struct ReportingGraph: View {
    @Binding var input: TeamLinesInput
    let original: TeamSnapshot
    /// The hub lets the owner make an agent a lead.
    let allowsLeads: Bool
    /// The hub's last reading and whether it is fresh, for the status dots in an agent's menu.
    let state: HubState?
    let isFresh: Bool

    /// One row of an agent's menu.
    private enum Choice: Hashable {
        case boss(String), role(String)
    }

    var body: some View {
        let tree = ReportingTree(lines: input.lines) { Self.wordsWidth($0, lines: input.lines) }
        // An agent whose line is not the saved one.
        let moved = Set(input.lines.filter { line in original.lines.first { $0.agent == line.agent }?.reports_to != line.reports_to }
            .map(\.agent))
        // A team with a lead under a lead is wider than the card: it moves sideways inside the card.
        ViewThatFits(in: .horizontal) {
            graph(tree, moved)
            ScrollView(.horizontal) { graph(tree, moved) }
        }
    }

    private func graph(_ tree: ReportingTree, _ moved: Set<String>) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(tree.boxes.enumerated()), id: \.offset) { _, box in
                RoundedRectangle(cornerRadius: FormMetrics.inner).fill(ShapeMetrics.islandFill)
                    .overlay(RoundedRectangle(cornerRadius: FormMetrics.inner).strokeBorder(ShapeMetrics.islandEdge, lineWidth: 0.5))
                    .frame(width: box.width, height: box.height).offset(x: box.minX, y: box.minY)
                    .accessibilityHidden(true)
            }
            path(tree.lines.filter { !moved.contains($0.agent ?? "") })
                .stroke(ShapeMetrics.line, style: StrokeStyle(lineWidth: ShapeMetrics.lineWidth, lineCap: .round))
            path(tree.lines.filter { moved.contains($0.agent ?? "") })
                .stroke(FleetStyle.text, style: StrokeStyle(lineWidth: ShapeMetrics.lineWidth, lineCap: .round))
            if let manager = tree.manager {
                Image(systemName: "person").font(IconMetrics.symbol(15)).foregroundStyle(ShapeMetrics.tileInk)
                    .frame(width: ReportingTree.managerMark, height: ReportingTree.managerMark)
                    .background(ShapeMetrics.tileFill, in: Circle())
                    .position(tree.youAt).accessibilityHidden(true)
                under(String(l10n: "You"), at: tree.youAt)
                AgentGlyph(name: manager, size: ReportingTree.managerMark).position(tree.managerAt)
                under(manager.agentLabel, at: tree.managerAt)
            }
            ForEach(tree.nodes, id: \.agent) { node in agent(node) }
        }
        .frame(width: tree.width, height: tree.height, alignment: .topLeading)
    }

    private func path(_ lines: [ReportingTree.Line]) -> Path {
        Path { path in
            for line in lines {
                let (first, second) = line.controls
                path.move(to: line.from)
                path.addCurve(to: line.to, control1: first, control2: second)
            }
        }
    }

    /// The words under the owner's mark and under the manager's, in the middle.
    private func under(_ words: String, at point: CGPoint) -> some View {
        Text(words).font(FormMetrics.title).foregroundStyle(FleetStyle.text).lineLimit(1)
            .frame(width: 90, height: ShapeMetrics.nameLine)
            .offset(x: point.x - 45, y: point.y + 24)
    }

    /// **The width of a lead's words**: the longer of its name in the title font and its second line in the detail
    /// font, so that the line to its agents leaves after both (`ReportingTree`, which takes at most
    /// `ReportingTree.wordsMost` of it).
    @MainActor static func wordsWidth(_ agent: String, lines: [ReportingLine], names: AgentNames = .shared) -> CGFloat {
        let lead = lines.first { $0.agent == agent }?.role == "lead"
        return max(ShapeMetrics.nameWidth(names.label(agent)),
                   detailWidth(names.graphLine(agent, lead: lead)?.words ?? ""))
    }

    /// The width of a second line's words in the detail font, as `ShapeMetrics.nameWidth` measures a name.
    @MainActor static func detailWidth(_ words: String) -> CGFloat {
        (words as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: FormMetrics.detailSize)]).width
            .rounded(.up)
    }

    /// **One agent: its mark, its name, and under the name its role, muted, with " · Lead" after it for a lead** (the
    /// owner's answer of 22 November 2026: "the role under the name in Reporting lines"; `AgentNames.graphLine`): "Lead"
    /// alone for a lead with no role beside its name, and one line for any other agent with none. The role is cut at
    /// its end where the words pass `ReportingTree.wordsMost`, and " · Lead" stays whole. Its menu is behind them.
    @ViewBuilder private func agent(_ node: ReportingTree.Node) -> some View {
        if let index = input.lines.firstIndex(where: { $0.agent == node.agent }) {
            let line = input.lines[index]
            let tasks = original.open_tasks[line.agent] ?? 0
            let second = AgentNames.shared.graphLine(line.agent, lead: line.role == "lead")
            // VoiceOver reads the node's words in its name, each once ("Nova, Customer Support, Lead reports to", or
            // "Nova reports to"), and the agent that it reports to as its value.
            let words = [line.agent.agentLabel, second?.role, second?.position].compactMap { $0 }.joined(separator: ", ")
            FleetSelect(String(l10n: "\(line.agent.agentLabel) reports to"), options: options(line, role: allowsLeads && tasks == 0),
                        checked: Set([Choice.role(line.role)] + (line.reports_to.map { [Choice.boss($0)] } ?? [])),
                        voiceLabel: String(l10n: "\(words) reports to"), voiceValue: line.reports_to?.agentLabel,
                        onSelect: { choose($0, for: line.agent) }) {
                HStack(spacing: ReportingTree.wordsGap) {
                    AgentGlyph(name: line.agent, size: ReportingTree.mark)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(line.agent.agentLabel).font(FormMetrics.title).foregroundStyle(FleetStyle.text)
                            .frame(height: ShapeMetrics.nameLine)
                        if let second {
                            HStack(spacing: 0) {
                                if let role = second.role { Text(verbatim: role).truncationMode(.tail) }
                                if let end = second.end { Text(verbatim: end).fixedSize() }
                            }
                            .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).frame(height: ShapeMetrics.underLine)
                        }
                    }
                    // **The words' own width, at most `wordsMost`**: a frame of a set width proposes it to the role, so
                    // a longer role is cut at its end, and " · Lead" stays whole. One point more than the measure, so
                    // that a name that fits is never cut.
                    .lineLimit(1)
                    .frame(width: min(Self.wordsWidth(line.agent, lines: input.lines) + 1, ReportingTree.wordsMost),
                           alignment: .leading)
                }
                .padding(.leading, 6).padding(.trailing, 10).frame(height: 40)
            }
            .buttonStyle(ReportingNodeStyle())
            // The role of an agent with open tasks cannot change: its menu has no Role, and the pointer says why.
            .help(tasks == 0 ? "" : tasks == 1 ? String(l10n: "1 open task · role locked") : String(l10n: "\(tasks) open tasks · role locked"))
            .offset(x: ReportingTree.markX(node.depth) - 6, y: node.y - 20)
        }
    }

    /// The rows of an agent's menu: the manager and each lead that is not under this agent, then the two roles.
    private func options(_ line: ReportingLine, role: Bool) -> [FleetOption<Choice>] {
        let above = Dictionary(input.lines.map { ($0.agent, $0.reports_to) }, uniquingKeysWith: { first, _ in first })
        func isUnder(_ name: String) -> Bool {
            var next = above[name] ?? nil, seen: Set<String> = [name]
            while let boss = next, seen.insert(boss).inserted {
                if boss == line.agent { return true }
                next = above[boss] ?? nil
            }
            return false
        }
        var rows = input.lines.filter { $0.agent != line.agent && ["manager", "lead"].contains($0.role) && !isUnder($0.agent) }.map {
            FleetOption(Choice.boss($0.agent), $0.agent.agentLabel, subtitle: $0.role == "lead" ? String(l10n: "Lead") : nil,
                        mark: .agent($0.agent, state: state, isFresh: isFresh), section: String(l10n: "Reports to"))
        }
        if role {
            rows.append(FleetOption(Choice.role("worker"), String(l10n: "Worker"), mark: .symbol("person"), section: String(l10n: "Role")))
            rows.append(FleetOption(Choice.role("lead"), String(l10n: "Lead"),
                                    subtitle: String(l10n: "Gives tasks to the agents that report to it"),
                                    mark: .symbol("person.2"), section: String(l10n: "Role")))
        }
        return rows
    }

    private func choose(_ choice: Choice, for agent: String) {
        guard let index = input.lines.firstIndex(where: { $0.agent == agent }) else { return }
        switch choice {
        case .boss(let name): input.lines[index].reports_to = name
        case .role(let role): input.lines[index].role = role
        }
    }
}

/// An agent of the graph as a button: a row's soft fill under the pointer, and a stronger one while it is pressed.
private struct ReportingNodeStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Node(configuration: configuration) }

    private struct Node: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovered = false

        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: FormMetrics.inner)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.08 : hovered ? 0.05 : 0)))
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
        }
    }
}
