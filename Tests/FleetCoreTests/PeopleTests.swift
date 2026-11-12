import Foundation
import Testing
@testable import FleetCore

// Other people and their conversations (UI-API.md 1.17). The fixtures in `Fixtures/` are the real answers of the
// hub's own code (`test_people.py` driving an in-process hub with a temporary database), not hand-written JSON, so
// a change of the hub's shape fails here rather than in the owner's window.

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func snapshot(_ name: String = "people-full") throws -> PeopleSnapshot {
    try JSONDecoder().decode(PeopleSnapshot.self, from: fixture(name))
}

private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

/// One person as the hub sends them, for the words that no fixture covers.
private func person(_ changes: [String: Any] = [:]) throws -> PeopleSnapshot.Person {
    let object: [String: Any] = ["id": 1, "name": "Laura", "role": "employee", "role_means": "a person who works…",
                                 "note": NSNull(), "daily": 100, "daily_set": NSNull(), "blocked": NSNull(),
                                 "added": 1000.0, "today": 0,
                                 "agents": [["agent": "studio", "can_chat": true, "says": NSNull()]],
                                 "handles": [["app": "whatsapp", "handle": "34600111999@s.whatsapp.net",
                                              "alias": NSNull(), "name": NSNull(), "added": 1000.0]],
                                 "conversations": []]
    return try JSONDecoder().decode(PeopleSnapshot.Person.self, from: json(object.merging(changes) { _, new in new }))
}

struct PeopleSnapshotTests {
    @Test func theHubsOwnAnswerCarriesTheRolesTheirToolsAndEveryPerson() throws {
        let people = try snapshot()
        #expect(people.hasPeople)
        #expect(people.roleList.map(\.role) == ["customer", "employee", "supervisor", "deputy"])
        #expect(people.role("customer")?.daily == 30 && people.role("employee")?.daily == 100)
        // A customer asks for no work: the role's own tools, from the hub.
        #expect(people.role("customer")?.tools == ["read_messages", "reply", "ask_owner"])
        #expect(people.role("supervisor")?.tools.contains("request_work") == true)
        #expect(people.role("employee")?.means.contains("works for the owner") == true)
        // the one role that decides for the owner in its own conversation
        #expect(people.role("deputy")?.means.contains("decides for the owner") == true)
        #expect(people.role("deputy")?.tools.contains("request_work") == true && people.role("deputy")?.daily == 100)
        #expect(people.peopleList.map(\.name) == ["Laura", "Ana Ruiz", "Tom Vega"])
    }

    /// Plan P1: the roles are data the owner writes, so the list is whatever the hub sends — any name, in its order,
    /// and no daily limit for a role of staff. A role of a newer shape takes nothing else of the page with it.
    @Test func theRolesAreTheHubsOwnWithAnyNameAndNoLimitForStaff() throws {
        var object = try #require(try JSONSerialization.jsonObject(with: fixture("people-full")) as? [String: Any])
        object["roles"] = [["role": "customer", "means": "An outsider.", "daily": 30,
                            "tools": ["read_messages", "reply", "ask_team"]],
                           ["role": "peer", "means": "A colleague.", "daily": NSNull(), "tools": true],
                           ["role": "manager", "means": "A colleague above the agent."]]
        let people = try JSONDecoder().decode(PeopleSnapshot.self, from: json(object))
        #expect(people.hasPeople && people.roleList.map(\.role) == ["customer", "peer", "manager"])
        #expect(people.role("customer")?.daily == 30 && people.role("peer")?.daily == nil)
        #expect(people.role("peer")?.tools == [] && people.role("manager")?.means == "A colleague above the agent.")
        #expect(people.peopleList.count == 3)
        // With contacts.v2 on, the hub lists the roles as GET /ui/roles does: a name, the owner's prompt, a switch.
        object["roles"] = [["name": "customer", "prompt": "An outsider.", "tools": false, "daily": 30, "people": 1],
                           ["name": "peer", "prompt": "A colleague.", "tools": true, "daily": NSNull(), "people": 0]]
        let switched = try JSONDecoder().decode(PeopleSnapshot.self, from: json(object))
        #expect(switched.roleList.map(\.role) == ["customer", "peer"] && switched.role("peer")?.means == "A colleague.")
        #expect(switched.role("customer")?.daily == 30 && switched.role("peer")?.daily == nil)
    }

    /// Plan P1: `GET /ui/roles` and the answer to a write of one role (`POST /ui/roles`), in the hub's shape.
    @Test func theRolesOfTheFleetAndTheAnswerToAChange() throws {
        let roles: [[String: Any]] = [
            ["name": "customer", "prompt": "An outsider: a customer.", "tools": false, "daily": 30, "created": 1000.0,
             "updated": 1000.0, "people": 2],
            ["name": "peer", "prompt": "A colleague.", "tools": true, "daily": NSNull(), "created": 1000.0,
             "updated": 1000.0, "people": 0]]
        // The card and its pages show only while the hub lists this, which it does only with contacts.v2 on.
        #expect(RoleList.feature == "contact_roles")
        let list = try JSONDecoder().decode(RoleList.self, from: json(["db": "g1", "roles": roles]))
        try list.validate(database: "g1")
        #expect(list.roles.map(\.word) == ["Customer", "Peer"])
        #expect(list.role("customer")?.tools == false && list.role("customer")?.daily == 30)
        #expect(list.role("peer")?.tools == true && list.role("peer")?.daily == nil && list.role("peer")?.people == 0)
        #expect(throws: HubError.self) { try list.validate(database: "g2") }
        let twice = try JSONDecoder().decode(RoleList.self, from: json(["db": "g1", "roles": roles + [roles[0]]]))
        #expect(throws: HubError.self) { try twice.validate(database: "g1") }

        let id = "0b7d6a52-5d1c-4f5e-9d0e-0b2c1f6e9a11"
        let answer: [String: Any] = ["ok": true, "request_id": id, "client": "this-mac", "replayed": false,
                                     "role": roles[1], "created": false, "changed": ["prompt"]]
        let receipt = try JSONDecoder().decode(RoleReceipt.self, from: json(answer))
        try receipt.validate(requestID: id, client: "this-mac", name: "peer")
        #expect(receipt.role?.prompt == "A colleague." && receipt.changed == ["prompt"])
        #expect(throws: HubError.self) { try receipt.validate(requestID: id, client: "this-mac", name: "customer") }
        #expect(throws: HubError.self) { try receipt.validate(requestID: id, client: "another", name: "peer") }
    }

    /// The owner writes a role's name as he reads it, and the hub keeps it as its key (POST /ui/roles `rename`).
    @Test func aRoleIsRenamedFromWhatTheOwnerTyped() throws {
        #expect(RoleList.name(from: "Peer") == "peer" && RoleList.name(from: "  Partner ") == "partner")
        #expect(RoleList.name(from: "Key account") == "key-account" && RoleList.name(from: "key-account") == "key-account")
        #expect(RoleList.name(from: People.roleWord("key-account")) == "key-account")   // the field as it opens
        for refused in ["", "x", "1st line", "Café", "a_b", String(repeating: "a", count: 32)] {
            #expect(RoleList.name(from: refused) == nil, "\(refused)")
        }
        #expect(RoleList.name(from: String(repeating: "a", count: 31)) != nil)
        // The answer to a rename carries the role under its new name.
        let id = "1c9e2b7a-3f4d-4e5a-8b6c-7d8e9f0a1b2c"
        let renamed = try JSONDecoder().decode(RoleReceipt.self, from: json([
            "ok": true, "request_id": id, "client": "this-mac", "replayed": false, "created": false,
            "changed": ["name"], "role": ["name": "partner", "prompt": "A colleague.", "tools": true, "daily": NSNull(),
                                          "created": 1000.0, "updated": 1001.0, "people": 2]]))
        try renamed.validate(requestID: id, client: "this-mac", name: "partner")
        #expect(throws: HubError.self) { try renamed.validate(requestID: id, client: "this-mac", name: "peer") }
    }

    @Test func aPersonCarriesTheirRoleTheirAgentsTheirHandlesAndTheirConversations() throws {
        let laura = try #require(try snapshot().person(1))
        #expect(laura.roleWord == "Employee" && laura.limit == 100 && laura.daily_set == nil)
        #expect(laura.note == "Laura runs the shop with me.")
        #expect(laura.agentNames == ["studio"] && laura.reachable.count == 1 && !laura.isBlocked)
        #expect(laura.handles.first?.app == "whatsapp")
        #expect(laura.handles.first?.shown == "34600111999")        // the ID without its WhatsApp part
        #expect(laura.conversations.map(\.id) == [1] && laura.apps == ["whatsapp"])
        #expect(laura.sentToday == 1)
    }

    @Test func anAgentThatCannotChatKeepsTheHubsOwnLine() throws {
        let ana = try #require(try snapshot().person(2))
        #expect(ana.agentNames == ["studio", "vps"])
        let vps = try #require(ana.unreachable.first)
        #expect(vps.agent == "vps" && !vps.can_chat)
        #expect(vps.says?.contains("cannot be locked down") == true)
        #expect(ana.reachable.map(\.agent) == ["studio"])
    }

    @Test func theStateLineSaysWhatStopsThemFirst() throws {
        let now = 2000.0
        #expect(try person(["blocked": 1500.0]).state(now: now) == ("Blocked", true))
        #expect(try person(["agents": []]).state(now: now) == ("No agent yet", true))
        #expect(try person(["handles": []]).state(now: now) == ("No handle yet", true))
        let codex = try person(["agents": [["agent": "vps", "can_chat": false, "says": "VPS runs on codex."]]])
        #expect(codex.state(now: now) == ("Vps cannot chat now", true))
        #expect(try person(["today": 100]).state(now: now) == ("Reached today's limit", true))
        #expect(try person().state(now: now) == ("No message yet", false))
        let talking = try person(["conversations": [["id": 1, "agent": "studio", "state": "open", "last": 1940.0]]])
        #expect(talking.state(now: now) == ("Last message 1 min ago", false))
    }

    /// The same fact as one mark, with that line behind it. The owner, 20 October 2026: "not even sentences, just
    /// a check or a cross, and on hover probably show the detail?"
    @Test func thatLineIsOneMarkAndWhatHeChoseHimselfIsNotAFault() throws {
        let now = 2000.0
        // Unfinished or broken: a cross.
        #expect(try person(["agents": []]).mark(now: now) == .bad)
        #expect(try person(["handles": []]).mark(now: now) == .bad)
        let codex = try person(["agents": [["agent": "vps", "can_chat": false, "says": "VPS runs on codex."]]])
        #expect(codex.mark(now: now) == .bad)
        // His own decisions: worth knowing, and not a cross. He blocked them, and he set that limit.
        #expect(try person(["blocked": 1500.0]).mark(now: now) == .warn)
        #expect(try person(["today": 100]).mark(now: now) == .warn)
        // They can talk, whether or not they have yet.
        #expect(try person().mark(now: now) == .good)
        let talking = try person(["conversations": [["id": 1, "agent": "studio", "state": "open", "last": 1940.0]]])
        #expect(talking.mark(now: now) == .good)
    }

    @Test func aPersonOfTheFixtureIsBlockedAndReachesNobody() throws {
        let tom = try #require(try snapshot().person(3))
        #expect(tom.isBlocked && tom.agentNames.isEmpty)
        #expect(tom.state(now: 1_792_316_400).words == "Blocked")
    }

    @Test func theHubWithoutTheseVersionsStillDecodes() throws {
        // `Fixtures/people.json` is round 1: the owner's handles and the dropped senders, with no roles and no people.
        let older = try snapshot("people")
        #expect(!older.hasPeople && older.roleList.isEmpty && older.peopleList.isEmpty)
        #expect(older.owner.handles.count == 2 && older.ignored(of: "whatsapp-main") != nil)
    }
}

struct StrangerTests {
    @Test func whoWroteAndWasNotAnsweredIsNewestFirstWithItsAppAndAgent() throws {
        let waiting = try snapshot().strangers
        #expect(waiting.count == 1)
        let one = try #require(waiting.first)
        #expect(one.app == "whatsapp" && one.agent == "studio")
        #expect(one.message.who == "sam" && one.message.said == "Hello, who is this?")
        #expect(try snapshot().ignoredToday == 1)
    }

    @Test func aSenderWhoIsAlreadyAPersonIsNotAStranger() throws {
        let people = try snapshot()
        let known = try #require(people.person(app: "whatsapp", handle: "34600111999@s.whatsapp.net"))
        #expect(known.name == "Laura")
        // Her own ID never shows as somebody who was dropped: her messages arrive.
        #expect(!people.strangers.contains { $0.message.sender == "34600111999@s.whatsapp.net" })
    }

    @Test func anAccountOfTheWholeFleetHasNoAgent() throws {
        let data = try json(["db": "db", "owner": ["handles": []], "roles": [], "people": [],
                             "ignored": [["account": "whatsapp-main", "today": 2,
                                          "last": [["sender": "34699000000@s.whatsapp.net", "name": NSNull(),
                                                    "preview": "Hello?", "ts": 100.0],
                                                   ["sender": "500600700", "name": "Jordi", "preview": NSNull(),
                                                    "ts": 200.0]]]]])
        let people = try JSONDecoder().decode(PeopleSnapshot.self, from: data)
        #expect(people.strangers.map(\.message.ts) == [200.0, 100.0])       // newest first
        #expect(people.strangers.first?.agent == nil && people.strangers.first?.app == "whatsapp")
        #expect(people.strangers.last?.message.who == "34699000000")        // no name: the ID the app gave
        #expect(people.strangers.first?.message.said == nil)                // a message with no text
    }
}

struct PersonInputTests {
    @Test func theFormRefusesWhatTheHubRefuses() throws {
        var input = PersonInput()
        #expect(input.problem() == "Write the name you know them by.")
        input.name = String(repeating: "a", count: 61)
        #expect(input.problem()?.contains("60 characters") == true)
        input.name = "Ana Ruiz"
        input.role = " "
        #expect(input.problem() == "Choose a role.")
        // Plan P1: the roles are the hub's data, so a role this app has never heard of is taken as it is.
        input.role = "peer"
        #expect(input.problem() == nil)
        input.role = "customer"
        #expect(input.problem() == nil)
        input.agents = (1...17).map { "a\($0)" }
        #expect(input.problem()?.contains("16 agents") == true)
        input.agents = ["studio"]
        input.note = String(repeating: "n", count: 2001)
        #expect(input.problem()?.contains(2000.formatted()) == true)
        input.note = "Ana is my accountant."
        input.daily = 1001
        #expect(input.problem()?.contains("0 to \(1000.formatted())") == true)
        input.daily = 30
        #expect(input.problem(existing: People.peopleMax)?.contains("200 people") == true)
        #expect(input.problem(existing: People.peopleMax, adding: false) == nil)   // a change is not a new person
    }

    /// A person whose role this app does not know keeps it: a change of their name sends their name and nothing
    /// else. The app used to refuse every change of such a person with "Choose a role."
    @Test func aPersonWithARoleOfTheHubsOwnCanBeChanged() throws {
        let bruno = try person(["name": "Bruno", "role": "peer"])
        var input = PersonInput(bruno)
        input.name = "Bruno M."
        #expect(input.problem(adding: false) == nil)
        #expect(input.changeFields(from: bruno).keys.sorted() == ["name"])
    }

    @Test func theOwnerWritesAPhoneNumberAndTheAppMakesTheWhatsAppId() {
        var handle = PersonInput.HandleInput()
        #expect(handle.problem == "Write their phone number, with the country code.")
        handle.typed = "+34 600 111 999"
        #expect(handle.problem == nil && handle.handle == "34600111999@s.whatsapp.net")
        handle.typed = "0034600111999"                     // the other way of writing the country code
        #expect(handle.handle == "34600111999@s.whatsapp.net")
        handle.typed = "600111"
        #expect(handle.handle == "600111@s.whatsapp.net")   // six digits is the shortest number there is
        handle.typed = "60011"
        #expect(handle.problem?.contains("6 to 15 digits") == true)
        handle.typed = "ana ruiz"
        #expect(handle.problem?.contains("no letters") == true)
        // an ID the owner pasted whole, and a hidden ID, are taken as they are: they are no phone number
        handle.typed = "34600111999@s.whatsapp.net"
        #expect(handle.problem == nil && handle.handle == "34600111999@s.whatsapp.net")
        handle.typed = "209876543210987@lid"
        #expect(handle.problem == nil && handle.handle == "209876543210987@lid")
        handle.app = "signal"
        #expect(handle.problem == "Choose WhatsApp or Discord.")
    }

    @Test func aDiscordHandleIsTheUserIdThatDiscordCopies() {
        var handle = PersonInput.HandleInput(app: "discord")
        #expect(handle.problem == "Write their Discord user ID.")
        handle.typed = " 500600700 "
        #expect(handle.problem == nil && handle.handle == "500600700")
        handle.typed = "100"
        #expect(handle.problem?.contains("5 to 25 digits") == true)
        handle.typed = "Jordi#1234"
        #expect(handle.problem?.contains("5 to 25 digits") == true)
        handle.typed = String(repeating: "1", count: 201)
        #expect(handle.problem?.contains("200 characters") == true)
    }

    @Test func aHandleTheHubAlreadyHoldsIsNeverRewritten() {
        // Removing one sends the ID back exactly as the hub gave it, whatever shape it has.
        let odd = PersonInput.HandleInput.exact(app: "whatsapp", handle: "34600111999")
        #expect(odd.handle == "34600111999" && odd.problem == nil)
        #expect(PersonInput.HandleInput.exact(app: "discord", handle: "500600700").handle == "500600700")
    }

    @Test func aNewPersonCarriesEveryPlaceTheyWriteFromAndTheirAgentsSorted() throws {
        var input = PersonInput()
        input.name = "  Ana Ruiz\n"
        input.role = "customer"
        input.agents = ["studio", "mini"]
        // the same person writes from Discord and from WhatsApp, and the hub takes both in the one command
        input.handles = [.init(app: "discord", handle: " 500600700 ", name: "Jordi"),
                         .init(app: "whatsapp", handle: "+34 600 111 999")]
        #expect(input.problem() == nil)
        let fields = input.addFields
        #expect(fields["name"] as? String == "Ana Ruiz")
        #expect(fields["agents"] as? [String] == ["mini", "studio"])
        #expect(fields["note"] is NSNull && fields["daily"] is NSNull)
        let handles = try #require(fields["handles"] as? [[String: Any]])
        #expect(handles.map { $0["handle"] as? String } == ["500600700", "34600111999@s.whatsapp.net"])
        #expect(handles.first?["name"] as? String == "Jordi")
        #expect(handles.last?["name"] == nil)
    }

    @Test func theFormRefusesTwoOfTheSamePlaceAndMoreThanTheHubTakes() {
        var input = PersonInput()
        input.name = "Ana Ruiz"
        input.handles = [.init(app: "whatsapp", handle: "+34 600 111 999"),
                         .init(app: "whatsapp", handle: "34600111999")]
        #expect(input.problem() == "The same handle is in the list two times.")
        input.handles = [.init(app: "whatsapp", handle: "+34 600 111 999"), .init(app: "discord", handle: "abc")]
        #expect(input.problem()?.contains("Discord user ID") == true)
        input.handles = (1...9).map { .init(app: "discord", handle: "50060070\($0)") }
        #expect(input.problem()?.contains("8 handles") == true)
        input.handles = []
        #expect(input.problem() == nil)             // a person with no place yet is one the hub takes
    }

    @Test func aChangeSendsOnlyWhatIsDifferent() throws {
        let laura = try #require(try snapshot().person(1))
        var input = PersonInput(laura)
        #expect(input.changeFields(from: laura).isEmpty)        // nothing to change writes nothing
        input.role = "customer"
        input.daily = 5
        let fields = input.changeFields(from: laura)
        #expect(Set(fields.keys) == ["role", "daily"])
        #expect(fields["role"] as? String == "customer" && fields["daily"] as? Int == 5)
        input = PersonInput(laura)
        input.note = ""
        #expect(input.changeFields(from: laura)["note"] is NSNull)      // an empty note clears it
        input = PersonInput(laura)
        input.agents = ["studio"]
        #expect(input.changeFields(from: laura).isEmpty)                // the same agents in another order
    }

    @Test func aPersonOfTheHubFillsTheForm() throws {
        let ana = try #require(try snapshot().person(2))
        let input = PersonInput(ana)
        #expect(input.name == "Ana Ruiz" && input.role == "customer" && input.note == "Ana is my accountant.")
        #expect(input.agents == ["studio", "vps"] && input.daily == nil)
    }
}

struct PersonReceiptTests {
    @Test func theAnswerToAnAddCarriesThePersonAsTheHubHasThem() throws {
        let receipt = try JSONDecoder().decode(PersonReceipt.self, from: fixture("person-added"))
        #expect(receipt.ok && receipt.replayed == false)
        #expect(receipt.full?.id == 4 && receipt.full?.name == "Rafa Soto" && receipt.full?.role == "supervisor")
        #expect(receipt.deleted == nil && receipt.changed == nil)
    }

    @Test func theAnswerToAChangeSaysWhatChanged() throws {
        let receipt = try JSONDecoder().decode(PersonReceipt.self, from: fixture("person-changed"))
        #expect(receipt.changed == ["daily", "role"])
        #expect(receipt.full?.role == "employee" && receipt.full?.daily_set == 25 && receipt.full?.daily == 25)
    }

    @Test func theAnswerToARemovalKeepsOnlyTheNumberAndTheNameAndSaysWhatWentWithIt() throws {
        let receipt = try JSONDecoder().decode(PersonReceipt.self, from: fixture("person-removed"))
        #expect(receipt.deleted == true && receipt.conversations == 0)
        #expect(receipt.person?.id == 4 && receipt.person?.name == "Rafa Soto")
        #expect(receipt.full == nil)        // a removal gives no whole person
    }

    @Test func aReceiptOfAnotherRequestOrAnotherClientIsRefused() throws {
        let receipt = try JSONDecoder().decode(PersonReceipt.self, from: fixture("person-added"))
        #expect(throws: HubError.self) { try receipt.validate(requestID: UUID().uuidString, client: receipt.client) }
        #expect(throws: HubError.self) { try receipt.validate(requestID: receipt.request_id, client: "another-app") }
        #expect(throws: Never.self) { try receipt.validate(requestID: receipt.request_id, client: receipt.client) }
    }
}

struct ConversationListTests {
    @Test func theListIsNewestFirstWithTheLastThingSaid() throws {
        let list = try JSONDecoder().decode(ConversationList.self, from: fixture("conversations"))
        #expect(list.conversations.map(\.id) == [2, 1])
        let ana = try #require(list.conversations.first)
        #expect(ana.person?.name == "Ana Ruiz" && ana.person?.roleWord == "Customer" && ana.agent == "studio")
        #expect(ana.app == "discord" && ana.waitingCount == 1 && ana.openNeeds == 0)
        #expect(ana.line == "Ana Ruiz: Is the invoice of October ready?")
        let laura = try #require(list.conversations.last)
        #expect(laura.app == "whatsapp" && laura.messages == 4)
        #expect(laura.line == "You: Yes, at 17:00.")      // the owner's own answer, in the owner's words
    }

    @Test func theStateLineSaysWhatNeedsTheOwnerFirst() throws {
        let data = try json(["db": "db", "conversations": [
            ["id": 1, "agent": "studio", "person": ["id": 1, "name": "Laura", "role": "employee"],
             "account": "whatsapp-studio", "state": "open", "created": 1.0, "last": 2.0, "messages": 3,
             "waiting": 2, "open_needs": 1, "newest": NSNull()]]])
        var list = try JSONDecoder().decode(ConversationList.self, from: data)
        var one = try #require(list.conversations.first)
        #expect(one.state(now: 10) ?? ("", false) == ("Waits for you", true))
        #expect(one.line == nil)        // no newest message: the row shows no line
        list = try JSONDecoder().decode(ConversationList.self, from: try json(["db": "db", "conversations": [
            ["id": 1, "agent": "studio", "person": NSNull(), "account": NSNull(), "state": "paused", "created": 1.0,
             "last": 2.0, "messages": 3, "waiting": 2, "open_needs": 0, "newest": NSNull()]]]))
        one = try #require(list.conversations.first)
        #expect(one.isPaused && (one.state(now: 10) ?? ("", false)) == ("Paused", true))
        #expect(one.app == nil)         // no account: no chat app mark
        list = try JSONDecoder().decode(ConversationList.self, from: try json(["db": "db", "conversations": [
            ["id": 1, "agent": "studio", "person": NSNull(), "account": "whatsapp-studio", "state": "open",
             "created": 1.0, "last": 2.0, "messages": 3, "waiting": 2, "open_needs": 0, "newest": NSNull()]]]))
        #expect((list.conversations.first?.state(now: 10) ?? ("", true)) == ("2 not read yet", false))
    }

    /// The same fact as one mark. Only what waits for him is a cross; a conversation he paused and messages an
    /// agent has not read are worth knowing, and an open conversation with nothing to say is a tick.
    @Test func thatLineIsOneMarkAndOnlyWhatWaitsForHimIsACross() throws {
        func one(_ changes: [String: Any]) throws -> Conversation {
            let row: [String: Any] = ["id": 1, "agent": "studio", "person": NSNull(), "account": "whatsapp-studio",
                                      "state": "open", "created": 1.0, "last": 2.0, "messages": 3, "waiting": 0,
                                      "open_needs": 0, "newest": NSNull()]
            let list = try JSONDecoder().decode(ConversationList.self, from: try json(
                ["db": "db", "conversations": [row.merging(changes) { _, new in new }]]))
            return try #require(list.conversations.first)
        }
        #expect(try one(["open_needs": 1]).mark(now: 10) == .bad)
        #expect(try one(["state": "paused"]).mark(now: 10) == .warn)
        #expect(try one(["waiting": 2]).mark(now: 10) == .warn)
        // Nothing to say about it is what a tick is for: `state` gives no line there at all.
        let quiet = try one([:])
        #expect(quiet.state(now: 10) == nil && quiet.mark(now: 10) == .good)
    }

    @Test func aListOfAnotherGenerationIsRefused() throws {
        let list = try JSONDecoder().decode(ConversationList.self, from: fixture("conversations"))
        #expect(throws: HubError.self) { try list.validate(database: "another") }
        #expect(throws: Never.self) { try list.validate(database: "test-generation") }
    }
}

struct ConversationRecordTests {
    private func record() throws -> ConversationRecord {
        try JSONDecoder().decode(ConversationRecord.self, from: fixture("conversation"))
    }

    @Test func theRecordCarriesTheHeadAndTheWholeConversation() throws {
        let record = try record()
        #expect(record.head.id == 1 && record.head.agent == "studio" && record.head.person?.name == "Laura")
        #expect(record.head.app == "whatsapp" && !record.head.isPaused)
        #expect(record.items.map(\.id) == ["CM-1", "CM-2", "CM-3", "CM-4"])
        #expect(record.items.map(\.who) == ["person", "agent", "action", "owner"])
        #expect(record.lastNumber == 4)
        #expect(throws: Never.self) { try record.validate(database: "test-generation", conversation: 1) }
        #expect(throws: HubError.self) { try record.validate(database: "test-generation", conversation: 2) }
    }

    @Test func eachLineSaysWhoSaidItInTheOwnersWords() throws {
        let items = try record().items
        #expect(items[0].said(person: "Laura", agent: "studio") == "Laura")
        #expect(items[1].said(person: "Laura", agent: "studio") == "Studio")
        #expect(items[3].said(person: "Laura", agent: "studio") == "You")
        #expect(items[0].text == "Can you ask Sam to call me today?")
        #expect(items[0].read_at != nil)            // the agent read it
        #expect(items[1].in_reply_to == "CM-1" && items[1].number == 2)
    }

    @Test func whatTheAgentDidCarriesTheQuestionAndItsAnswer() throws {
        let action = try #require(try record().items.first { $0.isAction })
        #expect(action.text == "Asked the owner: Can you call Laura today?")
        let need = try #require(action.need)
        #expect(need.kind == "question" && need.title == "Studio asks you, for Laura (employee)")
        #expect(need.answer == "Yes, at 17:00." && !need.isOpen)
        #expect((action.actionState ?? ("", true)) == ("You answered", false))
    }

    @Test func aQuestionThatNobodyAnsweredWaitsForTheOwner() throws {
        let data = try json(["id": "CM-3", "who": "action", "text": "Asked the owner: Can you call her?",
                             "created": 10.0, "read_at": NSNull(), "in_reply_to": NSNull(),
                             "need": ["id": 7, "kind": "question", "title": "Studio asks you",
                                      "answer": NSNull(), "answered": NSNull()], "delivery": NSNull()])
        let item = try JSONDecoder().decode(ConversationItem.self, from: data)
        #expect(item.need?.isOpen == true)
        #expect((item.actionState ?? ("", false)) == ("Waits for you", true))
        #expect(item.said(person: nil, agent: "studio") == "Studio")
    }

    @Test func theDeliveryOfAReplyIsTheChatAppsOwnState() throws {
        let reply = try #require(try record().items.first { $0.who == "agent" })
        let delivery = try #require(reply.delivery)
        #expect(delivery.state == "read" && delivery.outbound == 4)
        #expect(!delivery.isProblem && !delivery.canSendAgain)
        #expect(delivery.words(app: "whatsapp", time: { _ in "14:03" }) == "Sent to WhatsApp · Read 14:03")
    }

    @Test func aDeliveryThatFailedOrIsNotConfirmedCanBeSentAgain() throws {
        func delivery(_ state: String, outbound: Any = 41, error: Any = NSNull()) throws -> ConversationItem.Delivery {
            try JSONDecoder().decode(ConversationItem.Delivery.self,
                                     from: json(["outbound": outbound, "state": state, "at": 10.0, "error": error]))
        }
        #expect(try delivery("unknown").canSendAgain)
        #expect(try delivery("failed", error: "number not on WhatsApp")
            .words(app: "whatsapp", time: { _ in "" }) == "Not sent: number not on WhatsApp.")
        #expect(try !delivery("failed", outbound: NSNull()).canSendAgain)    // nothing to send again
        #expect(try delivery("queued").words(app: nil, time: { _ in "" }) == "Waiting to send to the chat app")
        #expect(try delivery("expired").isProblem)
        #expect(try delivery("something-new").words(app: "discord", time: { _ in "" }) == "Discord delivery: something-new")
    }

    @Test func theAnswerToAPauseCarriesTheConversation() throws {
        let receipt = try JSONDecoder().decode(ConversationReceipt.self, from: fixture("conversation-paused"))
        #expect(receipt.ok && receipt.conversation?.isPaused == true && receipt.conversation?.id == 1)
        #expect(throws: HubError.self) { try receipt.validate(requestID: "other", client: receipt.client) }
    }
}

struct PeopleWordsTests {
    @Test func theWordsOfAPageAreShortAndTrue() {
        #expect(People.roleWord("customer") == "Customer" && People.roleWord("supervisor") == "Supervisor")
        #expect(People.roleWord("deputy") == "Deputy" && People.roleWord("peer") == "Peer")
        #expect(People.handleAsk("whatsapp") == "Their phone number" && People.handleAsk("discord").contains("Discord"))
        #expect(People.whatsappID(from: "+34 600 111 999") == "34600111999@s.whatsapp.net")
        #expect(People.whatsappID(from: "12345") == nil && People.whatsappID(from: "") == nil)
        #expect(People.roleWord("something-new") == "Something-new")     // an unknown role shows as its own text
        #expect(People.agentWords([]) == "No agent")
        #expect(People.agentWords(["studio"]) == "Studio")
        #expect(People.agentWords(["studio", "mini"]) == "Studio and Mini")
        #expect(People.agentWords(["studio", "mini", "vps"]) == "Studio, Mini and Vps")
        #expect(People.oneLine("  two\nlines  ") == "two lines")
    }

    @Test func anAgentThatCannotHoldAConversationSaysWhyBeforeTheOwnerPicksIt() {
        #expect(People.cannotChat(role: "manager", runtime: "claude", active: true)?.contains("manager") == true)
        #expect(People.cannotChat(role: "worker", runtime: "claude", active: false)?.contains("setup") == true)
        // The provider's own name, capitalised (fix round 3, item 37).
        #expect(People.cannotChat(role: "worker", runtime: "codex", active: true)?.contains("A session of Codex ") == true)
        #expect(People.cannotChat(role: "worker", runtime: "claude", active: true) == nil)
        #expect(People.cannotChat(role: "lead", runtime: "claude", active: nil) == nil)
    }

    @Test func aRefusalOfTheHubIsGivenInTheHubsOwnWords() {
        #expect(People.reason(HubError.refusal(409, "this fleet already has 200 people"))
                == "The hub said: this fleet already has 200 people.")
        #expect(People.reason(URLError(.timedOut)).contains("can still have done it"))
    }
}
