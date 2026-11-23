import CoreGraphics
import FleetCore
import Testing
@testable import Founderizer

/// **The line to a lead's agents leaves after the longer of the lead's two lines** (Settings › Reporting lines, F16's
/// piece 6): the lead's name over its role and " · Lead". The bug that this catches: the width of the name alone, so
/// the line starts inside the role's words and crosses them. The test reads a book of its own, not
/// `AgentNames.shared`, which other tests read.
@MainActor @Test func theLineToALeadsAgentsLeavesAfterItsRole() throws {
    let names = AgentNames()
    names.read([("manager", "Fleet Manager"), ("nova", "Customer Support"), ("kai", "Support Writer")])
    let lines = [ReportingLine(agent: "manager", role: "manager", reports_to: nil),
                 ReportingLine(agent: "nova", role: "lead", reports_to: "manager"),
                 ReportingLine(agent: "kai", role: "worker", reports_to: "nova")]
    let width = ReportingGraph.wordsWidth("nova", lines: lines, names: names)
    #expect(width == ReportingGraph.detailWidth("Customer Support · Lead"))
    #expect(width > ShapeMetrics.nameWidth("Nova"))
    let tree = ReportingTree(lines: lines) { ReportingGraph.wordsWidth($0, lines: lines, names: names) }
    let toKai = try #require(tree.lines.first { $0.agent == "kai" })
    #expect(toKai.from.x == ReportingTree.wordsX(1) + min(width, ReportingTree.wordsMost) + 14)
}
