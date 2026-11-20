import Foundation
import Testing
@testable import FleetCore

/// Owner feature `need_recommended` (API 1.269; the owner, 20 November 2026: "the model should recommend one response,
/// and we should somehow show that on the UI too, even in multiple choice cards", and his pick "B: badge on the edge" of
/// three pictures): the card marks the row of the answer that the agent recommends, and no other row.
struct NeedRecommendedTests {
    private static let features = ["need_talk", NeedRecommended.feature]
    /// The app's own replies of an item with no options (`NeedAnswerBox.quickReplies`).
    private static let replies = ["Done", "Not now", "Tell me more"]

    private func need(_ extra: [String: Any] = [:]) throws -> OwnerNeed {
        let base: [String: Any] = ["id": 9, "title": "Which day?", "why": "The move needs a day.", "todo": "Pick one",
                                   "raised": 1, "by": "manager", "options": ["Monday", "Friday", "Next week"]]
        return try JSONDecoder().decode(OwnerNeed.self,
                                        from: JSONSerialization.data(withJSONObject: base.merging(extra) { _, new in new }))
    }

    private func row(_ item: OwnerNeed, features: [String]? = features) -> NeedRecommended.Row? {
        item.recommendedRow(features: features, replies: Self.replies)
    }

    /// The badge stands on the option with the agent's words, and on no row from a hub that does not name the feature,
    /// of an item that names none, of an item whose options the app does not draw, or of a key's form. The new field
    /// does not make another card of the one that he pressed on, so a press that waited across the hub's update goes.
    @Test func theBadgeStandsOnTheOptionThatTheAgentRecommendsOnAHubThatNamesIt() throws {
        let older = try need()                                          // a hub before API 1.269 sends no field
        #expect(older.recommended == nil && row(older) == nil)
        #expect(try row(need(["recommended": NSNull()])) == nil)
        let friday = try need(["recommended": "Friday"])
        #expect(row(friday) == .option(1))
        #expect(row(friday, features: ["need_talk"]) == nil && row(friday, features: nil) == nil)   // no feature
        #expect(try row(need(["recommended": "Saturday"])) == nil)      // no option has its words: no row of its own
        #expect(try row(need(["options": ["Only one"], "recommended": "Only one"])) == nil)   // no option drawn
        #expect(try row(need(["kind": "secret", "options": NSNull(), "recommended": "Save it"])) == nil)
        #expect(friday.signsTheSame(as: older))
    }

    /// On an item with no options the agent's own words are one row, trimmed as the box trims his words, so that its
    /// press sends them (`NeedAnswerBox.sendQuickReply` sends only words equal to the box's trimmed words). The app's
    /// reply with exactly those words takes the badge instead, so one answer does not stand on two rows; words of
    /// another case keep a row of their own, because the hub knows the press of the agent's words by its exact words.
    @Test func anItemWithNoOptionsHasTheAgentsOwnWordsAsOneRow() throws {
        #expect(try row(need(["options": NSNull(), "recommended": " No refund, a store credit "]))
                == .words("No refund, a store credit"))
        #expect(try row(need(["options": [String](), "recommended": "Done"])) == .reply(0))
        #expect(try row(need(["options": [String](), "recommended": "done"])) == .words("done"))
        #expect(try row(need(["options": NSNull(), "recommended": "   "])) == nil)
        #expect(try row(need(["options": NSNull(), "recommended": "Two\nlines"])) == nil)
    }
}
