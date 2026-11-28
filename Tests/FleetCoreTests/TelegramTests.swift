import Foundation
import Testing
@testable import FleetCore

// Telegram, the third chat app (CHAT-APPS.md 19, owner API 1.243): its card, its token's form, the deep links of the
// owner's code and of a person's invite, and each bot's own Start. Example names only.

private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

private let token = "7000000001:TEST-not-a-real-bot-token-aaaaaaaaaa"

struct TelegramTests {
    @Test func aConnectedBotIsItsUsernameWithAnAt() throws {
        let snapshot = try JSONDecoder().decode(ChatAppsSnapshot.self, from: json(["db": "db", "paused": false, "bridge_seen": 995.0,
            "accounts": [["id": "telegram-sales", "app": "telegram", "label": "Sales", "agents": ["sales"], "state": "connected",
                          "user": "7000000001", "name": "AcmeSalesBot", "status_at": 995.0]]]))
        let card = ChannelCard(app: "telegram", agent: "sales", in: snapshot, serverTime: 1000)
        #expect(card.kind == .connected && card.title == "@AcmeSalesBot")
        // A bot is a bot: Change token and Remove bot, and no invite to a server
        #expect(card.menu == [.changeToken, .remove])
        let none = ChannelCard(app: "telegram", agent: "other", in: snapshot, serverTime: 1000)
        #expect(none.kind == .none && none.action == .connect && none.title == "Telegram")
    }

    @Test func eachBotAsksForTheOwnersOwnStart() throws {
        func card(_ wrote: Bool?) throws -> ChannelCard {
            var account: [String: Any] = ["id": "telegram-sales", "app": "telegram", "label": "Sales", "agents": ["sales"],
                                          "state": "connected", "user": "7000000001", "name": "AcmeSalesBot", "status_at": 995.0]
            if let wrote { account["owner_wrote"] = wrote }
            let snapshot = try JSONDecoder().decode(ChatAppsSnapshot.self, from: json(["db": "db", "paused": false,
                                                                                       "bridge_seen": 995.0, "accounts": [account]]))
            return ChannelCard(app: "telegram", agent: "sales", in: snapshot, serverTime: 1000)
        }
        func people(_ handles: [[String: Any]]) throws -> PeopleSnapshot {
            try JSONDecoder().decode(PeopleSnapshot.self, from: json(["db": "db", "owner": ["handles": handles]]))
        }
        let linked = try people([["app": "telegram", "id": "5000000001", "alias": NSNull(), "name": "sam", "linked": 900.0]])
        let none = try people([])
        // his Telegram is linked through another bot: this one writes to him first only after his own Start in it
        #expect(try card(false).asksForOwnerLink(linked) && card(false).menu(for: linked).first == .linkMe)
        #expect(try !card(true).asksForOwnerLink(linked))
        #expect(try card(true).asksForOwnerLink(none) && card(false).asksForOwnerLink(none))
        // a hub before 1.243 says nothing of the bot: his handle decides, as on Discord
        #expect(try !card(nil).asksForOwnerLink(linked) && card(nil).asksForOwnerLink(none))
        #expect(try !card(false).asksForOwnerLink(nil))
    }

    @Test func aTokenOfTelegramsFormAndNoOtherIsTaken() throws {
        let pasted = try #require(BotToken(telegram: "  \(token)\n"))
        #expect(pasted.value == token && pasted.app == "telegram")
        #expect(BotToken(telegram: String(repeating: "a", count: 60)) == nil)        // a Discord token's form
        #expect(BotToken(telegram: "7000000001:short") == nil)
        #expect(BotToken(telegram: "bot7000000001:TEST-not-a-real-bot-token-aaaaaaaaaa") == nil)
        #expect(BotToken(pasted: token) == nil)                                       // and Discord's takes no colon
        var dumped = ""
        dump(pasted, to: &dumped)
        for text in [String(describing: pasted), "\(pasted)", String(reflecting: pasted), dumped] {
            #expect(!text.contains(token) && !text.contains("TEST-not"), "\(text)")
        }
        let send = ChatAppsClient.Command.token(account: "telegram-sales", token: pasted)
        #expect(send.route == "ui/chat-apps/telegram-sales/token")
        let body = try #require(try JSONSerialization.jsonObject(with: send.body(requestID: "11111111-2222-4333-8444-555555555555",
                                                                                  database: "db")) as? [String: Any])
        #expect(body["token"] as? String == token)
    }

    @Test func aDeepLinkOfTelegramIsAShownLinkAndNoOtherHostIs() throws {
        let code = try JSONDecoder().decode(LinkCode.self, from: json([
            "ok": true, "request_id": "r", "client": "c", "code": "K7P2-QX9M", "expires": 1600.0,
            "targets": [["account": "telegram-sales", "label": "Sales", "url": "https://t.me/AcmeSalesBot?start=K7P2-QX9M"],
                        ["account": "telegram-other", "label": "Other", "url": "https://t.me.example.com/x"],
                        ["account": "telegram-plain", "label": "Plain", "url": "http://t.me/AcmeSalesBot?start=K7P2-QX9M"]]]))
        #expect(code.targets[0].link?.absoluteString == "https://t.me/AcmeSalesBot?start=K7P2-QX9M")
        #expect(code.targets[1].link == nil && code.targets[2].link == nil)
    }

    @Test func aConversationOnTelegramHasItsApp() throws {
        let conversation = try JSONDecoder().decode(Conversation.self, from: json([
            "id": 4, "agent": "sales", "account": "telegram-sales", "state": "open"]))
        #expect(conversation.app == "telegram")
        // a handle that the owner types is WhatsApp's or Discord's; Telegram's comes from the chat app itself
        #expect(People.chatApps == ["whatsapp", "discord", "telegram"] && People.apps == ["whatsapp", "discord"])
    }
}
