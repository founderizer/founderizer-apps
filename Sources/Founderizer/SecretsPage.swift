import FleetCore
import SwiftUI

/// One reading of the catalog (`GET /ui/team`, feature `secrets`) and of its use: which agents list each reference in
/// their profile (the older grant).
private struct LoginReading: Sendable {
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

    /// The agents that have one secret: a grant, or a profile that lists it, in the hub's order.
    func holders(_ reference: String, _ entry: TeamLogin, agents: [String]) -> [String] {
        agents.filter { entry.grants?[$0] != nil || listed?[reference]?.contains($0) == true }
    }
}

/// What an agent's control of an API key offers.
private enum SecretChoice: Hashable { case use, read, none }

/// The secret whose detail shows over the page, by its reference.
private struct ShownSecret: Identifiable { let id: String }

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
struct SecretsPage: View {
    @Bindable var store: FleetStore
    /// One agent's own: only the secrets it has. nil is the fleet's own list.
    var agent: String?
    /// A group of the agent's Can use: the heading with its + (`giveMenu`), and the rows, each with its −, or the empty
    /// card when the agent has none.
    var grouped = false
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
    /// The last read failed. `reading` is then the last good one, or nil.
    @State private var failed = false
    /// When this visit began: a kept list that this visit reads again is not old before that read has had a second.
    @State private var opened = ContinuousClock.now
    /// The form of Add secret shows in the list's place.
    @State private var adding = false
    /// The import of secrets from another password manager shows in the list's place (`SecretImportView`).
    @State private var importing = false
    /// The catalog's references when Add secret opened. A reference that comes later is the result of that visit.
    @State private var before: Set<String>?
    @State private var copied: String?
    @State private var shown: ShownSecret?
    /// The change that the hub works on now: "reference agent" for a grant, the reference for a removal.
    @State private var working: String?
    /// The result or the problem of the last change, in its secret's detail.
    @State private var note: (login: String, text: String, warning: Bool)?
    /// A removal's result, over the list.
    @State private var removed: String?

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
    private var canChange: Bool { offered && store.isFresh && working == nil }
    private var agents: [String] { store.state?.agents.map(\.name) ?? [] }
    /// The central vault of this hub (owner feature `central_vault`), which the store keeps in order by itself: this
    /// page shows only its rows that need the owner, and each secret's servers. A hub without it shows none of them.
    private var vault: CentralVaultModel { store.vaultModel() }

    var body: some View {
        Group { if importing && offered { importPage } else if adding && offered { addPage } else { list } }
            .task(id: "\(store.hub)/\(store.state?.db ?? "")/\(offered)") { await poll() }
    }

    // MARK: list

    @ViewBuilder private var list: some View {
        if grouped {
            VStack(alignment: .leading, spacing: FleetSpace.block) { listContent }
                .fleetModal(item: $shown) { detail($0.id) }
        } else {
            FleetPage("Secrets") { listContent } actions: {
                // The page's one group has no heading, so its old-reading line stands with the header's actions.
                if reading != nil { lastReading }
                if offered {
                    Button {
                        note = nil; removed = nil
                        // As for Add secret: what is new after the import comes from the reading.
                        Task {
                            if reading == nil { await read() }
                            before = reading.map { Set($0.catalog.keys) }; importing = true
                        }
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }.buttonStyle(FleetOutlineButtonStyle()).accessibilityIdentifier("secret-import")
                    Button {
                        note = nil; removed = nil
                        // What is new after the form comes from the reading: a press that comes before the first one
                        // waits for it.
                        Task {
                            if reading == nil { await read() }
                            before = reading.map { Set($0.catalog.keys) }; adding = true
                        }
                    } label: {
                        Label("Add secret", systemImage: "plus")
                    }.buttonStyle(FleetPrimaryButtonStyle()).accessibilityIdentifier("secret-add")
                }
            }
            .fleetModal(item: $shown) { detail($0.id) }
        }
    }

    @ViewBuilder private var listContent: some View {
        Group {
            if agent == nil { CentralVaultSection(store: store, model: vault) }
            if !offered {
                FormSection(grouped ? "Secrets" : nil) {
                    FormEmpty(store.state?.ui_features?.contains(SecretEntryView.feature) == true
                              ? "Update the hub to add and share secrets here." : "This hub does not list its secrets yet.", symbol: "key")
                }
            } else if let reading { catalog(reading) }
            else if failed || !store.isFresh {
                // **Not while the window's notice says the outage** (`FleetStore.hubNoticeShows`; fix round 3, item 33:
                // an outage is said once): an agent's group keeps its heading alone, as while it reads.
                if !store.hubNoticeShows {
                    FormSection(grouped ? "Secrets" : nil) {
                        FormRow("Founderizer cannot read the secrets now.", detail: "It reads again when the hub answers.")
                    }
                } else if grouped {
                    FormSection("Secrets") { EmptyView() }
                }
            } else {
                if grouped { FormSection("Secrets") { EmptyView() } }
                LoadingLine("Reading the secrets…")
            }
        }
    }

    @ViewBuilder private func catalog(_ reading: LoginReading) -> some View {
        let entries = reading.catalog.sorted { ($0.value.name.lowercased(), $0.key) < ($1.value.name.lowercased(), $1.key) }
            .filter { entry in agent.map { reading.holders(entry.key, entry.value, agents: agents).contains($0) } ?? true }
        let added = before.map { known in entries.filter { !known.contains($0.key) } } ?? []
        if let removed {
            Label(removed, systemImage: "checkmark.circle").font(FormMetrics.text).foregroundStyle(FleetStyle.text)
                .accessibilityIdentifier("secret-removed")
        } else if !added.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "checkmark.circle").foregroundStyle(.green)
                Text("\(added.map { "“\($0.value.name)”" }.joined(separator: ", ")) \(added.count == 1 ? "is" : "are") in the list.")
                    .fixedSize(horizontal: false, vertical: true)
            }.font(FormMetrics.text).foregroundStyle(FleetStyle.text).accessibilityIdentifier("secret-added")
        }
        if !reading.hasCatalog {
            FormSection { FormRow("The hub gave no list of secrets that Founderizer can read.", symbol: "exclamationmark.circle") }
        } else {
            // No line under the list about what a click does: the row's own ⓘ says it, as on Apps. As a group of an
            // agent's Can use, the empty card when the agent has none, and the + that gives it one more (the owner's
            // yes of 3 November 2026).
            FormSection(grouped ? "Secrets" : nil) {
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

    /// **The + of an agent's Secrets** (the owner's yes of 3 November 2026): the catalog's secrets that this agent does
    /// not have, in the app's list; one choice gives it (`use`: its vault uses it, and the agent never sees it), as
    /// Give in the secret's detail does. Only while there is one to give and the hub answers; it waits while a change
    /// goes on.
    @ViewBuilder private func giveMenu(_ reading: LoginReading) -> some View {
        if let agent, offered, store.isFresh {
            let open = reading.catalog.filter { !reading.holders($0.key, $0.value, agents: agents).contains(agent) }
                .sorted { ($0.value.name.lowercased(), $0.key) < ($1.value.name.lowercased(), $1.key) }
            if !open.isEmpty {
                let words = "Give \(agent.agentLabel) a secret"
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
    /// so nothing under it moves when it comes or goes: every group of Can use moved 38 pt down and back.
    @ViewBuilder private var lastReading: some View {
        if failed || !store.isFresh {
            Held(since: opened) {
                Label("Last reading", systemImage: "clock.arrow.circlepath")
                    .font(FormMetrics.detail).foregroundStyle(.orange).lineLimit(1)
                    .help("Founderizer reads the secrets again when the hub answers.")
                    .accessibilityIdentifier("secrets-last-reading")
            }
        }
    }

    /// One secret: its kind as a mark, its name, its kind and the agents that have it. A click opens its detail.
    private func row(_ reference: String, _ entry: TeamLogin, reading: LoginReading, isNew: Bool) -> some View {
        let summary = "\(entry.isAPIKey ? "API key" : "Login") · \(agentWords(reading.holders(reference, entry, agents: agents)))"
        return Button { note = nil; shown = ShownSecret(id: reference) } label: {
            HStack(spacing: 12) {
                IconTile(symbol: entry.isAPIKey ? "key.horizontal" : "person.badge.key")
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(entry.name).font(entry.isAPIKey ? FormMetrics.title.monospaced() : FormMetrics.title)
                            .foregroundStyle(FleetStyle.text).lineLimit(1)
                        if isNew {
                            Text("New").font(FormMetrics.detailTitle).padding(.horizontal, 6).padding(.vertical, 1.5)
                                .background(Color.green.opacity(0.2), in: Capsule())
                        }
                    }
                    Text(summary).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).lineLimit(1)
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
            }.padding(.horizontal, FormMetrics.rowInset).frame(minHeight: FormMetrics.twoLineRow)
        }
        .buttonStyle(FleetRowButtonStyle())
        .help("Show which agents can use \(entry.name)")
        .accessibilityLabel(([entry.name, summary] + [managerLevel(reference).map { "Manager may give: \($0)" }].compactMap { $0 })
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
            IconButton(symbol: "minus", words: "Take \(entry.name) back from \(name)") {
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
                        MessageAction(symbol: copied == reference ? "checkmark" : "square.on.square", label: "Copy the reference",
                                      help: "Copy its reference, \(reference)", height: 16) { copyMessage(reference); copied = reference }
                            .foregroundStyle(FleetStyle.muted)
                    }
                }
                Spacer(minLength: 12)
                Button("Done") { shown = nil }.buttonStyle(FleetOutlineButtonStyle()).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("secret-done")
            }
            if let entry, let reading {
                let holders = reading.holders(reference, entry, agents: agents)
                FormSection("Available to", footer: entry.isAPIKey
                            ? "Agents use the key without seeing it. With Reads it, the key is in the agent's sessions."
                            : "Agents sign in with it. They never see the password.") {
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
        let words = grant == .read ? "Reads it in its sessions" : grant == .use ? "Can use it" : listed ? "Can use it (its profile)" : "No access"
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
            FleetOption(SecretChoice.use, "Uses it", subtitle: "\(name) uses the key and never sees it.", mark: .symbol("lock")),
            FleetOption(SecretChoice.read, "Reads it", subtitle: "The key is in its sessions as $\(entry.name). \(name) can copy it.",
                        mark: .symbol("eye")),
            FleetOption(SecretChoice.none, "Take it back", mark: .symbol("slash.circle")),
        ]
        return FleetSelect("Access of \(name)", options: rows, selection: reads ? SecretChoice.read : SecretChoice.use) { choice in
            let next: SecretGrant? = choice == .read ? .read : choice == .use ? .use : nil
            Task { await setGrant(next, agent: agent, reference: reference, entry: entry) }
        } label: {
            FleetSelectLabel(title: reads ? "Reads it" : "Uses it", mark: .symbol(reads ? "eye" : "lock"))
        }.disabled(!canChange)
    }

    // MARK: add

    /// Add secret, in the list's place, with Back: the form, with the agents that get the new secret under its
    /// fields. The form shows a save that is not finished when it opens. Its Cancel and Close, and a finished save,
    /// come back here; the list then reads the catalog again, and a saved secret opens its detail.
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

    /// After the form: the list reads the catalog again, and the secret that the form saved opens its detail with each
    /// agent's access and each vault. Cancel saves nothing.
    private func finishAdd(_ reference: String?) {
        adding = false
        Task {
            guard await read(), let reference, reading?.catalog[reference] != nil else { return }
            shown = ShownSecret(id: reference)
        }
    }

    // MARK: changes

    private static func text(_ error: Error) -> String { (error as? LocalizedError)?.errorDescription ?? "The hub did not answer." }

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
            return ("Founderizer could not change this for \(agent.agentLabel). \(Self.text(error))", true)
        }
    }

    /// What the owner must know after a grant: the agent's vault access, or when it reads the key.
    private static func note(_ receipt: SecretGrantReceipt, entry: TeamLogin) -> (text: String, warning: Bool)? {
        let name = receipt.agent.agentLabel
        if let vault = receipt.vault {
            if vault.after == "broker" { return ("\(name) uses its server's vault now.", false) }
            let reasons = (vault.missing ?? []).map(VaultAccessControl.reason).joined(separator: " ")
            return ("\(name) has it, but it has no vault access yet, so it cannot use it now. \(reasons)", true)
        }
        if receipt.grant == SecretGrant.read.rawValue && receipt.changed {
            return ("\(name) reads $\(entry.name) in its sessions from their next start.", false)
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
                note = (reference, "The fleet manager may give \(entry.name) to \(resources.audienceWords(to)), "
                        + "at most \(max).", false)
            }
        } catch {
            await read()
            note = (reference, "Founderizer could not change this. \(Self.text(error))", true)
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
            shown = nil; before = nil
            removed = "Removed “\(entry.name)” from Founderizer. Its value stays in the vaults."
            await read()
        } catch { note = (reference, "Founderizer could not remove it. \(Self.text(error))", true) }
    }

    // MARK: reading

    /// Reads the catalog every 15 seconds while the page shows, and again after 3 seconds when a read failed. Another
    /// hub or hub generation starts again without the form of the old connection; its readings are the store's, which
    /// keeps none of another hub or generation.
    private func poll() async {
        failed = false; before = nil; adding = false; importing = false; note = nil; shown = nil; removed = nil
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
            if !Task.isCancelled, store.hub == hub, store.state?.db == database { failed = true }
            return false
        }
        let profiles = withProfiles ? try? await client.profiles(hub: hub, database: database) : nil
        // A failed read of who may give them keeps the last one: the catalog is what this page is about.
        let standings = store.state?.ui_features?.contains(ResourceList.feature) == true
            ? try? await AccessSettings.readResources(store, agent: agent, hub: hub, database: database) : nil
        guard !Task.isCancelled else { return false }
        if first, let start { await store.settle(since: start) }
        guard store.hub == hub, store.state?.db == database else { return false }
        reading = LoginReading(team: team, profiles: profiles?.profiles); failed = false
        store.keep(team, as: "team.snapshot")
        if let standings { resources = standings }
        return true
    }
}
