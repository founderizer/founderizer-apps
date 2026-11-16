import Foundation
import Testing
@testable import FleetCore

// Rules that send (WAKEUPS-INTERFACE.md 8, owner API 1.184): the words of the row of a rule whose times send a ready
// text, and of a person's reminder, in On a schedule. Example names only.

private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

struct SendRuleTests {
    @Test func aRuleThatSendsSaysWhatGoesWhere() throws {
        func task(_ send: Any) throws -> TriggerTask {
            try JSONDecoder().decode(TriggerTask.self, from: json([
                "title": "Send to Acme Sales", "details": "Weekly offers", "done_when": "The hub sends the text at each time, with no session.",
                "needs": "none", "goal_id": NSNull(), "send": send]))
        }
        #expect(try task(["to": "owner", "text": "x"]).send?.title == "Send to you")
        #expect(try task(["to": "chat", "name": "Acme Sales", "account": "telegram-sales", "chat": "-1001000000001",
                          "text": "x"]).send?.title == "Send to Acme Sales")
        #expect(try task(["to": "conversation", "name": "Ana Ruiz", "conversation": 4, "text": "x"]).send?.title == "Reminder for Ana Ruiz")
        #expect(try task(["to": "somewhere", "text": "x"]).send?.title == nil)
        // a task with no send, as every rule before 1.184, and the encode the owner's app sends back stays five keys
        let plain = try JSONDecoder().decode(TriggerTask.self, from: json([
            "title": "Check", "details": "", "done_when": "checked", "needs": "none", "goal_id": NSNull()]))
        #expect(plain.send == nil && plain.isValid)
        let sent = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(try task(["to": "owner", "text": "x"])))
                                as? [String: Any])
        #expect(Set(sent.keys) == ["title", "details", "done_when", "needs", "goal_id"])
    }
}
