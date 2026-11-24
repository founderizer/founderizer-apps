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

    /// **The card of a key that left the fleet closes by itself, and no card names a secret by its reference or guesses
    /// its kind** (a Fable read of 22 November 2026): the key went at another device or with an agent's removal while
    /// this Mac's kept list still had it, so its badge stayed and opened its card. The bug that this catches: the card
    /// takes the raw `bws://` reference for its title and "Login" for its kind when its list has no entry for it
    /// (`entry?.name ?? reference`), and it stays open over a list of its own visit that no longer has the key; or it
    /// closes over a list that this app cannot read, which is no list, and what the owner typed in Value goes.
    @Test func aCardOfAKeyThatLeftTheListClosesAndNeverShowsItsReference() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop { () -> (shown: Bool, closed: Bool, again: Bool, kept: Bool,
                                                                    emptied: Bool, done: Bool, reference: Bool, login: Bool,
                                                                    closedAfter: Bool) in
            let features = [SecretEntryView.feature, "secret_grants"]
            let store = ViewHost.store(try ViewHost.reading(needs: [], features: features))
            store.destination = .agent("manager")
            let key = "bws://11111111-2222-4333-8444-555555555551"
            let held: [String: Any] = [key: ["title": "EXAMPLE_API_KEY", "kind": "api_key", "env": "EXAMPLE_API_KEY",
                                             "protected": true, "grants": [:]]]
            // the fleet's list of secrets, as a read of it keeps it (`SecretsPage.read`)
            @MainActor func keep(_ logins: [String: Any]) throws {
                let team: [String: Any] = [
                    "db": store.state?.db ?? "", "revision": String(repeating: "a", count: 40),
                    "sha256": String(repeating: "b", count: 64), "lines": [], "open_tasks": [:], "logins": logins,
                ]
                let snapshot = try JSONDecoder().decode(TeamSnapshot.self, from: JSONSerialization.data(withJSONObject: team))
                store.keep(LoginReading(team: snapshot, profiles: nil), as: "secrets.logins.fleet")
            }
            try keep(held)
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }

            // 1. The badge's press opens the key's card over the old list; the card's own read then has no such key.
            store.showSecret(named: "EXAMPLE_API_KEY")
            ViewHost.turn(20) { window.childWindows?.contains(where: \.isVisible) == true }
            guard let first = window.childWindows?.last(where: \.isVisible) else {
                throw ViewHost.Missing(description: "no card's window over the chat")
            }
            let shown = try ViewHost.middle(of: String(l10n: "Available to"), in: first) != nil
            try keep([:])
            let closed = ViewHost.turn(10) { store.secretCard == nil }
            // the closed card's window fades out first, so that the next card's window is the one visible window
            if closed { ViewHost.turn(10) { window.childWindows?.contains(where: \.isVisible) != true } }

            // 2. The key's card again, and then the hub's generation changes: the card has no list until it reads one.
            try keep(held)
            let pressed = store.showSecret(named: "EXAMPLE_API_KEY")
            ViewHost.turn(20) { window.childWindows?.contains(where: \.isVisible) == true }
            guard let second = window.childWindows?.last(where: \.isVisible) else {
                throw ViewHost.Missing(description: "no second card's window over the chat")
            }
            let again = try pressed && ViewHost.middle(of: String(l10n: "Available to"), in: second) != nil
            // a list that the hub gave in a form that this app cannot read is no list, never an empty one: the card stays
            try keep([key: 42])
            let kept = !ViewHost.turn(5) { store.secretCard == nil }
            store.state = try ViewHost.reading(needs: [], features: features)
            // the card draws with no list now: its part "Available to" goes
            let emptied = ViewHost.turn(20) { (try? ViewHost.middle(of: String(l10n: "Available to"), in: second, seconds: 0)) == nil }
            let done = try ViewHost.middle(of: String(l10n: "Done"), in: second) != nil
            let reference = try ViewHost.middle(of: "bws:", in: second, seconds: 1) != nil
            let login = try ViewHost.middle(of: String(l10n: "Login"), in: second, seconds: 1) != nil
            // the first list of the new generation, without the key
            try keep([:])
            let closedAfter = ViewHost.turn(10) { store.secretCard == nil }
            return (shown, closed, again, kept, emptied, done, reference, login, closedAfter)
        }
        #expect(seen.shown, "the key's card, over the chat")
        #expect(seen.closed, "a list of the card's visit without the key closes its card")
        #expect(seen.again, "the badge opens the key's card again while the list has it")
        #expect(seen.kept, "a list that this app cannot read closes no card")
        #expect(seen.emptied, "after the change of generation the card has no list")
        #expect(seen.done, "the card stands, with its Done")
        #expect(!seen.reference, "no card shows a secret's raw reference as its name")
        #expect(!seen.login, "no card guesses the kind of a key that its list does not have")
        #expect(seen.closedAfter, "the first list of the new generation without the key closes the card")
        #expect(screen.stayedHis)
    }
}
