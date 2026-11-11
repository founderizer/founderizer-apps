import Foundation
import Testing
@testable import FleetCore

/// A request stands in the agent's chat right after the agent's message that told the owner about it (D-7 item 1).
struct ChatRequestPlacesTests {
    private func mine(_ id: String, at created: Double, answering need: Int? = nil) throws -> ChatEntry {
        .message(try JSONDecoder().decode(OwnerMessage.self, from: JSONSerialization.data(withJSONObject: [
            "request_id": id, "kind": need == nil ? "message" : "answer", "need_id": need as Any? ?? NSNull(),
            "text": "Synthetic", "event_id": 1, "created": created, "client": "test", "recipient": "manager",
        ])))
    }

    private func agents(_ id: Int, at created: Double) throws -> ChatEntry {
        .report(try JSONDecoder().decode(ManagerReport.self, from: JSONSerialization.data(withJSONObject: [
            "id": id, "agent": "manager", "text": "Synthetic", "about": "", "created": created,
        ])))
    }

    private func need(_ id: Int, raised: Double, answered: Double? = nil) throws -> OwnerNeed {
        try JSONDecoder().decode(OwnerNeed.self, from: JSONSerialization.data(withJSONObject: [
            "id": id, "by": "manager", "title": "Synthetic", "why": "", "todo": "", "raised": raised,
            "answer": answered == nil ? NSNull() : "Correos", "answered": answered as Any? ?? NSNull(),
        ]))
    }

    @Test("A request raised in the agent's turn stands under the reply that told him, and his next message under it")
    func underTheReplyOfItsTurn() throws {
        let chat = [try mine("a", at: 10), try agents(1, at: 30), try agents(2, at: 31), try mine("b", at: 50)]
        let places = ChatRequestPlaces.of(needs: [try need(7, raised: 20)], in: chat, whole: true)
        #expect(places.after == ["report-2": [7]])
        #expect(places.atEnd.isEmpty)
    }

    @Test("Raised after the agent told him, with nothing of his between, it stands under that message")
    func underTheMessageBeforeIt() throws {
        // The fixture's Manager: "… It is in Needs you." at 30, the requests raised at 40 and 60.
        let chat = [try mine("a", at: 10), try agents(1, at: 30)]
        let places = ChatRequestPlaces.of(needs: [try need(8, raised: 60), try need(7, raised: 40)], in: chat, whole: true)
        #expect(places.after == ["report-1": [7, 8]])
        // His next message comes under the cards, not over them.
        let later = ChatRequestPlaces.of(needs: [try need(7, raised: 40)], in: chat + [try mine("b", at: 70)], whole: true)
        #expect(later.after == ["report-1": [7]])
    }

    @Test("A request no message told him about waits at the end, and once answered stands where his answer is")
    func atTheEndOrInPlaceOfTheAnswer() throws {
        let chat = [try agents(1, at: 10), try mine("a", at: 20), try mine("b", at: 40)]
        #expect(ChatRequestPlaces.of(needs: [try need(7, raised: 30)], in: chat, whole: true).atEnd == [7])
        let answered = chat + [try mine("c", at: 50, answering: 7)]
        let places = ChatRequestPlaces.of(needs: [try need(7, raised: 30, answered: 50)], in: answered, whole: true)
        #expect(places.inPlaceOf == ["message-c": 7])
        #expect(places.after.isEmpty && places.atEnd.isEmpty && places.hidden.isEmpty)
    }

    @Test("An answered request keeps its place under the agent's message, and his answer is no second bubble")
    func answeredKeepsItsPlace() throws {
        let chat = [try mine("a", at: 10), try agents(1, at: 30), try mine("c", at: 45, answering: 7), try agents(2, at: 50)]
        let places = ChatRequestPlaces.of(needs: [try need(7, raised: 20, answered: 45)], in: chat, whole: true)
        #expect(places.after == ["report-1": [7]])
        #expect(places.hidden == ["message-c"])
    }

    @Test("A request raised before the oldest message the chat holds is not placed by the newer ones")
    func olderThanTheWindow() throws {
        let window = [try agents(5, at: 100), try mine("z", at: 110)]
        #expect(ChatRequestPlaces.of(needs: [try need(7, raised: 50)], in: window, whole: false).atEnd == [7])
        #expect(ChatRequestPlaces.of(needs: [try need(7, raised: 50, answered: 60)], in: window, whole: false)
            == ChatRequestPlaces())
        // The whole chat: its first message is the agent's reply of that turn.
        #expect(ChatRequestPlaces.of(needs: [try need(7, raised: 50)], in: window, whole: true).after == ["report-5": [7]])
    }
}
