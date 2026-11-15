import Foundation
import Testing
@testable import FleetCore

/// **The places of the Reporting lines graph** (`ReportingTree`). The first team is the one of the three pictures that
/// the owner approved on 14 November 2026, and its values are the pictures' own.
struct ReportingTreeTests {
    private func line(_ agent: String, _ role: String, _ boss: String?) -> ReportingLine {
        ReportingLine(agent: agent, role: role, reports_to: boss)
    }

    /// The team of the pictures: two leads with their agents, and two agents that report to the manager.
    private var team: [ReportingLine] {
        [line("manager", "manager", nil), line("eng", "lead", "manager"), line("web", "worker", "eng"),
         line("mobile", "worker", "eng"), line("devops", "worker", "eng"), line("support", "worker", "manager"),
         line("marketing", "lead", "manager"), line("content", "worker", "marketing"), line("ads", "worker", "marketing"),
         line("research", "worker", "manager")]
    }

    /// The tree with a stand-in for the width of an agent's words: 7 points for each character of its name.
    private func tree(_ lines: [ReportingLine]) -> ReportingTree { ReportingTree(lines: lines) { CGFloat($0.count) * 7 } }

    private func y(_ tree: ReportingTree, _ agent: String) -> CGFloat? { tree.nodes.first { $0.agent == agent }?.y }

    @Test func thePlacesOfThePictures() {
        let tree = tree(team)
        #expect(tree.width == 680)
        #expect(tree.height == 406)
        #expect(tree.managerAt == CGPoint(x: 150, y: 223))
        #expect(tree.youAt == CGPoint(x: 42, y: 223))
        #expect(["web", "mobile", "devops"].map { y(tree, $0) } == [44, 90, 136])
        #expect(y(tree, "eng") == 90)
        #expect(y(tree, "support") == 194)
        #expect(["content", "ads"].map { y(tree, $0) } == [252, 298])
        #expect(y(tree, "marketing") == 275)
        #expect(y(tree, "research") == 356)
        #expect(tree.boxes == [CGRect(x: 452, y: 24, width: 210, height: 132), CGRect(x: 452, y: 232, width: 210, height: 86)])
    }

    @Test func eachReportingLineIsOneLineAndTheOwnersIsFirst() {
        let tree = tree(team)
        #expect(tree.lines.count == 10)
        #expect(tree.lines[0] == ReportingTree.Line(agent: nil, from: CGPoint(x: 68, y: 223), to: CGPoint(x: 124, y: 223)))
        #expect(tree.lines.first { $0.agent == "support" } == ReportingTree.Line(agent: "support", from: CGPoint(x: 176, y: 223),
                                                                              to: CGPoint(x: 228, y: 194)))
        // A line to a lead's agent starts after the lead's words: 274 for its words, 21 for "eng", and 14 of room.
        #expect(tree.lines.first { $0.agent == "web" } == ReportingTree.Line(agent: "web", from: CGPoint(x: 309, y: 90),
                                                                          to: CGPoint(x: 448, y: 44)))
        for agent in team.map(\.agent) where agent != "manager" { #expect(tree.lines.filter { $0.agent == agent }.count == 1) }
    }

    @Test func aLongRoleLeavesTheLineItsRoomToBend() {
        var lines = team
        lines[1] = line(String(repeating: "e", count: 40), "lead", "manager")
        for index in 2...4 { lines[index].reports_to = lines[1].agent }
        let tree = tree(lines)
        let web = tree.lines.first { $0.agent == "web" }
        // 274 for the lead's words, their most width of 150, and 14 of room.
        #expect(web?.from.x == CGFloat(438))
        #expect((web?.to.x ?? 0) - (web?.from.x ?? 0) >= 10)
    }

    @Test func anAgentWhoseLeadBecameAWorkerStandsInTheFirstColumnWithNoLine() {
        var lines = team
        lines[1].role = "worker"
        let tree = tree(lines)
        #expect(tree.boxes.count == 1)
        for agent in ["web", "mobile", "devops"] {
            let node = tree.nodes.first { $0.agent == agent }
            #expect(node?.depth == 1)
            #expect(node?.linked == false)
            #expect(!tree.lines.contains { $0.agent == agent })
        }
        #expect(tree.nodes.count == 9)
        #expect((y(tree, "web") ?? 0) > (y(tree, "research") ?? 0))
    }

    @Test func twoLeadsThatReportToEachOtherHaveNoLine() {
        let tree = tree([line("manager", "manager", nil), line("a", "lead", "b"), line("b", "lead", "a"), line("c", "worker", "manager")])
        #expect(tree.nodes.map(\.agent) == ["c", "a", "b"])
        #expect(tree.nodes.map(\.linked) == [true, false, false])
        #expect(tree.lines.compactMap(\.agent) == ["c"])
        #expect(tree.boxes.isEmpty)
    }

    @Test func aLeadUnderALeadAddsAColumnAndItsBoxStandsInTheOuterBox() {
        let tree = tree([line("manager", "manager", nil), line("eng", "lead", "manager"), line("web", "worker", "eng"),
                         line("apps", "lead", "eng"), line("ios", "worker", "apps"), line("android", "worker", "apps")])
        #expect(tree.nodes.first { $0.agent == "ios" }?.depth == 3)
        #expect(tree.width == ReportingTree.markX(3) + 218)
        #expect(tree.boxes.count == 2)
        let outer = tree.boxes.max { $0.width < $1.width }, inner = tree.boxes.min { $0.width < $1.width }
        if let outer, let inner {
            #expect(outer.contains(inner))
            #expect(inner.minY - outer.minY >= 8 && outer.maxY - inner.maxY >= 8 && outer.maxX - inner.maxX >= 8)
        }
    }

    @Test func eachNodeHasItsOwnPlaceInsideTheGraph() {
        var deep = team
        deep.append(line("apps", "lead", "eng"))
        deep.append(line("ios", "worker", "apps"))
        for lines in [team, deep, [line("manager", "manager", nil)], [line("manager", "manager", nil), line("solo", "worker", "manager")]] {
            let tree = tree(lines)
            #expect(tree.nodes.count == lines.count - 1)
            #expect(Set(tree.nodes.map { "\($0.depth):\($0.y)" }).count == tree.nodes.count)
            for node in tree.nodes {
                #expect(node.y - 20 >= 0 && node.y + 20 <= tree.height)
                #expect(ReportingTree.wordsX(node.depth) + ReportingTree.wordsMost <= tree.width)
            }
            for box in tree.boxes { #expect(box.minY >= 0 && box.maxY <= tree.height && box.maxX <= tree.width) }
            #expect(tree.managerAt.y + 42 <= tree.height)
        }
    }

    @Test func aManagerWithNoAgentHasOnlyTheOwnersLine() {
        let tree = tree([line("manager", "manager", nil)])
        #expect(tree.nodes.isEmpty)
        #expect(tree.lines.count == 1)
        #expect(tree.height == 106)
    }

    @Test func aTeamWithNoManagerDrawsEachAgentWithNoLine() {
        let tree = tree([line("a", "worker", "b"), line("b", "worker", nil)])
        #expect(tree.manager == nil)
        #expect(tree.lines.isEmpty)
        #expect(tree.nodes.map(\.linked) == [false, false])
    }
}
