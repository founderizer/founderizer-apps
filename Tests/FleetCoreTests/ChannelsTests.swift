import Foundation
import Testing
@testable import FleetCore

// Round 3 (CHAT-APPS.md 17): the cards of an agent's Channels page, the account that a card shows and that Add number
// or Add bot writes, the sidebar's dot, the owner's link step and the Discord page's answer.

private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

private func number(_ fields: [String: Any] = [:]) -> [String: Any] {
    ["id": "whatsapp-studio", "app": "whatsapp", "label": "Studio", "agents": ["studio"], "enabled": true, "state": "connected",
     "user": "34900123210:7@s.whatsapp.net", "name": "+34900123210", "error": NSNull(), "invite_url": NSNull(), "status_at": 990.0,
     "link": ["state": "linked", "expires": NSNull(), "error": NSNull()]].merging(fields) { _, new in new }
}

private func bot(_ fields: [String: Any] = [:]) -> [String: Any] {
    ["id": "discord-studio", "app": "discord", "label": "Studio", "agents": ["studio"], "enabled": true, "state": "connected",
     "user": "1200", "name": "Fleet Studio", "error": NSNull(), "status_at": 990.0, "link": NSNull(),
     "invite_url": "https://discord.com/oauth2/authorize?client_id=1100&scope=bot&permissions=0"].merging(fields) { _, new in new }
}

private func list(_ accounts: [[String: Any]]) throws -> ChatAppsSnapshot {
    try JSONDecoder().decode(ChatAppsSnapshot.self, from: json(["db": "db", "paused": false, "bridge_seen": 995.0, "accounts": accounts]))
}

private func card(_ app: String, _ accounts: [[String: Any]], linking: Bool = false, time: Double = 1000) throws -> ChannelCard {
    ChannelCard(app: app, agent: "studio", in: try list(accounts), linking: linking, serverTime: time)
}

private func people(_ handles: [[String: Any]]) throws -> PeopleSnapshot {
    try JSONDecoder().decode(PeopleSnapshot.self, from: json(["db": "db", "owner": ["handles": handles], "codes": []]))
}

struct WhatsAppCardTests {
    @Test func noNumberOffersAddNumber() throws {
        let empty = try card("whatsapp", [])
        #expect(empty.kind == .none && empty.status == ChatStateWords(words: "No number", tone: .off))
        #expect(empty.action == .addNumber && empty.menu.isEmpty && empty.title == "WhatsApp" && !empty.needsOwner)
        // Another agent's number is not this agent's.
        #expect(try card("whatsapp", [number(["id": "whatsapp-vps", "agents": ["vps"]])]).kind == .none)
        // Before the first reading, too.
        #expect(ChannelCard(app: "whatsapp", agent: "studio", in: nil, linking: false, serverTime: nil).kind == .none)
    }

    @Test func linkingShowsTheQRCodeWithoutAMainButton() throws {
        // Right after Add number: the bridge has not reported the number yet.
        let added = try card("whatsapp", [number(["state": NSNull(), "status_at": NSNull(), "link": NSNull(), "name": NSNull()])], linking: true)
        #expect(added.kind == .linking && added.status == ChatStateWords(words: "Linking", tone: .waiting))
        #expect(added.action == nil && added.menu == [.remove] && !added.needsOwner)
        // The bridge reports a never linked number as logged out while its code waits.
        let waiting = try card("whatsapp", [number(["state": "logged_out", "link": ["state": "waiting", "expires": 1020.0, "error": NSNull()]])],
                               linking: true)
        #expect(waiting.kind == .linking)
        // A linked number is never in Linking.
        #expect(try card("whatsapp", [number()], linking: true).kind == .connected)
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
        let out = try card("whatsapp", [number(["state": "logged_out", "link": ["state": "logged_out", "expires": NSNull(),
                                                                                 "error": "the QR code was not scanned in time"]])])
        #expect(out.kind == .unlinked && out.status.words == "Unlinked" && out.status.tone == .problem)
        #expect(out.status.detail == "the QR code was not scanned in time." && out.action == .linkAgain && out.menu == [.remove])
        #expect(out.needsOwner && out.title == "WhatsApp")
        // A code that waits after the owner cancelled it on the page: Unlinked, with Link again.
        let cancelled = try card("whatsapp", [number(["state": "connecting", "link": ["state": "waiting", "expires": 1020.0, "error": NSNull()]])])
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
    @Test func noBotOffersAddBot() throws {
        let empty = try card("discord", [])
        #expect(empty.kind == .none && empty.status.words == "No bot" && empty.action == .addBot && empty.menu.isEmpty)
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
        #expect(try list([number(["state": "logged_out", "link": NSNull()])]).needsOwner("studio", serverTime: 1000))
        // A code that waits for the scan, another agent's problem, or no channel at all: no dot.
        #expect(try !list([number(["state": "logged_out", "link": ["state": "waiting", "expires": 1020.0, "error": NSNull()]])])
            .needsOwner("studio", serverTime: 1000))
        #expect(try !list([bot(["id": "discord-vps", "agents": ["vps"], "state": "missing_token"])]).needsOwner("studio", serverTime: 1000))
        #expect(try !list([]).needsOwner("studio", serverTime: 1000))
    }

    @Test func theOwnerLinkStepShowsOnceTheCardIsConnectedAndTheOwnerHasNoID() throws {
        let linked = try card("whatsapp", [number()])
        #expect(linked.asksForOwnerLink(try people([])))
        #expect(!linked.asksForOwnerLink(try people([["app": "whatsapp", "id": "123@lid", "alias": NSNull(), "name": NSNull(), "linked": 900.0]])))
        // An ID of the other app does not count.
        #expect(linked.asksForOwnerLink(try people([["app": "discord", "id": "4242", "alias": NSNull(), "name": "sam", "linked": 900.0]])))
        // Not before the number is linked, and not without the hub's people list.
        #expect(try !card("whatsapp", [number(["state": "logged_out"])]).asksForOwnerLink(try people([])))
        #expect(!linked.asksForOwnerLink(nil))
    }
}

struct ChannelAccountTests {
    @Test func addNumberAndAddBotWriteTheAgentsOwnAccount() throws {
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
