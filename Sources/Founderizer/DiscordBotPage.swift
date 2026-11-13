import AppKit
import FleetCore
import SwiftUI

/// The Discord page of an agent's Channels (CHAT-APPS.md 17.3), in place of the cards, with a Channels back link.
/// **One centered step on a page, as the AI provider's sign-in** (`SetupPage`, `SetupStep`; the owner, 28 October 2026:
/// "use a better wizard for this, so when connected it properly shows it! and then it goes back to the Channels list
/// where it will also show as connected"):
///
///   1. **Add a Discord bot for Mia** ("Paste the bot's token" for Fix token and Change token): what he does in the
///      Developer Portal as short steps (`SetupSteps`), and under them the secure field, which sends a pasted token by
///      itself (Save shows for one typed by hand). While the bridge connects the bot, the title is its moving words.
///      The steps stand over the field because they come before the paste (the owner, 10 November 2026), so the page
///      of how that stood before it, with Open Developer Portal, is gone.
///   2. **Add Mia to your server**: Invite to server.
///   3. **Mia is connected**: the steps done, and Done, back to the Channels list, whose card says Connected.
///
/// Opened from the card of a bot that is connected (Change token), the page is the bot's connected state, with
/// Change token and Invite to server under it; Fix token opens on the token step. Save adds the account
/// `discord-<agent>` when the agent has no bot yet, then sends the token to the hub once (`POST /ui/chat-apps/<id>/token`).
/// The token is only in this view's state: never in a draft, the pending outbox or a log; the field is empty before the
/// request goes, and when the page closes. A failed send asks for it again.
struct DiscordBotPage: View {
    @Bindable var store: FleetStore
    let agent: String
    /// Add bot (true), or Fix token and Change token of the agent's bot (false).
    let adding: Bool
    /// The agent's bot in the Channels page's last reading; nil until Save adds it.
    let bot: ChatAppsSnapshot.Account?
    /// Adds the bot to team.json, or gives the bot that the agent has: its account ID.
    let addBot: () async throws -> String
    let refresh: () async -> Void
    let close: () -> Void
    @State private var token = ""
    @State private var sending = false
    @State private var problem: String?
    /// The hub time of the token's send: only a bridge report after it is about the new token.
    @State private var sentAt: Double?
    @State private var invited = false
    /// On a bot that is connected, he asked to change its token.
    @State private var changing = false
    @FocusState private var focused: Bool
    private let client = ChatAppsClient()
    private static let portal = URL(string: "https://discord.com/developers/applications")!

    private enum Page { case token, connecting, invite, done }

    private var name: String { ChatAppWords.agent(agent) }
    private var progress: DiscordProgress { DiscordProgress(bot: bot, sentAt: sentAt) }
    /// The bot's own name on Discord, once the bridge has said it.
    private var botName: String {
        if case .connected(let said) = progress { return said }
        return bot?.name ?? name
    }
    private var canInvite: Bool { bot?.isConnected == true && bot?.inviteURL != nil }

    private var page: Page {
        if sending { return .connecting }
        switch progress {
        case .connecting: return .connecting
        // A token changed on a bot that is on a server already needs no invite.
        case .connected: return invited || !canInvite || !adding ? .done : .invite
        case .refused: return .token
        case .paste:
            if !adding, bot?.isConnected == true, !changing { return .done }
            return .token
        }
    }

    var body: some View {
        // Back to the channels stands at the page's top left, where every setup page has it.
        SetupPage {
            SetupBack(action: close).keyboardShortcut(.cancelAction).accessibilityIdentifier("discord-back")
        } step: {
            Group {
                switch page {
                case .token: paste
                case .connecting:
                    SetupStep(title: String(l10n: "Connecting \(name)'s bot"), waits: true) { mark }
                        .accessibilityIdentifier("discord-connecting")
                case .invite: inviting
                case .done: done
                }
            }.animation(.easeInOut(duration: 0.18), value: page)
        }
        .foregroundStyle(FleetStyle.text)
        // The token never outlives the page.
        .onDisappear { token = "" }
    }

    /// Discord's own mark, over every step.
    private var mark: some View {
        BrandMark(app: "discord", size: SetupMetrics.mark).foregroundStyle(BrandMark.color("discord"))
    }

    // MARK: one — the bot and its token

    /// What he does in the Developer Portal, before the paste: a new bot of the agent's name, not public, and its token;
    /// for Fix token and Change token, a new token of the bot he has.
    private var steps: SetupSteps {
        let portal = String(l10n: "Open the [Developer Portal](\(Self.portal.absoluteString))")
        return adding
            ? SetupSteps([portal, String(l10n: "New Application › name it \(name) › Bot"), String(l10n: "Turn off Public Bot, then Reset Token"),
                          String(l10n: "Copy the token")])
            : SetupSteps([portal, String(l10n: "Open \(name)'s application › Bot › Reset Token"), String(l10n: "Copy the token")])
    }

    private var paste: some View {
        SetupStep(title: adding ? String(l10n: "Add a Discord bot for \(name)") : String(l10n: "Paste the bot's token")) { mark } content: {
            steps
            // Its placeholder in the muted words that read, with the cursor in it too (fix rounds 2 and 3, item 58 and 3).
            SecureField(text: $token, prompt: Text(verbatim: "")) { Text("Bot token") }
                .fieldPlaceholder(String(l10n: "Bot token"), shows: token.isEmpty)
                .setupField(focus: $focused)
                .onSubmit { Task { await save() } }
                // A paste arrives in one change of many characters, and a token is never typed by hand.
                .onChange(of: token) { before, after in
                    if after.count - before.count >= 20, BotToken(pasted: after) != nil { Task { await save() } }
                }
                .task { focused = true }
                .accessibilityIdentifier("discord-token")
            if let line = problem ?? refusal {
                SetupWarning(line).help(bot?.error ?? "").accessibilityIdentifier("discord-problem")
            }
            if !token.isEmpty, store.isFresh {
                Button("Save") { Task { await save() } }
                    .buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("discord-save")
            }
        }
    }

    /// Why the bot did not connect: after this page's send, or before it when Fix token opened the page.
    private var refusal: String? {
        switch progress {
        case .refused(let reason): return String(l10n: "\(reason) · Paste it again")
        case .paste where !adding && bot?.isEnabled == true && ["error", "logged_out", "missing_token"].contains(bot?.state):
            return bot?.state == "missing_token" ? String(l10n: "No token") : ChatApps.shortReason(bot?.error)
        default: return nil
        }
    }

    // MARK: two — the server

    private var inviting: some View {
        SetupStep(title: String(l10n: "Add \(botName) to your server")) { mark } content: {
            Button("Invite to server") { invite() }
                .buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("discord-invite")
        }
    }

    // MARK: three — connected

    /// **Connected, said so that it cannot be missed**: the bot's name in the title, and each step this page took
    /// ticked. Opened again on a bot that is connected, no step is this page's to tick: Change token and Invite to
    /// server are under Done, in the words of the card's own menu.
    private var done: some View {
        SetupStep(title: String(l10n: "\(botName) is connected")) { mark } content: {
            if sentAt != nil {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(stepsDone, id: \.self) { step in
                        Label {
                            Text(step).foregroundStyle(FleetStyle.text)
                        } icon: {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                }.accessibilityIdentifier("discord-steps-done")
                if invited { Text("Send it a direct message on Discord.").foregroundStyle(FleetStyle.muted) }
            }
            Button("Done", action: close)
                .buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("discord-done")
            if sentAt == nil {
                SetupLink(String(l10n: "Change token")) { changing = true }.accessibilityIdentifier("discord-change-token")
                if canInvite { SetupLink(String(l10n: "Invite to server")) { invite() }.accessibilityIdentifier("discord-invite-again") }
            }
        }
        .accessibilityIdentifier("discord-connected")
    }

    /// The steps of this page that were done, in their own titles.
    private var stepsDone: [String] {
        guard adding else { return [String(l10n: "Paste the token")] }
        return [String(l10n: "Make the bot"), String(l10n: "Paste the token")] + (invited ? [String(l10n: "Add it to your server")] : [])
    }

    private func invite() {
        guard let url = bot?.inviteURL else { return }
        NSWorkspace.shared.open(url)
        invited = true
    }

    /// The token, once: the field is empty before a request goes. Without a bot, Save adds it first. A send that
    /// failed, or whose answer did not come, asks for the token again.
    private func save() async {
        guard store.isFresh, !sending, let db = store.state?.db else { return }
        let pasted = BotToken(pasted: token)
        token = ""
        guard let pasted else { problem = String(l10n: "Not a bot token · Copy it again"); return }
        sending = true; problem = nil
        defer { sending = false }
        do {
            let id = try await addBot()
            // The hub's time now: its last state's time and the time since that reading.
            let at = (store.state?.time ?? 0) + Date().timeIntervalSince(store.lastSuccess ?? Date())
            _ = try await client.saveToken(hub: store.hub, database: db, client: store.installation, account: id, token: pasted)
            sentAt = at
            await refresh()
        } catch {
            problem = error is URLError ? String(l10n: "No answer from the hub · Paste it again if the bot does not connect")
                : String(l10n: "\(ChatAppWords.reason(error)) Paste it again.")
        }
    }
}
