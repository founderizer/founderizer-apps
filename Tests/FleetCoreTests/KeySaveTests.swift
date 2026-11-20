import Foundation
import Testing
@testable import FleetCore

/// A key request's card in a chat while he saves a key (the owner, 20 November 2026: "no text needed, just a nice
/// animation of loading and then a nice and smooth check"): a ring while the save runs, then a check, and the folded card.
struct KeySaveTests {
    @Test("A ring only for a save, the check once every step is done, also while the last read runs, and rows for a warning")
    func theFormsLook() {
        #expect(KeySaveLook.of(done: nil, busy: false, saving: false) == nil)
        // Decline, his words and the checks before a save make the form busy with no save: no ring
        #expect(KeySaveLook.of(done: nil, busy: true, saving: false) == nil)
        #expect(KeySaveLook.of(done: nil, busy: true, saving: true) == .goes)
        #expect(KeySaveLook.of(done: false, busy: true, saving: true) == .goes)
        // the save's last read of the hub brings the answered request: the check stands before it
        #expect(KeySaveLook.of(done: true, busy: true, saving: true) == .saved)
        #expect(KeySaveLook.of(done: false, busy: false, saving: false) == .failed)
        // Try again
        #expect(KeySaveLook.of(done: false, busy: true, saving: false) == .goes)
        // a grant whose agent cannot use the key yet, or an answer that the request had already: his rows, no check
        #expect(KeySaveLook.of(done: true, warned: true, busy: false, saving: false) == .failed)
        #expect(KeySaveLook.of(done: true, warned: true, busy: true, saving: true) == .goes)
    }

    @Test("An answered request never offers its Key field again, a step that failed after its answer stays, and a form that goes mid-save leaves no ring")
    func whenTheCardKeepsItsForm() {
        var card = KeySaveCard()
        #expect(!card.holds && card.showsForm(open: true) && !card.showsForm(open: false))
        #expect(card.folds(answered: true, expanded: false) && !card.folds(answered: true, expanded: true))
        card.take(.goes)
        // the reading can bring the answer before the save ends: the form stays to say how it ended, and nothing folds
        #expect(card.collapsed(expanded: false) && card.holds && card.showsForm(open: false))
        #expect(!card.folds(answered: true, expanded: false))
        card.take(.saved)
        // the form goes with the answered request: its check stays until it has drawn itself
        let changed = card.take(nil)
        #expect(!changed && card.look == .saved && card.holds && !card.folds(answered: true, expanded: false))
        card.settle()
        #expect(!card.holds && !card.showsForm(open: false) && card.collapsed(expanded: false))
        #expect(card.folds(answered: true, expanded: false))
        // he opens the folded card: its words, never a form
        #expect(!card.collapsed(expanded: true) && !card.showsForm(open: false))

        var failed = KeySaveCard()
        failed.take(.goes)
        failed.take(.failed)
        // a grant failed and the answer went without it: the card stays open with the form's rows and Try again
        #expect(failed.holds && failed.showsForm(open: false) && !failed.collapsed(expanded: false))
        #expect(!failed.folds(answered: true, expanded: false))
        failed.settle()
        #expect(failed.holds)
        failed.end()
        #expect(!failed.holds && !failed.showsForm(open: false) && failed.folds(answered: true, expanded: false))

        // a form that goes in the middle of a save (the hub's generation changed): no ring turns on for ever
        var gone = KeySaveCard()
        gone.take(.goes)
        gone.take(nil)
        #expect(gone.look == nil && !gone.holds && !gone.collapsed(expanded: false))
    }

    @Test("Only a saved key folds to its title and a check: a decline and his words keep their words")
    func onlyASavedKeyFoldsToTheCheck() throws {
        func key(_ secret: [String: Any], answered: Bool = true) throws -> OwnerNeed {
            try JSONDecoder().decode(OwnerNeed.self, from: JSONSerialization.data(withJSONObject: [
                "id": 2, "by": "manager", "title": "Synthetic", "why": "", "todo": "", "raised": 1,
                "answer": answered ? "Synthetic" : NSNull(), "answered": answered ? 2 : NSNull(), "kind": "secret", "secret": secret,
            ]))
        }
        let saved = ["kind": "api_key", "saved": "bws://11111111-2222-4333-8444-555555555555"]
        #expect(try key(saved).answeredWithKey)
        #expect(!(try key(saved, answered: false).answeredWithKey))
        #expect(!(try key(["kind": "login", "clarified": 2.5]).answeredWithKey))
        #expect(!(try key(["kind": "api_key"]).answeredWithKey))
    }

    @Test("The sidebar's line for his answer with a saved key is the check; a task that moved after it and other answers keep their words, and a request that waits for him comes first")
    func theRowsLineAfterASavedKey() throws {
        func need(_ secret: [String: Any]?) throws -> OwnerNeed {
            var json: [String: Any] = ["id": 4, "by": "vps", "title": "Synthetic", "why": "", "todo": "", "raised": 1,
                                       "answer": "Synthetic", "answered": 8]
            if let secret { json["kind"] = "secret"; json["secret"] = secret }
            return try JSONDecoder().decode(OwnerNeed.self, from: JSONSerialization.data(withJSONObject: json))
        }
        func answer(to id: Int) throws -> ChatEntry {
            .message(try JSONDecoder().decode(OwnerMessage.self, from: JSONSerialization.data(withJSONObject: [
                "request_id": "r", "recipient": "vps", "kind": "answer", "need_id": id, "event_id": 1, "created": 9.0,
                "client": "test", "text": "Saved the API key EXAMPLE_KEY in the vault, as bws://11111111-2222-4333-8444-555555555555.",
            ])))
        }
        func task(moved: Double) throws -> FleetTask {
            let json = "{\"id\": 1, \"title\": \"The shop page\", \"details\": \"\", \"done_when\": \"\", \"needs\": \"\", "
                + "\"goal\": \"\", \"owner\": \"vps\", \"requester\": \"manager\", \"state\": \"working\", "
                + "\"created\": 1, \"last_activity\": \(moved), \"attempt\": 1, \"restarts\": 0, \"nudge_level\": 0, \"stop_sent\": 0}"
            return try JSONDecoder().decode(FleetTask.self, from: Data(json.utf8))
        }
        let saved = try need(["kind": "api_key", "saved": "bws://11111111-2222-4333-8444-555555555555"])
        #expect(ChatList.savedKey("vps", last: try answer(to: 4), tasks: [], needs: [saved]))
        // a task that moved after his answer is the line, and says what the agent does now
        #expect(!ChatList.savedKey("vps", last: try answer(to: 4), tasks: [try task(moved: 50)], needs: [saved]))
        #expect(ChatList.savedKey("vps", last: try answer(to: 4), tasks: [try task(moved: 5)], needs: [saved]))
        // a declined key request, an answer to another request and a request that the reading does not hold keep words
        #expect(!ChatList.savedKey("vps", last: try answer(to: 4), tasks: [], needs: [try need(["kind": "api_key"])]))
        #expect(!ChatList.savedKey("vps", last: try answer(to: 4), tasks: [], needs: [try need(nil)]))
        #expect(!ChatList.savedKey("vps", last: try answer(to: 5), tasks: [], needs: [saved]))
        // **one order for both rows**: a request that waits for him, newer than the answer, is the line, in its words
        let waiting = try JSONDecoder().decode(OwnerNeed.self, from: JSONSerialization.data(withJSONObject: [
            "id": 7, "by": "vps", "title": "Enter the API key OTHER_KEY for api.example.com", "why": "", "todo": "", "raised": 20,
            "answer": NSNull(), "answered": NSNull(), "kind": "secret", "secret": ["kind": "api_key"],
        ]))
        let both = ChatList.line("vps", entries: [try answer(to: 4)], whole: true, needs: [saved, waiting], tasks: [])
        #expect(both?.request?.id == 7 && both?.isSavedKey == false && both?.words == waiting.title)
        let alone = ChatList.line("vps", entries: [try answer(to: 4)], whole: true, needs: [saved], tasks: [])
        #expect(alone?.request == nil && alone?.isSavedKey == true)
        #expect(ChatList.line("vps", entries: [], whole: true, needs: [saved], tasks: []) == nil)
    }
}
