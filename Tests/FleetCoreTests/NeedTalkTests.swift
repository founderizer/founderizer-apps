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
        // the hub gives the record of an item's talk, also of a discussion from before API 1.158
        let item = try need(["details": "Leo's plan, in full.", "multi": true, "chose": NSNull(),
                             "talk": [["who": "owner", "text": "Why now?", "ts": 2],
                                      ["who": "manager", "text": "Support ends tomorrow.", "ts": 3]]])
        #expect(item.details == "Leo's plan, in full." && item.combines)
        let older = try need()                                                  // a hub before the feature
        #expect(older.details == nil && older.multi == nil && !older.combines)
        #expect(try need(["multi": true, "options": ["Only one"]]).combines == false)     // one option is no choice
    }

    /// Needs clarification (owner API 1.272; the owner's "Keep Your answer too", 20 November 2026): the card takes his
    /// message under it only where the hub says so (`clarify`: no key request, no conversation's question, no other
    /// agent's item), on a hub that names the feature, while the item is open. A hub with Discuss's old `need_talk`
    /// alone has no such route, and a hub before the version sends neither field.
    @Test func aCardTakesAMessageUnderItOnlyWhereTheHubSaysSo() throws {
        let features = [NeedTalk.feature, NeedClarify.feature]
        let older = try need()
        #expect(older.clarify == nil && older.talk == nil && !older.clarifies(features: features))
        let open = try need(["clarify": true, "talk": [["who": "owner", "text": "Why now?", "ts": 2],
                                                       ["who": "manager", "text": "Support ends tomorrow.", "ts": 3]]])
        #expect(open.clarifies(features: features) && open.talk?.map(\.fromOwner) == [true, false])
        #expect(!open.clarifies(features: [NeedTalk.feature]) && !open.clarifies(features: nil))
        #expect(try !need(["clarify": false]).clarifies(features: features))
        #expect(try !need(["clarify": true, "answer": "Tide", "answered": 4]).clarifies(features: features))
        // the talk stays in the card after his answer, and on a card that takes no more of it; an older hub's has none
        let talk: [[String: Any]] = [["who": "owner", "text": "Why now?", "ts": 2]]
        let answered = try need(["clarify": false, "answer": "Tide", "answered": 4, "talk": talk])
        #expect(answered.shownTalk(features: features).map(\.text) == ["Why now?"])
        #expect(try need(["clarify": false, "talk": talk]).shownTalk(features: features).count == 1)
        #expect(answered.shownTalk(features: [NeedTalk.feature]).isEmpty && older.shownTalk(features: features).isEmpty)
    }

    /// The owner, 21 November 2026: "I clicked on discuss and typed, dont remember where". On his busy Mac the keys came
    /// before the field took them, and the chat sent them to its box: a key that the chat would send to its box goes to
    /// the open field of a card of that chat while its item is open, and to the box in every other case, also for a
    /// card of another agent's chat, an answered one and one that left the reading.
    @Test func aKeyForTheChatsBoxGoesToTheOpenFieldOfACardOfThatChat() throws {
        let needs = [try need(), try need(["id": 8, "by": "leo"]), try need(["id": 9, "answer": "Keep the pool", "answered": 4])]
        #expect(NeedClarify.field(open: 7, chat: "manager", needs: needs) == 7)
        #expect(NeedClarify.field(open: nil, chat: "manager", needs: needs) == nil)
        #expect(NeedClarify.field(open: 7, chat: "leo", needs: needs) == nil)       // the box of another chat
        #expect(NeedClarify.field(open: 8, chat: "manager", needs: needs) == nil)   // a card of another chat
        #expect(NeedClarify.field(open: 9, chat: "manager", needs: needs) == nil)   // answered
        #expect(NeedClarify.field(open: 12, chat: "manager", needs: needs) == nil)  // gone from the reading
    }

    /// The owner, 15 November 2026: "the task itself need to be very clear". The words an agent wrote as his task stand
    /// on the card; the hub's own sentences and the words of an item with a door call stay behind Details.
    @Test func theTaskOfAnAgentsItemStandsInFrontAndTheHubsOwnSentencesDoNot() throws {
        #expect(try need().taskInFront)
        #expect(try need(["details": "The facts."]).taskInFront)
        #expect(try need(["kind": "secret"]).taskInFront == false)             // the sentence about its secure form
        #expect(try need(["kind": "question", "conversation": 4]).taskInFront == false)    // where the answer goes
        #expect(try need(["door_call": String(repeating: "a", count: 64), "door_host": "web-1"]).taskInFront == false)
        #expect(try need(["door_call": String(repeating: "a", count: 64)]).taskInFront == false)  // his yes signs a hash
    }

    /// The lane "Give on the iPhone" (the owner's "Line to the Mac" and "Yes, add it", 19 November 2026): the hub takes
    /// Give, a team card's yes and the door card's Full access only from a Mac (or a PC), so the phone draws one line to
    /// the Mac in their place, and every other option stays by its own index, which its press sends. **The first option
    /// of a card that makes a GitHub App or opens the Add device picture stays, as a row that takes no press**: only
    /// the Mac's press starts that step. The bug that this stops: a press of it on the phone answered the card, closed
    /// it and started nothing.
    @Test func thePhoneDrawsOneLineInThePlaceOfWhatOnlyAMacOrAPCPresses() throws {
        let give: [String: Any] = ["agent": "dev", "level": "write", "repos": ["acme/web"]]
        let hash = String(repeating: "a", count: 64)
        let all: [OwnerNeed.PhoneRow] = [.option(0), .option(1), .option(2)]
        #expect(try need().phoneRows == all && need().onlyOnAComputer == nil)   // also before API 1.244: no `team`
        #expect(try need(["team": false]).phoneRows == all)
        #expect(try need(["door_call": hash]).phoneRows == all)     // a door call with no server has no Full access
        // No is 1 here, never Give's 0; on the door's card Run it once and No keep 0 and 2 around the line
        let giveCard = try need(["give": give, "options": ["Give Dev write", "No"]])
        #expect(giveCard.phoneRows == [.onTheComputer(0), .option(1)] && giveCard.onlyOnAComputer == .give)
        #expect(try need(["give": give, "options": ["Give Dev write", "Not now", "No"]]).phoneRows
                == [.onTheComputer(0), .option(1), .option(2)])
        let teamCard = try need(["team": true, "options": ["Yes: add nova", "Yes: add lia", "No"]])
        #expect(teamCard.phoneRows == [.onTheComputer(0), .option(2)] && teamCard.onlyOnAComputer == .teamYes)
        let doorCard = try need(["door_call": hash, "door_host": "web-1",
                                 "options": ["Run it once", "Full access on web-1", "No"]])
        #expect(doorCard.phoneRows == [.option(0), .onTheComputer(1), .option(2)] && doorCard.onlyOnAComputer == .fullAccess)
        let appCard = try need(["github_app": "acme", "options": ["Make the App", "Not now"]])
        #expect(appCard.phoneRows == [.unavailable(0), .option(1)] && appCard.firstOptionStartsOnTheMac)
        let scanCard = try need(["add_device": 1, "options": ["Scan it again", "Not now"]])
        #expect(scanCard.phoneRows == [.unavailable(0), .option(1)] && scanCard.firstOptionStartsOnTheMac)
        #expect(try need(["github_app": "", "add_device": 0]).phoneRows == all)   // no account, no picture
        let oneOption = try need(["team": true, "options": ["Yes: remove scout"]])       // one option is no choice
        #expect(oneOption.phoneRows.isEmpty && oneOption.onlyOnAComputer == nil)
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

    /// His message under a card (Needs clarification, owner API 1.272) goes only to a hub that takes it again: a hub
    /// with `need_talk` alone has no such route since Discuss left (API 1.158). An outbox that an app before 0.1.205
    /// saved still reads, and the receipt with his message in the item's talk confirms it.
    @Test func aMessageUnderACardGoesToAHubThatTakesItAndItsReceiptConfirmsIt() throws {
        let command = OwnerCommand.needTalk(need: 7)
        #expect(command.route == "ui/needs/7/talk" && command.requiredFeature == NeedClarify.feature)
        #expect(try command.bodyFields(text: "  Why now?  ") as? [String: String] == ["text": "Why now?"])
        #expect(throws: HubError.self) { try command.bodyFields(text: "   ") }
        #expect(throws: HubError.self) { try command.bodyFields(text: String(repeating: "x", count: NeedTalk.most + 1)) }
        // as the hub counts it: 1,001 characters of a letter and its accent are 2,002 code points, which it refuses
        #expect(throws: HubError.self) { try command.bodyFields(text: String(repeating: "e\u{301}", count: NeedTalk.most / 2 + 1)) }
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
