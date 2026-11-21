import AppKit
import FleetCore
import Testing
@testable import Founderizer

/// **A look at a picture answers nothing; a press on its words answers** (owner feature `need_pictures`; the owner's
/// "Yes, as drawn" of 21 November 2026): on Needs you, each option of an item with pictures is its picture over its
/// words. A press on the picture opens it in the preview window, and a press on the words sends that option. No hub
/// answers here, so a press waits for one (`AnswerWaits`) with the option that it sends; nothing reaches a hub.
@Suite(.serialized, .timeLimit(.minutes(1))) struct NeedPictureOptionsTests {
    struct Seen: Sendable {
        let afterPicture: Int?
        let afterWords: Int?
        let leftAtEnd: Bool
    }

    @Test func aPressOnAPictureSendsNothingAndAPressOnItsWordsSendsItsOption() async throws {
        let (seen, screen) = try await ViewHost.onMainLoop { () -> Seen in
            let now = Int(Date().timeIntervalSince1970)
            let names = ["bottle.png", "bigwords.png", "morning.png"]
            let pictures: [[String: Any]] = names.enumerated().map { index, name in
                ["id": 31 + index, "name": name, "mime": "image/png", "size": 1200,
                 "sha256": String(repeating: "b", count: 64), "created": now - 60, "kept": NSNull()]
            }
            let features = [AppDraws.needPictures]
            let store = ViewHost.store(try ViewHost.reading(
                needs: [["id": 9, "title": "Pick the ad for the campaign", "why": "", "todo": "",
                         "raised": now - 120, "by": "manager", "answered": NSNull(),
                         "options": ["Dark, the bottle", "Orange, big words", "Blue, the morning"],
                         "pictures": pictures]],
                features: features))
            store.destination = .needs
            store.selectedNeed = 9
            // an answer waits with Undo first (`AnswerHolds`): a short wait here, so the press reaches its queue soon
            AnswerHolds.shared.wait = .milliseconds(200)
            defer { AnswerHolds.shared.wait = .seconds(5) }
            let window = ViewHost.window(store)
            defer { ViewHost.close(window) }
            let need = try #require(store.openNeeds.first)
            // the second picture, by its file's name, which its tile shows while its bytes have not come
            guard let picture = try ViewHost.middle(of: "bigwords.png", in: window) else {
                throw ViewHost.Missing(description: "the second option's picture is not drawn")
            }
            ViewHost.atOnce(ViewHost.click(picture, in: window))
            ViewHost.turn(1)
            let afterPicture = AnswerWaits.shared.press(of: need)?.choice
            var afterWords: Int?
            // a press that waits already says "Sending…" on its option, which moves the words: the check stops here
            if afterPicture == nil {
                guard let words = try ViewHost.middle(of: "Orange, big words", in: window) else {
                    throw ViewHost.Missing(description: "the second option's words are not drawn")
                }
                ViewHost.atOnce(ViewHost.click(words, in: window))
                ViewHost.turn(5) { AnswerWaits.shared.press(of: need) != nil }
                afterWords = AnswerWaits.shared.press(of: need)?.choice
            }
            // the item leaves the reading: the press that waits ends, and no later test finds it
            store.state = try ViewHost.reading(needs: [], features: features)
            let left = ViewHost.turn(5) { AnswerWaits.shared.press(of: need) == nil }
            return Seen(afterPicture: afterPicture, afterWords: afterWords, leftAtEnd: left)
        }
        #expect(seen.afterPicture == nil, "a look at the picture sends no answer")
        #expect(seen.afterWords == 1, "the press on the words sends their option")
        #expect(seen.leftAtEnd)
        #expect(screen.stayedHis)
    }
}
