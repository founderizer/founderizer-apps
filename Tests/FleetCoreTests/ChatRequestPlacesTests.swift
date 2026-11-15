import Foundation
import Testing
@testable import FleetCore

/// A request stands in the agent's chat where it was raised (the owner, 14 November 2026), on the Mac and the iPhone.
struct ChatRequestPlacesTests {
    private func mine(_ id: String, at created: Double, answering need: Int? = nil) throws -> ChatEntry {
        .message(try JSONDecoder().decode(OwnerMessage.self, from: JSONSerialization.data(withJSONObject: [
            "request_id": id, "kind": need == nil ? "message" : "answer", "need_id": need as Any? ?? NSNull(),
            "text": "Synthetic", "event_id": 1, "created": created, "client": "test", "recipient": "manager",
        ])))
    }

    private func agents(_ id: Int, at created: Double, replyingTo asked: String? = nil) throws -> ChatEntry {
        .report(try JSONDecoder().decode(ManagerReport.self, from: JSONSerialization.data(withJSONObject: [
            "id": id, "agent": "manager", "text": "Synthetic", "about": "", "created": created,
            "in_reply_to": asked as Any? ?? NSNull(),
        ])))
    }

    private func need(_ id: Int, raised: Double, answered: Double? = nil, options: [String]? = nil,
                      chosen: Int? = nil, chose: [Int]? = nil, multi: Bool = false) throws -> OwnerNeed {
        try JSONDecoder().decode(OwnerNeed.self, from: JSONSerialization.data(withJSONObject: [
            "id": id, "by": "manager", "title": "Synthetic", "why": "", "todo": "", "raised": raised,
            "answer": answered == nil ? NSNull() : "Correos", "answered": answered as Any? ?? NSNull(),
            "options": options as Any? ?? NSNull(), "chosen": chosen as Any? ?? NSNull(),
            "chose": chose as Any? ?? NSNull(), "multi": multi,
        ]))
    }

    /// `event`: the hub's number of the message, and 0 for his words on their way, which the chat itself draws.
    private func mine(_ id: String, at created: Double, answering need: Int, saying text: String,
                      event: Int = 1) throws -> ChatEntry {
        .message(try JSONDecoder().decode(OwnerMessage.self, from: JSONSerialization.data(withJSONObject: [
            "request_id": id, "kind": "answer", "need_id": need, "text": text, "event_id": event, "created": created,
            "client": "test", "recipient": "manager",
        ])))
    }

    @Test("A waiting request that no message told him about stands at its own time, not at the end of the chat")
    func atItsOwnTime() throws {
        let chat = [try agents(1, at: 10), try mine("a", at: 20), try mine("b", at: 40), try agents(2, at: 50)]
        let places = ChatRequestPlaces.inTime(needs: [try need(7, raised: 30)], in: chat, whole: true)
        #expect(places.before == ["message-b": [7]])
        #expect(places.after.isEmpty && places.atEnd.isEmpty && places.hidden.isEmpty && places.spoken.isEmpty)
    }

    @Test("Only a request that nothing came after stands at the end, and what comes later stands under it")
    func atTheEndOnlyWhileNewest() throws {
        let chat = [try agents(1, at: 10), try mine("a", at: 20)]
        #expect(ChatRequestPlaces.inTime(needs: [try need(7, raised: 30)], in: chat, whole: true).atEnd == [7])
        let later = ChatRequestPlaces.inTime(needs: [try need(7, raised: 30)], in: chat + [try mine("b", at: 40)], whole: true)
        #expect(later.before == ["message-b": [7]] && later.atEnd.isEmpty)
    }

    @Test("The agent's reply of the turn in which a request was raised stands over its card, and no later message does")
    func underTheReplyOfItsOwnTurn() throws {
        // He asks at 20, the agent raises the request at 30 and answers him at 40: "It is in Needs you.", then the card.
        let turn = [try agents(1, at: 10), try mine("a", at: 20), try agents(2, at: 40, replyingTo: "a"), try agents(3, at: 900)]
        let places = ChatRequestPlaces.inTime(needs: [try need(7, raised: 30), try need(8, raised: 32)], in: turn, whole: true)
        #expect(places.after == ["report-2": [7, 8]] && places.before.isEmpty && places.atEnd.isEmpty)
        // A message that the agent wrote first, hours after the request, answers nothing: the card keeps its own time.
        let first = [try agents(1, at: 10), try mine("a", at: 20), try agents(2, at: 9_000), try agents(3, at: 9_100)]
        let own = ChatRequestPlaces.inTime(needs: [try need(7, raised: 30)], in: first, whole: true)
        #expect(own.before == ["report-2": [7]] && own.after.isEmpty)
        // A reply to a message that he sent after the request is the reply of a later turn.
        let later = [try agents(1, at: 10), try agents(2, at: 40, replyingTo: "b"), try mine("b", at: 35)]
            .sorted { $0.created < $1.created }
        let other = ChatRequestPlaces.inTime(needs: [try need(7, raised: 30)], in: later, whole: true)
        #expect(other.before == ["message-b": [7]] && other.after.isEmpty)
    }

    @Test("Requests of several days keep their days: the newest reply is the chat's last entry")
    func oldRequestsDoNotStandUnderTheNewestReply() throws {
        // His fleet on 14 November 2026: eight waiting requests of a week stood under the reply to his answer.
        let chat = [try mine("a", at: 10), try mine("b", at: 100), try mine("c", at: 200), try agents(9, at: 300)]
        let needs = [try need(1, raised: 50), try need(2, raised: 60), try need(3, raised: 150)]
        let places = ChatRequestPlaces.inTime(needs: needs, in: chat, whole: true)
        #expect(places.before == ["message-b": [1, 2], "message-c": [3]])
        #expect(places.atEnd.isEmpty && places.after.isEmpty)
    }

    @Test("What he answers in his own words is his message at its time, and the card folds where it was raised")
    func anAnswerInWordsIsHisMessage() throws {
        let chat = [try mine("a", at: 10), try mine("b", at: 40),
                    try mine("c", at: 60, answering: 7, saying: "What is it for?"), try agents(2, at: 70)]
        let places = ChatRequestPlaces.inTime(needs: [try need(7, raised: 30, answered: 60)], in: chat, whole: true)
        #expect(places.before == ["message-b": [7]])
        #expect(places.spoken == [7])
        #expect(places.hidden.isEmpty)
    }

    @Test("An option that he pressed is no second bubble: its card shows it, and a card before it keeps its place")
    func aPressIsNoSecondBubble() throws {
        let chat = [try mine("a", at: 10), try mine("c", at: 45, answering: 7, saying: "Yes"),
                    try mine("d", at: 55, answering: 8, saying: "No, later"), try agents(2, at: 70)]
        let needs = [try need(7, raised: 20, answered: 45, options: ["Yes", "No"], chosen: 0),
                     try need(8, raised: 30, answered: 55, options: ["Yes", "No"]),
                     // Raised right before the press on 7, which is not drawn: it stands before the next drawn entry.
                     try need(9, raised: 44)]
        let places = ChatRequestPlaces.inTime(needs: needs, in: chat, whole: true)
        #expect(places.hidden == ["message-c"])
        #expect(places.spoken == [8])
        #expect(places.before == ["message-d": [7, 8, 9]])
        // Ticked options are a press too.
        let ticked = try need(5, raised: 20, answered: 45, options: ["A", "B", "C"], chose: [0, 2], multi: true)
        let both = ChatRequestPlaces.inTime(needs: [ticked], in: [try mine("a", at: 10), try mine("c", at: 45, answering: 5, saying: "A; C")], whole: true)
        #expect(both.hidden == ["message-c"] && both.spoken.isEmpty)
    }

    @Test("While the reading still has the request open, his words on their way are his message, and a press is not")
    func onItsWay() throws {
        let open = try need(7, raised: 20, options: ["Yes", "No"])
        let words = [try mine("a", at: 10), try mine("c", at: 45, answering: 7, saying: "Why?")]
        #expect(ChatRequestPlaces.inTime(needs: [open], in: words, whole: true).spoken == [7])
        #expect(ChatRequestPlaces.inTime(needs: [open], in: words, whole: true).hidden.isEmpty)
        let press = [try mine("a", at: 10), try mine("c", at: 45, answering: 7, saying: "No")]
        #expect(ChatRequestPlaces.inTime(needs: [open], in: press, whole: true).hidden == ["message-c"])
        #expect(ChatRequestPlaces.inTime(needs: [open], in: press, whole: true).atEnd == [7])
        // Words that he wrote and that are an option's own words: on their way they are his message at once, and
        // not one reading late (the review of 14 November 2026). The chat draws only written words on their way.
        let same = [try mine("a", at: 10), try mine("c", at: 45, answering: 7, saying: "No", event: 0)]
        let places = ChatRequestPlaces.inTime(needs: [open], in: same, whole: true)
        #expect(places.spoken == [7] && places.hidden.isEmpty && places.before == ["message-c": [7]])
    }

    @Test("A request older than the messages the chat holds is not drawn, and his answer to it is his message")
    func olderThanTheWindowInTime() throws {
        let window = [try agents(5, at: 100), try mine("z", at: 110, answering: 7, saying: "Yes")]
        let waiting = ChatRequestPlaces.inTime(needs: [try need(6, raised: 50)], in: window, whole: false)
        #expect(waiting == ChatRequestPlaces())
        // A press is no bubble, also while its card is among the earlier messages: nothing changes its form when the
        // chat draws further back.
        let pressed = try need(7, raised: 50, answered: 110, options: ["Yes", "No"], chosen: 0)
        let out = ChatRequestPlaces.inTime(needs: [pressed], in: window, whole: false)
        #expect(out.hidden == ["message-z"] && out.before.isEmpty && out.after.isEmpty && out.atEnd.isEmpty)
        #expect(out.rows(of: window).map(\.id) == ["report-5"])
        // Words that he wrote to it are his message, and no card says them.
        let written = ChatRequestPlaces.inTime(needs: [try need(7, raised: 50, answered: 110)], in: window, whole: false)
        #expect(written == ChatRequestPlaces())
        #expect(written.rows(of: window).map(\.id) == ["report-5", "message-z"])
        // The whole chat: it stands at the chat's start, and its card shows the press.
        let whole = ChatRequestPlaces.inTime(needs: [pressed], in: [try mine("y", at: 90)] + window, whole: true)
        #expect(whole.before == ["message-y": [7]] && whole.hidden == ["message-z"])
    }

    @Test("The rows of a chat: each card in its place under one id, and a press that its card shows is no row")
    func rowsInOrder() throws {
        let chat = [try mine("a", at: 10), try agents(1, at: 20, replyingTo: "a"), try mine("b", at: 40),
                    try mine("c", at: 45, answering: 7, saying: "Yes"), try agents(2, at: 50)]
        let needs = [try need(6, raised: 15), try need(7, raised: 30, answered: 45, options: ["Yes", "No"], chosen: 0),
                     try need(8, raised: 60)]
        let rows = ChatRequestPlaces.inTime(needs: needs, in: chat, whole: true).rows(of: chat)
        #expect(rows.map(\.id) == ["message-a", "report-1", "need-6", "need-7", "message-b", "report-2", "need-8"])
        // An entry that comes after the card at the end moves the card over it, under the same id.
        let later = chat + [try mine("d", at: 70)]
        #expect(ChatRequestPlaces.inTime(needs: needs, in: later, whole: true).rows(of: later).map(\.id).suffix(3)
                == ["report-2", "need-8", "message-d"])
    }

    @Test("An answer in words that left no message in the chat is not spoken: its folded card says the words")
    func wordsWithNoMessage() throws {
        // He answered from a place that wrote no message of his into this chat.
        let chat = [try mine("a", at: 10), try mine("b", at: 40)]
        let places = ChatRequestPlaces.inTime(needs: [try need(7, raised: 30, answered: 35)], in: chat, whole: true)
        #expect(places.spoken.isEmpty && places.hidden.isEmpty && places.before == ["message-b": [7]])
    }

    @Test("The reply of a request's turn is found whatever the case of the request's id")
    func theTurnsReplyByAnyCase() throws {
        let chat = [try mine("ab-1", at: 20), try agents(2, at: 40, replyingTo: "AB-1")]
        #expect(ChatRequestPlaces.inTime(needs: [try need(7, raised: 30)], in: chat, whole: true).after == ["report-2": [7]])
    }

    @Test("A card has the time it was raised for the marks of a day or an hour, and no row is earlier than the one over it")
    func timesOfRows() throws {
        let chat = [try mine("a", at: 100), try agents(1, at: 300, replyingTo: "a"), try mine("b", at: 90_000)]
        let needs = [try need(6, raised: 200), try need(7, raised: 50_000)]
        let rows = ChatRequestPlaces.inTime(needs: needs, in: chat, whole: true).rows(of: chat)
        #expect(rows.map(\.id) == ["message-a", "report-1", "need-6", "need-7", "message-b"])
        let raised = Dictionary(uniqueKeysWithValues: needs.map { ($0.id, $0.raised) })
        // Request 6 was raised before the reply that stands over it: it takes the reply's time.
        #expect(ChatRequestPlaces.times(of: rows, raised: raised) == [100, 300, 300, 50_000, 90_000])
    }

    @Test("What a press writes: an option's own words, or ticked options joined, and nothing else")
    func whatAPressWrites() throws {
        let one = try need(1, raised: 1, options: ["Yes", "No; later"])
        #expect(one.offers("Yes") && one.offers("No; later") && !one.offers("yes please") && !one.offers("Yes; No; later"))
        let many = try need(1, raised: 1, options: ["A", "B", "C"], multi: true)
        #expect(many.offers("A; C") && many.offers("B") && !many.offers("A; D"))
        #expect(!(try need(1, raised: 1).offers("Done")))
    }

    @Test("An answer in words has no option, no tick and no secure form")
    func whichAnswersAreWords() throws {
        #expect(try need(1, raised: 1, answered: 2).answeredInWords)
        #expect(try need(1, raised: 1, answered: 2, options: ["Yes", "No"]).answeredInWords)
        #expect(!(try need(1, raised: 1, answered: 2, options: ["Yes", "No"], chosen: 1).answeredInWords))
        #expect(!(try need(1, raised: 1, answered: 2, options: ["A", "B"], chose: [0], multi: true).answeredInWords))
        #expect(!(try need(1, raised: 1).answeredInWords))
        let hub = URL(string: "http://127.0.0.9:8765")!
        #expect(PendingRequest(hub: hub, database: "d", client: "c", needID: 1, text: "Why?").answersInWords)
        #expect(!PendingRequest(hub: hub, database: "d", client: "c", needID: 1, choice: 0, text: "Yes").answersInWords)
        #expect(!PendingRequest(hub: hub, database: "d", client: "c", needID: 1, choices: [0, 1], text: "A; B").answersInWords)
        #expect(!PendingRequest(hub: hub, database: "d", client: "c", text: "A message").answersInWords)
    }
}
