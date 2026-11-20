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

    @Test func anInviteIsForOnePersonAndOneAgent() throws {
        let invite = ChatAppsClient.Command.invite(person: 12, agent: "sales")
        #expect(invite.route == "ui/people/codes")
        let body = try #require(try JSONSerialization.jsonObject(with: invite.body(requestID: "11111111-2222-4333-8444-555555555555",
                                                                                    database: "db")) as? [String: Any])
        #expect(body["purpose"] as? String == "invite" && body["app"] as? String == "telegram")
        #expect(body["person"] as? Int == 12 && body["agent"] as? String == "sales")
        #expect(ChatAppsClient.Command.invite(person: 0, agent: "sales").route == nil)
        #expect(ChatAppsClient.Command.invite(person: 3, agent: "").route == nil)
    }

    @Test func anInviteNeedsABotThatIsOnAndHasSaidItsName() throws {
        // the hub's own test (new_invite_code): an account of that agent alone, on, whose bot said its name
        func snapshot(_ accounts: [[String: Any]]) throws -> ChatAppsSnapshot {
            try JSONDecoder().decode(ChatAppsSnapshot.self, from: json(["db": "db", "paused": false, "accounts": accounts]))
        }
        let bot: [String: Any] = ["id": "telegram-sales", "app": "telegram", "label": "Sales", "agents": ["sales"],
                                  "state": "connected", "user": "7000000001", "name": "AcmeSalesBot"]
        #expect(try snapshot([bot]).canInviteOnTelegram(to: "sales"))
        #expect(try !snapshot([bot]).canInviteOnTelegram(to: "support"))
        // turned off: its card still shows (channel), and the hub refuses the link
        var off = bot
        off["enabled"] = false
        #expect(try snapshot([off]).channel("telegram", of: "sales") != nil && !snapshot([off]).canInviteOnTelegram(to: "sales"))
        // a bot that has not said its name yet, or a name that no link takes
        var unnamed = bot
        unnamed["name"] = NSNull()
        unnamed["state"] = "connecting"
        var badName = bot
        badName["name"] = "a b"
        #expect(try !snapshot([unnamed]).canInviteOnTelegram(to: "sales") && !snapshot([badName]).canInviteOnTelegram(to: "sales"))
        // an account of two agents, and another app's account
        var shared = bot
        shared["agents"] = ["sales", "support"]
        var discord = bot
        discord["app"] = "discord"
        #expect(try !snapshot([shared]).canInviteOnTelegram(to: "sales") && !snapshot([discord]).canInviteOnTelegram(to: "sales"))
        // one bot of the agent is off and another is on: the one that is on takes the invite
        var second = off
        second["id"] = "telegram-sales-2"
        #expect(try snapshot([second, bot]).canInviteOnTelegram(to: "sales"))
        #expect(try snapshot([second, bot]).telegramInviteAccount(of: "sales")?.id == "telegram-sales")
        // of two that take it, a connected one first
        var waiting = bot
        waiting["id"] = "telegram-sales-3"
        waiting["state"] = "connecting"
        #expect(try snapshot([waiting, bot]).telegramInviteAccount(of: "sales")?.id == "telegram-sales")
        #expect(try snapshot([waiting]).telegramInviteAccount(of: "sales")?.id == "telegram-sales-3")
        #expect(try snapshot([off, unnamed]).telegramInviteAccount(of: "sales") == nil)
    }

    @Test func anInviteShowsTheLinkOnItsOwnBotOrNone() throws {
        // the link on the bot that the invite is for; an answer with none for it is "The hub gave no link." on a
        // person's page as on the setup steps, never a form that waits for ever
        let code = try JSONDecoder().decode(LinkCode.self, from: json([
            "ok": true, "request_id": "r", "client": "c", "code": "K7P2-QX9M", "expires": 1600.0,
            "targets": [["account": "telegram-sales", "label": "Sales", "url": "https://t.me/AcmeSalesBot?start=K7P2-QX9M"],
                        ["account": "telegram-sales-2", "label": "Sales", "url": NSNull()],
                        ["account": "telegram-sales-3", "label": "Sales", "url": "https://t.me.example.com/x"]]]))
        #expect(code.link(on: "telegram-sales")?.absoluteString == "https://t.me/AcmeSalesBot?start=K7P2-QX9M")
        #expect(code.link(on: "telegram-sales-2") == nil && code.link(on: "telegram-sales-3") == nil)
        #expect(code.link(on: "telegram-other") == nil && code.link(on: nil) == nil)
    }

    @Test func aKeptInviteHasALinkOnItsBotAndServesOnlyItsOwnVisit() throws {
        // this Mac keeps a person's invite only with a link on its bot (else "The hub gave no link." would stand at
        // each visit for 7 days), and a visit shows it again only for the same person, agent and bot, with no
        // Telegram link of theirs since and more than an hour left
        func person(added: Any = 900.0, handles: [[String: Any]] = []) throws -> PeopleSnapshot.Person {
            try JSONDecoder().decode(PeopleSnapshot.Person.self, from: json([
                "id": 12, "name": "Ana", "role": "customer", "added": added,
                "agents": [["agent": "sales", "can_chat": true]], "handles": handles, "conversations": []]))
        }
        func bot(_ name: String = "AcmeSalesBot") throws -> ChatAppsSnapshot.Account? {
            try JSONDecoder().decode(ChatAppsSnapshot.self, from: json(["db": "db", "paused": false, "accounts": [
                ["id": "telegram-sales", "app": "telegram", "label": "Sales", "agents": ["sales"], "state": "connected",
                 "name": name]]])).telegramInviteAccount(of: "sales")
        }
        func invite(_ url: Any) throws -> LinkCode {
            try JSONDecoder().decode(LinkCode.self, from: json([
                "ok": true, "request_id": "r", "client": "c", "code": "K7P2-QX9M", "expires": 1000.0 + 7 * 86400,
                "targets": [["account": "telegram-sales", "label": "Sales", "url": url]]]))
        }
        let ana = try person()
        let link = "https://t.me/AcmeSalesBot?start=K7P2-QX9M"
        // an answer with no link on its bot is not kept: the next visit asks the hub again
        #expect(try KeptInvite(invite(NSNull()), person: ana, agent: "sales", bot: bot()) == nil)
        #expect(try KeptInvite(invite(link), person: ana, agent: "sales", bot: nil) == nil)
        let kept = try #require(try KeptInvite(invite(link), person: ana, agent: "sales", bot: bot()))
        let now = Date()
        func serves(_ someone: PeopleSnapshot.Person, agent: String = "sales", through account: ChatAppsSnapshot.Account?,
                    at serverTime: Double = 1000) -> Bool {
            kept.serves(someone, agent: agent, bot: account, serverTime: serverTime, readAt: now, now: now)
        }
        #expect(try serves(ana, through: bot()))
        #expect(try !serves(ana, agent: "support", through: bot()))
        // another bot of that account (its username changed), or no bot
        #expect(try !serves(ana, through: bot("AcmeSalesTwoBot")) && !serves(ana, through: nil))
        // a new person with that number, and the person who took a Telegram link since
        #expect(try !serves(person(added: 950.0), through: bot()))
        #expect(try !serves(person(handles: [["app": "telegram", "handle": "5000000002"]]), through: bot()))
        // less than an hour left by the hub's clock
        #expect(try !serves(ana, through: bot(), at: 1000.0 + 7 * 86400 - 3000))
    }

    @Test func aConversationOnTelegramHasItsApp() throws {
        let conversation = try JSONDecoder().decode(Conversation.self, from: json([
            "id": 4, "agent": "sales", "account": "telegram-sales", "state": "open"]))
        #expect(conversation.app == "telegram")
        // a handle that the owner types is WhatsApp's or Discord's; Telegram's comes from the person's invite
        #expect(People.chatApps == ["whatsapp", "discord", "telegram"] && People.apps == ["whatsapp", "discord"])
    }
}
