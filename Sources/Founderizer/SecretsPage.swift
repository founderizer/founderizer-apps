import FleetCore
import SwiftUI

/// One reading of the catalog (`GET /ui/team`, feature `secrets`) and of its use: which agents list each reference in
/// their profile (the older grant). The store keeps the fleet's as "secrets.logins.fleet", which a card's badge reads
/// too (`FleetStore.showSecret(named:)`).
struct LoginReading: Sendable {
    let catalog: [String: TeamLogin]
    /// False: the hub's answer had no catalog that Fleet can read.
    let hasCatalog: Bool
    /// The version of team.json that this reading has: a removal goes against it.
    let sha256: String
    /// By reference: the agents whose profile lists it. nil: the profiles were not read.
    let listed: [String: [String]]?

    init(team: TeamSnapshot, profiles: [AgentProfile]?) {
        catalog = team.logins ?? [:]; hasCatalog = team.logins != nil; sha256 = team.sha256
        listed = profiles.map { list in
            list.reduce(into: [:]) { result, profile in
                for reference in Set(Self.references(in: profile.sections.first { $0.key == "logins" }?.text ?? "")) {
                    result[reference, default: []].append(profile.agent)
                }
            }
        }
    }

    /// The `bws://<uuid>` references in a text, in the hub's one spelling (lower case).
    static func references(in text: String) -> [String] {
        let pattern = "bws://[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { text[$0].lowercased() } }
    }

    /// The agents that have one secret: a grant, or a profile that lists it, in the hub's order (`SecretsList.holders`).
    func holders(_ reference: String, _ entry: TeamLogin, agents: [String]) -> [String] {
        SecretsList.holders(of: reference, entry, agents: agents, listed: listed)
    }
}

/// What an agent's control of an API key offers.
private enum SecretChoice: Hashable { case use, read, none }

/// **The secret whose detail shows over the page, by its reference**: a row's of this page, and over any page the card
/// that a request's badge opens (`FleetStore.secretCard`, `showSecret(named:)`).
struct SecretCard: Identifiable, Equatable { let id: String }

/// **A change of several secrets that works now** (the bar of the fleet's Secrets page): what it does, how many calls
/// it makes and how many are done, and the secrets that it still changes, whose rows show a spinner at their end.
private struct BulkWork: Equatable {
    let change: SecretsList.Change
    /// The calls of the plan; 0 while the page reads the catalog once more before it makes the plan.
    let total: Int
    var done = 0
    var open: Set<String>
}

/// **The bar of the fleet's Secrets page, kept by the store** as the page's readings are (`FleetStore.pageModel`): the
/// ticks, the change that works now, the bar's orange line and a Delete's line over the list. A change goes on while
/// he is on another page, and when he comes back the page shows its bar and waits for it; another hub or hub
/// generation has a bar of its own, so a change of the old one never shows there.
@MainActor @Observable final class SecretsBar {
    var ticked: Set<String> = []
    fileprivate var work: BulkWork?
    var line: String?
    var removed: String?
}

/// The secrets of the fleet (features `secrets` and `secret_grants`): one list of the logins and API keys, by name. A
/// click on a row opens its detail over the page, which a click outside closes: each agent with its access and its
/// control. Give lets the agent's vault use the secret for it (`use`; the agent never sees it); Take back ends that. An
/// API key that an agent has also offers `read`, with its warning: the key is then in the agent's sessions. A secret
/// that no agent and no profile has can be removed from Fleet; its value stays in the vaults. Add secret opens its
/// form in the window, with the agents that get the new secret; the form owns the save into the central vault and the
/// grants. The detail also shows each server whose vault holds this secret, and who may give it, as a repository's and
/// an MCP server's detail do (`StandingRows`). Each grant and each change of who may give a secret is signed with the
/// owner key too (`GrantSigning`), because the central vault seals a secret only for what the owner signed.
///
/// **An agent's own Secrets is this same list, with `agent`, as a group of its Can use** (the owner, 25 October 2026:
/// "Secrets, mcps, Knowledge... they should have the same format between them AND also the same format as the main
/// Settings"; and his yes of 28 October 2026 to D-5, one editor for each kind): the same rows and the same detail, only
/// the secrets that agent has, with a + that gives it one more and a − on each row that takes one back (the owner, 3
/// November 2026); a secret is added in Settings › Secrets, and its detail, which the agent's row opens too, gives it to
/// every agent. The fleet's central vault is not this agent's, so its rows are not
/// there.
///
/// **The fleet's own list filters, shows each secret's holders, and changes several secrets at once** (the owner, 20
/// November 2026, and "yes as drawn" to its picture; `SecretsList` decides each part): under the header, a filter by
/// words (each secret's name and note, case and accents folded) and by agents (a menu of several ticks); each row with a
/// tick at its start and the faces of the agents that hold it, overlapping, then their names; and with a tick, a bar at
/// the bottom of the page that gives the ticked secrets to agents, takes them back, or deletes the ones that nobody
/// holds, one call at a time, with its count and a spinner on each row that it still changes. An agent's own Secrets
/// keeps its rows as they were.
struct SecretsPage: View {
    @Bindable var store: FleetStore
    /// One agent's own: only the secrets it has. nil is the fleet's own list.
    var agent: String?
    /// A group of the agent's Can use: the heading with its + (`giveMenu`), and the rows, each with its −, or the empty
    /// card when the agent has none.
    var grouped = false
    /// **The detail of this one secret alone, over any page** (`FleetStore.secretCard`): the card that a request's badge
    /// opens in a chat, on Needs you or over a job's card. It reads as the page does, and Done, Esc and a click outside
    /// close it with nothing else changed: he stays where he was. nil: the page.
    var card: SecretCard? = nil
    /// The readings are the store's (`FleetStore.reading`), the fleet's and each agent's under its own name: the list he
    /// saw last shows in the first frame when he comes back, and the read that starts then changes only what changed.
    /// The team it is made from is kept for the other pages that draw it too ("team.snapshot").
    private var reading: LoginReading? {
        get { store.reading("secrets.logins.\(agent ?? "fleet")") } nonmutating set { store.keep(newValue, as: "secrets.logins.\(agent ?? "fleet")") }
    }
    /// `GET /ui/resources` (owner feature `resource_grants`): who may give each secret, with the version a change of
    /// it goes against. nil on a hub without it, and then no secret shows the row. It is the reading of the MCPs and
    /// Apps lists (`AccessSettings.name`).
    private var resources: ResourceList? {
        get { store.reading(AccessSettings.name(agent)) } nonmutating set { store.keep(newValue, as: AccessSettings.name(agent)) }
    }
    /// When the first of the reads that failed in a row failed, or nil while the last read answered: `reading` is then
    /// the last good one, or nil. One break of them says nothing (`FleetStore.pageReadingIsOld`).
    @State private var failedSince: ContinuousClock.Instant?
    /// When this visit began: a kept list that this visit reads again is not old before that read has had a second.
    @State private var opened = ContinuousClock.now
    /// The form of Add secret shows in the list's place.
    @State private var adding = false
    /// The import of secrets from another password manager shows in the list's place (`SecretImportView`).
    @State private var importing = false
    /// The catalog's references when Add secret opened. A reference that comes later is the result of that visit.
    @State private var before: Set<String>?
    @State private var copied: String?
    @State private var shown: SecretCard?
    /// The change that the hub works on now: "reference agent" for a grant, the reference for a removal.
    @State private var working: String?
    /// The result or the problem of the last change, in its secret's detail.
    @State private var note: (login: String, text: String, warning: Bool)?
    /// A removal's result, over the list.
    @State private var removed: String?
    /// **The filter of the fleet's list**: its words (`SecretsList.matches`) and the agents ticked in its menu.
    @State private var words = ""
    @State private var filterAgents: Set<String> = []
    @FocusState private var filterFocused: Bool
    /// The bar, the store's (`SecretsBar`).
    private var bar: SecretsBar { store.pageModel("secrets.bar") { SecretsBar() } }
    /// The secrets ticked for the bar, by reference: only the ones that the list shows (`SecretsList.selected`).
    private var ticked: Set<String> { get { bar.ticked } nonmutating set { bar.ticked = newValue } }
    /// The change of several secrets that works now: every control of the page waits for it.
    private var bulk: BulkWork? { bar.work }
    /// The bar's one line: a refusal in the hub's words, a grant's warning, or the secrets that Delete kept, in orange.
    private var bulkLine: String? { get { bar.line } nonmutating set { bar.line = newValue } }
    @Environment(\.colorSchemeContrast) private var contrast

    private var offered: Bool { SecretEntryView.isOffered(by: store) }

    /// The catalog and its use, read before the page first opens (`PagePrefetch`): the fleet's, and each agent's.
    static let prefetch = PagePrefetch("secrets.logins.fleet", feature: SecretEntryView.feature) { try await loginReading(hub: $0, database: $1) }
    static let agentPrefetch = PagePrefetch(agent: { "secrets.logins.\($0)" }, feature: SecretEntryView.feature) { hub, database, _ in
        try await loginReading(hub: hub, database: database)
    }
    /// The reading the page makes itself (`read`): team.json, and the profiles where the hub has them.
    private nonisolated static func loginReading(hub: URL, database: String) async throws -> LoginReading {
        let client = HubClient()
        let team = try await client.team(hub: hub, database: database)
        let profiles = try? await client.profiles(hub: hub, database: database)
        return LoginReading(team: team, profiles: profiles?.profiles)
    }
    private var canChange: Bool { offered && store.writesNow && working == nil && bulk == nil }
    private var agents: [String] { store.state?.agents.map(\.name) ?? [] }
    /// The central vault of this hub (owner feature `central_vault`), which the store keeps in order by itself: this
    /// page shows only its rows that need the owner, and each secret's servers. A hub without it shows none of them.
    private var vault: CentralVaultModel { store.vaultModel() }

    var body: some View {
        Group {
            if let card { detail(card.id) }
            else if importing && offered { importPage } else if adding && offered { addPage } else { list }
        }
            .task(id: "\(store.hub)/\(store.state?.db ?? "")/\(offered)") { await poll() }
            // **What came of a change is said once**: when he leaves the page while no change works, the bar's line and
            // a Delete's line over the list go. A line that a change sets while he is away waits for his return. The
            // card over another page is not the page: its close leaves the page's lines.
            .onDisappear { if card == nil, agent == nil, bar.work == nil { bar.line = nil; bar.removed = nil } }
    }

    /// The detail goes: the card over any page (`FleetStore.secretCard`), or the page's own.
    private func close() {
        if card != nil { store.secretCard = nil } else { shown = nil }
    }

    // MARK: list

    @ViewBuilder private var list: some View {
        if grouped {
            VStack(alignment: .leading, spacing: FleetSpace.block) { listContent }
                .fleetModal(item: $shown) { detail($0.id) }
        } else {
            // Every control of the page waits while a change of several secrets works; the page still scrolls.
            FleetPage("Secrets") { listContent.disabled(bulk != nil) } actions: {
                // The page's one group has no heading, so its old-reading line stands with the header's actions.
                if reading != nil { lastReading }
                if offered {
                    Button {
                        note = nil; removed = nil; bar.removed = nil
                        // As for Add secret: what is new after the import comes from the reading.
                        Task {
                            if reading == nil { await read() }
                            before = reading.map { Set($0.catalog.keys) }; importing = true
                        }
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }.buttonStyle(FleetOutlineButtonStyle()).disabled(bulk != nil).accessibilityIdentifier("secret-import")
                    Button {
                        note = nil; removed = nil; bar.removed = nil
                        // What is new after the form comes from the reading: a press that comes before the first one
                        // waits for it.
                        Task {
                            if reading == nil { await read() }
                            before = reading.map { Set($0.catalog.keys) }; adding = true
                        }
                    } label: {
                        Label("Add secret", systemImage: "plus")
                    }.buttonStyle(FleetPrimaryButtonStyle()).disabled(bulk != nil).accessibilityIdentifier("secret-add")
                }
            }
            // **The bar, while a secret is ticked**, at the bottom of the page and over its scroll, in the cards' column.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Also while its line says what came of a change whose secrets the filter shows no more.
                if let reading, !ticked.isEmpty || bulk != nil || bulkLine != nil { barView(reading) }
            }
            .fleetModal(item: $shown) { detail($0.id) }
        }
    }

    @ViewBuilder private var listContent: some View {
        Group {
            // The filter's row stands under the header, while the list has more than one secret to filter, and while a
            // filter is on, so that it can always be cleared.
            if agent == nil, offered, let reading, reading.hasCatalog,
               reading.catalog.count > 1 || SecretsList.filters(words: words, agents: filterAgents) { filterRow(reading) }
            if agent == nil { CentralVaultSection(store: store, model: vault) }
            if !offered {
                FormSection(grouped ? String(l10n: "Secrets") : nil) {
                    FormEmpty(store.state?.ui_features?.contains(SecretEntryView.feature) == true
                              ? "Update the hub to add and share secrets here." : "This hub does not list its secrets yet.", symbol: "key")
                }
            } else if let reading { catalog(reading) }
            else if store.pageReadingIsOld(failedSince: failedSince) {
                // **Not while the window's notice says the outage** (`FleetStore.hubNoticeShows`; fix round 3, item 33:
                // an outage is said once): an agent's group keeps its heading alone, as while it reads. **One break of
                // the hub says nothing** (17 November 2026): the loading line stays until the reads have failed one
                // whole break, or the fleet's state is old.
                if !store.hubNoticeShows {
                    FormSection(grouped ? String(l10n: "Secrets") : nil) {
                        FormRow("Founderizer cannot read the secrets now.", detail: String(l10n: "It reads again when the hub answers."))
                    }
                } else if grouped {
                    FormSection("Secrets") { EmptyView() }
                }
            } else {
                if grouped { FormSection("Secrets") { EmptyView() } }
                LoadingLine(String(l10n: "Reading the secrets…"))
            }
        }
    }

    @ViewBuilder private func catalog(_ reading: LoginReading) -> some View {
        let entries = reading.catalog.sorted { ($0.value.name.lowercased(), $0.key) < ($1.value.name.lowercased(), $1.key) }
            .filter { entry in agent.map { reading.holders(entry.key, entry.value, agents: agents).contains($0) } ?? true }
        let added = before.map { known in entries.filter { !known.contains($0.key) } } ?? []
        if let removed = removed ?? (agent == nil ? bar.removed : nil) {
            Label(removed, systemImage: "checkmark.circle").font(FormMetrics.text).foregroundStyle(FleetStyle.text)
                .accessibilityIdentifier("secret-removed")
        } else if !added.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "checkmark.circle").foregroundStyle(.green)
                // One sentence for each count, so that each language says it in its own grammar.
                let names = added.map { String(l10n: "“\($0.value.name)”") }.joined(separator: ", ")
                Text(added.count == 1 ? "\(names) is in the list." : "\(names) are in the list.")
                    .fixedSize(horizontal: false, vertical: true)
            }.font(FormMetrics.text).foregroundStyle(FleetStyle.text).accessibilityIdentifier("secret-added")
        }
        if !reading.hasCatalog {
            FormSection { FormRow("The hub gave no list of secrets that Founderizer can read.", symbol: "exclamationmark.circle") }
        } else if agent == nil {
            fleetCatalog(reading, added: Set(added.map(\.key)))
        } else {
            // No line under the list about what a click does: the row's own ⓘ says it, as on Apps. As a group of an
            // agent's Can use, the empty card when the agent has none, and the + that gives it one more (the owner's
            // yes of 3 November 2026).
            FormSection(grouped ? String(l10n: "Secrets") : nil) {
                if entries.isEmpty { FormEmpty(grouped ? "No secrets" : "No secrets yet", symbol: "key") }
                ForEach(entries, id: \.key) { entry in
                    row(entry.key, entry.value, reading: reading, isNew: added.contains { $0.key == entry.key })
                }
            } accessory: {
                if grouped {
                    lastReading
                    giveMenu(reading)
                }
            }
            // **Only a refusal, in the hub's words** (UI-PATTERNS: a footer carries what went wrong and nothing else): a
            // + or a − that worked shows itself in the list. While the detail shows, its line is there.
            if grouped, shown == nil, let note, note.warning {
                Text(note.text).font(FormMetrics.detail).foregroundStyle(note.warning ? .orange : FleetStyle.muted)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .accessibilityIdentifier("secret-group-note")
            }
        }
    }

    // MARK: the fleet's list

    /// The fleet's secrets in the list's order, each with its holders, and the ones that the filter shows.
    private func fleetItems(_ reading: LoginReading) -> (all: [SecretsList.Item], shown: [SecretsList.Item]) {
        let all = reading.catalog.sorted { ($0.value.name.lowercased(), $0.key) < ($1.value.name.lowercased(), $1.key) }
            .map { SecretsList.Item(reference: $0.key, entry: $0.value, holders: reading.holders($0.key, $0.value, agents: agents)) }
        // An agent that left the fleet filters nothing.
        return (all, SecretsList.shown(all, words: words, agents: filterAgents.intersection(agents)))
    }

    /// **The fleet's list**: the rows that the filter shows, each with its tick (`fleetRow`), and the card's empty state
    /// when none shows. A tick that the filter hides goes, so the bar never acts on a secret that he cannot see.
    @ViewBuilder private func fleetCatalog(_ reading: LoginReading, added: Set<String>) -> some View {
        let (all, shown) = fleetItems(reading)
        // A list that can hold hundreds of rows makes only the ones on the screen (UI-PATTERNS, `FormSection`).
        FormSection(lazy: true) {
            if all.isEmpty { FormEmpty("No secrets yet", symbol: "key") }
            else if shown.isEmpty { FormEmpty("No secret matches the filter.", symbol: "magnifyingglass") }
            ForEach(shown, id: \.reference) { fleetRow($0, isNew: added.contains($0.reference)) }
        }
        .onChange(of: shown.map(\.reference)) { _, now in ticked.formIntersection(now) }
    }

    /// **The row of the filter, under the header**: the words (each secret's name and note), the menu of the agents
    /// with a tick each (a secret that at least one ticked agent holds), and, while a filter is on, "N of M" at its
    /// right.
    private func filterRow(_ reading: LoginReading) -> some View {
        let (all, shown) = fleetItems(reading)
        let chosen = agents.filter(filterAgents.contains)
        return HStack(spacing: FleetSpace.actions) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(IconMetrics.symbol(12)).foregroundStyle(FleetStyle.muted)
                    .accessibilityHidden(true)
                TextField(text: $words, prompt: Text(verbatim: "")) { Text("Filter") }
                    .focused($filterFocused)
                    .fieldPlaceholder(String(l10n: "Filter"), shows: words.isEmpty)
                    .accessibilityIdentifier("secrets-filter")
            }
            .modifier(FleetFieldBox(focused: filterFocused))
            .onTapGesture { filterFocused = true }
            .frame(width: 240)
            FleetTicks(String(l10n: "Agents"), options: agents.map {
                FleetOption($0, $0.agentLabel, mark: .agent($0, state: store.state, isFresh: store.isFresh))
            }, ticked: filterAgents, changed: { filterAgents = $0 }) {
                HStack(spacing: 7) {
                    if !chosen.isEmpty { HolderFaces(names: SecretsList.faces(chosen).shown) }
                    Text(SecretsList.agentsWords(chosen.count)).lineLimit(1)
                    Image(systemName: "chevron.down").font(IconMetrics.symbol(8.5, weight: .bold)).foregroundStyle(FleetStyle.muted)
                        .padding(.leading, 1).accessibilityHidden(true)
                }
            }
            .buttonStyle(FleetOutlineButtonStyle())
            .accessibilityValue(chosen.map(\.agentLabel).joined(separator: ", "))
            .accessibilityIdentifier("secrets-agents")
            Spacer(minLength: 12)
            if let count = SecretsList.count(shown: shown.count, of: all.count, filtering: SecretsList.filters(words: words, agents: Set(chosen))) {
                Text(count).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).monospacedDigit().lineLimit(1)
                    .accessibilityIdentifier("secrets-count")
            }
        }
        // The cards' measure from the column's left edge, so the count ends where the cards end.
        .frame(maxWidth: FormMetrics.formWidth, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
    }

    /// **One secret of the fleet's list** (the owner's "yes as drawn" of 20 November 2026): its tick at its start, always
    /// there; its kind as a mark; its name; under it the faces of the agents that hold it, overlapping, then their names
    /// (`SecretsList.holderWords`); and the ⓘ at its end, or a spinner while the bar's change still changes it. A click
    /// opens its detail; the tick stands over the row, never inside its button, so its click is its own.
    private func fleetRow(_ item: SecretsList.Item, isNew: Bool) -> some View {
        let entry = item.entry, reference = item.reference
        let kind = entry.isAPIKey ? String(l10n: "API key") : String(l10n: "Login")
        let summary = SecretsList.holderWords(item.holders)
        let faces = SecretsList.faces(item.holders).shown
        return Button { note = nil; shown = SecretCard(id: reference) } label: {
            HStack(spacing: 12) {
                // The tick's room: the box stands over it (`overlay`).
                Color.clear.frame(width: 14, height: 14)
                IconTile(symbol: entry.isAPIKey ? "key.horizontal" : "person.badge.key")
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        // Cut in the middle: the names of one project share their start, and the end tells them apart.
                        Text(entry.name).font(entry.isAPIKey ? FormMetrics.title.monospaced() : FormMetrics.title)
                            .foregroundStyle(FleetStyle.text).lineLimit(1).truncationMode(.middle)
                        if isNew {
                            Text("New").font(FormMetrics.detailTitle).padding(.horizontal, 6).padding(.vertical, 1.5)
                                .background(Color.green.opacity(0.2), in: Capsule())
                        }
                    }
                    HStack(spacing: 6) {
                        if !faces.isEmpty { HolderFaces(names: faces) }
                        Text(summary).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).lineLimit(1)
                    }
                }.padding(.vertical, 10)
                Spacer(minLength: 12)
                // Who may give it, only where the fleet manager may: the same word as on MCPs and Apps.
                if let level = managerLevel(reference) { ManagerGives(level: level) }
                ZStack {
                    if bulk?.open.contains(reference) == true {
                        ProgressView().controlSize(.small).accessibilityLabel(String(l10n: "Changing"))
                    } else {
                        Image(systemName: "info.circle").font(IconMetrics.symbol(14)).foregroundStyle(FleetStyle.muted).accessibilityHidden(true)
                    }
                }.frame(width: 18)
            }.padding(.horizontal, FormMetrics.rowInset).frame(minHeight: FormMetrics.twoLineRow)
        }
        .buttonStyle(FleetRowButtonStyle())
        .help("\(kind): show which agents can use \(entry.name)")
        .accessibilityLabel(([entry.name, kind, summary] + [managerLevel(reference).map { String(l10n: "Manager may give: \($0)") }]).compactMap { $0 }
            .joined(separator: ", "))
        .accessibilityHint("Shows its detail")
        .accessibilityIdentifier("secret-\(reference)")
        .overlay(alignment: .leading) {
            Toggle(isOn: Binding { ticked.contains(reference) } set: { on in
                if on { ticked.insert(reference) } else { ticked.remove(reference) }
                bulkLine = nil; bar.removed = nil
            }) { Text(entry.name) }
            .toggleStyle(FleetCheckboxStyle()).labelsHidden()
            .accessibilityLabel(String(l10n: "Select \(entry.name)"))
            .accessibilityIdentifier("secret-tick-\(reference)")
            // The box's 14 points in the room the row keeps for it, its 28-point reach around it.
            .padding(.leading, FormMetrics.rowInset - (IconMetrics.side - 14) / 2)
        }
    }

    /// **The bar of the ticked secrets**, at the bottom of the page in the cards' column: how many are ticked, or,
    /// while a change works, its spinner and "Giving 4 of 6"; Give access and Take access (each a menu of agents with a
    /// tick each and one white button), Delete, and the mark that clears the ticks; under them one orange line for a
    /// refusal, in the hub's words, or for the secrets that Delete kept.
    private func barView(_ reading: LoginReading) -> some View {
        let selected = selectedNow
        let takeable = SecretsList.takeable(selected, agents: agents)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: FleetSpace.actions) {
                if let bulk {
                    ProgressView().controlSize(.small)
                    // While the catalog is read once more before the plan, its count of ticks.
                    Text(bulk.total == 0 ? SecretsList.selectedWords(selected.count) : SecretsList.progress(bulk.change, done: bulk.done, of: bulk.total))
                        .monospacedDigit().accessibilityIdentifier("secrets-bulk-progress")
                } else {
                    Text(SecretsList.selectedWords(selected.count)).monospacedDigit().accessibilityIdentifier("secrets-selected")
                }
                Spacer(minLength: 12)
                access(.give, selected: selected, offered: agents)
                access(.take, selected: selected, offered: takeable)
                Button("Delete") { Task { await bulkDelete() } }
                    .buttonStyle(FleetDangerButtonStyle()).disabled(!canChange || selected.isEmpty)
                    .accessibilityIdentifier("secrets-bulk-delete")
                IconButton(symbol: "xmark", words: String(l10n: "Clear the selection")) { ticked = []; bulkLine = nil; bar.removed = nil }
                    .disabled(bulk != nil).accessibilityIdentifier("secrets-bulk-clear")
            }
            .font(FormMetrics.text).foregroundStyle(FleetStyle.text)
            if let bulkLine {
                Text(bulkLine).font(FormMetrics.detail).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .accessibilityIdentifier("secrets-bulk-line")
            }
        }
        .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 10)
        .background(FleetStyle.surface, in: RoundedRectangle(cornerRadius: FormMetrics.radius))
        .overlay(RoundedRectangle(cornerRadius: FormMetrics.radius)
            .strokeBorder(FleetStyle.hairline(0.08), lineWidth: FleetStyle.edgeWidth(contrast)))
        .environment(\.onCard, true)
        .frame(maxWidth: FormMetrics.formWidth, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        .fleetColumn()
        // The rows that scroll under it do not show around it.
        .padding(.top, FleetSpace.inside).padding(.bottom, FleetSpace.under)
        .background(FleetStyle.canvas)
    }

    /// Give access or Take access: a menu of the agents (every agent, or the ones with a grant of a ticked secret), a
    /// tick each, and one white button that names the change ("Give 4 secrets to 2 agents"), dimmed while it would
    /// change nothing.
    private func access(_ change: SecretsList.Change, selected: [SecretsList.Item], offered: [String]) -> some View {
        let words = change == .give ? String(l10n: "Give access") : String(l10n: "Take access")
        let agents = agents
        return FleetTicks(words, options: offered.map {
            FleetOption($0, $0.agentLabel, mark: .agent($0, state: store.state, isFresh: store.isFresh))
        }, ticked: [], button: { chosen in
            (SecretsList.buttonWords(change, secrets: selected.count, agents: chosen.count),
             !SecretsList.pairs(change, secrets: selected, chosen: chosen, agents: agents).isEmpty)
        }, press: { chosen in Task { await bulkGrant(change, chosen: chosen) } }) {
            Text(words)
        }
        .buttonStyle(FleetOutlineButtonStyle())
        .disabled(!canChange || selected.isEmpty || offered.isEmpty)
        .accessibilityIdentifier(change == .give ? "secrets-bulk-give" : "secrets-bulk-take")
    }

    /// **The + of an agent's Secrets** (the owner's yes of 3 November 2026): the catalog's secrets that this agent does
    /// not have, in the app's list; one choice gives it (`use`: its vault uses it, and the agent never sees it), as
    /// Give in the secret's detail does. Only while there is one to give and the hub answers; it waits while a change
    /// goes on.
    @ViewBuilder private func giveMenu(_ reading: LoginReading) -> some View {
        if let agent, offered, store.writesNow {
            let open = reading.catalog.filter { !reading.holders($0.key, $0.value, agents: agents).contains(agent) }
                .sorted { ($0.value.name.lowercased(), $0.key) < ($1.value.name.lowercased(), $1.key) }
            if !open.isEmpty {
                let words = String(l10n: "Give \(agent.agentLabel) a secret")
                FleetSelect(words, options: open.map { FleetOption($0.key, $0.value.name,
                                                                   mark: .symbol($0.value.isAPIKey ? "key.horizontal" : "person.badge.key")) }) { reference in
                    guard let entry = reading.catalog[reference] else { return }
                    Task { await setGrant(.use, agent: agent, reference: reference, entry: entry) }
                } label: {
                    Image(systemName: "plus").font(IconMetrics.symbol(13)).foregroundStyle(FleetStyle.muted)
                }
                .buttonStyle(FleetIconButtonStyle(rest: true))
                .disabled(!canChange)
                .help(words)
                // In the column of the rows' −, which stand the rows' inset in from the card's edge.
                .padding(.trailing, FormMetrics.rowInset)
                .accessibilityIdentifier("secret-give")
            }
        }
    }

    /// **"Last reading", only for a list that is old, and only after this visit's read has had its second** (D-1 rule 2,
    /// as Runs on holds its warning): it came 50 ms after Can use opened, over a list that the read on its way confirmed
    /// at 700 ms. It stands in the group's own heading row, at its right — on the page, beside the header's actions —
    /// so nothing under it moves when it comes or goes: every group of Can use moved 38 pt down and back. **One break
    /// of the hub says nothing** (17 November 2026): it stood from the first read that a restart of the hub refused.
    /// Not while the window's notice says the outage (fix round 3, item 33: an outage is said once).
    @ViewBuilder private var lastReading: some View {
        if store.pageReadingIsOld(failedSince: failedSince) && !store.hubNoticeShows {
            Held(since: opened) {
                Label("Last reading", systemImage: "clock.arrow.circlepath")
                    .font(FormMetrics.detail).foregroundStyle(.orange).lineLimit(1)
                    .help("Founderizer reads the secrets again when the hub answers.")
                    .accessibilityIdentifier("secrets-last-reading")
            }
        }
    }

    /// One secret: its kind as a mark, its name and the agents that have it. A click opens its detail. **The kind is its
    /// mark's, and on an agent's own list the agent is the page's** (the owner, 13 November 2026, of the import's list:
    /// "review all other pages for the same issues!!"): "API key ·" on every row, and the agent's own name on every row of
    /// its list, told nothing. There the line names the other agents that have it, and a secret of this agent alone has
    /// one line.
    private func row(_ reference: String, _ entry: TeamLogin, reading: LoginReading, isNew: Bool) -> some View {
        let kind = entry.isAPIKey ? String(l10n: "API key") : String(l10n: "Login")
        let holders = reading.holders(reference, entry, agents: agents)
        let others = agent.map { mine in holders.filter { $0 != mine } } ?? holders
        let summary: String? = agent != nil && others.isEmpty ? nil : agentWords(others)
        return Button { note = nil; shown = SecretCard(id: reference) } label: {
            HStack(spacing: 12) {
                IconTile(symbol: entry.isAPIKey ? "key.horizontal" : "person.badge.key")
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        // Cut in the middle: the names of one project share their start, and the end tells them apart.
                        Text(entry.name).font(entry.isAPIKey ? FormMetrics.title.monospaced() : FormMetrics.title)
                            .foregroundStyle(FleetStyle.text).lineLimit(1).truncationMode(.middle)
                        if isNew {
                            Text("New").font(FormMetrics.detailTitle).padding(.horizontal, 6).padding(.vertical, 1.5)
                                .background(Color.green.opacity(0.2), in: Capsule())
                        }
                    }
                    if let summary { Text(summary).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).lineLimit(1) }
                }.padding(.vertical, 10)
                Spacer(minLength: 12)
                // Who may give it, only where the fleet manager may: the same word as on MCPs and Apps.
                if let level = managerLevel(reference) { ManagerGives(level: level) }
                // An agent's row keeps the room of its control, which stands over the row (`agentControl`).
                if agent == nil {
                    Image(systemName: "info.circle").font(IconMetrics.symbol(14)).foregroundStyle(FleetStyle.muted).accessibilityHidden(true)
                } else {
                    Color.clear.frame(width: IconMetrics.side, height: IconMetrics.side)
                }
            }.padding(.horizontal, FormMetrics.rowInset).frame(minHeight: summary == nil ? FormMetrics.row : FormMetrics.twoLineRow)
        }
        .buttonStyle(FleetRowButtonStyle())
        .help("\(kind): show which agents can use \(entry.name)")
        .accessibilityLabel(([entry.name, kind, summary] + [managerLevel(reference).map { String(l10n: "Manager may give: \($0)") }]).compactMap { $0 }
            .joined(separator: ", "))
        .accessibilityHint("Shows its detail")
        .accessibilityIdentifier("secret-\(reference)")
        .overlay(alignment: .trailing) {
            if let agent { agentControl(agent, reference: reference, entry: entry, reading: reading).padding(.trailing, FormMetrics.rowInset) }
        }
    }

    /// **The end of a row on an agent's Secrets** (the owner's yes of 3 November 2026): the − that takes the secret back
    /// from this agent alone, as Take back in its detail does; nothing where the agent has it from its profile, which its
    /// detail shows and its profile changes. It stands over the row, never inside its button, so its click is its own.
    @ViewBuilder private func agentControl(_ agent: String, reference: String, entry: TeamLogin, reading: LoginReading) -> some View {
        let name = agent.agentLabel
        if working == "\(reference) \(agent)" {
            ProgressView().controlSize(.small).frame(width: IconMetrics.side, height: IconMetrics.side)
        } else if entry.grants?[agent] != nil {
            IconButton(symbol: "minus", words: String(l10n: "Take \(entry.name) back from \(name)")) {
                Task { await setGrant(nil, agent: agent, reference: reference, entry: entry) }
            }
            .disabled(!canChange)
            .accessibilityIdentifier("secret-take-\(reference)")
        }
    }

    // MARK: detail

    /// The detail of one secret: its name and kind, each agent with its access and its control, and
    /// it, and Remove for a secret that nobody has. Done, Esc or a click outside closes it.
    private func detail(_ reference: String) -> some View {
        let entry = reading?.catalog[reference]
        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                IconTile(symbol: entry?.isAPIKey == true ? "key.horizontal" : "person.badge.key")
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry?.name ?? reference)
                        .font(entry?.isAPIKey == true ? FormMetrics.title.monospaced() : FormMetrics.title)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled).accessibilityAddTraits(.isHeader)
                    HStack(spacing: 4) {
                        Text(entry?.isAPIKey == true ? "API key" : "Login").font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                        MessageAction(symbol: copied == reference ? "checkmark" : "square.on.square", label: String(l10n: "Copy the reference"),
                                      help: String(l10n: "Copy its reference, \(reference)"), height: 16) { copyMessage(reference); copied = reference }
                            .foregroundStyle(FleetStyle.muted)
                    }
                }
                Spacer(minLength: 12)
                Button("Done") { close() }.buttonStyle(FleetOutlineButtonStyle()).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("secret-done")
            }
            // **Its note, as a field that he edits** (owner feature `secret_notes`; the owner, 19 November 2026: "only use
            // when adding valuable context, otherwise leave empty", and 20 November 2026, to the note in the detail: "yes
            // - I also want the agents to be able to edit it!"): the words that the agents read beside its name, with
            // the mark of who wrote them, and his own words saved as he leaves the field. An agent writes it with its
            // own tools. A hub without notes shows the note's words, where it has one.
            if let entry {
                if store.state?.ui_features?.contains("secret_notes") == true {
                    SecretNoteField(note: entry.note ?? "", by: entry.note_by, canChange: offered && store.writesNow && bulk == nil) {
                        await saveNote($0, base: $1, reference: reference)
                    }
                    .id(reference)
                } else if let words = entry.note, !words.isEmpty {
                    Text(words).font(FormMetrics.text).foregroundStyle(FleetStyle.text)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .help(entry.note_by == "owner" ? String(l10n: "Your note") : String(l10n: "An agent wrote this note"))
                        .accessibilityIdentifier("secret-note-words")
                }
            }
            if let entry, let reading {
                let holders = reading.holders(reference, entry, agents: agents)
                FormSection("Available to", footer: entry.isAPIKey
                            ? String(l10n: "Agents use the key without seeing it. With Reads it, the key is in the agent's sessions.")
                            : String(l10n: "Agents sign in with it. They never see the password.")) {
                    ForEach(agents, id: \.self) { access($0, reference: reference, entry: entry, reading: reading) }
                }
                if let resources, let resource = resources.resource(Self.resourceID(reference)),
                   let kind = resources.kind(of: resource) {
                    // One "Who may give it" on the card (D-2): the row's.
                    FormSection(footer: StandingRows.words(resource.standing, reading: resources, kind: "secret").footer) {
                        StandingRows(title: entry.name, kind: "secret", standing: resource.standing, levels: kind.levels,
                                     reading: resources, busy: working == "standing \(reference)",
                                     canChange: canChange) { next in
                            Task { await saveStanding(next, reference: reference, entry: entry) }
                        }
                    }
                }
                if let note, note.login == reference {
                    Text(note.text).font(FormMetrics.detail).foregroundStyle(note.warning ? .orange : FleetStyle.muted)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).accessibilityIdentifier("secret-note")
                }
                CentralHeldRow(model: vault, reference: reference)
                if holders.isEmpty {
                    HStack {
                        Spacer()
                        Button("Remove from Founderizer") { Task { await remove(reference, entry: entry) } }
                            .buttonStyle(FleetDangerButtonStyle()).disabled(!canChange)
                            .help("Remove it from this list. Its value stays in the vaults.").accessibilityIdentifier("secret-remove")
                    }
                }
            } else {
                Text("This secret is no longer in the list.").font(FormMetrics.text).foregroundStyle(FleetStyle.muted)
            }
        }
        // The width of every card over the page that holds an item (margins row 27): an MCP server's, a repository's,
        // an account's and a file's are 560 points, and this one stood 540.
        .padding(22).frame(width: 560)
        .font(FleetStyle.body).foregroundStyle(FleetStyle.text)
    }

    /// One agent's access to one secret, with its control. No access: Give (`use`). A login: Take back. An API key:
    /// Uses it, Reads it with its warning, or Take it back. An agent whose profile lists the reference has it from there,
    /// and its profile changes that.
    private func access(_ agent: String, reference: String, entry: TeamLogin, reading: LoginReading) -> some View {
        let grant = entry.grants?[agent].flatMap(SecretGrant.init(rawValue:))
        let listed = reading.listed?[reference]?.contains(agent) == true
        let name = agent.agentLabel, busy = working == "\(reference) \(agent)"
        let words = grant == .read ? String(l10n: "Reads it in its sessions") : grant == .use ? String(l10n: "Can use it") : listed ? String(l10n: "Can use it (its profile)") : String(l10n: "No access")
        // **The glyph in the one mark column** (margins row 9): its name begins where "Who may give it" and every row
        // title of the card begins, 50 points in. A 16-point glyph and 10 of spacing put it 8 points to the left.
        return HStack(spacing: 0) {
            RowMark { AgentGlyph(name: agent, size: GlyphSize.inline) }
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(FormMetrics.title).foregroundStyle(FleetStyle.text)
                Text(words).font(FormMetrics.detail).foregroundStyle(grant == .read ? Color.orange : FleetStyle.muted)
            }.padding(.vertical, 10)
            Spacer(minLength: 12)
            if busy { ProgressView().controlSize(.small) }
            else if grant == nil && listed {
                Image(systemName: "checkmark").foregroundStyle(FleetStyle.muted)
                    .help("The profile of \(name) lists this secret. Its profile changes that.")
            } else if grant == nil {
                Button("Give") { Task { await setGrant(.use, agent: agent, reference: reference, entry: entry) } }
                    .buttonStyle(FleetOutlineButtonStyle()).disabled(!canChange)
                    .help("Let \(name) use it. \(name) never sees the value.")
            } else if entry.isAPIKey {
                keyAccess(agent, name: name, reference: reference, entry: entry, grant: grant)
            } else {
                Button("Take back") { Task { await setGrant(nil, agent: agent, reference: reference, entry: entry) } }
                    .buttonStyle(FleetOutlineButtonStyle()).disabled(!canChange).help("\(name) can no longer use it.")
            }
        }
        .padding(.horizontal, FormMetrics.rowInset).frame(minHeight: FormMetrics.twoLineRow)
        .accessibilityElement(children: .contain).accessibilityIdentifier("secret-agent-\(agent)")
    }

    /// The control of one API key: Uses it, Reads it with its warning, or Take it back. It is a function of its own,
    /// with its rows and its label in local values, because the select with three rows and two conditional labels in
    /// one expression is more than the type checker solves.
    private func keyAccess(_ agent: String, name: String, reference: String, entry: TeamLogin,
                           grant: SecretGrant?) -> some View {
        let reads = grant == .read
        let rows = [
            FleetOption(SecretChoice.use, "Uses it", subtitle: String(l10n: "\(name) uses the key and never sees it."), mark: .symbol("lock")),
            FleetOption(SecretChoice.read, "Reads it", subtitle: String(l10n: "The key is in its sessions as $\(entry.name). \(name) can copy it."),
                        mark: .symbol("eye")),
            FleetOption(SecretChoice.none, "Take it back", mark: .symbol("slash.circle")),
        ]
        return FleetSelect("Access of \(name)", options: rows, selection: reads ? SecretChoice.read : SecretChoice.use) { choice in
            let next: SecretGrant? = choice == .read ? .read : choice == .use ? .use : nil
            Task { await setGrant(next, agent: agent, reference: reference, entry: entry) }
        } label: {
            FleetSelectLabel(title: reads ? String(l10n: "Reads it") : String(l10n: "Uses it"), mark: .symbol(reads ? "eye" : "lock"))
        }.disabled(!canChange)
    }

    // MARK: add

    /// Add secret, in the list's place, with Back: the form, with the agents that get the new secret under its
    /// fields. The form shows a save that is not finished when it opens. Its Cancel and Close, and a finished save,
    /// come back here; the list then reads the catalog again and shows the saved secret as a row. Nothing opens by
    /// itself: the form gave each agent its access and showed what came of each grant, so the detail with the same
    /// agents was a second list of them (the owner, 13 November 2026: "IT looks duplicated! why?").
    private var addPage: some View {
        FleetPage("Add secret", back: FleetBack("Secrets") { adding = false; Task { await read() } }) {
            SecretEntryView(store: store) { finishAdd($0) }
        }
        .accessibilityIdentifier("secret-back")
    }

    /// Import, in the list's place: a setup's wizard with its own Back (`SecretImportView`). Its end, and its Back from the
    /// first page, come here; the list reads the catalog again, and what the import saved shows as new.
    private var importPage: some View {
        SecretImportView(store: store) { finishImport($0) }
    }

    private func finishImport(_ references: [String]) {
        importing = false
        if references.isEmpty { before = nil }
        Task { await read() }
    }

    /// After the form: back to the list, which reads the catalog again. It opens no detail: a click on a row does.
    /// Cancel saves nothing.
    private func finishAdd(_ reference: String?) {
        adding = false
        Task { await read() }
    }

    // MARK: changes

    private static func text(_ error: Error) -> String { (error as? LocalizedError)?.errorDescription ?? String(l10n: "The hub did not answer.") }

    /// One click: the grant of one secret to one agent, or its end. The hub commits it at once.
    private func setGrant(_ grant: SecretGrant?, agent: String, reference: String, entry: TeamLogin) async {
        note = nil
        note = await self.grant(grant, agent: agent, reference: reference, entry: entry).map { (reference, $0.text, $0.warning) }
    }

    /// One grant at the hub, then a new reading. Returns what the owner must know, or nil. A grant is signed for the
    /// central vault before the hub has it, and its end after (`GrantSigning`).
    private func grant(_ grant: SecretGrant?, agent: String, reference: String, entry: TeamLogin) async -> (text: String, warning: Bool)? {
        guard canChange, let database = store.state?.db else { return nil }
        let hub = store.hub, client = store.installation
        working = "\(reference) \(agent)"
        defer { working = nil }
        do {
            if grant != nil { try await GrantSigning.grant(grant, login: reference, agent: agent, store: store, hub: hub, database: database) }
            let receipt = try await SecretsClient().grant(hub: hub, database: database, client: client, login: reference, agent: agent, grant: grant)
            if grant == nil { try await GrantSigning.grant(nil, login: reference, agent: agent, store: store, hub: hub, database: database) }
            await read()
            return Self.note(receipt, entry: entry)
        } catch {
            await read()
            return (String(l10n: "Founderizer could not change this for \(agent.agentLabel). \(Self.text(error))"), true)
        }
    }

    /// What the owner must know after a grant: the agent's vault access, or when it reads the key.
    private static func note(_ receipt: SecretGrantReceipt, entry: TeamLogin) -> (text: String, warning: Bool)? {
        let name = receipt.agent.agentLabel
        if let vault = receipt.vault {
            if vault.after == "broker" { return (String(l10n: "\(name) uses its server's vault now."), false) }
            let reasons = (vault.missing ?? []).map(VaultAccessControl.reason).joined(separator: " ")
            return (String(l10n: "\(name) has it, but it has no vault access yet, so it cannot use it now. \(reasons)"), true)
        }
        if receipt.grant == SecretGrant.read.rawValue && receipt.changed {
            return (String(l10n: "\(name) reads $\(entry.name) in its sessions from their next start."), false)
        }
        return nil
    }

    /// The id of one secret among the fleet's resources.
    private static func resourceID(_ reference: String) -> String { "secret:\(reference)" }

    /// The level the fleet manager may give a secret ("Reads it"), and nothing for one only the owner gives.
    private func managerLevel(_ reference: String) -> String? {
        guard let resources, let standing = resources.resource(Self.resourceID(reference))?.standing,
              case .grantable(let max, _) = standing else { return nil }
        return AccessSettings.levelName(max, kind: "secret")
    }

    /// Who may give one secret, at the hub, against the version of the resources the page read; then a new reading.
    /// The hub refuses a standing it would refuse in team.json, with its reason, and an old version (409), after which
    /// the new reading shows what is there now.
    private func saveStanding(_ standing: ResourceStanding, reference: String, entry: TeamLogin) async {
        guard canChange, let database = store.state?.db, let sha256 = resources?.sha256 else { return }
        let hub = store.hub, client = store.installation
        working = "standing \(reference)"; note = nil
        defer { working = nil }
        do {
            // The pool is signed before the manager may give the secret, and its end after (`GrantSigning`).
            if standing != .ownerOnly { try await GrantSigning.pool(true, login: reference, store: store, hub: hub, database: database) }
            let receipt = try await ResourcesClient().saveStanding(hub: hub, database: database, client: client,
                                                                   sha256: sha256, resource: Self.resourceID(reference),
                                                                   standing: standing)
            if standing == .ownerOnly { try await GrantSigning.pool(false, login: reference, store: store, hub: hub, database: database) }
            await read()
            if receipt.changed, case .grantable(let max, let to) = standing, let resources {
                note = (reference, String(l10n: "The fleet manager may give \(entry.name) to \(resources.audienceWords(to)), at most \(max)."), false)
            }
        } catch {
            await read()
            note = (reference, String(l10n: "Founderizer could not change this. \(Self.text(error))"), true)
        }
    }

    /// Removes one secret that nobody has from the catalog, against the team.json version of the last reading. The
    /// hub refuses while a grant or a profile lists it. Its value stays in the vaults.
    private func remove(_ reference: String, entry: TeamLogin) async {
        guard canChange, let database = store.state?.db, let sha256 = reading?.sha256 else { return }
        let hub = store.hub, client = store.installation
        working = reference; note = nil
        defer { working = nil }
        do {
            _ = try await HubClient().removeLogin(hub: hub, database: database, client: client, sha256: sha256, login: reference)
            close(); before = nil
            removed = String(l10n: "Removed “\(entry.name)” from Founderizer. Its value stays in the vaults.")
            await read()
        } catch { note = (reference, String(l10n: "Founderizer could not remove it. \(Self.text(error))"), true) }
    }

    /// **His words for a secret's note** (`POST /ui/team/logins` with `note`, UI-API 1.249), with its title as it is,
    /// against the team.json of the last reading; then a new reading, whose note the field shows (`SecretsRun.note`:
    /// the hub makes a note plain). A version that moved meanwhile is read again once: when the note itself changed
    /// there, the field shows that note and his words do not go; else they go again. `base`: the note that the field
    /// started from.
    private func saveNote(_ words: String, base: String, reference: String) async -> SecretsRun.NoteSave {
        guard offered, store.writesNow, let database = store.state?.db else { return .failed(String(l10n: "The hub did not answer.")) }
        guard reading?.catalog[reference] != nil else { return .gone }
        let hub = store.hub, client = store.installation
        return await SecretsRun.note(words, base: base, send: {
            guard let current = reading, let entry = current.catalog[reference] else { throw HubError.invalidResponse }
            _ = try await HubClient().saveLoginTitle(hub: hub, database: database, client: client, sha256: current.sha256,
                                                     login: reference, title: entry.title, note: words)
        }, reread: {
            guard await read() else { return .unread }
            return reading?.catalog[reference].map { .note($0.note ?? "") } ?? .gone
        }, reason: { HubError.said($0) ?? Self.text($0) })
    }

    // MARK: changes of several secrets

    /// The ticked secrets that the list shows now, in its order: what the bar acts on (`SecretsList.selected`).
    private var selectedNow: [SecretsList.Item] {
        reading.map { SecretsList.selected(fleetItems($0).all, ticked: ticked, words: words, agents: filterAgents.intersection(agents)) } ?? []
    }

    /// The hub's own sentence for a change that failed, with the secret and the agent it was for.
    private static func refusal(_ error: Error, secret: String, agent: String?) -> String {
        let words = HubError.said(error) ?? text(error)
        return agent.map { String(l10n: "\(secret) for \($0.agentLabel): \(words)") } ?? String(l10n: "\(secret): \(words)")
    }

    /// **Give access or Take access to the ticked secrets**: the catalog read once more (a give never lowers a read
    /// that came after the last reading), the plan made from it (`SecretsList.pairs`), then one call for each pair, one
    /// at a time, each as one click of the detail makes it (`SecretsRun.grants`: `GrantSigning` before a give and after
    /// a take-back, `SecretsClient.grant`), and one reading at the end. The run is the store's bar's (`SecretsBar`), so
    /// it goes on and shows on another visit of the page. A refusal is the bar's one line, in the hub's words, and the
    /// run stops there; a grant whose agent cannot use the secret yet is said there at the end, in the detail's words.
    private func bulkGrant(_ change: SecretsList.Change, chosen: Set<String>) async {
        guard change != .delete, canChange, let database = store.state?.db else { return }
        let bar = bar, hub = store.hub, client = store.installation
        bar.line = nil; bar.removed = nil; note = nil; removed = nil
        bar.work = BulkWork(change: change, total: 0, open: [])
        await read()
        guard store.hub == hub, store.state?.db == database else { bar.work = nil; return }
        let selected = selectedNow
        let pairs = SecretsList.pairs(change, secrets: selected, chosen: chosen, agents: agents)
        guard !pairs.isEmpty else { bar.work = nil; return }
        let entries = Dictionary(selected.map { ($0.reference, $0.entry) }, uniquingKeysWith: { first, _ in first })
        let store = store
        let run = await SecretsRun.grants(change, pairs: pairs, sign: { pair, level in
            try await GrantSigning.grant(level, login: pair.reference, agent: pair.agent, store: store, hub: hub, database: database)
        }, call: { pair, level in
            let receipt = try await SecretsClient().grant(hub: hub, database: database, client: client, login: pair.reference,
                                                          agent: pair.agent, grant: level)
            guard let entry = entries[pair.reference], let said = Self.note(receipt, entry: entry), said.warning else { return nil }
            return said.text
        }, progress: { done, open in
            bar.work = BulkWork(change: change, total: pairs.count, done: done, open: open)
        })
        await read()
        bar.work = nil
        if let failed = run.failed {
            bar.line = Self.refusal(failed.error, secret: entries[failed.pair.reference]?.name ?? failed.pair.reference, agent: failed.pair.agent)
        } else {
            bar.line = run.warning
        }
    }

    /// **Delete the ticked secrets that nobody holds** (`SecretsList.removal`, after one more reading of the catalog),
    /// as the detail's own removal does, one at a time (`SecretsRun.removals`): each against the version of team.json
    /// that the one before left, once more after a version that moved meanwhile while nobody holds the secret, and one
    /// reading at the end. A ticked secret that is still held stays ticked, and the bar's line says so; the removed ones
    /// are said in the line over the list.
    private func bulkDelete() async {
        guard canChange, let database = store.state?.db else { return }
        let bar = bar, hub = store.hub, client = store.installation
        bar.line = nil; bar.removed = nil; note = nil; removed = nil
        bar.work = BulkWork(change: .delete, total: 0, open: [])
        await read()
        guard store.hub == hub, store.state?.db == database, let sha256 = reading?.sha256 else { bar.work = nil; return }
        let selected = selectedNow
        let plan = SecretsList.removal(selected)
        let names = Dictionary(selected.map { ($0.reference, $0.entry.name) }, uniquingKeysWith: { first, _ in first })
        var run = SecretsRun.Removals()
        if !plan.removes.isEmpty {
            run = await SecretsRun.removals(plan.removes, sha256: sha256, remove: { reference, version in
                try await HubClient().removeLogin(hub: hub, database: database, client: client, sha256: version, login: reference).sha256
            }, reread: { reference in
                await read()
                guard let fresh = reading, let entry = fresh.catalog[reference] else { return nil }
                return (fresh.sha256, !fresh.holders(reference, entry, agents: agents).isEmpty)
            }, progress: { done, open in
                bar.work = BulkWork(change: .delete, total: plan.removes.count, done: done, open: open)
            })
            before = nil
            await read()
        }
        bar.work = nil
        bar.ticked.subtract(run.gone)
        if run.gone.count == 1, let name = names[run.gone[0]] {
            bar.removed = String(l10n: "Removed “\(name)” from Founderizer. Its value stays in the vaults.")
        } else if run.gone.count > 1 {
            bar.removed = String(l10n: "Removed \(run.gone.count) secrets from Founderizer. Their values stay in the vaults.")
        }
        if let failed = run.failed {
            bar.line = Self.refusal(failed.error, secret: names[failed.reference] ?? failed.reference, agent: nil)
        } else if !plan.held.isEmpty {
            bar.line = SecretsList.heldWords(plan.held.count)
        }
    }

    // MARK: reading

    /// Reads the catalog every 15 seconds while the page shows, and again after 3 seconds when a read failed. Another
    /// hub or hub generation starts again without the form of the old connection; its readings are the store's, which
    /// keeps none of another hub or generation.
    private func poll() async {
        failedSince = nil; before = nil; adding = false; importing = false; note = nil; shown = nil; removed = nil
        let start = ContinuousClock.now
        while !Task.isCancelled {
            let current = await read(since: start)
            do { try await store.nap(current || !offered ? 15 : 3) } catch { return }
        }
    }

    /// One reading. A failed read keeps the last one, which then shows as the last reading.
    @discardableResult private func read(since start: ContinuousClock.Instant? = nil) async -> Bool {
        guard offered, store.isFresh, let database = store.state?.db else { return false }
        let hub = store.hub, client = HubClient(), withProfiles = store.state?.ui_features?.contains("profiles") == true
        let first = reading == nil
        guard let team = try? await client.team(hub: hub, database: database) else {
            if first, let start { await store.settle(since: start) }
            if !Task.isCancelled, store.hub == hub, store.state?.db == database {
                if failedSince == nil { failedSince = .now }
            }
            return false
        }
        let profiles = withProfiles ? try? await client.profiles(hub: hub, database: database) : nil
        // A failed read of who may give them keeps the last one: the catalog is what this page is about.
        let standings = store.state?.ui_features?.contains(ResourceList.feature) == true
            ? try? await AccessSettings.readResources(store, agent: agent, hub: hub, database: database) : nil
        guard !Task.isCancelled else { return false }
        if first, let start { await store.settle(since: start) }
        guard store.hub == hub, store.state?.db == database else { return false }
        reading = LoginReading(team: team, profiles: profiles?.profiles); failedSince = nil
        // A tick of a secret that left the catalog goes, so the bar never counts one that is no longer there.
        if agent == nil { bar.ticked.formIntersection((team.logins ?? [:]).keys) }
        store.keep(team, as: "team.snapshot")
        if let standings { resources = standings }
        return true
    }
}

extension FleetStore {
    /// **The card of the secret of this name, over the page where he is** (the owner, 21 November 2026: "task cards in
    /// both agents chat and needs you sohuld also have a badge for specific Credentials, like we have for agents! ideally
    /// a modal of that key should open so it can be edited right there after clicking it", and "Yes, both" to its
    /// drawing): the key badge of a request's card calls it, and the card shows over the chat, Needs you or a job's
    /// card (`secretCard`), never on Settings › Secrets. True when the kept reading of the fleet's secrets has exactly
    /// one secret of that name (`SecretsList.reference(named:in:)`); else nothing opens.
    @discardableResult func showSecret(named name: String) -> Bool {
        guard SecretEntryView.isOffered(by: self), let kept: LoginReading = reading("secrets.logins.fleet"),
              let reference = SecretsList.reference(named: name, in: kept.catalog) else { return false }
        secretCard = SecretCard(id: reference)
        return true
    }

    /// **The names that a card's badges take** (`CardNames`), with the kind of each for its mark (true: an API key's
    /// `key.horizontal`, else a login's `person.badge.key`): each name that one secret of the kept reading has, so a
    /// badge always opens a card (`showSecret(named:)`). Empty on a hub without Add secret and its grants
    /// (`SecretEntryView.isOffered`), and before the first reading.
    var cardSecrets: [(name: String, key: Bool)] {
        guard SecretEntryView.isOffered(by: self), let kept: LoginReading = reading("secrets.logins.fleet") else { return [] }
        return SecretsList.badges(kept.catalog)
    }
}

/// **The faces of the agents that hold a secret**, as a group shows its members: each agent's glyph at the size beside
/// a name, on a ring of the card's colour, each one over the next and 6 points over it, with no status dot (the
/// owner's "yes as drawn" of 20 November 2026). Their names stand after them, in words that VoiceOver reads.
private struct HolderFaces: View {
    let names: [String]
    @Environment(\.cardFill) private var cardFill
    /// The ring of the card's colour around each glyph, which parts it from the one under it.
    private static let ring: CGFloat = 1.5

    var body: some View {
        HStack(spacing: -(6 + 2 * Self.ring)) {
            ForEach(Array(names.enumerated()), id: \.element) { index, name in
                AgentGlyph(name: name, size: GlyphSize.inline, dot: false)
                    .padding(Self.ring)
                    .background(cardFill, in: Circle())
                    .zIndex(Double(names.count - index))
            }
        }
        .accessibilityHidden(true)
    }
}

/// **A secret's note in its detail** (owner feature `secret_notes`): one line of at most the hub's 200 characters, the
/// mark of who wrote what stands there (him, or an agent; the word on hover), and his own words saved as he leaves the
/// field, presses Return or closes the card, with the save's mark beside it (`SaveMark`). After a save the field shows
/// the note as the hub keeps it (`SecretsRun.NoteSave`). Empty words take the note away. Words that look like a key do
/// not go: a note is never a key.
private struct SecretNoteField: View {
    /// The note as the hub gives it now, and who wrote it (`owner` or `agent`).
    let note: String
    let by: String?
    let canChange: Bool
    /// His words and the note that the field started from.
    let save: (_ words: String, _ base: String) async -> SecretsRun.NoteSave
    @State private var text: String
    @State private var state: SaveState?
    @FocusState private var focused: Bool

    init(note: String, by: String?, canChange: Bool, save: @escaping (_ words: String, _ base: String) async -> SecretsRun.NoteSave) {
        self.note = note; self.by = by; self.canChange = canChange; self.save = save
        _text = State(initialValue: note)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if !note.isEmpty {
                    let owner = by == "owner"
                    Image(systemName: owner ? "person" : "sparkles").font(IconMetrics.symbol(13)).foregroundStyle(FleetStyle.muted)
                        .frame(width: 18).help(owner ? String(l10n: "You") : String(l10n: "An agent"))
                        .accessibilityLabel(owner ? String(l10n: "You") : String(l10n: "An agent"))
                        .accessibilityIdentifier("secret-note-by")
                }
                TextField(text: $text, prompt: Text(verbatim: "")) { Text("Note") }
                    .fieldPlaceholder(String(l10n: "Note"), shows: text.isEmpty)
                    .fleetField(focus: $focused)
                    .disabled(!canChange || state == .saving)
                    .onSubmit { Task { await send() } }
                    .accessibilityIdentifier("secret-note")
                SaveMark(state: state) { Task { await send(again: true) } }
            }
            if let failure = state?.failure {
                Text(failure).font(FormMetrics.detail).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
        .animation(SaveState.lineMotion, value: state?.failure)
        // The field holds no more than the hub keeps, counted as the hub counts (`NeedSecret.noteLength`).
        .onChange(of: text) { _, now in
            if NeedSecret.noteLength(now) > NeedSecret.noteMost { text = NeedSecret.cut(now, most: NeedSecret.noteMost, note: true) }
        }
        .onChange(of: focused) { _, now in if !now { Task { await send() } } }
        // **Done, Esc or a click outside closes the card with the cursor still in the field: his words go then.** They
        // are taken here, while the field still stands, and the save is the page's, so it ends after the card has gone.
        .onDisappear {
            let words = NeedSecret.oneLine(text, most: NeedSecret.noteMost)
            guard canChange, state != .saving, words != note, !KeyInText.contains(words) else { return }
            let save = save, base = note
            Task { _ = await save(words, base) }
        }
        // A note that changed at the hub shows, unless he is writing his own.
        .onChange(of: note) { _, now in if !focused && state != .saving { text = now } }
    }

    /// His words, when they are not the note that stands: one plain line, as the hub keeps it.
    private func send(again: Bool = false) async {
        let words = NeedSecret.oneLine(text, most: NeedSecret.noteMost)
        guard canChange, state != .saving, again || words != note else { return }
        guard words != note else { state = nil; text = note; return }
        if KeyInText.contains(words) { state = .failed(SecretEntryView.keyInNote); return }
        state = .saving
        switch await save(words, note) {
        case .saved(let now):
            text = now; state = .saved
            try? await Task.sleep(for: .seconds(3))
            if state == .saved { state = nil }
        case .changedElsewhere(let now):
            text = now; state = .changedElsewhere
        case .gone:
            state = .failed(String(l10n: "This secret is no longer in the list."))
        case .failed(let reason):
            state = .failed(reason)
        }
    }
}
