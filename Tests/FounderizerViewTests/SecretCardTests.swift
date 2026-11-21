import AppKit
import FleetCore
import Testing
@testable import Founderizer

/// **The card of a secret that a request's key badge opens stands over the page where he is, and Esc leaves him there**
/// (the owner, 21 November 2026: "ideally a modal of that key should open so it can be edited right there after
/// clicking it", and "Yes, both" to its drawing). The bug that this catches: the badge opens Settings › Secrets, or its
/// card's close writes the page, and he lands in Settings with his chat gone from under him.
@Suite(.serialized, .timeLimit(.minutes(1))) struct SecretCardTests {
    @Test func aBadgesSecretCardShowsOverTheChatAndEscLeavesThePageAsItWas() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop { () -> (opened: Bool, twice: Bool, shown: Bool, closed: Bool, chat: Bool) in
            let store = ViewHost.store(try ViewHost.reading(needs: [], features: [SecretEntryView.feature, "secret_grants"]))
            store.destination = .agent("manager")
            // the kept reading of the fleet's secrets, as the store keeps it before Settings › Secrets ever opened
            let team: [String: Any] = [
                "db": store.state?.db ?? "", "revision": String(repeating: "a", count: 40), "sha256": String(repeating: "b", count: 64),
                "lines": [], "open_tasks": [:],
                "logins": ["bws://11111111-2222-4333-8444-555555555551": ["title": "EXAMPLE_API_KEY", "kind": "api_key",
                                                                          "env": "EXAMPLE_API_KEY", "protected": true, "grants": [:]],
                           "bws://11111111-2222-4333-8444-555555555552": ["title": "TWICE_API_KEY", "kind": "api_key",
                                                                          "env": "TWICE_API_KEY", "protected": true],
                           "bws://11111111-2222-4333-8444-555555555553": ["title": "TWICE_API_KEY", "kind": "api_key",
                                                                          "env": "TWICE_API_KEY", "protected": true]],
            ]
            let snapshot = try JSONDecoder().decode(TeamSnapshot.self, from: JSONSerialization.data(withJSONObject: team))
            store.keep(LoginReading(team: snapshot, profiles: nil), as: "secrets.logins.fleet")
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            // a name of two secrets opens nothing
            let twice = store.showSecret(named: "TWICE_API_KEY")
            let opened = store.showSecret(named: "EXAMPLE_API_KEY")
            ViewHost.turn(20) { window.childWindows?.contains(where: \.isVisible) == true }
            guard let card = window.childWindows?.last(where: \.isVisible) else {
                throw ViewHost.Missing(description: "no card's window over the chat")
            }
            let shown = try ViewHost.middle(of: String(l10n: "Available to"), in: card) != nil
            // Esc in the card's window: the command that AppKit's key bindings make of Esc there (`cancelOperation`),
            // which the card's window takes (`fleetModal`). A test's app is never active, so its window of the card is
            // never key: `NSApp.sendEvent` gave the key to the chat's window under the card, and a SwiftUI shortcut of a
            // window that is not key takes none.
            card.cancelOperation(nil)
            ViewHost.turn(20) { store.secretCard == nil }
            return (opened, twice, shown, store.secretCard == nil, store.destination == .agent("manager"))
        }
        #expect(seen.opened, "the badge's name is one secret of the list")
        #expect(!seen.twice, "a name of two secrets opens no card")
        #expect(seen.shown, "the secret's own card, over the chat")
        #expect(seen.closed, "Esc closes it")
        #expect(seen.chat, "and he is in the chat, where he was")
        #expect(screen.stayedHis)
    }
}
