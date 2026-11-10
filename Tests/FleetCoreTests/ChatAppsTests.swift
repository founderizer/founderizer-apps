import Foundation
import Testing
@testable import FleetCore

private let sha = String(repeating: "c", count: 64)

private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

/// A `/ui/state` with one owner message and one reply; `extra` adds the chat apps fields of a newer hub.
private func state(message: [String: Any] = [:], report: [String: Any] = [:], extra: [String: Any] = [:]) throws -> HubState {
    var object: [String: Any] = [
        "schema_version": 1, "db": "db", "time": 1000.0,
        "agents": [["name": "studio", "role": "worker", "runtime": "claude", "can": []]],
        "tasks": [], "notes": [], "needs": [], "permissions": [],
        "messages": [["request_id": "8c1f2b9e-1111-4222-8333-444455556666", "recipient": "studio", "kind": "message",
                      "text": "How is the scrape going?", "event_id": 7, "created": 990.0, "client": "fleet-channels/1/whatsapp-main"]
            .merging(message) { _, new in new }],
        "reports": [["id": 3, "agent": "studio", "in_reply_to": "8c1f2b9e-1111-4222-8333-444455556666", "text": "Half done.",
                     "about": "", "created": 995.0].merging(report) { _, new in new }]]
    object.merge(extra) { _, new in new }
    return try HubState.decode(json(object))
}

private func account(_ fields: [String: Any]) -> [String: Any] {
    ["id": "discord-studio", "app": "discord", "label": "Studio", "agents": ["studio"], "default": NSNull(), "unknown": "ignore",
     "enabled": true, "state": "connected", "user": "1200", "name": "Fleet Studio", "error": NSNull(), "application_id": "1100",
     "invite_url": "https://discord.com/oauth2/authorize?client_id=1100&scope=bot&permissions=0", "status_at": 990.0,
     "last_event": 760.0, "sent_today": 0, "ignored_today": 1, "link": NSNull(),
     "setup": "mkdir -p ~/.fleet/chat-apps && chmod 700 ~/.fleet/chat-apps && read -rs T"].merging(fields) { _, new in new }
}

private func snapshot(_ accounts: [[String: Any]], bridge: Any = 995.0, sha256: Any? = nil) throws -> ChatAppsSnapshot {
    var object: [String: Any] = ["db": "db", "paused": false, "bridge_seen": bridge, "accounts": accounts]
    if let sha256 { object["sha256"] = sha256 }
    return try JSONDecoder().decode(ChatAppsSnapshot.self, from: json(object))
}

private func people(handles: [[String: Any]] = [], codes: Any? = [], ignored: Any? = []) throws -> PeopleSnapshot {
    var object: [String: Any] = ["db": "db", "owner": ["handles": handles]]
    if let codes { object["codes"] = codes }
    if let ignored { object["ignored"] = ignored }
    return try JSONDecoder().decode(PeopleSnapshot.self, from: json(object))
}

struct ChatAppsStateTests {
    @Test func theStateGivesTheOriginTheDeliveryAndTheSummary() throws {
        let hub = try state(message: ["origin": ["app": "whatsapp", "account": "whatsapp-main", "label": "Fleet"]],
                            report: ["delivery": ["app": "whatsapp", "account": "whatsapp-main", "state": "read", "at": 996.0,
                                                  "error": NSNull(), "outbound": 41]],
                            extra: ["ui_features": ["direct_chat", "chat_apps", "people"], "chat_apps": ["paused": true, "problems": 2]])
        #expect(hub.messages[0].origin == MessageOrigin(app: "whatsapp", account: "whatsapp-main", label: "Fleet"))
        #expect(hub.reports[0].delivery?.state == "read" && hub.reports[0].delivery?.outbound == 41)
        #expect(hub.chat_apps == ChatAppsSummary(paused: true, problems: 2))
        #expect(hub.ui_features?.contains(ChatApps.feature) == true && hub.ui_features?.contains(ChatApps.peopleFeature) == true)
    }

    @Test func anOlderHubHasNoOriginNoDeliveryAndNoSummary() throws {
        let older = try state()
        #expect(older.messages[0].origin == nil && older.reports[0].delivery == nil && older.chat_apps == nil)
        let nulls = try state(message: ["origin": NSNull()], report: ["delivery": NSNull()], extra: ["chat_apps": NSNull()])
        #expect(nulls.messages[0].origin == nil && nulls.reports[0].delivery == nil && nulls.chat_apps == nil)
    }

    @Test func aChangedDeliveryChangesTheChatTimeline() throws {
        let sent = try state(report: ["delivery": ["app": "discord", "account": "discord-studio", "state": "sent", "at": 996.0, "error": NSNull(), "outbound": 9]])
        let read = try state(report: ["delivery": ["app": "discord", "account": "discord-studio", "state": "read", "at": 997.0, "error": NSNull(), "outbound": 9]])
        var timeline = ChatTimeline()
        let first = timeline.update(messages: sent.messages, reports: sent.reports)
        let changed = timeline.update(messages: read.messages, reports: read.reports)
        let same = timeline.update(messages: read.messages, reports: read.reports)
        #expect(first && changed && !same)
    }

    @Test func theDeliveryLineSaysWhereTheReplyWentAndWhatTheOwnerCanDo() throws {
        func delivery(_ state: String, at: Any = 996.0, error: Any = NSNull(), outbound: Any = 41) throws -> ReportDelivery {
            try JSONDecoder().decode(ReportDelivery.self, from: json(["app": "whatsapp", "account": "whatsapp-main", "state": state,
                                                                      "at": at, "error": error, "outbound": outbound]))
        }
        let time: (Double) -> String = { _ in "14:03" }
        #expect(try delivery("read").words(time: time) == "Sent to WhatsApp · Read 14:03")
        #expect(try delivery("delivered").words(time: time) == "Sent to WhatsApp · Delivered 14:03")
        #expect(try delivery("sent").words(time: time) == "Sent to WhatsApp · 14:03")
        #expect(try delivery("sent", at: NSNull()).words(time: time) == "Sent to WhatsApp")
        #expect(try delivery("queued").words(time: time) == "Waiting to send to WhatsApp")
        #expect(try delivery("sending").words(time: time) == "Sending to WhatsApp…")
        #expect(try delivery("failed", error: "WhatsApp is unlinked").words(time: time) == "Not sent: WhatsApp is unlinked.")
        #expect(try delivery("failed", error: "daily WhatsApp limit.").words(time: time) == "Not sent: daily WhatsApp limit.")
        #expect(try delivery("failed").words(time: time) == "Not sent to WhatsApp.")
        #expect(try delivery("unknown").words(time: time) == "Delivery to WhatsApp not confirmed")
        for good in ["queued", "sending", "sent", "delivered", "read"] {
            #expect(try !delivery(good).isProblem && !delivery(good).canSendAgain, "\(good)")
        }
        #expect(try delivery("failed").canSendAgain && delivery("unknown").canSendAgain && delivery("unknown").isProblem)
        #expect(try !delivery("unknown", outbound: NSNull()).canSendAgain)
    }
}

struct ChatAppsReadTests {
    @Test func theAccountsDecodeWithTheTeamVersion() throws {
        let list = try snapshot([
            account([:]),
            account(["id": "whatsapp-studio", "app": "whatsapp", "label": "Studio", "state": "logged_out", "name": "+34900123210",
                     "invite_url": NSNull(), "link": ["state": "logged_out", "expires": NSNull(), "error": NSNull()], "setup": NSNull()])], sha256: sha)
        try list.validate(database: "db")
        #expect(list.sha256 == sha && list.bridge_seen == 995.0 && !list.bridgeSeenWithoutTime)
        let bot = list.accounts[0], number = list.accounts[1]
        #expect(bot.inviteURL?.absoluteString == "https://discord.com/oauth2/authorize?client_id=1100&scope=bot&permissions=0")
        #expect(bot.isConnected && bot.belongs(to: "studio") && !bot.belongs(to: "vps"))
        #expect(number.link?.state == "logged_out" && number.inviteURL == nil && !number.isConnected)
        #expect(throws: HubError.self) { try list.validate(database: "other") }
    }

    @Test func theBridgeDotSaysOnlineOnlyWhileTheBridgeIsInContact() throws {
        let list = try snapshot([])
        #expect(list.bridgeStatus(serverTime: 1000) == ChatStateWords(words: "Bridge online", tone: .good))
        let silent = list.bridgeStatus(serverTime: 995 + ChatApps.statusAge + 1)
        #expect(silent.words == "Bridge offline" && silent.tone == .problem && silent.readingAt == 995)
        let never = try snapshot([], bridge: NSNull()).bridgeStatus(serverTime: 1000)
        #expect(never.words == "No bridge" && never.tone == .problem)
        let flag = try snapshot([], bridge: true)
        #expect(flag.bridgeSeenWithoutTime && flag.bridgeStatus(serverTime: 1000).tone == .good)
    }

    @Test func aBadListOrALinkToAnotherSiteIsRefused() throws {
        #expect(throws: HubError.self) { try snapshot([account([:]), account([:])]).validate(database: "db") }
        #expect(throws: HubError.self) { try snapshot([account(["id": "Discord Studio"])]).validate(database: "db") }
        #expect(throws: HubError.self) { try snapshot([], sha256: "short").validate(database: "db") }
        #expect(try snapshot([account(["invite_url": "http://discord.com/oauth2/authorize"])]).accounts[0].inviteURL == nil)
        #expect(try snapshot([account(["invite_url": "https://evil.example/discord.com"])]).accounts[0].inviteURL == nil)
        // A hub that sends an account without the bridge's fields still shows the card.
        let bare = try snapshot([["id": "discord-studio", "app": "discord", "label": "Studio", "agents": ["studio"]]])
        let card = ChannelCard(app: "discord", agent: "studio", in: bare, linking: false, serverTime: 1000)
        #expect(card.kind == .connecting && bare.accounts[0].isEnabled)
    }

    @Test func theLinkReadingGivesTheQRTextOnlyWhileItWaits() throws {
        let waiting = try JSONDecoder().decode(ChatLinkReading.self, from: json(["state": "waiting", "qr": "2@abc,def,ghi", "expires": 1020.0, "error": NSNull()]))
        #expect(waiting == ChatLinkReading(state: "waiting", qr: "2@abc,def,ghi", expires: 1020, error: nil))
        let linked = try JSONDecoder().decode(ChatLinkReading.self, from: json(["db": "db", "state": "linked", "qr": NSNull(), "expires": NSNull(), "error": NSNull()]))
        #expect(linked.state == "linked" && linked.qr == nil)
    }
}

struct PeopleTests {
    private let handle: [String: Any] = ["app": "discord", "id": "4242", "alias": NSNull(), "name": "sam", "linked": 900.0]

    @Test func peopleGivesTheOwnersIDsAndTheOpenCodes() throws {
        let list = try people(handles: [handle], codes: [["app": "whatsapp", "expires": 1500.0]],
                              ignored: [["account": "whatsapp-studio", "today": 3,
                                         "last": [["sender": "34600123412@s.whatsapp.net", "name": "Ana R.", "preview": "Hi, I am Ana", "ts": 980.0]]]])
        try list.validate(database: "db")
        #expect(list.handles(of: "discord").map(\.key) == ["discord/4242"] && list.handles(of: "whatsapp").isEmpty)
        #expect(list.code(of: "whatsapp")?.expires == 1500 && list.code(of: "discord") == nil)
        #expect(throws: HubError.self) { try list.validate(database: "other") }
        // Without the lists, no code is open.
        #expect(try people(codes: nil, ignored: nil).code(of: "discord") == nil)
    }

    @Test func thePeopleWhoWroteAndWereNotAnsweredAreNotThrownAway() throws {
        // The hub counts and keeps them because nobody else may write to an agent; this is the one place the owner
        // sees that somebody tried. The app showed none of it until now.
        let list = try people(ignored: [["account": "whatsapp-studio", "today": 3,
                                         "last": [["sender": "34600123412@s.whatsapp.net", "name": "Ana R.",
                                                   "preview": "Hi, I am Ana", "ts": 980.0],
                                                  ["sender": "34600999000@s.whatsapp.net", "name": NSNull(),
                                                   "preview": NSNull(), "ts": 940.0]]],
                                        ["account": "discord-studio", "today": 0, "last": []]])
        let wrote = try #require(list.ignored(of: "whatsapp-studio"))
        #expect(wrote.today == 3 && wrote.messages.count == 2)
        #expect(wrote.messages[0].who == "Ana R." && wrote.messages[0].said == "Hi, I am Ana")
        // No name and no text: the app still says who it was, from the id the app gave, and says nothing more.
        #expect(wrote.messages[1].who == "34600999000" && wrote.messages[1].said == nil)
        // An account nobody wrote to has nothing to show, and so has a hub that sends no list at all.
        #expect(list.ignored(of: "discord-studio") == nil)
        #expect(try people(ignored: nil).ignored(of: "whatsapp-studio") == nil)
    }

    @Test func theHubsOwnAnswerCarriesThemInThatShape() throws {
        // `Fixtures/people.json` is `GET /ui/people` from the hub's own code (`ui_fixture.py`), so this reads the
        // shape the hub really sends and not one this app guessed.
        let url = try #require(Bundle.module.url(forResource: "people", withExtension: "json", subdirectory: "Fixtures"))
        let list = try JSONDecoder().decode(PeopleSnapshot.self, from: try Data(contentsOf: url))
        let wrote = try #require(list.ignored(of: "whatsapp-main"))
        #expect(wrote.today == 1)
        #expect(wrote.messages.first?.who == "Unknown")
        #expect(wrote.messages.first?.said == "Hello, who is this?")
        #expect(list.ignored(of: "discord-studio") == nil)
    }

    @Test func linkedShowsByItselfWhenTheHubTakesTheCode() throws {
        let before: Set<String> = []
        let open = try people(codes: [["app": "discord", "expires": 1500.0]])
        #expect(!open.bound("discord", before: before, codeOpen: true))
        // A new ID of the app: the hub bound the sender.
        let bound = try people(handles: [handle], codes: [])
        #expect(bound.bound("discord", before: before, codeOpen: false))
        #expect(bound.newHandle(of: "discord", before: before)?.name == "sam")
        // The same ID linked again: no new ID, but the hub no longer has the code while it still works.
        let again = try people(handles: [handle], codes: [])
        #expect(again.bound("discord", before: ["discord/4242"], codeOpen: true))
        #expect(!again.bound("discord", before: ["discord/4242"], codeOpen: false))
        #expect(!again.bound("whatsapp", before: [], codeOpen: true))
        // An older answer without `codes` never says that the code was taken.
        #expect(!(try people(handles: [handle], codes: nil)).bound("discord", before: ["discord/4242"], codeOpen: true))
    }

    @Test func aLinkCodeShowsAsTheOwnerTypesIt() throws {
        let code = try JSONDecoder().decode(LinkCode.self, from: json([
            "ok": true, "request_id": "r", "client": "c", "replayed": false, "code": "K7P2QX9M", "expires": 1600.0,
            "targets": [["account": "whatsapp-main", "label": "Fleet", "url": "https://wa.me/34900123210?text=link%20K7P2-QX9M"],
                        ["account": "discord-studio", "label": "Studio", "url": "https://discord.com/users/1200"],
                        ["account": "discord-vps", "label": "VPS", "url": NSNull()],
                        ["account": "x", "label": NSNull(), "url": "https://example.com/users/1"]]]))
        #expect(code.display == "K7P2-QX9M")
        #expect(code.targets.map { $0.link?.absoluteString } == ["https://wa.me/34900123210?text=link%20K7P2-QX9M", "https://discord.com/users/1200", nil, nil])
        #expect(ChatApps.displayCode("k7p2-qx9m") == "K7P2-QX9M" && ChatApps.displayCode("ABC") == "ABC")
        // A replay of the command: the hub keeps no code.
        let replay = try JSONDecoder().decode(LinkCode.self, from: json([
            "ok": true, "request_id": "r", "client": "c", "replayed": true, "purpose": "owner", "app": "discord", "code": NSNull(),
            "expires": 1600.0, "targets": [["account": "discord-studio", "label": "Studio", "url": NSNull()]]]))
        #expect(replay.code == nil && replay.targets[0].link == nil)
    }
}

struct ChatAppsCommandTests {
    private func body(_ command: ChatAppsClient.Command) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: command.body(requestID: "11111111-2222-4333-8444-555555555555", database: "db")) as? [String: Any])
    }

    @Test func eachCommandHasItsRouteAndItsFields() throws {
        let number = ChatAccountInput(app: "whatsapp", label: "Studio", agents: ["studio"])
        let save = try body(.account(sha256: sha, id: "whatsapp-studio", account: number))
        #expect(ChatAppsClient.Command.account(sha256: sha, id: "whatsapp-studio", account: number).route == "ui/team/chat-apps")
        #expect(Set(save.keys) == ["request_id", "db", "base_sha256", "id", "account"])
        #expect(save["base_sha256"] as? String == sha && save["db"] as? String == "db")
        let sent = try #require(save["account"] as? [String: Any])
        #expect(Set(sent.keys) == ["app", "label", "agents", "unknown"])
        #expect(sent["unknown"] as? String == "ignore" && sent["agents"] as? [String] == ["studio"])

        let removed = try body(.account(sha256: sha, id: "discord-vps", account: nil))
        #expect(removed["account"] is NSNull && removed["id"] as? String == "discord-vps")
        #expect(ChatAppsClient.Command.account(sha256: sha, id: "Bad ID", account: nil).route == nil)

        #expect(try body(.pause(true))["paused"] as? Bool == true)
        #expect(ChatAppsClient.Command.pause(false).route == "ui/chat-apps/pause")
        #expect(try Set(body(.link("whatsapp-studio")).keys) == ["request_id", "db"])
        #expect(ChatAppsClient.Command.link("whatsapp-studio").route == "ui/chat-apps/whatsapp-studio/link")
        #expect(ChatAppsClient.Command.unlink("whatsapp-studio").route == "ui/chat-apps/whatsapp-studio/unlink")
        #expect(ChatAppsClient.Command.link("../ui/state").route == nil)
        #expect(ChatAppsClient.Command.sendAgain(41).route == "ui/outbound/41/again")
        #expect(ChatAppsClient.Command.sendAgain(0).route == nil)
        #expect(try Set(body(.sendAgain(41)).keys) == ["request_id", "db"])
        let code = try body(.code("discord"))
        #expect(ChatAppsClient.Command.code("discord").route == "ui/people/codes")
        #expect(code["purpose"] as? String == "owner" && code["app"] as? String == "discord")
    }

    @Test func anAccountNeverSendsADefaultAndSendsEnabledOnlyWhenOff() throws {
        let bot = ChatAccountInput(app: "discord", label: "Studio", agents: ["studio"])
        #expect(Set(bot.fields.keys) == ["app", "label", "agents", "unknown"])
        var off = bot; off.enabled = false
        #expect(off.fields["enabled"] as? Bool == false && off.fields["default"] == nil)
        // Turn on writes the account as the hub has it, with enabled on.
        let current = try snapshot([account(["id": "whatsapp-studio", "app": "whatsapp", "default": "studio", "enabled": false])])
        var input = ChatAccountInput(current.accounts[0])
        #expect(input == ChatAccountInput(app: "whatsapp", label: "Studio", agents: ["studio"], enabled: false))
        input.enabled = true
        #expect(Set(input.fields.keys) == ["app", "label", "agents", "unknown"])
    }
}

struct ChatAppsLogicTests {
    @Test func anAccountIDComesFromTheAgentName() {
        #expect(ChatApps.accountID(app: "discord", agent: "studio", taken: []) == "discord-studio")
        #expect(ChatApps.accountID(app: "discord", agent: "studio", taken: ["discord-studio"]) == "discord-studio-2")
        #expect(ChatApps.accountID(app: "discord", agent: "studio", taken: ["discord-studio", "discord-studio-2"]) == "discord-studio-3")
        #expect(ChatApps.accountID(app: "discord", agent: "web_dev", taken: []) == "discord-web-dev")
        let long = ChatApps.accountID(app: "discord", agent: String(repeating: "a", count: 64), taken: [])
        #expect(ChatApps.isAccountID(long) && long.count <= 36)
        #expect(ChatApps.accountID(app: "whatsapp", agent: "Manager", taken: []) == "whatsapp-manager")
        #expect(!ChatApps.isAccountID("-x") && !ChatApps.isAccountID("A") && !ChatApps.isAccountID(String(repeating: "a", count: 41)))
    }

    @Test func aLabelIsOneLineOfAtMostFortyCharacters() {
        #expect(ChatApps.label("  Studio ") == "Studio")
        #expect(ChatApps.label("") == nil && ChatApps.label("   ") == nil && ChatApps.label("a\nb") == nil)
        #expect(ChatApps.label(String(repeating: "x", count: 40)) != nil && ChatApps.label(String(repeating: "x", count: 41)) == nil)
    }

    @Test func theCountdownUsesTheHubsClock() {
        let read = Date(timeIntervalSince1970: 5000)
        // The Mac's clock is 4,000 seconds behind the hub: only the hub's time counts.
        #expect(ChatApps.remaining(expires: 1600, serverTime: 1000, readAt: read, now: read.addingTimeInterval(19)) == 581)
        #expect(ChatApps.remaining(expires: 1600, serverTime: 1000, readAt: read, now: read.addingTimeInterval(700)) == 0)
        #expect(ChatApps.countdown(581) == "9:41")
        #expect(ChatApps.countdown(600) == "10:00" && ChatApps.countdown(0.2) == "0:01" && ChatApps.countdown(0) == "0:00")
    }

    @Test func aListMasksPhoneNumbers() {
        #expect(ChatApps.masked("34600123412@s.whatsapp.net", app: "whatsapp") == "+34 6•• ••• 412")
        #expect(ChatApps.masked("34600123412:7@s.whatsapp.net", app: "whatsapp") == "+34 6•• ••• 412")
        #expect(ChatApps.masked("+34900123210", app: "whatsapp") == "+34 9•• ••• 210")
        #expect(ChatApps.masked("123456789012345@lid", app: "whatsapp") == "Hidden number")
        #expect(ChatApps.masked("+34 6•• ••• 412", app: "whatsapp") == "+34 6•• ••• 412")
        #expect(ChatApps.masked("4242", app: "discord") == "4242")
    }

    @Test func eachAppHasItsNameAndTheCardsTheirOrder() {
        #expect(ChatApps.title("discord") == "Discord" && ChatApps.title("whatsapp") == "WhatsApp" && ChatApps.title("telegram") == "Telegram")
        #expect(ChatApps.apps == ["whatsapp", "discord"])
    }
}
