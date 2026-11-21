import Foundation
import Testing
@testable import FleetCore

/// A card's pieces with a name and its role as one (`CardJoin`).
struct CardJoinTests {
    /// **A name beside its role is one badge with the role** (the owner, 21 November 2026: "it should be the same,
    /// right? or show it only once!"): on a card, an agent's name and its own role, in a bracket, after a comma or a
    /// dash and the other way round, are one badge whose words are the role as written, with its link; the bracket's
    /// ")" goes with it, and every other character stays in its order. Two agents, and a name and its role with other
    /// words between them, stay two badges. A card that kept both drew the same agent twice.
    @Test func aNameBesideItsRoleIsOneBadgeWithTheRole() {
        let book = CardNames(agents: [("nova", "Customer Support Lead"), ("mia", "Web Developer")])
        func drawn(_ text: String) -> [String] {
            CardJoin.join(book.pieces(AttributedString(text))).map {
                $0.badge == nil ? String($0.words.characters) : "[\(String($0.words.characters))]"
            }
        }
        for text in ["Then ask Nova (Customer Support Lead) first.", "Then ask Customer Support Lead (Nova) first.",
                     "Then ask Nova, Customer Support Lead first.", "Then ask Nova - Customer Support Lead first.",
                     "Then ask Nova – Customer Support Lead first.", "Then ask Customer Support Lead — Nova first."] {
            #expect(drawn(text) == ["Then ask ", "[Customer Support Lead]", " first."], "\(text)")
        }
        // a start of the role that the book holds; the bracket at the words' end
        #expect(drawn("Then ask Nova (Customer Support)") == ["Then ask ", "[Customer Support]"])
        let one = CardJoin.join(book.pieces(AttributedString("Nova (Customer Support Lead)")))
        #expect(one.map(\.badge) == [.agent("nova")])
        #expect(one[0].words.link == CardNames.Target.agent("nova").url)
        // two agents; other words between; a bracket that does not close right after the role
        #expect(drawn("Nova (Web Developer) first.") == ["[Nova]", " (", "[Web Developer]", ") first."])
        #expect(drawn("Nova and Customer Support Lead") == ["[Nova]", " and ", "[Customer Support Lead]"])
        #expect(drawn("Nova (Customer Support Lead, EU)") == ["[Nova]", " (", "[Customer Support Lead]", ", EU)"])
    }
}
