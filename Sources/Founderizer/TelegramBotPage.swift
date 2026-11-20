import AppKit
import FleetCore
import SwiftUI

/// The Telegram page of an agent's Channels (CHAT-APPS.md 19; the owner's "Yes, build it" of 15 November 2026 to its
/// picture), in place of the cards, with a Channels back link. **One centered step on a page, as the Discord page**
/// (`SetupPage`, `SetupStep`):
///
///   1. **Add a Telegram bot for Mia** ("Paste the bot's token" for Fix token and Change token): what he does with
///      @BotFather as short steps (`SetupSteps`), the first with its link, and under them the secure field, which sends a
///      pasted token by itself (Save shows for one typed by hand). While the bridge connects the bot, the title is its
///      moving words. A Telegram bot needs no server, so there is no invite step.
///   2. For a new bot, the steps that all three apps share (`ChannelFollowSteps`): "Write to Mia from your Telegram",
///      "Who else can write to Mia?" and "Mia is on Telegram", with Done. A hub that does not serve the people keeps
///      **@bot is connected**, the steps done, and Done.
///
/// Opened from the card of a bot that is connected (Change token), the page is the bot's connected state, with Change
/// token under it; Fix token opens on the token step. Save adds the account `telegram-<agent>` when the agent has no bot
/// yet, then sends the token to the hub once (`POST /ui/chat-apps/<id>/token`). The token is only in this view's state:
/// never in a draft, the pending outbox or a log; the field is empty before the request goes, and when the page closes.
/// A failed send asks for it again.
struct TelegramBotPage: View {
    @Bindable var store: FleetStore
    let agent: String
    /// Connect, for an agent with no bot (true), or Fix token and Change token of the agent's bot (false).
    let adding: Bool
    /// The agent's bot in the Channels page's last reading; nil until Save adds it.
    let bot: ChatAppsSnapshot.Account?
    /// The hub serves the people: a new bot's steps go on to the ones that all three apps share.
    var follows = false
    /// Adds the bot to team.json, or gives the bot that the agent has: its account ID.
    let addBot: () async throws -> String
    let refresh: () async -> Void
    let close: () -> Void
    @State private var token = ""
    @State private var sending = false
    @State private var problem: String?
    /// The hub time of the token's send: only a bridge report after it is about the new token.
    @State private var sentAt: Double?
    /// On a bot that is connected, he asked to change its token.
    @State private var changing = false
    /// The steps that the apps share showed: they stay, whatever the bridge says of the bot while it connects again.
    @State private var following = false
    @FocusState private var focused: Bool
    private let client = ChatAppsClient()
    private static let botFather = URL(string: "https://t.me/BotFather")!

    private enum Page { case token, connecting, done }

    private var name: String { ChatAppWords.agent(agent) }
    private var progress: DiscordProgress { DiscordProgress(bot: bot, sentAt: sentAt) }
    /// The bot's own name on Telegram, once the bridge has said it: its username with Telegram's @.
    private var botName: String {
        if case .connected(let said) = progress { return "@" + said }
        return bot?.name.map { "@" + $0 } ?? name
    }

    private var page: Page {
        if sending { return .connecting }
        switch progress {
        case .connecting: return .connecting
        case .connected: return .done
        case .refused: return .token
        case .paste:
            if !adding, bot?.isConnected == true, !changing { return .done }
            return .token
        }
    }

    var body: some View {
        Group {
            if following || (adding && follows && page == .done) {
                // A new bot that is connected: the owner's own link, who else, and the end.
                ChannelFollowSteps(store: store, app: "telegram", agent: agent, flow: true, refresh: refresh, close: close)
            } else {
                // Back to the channels stands at the page's top left, where every setup page has it.
                SetupPage {
                    SetupBack(action: close).keyboardShortcut(.cancelAction).accessibilityIdentifier("telegram-back")
                } step: {
                    Group {
                        switch page {
                        case .token: paste
                        case .connecting:
                            SetupStep(title: String(l10n: "Connecting \(name)'s bot"), waits: true) { mark }
                                .accessibilityIdentifier("telegram-connecting")
                        case .done: done
                        }
                    }.animation(.easeInOut(duration: 0.18), value: page)
                }
                .foregroundStyle(FleetStyle.text)
            }
        }
        .onChange(of: adding && follows && page == .done, initial: true) { _, now in if now { following = true } }
        // The token never outlives the page.
        .onDisappear { token = "" }
    }

    /// Telegram's own mark, over every step.
    private var mark: some View {
        BrandMark(app: "telegram", size: SetupMetrics.mark).foregroundStyle(BrandMark.color("telegram"))
    }

    // MARK: one — the bot and its token

    /// What he does with @BotFather, before the paste: a new bot of the agent's name and its token; for Fix token and
    /// Change token, a new token of the bot he has.
    private var steps: SetupSteps {
        let father = String(l10n: "In Telegram, open [@BotFather](\(Self.botFather.absoluteString))")
        return adding
            ? SetupSteps([father, String(l10n: "Send /newbot › name it \(name) › give it a username that ends in bot"),
                          String(l10n: "Copy the token")])
            : SetupSteps([father, String(l10n: "Send /token › choose \(botName)"), String(l10n: "Copy the token")])
    }

    private var paste: some View {
        SetupStep(title: adding ? String(l10n: "Add a Telegram bot for \(name)") : String(l10n: "Paste the bot's token")) { mark } content: {
            steps
            // Its placeholder in the muted words that read, with the cursor in it too, as on the Discord page.
            SecureField(text: $token, prompt: Text(verbatim: "")) { Text("Bot token") }
                .fieldPlaceholder(String(l10n: "Bot token"), shows: token.isEmpty)
                .setupField(focus: $focused)
                .onSubmit { Task { await save() } }
                // A paste arrives in one change of many characters, and a token is never typed by hand.
                .onChange(of: token) { before, after in
                    if after.count - before.count >= 20, BotToken(telegram: after) != nil { Task { await save() } }
                }
                .task { focused = true }
                .accessibilityIdentifier("telegram-token")
            if let line = problem ?? refusal {
                SetupWarning(line).help(bot?.error ?? "").accessibilityIdentifier("telegram-problem")
            }
            if !token.isEmpty, store.writesNow {
                Button("Save") { Task { await save() } }
                    .buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("telegram-save")
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

    // MARK: two — connected

    /// **Connected, said so that it cannot be missed**: the bot's name in the title, and the steps this page took ticked.
    /// Opened again on a bot that is connected, Change token is under Done, in the words of the card's own menu.
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
                }.accessibilityIdentifier("telegram-steps-done")
            }
            Button("Done", action: close)
                .buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("telegram-done")
            if sentAt == nil {
                SetupLink(String(l10n: "Change token")) { changing = true }.accessibilityIdentifier("telegram-change-token")
            }
        }
        .accessibilityIdentifier("telegram-connected")
    }

    /// The steps of this page that were done, in their own titles.
    private var stepsDone: [String] {
        adding ? [String(l10n: "Make the bot"), String(l10n: "Paste the token")] : [String(l10n: "Paste the token")]
    }

    /// The token, once: the field is empty before a request goes. Without a bot, Save adds it first. A send that
    /// failed, or whose answer did not come, asks for the token again.
    private func save() async {
        guard store.writesNow, !sending, let db = store.state?.db else { return }
        let pasted = BotToken(telegram: token)
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
