import AppKit
import FleetCore
import Testing
@testable import Founderizer

/// **A key request's card shows his talk with the manager over its form** (owner feature `need_clarify`): a key
/// request that took another's place carries his question about it (the area Needs-you and the manager, 21 November
/// 2026), and a chat's card drew the talk only inside the answer box, which a key card does not have. Needs you draws it
/// over every request's answers already.
@Suite(.serialized, .timeLimit(.minutes(1))) struct KeyCardTalkTests {
    @Test func anOpenKeyCardInAChatShowsHisTalkOverItsForm() async throws {
        let (shown, screen) = try await ViewHost.onMainLoop { () -> Bool in
            let now = Int(Date().timeIntervalSince1970)
            let store = ViewHost.store(try ViewHost.reading(
                needs: [["id": 71, "title": "Enter the API key for the logs", "why": "", "todo": "",
                         "raised": now - 300, "by": "manager", "answered": NSNull(), "kind": "secret",
                         "secret": ["kind": "api_key", "env": "ACME_LOGS_KEY"],
                         "talk": [["who": "owner", "text": "Which account is this for?", "ts": now - 200],
                                  ["who": "manager", "text": "The shared one of the support team.", "ts": now - 100]]]],
                features: [NeedTalk.feature, NeedClarify.feature]))
            store.destination = .agent("manager")
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            return try ViewHost.middle(of: "Which account is this for", in: window) != nil
        }
        #expect(shown, "his question stands on the key card")
        #expect(screen.stayedHis)
    }
}
