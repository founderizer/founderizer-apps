import Foundation
import Testing
@testable import FleetCore

/// The options of a Needs-you item (UI-API 1.18): an agent offers the answers with its question, the owner presses
/// one, and the hub writes that option's own words as the answer. An item that offers none behaves as before.
struct NeedOptionsTests {
    private func need(_ fields: String) throws -> OwnerNeed {
        try JSONDecoder().decode(OwnerNeed.self, from: Data("""
        {"id": 7, "title": "Which label?", "why": "w", "todo": "t", "raised": 1, "by": "manager",
         "answer": null, "answered": null, \(fields)}
        """.utf8))
    }

    @Test func anItemCarriesTheAnswersItsAgentOffered() throws {
        let offered = try need("""
        "options": ["Ship it", "Hold for now", "Ask me again Monday"], "chosen": null
        """)
        #expect(offered.choices == ["Ship it", "Hold for now", "Ask me again Monday"])
        // A hub without the feature, and a question that is not a choice: the app's own quick replies stay.
        #expect(try need("\"options\": null, \"chosen\": null").choices.isEmpty)
        #expect(try need("\"options\": [], \"chosen\": null").choices.isEmpty)
    }

    @Test func whatIsNotOneAnswerToPressIsNotDrawn() throws {
        // One option is not a choice; a label that is empty, one with a control character in it, and two that say
        // the same thing are not two answers either. These the app refuses, because it cannot draw them.
        for bad in ["[\"Only one\"]", "[\"ok\", \"  \"]", "[\"ok\", \"two\\nlines\"]",
                    "[\"Ship it\", \"SHIP IT\"]"] {
            #expect(try need("\"options\": \(bad), \"chosen\": null").choices.isEmpty, "\(bad) was drawn")
        }
    }

    /// How many answers an agent may offer, and how long each may be, is the hub's to decide: it refuses what is
    /// too long and raises nothing. So the app draws what it was sent, whole. A limit of its own would quietly
    /// drop an answer that the hub accepted the day that limit moves.
    @Test func theHubOwnsHowManyAndHowLongAndTheAppDrawsWhatCame() throws {
        let sentence = "Move the export to vps tonight and leave mini alone until it answers for itself"
        let long = try need("""
        "options": ["\(sentence)", "Wait for mini", "Stop the task", "Ask me again tomorrow",
                    "Move it and tell the customer", "Leave it"], "chosen": null
        """)
        #expect(long.choices.count == 6)
        #expect(long.choices.first == sentence)      // a sentence, not a badge label, and nothing is cut here
        #expect(sentence.count > 32)                 // over the limit the hub keeps today
    }

    @Test func aPressSendsTheIndexAndNoTextBesideIt() throws {
        let hub = URL(string: "http://100.84.1.2:8765")!
        let press = PendingRequest(hub: hub, database: "db", client: "c", needID: 7, choice: 1, text: "Hold for now")
        let body = try JSONSerialization.jsonObject(with: press.body()) as? [String: Any] ?? [:]
        #expect(press.route == "ui/needs/7")
        #expect(body["choice"] as? Int == 1)
        // `choice` and `answer` are exclusive: the option's words are kept here to show, and are not sent.
        #expect(body["answer"] == nil)
        #expect(press.text == "Hold for now")
        // A typed answer is unchanged.
        let typed = PendingRequest(hub: hub, database: "db", client: "c", needID: 7, text: "Monday")
        let text = try JSONSerialization.jsonObject(with: typed.body()) as? [String: Any] ?? [:]
        #expect(text["answer"] as? String == "Monday" && text["choice"] == nil)
        // A choice without a need is no choice at all: a chat message never carries one.
        let message = PendingRequest(hub: hub, database: "db", client: "c", choice: 2, recipient: "manager", text: "hi")
        #expect(message.choice == nil)
        #expect(try (JSONSerialization.jsonObject(with: message.body()) as? [String: Any])?["choice"] == nil)
    }

    @Test func theIndexOfTheOneHePressedComesBack() throws {
        let answered = try JSONDecoder().decode(OwnerNeed.self, from: Data("""
        {"id": 7, "title": "Which label?", "why": "w", "todo": "t", "raised": 1, "by": "manager",
         "answer": "Hold for now", "answered": 2, "options": ["Ship it", "Hold for now"], "chosen": 1}
        """.utf8))
        #expect(answered.chosen == 1 && answered.answer == "Hold for now" && !answered.isOpen)
    }

    /// An agent that asks the owner from inside a conversation with another person (UI-API 1.17) raises an ordinary
    /// Needs-you item with two more fields. The owner's answer goes back into that conversation, and the window a
    /// person talks to can open no file, so the hub refuses one: the request offers none in the first place.
    @Test func aRequestFromSomebodysConversationCarriesNoFile() throws {
        let asked = try need("""
        "options": null, "chosen": null, "kind": "question", "conversation": 12
        """)
        #expect(asked.kind == "question" && asked.conversation == 12)
        #expect(!asked.takesFiles)
        // Every other item is unchanged, on a hub with the feature and on one without it.
        let plain = try need("\"options\": null, \"chosen\": null, \"kind\": null, \"conversation\": null")
        #expect(plain.kind == nil && plain.conversation == nil && plain.takesFiles)
        #expect(try need("\"options\": null, \"chosen\": null").takesFiles)
    }
}

struct NotificationTests {
    @Test func managerWarningsUsePersistentEpisodesRatherThanChangingText() throws {
        func warning(_ kind: String, _ since: Double) throws -> ManagerWarning {
            try JSONDecoder().decode(ManagerWarning.self, from: JSONSerialization.data(withJSONObject: ["kind": kind, "since": since]))
        }
        // Existing saved Needs-you ledgers remain readable when warnings are first added.
        var ledger = try JSONDecoder().decode(NotificationLedger.self, from: Data("{\"seen\":{\"hub\":4}}".utf8))
        #expect(ledger.observeWarning(context: "hub", warning: nil) == nil)
        let first = try warning("down", 1000)
        #expect(ledger.observeWarning(context: "hub", warning: first) == first.episode)
        ledger = try JSONDecoder().decode(NotificationLedger.self, from: JSONEncoder().encode(ledger))
        #expect(ledger.observeWarning(context: "hub", warning: first) == nil)
        #expect(ledger.observeWarning(context: "hub", warning: nil) == nil)
        #expect(ledger.observeWarning(context: "hub", warning: first) == nil)
        let next = try warning("down", 2000)
        #expect(ledger.observeWarning(context: "hub", warning: next) == next.episode)
        #expect(ledger.observeWarning(context: "new-generation", warning: first) == nil)
        #expect(try warning("down", -1).episode == nil)
    }

    @Test func onlyNewManagerRequestsNotifyAcrossRelaunch() throws {
        func need(_ id: Int, by: String = "manager", closed: Bool = false) throws -> OwnerNeed {
            try JSONDecoder().decode(OwnerNeed.self, from: JSONSerialization.data(withJSONObject: ["id": id, "by": by, "title": "Synthetic", "why": "", "todo": "", "raised": 1, "answered": closed ? 2 : NSNull()]))
        }
        var ledger = NotificationLedger()
        #expect(ledger.observe(context: "hub-a/generation-a", needs: [try need(1)]).isEmpty)
        #expect(ledger.observe(context: "hub-a/generation-a", needs: [try need(1), try need(2)] ) == [2])
        ledger = try JSONDecoder().decode(NotificationLedger.self, from: JSONEncoder().encode(ledger))
        #expect(ledger.observe(context: "hub-a/generation-a", needs: [try need(1), try need(2)]).isEmpty)
        #expect(ledger.observe(context: "hub-a/generation-a", needs: [try need(3, closed: true), try need(4, by: "vps")]).isEmpty)
        #expect(ledger.observe(context: "hub-a/generation-b", needs: [try need(1)]).isEmpty)
        #expect(ledger.observe(context: "hub-a/generation-b", needs: [try need(2)]) == [2])
    }
}
