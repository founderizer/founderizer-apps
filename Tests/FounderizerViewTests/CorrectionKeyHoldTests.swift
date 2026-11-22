import AppKit
import FleetCore
import Testing
@testable import Founderizer

/// **A key in the correction of a sent message waits for his choice, as in the chat's box** (`FleetView.editMessagePanel`,
/// `KeyHoldBanner`). Until 22 November 2026 the correction box sent the owner's corrected words to the agent with no
/// question, while the chat's box, a request's answer, Needs clarification and the feedback box held words that look
/// like a key. The bugs that they catch: the correction box sends a key in clear text, to the agent's session and its
/// records; a press that waits behind another write is dropped, or sends its old words after he changed the box, took
/// a kept key out of it or pressed Cancel; a "Keep it" of an earlier correction of the same message lets a key of a
/// later one go with no question. The real views and store, on a stand-in hub (`LoopbackHub`), which keeps what the app
/// sends and refuses it, so each request stays in the outbox. Example names only.
@Suite(.serialized, .timeLimit(.minutes(3))) struct CorrectionKeyHoldTests {
    /// A made-up key with the shape of a real one (`KeyInText` knows it by its prefix), in two parts so that no scan of
    /// the repository takes it for a key.
    private static let keyText = "sk_test_" + "EXAMPLEexample0123456789"
    private static let first = "bbbbbbbb-0000-4000-8000-000000000002"
    private static let second = "bbbbbbbb-0000-4000-8000-000000000003"
    private static let kept = "Use the staging account. Key: " + keyText

    /// A reading with the manager and DevOps, and one message of this Mac's to `recipient`, which he can correct; with
    /// `plan`, a second one to the manager.
    private static func reading(to recipient: String, features: [String], plan: Bool = false) throws -> Data {
        let now = Int(Date().timeIntervalSince1970)
        let agents: [[String: Any]] = [
            ["name": "manager", "role": "manager", "title": "Fleet Manager", "runtime": "claude", "can": [], "placed": true],
            ["name": "devops", "role": "worker", "title": "DevOps", "runtime": "claude", "can": [], "placed": true]]
        let message: [String: Any] = [
            "request_id": first, "recipient": recipient, "kind": "message", "text": "Use the staging account.",
            "event_id": 1, "created": now - 60, "client": "founderizer-swift/1/example-installation"]
        let other: [String: Any] = [
            "request_id": second, "recipient": "manager", "kind": "message", "text": "Plan the week.",
            "event_id": 2, "created": now - 50, "client": "founderizer-swift/1/example-installation"]
        return try JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "db": "correction-key-\(UUID().uuidString)", "time": now, "agents": agents,
            "tasks": [], "messages": plan ? [message, other] : [message], "holds": [], "outcomes": [], "notes": [],
            "needs": [], "permissions": [], "reports": [], "ui_features": features] as [String: Any])
    }

    /// A store of the app that reads `hub`, after the hub's first answer: it can write, and it is this Mac's
    /// installation, which sent the message.
    @MainActor private static func store(on hub: LoopbackHub, _ reading: Data, messages: Int = 1) throws -> FleetStore {
        _ = ViewHost.store(try HubState.decode(reading))         // the test's own defaults and folder
        AppDefaults.store.set(hub.address, forKey: "hubAddress")
        AppDefaults.store.set("example-installation", forKey: "installationID")
        let store = FleetStore()
        Task { await store.refresh() }
        guard ViewHost.turn(10, until: { store.canWrite && store.state?.messages.count == messages }) else {
            throw ViewHost.Missing(description: "the stand-in hub's reading did not reach the store")
        }
        return store
    }

    /// The words of each message that the app sent to the hub.
    private static func sent(_ hub: LoopbackHub) -> [[String: Any]] {
        hub.requests.filter { $0.method == "POST" && $0.path == "/ui/messages" }.compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.body.utf8))) as? [String: Any]
        }
    }

    struct Held: Sendable {
        var heldOnTyping = false, sentWhileHeld = true, keptWent = false, askedAgain = false
        var tell: String?, savedKey: String?, rest: String?
    }

    /// He types a key into his correction of a message to DevOps: the question stands over the box, and Return sends
    /// nothing. "Keep it" lets Return send his words as they are. Words with no key end that choice, and the next key
    /// asks again; "Save it as a secret" takes the key out of his words into the secure form, whose save tells DevOps,
    /// the agent of the message, the secret's name.
    @Test func aKeyInACorrectionWaitsForHisChoice() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 150) { () -> Held in
            var seen = Held()
            let reading = try Self.reading(to: "devops", features: ["direct_chat", "corrections", SecretEntryView.feature,
                                                                    "secret_grants"])
            let hub = try LoopbackHub(state: reading)
            defer { hub.stop() }
            let store = try Self.store(on: hub, reading)
            defer { store.secretForm = nil }
            store.destination = .agent("devops")
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            guard let message = store.state?.messages.first else { throw ViewHost.Missing(description: "no message") }
            store.beginEdit(message)
            let held = HeldKey(composer: store.correctionKey, hold: .text)
            // the correction takes the keyboard as it shows, with his words in its box
            guard ViewHost.turn(10, until: { ViewHost.fieldWords(in: window) == "Use the staging account." }) else {
                throw ViewHost.Missing(description: "the correction's box did not take the keyboard")
            }
            Self.typeKey(in: window)
            seen.heldOnTyping = ViewHost.turn(5) { store.heldKey == held }
            // Return while the question stands, on a store that can write, so a Return that sent would send: nothing
            // goes, and the question stays
            Task { await store.refresh() }
            ViewHost.turn(10) { store.canWrite }
            ViewHost.atOnce(ViewHost.keys("\r", in: window))
            ViewHost.turn(2)
            seen.sentWhileHeld = !Self.sent(hub).isEmpty || store.heldKey != held
            guard let keep = try ViewHost.middle(of: String(l10n: "Keep it"), in: window) else {
                throw ViewHost.Missing(description: "the question of the key has no Keep it")
            }
            ViewHost.atOnce(ViewHost.click(keep, in: window))
            ViewHost.turn(5) { store.heldKey == nil }
            // the box keeps the keyboard, or takes it again at a click on his words
            if ViewHost.fieldWords(in: window) == nil, let box = try ViewHost.middle(of: "Key:", in: window) {
                ViewHost.atOnce(ViewHost.click(box, in: window))
                ViewHost.turn(2) { ViewHost.fieldWords(in: window) != nil }
            }
            Task { await store.refresh() }
            ViewHost.turn(10) { store.canWrite }
            ViewHost.atOnce(ViewHost.keys("\r", in: window))
            ViewHost.turn(10) { !Self.sent(hub).isEmpty }
            let went = Self.sent(hub).first
            seen.keptWent = (went?["text"] as? String) == "Use the staging account. Key: " + Self.keyText
                && (went?["replaces_request_id"] as? String) == Self.first
            // the hub refused it: he lets it go, and his words stay in the box
            ViewHost.turn(10) { store.pending?.refusal != nil }
            store.discardRefused()
            store.editText = "Use the staging account."
            ViewHost.turn(2)
            store.editText = "Use the staging account. Key: " + Self.keyText
            seen.askedAgain = ViewHost.turn(5) { store.heldKey == held }
            guard let save = try ViewHost.middle(of: String(l10n: "Save it as a secret"), in: window) else {
                throw ViewHost.Missing(description: "the question of the key has no Save it as a secret")
            }
            ViewHost.atOnce(ViewHost.click(save, in: window))
            ViewHost.turn(5) { store.secretForm != nil }
            seen.tell = store.secretForm?.tell
            seen.savedKey = store.secretForm?.key
            seen.rest = store.editText
            return seen
        }
        #expect(seen.heldOnTyping, "a key typed into the correction asks the question")
        #expect(!seen.sentWhileHeld, "Return sends nothing while the question stands")
        #expect(seen.keptWent, "Keep it: Return sends his words as they are, as a correction of his message")
        #expect(seen.askedAgain, "words with no key end his choice, and the next key asks again")
        #expect(seen.tell == "devops", "the secret's name goes to the agent of the message")
        #expect(seen.savedKey == Self.keyText, "the key goes into the secure form")
        #expect(seen.rest == "Use the staging account. Key:", "and out of his words")
        #expect(screen.stayedHis)
    }

    /// He types a key at the end of the words in the box that has the keys. The caret goes there first: a box that
    /// just took the keyboard selects all its words until the caret moves to their end a turn later
    /// (`ComposerCaret.toEnd`), and a key typed then would take the place of his words.
    @MainActor private static func typeKey(in window: NSWindow) {
        guard let field = window.firstResponder as? NSTextView else { return }
        field.setSelectedRange(NSRange(location: (field.string as NSString).length, length: 0))
        field.insertText(" Key: " + keyText, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// Another write that the hub refuses, so the store cannot write until he lets it go (`discardRefused`).
    @MainActor private static func block(_ store: FleetStore) {
        Task { _ = await store.command(.control(task: 41, action: .pause)) }
        ViewHost.turn(10) { store.pending?.refusal != nil }
    }

    /// He lets the refused write go, and the hub answers again: a correction that waits for the store goes now.
    @MainActor private static func free(_ store: FleetStore) {
        store.discardRefused()
        Task { await store.refresh() }
        ViewHost.turn(10) { store.canWrite }
    }

    /// **His press decides once**: a correction that he kept with "Keep it" and sent while another write is on its way
    /// waits for it and goes with the words of his press, and the other write reaches the hub too. When he changes the
    /// box during the wait (here: he takes the kept key out), nothing goes, and the box keeps his new words.
    @Test func aCorrectionThatWaitsGoesOnlyWithTheWordsOfItsPress() async throws {
        struct Seen: Sendable {
            var blocked = false, early = true, other = false, words: String?, replaces: String?
            var changedSent = true, box: String?, open = false
        }
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 90) { () -> Seen in
            var seen = Seen()
            let reading = try Self.reading(to: "manager", features: ["corrections", "task_controls", SecretEntryView.feature,
                                                                     "secret_grants"])
            let hub = try LoopbackHub(state: reading)
            defer { hub.stop() }
            let store = try Self.store(on: hub, reading)
            defer { try? FileManager.default.removeItem(at: AppFolders.support.appendingPathComponent("Founderizer")) }
            guard let message = store.state?.messages.first else { throw ViewHost.Missing(description: "no message") }
            store.beginEdit(message)
            store.editText = Self.kept
            // his press of the kept correction while another write waits, with the words that it checked
            // (`FleetView.sendCorrection`); the box stays as it was
            Self.block(store)
            seen.blocked = !store.canWrite
            Task { await store.sendEdit(Self.kept) }
            ViewHost.turn(1.5)
            seen.early = !Self.sent(hub).isEmpty
            Self.free(store)
            ViewHost.turn(10) { !Self.sent(hub).isEmpty }
            seen.other = hub.requests.contains { $0.method == "POST" && $0.path.hasSuffix("tasks/41/control") }
            seen.words = Self.sent(hub).first?["text"] as? String
            seen.replaces = Self.sent(hub).first?["replaces_request_id"] as? String
            // the hub refused the correction: he lets it go, and presses again while another write waits, then takes
            // the kept key out of the box before that write ends
            ViewHost.turn(10) { store.pending?.refusal != nil }
            Self.free(store)
            Self.block(store)
            Task { await store.sendEdit(Self.kept) }
            ViewHost.turn(1)
            store.editText = "Use the staging account."
            Self.free(store)
            ViewHost.turn(1.5)
            seen.changedSent = Self.sent(hub).count > 1
            seen.box = store.editText
            seen.open = store.editingMessage?.id == message.id
            return seen
        }
        #expect(seen.blocked, "another write was on its way")
        #expect(!seen.early, "the correction waited for it")
        #expect(seen.other, "the other write reached the hub")
        #expect(seen.words == Self.kept, "the correction went with the words of his press")
        #expect(seen.replaces == Self.first)
        #expect(!seen.changedSent, "a press whose words he changed during the wait sends nothing")
        #expect(seen.box == "Use the staging account." && seen.open, "the box keeps his new words for a new press")
        #expect(screen.stayedHis)
    }

    /// **Cancel takes back a press that waits**: he presses Send while another write is on its way and presses Cancel;
    /// as that write ends, and before the press looks again, a correction of the same message opens again with the same
    /// words (a Correct opens one only while the store can write). Nothing goes: that press was of the correction that
    /// he cancelled, and the new one has had no press.
    @Test func cancelTakesBackACorrectionThatWaits() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 90) {
            () -> (blocked: Bool, reopened: Bool, sent: Bool, box: String?) in
            let reading = try Self.reading(to: "manager", features: ["corrections", "task_controls", SecretEntryView.feature,
                                                                     "secret_grants"])
            let hub = try LoopbackHub(state: reading)
            defer { hub.stop() }
            let store = try Self.store(on: hub, reading)
            defer { try? FileManager.default.removeItem(at: AppFolders.support.appendingPathComponent("Founderizer")) }
            guard let message = store.state?.messages.first else { throw ViewHost.Missing(description: "no message") }
            store.beginEdit(message)
            store.editText = Self.kept
            Self.block(store)
            let blocked = !store.canWrite
            Task { await store.sendEdit(Self.kept) }
            ViewHost.turn(1)
            store.cancelEdit()
            store.discardRefused()
            store.beginEdit(message)
            let reopened = store.editingMessage?.id == message.id
            store.editText = Self.kept
            ViewHost.turn(2)
            return (blocked, reopened, !Self.sent(hub).isEmpty, store.editText)
        }
        #expect(seen.blocked, "another write was on its way")
        #expect(seen.reopened, "a correction of the same message opened again")
        #expect(!seen.sent, "the press of the cancelled correction sends nothing")
        #expect(seen.box == Self.kept, "the new correction keeps its words")
        #expect(screen.stayedHis)
    }

    /// **A "Keep it" goes with its correction** (a reader's probe): he keeps a key in a correction of a message to DevOps,
    /// opens a correction in the manager's chat, which ends the first one where its box does not show, where a key asks
    /// too, and cancels it; back in DevOps, a new correction of the same message gets a key at once (Edit > Paste or a
    /// drop, which the guard of Cmd+V does not see): the question stands again, and Return sends nothing.
    @Test func aKeepItGoesWithItsCorrection() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop(limit: 150) {
            () -> (kept: Bool, askedOther: Bool, asked: Bool, sent: Bool) in
            let reading = try Self.reading(to: "devops", features: ["direct_chat", "corrections", SecretEntryView.feature,
                                                                    "secret_grants"], plan: true)
            let hub = try LoopbackHub(state: reading)
            defer { hub.stop() }
            let store = try Self.store(on: hub, reading, messages: 2)
            store.destination = .agent("devops")
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            guard let first = store.state?.messages.first(where: { $0.request_id == Self.first }),
                  let other = store.state?.messages.first(where: { $0.request_id == Self.second }) else {
                throw ViewHost.Missing(description: "no messages")
            }
            store.beginEdit(first)
            guard ViewHost.turn(10, until: { ViewHost.fieldWords(in: window) == first.text }) else {
                throw ViewHost.Missing(description: "the correction's box did not take the keyboard")
            }
            Self.typeKey(in: window)
            ViewHost.turn(5) { store.heldKey != nil }
            guard let keep = try ViewHost.middle(of: String(l10n: "Keep it"), in: window) else {
                throw ViewHost.Missing(description: "the question of the key has no Keep it")
            }
            ViewHost.atOnce(ViewHost.click(keep, in: window))
            let kept = ViewHost.turn(5) { store.heldKey == nil }
            store.destination = .agent("manager")
            ViewHost.turn(2)
            store.beginEdit(other)
            guard ViewHost.turn(10, until: { ViewHost.fieldWords(in: window) == other.text }) else {
                throw ViewHost.Missing(description: "the manager's correction's box did not take the keyboard")
            }
            // a correction of another message is one of its own: its key asks too
            Self.typeKey(in: window)
            let askedOther = ViewHost.turn(5) { store.heldKey == HeldKey(composer: store.correctionKey, hold: .text) }
            store.cancelEdit()
            ViewHost.turn(1)
            store.destination = .agent("devops")
            ViewHost.turn(2)
            store.beginEdit(first)
            guard ViewHost.turn(10, until: { ViewHost.fieldWords(in: window) == first.text }) else {
                throw ViewHost.Missing(description: "the second correction's box did not take the keyboard")
            }
            Self.typeKey(in: window)
            let asked = ViewHost.turn(5) { store.heldKey == HeldKey(composer: store.correctionKey, hold: .text) }
            Task { await store.refresh() }
            ViewHost.turn(10) { store.canWrite }
            ViewHost.atOnce(ViewHost.keys("\r", in: window))
            ViewHost.turn(2)
            return (kept, askedOther, asked, !Self.sent(hub).isEmpty)
        }
        #expect(seen.kept, "he kept the key of the first correction")
        #expect(seen.askedOther, "the key of a correction of another message asks")
        #expect(seen.asked, "the key of a later correction of the same message asks again")
        #expect(!seen.sent, "Return sends nothing while it asks")
        #expect(screen.stayedHis)
    }
}
