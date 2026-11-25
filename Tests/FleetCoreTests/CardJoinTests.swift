import Foundation
import Testing
@testable import FleetCore

/// A card's pieces with a name and its role as one (`CardJoin`).
struct CardJoinTests {
    /// **A name beside its role is one badge with the name** (the owner, 21 November 2026: "it should be the same,
    /// right? or show it only once!"; 22 November 2026: "the names should show ... in needs you cards"): on a card, an
    /// agent's name and its own role, in a bracket, after a comma or a dash and the other way round, are one badge whose
    /// words are the name as written, with its link; the role and the bracket's ")" go with it, and every other
    /// character stays in its order. Where the agent's label is its role (a role that says the name, "Fleet
    /// Manager"), the badge is the role. **A whole role alone is a badge with the name and the role beside it** (the
    /// owner, 23 November 2026: "We should ALWAYS use the name"; `RoleNames`). Two agents, and a name and its role with other words between
    /// them, stay two badges, and so do a name and its role in the owner's own words (`RoleNames.Written`). The bug that
    /// this catches: a card draws the role where the agent wrote the name and the role, or the role alone (the rules
    /// before), draws "Manager" where every other place says "Fleet Manager", draws the same agent twice, or drops the
    /// role from an answer that he typed.
    @Test func aNameBesideItsRoleIsOneBadgeWithTheName() {
        let team: [(name: String, role: String?)] = [("nova", "Customer Support Lead"), ("mia", "Web Developer"),
                                                     ("manager", "Fleet Manager")]
        let book = CardNames(agents: team), roles = AgentNames.roles(team.map { ($0.name, $0.role) })
        func drawn(_ text: String) -> [String] {
            CardJoin.join(book.pieces(AttributedString(text)), roles: roles).map {
                $0.badge == nil ? String($0.words.characters) : "[\(String($0.words.characters))]"
            }
        }
        for text in ["Then ask Nova (Customer Support Lead) first.", "Then ask Customer Support Lead (Nova) first.",
                     "Then ask Nova, Customer Support Lead first.", "Then ask Nova - Customer Support Lead first.",
                     "Then ask Nova – Customer Support Lead first.", "Then ask Customer Support Lead — Nova first."] {
            #expect(drawn(text) == ["Then ask ", "[Nova]", " first."], "\(text)")
        }
        // a start of the role that the book holds; the bracket at the words' end
        #expect(drawn("Then ask Nova (Customer Support)") == ["Then ask ", "[Nova]"])
        let one = CardJoin.join(book.pieces(AttributedString("Nova (Customer Support Lead)")), roles: roles)
        #expect(one.map(\.badge) == [.agent("nova")])
        #expect(String(one[0].words.characters) == "Nova" && one[0].words.link == CardNames.Target.agent("nova").url)
        // a role that says the name: the label is the role, either way round
        #expect(drawn("Then ask Manager (Fleet Manager) first.") == ["Then ask ", "[Fleet Manager]", " first."])
        #expect(drawn("Then ask Fleet Manager, Manager first.") == ["Then ask ", "[Fleet Manager]", " first."])
        // a whole role alone is a badge with the name
        #expect(drawn("Then ask Customer Support Lead first.") ==
                ["Then ask ", "[Nova · Customer Support Lead]", " first."])
        // two agents; other words between; a bracket that does not close right after the role
        #expect(drawn("Nova (Web Developer) first.") == ["[Nova]", " (", "[Mia · Web Developer]", ") first."])
        #expect(drawn("Nova and Customer Support Lead") == ["[Nova]", " and ", "[Customer Support Lead]"])
        #expect(drawn("Nova (Customer Support Lead, EU)") == ["[Nova]", " (", "[Customer Support Lead]", ", EU)"])
        // the owner's own words (his typed answer) keep every word that he wrote, and the agent shows once: the name is
        // the badge, and its role beside it is plain words with no link (his "show it only once!" of 21 November 2026)
        func his(_ text: String) -> [CardNames.Piece] {
            CardJoin.join(book.pieces(RoleNames.written(AttributedString(text))), roles: roles)
        }
        let asked = his("I asked Nova (Customer Support Lead).")
        #expect(asked.map { String($0.words.characters) } == ["I asked ", "Nova", " (", "Customer Support Lead", ")."])
        #expect(asked.map(\.badge) == [nil, .agent("nova"), nil, nil, nil])
        #expect(asked.allSatisfy { $0.badge != nil || $0.words.link == nil })
        let first = his("Customer Support Lead, Nova")
        #expect(first.map { String($0.words.characters) } == ["Customer Support Lead", ", ", "Nova"])
        #expect(first.map(\.badge) == [nil, nil, .agent("nova")])
    }
}
