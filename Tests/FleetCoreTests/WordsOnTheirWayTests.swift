import Foundation
import Testing
@testable import FleetCore

/// His message and his answer show in the frame he sends them, from the request the outbox saved, until the reading
/// that holds the hub's copy (fix round 3, item 11).
struct WordsOnTheirWayTests {
    private let hub = URL(string: "http://127.0.0.1:8765")!

    private func message(to agent: String = "vps", text: String = "Is the fix live?") -> PendingRequest {
        PendingRequest(hub: hub, database: "test-db", client: "test", recipient: agent, text: text)
    }

    private func receipt(for request: PendingRequest) throws -> SendReceipt {
        try JSONDecoder().decode(SendReceipt.self, from: JSONSerialization.data(withJSONObject: [
            "request_id": request.requestID.uuidString.lowercased(), "recipient": request.recipient as Any? ?? NSNull(),
            "ok": true, "event_id": 5, "created": 995.0, "replayed": false, "client": request.client,
        ]))
    }

    private func need(_ id: Int, answered: Bool = false) throws -> OwnerNeed {
        try JSONDecoder().decode(OwnerNeed.self, from: JSONSerialization.data(withJSONObject: [
            "id": id, "by": "vps", "title": "Refund two orders?", "why": "", "todo": "", "raised": 900.0,
            "answer": answered ? "Refund neither" : NSNull(), "answered": answered ? 950.0 : NSNull(),
        ]))
    }

    private func onItsWay(_ pending: PendingRequest?, kept: PendingRequest? = nil, receipt: SendReceipt? = nil,
                          to agent: String = "vps", database: String = "test-db",
                          messages: [OwnerMessage] = []) -> PendingRequest? {
        WordsOnTheirWay.message(to: agent, pending: pending, kept: kept, receipt: receipt, hub: hub, database: database,
                                messages: messages)
    }

    @Test("His message is drawn from the saved request at once, in its own chat, until the reading holds the hub's copy")
    func aMessageFromItsSavedRequest() throws {
        let sent = message()
        #expect(onItsWay(sent) == sent)
        #expect(onItsWay(sent, to: "manager") == nil)
        // The hub's copy keeps the request's id, in the hub's own lower case, and takes its place.
        let copy = OwnerMessage(onItsWay: sent)
        #expect(copy.request_id == sent.requestID.uuidString.lowercased())
        #expect(copy.chatRecipient == "vps" && copy.kind == "message" && copy.text == "Is the fix live?")
        #expect(ChatEntry.message(copy).id == "message-" + sent.requestID.uuidString.lowercased())
        #expect(onItsWay(sent, messages: [copy]) == nil)
    }

    @Test("After the receipt, the one the chat saw go stays until the reading, and only when the hub confirmed it")
    func theReceiptKeepsItUntilTheReading() throws {
        let sent = message()
        #expect(onItsWay(nil, kept: sent, receipt: try receipt(for: sent)) == sent)
        #expect(onItsWay(nil, kept: sent) == nil)
        #expect(onItsWay(nil, kept: sent, receipt: try receipt(for: message())) == nil)
        #expect(onItsWay(nil, kept: sent, receipt: try receipt(for: sent), messages: [OwnerMessage(onItsWay: sent)]) == nil)
        // A newer request on its way comes first.
        let next = message(text: "And the label?")
        #expect(onItsWay(next, kept: sent, receipt: try receipt(for: sent)) == next)
    }

    @Test("A refused request, a correction and another hub generation are not drawn as said")
    func notWhatTheHubRefused() throws {
        var refused = message()
        refused.refusal = "Hub refused the request (409): Vps is in setup."
        #expect(onItsWay(refused) == nil)
        let correction = PendingRequest(hub: hub, database: "test-db", client: "test", recipient: "vps",
                                        replacesRequestID: UUID().uuidString.lowercased(), text: "Other words.")
        #expect(onItsWay(correction) == nil)
        #expect(onItsWay(message(), database: "other-db") == nil)
        // An answer is the card's, never a bubble.
        let answer = PendingRequest(hub: hub, database: "test-db", client: "test", needID: 7, text: "Refund neither")
        #expect(onItsWay(answer) == nil)
    }

    @Test("An answer folds its card from the saved request while the reading still has the request open")
    func anAnswerFoldsFromItsSavedRequest() throws {
        let answer = PendingRequest(hub: hub, database: "test-db", client: "test", needID: 7, choice: 1,
                                    text: "Refund neither")
        let open = try need(7)
        #expect(WordsOnTheirWay.answer(to: open, pending: answer, kept: nil, receipt: nil, hub: hub,
                                       database: "test-db") == answer)
        #expect(WordsOnTheirWay.answer(to: try need(8), pending: answer, kept: nil, receipt: nil, hub: hub,
                                       database: "test-db") == nil)
        #expect(WordsOnTheirWay.answer(to: open, pending: nil, kept: answer, receipt: try receipt(for: answer), hub: hub,
                                       database: "test-db") == answer)
        // Answered in the reading: the card folds by its own answer.
        #expect(WordsOnTheirWay.answer(to: try need(7, answered: true), pending: answer, kept: nil, receipt: nil,
                                       hub: hub, database: "test-db") == nil)
    }

    @Test("The field is empty while its draft is the words on their way, and keeps what he writes meanwhile")
    func theFieldEmptiesWithTheSend() {
        let sent = message()
        #expect(WordsOnTheirWay.field("Is the fix live?\n", sending: sent) == "")
        #expect(WordsOnTheirWay.field("And the label?", sending: sent) == "And the label?")
        #expect(WordsOnTheirWay.field("Is the fix live?", sending: nil) == "Is the fix live?")
    }
}
