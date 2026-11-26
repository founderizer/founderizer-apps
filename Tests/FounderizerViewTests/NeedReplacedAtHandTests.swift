import AppKit
import FleetCore
import Testing
@testable import Founderizer

/// **The request at hand that the manager replaced gives its place to the new item** (owner API 1.274, `replaced_by`;
/// the owner's feedback of 22 November 2026, F13a): the hub closes the old item with its own words ("Replaced by Fleet
/// Manager with a new item: …") and raises the new one. Needs you kept the old item at hand as one that ended in
/// another way, so he read the hub's words in the place of the new card, which no page shows (`NeedReplaced`).
@Suite(.serialized, .timeLimit(.minutes(10))) struct NeedReplacedAtHandTests {
    private static let now = Int(Date().timeIntervalSince1970)

    /// A reading of the manager and these items, of the database `db`: the second reading is of the same hub and
    /// generation as the first, as the hub's next answer is, so the page keeps what it knows of the lane.
    private static func reading(_ needs: [[String: Any]], db: String) throws -> HubState {
        let agents: [[String: Any]] = [["name": "manager", "role": "manager", "title": "Fleet Manager", "runtime": "claude",
                                        "can": [], "placed": true]]
        return try HubState.decode(JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "db": db, "time": now, "agents": agents, "tasks": [], "holds": [], "outcomes": [],
            "notes": [], "needs": needs, "permissions": [], "messages": [], "reports": [], "ui_features": []]
            as [String: Any]))
    }

    private static func need(_ id: Int, _ title: String, options: [String], _ extra: [String: Any] = [:]) -> [String: Any] {
        ["id": id, "title": title, "why": "", "todo": "Choose one", "raised": now - 300 + id, "by": "manager",
         "options": options, "answered": NSNull()].merging(extra) { _, new in new }
    }

    /// Request 9, which waits under 12 in the lane: with no rule for a replaced request, it is the one that comes to
    /// hand when 12 leaves.
    private static var under: [String: Any] { need(9, "Approve the office lease", options: ["Approve", "Wait"]) }

    struct Seen: Sendable {
        /// Words that only item 15 at hand draws: an option of it while it waits, his answer once it ended.
        let newAtHand: Bool
        /// The hub's words of the replaced item stand somewhere on the page.
        let hubWords: Bool
        let chosen: Int?
    }

    /// Item 12 at hand, with 9 under it in the lane; then the hub's next reading, in which `new`, item 15, replaced 12.
    /// It reads the page for `words` and for the hub's words.
    @MainActor private static func replace12(by new: [String: Any], reading words: String) throws -> Seen {
        let db = "replaced-\(UUID().uuidString)"
        let old = need(12, "Choose the moving day", options: ["Friday", "Monday"])
        let store = ViewHost.store(try reading([old, under], db: db))
        store.destination = .needs
        store.selectedNeed = 12
        let window = ViewHost.window(store)
        defer { ViewHost.close(window) }
        guard try ViewHost.middle(of: "Monday", in: window) != nil else {
            throw ViewHost.Missing(description: "the request at hand, 12, is not drawn with its options")
        }
        let replaced = old.merging(["answer": "Replaced by Fleet Manager with a new item: Choose the day",
                                    "answered": now, "replaced_by": 15]) { _, value in value }
        store.state = try reading([replaced, new, under], db: db)
        let found = try ViewHost.middle(of: words, in: window)
        let hub = try ViewHost.middle(of: "Replaced by", in: window, seconds: 2)
        return Seen(newAtHand: found != nil, hubWords: hub != nil, chosen: store.selectedNeed)
    }

    /// The bug it catches: `NeedsBoard.settle` keeps the replaced item at hand as one that ended in another way, and
    /// the stage shows its answer, the hub's "Replaced by ..." words, in the place of the new item; or the request
    /// under the old one comes to hand in its place.
    @Test func aReplacedRequestAtHandGivesItsPlaceToTheNewItem() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop {
            try Self.replace12(by: Self.need(15, "Choose the day", options: ["Tuesday", "Thursday"]), reading: "Thursday")
        }
        #expect(seen.newAtHand, "the new item stands at hand, with its options")
        #expect(!seen.hubWords, "the hub's words of the replaced item show nowhere")
        #expect(seen.chosen == 15)
        #expect(screen.stayedHis)
    }

    /// The Mac slept while the manager replaced 12 and he answered the new item on his phone: its next reading holds
    /// both. The bug it catches: the old item stays at hand as the request that ended, with the hub's words, where the
    /// new one with his answer belongs.
    @Test func aReplacedRequestWhoseNewItemEndedShowsTheNewItemWithHisAnswer() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop {
            try Self.replace12(by: Self.need(15, "Choose the day", options: ["Tuesday", "Thursday"],
                                             ["answer": "Thursday suits me", "answered": Self.now]),
                               reading: "suits me")
        }
        #expect(seen.newAtHand, "the new item stands at hand, with his answer")
        #expect(!seen.hubWords, "the hub's words of the replaced item show nowhere")
        #expect(screen.stayedHis)
    }
}
