import AppKit
import FleetCore
import SwiftUI

/// One agent's Channels (CHAT-APPS.md 17 and 18, owner feature `chat_apps`): where the owner and the people can message
/// it. Three cards, WhatsApp, Discord and Telegram (on a hub that serves it, CHAT-APPS.md 19), each with the agent's
/// own account (`ChannelCard`). **A channel that is not
/// connected is its mark, its name and Connect** (the owner's "Yes, build it" of 14 November 2026 to the mock of the
/// whole experience): Connect opens the app's steps in place of the cards (`ChannelSetup`: `WhatsAppSetupPage`,
/// `DiscordBotPage`, then the steps that both share, `ChannelFollowSteps`). A connected card has the number or the
/// bot's name, one status and a "…" menu, whose first line is the owner's own link while it is still to do.
///
/// **No line stands outside a card** (the owner, the same day: "it shows Removed outside of the card all the time"):
/// a change that worked is the card's new state, a change on its way is the card's own status with its spinner, and
/// only a refusal is a line, in the hub's words, in its card. Over the cards stand only what is about the reading
/// itself: an old reading, and Paused in Settings. **A connected card has the row "People outside the org"**
/// (`OutsidersRow`; the owner's "Yes, build it" of 26 November 2026, and his correction of the same day): Ignore or As
/// customers, written to the account at once, and under it only the lines that its pictures draw.
/// The page reads the accounts every 5 seconds while it shows, and every 2 while a channel's steps show.
struct ChannelsPage: View {
    @Bindable var store: FleetStore
    let agent: String
    /// **The first group of the agent's People** (D-5): its heading and its two cards, without a page of its own.
    var grouped = false
    /// A channel's steps, kept by the part around this group, which shows them in its own place (`AgentPeoplePart`):
    /// nil keeps them here.
    var setup: Binding<ChannelSetup?>? = nil
    /// The readings are the store's (`FleetStore.reading`), for the whole fleet: the cards he saw last show in the
    /// first frame when he comes back, and the read that starts then changes only what changed. A channel's steps read
    /// the same two names.
    private var snapshot: ChatAppsSnapshot? { store.reading(AgentPage.channelsName) }
    private var people: PeopleSnapshot? {
        (store.reading(PeoplePage.peopleName) as PeopleReading<PeopleSnapshot>?)?.value
    }
    private var readAt: Date? { store.readingDate(AgentPage.channelsName) }
    @State private var readError: String?
    /// When the first of the reads that failed in a row failed: one break of them says nothing
    /// (`FleetStore.pageReadingIsOld`).
    @State private var failedSince: ContinuousClock.Instant?
    /// The words of the reads that failed, once they have failed one whole break.
    private var saidError: String? { readError.flatMap { store.pageReadingIsOld(failedSince: failedSince) ? $0 : nil } }
    /// The change that is on its way, by its app: that card's status says it.
    @State private var busy: (app: String, words: String)?
    /// What the hub refused, by its app: one line in that app's card.
    @State private var refused: [String: String] = [:]
    @State private var ownSetup: ChannelSetup?
    private var steps: ChannelSetup? {
        get { setup?.wrappedValue ?? ownSetup }
        nonmutating set { if let setup { setup.wrappedValue = newValue } else { ownSetup = newValue } }
    }
    private let client = ChatAppsClient()

    private var name: String { ChatAppWords.agent(agent) }
    private var canChange: Bool { store.writesNow && busy == nil && snapshot?.sha256 != nil }
    private var serverTime: Double? { store.state?.time }
    private var peopleOffered: Bool { store.state?.ui_features?.contains(ChatApps.peopleFeature) == true }
    private var paused: Bool { store.state?.chat_apps?.paused ?? snapshot?.paused ?? false }

    var body: some View {
        Group {
            switch steps {
            case .whatsApp:
                WhatsAppSetupPage(store: store, agent: agent, follows: peopleOffered, start: startNumber,
                                  remove: { id in await removeLeft(id) }, refresh: { await read() },
                                  close: { steps = nil })
            case .discord(let adding):
                DiscordBotPage(store: store, agent: agent, adding: adding, bot: snapshot?.channel("discord", of: agent),
                               follows: peopleOffered, addBot: { try await addBot("discord") }, refresh: { await read() },
                               close: { steps = nil })
            case .telegram(let adding):
                TelegramBotPage(store: store, agent: agent, adding: adding, bot: snapshot?.channel("telegram", of: agent),
                                follows: peopleOffered, addBot: { try await addBot("telegram") }, refresh: { await read() },
                                close: { steps = nil })
            case .me(let app):
                ChannelFollowSteps(store: store, app: app, agent: agent, flow: false, refresh: { await read() },
                                   close: { steps = nil })
            case nil:
                if grouped {
                    VStack(alignment: .leading, spacing: FleetSpace.inside) {
                        Text("Channels").font(FormMetrics.heading).foregroundStyle(FleetStyle.text)
                            .frame(minHeight: FormMetrics.headingRow).padding(.leading, 2).accessibilityAddTraits(.isHeader)
                        VStack(alignment: .leading, spacing: FleetSpace.block) { cards }
                    }
                } else {
                    FleetPage("Channels") { cards }
                }
            }
        }
        .task(id: "\(store.hub)/\(store.state?.db ?? "")/\(agent)") {
            readError = nil; failedSince = nil; refused = [:]; busy = nil
            // The steps that the part keeps stay open: this view is made again as they open and close.
            if setup == nil { ownSetup = nil }
            let start = ContinuousClock.now
            while !Task.isCancelled {
                await read(since: start)
                var waited = 0
                repeat {
                    // A wake reads at once; else the step of one second keeps the wait short once a channel's steps open.
                    do { if try await store.nap(1) { break } } catch { return }
                    waited += 1
                } while waited < (steps == nil ? 5 : 2)
            }
        }
    }

    /// The page's line and its two cards, or what stands in their place while they are not read.
    @ViewBuilder private var cards: some View {
        status
        if snapshot != nil {
            ForEach(ChatApps.shown(features: store.state?.ui_features), id: \.self) { card($0) }
        } else if saidError != nil || store.connectionError != nil {
            // While the hub does not answer nothing is read: the failed row, never "Reading…". **Not while the
            // window's notice says the outage** (`FleetStore.hubNoticeShows`; fix round 3, item 33: it is said once).
            // **One break of the hub says nothing** (17 November 2026): "Reading…" stays until then.
            if !store.hubNoticeShows {
                FormSection { FormRow("Not read", symbol: "exclamationmark.circle", warning: saidError) }
            }
        } else {
            LoadingLine(String(l10n: "Reading the channels…"))
        }
    }

    // MARK: status

    /// One line at a time, and only about the reading itself: an old reading, or Pause all. **One break of the hub says
    /// nothing** (17 November 2026), and an old reading is not said while the window's notice says the outage (fix round
    /// 3, item 33: it is said once).
    @ViewBuilder private var status: some View {
        if let saidError, snapshot != nil, !store.hubNoticeShows {
            Label("Last reading \(readAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? "")", systemImage: "exclamationmark.circle")
                .font(FormMetrics.detail).foregroundStyle(.orange).help(saidError)
        } else if snapshot != nil, !store.isFresh, !store.hubNoticeShows, let readAt {
            Label("Last reading \(readAt.formatted(date: .omitted, time: .shortened))", systemImage: "exclamationmark.circle")
                .font(FormMetrics.detail).foregroundStyle(.orange)
        } else if paused {
            Label("Paused in Settings", systemImage: "pause.circle").font(FormMetrics.detail).foregroundStyle(.orange)
                .help("No message comes in or goes out. Turn on Receive messages in Settings > General.")
        }
    }

    // MARK: cards

    private func card(_ app: String) -> some View {
        let account = snapshot?.channel(app, of: agent)
        let card = ChannelCard(app: app, agent: agent, in: snapshot, serverTime: serverTime)
        let items = card.menu(for: peopleOffered ? people : nil)
        return FormSection {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    BrandMark(app: app, size: 28).foregroundStyle(BrandMark.color(app)).frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(card.title).font(FormMetrics.title).foregroundStyle(FleetStyle.text).lineLimit(1)
                            .help(card.kind == .connected ? account?.name ?? account?.user ?? "" : "")
                            // A channel that is not connected draws no state: a reader of the screen hears it here.
                            .accessibilityValue(card.kind == .none ? card.status.words : "")
                        // A channel that is not connected is its name and Connect: it has no state to say.
                        if let busy, busy.app == app {
                            ChannelStatusLine(status: ChatStateWords(words: busy.words, tone: .waiting), spinning: true)
                                .accessibilityIdentifier("channels-state-\(app)")
                        } else if card.kind != .none {
                            ChannelStatusLine(status: card.status, spinning: card.kind == .connecting)
                                .accessibilityIdentifier("channels-state-\(app)")
                        }
                    }
                    Spacer(minLength: 8)
                    if let action = card.action {
                        Button(words(action)) { perform(action, card) }.buttonStyle(FleetPrimaryButtonStyle()).disabled(!canChange)
                            .accessibilityIdentifier("channels-\(action.rawValue)-\(app)")
                    }
                    if !items.isEmpty { menu(card, items) }
                }
                // What the hub refused of this card's last change, in the hub's words.
                if let why = refused[app] {
                    Text(why).font(FormMetrics.detail).foregroundStyle(.orange).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("channels-refused-\(app)")
                }
                if let row = OutsidersRow(card: card, agent: agent, in: store.state?.agents.first(where: { $0.name == agent }),
                                          features: store.state?.ui_features) {
                    outsiders(row, card)
                }
                if peopleOffered, let account, let ignored = people?.ignored(of: account.id) { wrote(ignored) }
            }
            .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 14)
            .accessibilityElement(children: .contain).accessibilityIdentifier("channels-card-\(app)")
        }
    }

    /// **People outside the org** (`OutsidersRow`): the account's rule for a sender who is not the owner and no person of
    /// the People page, one choice written at once, and under it, muted, each reason why the agent cannot take such a
    /// sender.
    private func outsiders(_ row: OutsidersRow, _ card: ChannelCard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "person.2").font(IconMetrics.symbol(12)).foregroundStyle(FleetStyle.muted).accessibilityHidden(true)
                Text("People outside the org").font(FormMetrics.title).foregroundStyle(FleetStyle.text)
                Spacer(minLength: 8)
                FleetSelect(String(l10n: "People outside the org"),
                            selection: Binding(get: { row.rule }, set: { rule in choose(rule, row, card) }),
                            options: OutsidersRow.Rule.allCases.map { FleetOption($0, $0.words) })
                    .disabled(!canChange)
                    .accessibilityIdentifier("channels-outsiders-\(card.app)")
            }
            if !row.facts.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(row.facts, id: \.self) { line in Text(line) }
                }
                .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine).accessibilityIdentifier("channels-outsiders-lines-\(card.app)")
            }
        }
    }

    /// Who wrote to this account and got no answer. Your agents answer you and nobody else, so a message from
    /// anyone else is counted and dropped — and this is the one place you can see that somebody tried.
    ///
    /// It is not a conversation: nothing here can answer them, and nothing in this fleet will.
    @ViewBuilder private func wrote(_ ignored: PeopleSnapshot.Ignored) -> some View {
        let messages = ignored.messages
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.questionmark").font(IconMetrics.symbol(12))
                    .foregroundStyle(FleetStyle.muted).accessibilityHidden(true)
                Text(title(ignored)).font(FormMetrics.title).foregroundStyle(FleetStyle.text)
                Spacer(minLength: 8)
            }
            ForEach(messages) { message in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(message.who).font(FormMetrics.detail).foregroundStyle(FleetStyle.text).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(activityAge(message.ts, now: serverTime ?? Date().timeIntervalSince1970)).font(FormMetrics.detail)
                            .foregroundStyle(FleetStyle.muted)
                    }
                    if let said = message.said {
                        Text(said).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("channels-ignored-\(message.id)")
            }
        }.accessibilityIdentifier("channels-ignored-\(ignored.account)")
    }

    private func title(_ ignored: PeopleSnapshot.Ignored) -> String {
        if ignored.messages.isEmpty { return String(l10n: "\(ignored.today) wrote today and were not answered") }
        if ignored.today > 0 { return String(l10n: "Wrote and was not answered · \(ignored.today) today") }
        return String(l10n: "Wrote and was not answered")
    }

    private func words(_ action: ChannelCard.Action) -> String {
        switch action {
        case .connect: String(l10n: "Connect")
        case .linkAgain: String(l10n: "Link again")
        case .fixToken: String(l10n: "Fix token")
        case .turnOn: String(l10n: "Turn on")
        }
    }

    private func perform(_ action: ChannelCard.Action, _ card: ChannelCard) {
        refused[card.app] = nil
        switch action {
        case .connect: steps = card.app == "whatsapp" ? .whatsApp : card.app == "telegram" ? .telegram(adding: true) : .discord(adding: true)
        case .linkAgain: steps = .whatsApp
        case .fixToken: steps = card.app == "telegram" ? .telegram(adding: false) : .discord(adding: false)
        case .turnOn: if let id = card.account?.id { Task { await turnOn(id, app: card.app) } }
        }
    }

    /// The card's other actions, behind a "…" capsule.
    private func menu(_ card: ChannelCard, _ items: [ChannelCard.MenuItem]) -> some View {
        let whatsApp = card.app == "whatsapp"
        let options: [FleetOption<ChannelCard.MenuItem>] = items.map { item in
            switch item {
            case .linkMe: FleetOption(item, whatsApp ? String(l10n: "Link my phone")
                                        : card.app == "telegram" ? String(l10n: "Link my Telegram") : String(l10n: "Link my Discord"),
                                      mark: .symbol(whatsApp ? "iphone" : "person.crop.circle.badge.checkmark"))
            case .invite: FleetOption(item, "Invite to server", mark: .symbol("person.badge.plus"))
            case .changeToken: FleetOption(item, "Change token", mark: .symbol("key"))
            case .unlink: FleetOption(item, "Unlink", mark: .symbol("iphone.slash"))
            case .remove: FleetOption(item, whatsApp ? "Remove number" : "Remove bot", mark: .symbol("trash"), destructive: true)
            }
        }
        let title = String(l10n: "More \(ChatApps.title(card.app)) actions")
        return FleetSelect(title, options: options, onSelect: { item in
            refused[card.app] = nil
            switch item {
            case .linkMe: steps = .me(app: card.app)
            case .invite: if let url = card.account?.inviteURL { NSWorkspace.shared.open(url) }
            case .changeToken: steps = card.app == "telegram" ? .telegram(adding: false) : .discord(adding: false)
            case .unlink: if let account = card.account { Task { await unlink(account) } }
            case .remove: if let account = card.account { Task { await remove(account.id, app: account.app) } }
            }
        }) {
            Image(systemName: "ellipsis").font(IconMetrics.symbol(13)).foregroundStyle(FleetStyle.muted)
        }
        .buttonStyle(FleetIconButtonStyle()).disabled(!canChange).help(title)
        .accessibilityIdentifier("channels-menu-\(card.app)")
    }

    // MARK: changes

    /// Connect and Link again of WhatsApp, for its first step: the number's account, written now when the agent has
    /// none, and the hub asked for its QR code. The bridge reports a new number first (wa-link says that it has no
    /// device); then Founderizer asks for the code, after at most 20 readings in any case. It gives the account's ID.
    /// `goesOn` is false once he left the step: the wait ends, and no code is asked for.
    private func startNumber(_ goesOn: @MainActor () -> Bool) async throws -> String {
        guard store.writesNow, snapshot != nil, let db = store.state?.db else { throw HubError.invalidResponse }
        var id = snapshot?.channel("whatsapp", of: agent)?.id
        if id == nil {
            let made = try await write { current in
                guard current.channel("whatsapp", of: agent) == nil else { return nil }
                let choice = ChatApps.agentAccount(app: "whatsapp", agent: agent, taken: Set(current.accounts.map(\.id)))
                return (choice.id, choice.account)
            }
            await read()
            id = made ?? snapshot?.channel("whatsapp", of: agent)?.id
            guard let new = id else { throw HubError.invalidResponse }
            var waited = 0
            while waited < 20, goesOn(), snapshot?.accounts.first(where: { $0.id == new })?.state == nil {
                _ = try await store.nap(1)
                await read()
                waited += 1
            }
        }
        guard goesOn() else { throw CancellationError() }
        guard let id else { throw HubError.invalidResponse }
        _ = try await client.link(hub: store.hub, database: db, client: store.installation, account: id)
        return id
    }

    /// The Discord or Telegram page's Save, for an agent without a bot: the account `discord-<agent>` (or
    /// `telegram-<agent>`) first.
    private func addBot(_ app: String) async throws -> String {
        guard let current = snapshot else { throw HubError.invalidResponse }
        if let bot = current.channel(app, of: agent) { return bot.id }
        guard let id = try await write({ current in
            guard current.channel(app, of: agent) == nil else { return nil }
            let choice = ChatApps.agentAccount(app: app, agent: agent, taken: Set(current.accounts.map(\.id)))
            return (choice.id, choice.account)
        }) else { throw HubError.invalidResponse }
        await read()
        return id
    }

    private func unlink(_ number: ChatAppsSnapshot.Account) async {
        guard canChange, let db = store.state?.db else { return }
        busy = (number.app, String(l10n: "Unlinking…"))
        do {
            _ = try await client.link(hub: store.hub, database: db, client: store.installation, account: number.id, unlink: true)
        } catch { refused[number.app] = ChatAppWords.reason(error) }
        busy = nil
        await read()
    }

    /// A choice of People outside the org: the account as the hub holds it, with this rule. The hub's refusal (As
    /// customers with no live Teams licence: `teams_off`) is the card's refusal line, in the hub's words.
    private func choose(_ rule: OutsidersRow.Rule, _ row: OutsidersRow, _ card: ChannelCard) {
        guard row.changes(to: rule), let id = card.account?.id else { return }
        Task {
            await save(String(l10n: "Saving…"), app: card.app) { current in
                guard var input = current.accounts.first(where: { $0.id == id }).map(ChatAccountInput.init),
                      input.unknown != rule.rawValue else { return nil }
                input.unknown = rule.rawValue
                return (id, input)
            }
        }
    }

    private func turnOn(_ id: String, app: String) async {
        await save(String(l10n: "Turning on…"), app: app) { current in
            guard var input = current.accounts.first(where: { $0.id == id }).map(ChatAccountInput.init), !input.enabled else { return nil }
            input.enabled = true
            return (id, input)
        }
    }

    /// Remove number and Remove bot, and a number that no phone linked when he leaves its steps. The card that is
    /// left says it: its mark, its name and Connect.
    private func remove(_ id: String, app: String) async {
        await save(String(l10n: "Removing…"), app: app) { current in current.accounts.contains { $0.id == id } ? (id, nil) : nil }
    }

    /// The removal that Back of the WhatsApp steps asks for, after a write that is on its way (30 looks at most). A
    /// removal that cannot go now leaves a number that no phone holds: its card says Connect, which takes it.
    private func removeLeft(_ id: String) async {
        var looks = 0
        while busy != nil, looks < 30 {
            try? await Task.sleep(for: .milliseconds(100))
            looks += 1
        }
        await remove(id, app: "whatsapp")
    }

    /// One account write: its words are its card's status while it is on its way, and the hub's refusal is that
    /// card's line.
    private func save(_ words: String, app: String, _ choose: (ChatAppsSnapshot) -> (id: String, account: ChatAccountInput?)?) async {
        guard canChange else { return }
        busy = (app, words); refused[app] = nil
        defer { busy = nil }
        do {
            _ = try await write(choose)
        } catch {
            refused[app] = ChatAppWords.reason(error)
        }
        await read()
    }

    /// One account write against the team.json version that the page read. `choose` gives the account ID and the
    /// account (nil removes it) from the current accounts, or nil when nothing is left to do; on 409 the page reads
    /// again and asks once more. It gives the ID that the hub saved.
    private func write(_ choose: (ChatAppsSnapshot) -> (id: String, account: ChatAccountInput?)?) async throws -> String? {
        guard store.writesNow, var current = snapshot, let db = store.state?.db else { return nil }
        let hub = store.hub, installation = store.installation
        for attempt in 1...2 {
            guard let choice = choose(current), let sha = current.sha256 else { return nil }
            do {
                _ = try await client.saveAccount(hub: hub, database: db, client: installation, sha256: sha, id: choice.id, account: choice.account)
                return choice.id
            } catch let error as HubError where attempt == 1 && ChatApps.triesAgain(after: error) {
                current = try await client.read(hub: hub, database: db)
            }
        }
        return nil
    }

    // MARK: reading

    /// The accounts, and the people with them: a first reading draws its cards whole, in one frame.
    private func read(since start: ContinuousClock.Instant? = nil) async {
        guard let db = store.state?.db else { return }
        let hub = store.hub, first = snapshot == nil, accountsStart = store.pageReadStart()
        var accounts: ChatAppsSnapshot?, reason: String?
        do { accounts = try await AgentPage.readAccounts(store, hub: hub, database: db, from: accountsStart) }
        catch { reason = ChatAppWords.reason(error) }
        guard !Task.isCancelled, store.hub == hub, store.state?.db == db else { return }
        let peopleStart = store.pageReadStart()
        var readPeople: PeopleReading<PeopleSnapshot>?
        if peopleOffered, (accounts ?? snapshot) != nil {
            // The channel client has a longer deadline than the People page. Share its accepted
            // result, and let HubReads join only requests with the same time limits.
            let people = try? await store.read(PeoplePage.peopleName + ".channels", from: peopleStart) { [client] in
                try await client.people(hub: hub, database: db)
            }
            if let people { readPeople = .current(people, at: store.state?.time ?? Date().timeIntervalSince1970) }
        }
        if first, let start { await store.settle(since: start) }
        guard !Task.isCancelled, store.hub == hub, store.state?.db == db else { return }
        if let accounts {
            if store.keep(accounts, as: AgentPage.channelsName, from: accountsStart) {
                readError = nil; failedSince = nil
            }
        } else if store.acceptsPageRead(accountsStart, for: AgentPage.channelsName) {
            readError = reason; failedSince = failedSince ?? .now
        }
        if peopleOffered, let readPeople { store.keep(readPeople, as: PeoplePage.peopleName, from: peopleStart) }
    }
}
