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
}
