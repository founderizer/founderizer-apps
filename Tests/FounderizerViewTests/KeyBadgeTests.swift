import AppKit
import FleetCore
import Testing
@testable import Founderizer

/// **A key that a request's words or an agent's message name is a badge, and a press on it opens the key's own card
/// over the chat** (the owner, 21 November 2026: "task cards in both agents chat and needs you sohuld also have a badge
/// for specific Credentials, like we have for agents! ideally a modal of that key should open so it can be edited right
/// there after clicking it", and "Yes, both"). The bugs that these catch: the name stays words, or its press opens
/// nothing or Settings › Secrets.
@Suite(.serialized, .timeLimit(.minutes(10))) struct KeyBadgeTests {
    /// The reference of the one key of `keepTheKey`, and of a second key.
    private static let keyA = "bws://11111111-2222-4333-8444-555555555551"
    private static let keyB = "bws://11111111-2222-4333-8444-555555555552"

    /// The fleet's secrets as Settings › Secrets read them last: one API key, EXAMPLE_API_KEY, or the API keys given, by
    /// reference and name.
    @MainActor private static func keepTheKey(in store: FleetStore,
                                              keys: [String: String] = [keyA: "EXAMPLE_API_KEY"]) throws {
        let logins = keys.mapValues { name -> [String: Any] in
            ["title": name, "kind": "api_key", "env": name, "protected": true, "grants": [String: Any]()]
        }
        let team: [String: Any] = [
            "db": store.state?.db ?? "", "revision": String(repeating: "a", count: 40),
            "sha256": String(repeating: "b", count: 64), "lines": [], "open_tasks": [:], "logins": logins]
        let snapshot = try JSONDecoder().decode(TeamSnapshot.self, from: JSONSerialization.data(withJSONObject: team))
        store.keep(LoginReading(team: snapshot, profiles: nil), as: "secrets.logins.fleet")
    }

    @Test func aPressOnAKeysBadgeOpensTheKeysCardOverTheChat() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop { () -> (card: Bool, chat: Bool, renamed: Bool) in
            let now = Int(Date().timeIntervalSince1970)
            let store = ViewHost.store(try ViewHost.reading(
                needs: [["id": 81, "title": "Make a new key for the logs", "raised": now - 300, "by": "manager",
                         "why": "The old one expired. Put the new value in EXAMPLE_API_KEY.", "todo": "",
                         "answered": NSNull()]],
                features: [SecretEntryView.feature, "secret_grants"]))
            store.destination = .agent("manager")
            let need = try #require(store.state?.needs.first)
            let oldName = "EXAMPLE_OLD_KEY"
            try Self.keepTheKey(in: store, keys: [Self.keyA: oldName])
            let hadOldName = !store.cardNames(for: need).find(in: oldName).isEmpty
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            guard try ViewHost.middle(of: "expired", in: window) != nil else {
                throw ViewHost.Missing(description: "the open card did not show its reason")
            }
            // The next reading renames the same key while the card is on screen.
            try Self.keepTheKey(in: store)
            let renamed = hadOldName && store.cardNames(for: need).find(in: oldName).isEmpty
            guard ViewHost.turn(10, until: { !Self.presses(in: window.contentView!).isEmpty }),
                  let badge = Self.presses(in: window.contentView!).first else {
                throw ViewHost.Missing(description: "the new key name did not become a badge")
            }
            let frame = badge.convert(badge.bounds, to: nil)
            ViewHost.atOnce(ViewHost.click(NSPoint(x: frame.midX, y: frame.midY), in: window))
            ViewHost.turn(10) { store.secretCard != nil }
            let card = store.secretCard != nil
            if card { store.secretCard = nil }
            return (card, store.destination == .agent("manager"), renamed)
        }
        #expect(seen.renamed, "the old badge goes away at the next reading")
        #expect(seen.card, "the key's own card opens")
        #expect(seen.chat, "over the chat, where he was")
        #expect(screen.stayedHis)
    }

    /// **In an agent's message as on its card**: the chat's book holds the same secrets (`FleetStore.chatNames`), and
    /// the press of the badge in the message under the pointer (`chatBadgeLayer`) opens the same card. The chat draws
    /// its messages from the hub's reading, so a stand-in hub gives the agent's message (`LoopbackHub`). The bug that
    /// this catches: the chat's book is made with no secrets, so the key's name in the message stays words.
    @Test func aPressOnAKeysBadgeInAnAgentsMessageOpensTheKeysCardOverTheChat() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 90) { () -> (press: Bool, card: Bool, chat: Bool) in
            let now = Int(Date().timeIntervalSince1970)
            let agents: [[String: Any]] = [["name": "manager", "role": "manager", "runtime": "claude", "can": [],
                                            "placed": true]]
            let reading = try JSONSerialization.data(withJSONObject: [
                "schema_version": 1, "db": "key-chat-\(UUID().uuidString)", "time": now, "agents": agents, "tasks": [],
                "holds": [], "outcomes": [], "notes": [], "needs": [], "permissions": [], "messages": [],
                "reports": [["agent": "manager", "id": 7, "about": "", "created": now - 60,
                             "text": "The old one expired. I put the new value in EXAMPLE_API_KEY."]],
                "ui_features": [SecretEntryView.feature, "secret_grants"]] as [String: Any])
            let hub = try LoopbackHub(state: reading)
            defer { hub.stop() }
            _ = ViewHost.store(try HubState.decode(reading))         // the test's own defaults and folder
            AppDefaults.store.set(hub.address, forKey: "hubAddress")
            let store = FleetStore()
            Task { await store.refresh() }
            guard ViewHost.turn(10, until: { store.chatTimeline.count(for: "manager") > 0 }) else {
                throw ViewHost.Missing(description: "the stand-in hub's reading did not reach the chat")
            }
            try Self.keepTheKey(in: store)
            store.destination = .agent("manager")
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            guard let badge = try ViewHost.middle(of: "EXAMPLE_API_KEY", in: window) else {
                throw ViewHost.Missing(description: "the agent's message does not show the key's name")
            }
            ViewHost.pointerComes(to: badge, in: window)
            let press = ViewHost.turn(10) {
                window.contentView?.superview?.hitTest(badge).map { String(reflecting: type(of: $0)) }?
                    .contains("ChatBadgePress") == true
            }
            ViewHost.atOnce(ViewHost.click(badge, in: window))
            ViewHost.turn(10) { store.secretCard != nil }
            let card = store.secretCard != nil
            if card { store.secretCard = nil }
            return (press, card, store.destination == .agent("manager"))
        }
        #expect(seen.press, "the badge's press stands over the key's name in the message under the pointer")
        #expect(seen.card, "the key's own card opens")
        #expect(seen.chat, "over the chat, where he was")
        #expect(screen.stayedHis)
    }

    /// **The key's name in the title of a request for its new value is its badge** (his "Yes, both" to the drawing
    /// "New value for DOOR_BACKBLAZE_ACME_KEY"), and **no other card's title has one** (the area Needs-you and the
    /// manager). A press on the badge in a Replace card's title opens the card of the key that the request replaces,
    /// and the title's own press (it opens the card's long part) does not take it; in another key request's title the
    /// name is words, and a press on the title opens the long part and no key's card. **A second key of the same name
    /// is another key** (review; Fable's read of 22 November 2026): where the one key of that name in the list is not
    /// the one that the request replaces, the title is words. **A name of letters only is a badge too**: in this title
    /// it is the hub's own word for the key.
    @Test func onlyAReplaceCardsTitleHasTheKeysBadge() async throws {
        struct Pass: Sendable { let id: Int; let env: String; let replaces: String?; let keys: [String: String] }
        let passes = [
            // the key that the request replaces
            Pass(id: 82, env: "EXAMPLE_API_KEY", replaces: Self.keyA, keys: [Self.keyA: "EXAMPLE_API_KEY"]),
            // another key request
            Pass(id: 83, env: "EXAMPLE_API_KEY", replaces: nil, keys: [Self.keyA: "EXAMPLE_API_KEY"]),
            // the one key of that name is not the one that the request replaces
            Pass(id: 84, env: "EXAMPLE_API_KEY", replaces: Self.keyA,
                 keys: [Self.keyA: "OLD_EXAMPLE_KEY", Self.keyB: "EXAMPLE_API_KEY"]),
            // a name of letters only
            Pass(id: 85, env: "TOKEN", replaces: Self.keyB, keys: [Self.keyB: "TOKEN"]),
        ]
        struct Seen: Sendable { let badges: [Int]; let keyCard: [String?]; let longPart: [Bool] }
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 100) { () -> Seen in
            var badges: [Int] = [], keyCard: [String?] = [], longPart: [Bool] = []
            // where the Replace card's badge stood: on a card with no badge the same point is its title's words
            var badgePoint: NSPoint?
            for pass in passes {
                let now = Int(Date().timeIntervalSince1970)
                var secret: [String: Any] = ["kind": "api_key", "env": pass.env]
                if let replaces = pass.replaces { secret["replaces"] = replaces }
                let store = ViewHost.store(try ViewHost.reading(
                    needs: [["id": pass.id, "title": "New value for \(pass.env)", "raised": now - 300,
                             "by": "manager", "why": "The old one expired.", "todo": "", "answered": NSNull(),
                             "details": "Make the new key at Backblaze, under Keys.", "kind": "secret", "secret": secret]],
                    features: [SecretEntryView.feature, "secret_grants"]))
                store.destination = .agent("manager")
                try Self.keepTheKey(in: store, keys: pass.keys)
                let window = ViewHost.window(store)
                defer { ViewHost.close(window) }
                guard try ViewHost.middle(of: "New value for", in: window) != nil else {
                    throw ViewHost.Missing(description: "the card's title is not drawn")
                }
                // the badge's own press (`BadgePress`), where the title draws it: the text reader's box of a name in a
                // line with a badge's mark stood far from the badge
                let presses = Self.presses(in: window.contentView!)
                badges.append(presses.count)
                if let press = presses.first {
                    let frame = press.convert(press.bounds, to: nil)
                    badgePoint = NSPoint(x: frame.midX, y: frame.midY)
                }
                guard let point = badgePoint else { throw ViewHost.Missing(description: "the Replace card had no badge") }
                ViewHost.atOnce(ViewHost.click(point, in: window))
                let opens = !presses.isEmpty
                ViewHost.turn(opens ? 10 : 2) { store.secretCard != nil }
                keyCard.append(store.secretCard?.id)
                store.secretCard = nil
                longPart.append(try ViewHost.middle(of: "under Keys", in: window, seconds: opens ? 2 : 10) != nil)
            }
            return Seen(badges: badges, keyCard: keyCard, longPart: longPart)
        }
        #expect(seen.badges == [1, 0, 0, 1], "a badge in the title of a Replace card of its key alone, TOKEN's too")
        #expect(seen.keyCard == [Self.keyA, nil, nil, Self.keyB], "the badge opens the card of the key that it replaces")
        #expect(seen.longPart == [false, true, true, false], "the badge's press is not the title's; a title's press is")
        #expect(screen.stayedHis)
    }

    /// **A Replace card reads the secrets list once where the kept list lacks its key** (Fable's read of 22 November
    /// 2026): the app reads the list once a launch, and a key that the fleet took after that read, as on the morning of
    /// his drawing, is not in it. The bug that this catches: the title stays words until the app starts again or
    /// Settings › Secrets opens.
    @Test func aReplaceCardReadsTheListThatLacksItsKey() async throws {
        let (badges, screen) = try await ViewHost.onMainLoop { () -> Int in
            let now = Int(Date().timeIntervalSince1970), database = "view-test-\(UUID().uuidString)"
            let need: [String: Any] = [
                "id": 86, "title": "New value for NEW_EXAMPLE_KEY", "raised": now - 300, "by": "manager",
                "why": "The provider refused it.", "todo": "", "answered": NSNull(), "kind": "secret",
                "secret": ["kind": "api_key", "env": "NEW_EXAMPLE_KEY", "replaces": Self.keyB]]
            let state = try JSONSerialization.data(withJSONObject: [
                "schema_version": 1, "db": database, "time": now,
                "agents": [["name": "manager", "role": "manager", "runtime": "claude", "can": [], "placed": true]],
                "tasks": [], "holds": [], "outcomes": [], "notes": [], "needs": [need], "permissions": [], "messages": [],
                "reports": [], "ui_features": [SecretEntryView.feature, "secret_grants"]] as [String: Any])
            let hub = try LoopbackHub(state: state)
            defer { hub.stop() }
            // the list now: the key that the fleet took after the launch's read, in a team that the app takes (one with
            // its manager, `TeamSnapshot.validate`)
            hub.give(try JSONSerialization.data(withJSONObject: [
                "db": database, "revision": String(repeating: "a", count: 40), "sha256": String(repeating: "b", count: 64),
                "lines": [["agent": "manager", "role": "manager", "reports_to": NSNull()]], "open_tasks": [:],
                "logins": [Self.keyB: ["title": "NEW_EXAMPLE_KEY", "kind": "api_key", "env": "NEW_EXAMPLE_KEY",
                                       "protected": true, "grants": [:]]]] as [String: Any]), at: "/ui/team")
            _ = ViewHost.store(try HubState.decode(state))         // the test's own defaults and folder
            AppDefaults.store.set(hub.address, forKey: "hubAddress")
            let store = FleetStore()
            Task { await store.refresh() }
            ViewHost.turn(10) { store.state?.db == database }
            // the list that the launch read: another key
            try Self.keepTheKey(in: store)
            store.destination = .agent("manager")
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            ViewHost.turn(20) { !Self.presses(in: window.contentView!).isEmpty }
            return Self.presses(in: window.contentView!).count
        }
        #expect(badges == 1, "the title shows the new key's badge")
        #expect(screen.stayedHis)
    }

    /// The badges' presses in a view, deepest first.
    @MainActor private static func presses(in view: NSView) -> [NSView] {
        view.subviews.flatMap { presses(in: $0) + ($0 is BadgePress.PressView ? [$0] : []) }
    }
}
