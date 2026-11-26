import FleetCore
import Foundation
import Testing
@testable import Founderizer

/// **A key in a rule of an agent's Behaviour waits for his choice, as in the chat's box** (`TeamModel.holdsKey`,
/// `RuleEditor`, `KeyHoldBanner`). Until 22 November 2026 the rule's editor took the owner's words to the agent's
/// profile with no question, while the chat's box, a request's answer, Needs clarification, the feedback box and a
/// task's guidance held words that look like a key (a reader of another area's fix found it). The bug that this
/// catches: a save of a rule that takes such words to the hub with no question, by any of its ways (2 seconds without
/// typing, Done, Back, another page, Add rule, Try again: each is the model's save), or by the queue, which sends the
/// rule's newest words when its turn comes. The test reads the agent's profile from a stand-in hub, puts a key in a
/// rule's text, and reads that nothing goes and that the editor's question stands; then that the same save goes after
/// "Keep it", so it was the key that held it. A second test draws the editor over a rule that holds a key and reads
/// that it asks at once, in the words of a rule: a rule is no message.
@Suite(.serialized, .timeLimit(.minutes(10)))
struct RuleKeyHoldTests {
    /// A made-up key with the shape of a real one (`KeyInText` knows it by its prefix), in two parts so that no scan of
    /// the repository takes it for a key.
    private static let keyText = "sk_test_" + "EXAMPLEexample0123456789"

    /// A reading with the manager, of a hub that takes profiles and secrets.
    private static func reading(db: String) throws -> Data {
        let state: [String: Any] = [
            "schema_version": 1, "db": db, "time": Int(Date().timeIntervalSince1970),
            "agents": [["name": "manager", "role": "manager", "runtime": "claude", "can": [], "placed": true]],
            "tasks": [], "holds": [], "outcomes": [], "notes": [], "needs": [], "permissions": [], "messages": [],
            "reports": [], "ui_features": ["profiles", SecretEntryView.feature, "secret_grants"]]
        return try JSONSerialization.data(withJSONObject: state)
    }

    /// The manager's profile, with the four sections that every profile has.
    private static func profiles(db: String, character: String = "Calm.") throws -> Data {
        let sections = [("character", "Character", character), ("responsible_for", "Responsible for", "The team."),
                        ("may_do", "May do without asking", "Plan work."), ("must_ask", "Must ask first", "Money.")]
        let profile: [String: Any] = [
            "agent": "manager", "path": "profiles/manager.md", "sha256": String(repeating: "b", count: 64),
            "sections": sections.map { ["key": $0.0, "title": $0.1, "text": $0.2] },
            "text": sections.map { "**\($0.1).** \($0.2)" }.joined(separator: "\n\n")]
        return try JSONSerialization.data(withJSONObject: [
            "db": db, "revision": String(repeating: "a", count: 40), "profiles": [profile]])
    }

    /// A store of the app that reads `hub`, after the hub's first answer: it can write.
    @MainActor private static func store(on hub: LoopbackHub, _ state: Data) throws -> FleetStore {
        _ = ViewHost.store(try HubState.decode(state))         // the test's own defaults and folder
        AppDefaults.store.set(hub.address, forKey: "hubAddress")
        let store = FleetStore()
        Task { await store.refresh() }
        ViewHost.turn(10) { store.canWrite }
        return store
    }

    struct Seen: Sendable {
        var read = false, queuedSent = true, heldOnSave = false, asked = false, sentHeld = true, keptSent = false
    }

    @Test func aKeyInARuleWaitsForHisChoice() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop { () -> Seen in
            let db = "view-test-\(UUID().uuidString)"
            let state = try Self.reading(db: db)
            let hub = try LoopbackHub(state: state)
            hub.give(try Self.profiles(db: db), at: "/ui/profiles")
            defer { hub.stop() }
            let store = try Self.store(on: hub, state)
            // what its store kept in the test's folder (an outbox's request) goes with the test
            defer { try? FileManager.default.removeItem(at: AppFolders.support.appendingPathComponent("Founderizer")) }
            let team = TeamModel()
            Task { await team.read(store) }
            let rule = TeamModel.EditKey(agent: "manager", id: ProfileSectionID(key: "character"))
            let mine = HeldKey(composer: TeamModel.guardKey(rule), hold: .text)
            let sent = { hub.requests.contains { $0.method == "POST" && $0.path == "/ui/profiles/manager" } }
            var seen = Seen()
            seen.read = ViewHost.turn(10) { team.profile("manager") != nil }
            team.begin(rule)
            // a save that came into the queue before he wrote the key: its turn sends his newest words
            team.setText("Calm and short.", of: rule)
            team.save(rule, store: store)
            team.setText("Calm and short. The deploy key is " + Self.keyText, of: rule)
            seen.queuedSent = ViewHost.turn(2, until: sent)
            // a save of words with the key
            seen.heldOnSave = !team.save(rule, store: store)
            seen.asked = store.heldKey == mine
            seen.sentHeld = ViewHost.turn(2, until: sent)
            // "Keep it": the same save goes
            store.heldKey = nil
            team.keepKey(rule)
            Task { await store.refresh() }
            ViewHost.turn(10) { store.canWrite }
            team.save(rule, store: store)
            seen.keptSent = ViewHost.turn(10) {
                hub.requests.contains { $0.method == "POST" && $0.path == "/ui/profiles/manager" && $0.body.contains(Self.keyText) }
            }
            return seen
        }
        #expect(seen.read, "the stand-in hub gives the manager's profile")
        #expect(!seen.queuedSent, "the queue's turn holds words that he wrote after the save came into it")
        #expect(seen.heldOnSave, "a save of words with a key waits")
        #expect(seen.asked, "and the editor's question stands")
        #expect(!seen.sentHeld, "no profile with the key reached the hub")
        #expect(seen.keptSent, "after Keep it the same save goes")
        #expect(screen.stayedHis)
    }

    struct Asked: Sendable {
        var asked = false, ruleWords = false, ruleDetail = false, messageWords = true
    }

    @Test func theEditorOfARuleThatHoldsAKeyAsksInTheWordsOfARule() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop { () -> Asked in
            let db = "view-test-\(UUID().uuidString)"
            let state = try Self.reading(db: db)
            let profiles = try Self.profiles(db: db, character: "Calm. The deploy key is " + Self.keyText)
            let hub = try LoopbackHub(state: state)
            hub.give(profiles, at: "/ui/profiles")
            defer { hub.stop() }
            let store = try Self.store(on: hub, state)
            let rule = ProfileSectionID(key: "character")
            store.destination = .agentRule("manager", rule)
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            var seen = Asked()
            // the editor opens on the saved rule, which holds the key: the question stands at once, with no save
            seen.asked = ViewHost.turn(10) {
                store.heldKey == HeldKey(composer: TeamModel.guardKey(.init(agent: "manager", id: rule)), hold: .text)
            }
            seen.ruleWords = try ViewHost.middle(of: String(l10n: "This rule holds what looks like a key."), in: window) != nil
            seen.ruleDetail = try ViewHost.middle(of: "In a rule,", in: window, seconds: 5) != nil
            seen.messageWords = try ViewHost.middle(of: "This message holds", in: window, seconds: 0) != nil
            return seen
        }
        #expect(seen.asked, "the editor asks over a rule that holds a key when it opens")
        #expect(seen.ruleWords, "its question says that the rule holds what looks like a key")
        #expect(seen.ruleDetail, "and what a rule would give the agent")
        #expect(!seen.messageWords, "and not the words of a message")
        #expect(screen.stayedHis)
    }
}
