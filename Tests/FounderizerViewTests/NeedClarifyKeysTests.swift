import AppKit
import FleetCore
import Testing
@testable import Founderizer

/// **His words typed right after he presses Needs clarification go into the card's field** (the owner, 21 November
/// 2026: "I clicked on discuss and typed, dont remember where"; his words left as a chat message). On his busy Mac the
/// press and the keys come out of the queue one after the other, before the field is drawn: the chat put them in its
/// box, whose Return sent them to the manager, and a Needs you step took a digit of them as its option. These tests
/// send the press and the keys at once, as such a Mac does, and read where his words went. No hub answers here, so the
/// app sends nothing (it writes only after its hub's answer): the words must stand in the card's field, ready for his
/// Send, and none in the chat's box.
@Suite(.serialized, .timeLimit(.minutes(10))) struct NeedClarifyKeysTests {
    /// Where his words went: the field that has the keys, and the chat's box.
    struct Seen: Sendable {
        let field: String?
        let box: String
    }

    /// A store whose reading holds one open item of the manager's, with this id: each test has its own, so that no
    /// wait of the app for an earlier test's card is this one's.
    @MainActor private static func store(item id: Int) throws -> FleetStore {
        ViewHost.store(try ViewHost.reading(
            needs: [["id": id, "title": "Choose the day of the move", "why": "", "todo": "Choose one",
                     "raised": Int(Date().timeIntervalSince1970) - 300, "by": "manager",
                     "options": ["Friday", "Monday"], "clarify": true, "answered": NSNull()]],
            features: [NeedTalk.feature, NeedClarify.feature]))
    }

    /// The press of the card's Needs clarification, then these words and Return, at once, on the page that the store
    /// shows. It waits until the field that has the keys holds the words and the chat's box holds none, for 20 s at most:
    /// the box's own field editor holds them too while the keys go there.
    @MainActor private static func pressAndType(_ words: String, on store: FleetStore) throws -> Seen {
        let window = ViewHost.window(store)
        defer { ViewHost.close(window) }
        guard let link = try ViewHost.middle(of: String(l10n: "Needs clarification"), in: window) else {
            throw ViewHost.Missing(description: "the card's Needs clarification is not drawn")
        }
        ViewHost.atOnce(ViewHost.click(link, in: window) + ViewHost.keys(words + "\r", in: window))
        ViewHost.turn(20) { ViewHost.fieldWords(in: window) == words && store.composerText(for: "manager").isEmpty }
        return Seen(field: ViewHost.fieldWords(in: window), box: store.composerText(for: "manager"))
    }

    /// In the manager's chat, where his card stands: a press of its Needs clarification, then "hello" and Return.
    @Test func wordsTypedRightAfterThePressInAChatGoIntoTheCardsField() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop {
            let store = try Self.store(item: 7)
            store.destination = .agent("manager")
            return try Self.pressAndType("hello", on: store)
        }
        #expect(seen.field == "hello", "his words, in the card's field")
        #expect(seen.box.isEmpty, "nothing of them in the chat's box")
        #expect(screen.stayedHis)
    }

    /// On Needs you, with the card at hand: a press of its Needs clarification, then "ok 2" and Return. The step's own
    /// keys mark an option with its digit and send it with Return.
    @Test func wordsTypedRightAfterThePressOnAStepGoIntoTheCardsField() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop {
            let store = try Self.store(item: 8)
            store.destination = .needs
            store.selectedNeed = 8
            return try Self.pressAndType("ok 2", on: store)
        }
        #expect(seen.field == "ok 2", "his words, in the card's field, and none of them the step's keys")
        #expect(screen.stayedHis)
    }
}
