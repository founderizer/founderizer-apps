import AppKit
import FleetCore
import Testing
@testable import Founderizer

/// **A key that a request's words name is a badge, and a press on it opens the key's own card over the chat** (the
/// owner, 21 November 2026: "a badge for specific Credentials, like we have for agents! ideally a modal of that key
/// should open so it can be edited right there after clicking it", and "Yes, both"). The bug that this catches: the
/// name stays words, or its press opens nothing or Settings › Secrets.
@Suite(.serialized, .timeLimit(.minutes(1))) struct KeyBadgeTests {
    @Test func aPressOnAKeysBadgeOpensTheKeysCardOverTheChat() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop { () -> (card: Bool, chat: Bool) in
            let now = Int(Date().timeIntervalSince1970)
            let store = ViewHost.store(try ViewHost.reading(
                needs: [["id": 81, "title": "Make a new key for the logs", "raised": now - 300, "by": "manager",
                         "why": "The old one expired. Put the new value in EXAMPLE_API_KEY.", "todo": "",
                         "answered": NSNull()]],
                features: [SecretEntryView.feature, "secret_grants"]))
            store.destination = .agent("manager")
            let team: [String: Any] = [
                "db": store.state?.db ?? "", "revision": String(repeating: "a", count: 40),
                "sha256": String(repeating: "b", count: 64), "lines": [], "open_tasks": [:],
                "logins": ["bws://11111111-2222-4333-8444-555555555551": ["title": "EXAMPLE_API_KEY", "kind": "api_key",
                                                                          "env": "EXAMPLE_API_KEY", "protected": true,
                                                                          "grants": [:]]]]
            let snapshot = try JSONDecoder().decode(TeamSnapshot.self, from: JSONSerialization.data(withJSONObject: team))
            store.keep(LoginReading(team: snapshot, profiles: nil), as: "secrets.logins.fleet")
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            guard let badge = try ViewHost.middle(of: "EXAMPLE_API_KEY", in: window) else {
                throw ViewHost.Missing(description: "the card does not show the key's name")
            }
            ViewHost.atOnce(ViewHost.click(badge, in: window))
            ViewHost.turn(10) { store.secretCard != nil }
            let card = store.secretCard != nil
            if card { store.secretCard = nil }
            return (card, store.destination == .agent("manager"))
        }
        #expect(seen.card, "the key's own card opens")
        #expect(seen.chat, "over the chat, where he was")
        #expect(screen.stayedHis)
    }
}
