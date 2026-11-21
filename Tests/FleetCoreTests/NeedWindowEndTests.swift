import Foundation
import Testing
@testable import FleetCore

/// A request card's own window (`NeedWindowEnd`): it closes by itself once the hub has his answer and no save or run
/// holds the card, and when the request is gone; a failed save keeps it.
struct NeedWindowEndTests {
    private func need(_ extra: [String: Any] = [:]) throws -> OwnerNeed {
        let base: [String: Any] = ["id": 3, "by": "nova", "title": "Enter the API key ACME_KEY", "why": "", "todo": "",
                                   "raised": 1, "kind": "secret", "secret": ["kind": "api_key", "env": "ACME_KEY"]]
        return try JSONDecoder().decode(OwnerNeed.self,
                                        from: JSONSerialization.data(withJSONObject: base.merging(extra) { _, new in new }))
    }

    @Test func itClosesOnceTheHubHasTheAnswerOrTheRequestIsGoneAndAFailedSaveKeepsIt() throws {
        let open = try need(), answered = try need(["answer": "Saved", "answered": 2])
        let none = KeySaveCard()
        // an open reading keeps it, also while his answer is on its way and the card in the chat has folded
        #expect(!NeedWindowEnd.closes(reading: open, runs: false, keySave: none))
        #expect(NeedWindowEnd.closes(reading: answered, runs: false, keySave: none))
        // a run of its command that goes on keeps it, also once the request has its answer
        #expect(!NeedWindowEnd.closes(reading: answered, runs: true, keySave: none))
        // a key's save: the ring and the check that still draws hold the window; the check at rest closes it
        var saved = KeySaveCard()
        saved.take(.goes)
        #expect(!NeedWindowEnd.closes(reading: answered, runs: false, keySave: saved))
        saved.take(.saved)
        #expect(!NeedWindowEnd.closes(reading: answered, runs: false, keySave: saved))
        saved.settle()
        #expect(NeedWindowEnd.closes(reading: answered, runs: false, keySave: saved))
        #expect(!NeedWindowEnd.closes(reading: open, runs: false, keySave: saved))
        // a save that failed keeps it, also once the request has its answer
        var failed = KeySaveCard()
        failed.take(.goes)
        failed.take(.failed)
        #expect(!NeedWindowEnd.closes(reading: answered, runs: false, keySave: failed))
        // the request is gone from the reading, or a new item replaced it
        #expect(NeedWindowEnd.closes(reading: nil, runs: false, keySave: none))
        #expect(NeedWindowEnd.closes(reading: try need(["replaced_by": 4]), runs: false, keySave: none))
    }
}
