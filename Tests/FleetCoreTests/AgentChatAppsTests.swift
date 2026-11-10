import Foundation
import Testing
@testable import FleetCore

// Chat apps round 2: an agent's own number or bot, messages that an agent writes first, and messages between agents.

private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

private func reports(_ fields: [String: Any]) throws -> HubState {
    var report: [String: Any] = ["id": 4, "agent": "studio", "in_reply_to": NSNull(), "text": "The scrape finished.", "about": "",
                                 "created": 995.0]
    report.merge(fields) { _, new in new }
    return try HubState.decode(json(["schema_version": 1, "db": "db", "time": 1000.0,
                                     "agents": [["name": "studio", "role": "worker", "runtime": "claude", "can": []]],
                                     "tasks": [], "notes": [], "needs": [], "permissions": [], "messages": [], "reports": [report]]))
}

private func account(_ id: String, _ app: String, agents: [String], state: Any = "connected") -> [String: Any] {
    ["id": id, "app": app, "label": id, "agents": agents, "state": state]
}

private func page(_ messages: [[String: Any]], db: String = "db") throws -> AgentMessagesPage {
    try JSONDecoder().decode(AgentMessagesPage.self, from: json(["db": db, "messages": messages]))
}

private func message(_ id: Any, sender: String = "studio", recipient: String = "vps", inReplyTo: Any = NSNull()) -> [String: Any] {
    ["id": id, "sender": sender, "recipient": recipient, "text": "Is the VPS free tonight?", "in_reply_to": inReplyTo,
     "created": 990.0, "read_at": NSNull()]
}

private let token = "MTIzNDU2Nzg5MDEyMzQ1Njc4OQ.GaBcDe.abcdefghijklmnopqrstuvwxyz_0123-45"

struct PushedReportTests {
    @Test func aReportThatTheAgentWroteFirstIsPushed() throws {
        #expect(try reports(["pushed": 1]).reports[0].isPushed)
        #expect(try reports(["pushed": true]).reports[0].isPushed)
        #expect(try !reports(["pushed": 0]).reports[0].isPushed)
        #expect(try !reports(["pushed": false]).reports[0].isPushed)
        // An older hub gives no field, or null.
        #expect(try !reports([:]).reports[0].isPushed && reports([:]).reports[0].pushed == nil)
        #expect(try !reports(["pushed": NSNull()]).reports[0].isPushed)
        // With its delivery line, as a reply to a chat-app message has it.
        let sent = try reports(["pushed": 1, "delivery": ["app": "whatsapp", "account": "whatsapp-studio", "state": "delivered",
                                                         "at": 996.0, "error": NSNull(), "outbound": 52]])
        #expect(sent.reports[0].delivery?.state == "delivered" && sent.reports[0].isPushed)
        #expect(throws: (any Error).self) { try reports(["pushed": "yes"]) }
    }
}

struct AgentAccountTests {
    @Test func anAgentsOwnAccountIsNamedAfterTheAgent() {
        let first = ChatApps.agentAccount(app: "whatsapp", agent: "studio", taken: ["whatsapp-main", "discord-studio"])
        #expect(first.id == "whatsapp-studio")
        #expect(first.account == ChatAccountInput(app: "whatsapp", label: "Studio", agents: ["studio"]))
        let second = ChatApps.agentAccount(app: "whatsapp", agent: "studio", taken: ["whatsapp-studio"])
        #expect(second.id == "whatsapp-studio-2" && second.account.label == "Studio 2")
        let third = ChatApps.agentAccount(app: "whatsapp", agent: "studio", taken: ["whatsapp-studio", "whatsapp-studio-2"])
        #expect(third.id == "whatsapp-studio-3" && third.account.label == "Studio 3")
        let bot = ChatApps.agentAccount(app: "discord", agent: "vps", taken: ["whatsapp-vps"])
        #expect(bot.id == "discord-vps" && bot.account.label == "Vps" && bot.account.agents == ["vps"])
        // Only that agent: no default, and the unknown rule of this round.
        #expect(Set(first.account.fields.keys) == ["app", "label", "agents", "unknown"])
        #expect(first.account.fields["agents"] as? [String] == ["studio"] && first.account.fields["unknown"] as? String == "ignore")
        let long = ChatApps.agentAccount(app: "whatsapp", agent: String(repeating: "a", count: 60), taken: [])
        #expect(ChatApps.isAccountID(long.id) && ChatApps.label(long.account.label) != nil)
    }

    @Test func aCardShowsTheAgentsOwnAccountOnly() throws {
        let list = try JSONDecoder().decode(ChatAppsSnapshot.self, from: json(["db": "db", "paused": false, "bridge_seen": 995.0, "accounts": [
            account("whatsapp-main", "whatsapp", agents: ["manager", "studio"]),
            account("whatsapp-studio", "whatsapp", agents: ["studio"], state: "logged_out"),
            account("whatsapp-vps", "whatsapp", agents: ["vps"]),
            account("discord-studio", "discord", agents: ["studio"], state: NSNull())]]))
        // A shared number of an older team.json shows on no card, also not on its default agent's.
        #expect(list.channel("whatsapp", of: "studio")?.id == "whatsapp-studio")
        #expect(list.channel("whatsapp", of: "manager") == nil)
        #expect(list.channel("discord", of: "studio")?.id == "discord-studio")
        #expect(list.channel("discord", of: "vps") == nil && list.channel("whatsapp", of: "vps")?.id == "whatsapp-vps")
        // Of two own numbers, the connected one.
        let two = try JSONDecoder().decode(ChatAppsSnapshot.self, from: json(["db": "db", "paused": false, "bridge_seen": 995.0, "accounts": [
            account("whatsapp-studio", "whatsapp", agents: ["studio"], state: "logged_out"),
            account("whatsapp-studio-2", "whatsapp", agents: ["studio"])]]))
        #expect(two.channel("whatsapp", of: "studio")?.id == "whatsapp-studio-2")
    }

    @Test func theOwnerCodeGoesToTheAgentsOwnAccountFirst() throws {
        let code = try JSONDecoder().decode(LinkCode.self, from: json([
            "ok": true, "request_id": "r", "client": "c", "code": "K7P2-QX9M", "expires": 1600.0,
            "targets": [["account": "whatsapp-main", "label": "Fleet", "url": "https://wa.me/34900123210?text=link%20K7P2-QX9M"],
                        ["account": "whatsapp-studio", "label": "Studio", "url": "https://wa.me/34900555111?text=link%20K7P2-QX9M"],
                        ["account": "whatsapp-vps", "label": "VPS", "url": NSNull()]]]))
        #expect(code.target(preferring: ["whatsapp-studio", "whatsapp-main"])?.account == "whatsapp-studio")
        // An account without a link yet gives way to one that has a link.
        #expect(code.target(preferring: ["whatsapp-vps"])?.account == "whatsapp-main")
        #expect(code.target(preferring: [])?.account == "whatsapp-main")
        let none = try JSONDecoder().decode(LinkCode.self, from: json([
            "ok": true, "request_id": "r", "client": "c", "code": "K7P2-QX9M", "expires": 1600.0,
            "targets": [["account": "whatsapp-vps", "label": "VPS", "url": NSNull()]]]))
        #expect(none.target(preferring: ["whatsapp-vps"])?.account == "whatsapp-vps" && none.target(preferring: [])?.link == nil)
    }
}

struct BotTokenTests {
    @Test func aTokenHasTheHubsFormAndHidesItsValue() throws {
        let pasted = try #require(BotToken(pasted: "  \(token)\n"))
        #expect(pasted.value == token)
        #expect(BotToken(pasted: String(repeating: "a", count: 49)) == nil)
        #expect(BotToken(pasted: String(repeating: "a", count: 50)) != nil && BotToken(pasted: String(repeating: "a", count: 100)) != nil)
        #expect(BotToken(pasted: String(repeating: "a", count: 101)) == nil)
        #expect(BotToken(pasted: String(repeating: "a", count: 60) + " b") == nil)
        #expect(BotToken(pasted: String(repeating: "a", count: 60) + "/") == nil)
        #expect(BotToken(pasted: String(repeating: "é", count: 60)) == nil)
        #expect(BotToken(pasted: "") == nil)
        // No print, interpolation or dump shows the value.
        var dumped = ""
        dump(pasted, to: &dumped)
        for text in [String(describing: pasted), "\(pasted)", String(reflecting: pasted), dumped] {
            #expect(!text.contains(token) && !text.contains("MTIz"), "\(text)")
        }
        let command = ChatAppsClient.Command.token(account: "discord-studio", token: pasted)
        var dumpedCommand = ""
        dump(command, to: &dumpedCommand)
        #expect(!String(describing: command).contains(token) && !dumpedCommand.contains(token))
    }

    @Test func theTokenCommandSendsTheTokenOnceOrRemovesTheFile() throws {
        let send = ChatAppsClient.Command.token(account: "discord-studio", token: BotToken(pasted: token))
        #expect(send.route == "ui/chat-apps/discord-studio/token")
        let body = try #require(try JSONSerialization.jsonObject(with: send.body(requestID: "11111111-2222-4333-8444-555555555555", database: "db")) as? [String: Any])
        #expect(Set(body.keys) == ["request_id", "db", "token"] && body["token"] as? String == token)
        let remove = ChatAppsClient.Command.token(account: "discord-studio", token: nil)
        let removed = try #require(try JSONSerialization.jsonObject(with: remove.body(requestID: "11111111-2222-4333-8444-555555555555", database: "db")) as? [String: Any])
        #expect(Set(removed.keys) == ["request_id", "db", "delete"] && removed["delete"] as? Bool == true)
        #expect(ChatAppsClient.Command.token(account: "../ui/state", token: nil).route == nil)
        let receipt = try JSONDecoder().decode(TokenReceipt.self, from: json(["ok": true, "request_id": "r", "client": "c", "replayed": false,
                                                                              "id": "discord-studio", "set": true, "replaced": false]))
        #expect(receipt.set == true && receipt.replaced == false && receipt.id == "discord-studio")
    }
}

struct AgentMessagesTests {
    @Test func aMessageHasItsNumberWithOrWithoutTheAMPrefix() throws {
        let list = try page([message("AM-12"), message(13, sender: "vps", recipient: "studio", inReplyTo: "AM-12"),
                             ["id": "14", "sender": "studio", "recipient": "manager", "text": "Done.", "created": 999.0, "read_at": 999.5]])
        try list.validate(database: "db", agent: "studio", after: 11)
        #expect(list.messages.map(\.id) == [12, 13, 14] && list.messages.map(\.label) == ["AM-12", "AM-13", "AM-14"])
        #expect(list.messages[0].inReplyTo == nil && list.messages[1].inReplyTo == 12 && list.messages[2].inReplyTo == nil)
        #expect(list.messages[0].read_at == nil && list.messages[2].read_at == 999.5)
        #expect(list.messages[1].sender == "vps" && list.messages[1].recipient == "studio")
        #expect(throws: (any Error).self) { try page([message("XY-1")]) }
        #expect(throws: (any Error).self) { try page([message(NSNull())]) }
        #expect(throws: (any Error).self) { try page([message("AM-")]) }
    }

    @Test func aPageOfAnotherAgentOrOutOfOrderIsRefused() throws {
        #expect(throws: HubError.self) { try page([message(1)], db: "other").validate(database: "db", agent: "studio", after: 0) }
        #expect(throws: HubError.self) { try page([message(2), message(1)]).validate(database: "db", agent: "studio", after: 0) }
        #expect(throws: HubError.self) { try page([message(1), message(1)]).validate(database: "db", agent: "studio", after: 0) }
        #expect(throws: HubError.self) { try page([message(5)]).validate(database: "db", agent: "studio", after: 5) }
        #expect(throws: HubError.self) { try page([message(1, sender: "vps", recipient: "manager")]).validate(database: "db", agent: "studio", after: 0) }
        #expect(throws: HubError.self) { try page((1...201).map { message($0) }).validate(database: "db", agent: "studio", after: 0) }
        try page([]).validate(database: "db", agent: "studio", after: 40)
    }

    @Test func newPagesGoAtTheEndAndTheNewestStay() {
        func make(_ id: Int) -> AgentMessage { AgentMessage(id: id, sender: "studio", recipient: "vps", text: "m\(id)", created: Double(id)) }
        let first = AgentMessages.merged([], [make(1), make(2)])
        #expect(first.map(\.id) == [1, 2])
        #expect(AgentMessages.merged(first, [make(2), make(3)]).map(\.id) == [1, 2, 3])
        #expect(AgentMessages.merged(first, [make(3), make(4)], keep: 3).map(\.id) == [2, 3, 4])
    }
}
