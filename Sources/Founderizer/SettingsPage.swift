import FleetCore
import SwiftUI

/// The sections of the Settings page, in its own sidebar. It takes the place of the hub connection popover and of the
/// Reporting lines, Projects and System status sheets.
///
/// **There is no Access section.** It listed every secret, repository, account and MCP server the fleet holds, each
/// one already a row of its own section here — Secrets, Apps — with the same detail behind it (the owner,
/// 24 October 2026: "there shouldn't even be an Access section, right? it's all done in each specific section!").
///
/// **Ten sections, in the owner's map of 28 October 2026** (D-4, "the whole map"): the servers and his own devices are
/// one section, Servers, and the fleet's and this Mac's updates another, Updates;
/// they were three pages of the main sidebar. The MCP servers are a group of Apps, where the other apps his agents
/// work in are.
enum SettingsTab: String, CaseIterable, Hashable {
    case general, servers, updates, backup, status, secrets, knowledge, apps, people, team

    /// A section by its name, also by the names of the pages that became parts of a section: `mcps` is Apps,
    /// `subscription`, which is gone, Updates and `devices` Servers.
    static func named(_ name: String) -> SettingsTab? {
        switch name {
        case "mcps": .apps
        case "subscription": .updates
        case "devices": .servers
        default: SettingsTab(rawValue: name)
        }
    }

    var title: String {
        switch self {
        case .general: "General"
        case .servers: "Servers"
        case .updates: "Updates"
        case .backup: "Backup"
        case .secrets: "Secrets"
        case .knowledge: "Knowledge"
        case .apps: "Apps"
        case .people: "People"
        case .team: "Reporting lines"
        case .status: "System status"
        }
    }

    /// One symbol for each section, and none that another place of the window has: General's gear was the Settings
    /// row's own, and Apps' grid was the Dashboard's.
    var symbol: String {
        switch self {
        case .general: "switch.2"
        case .servers: "server.rack"
        case .updates: "arrow.down.circle"
        case .backup: "clock.arrow.circlepath"
        case .secrets: "key"
        case .knowledge: "books.vertical"
        case .apps: "puzzlepiece.extension"
        case .people: "person.crop.circle"
        case .team: "arrow.triangle.branch"
        case .status: "waveform.path.ecg"
        }
    }

    /// The sections that this hub offers. Two of them are always there: General, which is this Mac's own
    /// settings, and System status, which answers whether this Mac reaches the hub at all — and carries the one
    /// field that puts that right, so it has to be reachable exactly when nothing else is.
    static func available(features: [String]) -> [SettingsTab] {
        allCases.filter { tab in
            switch tab {
            case .general: true
            case .backup: true
            case .status: true
            case .servers: features.contains(Servers.feature) || features.contains("machines")
                || features.contains(OwnerDevices.feature)
            // It reads the releases route.
            case .updates: features.contains(ReleaseState.feature)
            case .secrets: features.contains("secrets")
            case .knowledge: features.contains(KnowledgeClient.feature)
            case .apps: features.contains(Integrations.feature) || features.contains(Google.feature)
                || features.contains(MCP.feature)
            case .people: features.contains(People.feature)
            case .team: features.contains("reporting_lines")
            }
        }
    }
}

/// The app's and the team's settings, in the window: a sidebar of their own with a row for each section, and the open
/// section at the right, under its title. Each team form keeps its own Save, conflict and request lines.
struct SettingsPage: View {
    @Bindable var store: FleetStore
    let tab: SettingsTab
    /// A page of the section that takes its place, with the section still selected: a server's page, Add server.
    var detail: AnyView? = nil
    let select: (SettingsTab) -> Void
    /// The fleet's channels, read by the page and not by the section they decide the existence of.
    ///
    /// **A view whose body can be empty cannot read anything of its own.** The section used to hold this read in
    /// its own `.task`, and the moment its body became conditional the view resolved to nothing, SwiftUI
    /// installed no task, the read never happened — so the condition stayed false for ever. Whatever decides
    /// that a block is not there has to live outside the block.
    ///
    /// The store keeps it (`FleetStore.reading`), so both sections are there in the first frame when he comes back.
    private var channels: ChatAppsSnapshot? {
        get { store.reading("channels.snapshot") } nonmutating set { store.keep(newValue, as: "channels.snapshot") }
    }
    /// When General first asked for the channels, and whether that read has answered. Until it has, General draws
    /// neither of its sections, for at most a second, so the two come in one frame: Channels came 311 ms after
    /// Notifications on the owner's Mac.
    @State private var asked: ContinuousClock.Instant?
    @State private var answered = false
    /// Owner feature `default_models`: each provider's default and the models that its servers report, read by the
    /// page for the same reason as the channels, and kept by the store.
    private var defaults: DefaultModelsPage? {
        get { store.reading("defaults.page") } nonmutating set { store.keep(newValue, as: "defaults.page") }
    }
    /// The default models, read before General first opens (`PagePrefetch`), as the channels are (`AgentPage.prefetch`):
    /// the page's first visit drew its title alone for the 430 ms that this read took, and then its sections
    /// (10 November 2026).
    static let defaultsPrefetch = PagePrefetch("defaults.page", feature: DefaultModels.feature) {
        try await DefaultModelsClient().read(hub: $0, database: $1)
    }

    var body: some View {
        let tabs = SettingsTab.available(features: store.state?.ui_features ?? [])
        let shown = tabs.contains(tab) ? tab : .general
        HStack(spacing: 0) {
            PageSidebar(items: tabs.map { .init(value: $0, title: $0.title, symbol: $0.symbol) }, selection: shown,
                        identifier: "settings-tab", select: select) {
                // On the page title's line (margins row 3).
                Text("Settings").font(FormMetrics.title).accessibilityAddTraits(.isHeader)
                    .padding(.top, FormMetrics.sidebarHeadingTop - FleetSpace.lights - FleetSpace.back)
            }
            Rule(vertical: true)
            // Each section is a page of its own and brings its own title and actions: the shell adds no second
            // header and no second column.
            Group {
                if let detail, shown == tab {
                    detail
                } else {
                    switch shown {
                    case .general: FleetPage("General") { general }
                    case .servers: ServersPage(store: store)
                    case .updates: UpdatesPage(store: store)
                    case .backup: BackupSettings(store: store)
                    case .secrets: SecretsPage(store: store)
                    case .knowledge: KnowledgePage(store: store)
                    case .apps: AppsPage(store: store)
                    case .people: PeoplePage(store: store)
                    case .team: TeamEditor(store: store)
                    case .status: HealthView(store: store)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // **The generation is a version, not an identity.** Every write of the owner's that touches the
            // configuration — a secret, a grant, a profile — commits it and gives the fleet a new generation, so a
            // page keyed by it was destroyed and built again at the moment of the owner's own save. He saw the
            // screen blink and come back, and SwiftUI aborted the app on the third one: a field still held the
            // keyboard, and the responder chain reached the view that had just gone (`swift_abortRetainUnowned`,
            // 22 October 2026). The reading below follows the generation; the view does not.
            .id("\(store.hub)/\(shown.rawValue)")
            .pageNotices(store)
            // The title and the header's button stand where every page has them (`columnPull`).
            .environment(\.columnPull, (FleetStyle.pageSidebarWidth + 1) / 2)
        }
        .task(id: "\(store.hub)/\(store.state?.db ?? "")/\(shown.rawValue)/\(generalReads)") {
            let features = store.state?.ui_features ?? []
            let chat = features.contains(ChatApps.feature), models = features.contains(DefaultModels.feature)
            guard shown == .general, chat || models else { return }
            asked = .now
            while !Task.isCancelled {
                if let db = store.state?.db {
                    let hub = store.hub
                    // both reads at once, so that the two sections come in one frame
                    async let chatRead = chat ? try? await ChatAppsClient().read(hub: hub, database: db) : nil
                    async let modelsRead = models ? try? await DefaultModelsClient().read(hub: hub, database: db) : nil
                    let (freshChannels, freshDefaults) = await (chatRead, modelsRead)
                    if store.state?.db == db {
                        if let freshChannels { channels = freshChannels }
                        if let freshDefaults { defaults = freshDefaults }
                    }
                }
                if !Task.isCancelled { answered = true }
                do { try await store.nap(15) } catch { return }
            }
        }
    }

    /// Which of General's two readings the hub offers: a hub that gains one while the page shows starts its loop again.
    private var generalReads: String {
        let features = store.state?.ui_features ?? []
        return "\(features.contains(ChatApps.feature))/\(features.contains(DefaultModels.feature))"
    }

    /// The channels or the default models are offered and not read yet on this page.
    private var channelsWait: Bool {
        let features = store.state?.ui_features ?? []
        return !answered && (features.contains(ChatApps.feature) && channels == nil ||
                             features.contains(DefaultModels.feature) && defaults == nil)
    }

    /// What is left here is what he sets: when Founderizer tells him something, and whether his agents receive
    /// messages. The hub's address, its connection and its generation were all here on 20 October 2026 and none
    /// of them was his to set — "this hub generation is useless for the user", "I have no idea why we need to
    /// show the user and give it the option to change it! I only want to know if everything is connected like in
    /// the System Status". The connection is now one mark on System status, which carries the address with it;
    /// the generation is this app's own concurrency token and is nowhere he reads, which is where a token belongs.
    @ViewBuilder private var general: some View {
        if channelsWait {
            if let asked { Held(since: asked) { sections } }
        } else {
            sections
        }
    }

    @ViewBuilder private var sections: some View {
        Group {
            FormSection("Notifications") {
                // No line under it (D-2): the row's words say what it does.
                FormRow("Tell me when I am needed", symbol: "bell", warning: store.notifications.status) {
                    Toggle("Tell me when I am needed", isOn: Binding(get: { store.notifications.enabled },
                                                                    set: { _ in Task { await store.notifications.toggle() } }))
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                        .disabled(store.notifications.requestingPermission).accessibilityIdentifier("notification-toggle")
                }
                .help(store.notifications.status == nil ? "" : store.notifications.cause ?? "")
            }
            // Owner feature default_models: a row for each provider that his servers report, and for one whose default
            // stays set while none does. No section while there is no row.
            if let defaults, !defaults.runtimes.isEmpty {
                DefaultModelsSection(store: store, page: defaults) { self.defaults = $0 }
            }
            // A channel of his, anywhere in the fleet. Until there is one there is nothing to pause, so there
            // is no section — not an empty one, and not one that reports a bridge he has no use for.
            if let channels, !channels.accounts.isEmpty {
                ChannelsSettings(store: store, channels: channels).id(store.hub)
            }
        }
    }
}

/// The provider whose card shows over Settings › General, by its runtime.
private struct ShownProvider: Identifiable { let id: String }

/// Settings › General › Default models (owner feature `default_models`, owner API 1.108): for each AI provider that his
/// fleet runs, the model and the reasoning that an agent without its own gets. The owner, 9 November 2026: "There
/// should be a default for each somewhere under settings, and then each agent can be changed individually".
///
/// **One row for each provider, and its own card** (the owner, 10 November 2026, of two menus side by side on each row:
/// "both dropdowns there don't make any sense!! what do they even mean? ... what if we have multiple AI providers, it
/// will be a mess!! I would configure each one individually", and his yes to the drawing): the row is the provider's
/// icon, its name and its choice in a few words ("Automatic", "Opus · High") with the chevron of a row that opens; a
/// click opens the provider's card, with Done, a Model menu and a Reasoning menu under their names, "Automatic" first
/// in each. An agent's own choice stays under AI provider › Change on its page, where "Default (Opus)" is the first
/// option.
private struct DefaultModelsSection: View {
    @Bindable var store: FleetStore
    let page: DefaultModelsPage
    let reloaded: (DefaultModelsPage) -> Void
    @State private var states: [String: SaveState] = [:]
    /// The newest value of each row that the hub's page does not hold yet: on its way, waiting behind the one on its
    /// way, or not saved (refused, or with no answer) and kept for Try again.
    @State private var wanted: [String: ModelDefault] = [:]
    /// The request of a save that got no answer, which Try again sends again as the same request.
    @State private var unanswered: [String: String] = [:]
    /// The rows with a save on its way: one at a time each, so two quick picks cannot pass each other.
    @State private var sending: Set<String> = []
    /// When each row's last save was answered: a page that still lacks that value well after it was changed elsewhere.
    @State private var answered: [String: Date] = [:]
    @State private var saves: [String: Int] = [:]
    /// The provider whose card is open.
    @State private var open: ShownProvider?
    private static let client = DefaultModelsClient()

    var body: some View {
        FormSection("Default models") {
            ForEach(page.runtimes, id: \.self) { runtime in row(runtime) }
        }
        .onChange(of: page.defaults) { _, defaults in settle(defaults) }
        .fleetModal(item: $open) { card($0.id) }
        // `-openProvider <runtime>` opens one provider's card, so that it can be looked at without a click to it, as
        // `-openResource` opens a repository's.
        .onAppear { if open == nil { open = UserDefaults.standard.string(forKey: "openProvider").map(ShownProvider.init) } }
    }

    /// One provider: its icon, its name and its choice, and a click opens its card. A save that failed says so here
    /// too, for a card that he closed before its answer came; its Try again is in the card.
    private func row(_ runtime: String) -> some View {
        let words = summary(runtime)
        return Button { open = ShownProvider(id: runtime) } label: {
            FormRow(providerName(runtime), mark: ProviderIcon(runtime: runtime, size: 18), warning: states[runtime]?.failure) {
                HStack(spacing: 8) {
                    Text(words).foregroundStyle(FleetStyle.muted).lineLimit(1)
                    Image(systemName: "chevron.right").font(IconMetrics.symbol(11, weight: .semibold)).foregroundStyle(FleetStyle.muted)
                }
            }
        }
        .buttonStyle(FleetRowButtonStyle())
        .accessibilityLabel(providerName(runtime))
        .accessibilityValue(words)
        .accessibilityHint("Opens its model and reasoning")
        .accessibilityIdentifier("default-models-\(runtime)")
    }

    /// The choice in a few words: the model's name or Automatic, and the reasoning after a dot where one is chosen.
    private func summary(_ runtime: String) -> String {
        let value = shown(runtime)
        let model = value.model.map { name in page.models[runtime]?.first { $0.model == name }?.display_name ?? name }
        return ([model ?? automaticChoice] + [value.effort.map(reasoningName)].compactMap { $0 }).joined(separator: " · ")
    }

    /// **The provider's card** (the owner's yes of 10 November 2026): its icon and name with Done, then Model and
    /// Reasoning, each a menu under its own name. A pick saves at once, as the row's two menus did; the card says
    /// Saving…, Saved or Try again beside Done, and a refusal's words under the menus.
    private func card(_ runtime: String) -> some View {
        let value = shown(runtime)
        let options = page.models[runtime] ?? []
        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                ProviderIcon(runtime: runtime, size: 30)
                Text(providerName(runtime)).font(FormMetrics.title).lineLimit(1).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                SaveMark(state: states[runtime]) { retry(runtime) }
                Button("Done") { open = nil }.buttonStyle(FleetOutlineButtonStyle()).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("default-models-done")
            }
            FormSection {
                FormRow("Model") {
                    FleetSelect("Model", selection: Binding(get: { value.model ?? "" }, set: { name in
                        let next = name.isEmpty ? nil : name
                        guard next != value.model else { return }
                        // the reasoning stays where the new model offers it, else it goes back to Automatic
                        let effort = value.effort.flatMap { DefaultModels.efforts(options, for: next).contains($0) ? $0 : nil }
                        choose(runtime, ModelDefault(model: next, effort: effort))
                    }), options: Self.models(options, current: value.model))
                        .disabled(!store.isFresh).accessibilityIdentifier("default-model-\(runtime)")
                }
                FormRow("Reasoning") {
                    FleetSelect("Reasoning", selection: Binding(get: { value.effort ?? "" }, set: { level in
                        let next = level.isEmpty ? nil : level
                        guard next != value.effort else { return }
                        choose(runtime, ModelDefault(model: value.model, effort: next))
                    }), options: Self.efforts(page.efforts(runtime, for: value.model), current: value.effort))
                        .disabled(!store.isFresh).accessibilityIdentifier("default-effort-\(runtime)")
                }
            }
            if let failure = states[runtime]?.failure {
                Text(failure).font(FormMetrics.detail).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(22).frame(width: 440)
        .font(FleetStyle.body).foregroundStyle(FleetStyle.text)
    }

    /// Automatic, the models his servers report, and a saved model that none of them reports now.
    private static func models(_ options: [RuntimeModels.Option], current: String?) -> [FleetOption<String>] {
        [FleetOption("", automaticChoice)] +
            options.map { FleetOption($0.model, $0.display_name, subtitle: $0.default ? "The provider's default" : nil) } +
            (current.map { name in options.contains { $0.model == name } ? [] : [FleetOption(name, name, subtitle: "Not offered now")] } ?? [])
    }

    /// Automatic, the levels that the model takes, and a saved level that it does not take.
    private static func efforts(_ levels: [String], current: String?) -> [FleetOption<String>] {
        [FleetOption("", automaticChoice)] + levels.map { FleetOption($0, reasoningName($0)) } +
            (current.map { levels.contains($0) ? [] : [FleetOption($0, reasoningName($0), subtitle: "Not offered for this model")] } ?? [])
    }

    /// The value on its way; the hub's once a save of it failed, beside Try again, which sends the failed one again.
    private func shown(_ runtime: String) -> ModelDefault {
        if states[runtime]?.failure == nil, let value = wanted[runtime] { return value }
        return page.defaults[runtime] ?? ModelDefault()
    }

    private func choose(_ runtime: String, _ value: ModelDefault) {
        guard store.isFresh else { return }
        wanted[runtime] = value
        unanswered[runtime] = nil
        states[runtime] = .saving
        if !sending.contains(runtime) { Task { await drain(runtime) } }
    }

    private func retry(_ runtime: String) {
        guard store.isFresh, wanted[runtime] != nil, !sending.contains(runtime) else { return }
        states[runtime] = .saving
        Task { await drain(runtime) }
    }

    /// The saves of one row, one at a time: a value that he picked while one was on its way goes next, and only the
    /// newest one's answer marks the row.
    private func drain(_ runtime: String) async {
        guard let database = store.state?.db else { states[runtime] = nil; return }
        sending.insert(runtime)
        defer { sending.remove(runtime) }
        var latest: DefaultModelsPage?
        var sent: ModelDefault?
        while let value = wanted[runtime], value != sent {
            sent = value
            let id = unanswered[runtime] ?? UUID().uuidString.lowercased()
            states[runtime] = .saving
            do {
                _ = try await Self.client.save(hub: store.hub, database: database, client: store.installation,
                                               runtime: runtime, value: value, requestID: id)
                unanswered[runtime] = nil
                guard wanted[runtime] == value else { continue }        // a newer value waits: it goes next
                answered[runtime] = .now
                let save = saves[runtime, default: 0] + 1
                saves[runtime] = save
                states[runtime] = .saved
                Task { try? await Task.sleep(for: .seconds(3)); if saves[runtime] == save, states[runtime] == .saved { states[runtime] = nil } }
                // The row keeps its value until a page that holds it comes: this read, or the page's next one.
                if let fresh = try? await Self.client.read(hub: store.hub, database: database), store.state?.db == database {
                    latest = fresh
                    reloaded(fresh)
                }
            } catch let HubError.refusal(_, words) {
                guard wanted[runtime] == value else { continue }
                states[runtime] = .failed(words)
            } catch {
                guard wanted[runtime] == value else { continue }
                unanswered[runtime] = id
                states[runtime] = .failed("The hub has not answered. Try again sends the same request.")
            }
        }
        // The page that this save read came while the row still sent, so `settle` passed it over: it does it now.
        sending.remove(runtime)
        if let latest { settle(latest.defaults) }
        await store.refresh()
    }

    /// A page that holds a row's value ends its wait, and also a save with no answer that took effect. One that still
    /// lacks a saved value ten seconds after the answer shows the hub's: it was changed elsewhere.
    private func settle(_ defaults: [String: ModelDefault]) {
        for (runtime, value) in wanted where !sending.contains(runtime) {
            if (defaults[runtime] ?? ModelDefault()) == value {
                wanted[runtime] = nil
                unanswered[runtime] = nil
                if states[runtime]?.failure != nil { states[runtime] = nil }
            } else if states[runtime]?.failure == nil, let at = answered[runtime], Date.now.timeIntervalSince(at) > 10 {
                wanted[runtime] = nil
                states[runtime] = .changedElsewhere
            }
        }
    }
}

/// Settings > General > Channels: the one switch that is his and is about the whole fleet — do his agents
/// receive messages from WhatsApp and Discord at all.
///
/// **It is not there until he has a channel.** The owner, 20 October 2026, with a screenshot of this row reading
/// "Receive messages · No bridge" with the switch on: "what is even that?? I would not show it, I dont
/// understand what it does, we discussed that...". He was right twice over. His fleet has no WhatsApp number and
/// no Discord bot, so the switch paused nothing, and the orange "No bridge" reported a fault he did not have —
/// there is nothing for a bridge to carry. A channel is connected on the agent's own Channels page, which is
/// where the offer belongs; this section is only the pause that no one agent's page could hold, and it shows when
/// there is something to pause.
///
/// The bridge's own state went with the dot. It is not the owner's to fix from here, and each account's card on
/// the agent's Channels page already says what the bridge last reported about that account, where he acts on it.
private struct ChannelsSettings: View {
    @Bindable var store: FleetStore
    /// What the page read. The section does not read it: see `SettingsPage.channels`.
    let channels: ChatAppsSnapshot
    @State private var sending = false
    @State private var problem: String?
    private let client = ChatAppsClient()

    private var paused: Bool { store.state?.chat_apps?.paused ?? channels.paused }

    var body: some View {
        FormSection("Channels") {
            // A line only while it is paused (D-2): the switch says the rest.
            FormRow("Receive messages", symbol: "antenna.radiowaves.left.and.right",
                    detail: paused ? "Paused: nothing comes in and nothing goes out." : nil,
                    warning: problem) {
                HStack(spacing: 14) {
                    if sending { ProgressView().controlSize(.small) }
                    Toggle("Receive messages", isOn: Binding(get: { !paused },
                                                             set: { on in Task { await setPaused(!on) } }))
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                        .disabled(sending || !store.isFresh)
                        .accessibilityIdentifier("settings-receive-messages")
                }
            }
        }
    }

    private func setPaused(_ value: Bool) async {
        guard store.isFresh, !sending, let db = store.state?.db else { return }
        sending = true; problem = nil
        defer { sending = false }
        do {
            _ = try await client.pause(hub: store.hub, database: db, client: store.installation, paused: value)
        } catch { problem = ChatAppWords.reason(error) }
        await store.refresh()
    }
}

/// Settings > Backup: the whole of what he sets about the copies this Mac keeps.
///
/// **A switch and a route, and nothing else.** The owner, 20 October 2026, looking at this card when it also
/// carried a sentence about when the next copy was due, a How often dropdown and a three-line footer about what a
/// copy holds: "I've talked about this so many times! Dont add more fields or elements!! Just enable/disable
/// switch (on by default) and a route. Remove the 3 lines explaining it at the bottom, come on!". So the card is
/// those two rows. The switch is on for a fleet that has never been asked (`CopyDefault.on`) and the folder is
/// taken for him, so the ordinary fleet keeps copies without him setting anything at all.
///
/// What the three lines said has not been lost, it has been put where it is read instead of skipped: the save
/// panel says what a copy holds at the moment he names the file, and every copy carries its own `RESTORE.md`,
/// which is the only list that can be right about the copy it is inside. Every day one sentence stood here and
/// every day it was the same sentence, which is how a warning becomes wallpaper.
private struct CopySettings: View {
    @Bindable var keeper: FleetCopyKeeper

    var body: some View {
        FormSection("A copy of your fleet") {
            // The failure stays: a copy that quietly stopped is the one thing a backup must never keep to
            // itself, and it is a row that is there only when there is something to say.
            FormRow("Keep a copy automatically", symbol: "clock.arrow.circlepath",
                    warning: keeper.schedule.on ? keeper.schedule.failure : nil) {
                HStack(spacing: 10) {
                    if keeper.busy { ProgressView().controlSize(.small) }
                    Toggle("Keep a copy automatically", isOn: Binding(get: { keeper.schedule.on },
                                                                     set: { keeper.setOn($0) }))
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                        .accessibilityIdentifier("copy-automatic")
                }
            }
            if keeper.schedule.on {
                FormRow("Where", symbol: "folder", detail: keeper.shownFolderName) {
                    HStack(spacing: FleetSpace.actions) {
                        if FleetCopyKeeper.iCloudDrive != nil, !keeper.holdsICloud {
                            Button("Use iCloud Drive") { keeper.useICloud() }
                                .buttonStyle(FleetOutlineButtonStyle())
                                .accessibilityIdentifier("copy-icloud")
                        }
                        Button(keeper.shownFolderName == nil ? "Choose a folder" : "Change\u{2026}") { keeper.choose() }
                            .buttonStyle(FleetOutlineButtonStyle())
                            .accessibilityIdentifier("copy-folder")
                    }.fixedSize()
                }
            }
        }
    }
}

/// Settings > Backup: everything about a copy of his fleet, in one place of its own.
///
/// The owner, 20 October 2026: "The copy of your fleet and the auto updates should probably be on its own Backup
/// section". They were in two places and neither was one he would look for — the switch was a card at the bottom
/// of General, and the copy itself was behind a Details fold on System status. A backup is one subject, so it is
/// one section: what is kept automatically, where it goes, the copy he takes himself, and the way back.
///
/// System status keeps one thing about copies and only one: the cross that says a copy he asked for is not being
/// kept. That is a fault, and faults are what that page answers.
struct BackupSettings: View {
    @Bindable var store: FleetStore
    @State private var copy = FleetCopyModel()
    @State private var restore = RestoreModel()

    var body: some View {
        FleetPage("Backup") {
            CopySettings(keeper: store.copies)
            // The way back. `restore` is its own feature: a hub from before owner API 1.5's second half serves
            // the copy routes and not this one, and the app offers nothing a hub cannot do.
            if RestoreOffer.inHealth(store.state) {
                FormSection {
                    RestoreRows(store: store, model: restore, go: { store.destination = $0 },
                                explains: false)
                }
            }
        } actions: {
            // `isFresh`, not `canWrite`: taking the copy is a GET and confirming it goes straight to the hub,
            // neither through the outbox. A refused request waiting there must not block the one button that
            // stands between him and losing his fleet.
            // **Only while it can act** (never grey): not while the hub does not answer, and while the copy is being
            // taken its place says so in moving words.
            if copy.busy {
                ShimmeringWords(text: "Saving\u{2026}").accessibilityIdentifier("backup-saving-copy")
            } else if store.isFresh {
                Button(FleetHealth.Warning.Act.saveCopy.label) { Task { await copy.save(store: store) } }
                    .buttonStyle(FleetPrimaryButtonStyle())
                    .accessibilityIdentifier("backup-save-copy")
            }
        }
        .font(FleetStyle.body).background(FleetStyle.canvas)
    }
}
