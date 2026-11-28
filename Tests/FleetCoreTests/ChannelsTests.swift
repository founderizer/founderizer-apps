import Foundation
import Testing
@testable import FleetCore

// Round 3 (CHAT-APPS.md 17 and 18): the cards of an agent's Channels, the account that a card shows and that Connect
// writes, a number that no phone ever linked, the sidebar's dot, the owner's link step and the Discord page's answer.

private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

private func number(_ fields: [String: Any] = [:]) -> [String: Any] {
    ["id": "whatsapp-studio", "app": "whatsapp", "label": "Studio", "agents": ["studio"], "enabled": true, "state": "connected",
     "user": "34900123210:7@s.whatsapp.net", "name": "+34900123210", "error": NSNull(), "invite_url": NSNull(), "status_at": 990.0,
     "link": ["state": "linked", "expires": NSNull(), "error": NSNull()]].merging(fields) { _, new in new }
}

/// A number that worked and lost its link, as the bridge reports it: it forgets the number when the phone logs it out
/// (`channels.py` `on_state`), and a message came in on it once.
private func lost(_ fields: [String: Any] = [:]) -> [String: Any] {
    number(["state": "logged_out", "user": NSNull(), "name": NSNull(), "last_event": 900.0,
            "link": ["state": "logged_out", "expires": NSNull(), "error": NSNull()]].merging(fields) { _, new in new })
}

private func bot(_ fields: [String: Any] = [:]) -> [String: Any] {
    ["id": "discord-studio", "app": "discord", "label": "Studio", "agents": ["studio"], "enabled": true, "state": "connected",
     "user": "1200", "name": "Fleet Studio", "error": NSNull(), "status_at": 990.0, "link": NSNull(),
     "invite_url": "https://discord.com/oauth2/authorize?client_id=1100&scope=bot&permissions=0"].merging(fields) { _, new in new }
}

private func list(_ accounts: [[String: Any]]) throws -> ChatAppsSnapshot {
    try JSONDecoder().decode(ChatAppsSnapshot.self, from: json(["db": "db", "paused": false, "bridge_seen": 995.0, "accounts": accounts]))
}

private func card(_ app: String, _ accounts: [[String: Any]], time: Double = 1000) throws -> ChannelCard {
    ChannelCard(app: app, agent: "studio", in: try list(accounts), serverTime: time)
}

private func people(_ handles: [[String: Any]]) throws -> PeopleSnapshot {
    try JSONDecoder().decode(PeopleSnapshot.self, from: json(["db": "db", "owner": ["handles": handles], "codes": []]))
}

struct WhatsAppCardTests {
    @Test func noNumberOffersConnect() throws {
        let empty = try card("whatsapp", [])
        #expect(empty.kind == .none && empty.status == ChatStateWords(words: "Not connected", tone: .off))
        #expect(empty.action == .connect && empty.menu.isEmpty && empty.title == "WhatsApp" && !empty.needsOwner)
        // Another agent's number is not this agent's.
        #expect(try card("whatsapp", [number(["id": "whatsapp-vps", "agents": ["vps"]])]).kind == .none)
        // Before the first reading, too.
        #expect(ChannelCard(app: "whatsapp", agent: "studio", in: nil, serverTime: nil).kind == .none)
    }

    /// The owner, 14 November 2026: "it says remove number when I haven't entered or linked any". The app writes the
    /// number's account to ask for its QR code; while no phone ever linked it, the card is the one of no number.
    @Test func aNumberThatNoPhoneEverLinkedIsNoNumber() throws {
        let never: [String: Any] = ["user": NSNull(), "name": NSNull()]
        for left in [number(never.merging(["state": NSNull(), "status_at": NSNull(), "link": NSNull()]) { _, new in new }),
                     number(never.merging(["state": "logged_out", "link": ["state": "logged_out", "expires": NSNull(),
                                                                         "error": "the QR code was not scanned in time"]]) { _, new in new }),
                     number(never.merging(["state": "connecting", "link": ["state": "waiting", "expires": 1020.0, "error": NSNull()]]) { _, new in new }),
                     number(never.merging(["state": "error", "error": "wa-link is not running.", "link": NSNull()]) { _, new in new })] {
            let shown = try card("whatsapp", [left])
            #expect(shown.kind == .none && shown.action == .connect && shown.menu.isEmpty && !shown.needsOwner && shown.title == "WhatsApp")
            #expect(shown.menu(for: try people([])).isEmpty)
            #expect(try !list([left]).needsOwner("studio", serverTime: 1000))
        }
        // A number that had a message worked once: it lost its link, and Remove number is true of it.
        let gone = try card("whatsapp", [lost()])
        #expect(gone.kind == .unlinked && gone.action == .linkAgain && gone.menu == [.remove] && gone.needsOwner)
        // A phone linked it and nobody wrote yet: while the bridge starts again it knows no number, and the hub's link
        // still says linked. It is no "never linked" number, so Back from its steps never takes it away.
        for state in ["connecting", "error"] {
            let again = number(never.merging(["state": state, "link": ["state": "linked", "expires": NSNull(), "error": NSNull()]]) { _, new in new })
            #expect(try !list([again]).accounts[0].holdsNoPhone && !list([again]).accounts[0].neverLinked)
            #expect(try card("whatsapp", [again]).kind != .none)
        }
        // Turned off comes first: Connect could not work on an account that the bridge does not run.
        let off = try card("whatsapp", [number(never.merging(["enabled": false, "state": NSNull(), "link": NSNull()]) { _, new in new })])
        #expect(off.kind == .off && off.action == .turnOn)
        // A bot is never "never linked": a token went in for it.
        #expect(try card("discord", [bot(["state": "missing_token", "user": NSNull(), "name": NSNull()])]).kind == .failed)
    }

    @Test func linkedShowsTheNumberConnectedWithUnlinkAndRemove() throws {
        let linked = try card("whatsapp", [number()])
        #expect(linked.kind == .connected && linked.status == ChatStateWords(words: "Connected", tone: .good))
        #expect(linked.action == nil && linked.menu == [.unlink, .remove])
        #expect(linked.title == "+34 9•• ••• 210")
        // An old report is the last reading: a gray ring, not green.
        let old = try card("whatsapp", [number()], time: 990 + ChatApps.statusAge + 1)
        #expect(old.kind == .connected && old.status.tone == .waiting && old.status.readingAt == 990 && old.status.words == "Connected")
    }

    @Test func unlinkedIsOrangeWithLinkAgain() throws {
        let out = try card("whatsapp", [lost(["link": ["state": "logged_out", "expires": NSNull(),
                                                       "error": "the QR code was not scanned in time"]])])
        #expect(out.kind == .unlinked && out.status.words == "Unlinked" && out.status.tone == .problem)
        #expect(out.status.detail == "the QR code was not scanned in time." && out.action == .linkAgain && out.menu == [.remove])
        #expect(out.needsOwner && out.title == "WhatsApp")
        // A number that worked, whose new code waits for a scan after he left its steps: Unlinked, with Link again.
        let cancelled = try card("whatsapp", [lost(["state": "connecting", "link": ["state": "waiting", "expires": 1020.0, "error": NSNull()]])])
        #expect(cancelled.kind == .unlinked && cancelled.action == .linkAgain)
        #expect(try card("whatsapp", [number(["state": "error", "error": "stream replaced", "link": NSNull()])]).status.detail == "stream replaced.")
    }

    @Test func aReconnectingNumberAndATurnedOffNumberHaveTheirOwnWords() throws {
        let connecting = try card("whatsapp", [number(["state": "connecting"])])
        #expect(connecting.kind == .connecting && connecting.status.words == "Connecting…" && connecting.action == nil)
        let off = try card("whatsapp", [number(["enabled": false])])
        #expect(off.kind == .off && off.status == ChatStateWords(words: "Turned off", tone: .off) && off.action == .turnOn && off.menu == [.remove])
    }
}

struct DiscordCardTests {
    @Test func noBotOffersConnect() throws {
        let empty = try card("discord", [])
        #expect(empty.kind == .none && empty.status.words == "Not connected" && empty.action == .connect && empty.menu.isEmpty)
    }

    @Test func connectingHasASpinnerAndNoMainButton() throws {
        for fields: [String: Any] in [["state": NSNull(), "status_at": NSNull()], ["state": "connecting"]] {
            let connecting = try card("discord", [bot(fields)])
            #expect(connecting.kind == .connecting && connecting.status == ChatStateWords(words: "Connecting…", tone: .waiting))
            #expect(connecting.action == nil && connecting.menu == [.remove] && !connecting.needsOwner)
        }
    }

    @Test func connectedShowsTheBotsNameWithInviteChangeTokenAndRemove() throws {
        let connected = try card("discord", [bot()])
        #expect(connected.kind == .connected && connected.status.tone == .good && connected.title == "Fleet Studio")
        #expect(connected.action == nil && connected.menu == [.invite, .changeToken, .remove])
        // No Invite to server before the bridge reported the application.
        #expect(try card("discord", [bot(["invite_url": NSNull()])]).menu == [.changeToken, .remove])
        #expect(try card("discord", [bot(["invite_url": "https://evil.example/x"])]).menu == [.changeToken, .remove])
    }

    @Test func anErrorIsAShortOrangeReasonWithFixToken() throws {
        let missing = try card("discord", [bot(["state": "missing_token", "name": NSNull()])])
        #expect(missing.kind == .failed && missing.status.words == "No token" && missing.status.tone == .problem)
        #expect(missing.action == .fixToken && missing.menu == [.remove] && missing.needsOwner && missing.title == "Discord")
        let refused = try card("discord", [bot(["state": "error", "error": "4004 authentication failed"])])
        #expect(refused.status.words == "Token refused" && refused.status.detail == "4004 authentication failed." && refused.action == .fixToken)
        let other = try card("discord", [bot(["state": "error", "error": "4013 invalid intents"])])
        #expect(other.status.words == "Not connected" && other.status.detail == "4013 invalid intents.")
        #expect(try card("discord", [bot(["state": "error"])]).status.detail == "The bridge could not connect the bot.")
        #expect(try card("discord", [bot(["state": "logged_out"])]).status.words == "Logged out")
    }

    @Test func theDiscordPageWaitsForTheFirstReportAfterTheSend() throws {
        let sentAt = 995.0
        func account(_ fields: [String: Any]) throws -> ChatAppsSnapshot.Account { try list([bot(fields)]).accounts[0] }
        #expect(DiscordProgress(bot: try account([:]), sentAt: nil) == .paste)
        #expect(DiscordProgress(bot: nil, sentAt: sentAt) == .connecting)
        // A report before the send is about the old token.
        #expect(DiscordProgress(bot: try account(["status_at": 990.0]), sentAt: sentAt) == .connecting)
        #expect(DiscordProgress(bot: try account(["status_at": 996.0]), sentAt: sentAt) == .connected("Fleet Studio"))
        #expect(DiscordProgress(bot: try account(["status_at": 996.0, "name": NSNull()]), sentAt: sentAt) == .connected("Studio"))
        #expect(DiscordProgress(bot: try account(["status_at": 996.0, "state": "error", "error": "4004 authentication failed"]), sentAt: sentAt)
                == .refused("Token refused"))
        // The bridge reads a new token file within 15 seconds: no token yet is not a refusal.
        #expect(DiscordProgress(bot: try account(["status_at": 996.0, "state": "missing_token"]), sentAt: sentAt) == .connecting)
    }
}

struct ChannelAttentionTests {
    @Test func theSidebarDotShowsWhileACardIsOrange() throws {
        #expect(try !list([number(), bot()]).needsOwner("studio", serverTime: 1000))
        #expect(try list([number(), bot(["state": "missing_token"])]).needsOwner("studio", serverTime: 1000))
        #expect(try list([lost()]).needsOwner("studio", serverTime: 1000))
        // The dot and the card say the same: a number that worked and waits for a new scan is orange in both.
        #expect(try list([lost(["link": ["state": "waiting", "expires": 1020.0, "error": NSNull()]])]).needsOwner("studio", serverTime: 1000))
        // Another agent's problem, or no channel at all: no dot.
        #expect(try !list([bot(["id": "discord-vps", "agents": ["vps"], "state": "missing_token"])]).needsOwner("studio", serverTime: 1000))
        #expect(try !list([]).needsOwner("studio", serverTime: 1000))
    }

    @Test func theOwnersOwnLinkIsToDoOnceTheCardIsConnectedAndTheOwnerHasNoID() throws {
        let linked = try card("whatsapp", [number()])
        #expect(linked.asksForOwnerLink(try people([])))
        #expect(!linked.asksForOwnerLink(try people([["app": "whatsapp", "id": "123@lid", "alias": NSNull(), "name": NSNull(), "linked": 900.0]])))
        // An ID of the other app does not count.
        #expect(linked.asksForOwnerLink(try people([["app": "discord", "id": "4242", "alias": NSNull(), "name": "sam", "linked": 900.0]])))
        // Not before the number is linked, and not without the hub's people list.
        #expect(try !card("whatsapp", [lost()]).asksForOwnerLink(try people([])))
        #expect(!linked.asksForOwnerLink(nil))
    }

    /// Link my phone and Link my Discord stand first in a connected card's menu, only while the link is to do.
    @Test func theMenuHasTheOwnersOwnLinkWhileItIsToDo() throws {
        let phone = try card("whatsapp", [number()]), robot = try card("discord", [bot()])
        #expect(phone.menu(for: try people([])) == [.linkMe, .unlink, .remove])
        #expect(robot.menu(for: try people([])) == [.linkMe, .invite, .changeToken, .remove])
        let mine: [[String: Any]] = [["app": "whatsapp", "id": "123@lid", "alias": NSNull(), "name": NSNull(), "linked": 900.0]]
        #expect(phone.menu(for: try people(mine)) == [.unlink, .remove])
        #expect(robot.menu(for: try people(mine)) == [.linkMe, .invite, .changeToken, .remove])
        // Without the hub's people list, and on a card that is not connected, the menu is the card's own.
        #expect(phone.menu(for: nil) == [.unlink, .remove])
        #expect(try card("whatsapp", [lost()]).menu(for: try people([])) == [.remove])
    }
}

/// **The row "People outside the org" of a channel card** (the owner's "Yes, build it" of 26 November 2026 to question 4
/// of `channels-2026-11-26`, and his correction of the same day, the coordinator's D132: Ignore and As customers alone):
/// its value, its choices, and only the lines that its pictures draw.
struct OutsidersRowTests {
    private func agent(role: String = "worker", can: [String] = [], otherModels: Bool = false) throws -> FleetAgent {
        var fields: [String: Any] = ["name": "studio", "role": role, "runtime": "claude", "can": can]
        if otherModels { fields["model_account"] = ["kind": "key", "provider": "google", "label": "Gemini", "address": NSNull()] }
        return try JSONDecoder().decode(FleetAgent.self, from: json(fields))
    }

    private func row(_ unknown: String?, on app: String = "whatsapp", of agent: FleetAgent?,
                     features: [String]? = [OutsidersRow.feature]) throws -> OutsidersRow? {
        var account = app == "whatsapp" ? number() : bot()
        account["unknown"] = unknown
        return OutsidersRow(card: try card(app, [account]), agent: "studio", in: agent, features: features)
    }

    /// The control shows the account's own rule (a reading with none is Ignore); a stored rule that the app does not
    /// know, `colleagues` among them, shows as Ignore, and a choice of Ignore still writes over it, or the owner could
    /// never clear it; only a hub that lists `chat_outsiders` has the row, since an older one refuses As customers; and
    /// only a connected card of an agent that people can reach: a row on the manager's card would offer a choice that
    /// the hub never acts on.
    @Test func theRowShowsTheAccountsRuleOnAConnectedCardOfAnAgentThatPeopleReach() throws {
        let shell = try agent(can: ["shell"])
        let customers = try #require(try row("customers", of: shell))
        #expect(customers.rule == .customers && OutsidersRow.Rule.allCases == [.ignore, .customers])
        #expect(!customers.changes(to: .customers) && customers.changes(to: .ignore))
        #expect(try row("customers", on: "discord", of: shell)?.rule == .customers)
        #expect(try row(nil, of: shell).map { $0.rule == .ignore && !$0.changes(to: .ignore) } == true)
        let colleagues = try #require(try row("colleagues", of: shell))
        #expect(colleagues.rule == .ignore && colleagues.changes(to: .ignore))
        #expect(try row("ignore", of: shell, features: ["telegram"]) == nil && row("ignore", of: shell, features: nil) == nil)
        #expect(try OutsidersRow(card: card("whatsapp", [lost()]), agent: "studio", in: shell, features: [OutsidersRow.feature]) == nil)
        #expect(try OutsidersRow(card: card("discord", []), agent: "studio", in: shell, features: [OutsidersRow.feature]) == nil)
        #expect(try row("ignore", of: agent(role: "manager", can: ["shell"])) == nil)
    }

    /// **Each line stands only where its picture draws it**, under both values: "Works only when <agent>'s Shell box is
    /// off." for a worker or a lead whose Shell box is on, "Does not work when <agent> runs on Other models." for an
    /// agent on Other models, both in that order, and no line for an agent that can take such a sender.
    @Test func eachLineStandsOnlyWhereItsPictureDrawsIt() throws {
        let shellLine = "Works only when Studio's Shell box is off."
        let otherLine = "Does not work when Studio runs on Other models."
        for rule in ["ignore", "customers"] {
            #expect(try row(rule, of: agent(can: ["shell", "browser"]))?.facts == [shellLine], "\(rule)")
            #expect(try row(rule, of: agent(role: "lead", can: ["shell"]))?.facts == [shellLine], "\(rule)")
            #expect(try row(rule, of: agent(can: ["browser"]))?.facts == [], "\(rule)")
            #expect(try row(rule, of: agent(otherModels: true))?.facts == [otherLine], "\(rule)")
            #expect(try row(rule, of: agent(can: ["shell"], otherModels: true))?.facts == [shellLine, otherLine], "\(rule)")
        }
        // an agent that the reading does not have: the value, and no line that the reading cannot say
        #expect(try row("customers", of: nil).map { $0.rule == .customers && $0.facts.isEmpty } == true)
    }

    /// **An account write is sent once more only after a 409 of team.json's version**: As customers with no live Teams
    /// licence (`teams_off`, D132) would be refused again, so its words stand in the card at once and the hub gets no
    /// second write; a 400 or no answer is not tried again either.
    @Test func onlyAConflictOfTheVersionIsTriedAgain() {
        #expect(ChatApps.triesAgain(after: HubError.refusal(.read(status: 409, body: Data(#"{"error": "team.json changed"}"#.utf8)))))
        let teams = Data(#"{"error": "This needs Founderizer for Teams, which this fleet does not have.", "code": "teams_off"}"#.utf8)
        #expect(!ChatApps.triesAgain(after: HubError.refusal(.read(status: 409, body: teams))))
        #expect(!ChatApps.triesAgain(after: HubError.refusal(.read(status: 400, body: Data()))))
        #expect(!ChatApps.triesAgain(after: URLError(.timedOut)) && !ChatApps.triesAgain(after: HubError.invalidResponse))
    }
}

struct ChannelAccountTests {
    @Test func connectWritesTheAgentsOwnAccount() throws {
        let taken = Set(try list([number(["id": "whatsapp-vps", "agents": ["vps"]]), bot()]).accounts.map(\.id))
        let added = ChatApps.agentAccount(app: "whatsapp", agent: "studio", taken: taken)
        #expect(added.id == "whatsapp-studio" && added.account == ChatAccountInput(app: "whatsapp", label: "Studio", agents: ["studio"]))
        #expect(Set(added.account.fields.keys) == ["app", "label", "agents", "unknown"])
        let manager = ChatApps.agentAccount(app: "whatsapp", agent: "manager", taken: taken)
        #expect(manager.id == "whatsapp-manager" && manager.account.agents == ["manager"])
        // An ID that an older account still has gets a number.
        let again = ChatApps.agentAccount(app: "discord", agent: "studio", taken: taken)
        #expect(again.id == "discord-studio-2" && again.account.label == "Studio 2")
    }
}

struct BrandPathTests {
    @Test func eachArcFlagAndNumberStandsApart() {
        // Simple Icons writes an arc's two flags against the next number; CoreSVG does not read that.
        #expect(ChatApps.spacedPath("a.0741.0741 0 00-.0785.0371") == "a .0741 .0741 0 0 0 -.0785 .0371")
        #expect(ChatApps.spacedPath("a9.87 9.87 0 01-5.031-1.378l-.361-.214") == "a 9.87 9.87 0 0 1 -5.031 -1.378 l -.361 -.214")
        #expect(ChatApps.spacedPath("M17.472 14.382c-.297-.149-1.758-.867Z") == "M 17.472 14.382 c -.297 -.149 -1.758 -.867 Z")
        #expect(ChatApps.spacedPath("M1e-2,3E+1z") == "M 1e-2 3E+1 z")
        // Two arcs in a row keep the flag places.
        #expect(ChatApps.spacedPath("a1 1 0 011 1 1 1 0 102 2") == "a 1 1 0 0 1 1 1 1 1 0 1 0 2 2")
        let spaced = ChatApps.spacedPath("A11.815 11.815 0 0012.05 0C5.495 0 .16 5.335.157 11.892")
        #expect(spaced == "A 11.815 11.815 0 0 0 12.05 0 C 5.495 0 .16 5.335 .157 11.892" && ChatApps.spacedPath(spaced) == spaced)
    }
}
