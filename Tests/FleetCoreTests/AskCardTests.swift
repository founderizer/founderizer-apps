import Foundation
import Testing
@testable import FleetCore

// Explicit test data only: one ask's card as the hub gives it (`GET /ui/mobile/asks/<id>`, owner feature `ask_follow_ups`):
// his messages, the agents' answers and the heads of its tasks.
struct AskCardTests {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Double {
        utc.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!.timeIntervalSince1970
    }

    private func message(_ id: String, _ created: Double, event: Int) -> [String: Any] {
        ["request_id": id, "event_id": event, "text": "Words of \(id)", "created": created, "client": "founderizer-swift/1",
         "origin": false, "recipient": "manager"]
    }

    private func report(_ id: Int, _ created: Double, by agent: String?, replyingTo asked: String? = nil,
                        turn: String? = nil) -> [String: Any] {
        ["id": id, "text": "Reply \(id)", "created": created, "agent": agent ?? NSNull(), "in_reply_to": asked ?? NSNull(),
         "turn": turn ?? NSNull()]
    }

    private func head(_ id: Int, ask: String, owner: String, created: Double, plain: String? = nil,
                      parent: Int? = nil, accepted: Int? = 1, follows: Int? = nil) -> [String: Any] {
        ["plain": plain ?? NSNull(), "id": id, "title": "Task \(id)", "state": "completed", "owner": owner, "requester": "manager", "goal": "",
         "needs": "none", "attempt": 1, "accepted": accepted ?? NSNull(), "created": created, "started": created, "last_activity": created + 60,
         "delivered": created + 60, "checked_at": NSNull(), "waiting_on": NSNull(), "follows": follows ?? NSNull(),
         "stalled_since": NSNull(), "nudge_level": 0, "missing_since": NSNull(), "parent": parent ?? NSNull(), "ask": ask,
         "limit": NSNull()]
    }

    private func card(_ fields: [String: Any]) throws -> AskCard {
        try JSONDecoder().decode(AskCard.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    /// A line in short: "day", a message's id, "r<report>", or "w:" and the tasks of a message's work.
    private func shape(_ line: AskCard.Line) -> String {
        switch line {
        case .day: "day"
        case .mine(let message): message.request_id
        case .reply(let report): "r\(report.id)"
        case .work(_, let tasks): "w:" + tasks.map { String($0.id) }.joined(separator: ",")
        case .result(let task): "t\(task.id)"
        }
    }

    /// The reading of the picture r3 (`my-asks-tracking-2026-11-25/r3-mac-open.png`): by day, his messages and the answers
    /// in time order, and the work that a message began under the first answer to it. The bugs that this catches: work
    /// under the wrong message, or at the card's end; a follow-up's work under the first message; work of a message
    /// that nothing answered yet left out; a day's line missing where the day changes; an answer that took his turn
    /// (`turn`) standing apart from the work of that message.
    @Test func theWorkOfAMessageStandsUnderItsFirstAnswerByDay() throws {
        let card = try card([
            "db": "test-db", "id": "m1", "agent": "manager", "name": "Refund the failed orders",
            "messages": [message("m1", Self.at(23, 20, 23), event: 1), message("m2", Self.at(25, 9, 5), event: 2),
                         message("m3", Self.at(25, 13), event: 3)],
            "reports": [report(1, Self.at(23, 20, 24), by: "manager", replyingTo: "m1"),
                        report(2, Self.at(25, 9, 6), by: nil, turn: "m2"),
                        report(3, Self.at(25, 12, 48), by: "nova")],
            "tasks": [head(10, ask: "m1", owner: "nova", created: Self.at(23, 20, 30)),
                      head(11, ask: "m1", owner: "shop", created: Self.at(23, 20, 31)),
                      head(12, ask: "m2", owner: "nova", created: Self.at(25, 9, 10)),
                      head(13, ask: "m3", owner: "nova", created: Self.at(25, 13, 1)),
                      head(14, ask: "gone", owner: "nova", created: Self.at(25, 13, 2))],
        ])
        #expect(card.lines(calendar: Self.utc).map(shape)
                    == ["day", "m1", "r1", "w:10,11", "day", "m2", "r2", "w:12", "r3", "m3", "w:13", "w:14"])
        // the agents in it: the one that he asked first, then each in the order in which it came in
        #expect(card.agents == ["manager", "nova", "shop"])
        #expect(card.asked == "manager")
    }

    /// The bug that this catches: the agents' words about what their work came to are on no line of the card (the
    /// picture r3 shows them as an agent's answer), a subtask's result stands beside its task's, a result that its
    /// check refused, that nobody checked yet or that later work follows stands as an answer (the rule of the hub's
    /// `answer`), or a hub before the field (owner API 1.363) fails the card.
    @Test func whatATaskCameToStandsAsItsAgentsAnswerInTimeOrder() throws {
        let refund = try card([
            "db": "test-db", "id": "m1", "agent": "manager", "name": "Refund the failed orders",
            "messages": [message("m1", Self.at(25, 9), event: 1)],
            "reports": [report(1, Self.at(25, 9, 1), by: "manager", replyingTo: "m1"),
                        report(2, Self.at(25, 13), by: "manager", replyingTo: "m1")],
            "tasks": [head(10, ask: "m1", owner: "nova", created: Self.at(25, 12, 39), plain: "14 orders had the error."),
                      head(11, ask: "m1", owner: "shop", created: Self.at(25, 10), plain: "Part of it.", parent: 10),
                      head(12, ask: "m1", owner: "shop", created: Self.at(25, 11)),
                      head(13, ask: "m1", owner: "shop", created: Self.at(25, 12), plain: "Fixed.", accepted: 0),
                      head(14, ask: "m1", owner: "shop", created: Self.at(25, 12, 30), plain: "Done.", accepted: nil)],
        ])
        #expect(refund.lines(calendar: Self.utc).map(shape) == ["day", "m1", "r1", "w:10,11,12,13,14", "t10", "r2"])
        // a later task that follows it puts its result right, so its words are no answer any more
        let followed = try card([
            "db": "test-db", "id": "m1", "agent": "manager", "name": "Refund the failed orders",
            "messages": [message("m1", Self.at(25, 9), event: 1)], "reports": [],
            "tasks": [head(10, ask: "m1", owner: "nova", created: Self.at(25, 10), plain: "Fixed."),
                      head(15, ask: "m1", owner: "nova", created: Self.at(25, 11), follows: 10)],
        ])
        #expect(followed.lines(calendar: Self.utc).map(shape) == ["day", "m1", "w:10,15"])
        let old = try card(["db": "test-db", "id": "m1", "agent": "manager", "name": "Old hub", "messages": [], "reports": [],
                            "tasks": [head(10, ask: "m1", owner: "nova", created: Self.at(25, 9)).filter { $0.key != "plain" }]])
        #expect(old.tasks.first?.plainWords == nil)
    }

    /// The bug that this catches (design question 3, the Mac validator of 26 November 2026): words that an AI session of
    /// his or a program sent for him stand on the card as his own typed words; or their answer and their work leave
    /// the card with them. A row of before the hub kept the hand goes by the label of an app of his.
    @Test func onlyHisOwnHandsWordsStandAsHisMessages() throws {
        func said(_ id: String, _ created: Double, event: Int, hand: String?, client: String = "test") -> [String: Any] {
            var row = message(id, created, event: event)
            row["hand"] = hand ?? NSNull()
            row["client"] = client
            return row
        }
        let card = try card([
            "db": "test-db", "id": "m1", "agent": "manager", "name": "Refund the failed orders",
            "messages": [said("m1", Self.at(25, 9), event: 1, hand: "app"),
                         said("m2", Self.at(25, 10), event: 2, hand: "tool"),
                         said("m3", Self.at(25, 11), event: 3, hand: nil, client: "founderizer-ios/1"),
                         said("m4", Self.at(25, 12), event: 4, hand: nil)],
            "reports": [report(1, Self.at(25, 10, 1), by: "manager", replyingTo: "m2")],
            "tasks": [head(10, ask: "m2", owner: "nova", created: Self.at(25, 10, 2))],
        ])
        #expect(card.lines(calendar: Self.utc).map(shape) == ["day", "m1", "r1", "w:10", "m3"])
    }

    /// The bug that this catches: a card of another generation of the hub, or of another ask, stands as this ask's
    /// card; or the card of a follow-up's id (the hub gives the card of its first message) is refused.
    @Test func aCardIsOfTheGenerationAndTheAskThatWasAsked() throws {
        let card = try card(["db": "test-db", "id": "m1", "agent": NSNull(), "name": NSNull(),
                             "messages": [message("m1", Self.at(23, 9), event: 1), message("m2", Self.at(24, 9), event: 2)],
                             "reports": [], "tasks": []])
        #expect(throws: Never.self) { try card.validate(database: "test-db", id: "m1") }
        #expect(throws: Never.self) { try card.validate(database: "test-db", id: "M2") }
        #expect(throws: HubError.self) { try card.validate(database: "another-db", id: "m1") }
        #expect(throws: HubError.self) { try card.validate(database: "test-db", id: "m9") }
        #expect(card.asked == "manager" && card.agents == ["manager"])
    }
}
