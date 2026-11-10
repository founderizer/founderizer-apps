import AppKit
import FleetCore
import SwiftUI

/// One agent's Channels (CHAT-APPS.md 17, owner feature `chat_apps`): where the owner can message it. Two cards,
/// WhatsApp and Discord, each with the agent's own account (`ChannelCard`): one status, at most one main button, and
/// a "…" menu. Add number writes the account `whatsapp-<agent>` and shows its QR code in the card until the phone
/// links. Add bot, Fix token and Change token open the Discord page (`DiscordBotPage`) in place of the cards. The
/// first time for an app, while the owner has no ID there, the connected card first shows the owner's link code.
/// The page reads the accounts every 5 seconds while it shows, every 2 while a QR code, a code or the Discord page
/// shows, and a number's link every 2 seconds while its QR code shows.
struct ChannelsPage: View {
    @Bindable var store: FleetStore
    let agent: String
    /// Each reading of the accounts, for the People dot of the agent's sidebar.
    var onRead: (ChatAppsSnapshot) -> Void = { _ in }
    /// **The first group of the agent's People** (D-5): its heading, its line and its two cards, without a page of its
    /// own.
    var grouped = false
    /// The Discord page, kept by the part around this group, which shows it in its own place (`AgentPeoplePart`): nil
    /// keeps it here.
    var discord: Binding<Bool?>? = nil
    /// The readings are the store's (`FleetStore.reading`), under this agent's name: the cards he saw last show in the
    /// first frame when he comes back, and the read that starts then changes only what changed.
    private var snapshot: ChatAppsSnapshot? {
        get { store.reading("channels.accounts.\(agent)") } nonmutating set { store.keep(newValue, as: "channels.accounts.\(agent)") }
    }
    private var people: PeopleSnapshot? {
        get { store.reading("channels.people.\(agent)") } nonmutating set { store.keep(newValue, as: "channels.people.\(agent)") }
    }
    private var readAt: Date? {
        get { store.reading("channels.read_at.\(agent)") } nonmutating set { store.keep(newValue, as: "channels.read_at.\(agent)") }
    }
    @State private var readError: String?
    @State private var busy: String?
    @State private var message: (text: String, warning: Bool)?
    /// The number whose QR code shows, its last link reading, and when Fleet asked for a code: until the bridge
    /// answers, an older state of the link does not show.
    @State private var linking: String?
    @State private var link: ChatLinkReading?
    @State private var linkError: String?
    @State private var linkAsked: Date?
    /// Numbers whose waiting link the owner cancelled on this page.
    @State private var cancelled: Set<String> = []
    /// The Discord page shows in place of the cards; `true` when it adds the bot.
    @State private var ownDiscord: Bool?
    private var discordPage: Bool? {
        get { discord?.wrappedValue ?? ownDiscord }
        nonmutating set { if let discord { discord.wrappedValue = newValue } else { ownDiscord = newValue } }
    }
    /// The owner link code of each app that this page made, and the apps for which it asked for one.
    @State private var codes: [String: OpenCode] = [:]
    @State private var asked: Set<String> = []
    @State private var making: Set<String> = []
    private let client = ChatAppsClient()

    private struct OpenCode {
        let code: LinkCode
        let before: Set<String>
        let made: Date
    }

    /// The accounts and the people, read when the agent's chat first opens (`PagePrefetch`).
    static let prefetch = PagePrefetch(agent: { "channels.accounts.\($0)" }, feature: ChatApps.feature) { hub, database, _ in
        try await ChatAppsClient().read(hub: hub, database: database)
    }
    static let peoplePrefetch = PagePrefetch(agent: { "channels.people.\($0)" }, feature: ChatApps.peopleFeature) { hub, database, _ in
        try await ChatAppsClient().people(hub: hub, database: database)
    }

    private var name: String { ChatAppWords.agent(agent) }
    private var canChange: Bool { store.isFresh && busy == nil && snapshot?.sha256 != nil }
    private var serverTime: Double? { store.state?.time }
    private var peopleOffered: Bool { store.state?.ui_features?.contains(ChatApps.peopleFeature) == true }
    private var paused: Bool { store.state?.chat_apps?.paused ?? snapshot?.paused ?? false }

    var body: some View {
        Group {
            if let adding = discordPage {
                DiscordBotPage(store: store, agent: agent, adding: adding, bot: snapshot?.channel("discord", of: agent),
                               addBot: addBot, refresh: { await read() }, close: { discordPage = nil })
            } else if grouped {
                VStack(alignment: .leading, spacing: FleetSpace.inside) {
                    Text("Channels").font(FormMetrics.heading).foregroundStyle(FleetStyle.text)
                        .frame(minHeight: FormMetrics.headingRow).padding(.leading, 2).accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: FleetSpace.block) { cards }
                }
            } else {
                FleetPage("Channels") { cards }
            }
        }
        .task(id: "\(store.hub)/\(store.state?.db ?? "")/\(agent)") {
            readError = nil; message = nil; linking = nil; cancelled = []
            // The Discord page that the part keeps stays open: this view is made again as it opens and closes.
            if discord == nil { ownDiscord = nil }
            codes = [:]; asked = []; making = []
            let start = ContinuousClock.now
            while !Task.isCancelled {
                await read(since: start)
                var waited = 0
                repeat {
                    // A wake reads at once; else the step of one second keeps the wait short once a link starts.
                    do { if try await store.nap(1) { break } } catch { return }
                    waited += 1
                } while waited < (linking == nil && discordPage == nil && codes.isEmpty ? 5 : 2)
            }
        }
        .task(id: linking) {
            link = nil; linkError = nil
            while let account = linking, !Task.isCancelled {
                await readLink(account)
                do { try await store.nap(2) } catch { return }
            }
        }
    }

    /// The page's line and its two cards, or what stands in their place while they are not read.
    @ViewBuilder private var cards: some View {
        status
        if snapshot != nil {
            ForEach(ChatApps.apps, id: \.self) { card($0) }
        } else if readError != nil || store.connectionError != nil {
            // While the hub does not answer nothing is read: the failed row, never "Reading…". **Not while the
            // window's notice says the outage** (`FleetStore.hubNoticeShows`; fix round 3, item 33: it is said once).
            if !store.hubNoticeShows {
                FormSection { FormRow("Not read", symbol: "exclamationmark.circle", warning: readError) }
            }
        } else {
            LoadingLine("Reading the channels…")
        }
    }

    // MARK: status

    /// One line at a time: the change that waits, its result, an old reading, or Pause all.
    @ViewBuilder private var status: some View {
        if let busy {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(busy) }
                .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
        } else if let message {
            Text(message.text).font(FormMetrics.detail).foregroundStyle(message.warning ? .orange : FleetStyle.muted)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("channels-status")
        } else if let readError, snapshot != nil {
            Label("Last reading \(readAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? "")", systemImage: "exclamationmark.circle")
                .font(FormMetrics.detail).foregroundStyle(.orange).help(readError)
        } else if snapshot != nil, !store.isFresh, let readAt {
            Label("Last reading \(readAt.formatted(date: .omitted, time: .shortened))", systemImage: "exclamationmark.circle")
                .font(FormMetrics.detail).foregroundStyle(.orange)
        } else if paused {
            Label("Paused in Settings", systemImage: "pause.circle").font(FormMetrics.detail).foregroundStyle(.orange)
                .help("No message comes in or goes out. Turn on Receive messages in Settings > General.")
        }
    }

    // MARK: cards

    /// The QR code of a number shows while the owner asked for it, or while the hub's link waits for a scan.
    private func isLinking(_ account: ChatAppsSnapshot.Account?) -> Bool {
        guard let account, account.app == "whatsapp" else { return false }
        return linking == account.id || (account.link?.state == "waiting" && !cancelled.contains(account.id))
    }

    private func card(_ app: String) -> some View {
        let account = snapshot?.channel(app, of: agent)
        let card = ChannelCard(app: app, agent: agent, in: snapshot, linking: isLinking(account), serverTime: serverTime)
        return FormSection {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    BrandMark(app: app, size: 28).foregroundStyle(BrandMark.color(app)).frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(card.title).font(FormMetrics.title).foregroundStyle(FleetStyle.text).lineLimit(1)
                            .help(card.kind == .connected ? account?.name ?? account?.user ?? "" : "")
                        ChannelStatusLine(status: card.status, spinning: card.kind == .connecting).accessibilityIdentifier("channels-state-\(app)")
                    }
                    Spacer(minLength: 8)
                    if let action = card.action {
                        Button(words(action)) { perform(action, card) }.buttonStyle(FleetPrimaryButtonStyle()).disabled(!canChange)
                            .accessibilityIdentifier("channels-\(action.rawValue)")
                    }
                    if !card.menu.isEmpty { menu(card) }
                }
                if card.kind == .linking, let account { qrBlock(account) }
                if peopleOffered, let account, let ignored = people?.ignored(of: account.id) { wrote(ignored) }
                if peopleOffered, card.asksForOwnerLink(people), let account {
                    let open = codes[app]
                    OwnerLinkStep(store: store, app: app, code: open?.code, target: open?.code.target(preferring: [account.id]),
                                  making: making.contains(app), canRenew: canChange && !making.contains(app),
                                  renew: { Task { await makeCode(app) } })
                }
            }
            .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 14)
            .accessibilityElement(children: .contain).accessibilityIdentifier("channels-card-\(app)")
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
        if ignored.messages.isEmpty { return "\(ignored.today) wrote today and were not answered" }
        if ignored.today > 0 { return "Wrote and was not answered · \(ignored.today) today" }
        return "Wrote and was not answered"
    }

    private func words(_ action: ChannelCard.Action) -> String {
        switch action {
        case .addNumber: "Add number"
        case .linkAgain: "Link again"
        case .addBot: "Add bot"
        case .fixToken: "Fix token"
        case .turnOn: "Turn on"
        }
    }

    private func perform(_ action: ChannelCard.Action, _ card: ChannelCard) {
        message = nil
        switch action {
        case .addNumber: Task { await addNumber() }
        case .linkAgain: if let id = card.account?.id { Task { await startLink(id) } }
        case .addBot: discordPage = true
        case .fixToken: discordPage = false
        case .turnOn: if let id = card.account?.id { Task { await turnOn(id) } }
        }
    }

    /// The bridge's QR code while the number waits for a scan. It changes by itself until the phone links.
    private func qrBlock(_ number: ChatAppsSnapshot.Account) -> some View {
        HStack(alignment: .top, spacing: 18) {
            if linkAsked == nil, let link, link.state == "waiting", let qr = link.qr, !qr.isEmpty {
                QRCodeView(text: qr, size: 168).accessibilityIdentifier("channels-qr-\(number.id)")
            } else {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the code").font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                }.frame(width: 188, height: 188).background(FleetStyle.canvas, in: RoundedRectangle(cornerRadius: FormMetrics.inner))
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Open WhatsApp on the phone with this number › Settings › Linked devices › Link a device.")
                    .font(FormMetrics.text).foregroundStyle(FleetStyle.text).fixedSize(horizontal: false, vertical: true)
                // Not while the window's notice says the outage (`FleetStore.hubNoticeShows`).
                if let linkError, !store.hubNoticeShows {
                    Label("Code not read", systemImage: "exclamationmark.circle").font(FormMetrics.detail).foregroundStyle(.orange).help(linkError)
                }
                Button("Cancel") { cancelled.insert(number.id); linking = nil; linkAsked = nil }
                    .buttonStyle(.plain).font(FormMetrics.text).foregroundStyle(FleetStyle.muted)
                    .accessibilityIdentifier("channels-cancel-link")
            }
        }
    }

    /// The card's other actions, behind a "…" capsule.
    private func menu(_ card: ChannelCard) -> some View {
        let options: [FleetOption<ChannelCard.MenuItem>] = card.menu.map { item in
            switch item {
            case .invite: FleetOption(item, "Invite to server", mark: .symbol("person.badge.plus"))
            case .changeToken: FleetOption(item, "Change token", mark: .symbol("key"))
            case .unlink: FleetOption(item, "Unlink", mark: .symbol("iphone.slash"))
            case .remove: FleetOption(item, card.app == "whatsapp" ? "Remove number" : "Remove bot", mark: .symbol("trash"),
                                      destructive: true)
            }
        }
        let title = "More \(ChatApps.title(card.app)) actions"
        return FleetSelect(title, options: options, onSelect: { item in
            message = nil
            switch item {
            case .invite: if let url = card.account?.inviteURL { NSWorkspace.shared.open(url) }
            case .changeToken: discordPage = false
            case .unlink: if let account = card.account { Task { await unlink(account) } }
            case .remove: if let account = card.account { Task { await remove(account) } }
            }
        }) {
            Image(systemName: "ellipsis").frame(height: 15)
        }
        .buttonStyle(FleetOutlineButtonStyle()).disabled(!canChange).help(title)
        .accessibilityIdentifier("channels-menu-\(card.app)")
    }

    // MARK: changes

    /// Add number: the account, then its QR code at once. The bridge reports a new number first (wa-link says that it
    /// has no device); then Fleet asks for the code, after at most 20 seconds in any case.
    private func addNumber() async {
        guard let id = await save("Adding…", { current in
            guard current.channel("whatsapp", of: agent) == nil else { return nil }
            let choice = ChatApps.agentAccount(app: "whatsapp", agent: agent, taken: Set(current.accounts.map(\.id)))
            return (choice.id, choice.account)
        }) else { return }
        cancelled.remove(id); link = nil; linkAsked = Date(); linking = id
        var waited = 0
        while waited < 20, snapshot?.accounts.first(where: { $0.id == id })?.state == nil {
            do { try await store.nap(1) } catch { return }
            guard linking == id else { return }
            await read()
            waited += 1
        }
        guard linking == id else { return }
        await startLink(id)
    }

    /// The Discord page's Save, for an agent without a bot: the account `discord-<agent>` first.
    private func addBot() async throws -> String {
        guard let current = snapshot else { throw HubError.invalidResponse }
        if let bot = current.channel("discord", of: agent) { return bot.id }
        guard let id = try await write({ current in
            guard current.channel("discord", of: agent) == nil else { return nil }
            let choice = ChatApps.agentAccount(app: "discord", agent: agent, taken: Set(current.accounts.map(\.id)))
            return (choice.id, choice.account)
        }) else { throw HubError.invalidResponse }
        await read()
        return id
    }

    private func startLink(_ id: String) async {
        guard store.isFresh, let db = store.state?.db else { return }
        cancelled.remove(id)
        do {
            _ = try await client.link(hub: store.hub, database: db, client: store.installation, account: id)
            link = nil; linkAsked = Date(); linking = id
        } catch {
            message = (ChatAppWords.reason(error), true)
            if linking == id { linking = nil; linkAsked = nil }
        }
    }

    private func unlink(_ number: ChatAppsSnapshot.Account) async {
        guard canChange, let db = store.state?.db else { return }
        busy = "Unlinking…"
        do {
            _ = try await client.link(hub: store.hub, database: db, client: store.installation, account: number.id, unlink: true)
            cancelled.insert(number.id)
        } catch { message = (ChatAppWords.reason(error), true) }
        busy = nil
        await read()
    }

    private func turnOn(_ id: String) async {
        _ = await save("Turning on…") { current in
            guard var input = current.accounts.first(where: { $0.id == id }).map(ChatAccountInput.init), !input.enabled else { return nil }
            input.enabled = true
            return (id, input)
        }
    }

    private func remove(_ account: ChatAppsSnapshot.Account) async {
        guard await save("Removing…", { current in current.accounts.contains { $0.id == account.id } ? (account.id, nil) : nil }) != nil
        else { return }
        if linking == account.id { linking = nil }
        codes[account.app] = nil
        message = ("Removed", false)
    }

    /// One account write with the busy words, and the hub's refusal as the status line.
    private func save(_ words: String, _ choose: (ChatAppsSnapshot) -> (id: String, account: ChatAccountInput?)?) async -> String? {
        guard canChange else { return nil }
        busy = words; message = nil
        defer { busy = nil }
        do {
            let saved = try await write(choose)
            await read()
            return saved
        } catch {
            message = (ChatAppWords.reason(error), true)
            await read()
            return nil
        }
    }

    /// One account write against the team.json version that the page read. `choose` gives the account ID and the
    /// account (nil removes it) from the current accounts, or nil when nothing is left to do; on 409 the page reads
    /// again and asks once more. It gives the ID that the hub saved.
    private func write(_ choose: (ChatAppsSnapshot) -> (id: String, account: ChatAccountInput?)?) async throws -> String? {
        guard store.isFresh, var current = snapshot, let db = store.state?.db else { return nil }
        let hub = store.hub, installation = store.installation
        for attempt in 1...2 {
            guard let choice = choose(current), let sha = current.sha256 else { return nil }
            do {
                _ = try await client.saveAccount(hub: hub, database: db, client: installation, sha256: sha, id: choice.id, account: choice.account)
                return choice.id
            } catch HubError.refusal(409, _) where attempt == 1 {
                current = try await client.read(hub: hub, database: db)
            }
        }
        return nil
    }

    // MARK: the owner's link

    private func makeCode(_ app: String) async {
        guard store.isFresh, peopleOffered, let db = store.state?.db, let people else { return }
        asked.insert(app); codes[app] = nil; making.insert(app)
        defer { making.remove(app) }
        do {
            let code = try await client.makeCode(hub: store.hub, database: db, client: store.installation, app: app)
            guard store.state?.db == db else { return }
            codes[app] = OpenCode(code: code, before: Set(people.handles(of: app).map(\.key)), made: Date())
        } catch { message = (ChatAppWords.reason(error), true) }
    }

    // MARK: reading

    /// The accounts, and the people with them: a first reading draws its cards whole, in one frame.
    private func read(since start: ContinuousClock.Instant? = nil) async {
        guard let db = store.state?.db else { return }
        let hub = store.hub, started = Date(), first = snapshot == nil
        var accounts: ChatAppsSnapshot?, reason: String?
        do { accounts = try await client.read(hub: hub, database: db) } catch { reason = ChatAppWords.reason(error) }
        let readPeople = peopleOffered && (accounts ?? snapshot) != nil ? try? await client.people(hub: hub, database: db) : nil
        if first, let start { await store.settle(since: start) }
        guard store.hub == hub, store.state?.db == db else { return }
        if let accounts {
            snapshot = accounts; readAt = Date(); readError = nil
            onRead(accounts)
        } else { readError = reason }
        guard let snapshot else { return }
        // A number whose link waits for a scan shows its QR code, also after the page opened again.
        if linking == nil, let number = snapshot.channel("whatsapp", of: agent), number.link?.state == "waiting",
           !number.isConnected, !cancelled.contains(number.id) {
            linking = number.id
        }
        guard peopleOffered else { return }
        if let fresh = readPeople {
            // A code that the hub took binds the sender: a new ID of that app, or a code that the hub no longer has.
            for (app, open) in codes where fresh.bound(app, before: open.before, codeOpen: started > open.made.addingTimeInterval(1)
                && ChatApps.remaining(expires: open.code.expires, serverTime: store.state?.time ?? 0,
                                      readAt: store.lastSuccess ?? started, now: started) > 0) {
                codes[app] = nil
            }
            people = fresh
        }
        // The first time for an app: the connected card makes the owner's code by itself, once.
        for app in ChatApps.apps where !asked.contains(app) && store.isFresh {
            let card = ChannelCard(app: app, agent: agent, in: snapshot, linking: false, serverTime: serverTime)
            if card.asksForOwnerLink(people) { await makeCode(app) }
        }
    }

    private func readLink(_ account: String) async {
        guard let db = store.state?.db else { return }
        do {
            let reading = try await client.link(hub: store.hub, database: db, account: account)
            guard linking == account else { return }
            link = reading; linkError = nil
            if let asked = linkAsked, reading.state == "waiting" || reading.state == "linked" || Date().timeIntervalSince(asked) > 30 {
                linkAsked = nil
            }
            guard linkAsked == nil else { return }
            // Linked, or the link ended: the card shows the number's state again.
            if reading.state == "linked" {
                linking = nil
                await read()
            } else if reading.state == "error" || reading.state == "logged_out" {
                cancelled.insert(account); linking = nil
                await read()
            }
        } catch { linkError = ChatAppWords.reason(error) }
    }
}
