import Foundation
import Testing
@testable import FleetCore

/// Owner feature `need_talk` (API 1.106; the owner's yes of 9 November 2026 to each mockup): a short card with its long
/// part behind Details, and options that combine. Its Discuss left the app on 13 November 2026 (API 1.158).
struct NeedTalkTests {
    private let hub = URL(string: "http://hub.test:8765")!

    private func need(_ extra: [String: Any] = [:]) throws -> OwnerNeed {
        let base: [String: Any] = ["id": 7, "title": "Move Acme off .NET 8", "why": "Choose any of four steps.",
                                   "todo": "Tick and send", "raised": 1, "by": "manager",
                                   "options": ["Mia moves them", "Keep the pool", "Retire the copies"]]
        return try JSONDecoder().decode(OwnerNeed.self,
                                        from: JSONSerialization.data(withJSONObject: base.merging(extra) { _, new in new }))
    }

    @Test func anItemCarriesItsDetailsAndItsTicksAndAnOldDiscussionDoesNotStopItsRead() throws {
        // the hub still gives the record of a discussion from before API 1.158, which the app no longer reads
        let item = try need(["details": "Leo's plan, in full.", "multi": true, "chose": NSNull(),
                             "talk": [["who": "owner", "text": "Why now?", "ts": 2],
                                      ["who": "manager", "text": "Support ends tomorrow.", "ts": 3]]])
        #expect(item.details == "Leo's plan, in full." && item.combines)
        let older = try need()                                                  // a hub before the feature
        #expect(older.details == nil && older.multi == nil && !older.combines)
        #expect(try need(["multi": true, "options": ["Only one"]]).combines == false)     // one option is no choice
    }

    @Test func theTickedOptionsTravelAsIndexesInOrderAndTheirWordsStayHere() throws {
        let request = PendingRequest(hub: hub, database: "db", client: "mac", needID: 7, choices: [2, 0, 2],
                                     text: "Mia moves them; Retire the copies")
        let sent = try #require(try JSONSerialization.jsonObject(with: request.body()) as? [String: Any])
        #expect(sent["choices"] as? [Int] == [0, 2])
        #expect(sent["answer"] == nil && sent["choice"] == nil && sent["text"] == nil)
        let saved = try JSONDecoder().decode(PendingRequest.self, from: JSONEncoder().encode(request))
        #expect(saved.choices == [0, 2] && saved == request)                  // the outbox keeps them across a launch
        let press = PendingRequest(hub: hub, database: "db", client: "mac", needID: 7, choice: 1, choices: [0],
                                   text: "Keep the pool")
        #expect(press.choices == nil)                                           // a press is one choice, never both
        let message = PendingRequest(hub: hub, database: "db", client: "mac", choices: [0], recipient: "manager",
                                     text: "Hello")
        #expect(message.choices == nil)                                         // only an item takes ticks
    }

    /// Nothing makes this command since Discuss left the app, but an outbox that an app before 0.1.205 saved can hold
    /// one: it still reads, so the outbox is not blocked, and it still matches its receipt.
    @Test func aSavedDiscussionMessageStillReadsAndItsReceiptConfirmsIt() throws {
        let command = OwnerCommand.needTalk(need: 7)
        #expect(command.route == "ui/needs/7/talk" && command.requiredFeature == NeedTalk.feature)
        #expect(try command.bodyFields(text: "  Why now?  ") as? [String: String] == ["text": "Why now?"])
        #expect(throws: HubError.self) { try command.bodyFields(text: "   ") }
        #expect(throws: HubError.self) { try command.bodyFields(text: String(repeating: "x", count: NeedTalk.most + 1)) }
        #expect(throws: HubError.self) { try OwnerCommand.needTalk(need: 0).bodyFields(text: "Hi") }
        let request = PendingRequest(hub: hub, database: "db", client: "mac", command: command, text: "Why now?")
        #expect(try JSONDecoder().decode(PendingRequest.self, from: JSONEncoder().encode(request)) == request)
        func receipt(_ need: Int, owner: Bool) throws -> ControlReceipt {
            try JSONDecoder().decode(ControlReceipt.self, from: JSONSerialization.data(withJSONObject: [
                "ok": true, "request_id": request.requestID.uuidString.lowercased(), "client": "mac", "replayed": false, "need": need,
                "talk": [["who": owner ? "owner" : "manager", "text": "Why now?", "ts": 2]]]))
        }
        #expect(try receipt(7, owner: true).matches(request))
        #expect(try receipt(8, owner: true).matches(request) == false)
        #expect(try receipt(7, owner: false).matches(request) == false)
        #expect(command.label == "Ask about a request")
    }
}
