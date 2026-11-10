import CoreGraphics
import SwiftUI
import Testing
@testable import FleetMark

/// An agent's mark is its face in both apps, so these tests hold it still. They are not about the drawing: they pin
/// the hash, the eleven shapes, the nine hues and the team rule to the marks that the owner's fleet wears today.
/// A change to any of them fails here, which is the point — the owner would otherwise find one morning that his
/// manager had quietly become another creature on one of his two screens.
struct AgentMarkTests {
    /// The hub's order of the owner's fleet.
    private let fleet = ["manager", "vps", "studio", "mini", "scout"]

    @Test("The owner's fleet wears these marks")
    func theFleetsMarks() {
        let looks = GlyphLook.team(fleet)
        #expect(looks["manager"]?.kind == .sparkle)
        #expect(looks["manager"]?.tone == 2)      // lime
        #expect(looks["vps"]?.kind == .clover)
        #expect(looks["vps"]?.tone == 0)          // coral
        #expect(looks["studio"]?.kind == .moon)
        #expect(looks["studio"]?.tone == 5)       // blue
        #expect(looks["mini"]?.kind == .diamond)
        #expect(looks["mini"]?.tone == 8)         // rose
        // Its own name gives scout the diamond and the rose as well, so the team gives it its next look.
        #expect(looks["scout"]?.kind == .triangle)
        #expect(looks["scout"]?.tone == 6)        // sand
    }

    /// **A lobed shape is one area with one edge** (fix round 3, item 52): the dashed outline of an agent in setup strokes
    /// it, and a stroke of the circles laid one over another dashed every circle.
    @Test("The clover and the flower are each one outline")
    func lobesAreOneOutline() {
        for kind in [GlyphKind.clover, .flower] {
            let path = GlyphOutline(kind: kind).path(in: CGRect(x: 0, y: 0, width: 100, height: 100))
            var starts = 0
            path.forEach { if case .move = $0 { starts += 1 } }
            #expect(starts == 1, "\(kind) has \(starts) outlines")
            // Still the area: its middle is inside it, a corner of its square is not.
            #expect(path.contains(CGPoint(x: 50, y: 50)))
            #expect(!path.contains(CGPoint(x: 1, y: 1)))
        }
    }

    @Test("A name alone keeps its first look, whatever team it is in")
    func aNameAloneKeepsItsFirstLook() {
        #expect(GlyphLook(name: "manager").kind == .sparkle)
        #expect(GlyphLook(name: "manager").tone == 2)
        #expect(GlyphLook(name: "scout").kind == .diamond)
        #expect(GlyphLook(name: "scout").tone == 8)
        // The case of the name does not change the mark: the hash reads it in lower case.
        #expect(GlyphLook(name: "Manager").kind == GlyphLook(name: "manager").kind)
        #expect(GlyphLook(name: "MANAGER").tone == GlyphLook(name: "manager").tone)
    }

    @Test("No two agents of one team share a shape or a hue")
    func aTeamDiffersInShapeAndHue() {
        for names in [["manager", "vps", "studio", "mini", "scout"],
                      ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota"]] {
            let looks = GlyphLook.team(names)
            #expect(looks.count == names.count)
            #expect(Set(looks.values.map(\.kind)).count == names.count)
            #expect(Set(looks.values.map(\.tone)).count == names.count)
        }
    }

    @Test("An agent that joins at the end changes no other agent")
    func aNewAgentChangesNoOther() {
        let before = GlyphLook.team(fleet)
        let after = GlyphLook.team(fleet + ["courier"])
        for name in fleet {
            #expect(before[name]?.kind == after[name]?.kind)
            #expect(before[name]?.tone == after[name]?.tone)
        }
        #expect(after["courier"] != nil)
    }

    @Test("A team longer than the lists starts them again rather than giving up")
    func aLongTeamStartsTheListsAgain() {
        let names = (1...14).map { "agent\($0)" }
        let looks = GlyphLook.team(names)
        #expect(looks.count == names.count)
        // The first nine differ in hue; the tenth starts the hues again, and no name is left without a look.
        #expect(Set(names.prefix(9).compactMap { looks[$0]?.tone }).count == 9)
    }

    @Test("Each shape has a start time of its own and an anchor for its inner mark")
    func everyShapeIsDrawable() {
        for kind in GlyphKind.allCases {
            let square = CGRect(x: 0, y: 0, width: 40, height: 40)
            #expect(!GlyphOutline(kind: kind).path(in: square).isEmpty)
            #expect(!GlyphCore(kind: kind).path(in: square).isEmpty)
            #expect(kind.coreAnchor.x >= 0 && kind.coreAnchor.x <= 1)
        }
        // Two agents do not breathe as one: the phase comes from the name.
        #expect(GlyphLook(name: "manager").phase != GlyphLook(name: "vps").phase)
        #expect(GlyphLook(name: "manager").phase == GlyphLook(name: "manager").phase)
    }
}
