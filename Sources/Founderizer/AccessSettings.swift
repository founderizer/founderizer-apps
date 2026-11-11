import FleetCore
import SwiftUI

/// What one dropdown of the detail offers: who may give this resource.
private enum StandingChoice: Hashable { case owner, manager }

/// The resource whose detail shows over the page, by its id.
private struct ShownResource: Identifiable { let id: String }

/// The list of what the fleet holds of one kind — repositories, MCP servers, secrets and deploy routes, Drive and
/// mail accounts — and, for each one, **which agents may use it**. Settings › Apps shows it for the fleet, and an
/// agent's own Can use shows it from that agent's end.
///
/// It is one relation seen from both ends: an item is in the fleet, and each agent either may use it or may not.
/// One item, many agents, on the fleet's page; one agent, many items, on the agent's. Nothing is "global" or "for
/// one agent only": there is no second kind of entry.
///
/// A click on a row opens the item: what a duty needs it for, where its credential is, the agents that may use it
/// (which this page writes, and where No access takes it back), who may hand it out (the standing), and the record of
/// who gave what and when. The record reads here and not on an agent, because the question it
/// answers starts at the item: who can reach this repository?
///
/// Bringing a credential into the fleet stays the owner's: it is their account, their money and their liability.
/// Handing out something the fleet already holds can be the fleet manager's, so each item carries one standing,
/// and nothing is grantable until the owner says so. The grant is the authorization: an agent that holds an item
/// does what that access allows and answers for it, and nothing asks the owner a second time.
///
/// There is no list of every kind at once any more. Settings › Access was that list, and each of its items was
/// already a row of its own kind's section with the same detail behind it (the owner, 24 October 2026: "there
/// shouldn't even be an Access section, right? it's all done in each specific section!"). Which items the fleet
/// manager may hand out reads on each row instead, where the manager may.
struct AccessSettings: View {
    @Bindable var store: FleetStore
    /// The kinds this list shows: `secret`, `repo`, `tool`, `drive`, `gmail`. Empty shows them all.
    var kinds: [String] = []
    /// One agent's own: only what it holds, each row with its − and the empty card when it holds none (`agentList`);
    /// its heading's + is `AccessGive`. The card that a row opens still gives and takes back for every agent.
    var agent: String?
    /// **The room over it, under its group's heading** (`AppsSettings`), and none while it draws nothing (margins row
    /// 20). The empty list took the group's 10 points, and Apps' four groups stood 60 apart.
    var lead: CGFloat = 0
    /// The store's (`FleetStore.reading`), the fleet's pages' and each agent's under its own name (`name`): the list he
    /// saw last shows in the first frame when he comes back, and the read that starts then changes only what changed.
    private var reading: ResourceList? {
        get { store.reading(Self.name(agent)) } nonmutating set { store.keep(newValue, as: Self.name(agent)) }
    }
    /// The last read failed. `reading` is then the last good one, or nil. It is the reading's, kept beside it, so the
    /// lists that draw one reading (an agent's Apps has three) agree on it whichever of them read last.
    private var failed: Bool {
        get { store.reading(Self.name(agent) + ".failed") ?? false }
        nonmutating set { store.keep(newValue, as: Self.name(agent) + ".failed") }
    }
    @State private var shown: ShownResource?
    /// The resource whose standing the hub works on now, or "<resource> <agent>" while a hold ends.
    @State private var working: String?
    /// The result or the problem of the last change, in its resource's detail.
    @State private var note: (resource: String, text: String, warning: Bool)?
    /// The rows of an agent's repositories that he opened, each "<agent> <owner>/<level>" (`repositoryRows`): closed again
    /// when the page opens again.
    @State private var opened: Set<String> = []

    private var offered: Bool { store.state?.ui_features?.contains(ResourceList.feature) == true }
    private var canChange: Bool { offered && store.isFresh && working == nil }

    /// The name of the fleet's resources, or of one agent's: the MCPs and Apps lists and the Secrets page draw it.
    nonisolated static func name(_ agent: String?) -> String { "resources.\(agent ?? "fleet")" }
    /// The words behind the orange mark of a repository that the hub's GitHub App does not reach.
    static let unreachedWords = "The GitHub App cannot reach this repository"
    /// The resources, read before the page first opens (`PagePrefetch`): the fleet's, and each agent's.
    static let prefetch = PagePrefetch(name(nil), feature: ResourceList.feature) {
        try await ResourcesClient().read(hub: $0, database: $1)
    }
    static let agentPrefetch = PagePrefetch(agent: { name($0) }, feature: ResourceList.feature) { hub, database, _ in
        try await ResourcesClient().read(hub: hub, database: database)
    }
    /// **"Last reading", in the heading row of the page's first group** (review B17, fix round 2; as Secrets): one line
    /// for the one reading that Apps draws in its lists, and only once this visit's read has had its second (`Held`).
    /// It stood as a row over the first list — 51 ms after the page opened, and at its second once `Held` worked — and
    /// every group under it moved down 37 pt and back.
    @ViewBuilder static func lastReading(_ store: FleetStore, agent: String?, since opened: ContinuousClock.Instant) -> some View {
        let failed: Bool = store.reading(name(agent) + ".failed") ?? false
        if (store.reading(name(agent)) as ResourceList?) != nil && (failed || !store.isFresh) {
            Held(since: opened) {
                Label("Last reading", systemImage: "clock.arrow.circlepath")
                    .font(FormMetrics.detail).foregroundStyle(.orange).lineLimit(1)
                    .help("Founderizer reads the resources again when the hub answers.")
            }
        }
    }

    /// The resources, read once for every list of a page that is reading them now (`FleetStore.read`).
    static func readResources(_ store: FleetStore, agent: String?, hub: URL, database: String) async throws -> ResourceList {
        try await store.read(name(agent)) { try await ResourcesClient().read(hub: hub, database: database) }
    }

    var body: some View {
        // A section of a page, never a page: the page around it brings the title, the column and the scroll.
        VStack(alignment: .leading, spacing: FleetSpace.block) { items }
            .padding(.top, drawsNothing ? 0 : lead)
            .fleetModal(item: $shown) { detail($0.id) }
            .task(id: "\(store.hub)/\(store.state?.db ?? "")/\(offered)") { await poll() }
    }

    @ViewBuilder private var items: some View {
        if !offered {
            FormSection { FormEmpty("Update the hub to give access from here.", symbol: "square.stack.3d.up") }
        } else if let reading { list(reading) }
        else if failed || !store.isFresh {
            // **Not while the window's notice says the outage** (`FleetStore.hubNoticeShows`; fix round 3, item 33: an
            // outage is said once): the line stands only where no notice over the page says why.
            if !store.hubNoticeShows {
                FormSection { FormRow("Founderizer cannot read the resources now.", detail: "It reads again when the hub answers.") }
            }
        } else { LoadingLine("Reading the resources…") }
    }

    // MARK: list

    /// The list draws nothing: a list with no reading says nothing while the window's notice says why it cannot read
    /// (`items`). An agent's list of one kind always draws its card, empty or not (`agentList`).
    private var drawsNothing: Bool {
        guard offered else { return false }
        guard let reading else { return (failed || !store.isFresh) && store.hubNoticeShows }
        return !(agent != nil && kinds.count == 1) && groups(reading).isEmpty
    }

    @ViewBuilder private func list(_ reading: ResourceList) -> some View {
        if let agent, kinds.count == 1 {
            agentList(reading, agent: agent, kind: kinds[0])
        } else {
            // Its "Last reading" stands in the heading row of the page's first group (`lastReading`).
            ForEach(groups(reading)) { group in
                // Only the rows on the screen: Mia's repositories and the fleet's are lists of hundreds (`FormSection.lazy`).
                FormSection(kinds.count == 1 ? nil : group.kind.title, lazy: true) {
                    let items = shown(group.resources)
                    if items.isEmpty && agent == nil { FormEmpty(empty(group.kind), symbol: Self.symbol(group.kind.kind)) }
                    ForEach(items) { row($0, kind: group.kind, reading: reading) }
                }
            }
        }
    }

    /// **One kind of an agent's Can use** (the owner, 3 November 2026: "it is weird to show the categories there like
    /// empty... show like an empty card ... we should be able to MANAGE the existing ones for the Agent from its own
    /// screen too", and his yes to a + on each heading and a − on each row): the card of what it holds, or the empty
    /// card; each row with its −; and under the card, the hub's words when the + of the heading (`AccessGive`) or a −
    /// was refused.
    @ViewBuilder private func agentList(_ reading: ResourceList, agent: String, kind: String) -> some View {
        let held = reading.resources.filter { $0.kind == kind && $0.holders.contains { $0.agent == agent } }
        let info = reading.kinds.first { $0.kind == kind }
        VStack(alignment: .leading, spacing: FleetSpace.inside) {
            FormSection(lazy: true) {
                if held.isEmpty { FormEmpty(Self.emptyForAgent(kind), symbol: Self.symbol(kind)) }
                if let info {
                    if kind == "repo" { repositoryRows(held, agent: agent, kind: info, reading: reading) }
                    else { ForEach(held) { row($0, kind: info, reading: reading) } }
                }
            }
            if let said: String = store.reading(Self.saidName(agent, kind: kind)) {
                Text(said).font(FormMetrics.detail).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled).accessibilityIdentifier("access-said-\(kind)")
            }
        }
    }

    /// **An agent's repositories, an owner's at one level as one row once there are more than three** (the owner's yes
    /// of 9 November 2026 to "AbcCorp 179 Read" as one row, and of 11 November 2026 to its picture on ABC
    /// Developer's Can use: "Yes, as shown"): the rows of its 179 repositories stood one by one. In the order of
    /// `Integrations.groups`: by owner, then from the lowest level to the highest. A row of an owner opens to its
    /// repositories' own rows, each with its card and its −.
    @ViewBuilder private func repositoryRows(_ held: [FleetResource], agent: String, kind: ResourceKind,
                                             reading: ResourceList) -> some View {
        let byName = Dictionary(held.map { ($0.what, $0) }) { first, _ in first }
        let levels = byName.mapValues { resource in
            resource.holders.first { $0.agent == agent }.flatMap { RepositoryAccess(rawValue: $0.level) } ?? .read
        }
        ForEach(Integrations.groups(levels), id: \.id) { group in
            let resources = group.repos.compactMap { byName[$0] }
            if group.grouped { groupRow(group, resources: resources, agent: agent, reading: reading) }
            if !group.grouped || opened.contains("\(agent) \(group.id)") {
                ForEach(resources) { row($0, kind: kind, reading: reading) }
            }
        }
    }

    /// **One owner's repositories at one level, in one row**: the account as GitHub writes it, how many, the level and a
    /// chevron in the column of the rows' −. A click opens it to their own rows and closes it again. It carries the orange
    /// mark of a row in it that the GitHub App does not reach, as Apps' GitHub row does.
    private func groupRow(_ group: RepositoryGroup, resources: [FleetResource], agent: String,
                          reading: ResourceList) -> some View {
        let key = "\(agent) \(group.id)", open = opened.contains(key)
        let list: RepositoryList? = store.reading(RepositoryPicking.listName)
        let account = list?.account(group.owner) ?? group.owner
        let level = Self.levelName(group.access.rawValue, kind: "repo")
        let unreached = resources.contains { reading.unreachedPage($0) != nil }
        return Button { if open { opened.remove(key) } else { opened.insert(key) } } label: {
            HStack(spacing: 12) {
                IconTile(symbol: Self.symbol("repo"))
                Text(account).font(FormMetrics.title).foregroundStyle(FleetStyle.text).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 12)
                if unreached {
                    Image(systemName: "exclamationmark.triangle.fill").font(IconMetrics.symbol(13)).foregroundStyle(.orange)
                        .help(Self.unreachedWords).accessibilityHidden(true)
                }
                HStack(spacing: 10) {
                    Text("\(group.repos.count)").monospacedDigit()
                    Text(level)
                }.font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).lineLimit(1).fixedSize()
                Image(systemName: open ? "chevron.down" : "chevron.right").font(IconMetrics.symbol(11, weight: .semibold))
                    .foregroundStyle(FleetStyle.muted).frame(width: IconMetrics.side, height: IconMetrics.side)
            }.padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 10)
        }
        .buttonStyle(FleetRowButtonStyle())
        .help(open ? "Hide these repositories" : "Show these repositories")
        .accessibilityLabel("\(account), \(group.repos.count) repositories, \(level)" + (unreached ? ", \(Self.unreachedWords)" : ""))
        .accessibilityValue(open ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("access-repo-group-\(group.id)")
        // The account as GitHub writes it, from the list that the + reads; until then, as team.json keeps it.
        .task(id: "\(store.hub)/\(store.state?.db ?? "")") { await RepositoryPicking.keepNames(store) }
    }

    /// The empty card of one kind on an agent's Can use, under its heading, which already names the kind.
    private static func emptyForAgent(_ kind: String) -> String {
        switch kind {
        case "tool": "No MCP servers"
        case "repo": "No repositories"
        case "gmail", "drive": "No accounts"
        case "secret": "No secrets"
        default: "None"
        }
    }

    /// The hub's words of the last refused + or − of one kind on an agent's Can use, kept by the store so that the
    /// heading's + and the list's rows, two views, say it in one place.
    nonisolated static func saidName(_ agent: String, kind: String) -> String { "\(name(agent)).said.\(kind)" }

    /// The groups this list shows, in the order the hub gives them.
    private func groups(_ reading: ResourceList) -> [ResourceGroup] {
        kinds.isEmpty ? reading.groups : reading.groups.filter { kinds.contains($0.kind.kind) }
    }

    /// One agent's list holds what that agent may use; the fleet's holds everything.
    private func shown(_ resources: [FleetResource]) -> [FleetResource] {
        guard let agent else { return resources }
        return resources.filter { $0.holders.contains { $0.agent == agent } }
    }

    /// One line for an empty list, the same on the fleet's page and on an agent's: "No <things> yet", as every empty
    /// list of the app says it.
    private func empty(_ kind: ResourceKind) -> String {
        switch kind.kind {
        case "tool": "No MCP servers yet"
        case "repo": "No repositories yet"
        case "gmail", "drive": "No accounts yet"
        case "secret": "No secrets yet"
        default: "None yet"
        }
    }

    /// One resource: its mark, its name, who holds it now, and its standing in a few words. A click opens its detail.
    private func row(_ resource: FleetResource, kind: ResourceKind, reading: ResourceList) -> some View {
        let standing = StandingRows.words(resource.standing, reading: reading, kind: resource.kind)
        let unreached = reading.unreachedPage(resource) != nil
        return Button { note = nil; shown = ShownResource(id: resource.id) } label: {
            HStack(spacing: 12) {
                IconTile(symbol: Self.symbol(resource.kind))
                VStack(alignment: .leading, spacing: 3) {
                    Text(resource.title).font(Self.isCode(resource.kind) ? FormMetrics.title.monospaced()
                                              : FormMetrics.title)
                        .foregroundStyle(FleetStyle.text).lineLimit(1).truncationMode(.middle)
                    Text(who(resource)).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).lineLimit(1)
                }
                Spacer(minLength: 12)
                // Who may give it, only where the fleet manager may: "You give it" on every other row said the
                // same thing every day, and this column is how the owner sees what the manager can hand out.
                if case .grantable(let max, _) = resource.standing {
                    ManagerGives(level: AccessSettings.levelName(max, kind: resource.kind), color: standing.color)
                }
                // **A repository that the hub's GitHub App does not reach** (the owner's yes of 2 November 2026: the
                // mark on the row, its words on hover, and Add on GitHub on the group's heading, `AppsSettings`).
                if unreached {
                    Image(systemName: "exclamationmark.triangle.fill").font(IconMetrics.symbol(13)).foregroundStyle(.orange)
                        .help(Self.unreachedWords).accessibilityHidden(true)
                }
                // An agent's row keeps the room of its −, which stands over the row (`take`).
                if agent == nil {
                    Image(systemName: "info.circle").font(IconMetrics.symbol(14)).foregroundStyle(FleetStyle.muted).accessibilityHidden(true)
                } else {
                    Color.clear.frame(width: IconMetrics.side, height: IconMetrics.side)
                }
            }.padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 10)
        }
        .buttonStyle(FleetRowButtonStyle())
        .help("Show \(resource.title) and who may give it")
        .accessibilityLabel("\(resource.title), \(kind.word), \(standing.short)" + (unreached ? ", \(Self.unreachedWords)" : ""))
        .accessibilityHint("Shows its detail")
        .accessibilityIdentifier("resource-\(resource.id)")
        .overlay(alignment: .trailing) {
            if let agent { take(resource, from: agent).padding(.trailing, FormMetrics.rowInset) }
        }
    }

    /// **The − of a row on an agent's Can use** (the owner's yes of 3 November 2026): it takes the item back from this
    /// agent alone, with the write its card's No access makes. It stands over the row, never inside its button, so its
    /// click is its own; while its write goes on, a spinner stands in its place.
    @ViewBuilder private func take(_ resource: FleetResource, from agent: String) -> some View {
        if working == "\(resource.id) \(agent)" {
            ProgressView().controlSize(.small).frame(width: IconMetrics.side, height: IconMetrics.side)
        } else {
            IconButton(symbol: "minus", words: "Take \(resource.title) back from \(agent.agentLabel)") {
                Task {
                    guard let reading, let database = store.state?.db else { return }
                    working = "\(resource.id) \(agent)"
                    defer { working = nil }
                    let said = await Self.write(resource, to: agent, level: nil, sha256: reading.sha256, store: store,
                                                database: database)
                    store.keep(said, as: Self.saidName(agent, kind: resource.kind))
                    await read()
                }
            }
            .disabled(!canChange || !store.isFresh)
            .accessibilityIdentifier("access-take-\(resource.id)")
        }
    }

    /// Who has this item, in the same words on the fleet's own list and on an agent's: the agents that hold it, or
    /// all of them. The level each one has is in the item's detail.
    private func who(_ resource: FleetResource) -> String {
        let all = (store.state?.agents.map(\.name) ?? []).sorted()
        let holders = resource.holders.map(\.agent).sorted()
        if holders.isEmpty { return "No agent" }
        if !all.isEmpty && Set(all) == Set(holders) { return "All agents" }
        return agentWords(holders)
    }

    // MARK: detail

    /// The detail of one resource: what it is, where its credential is, who may give it, and the agents that hold it.
    private func detail(_ id: String) -> some View {
        let resource = reading?.resource(id)
        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                IconTile(symbol: Self.symbol(resource?.kind ?? "secret"))
                VStack(alignment: .leading, spacing: 3) {
                    Text(resource?.title ?? id)
                        .font(Self.isCode(resource?.kind ?? "") ? FormMetrics.title.monospaced()
                              : FormMetrics.title)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled).accessibilityAddTraits(.isHeader)
                    Text(reading?.kind(of: resource ?? .placeholder)?.word ?? "").font(FormMetrics.detail)
                        .foregroundStyle(FleetStyle.muted)
                }
                Spacer(minLength: 12)
                Button("Done") { shown = nil }.buttonStyle(FleetOutlineButtonStyle()).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("resource-done")
            }
            if let resource, let reading, let kind = reading.kind(of: resource) {
                agentsSection(resource, kind: kind, reading: reading)
                standingSection(resource, kind: kind, reading: reading)
                // No "Who holds it now" (D-5): each agent's level is the list above, where No access takes it back.
                if !resource.history.isEmpty {
                    FormSection("Who gave it") {
                        ForEach(resource.history) { record in
                            FormRow(record.words, symbol: record.level == nil ? "slash.circle" : "arrow.right.circle",
                                    detail: fleetDate(record.ts)) { EmptyView() }
                        }
                    }
                }
            } else {
                Text("This resource is no longer in the list.").font(FormMetrics.text).foregroundStyle(FleetStyle.muted)
            }
        }
        .padding(22).frame(width: 560)
        .font(FleetStyle.body).foregroundStyle(FleetStyle.text)
    }

    /// **Which agents may use this item**, which is what the owner came here to set: every agent of the fleet with
    /// the level it has, or None. One control, because this is one relation — an agent's own list writes the same
    /// thing from its end.
    ///
    /// **A Drive or mail account is written here like every other kind** (20 October 2026, the owner's own call).
    /// It used to be read-only, under a footer saying the grant happened on the agent's own Apps section. That
    /// conflated two different things: **connecting** an account is the owner's consent, once, for the account,
    /// and happens in a browser; **giving an agent a level** on an account that is already connected is a plain
    /// write of the team file, which `give` has always made correctly. So every kind is now granted from both
    /// ends, which is what the fleet's own model says it is: one item, many agents.
    @ViewBuilder private func agentsSection(_ resource: FleetResource, kind: ResourceKind, reading: ResourceList) -> some View {
        let agents = store.state?.agents.map(\.name) ?? []
        FormSection("Which agents may use it", footer: Self.levelsFooter(kind)) {
            if let level = kind.levels.last {
                // The row names the level it gives. "All agents" is one click and the highest level of the kind,
                // which for a mail account is Send — what it hands out belongs where it is handed out, not in a
                // footer under it.
                FormRow("All agents", symbol: "person.3",
                        detail: resource.kind == "secret" ? "Every agent: \(Self.levelName(level, kind: resource.kind))."
                            : "Gives every agent \(Self.levelName(level, kind: resource.kind)).") {
                    if working == "\(resource.id) all" { ProgressView().controlSize(.small) }
                    else {
                        Toggle("All agents", isOn: Binding(
                            get: { !agents.isEmpty && Set(resource.holders.map(\.agent)) == Set(agents) },
                            set: { on in Task { await giveAll(resource, agents: agents, level: on ? level : nil) } }))
                            .toggleStyle(.switch).controlSize(.small).labelsHidden()
                            .disabled(!canChange).accessibilityIdentifier("access-all-agents")
                    }
                }
            }
            if agents.isEmpty { FormEmpty("This fleet has no agent yet.", symbol: "person.slash") }
            ForEach(agents, id: \.self) { agent in
                let level = resource.holders.first { $0.agent == agent }?.level
                let busy = working == "\(resource.id) \(agent)"
                // **The agent's glyph, with its dot, before its name** (the owner, 30 October 2026: "Marks on every agent
                // row"; margins row 15), as a secret's card has it: one agent row in every card, its name at the edge
                // of "All agents".
                FormRow(agent.agentLabel, mark: AgentGlyph(name: agent, size: GlyphSize.inline),
                        detail: level.map { resource.kind == "secret" ? "Has it: \(Self.levelName($0, kind: resource.kind))"
                            : "Has it at \(Self.levelName($0, kind: resource.kind))" }) {
                    if busy { ProgressView().controlSize(.small) } else {
                        FleetSelect("What \(agent.agentLabel) may do with \(resource.title)",
                                    options: [FleetOption("", "No access")]
                                        + kind.levels.map { FleetOption($0, Self.levelName($0, kind: resource.kind)) },
                                    selection: level ?? "") { chosen in
                            Task { await give(resource, to: agent, level: chosen.isEmpty ? nil : chosen) }
                        } label: { FleetSelectLabel(title: level.map { Self.levelName($0, kind: resource.kind) } ?? "No access") }
                            .disabled(!canChange).accessibilityIdentifier("access-agent-\(agent)")
                    }
                }
            }
        }
    }

    /// **One name for each level, wherever it stands** (fix round 2): a secret's level was "Reads it" on its row, "read"
    /// in At most and "Manager: up to read". A secret's are the words of its own control ("Uses it", "Reads it"), every
    /// other kind's the hub's own name for it as he reads it ("Read", "Write").
    static func levelName(_ level: String, kind: String) -> String {
        if kind == "secret" {
            switch level {
            case SecretGrant.use.rawValue: return "Uses it"
            case SecretGrant.read.rawValue: return "Reads it"
            default: break
            }
        }
        return levelWords(level)
    }

    /// One level as the owner reads it: the hub's own name for it, without the underscore a raw value carries.
    static func levelWords(_ level: String) -> String {
        let words = level.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// The one thing worth saying under the agents of this kind: that its top level acts as the owner towards
    /// other people. Every other kind says nothing, because a level that reaches nobody needs no warning.
    private static func levelsFooter(_ kind: ResourceKind) -> String? {
        let reaching = kind.levels.compactMap(GoogleLevel.init(rawValue:)).filter(\.reachesOthers)
        guard !reaching.isEmpty else { return nil }
        return "\(reaching.map(\.title).joined(separator: " and ")): \(Google.reachesOthers)"
    }

    /// Gives every agent this item at one level, or takes it from all of them: the one control for "everyone".
    /// There is no wildcard in the fleet, so this is every agent that exists now — and the row says so by reading
    /// "All agents" only while that is true.
    private func giveAll(_ resource: FleetResource, agents: [String], level: String?) async {
        working = "\(resource.id) all"
        defer { working = nil }
        for agent in agents where (resource.holders.first { $0.agent == agent }?.level != nil) != (level != nil) {
            await give(resource, to: agent, level: level)
        }
        await read()
    }

    /// Gives one agent one item, or takes it back (`level: nil`). Each kind has its own write, and each is the one
    /// the agent's own list uses: a repository and an MCP server are written for the whole item at once, which is
    /// how the hub takes them, and a secret's grant is written for that one agent.
    private func give(_ resource: FleetResource, to agent: String, level: String?) async {
        guard let reading, let database = store.state?.db else { return }
        working = "\(resource.id) \(agent)"
        note = nil
        defer { working = nil }
        if let refused = await Self.write(resource, to: agent, level: level, sha256: reading.sha256, store: store, database: database) {
            note = (resource.id, refused, true)
            return
        }
        note = (resource.id, level == nil ? "\(agent.agentLabel) no longer has \(resource.title)."
                : "\(agent.agentLabel) has \(resource.title) at \(level ?? "").", false)
        await read()
    }

    /// **The one write of one agent's hold on one item**, for the card's control, the − of an agent's row and the + of
    /// an agent's heading (`AccessGive`): nil when the hub took it, else the words to show. Each kind has its own route;
    /// a repository, an MCP server and an account are written whole, against the version `sha256` of the reading.
    static func write(_ resource: FleetResource, to agent: String, level: String?, sha256: String, store: FleetStore,
                      database: String) async -> String? {
        let client = store.installation, hub = store.hub
        do {
            switch resource.kind {
            case "repo":
                let access = resource.repositoryAccess(giving: agent, level: level)
                    .compactMapValues(RepositoryAccess.init(rawValue:))
                _ = try await IntegrationsClient().saveRepository(hub: hub, database: database, client: client,
                                                                  sha256: sha256, repo: resource.what, access: access)
            case "tool":
                _ = try await IntegrationsClient().saveTool(hub: hub, database: database, client: client,
                                                            sha256: sha256, tool: resource.what,
                                                            agents: resource.toolAgents(giving: agent, level: level))
            case "secret":
                // Signed for the central vault before the hub's grant, and its end after it (`GrantSigning`).
                let grant = level.flatMap(SecretGrant.init(rawValue:))
                if grant != nil {
                    try await GrantSigning.grant(grant, login: resource.what, agent: agent, store: store, hub: hub, database: database)
                }
                _ = try await SecretsClient().grant(hub: hub, database: database, client: client,
                                                    login: resource.what, agent: agent, grant: grant)
                if grant == nil {
                    try await GrantSigning.grant(nil, login: resource.what, agent: agent, store: store, hub: hub, database: database)
                }
            case "drive", "gmail":
                // The account is the unit: it belongs to the fleet, and this writes which agents may use it.
                try await GoogleClient().saveAccess(hub: hub, database: database, client: client,
                                                    sha256: sha256, account: resource.what,
                                                    service: resource.kind == "drive" ? .drive : .gmail,
                                                    access: resource.googleAccess(giving: agent, level: level))
            default:
                return "Founderizer cannot give this kind yet."
            }
            return nil
        } catch let HubError.refusal(_, words) {
            return words
        } catch let stop as GrantSigning.Stop {
            return stop.errorDescription ?? "The hub did not take this change. Try again."
        } catch {
            return "The hub did not take this change. Try again."
        }
    }

    /// Who may give this item: the owner alone, or the fleet manager too, up to a level (`StandingRows`).
    @ViewBuilder private func standingSection(_ resource: FleetResource, kind: ResourceKind, reading: ResourceList) -> some View {
        // One "Who may give it" on the card (D-2): the row's, and no heading of the same words over it.
        FormSection(footer: StandingRows.words(resource.standing, reading: reading, kind: resource.kind).footer) {
            StandingRows(title: resource.title, kind: resource.kind, standing: resource.standing, levels: kind.levels, reading: reading,
                         busy: working == resource.id, canChange: canChange) { next in
                Task { await save(next, for: resource) }
            }
            if let note, note.resource == resource.id {
                FormRow(note.text, symbol: note.warning ? "exclamationmark.triangle" : "checkmark.circle") { EmptyView() }
            }
        }
    }

    // MARK: the words

    /// The mark of one kind, shared with the modal that gives an agent more of it.
    static func symbol(_ kind: String) -> String {
        switch kind {
        case "repo": "shippingbox"
        case "drive": "folder"
        case "gmail": "envelope"
        case "tool": "puzzlepiece.extension"
        default: "key.horizontal"
        }
    }

    /// A kind whose name Fleet shows in a monospaced font: a reference, a repository or a server name.
    private static func isCode(_ kind: String) -> Bool { ["repo", "tool"].contains(kind) }

    /// One secret that a resource uses, by its name on the Secrets page when the reading has it.
    private static func secretName(reading: ResourceList) -> (String) -> String {
        { reference in reading.resource("secret:\(reference)")?.title ?? reference }
    }

    // MARK: changes

    private static func text(_ error: Error) -> String { (error as? LocalizedError)?.errorDescription ?? "The hub did not answer." }

    /// One standing at the hub, against the team.json version of the last reading, then a new reading. The hub refuses
    /// a standing that it would refuse in team.json, with its reason, and an old version (409), after which the new
    /// reading shows what is there now.
    private func save(_ standing: ResourceStanding, for resource: FleetResource) async {
        guard canChange, let database = store.state?.db, let sha256 = reading?.sha256 else { return }
        let hub = store.hub, client = store.installation
        working = resource.id; note = nil
        defer { working = nil }
        do {
            // A secret's place in the pool is signed for the central vault before the manager may give it, and its end
            // after (`GrantSigning`).
            let secret = resource.kind == "secret"
            if secret && standing != .ownerOnly {
                try await GrantSigning.pool(true, login: resource.what, store: store, hub: hub, database: database)
            }
            let receipt = try await ResourcesClient().saveStanding(hub: hub, database: database, client: client,
                                                                   sha256: sha256, resource: resource.id, standing: standing)
            if secret && standing == .ownerOnly {
                try await GrantSigning.pool(false, login: resource.what, store: store, hub: hub, database: database)
            }
            await read()
            if receipt.changed, case .grantable(let max, let to) = standing, let reading {
                note = (resource.id, "The fleet manager may give \(resource.title) to \(reading.audienceWords(to)), "
                        + "at most \(max).", false)
            }
        } catch {
            await read()
            note = (resource.id, "Founderizer could not change this. \(Self.text(error))", true)
        }
    }

    // MARK: reading

    /// Reads the resources every 15 seconds while the page shows, and again after 3 seconds when a read failed.
    private func poll() async {
        failed = false; note = nil
        // `-openResource <id>` opens one item's detail, so that card can be looked at without clicking to it.
        shown = UserDefaults.standard.string(forKey: "openResource").map(ShownResource.init)
        let start = ContinuousClock.now
        while !Task.isCancelled {
            let current = await read(since: start)
            do { try await store.nap(current || !offered ? 15 : 3) } catch { return }
        }
    }

    /// One reading. A failed read keeps the last one, which then shows as the last reading.
    @discardableResult private func read(since start: ContinuousClock.Instant? = nil) async -> Bool {
        await Self.readOnce(store, agent: agent, since: start)
    }

    /// One reading of the fleet's resources, or of one agent's, into the store, where every list and page that draws
    /// it finds it. A failed read keeps the last one, which then shows as the last reading. **The lists of one page read
    /// their one reading once** (`FleetStore.read`): an agent's Apps draws it in four lists, and each read it for itself.
    /// Settings › Apps reads it here for its counts (`AppsPage`).
    @discardableResult static func readOnce(_ store: FleetStore, agent: String?, since start: ContinuousClock.Instant? = nil) async -> Bool {
        guard store.state?.ui_features?.contains(ResourceList.feature) == true, store.isFresh,
              let database = store.state?.db else { return false }
        let hub = store.hub, first = (store.reading(name(agent)) as ResourceList?) == nil
        guard let list = try? await readResources(store, agent: agent, hub: hub, database: database) else {
            if first, let start { await store.settle(since: start) }
            if !Task.isCancelled, store.hub == hub, store.state?.db == database { store.keep(true, as: name(agent) + ".failed") }
            return false
        }
        guard !Task.isCancelled else { return false }
        if first, let start { await store.settle(since: start) }
        guard store.hub == hub, store.state?.db == database else { return false }
        store.keep(list, as: name(agent))
        store.keep(false, as: name(agent) + ".failed")
        return true
    }
}

/// **The + on a heading of an agent's Can use** (the owner's yes of 3 November 2026): what the fleet already holds of
/// one kind and this agent does not, in the app's list; one choice gives it to this agent at the kind's lowest level
/// (Read for a repository or an account), with the write its card makes (`AccessSettings.write`). It is drawn only
/// while there is one to give and the hub answers, and waits while its write goes on. A refusal is said under the
/// kind's card (`AccessSettings.saidName`).
struct AccessGive: View {
    @Bindable var store: FleetStore
    let agent: String
    /// `repo`, `drive`, `gmail` or `tool`.
    let kind: String
    @State private var giving = false

    var body: some View {
        let reading: ResourceList? = store.reading(AccessSettings.name(agent))
        let open = (reading?.resources ?? []).filter { $0.kind == kind && !$0.holders.contains { $0.agent == agent } }
        if giving {
            ProgressView().controlSize(.small).frame(width: IconMetrics.side, height: IconMetrics.side)
        } else if let reading, store.state?.ui_features?.contains(ResourceList.feature) == true, store.isFresh, !open.isEmpty {
            FleetSelect(words, options: open.map { FleetOption($0.id, $0.title, mark: .symbol(AccessSettings.symbol(kind))) }) { id in
                guard let resource = open.first(where: { $0.id == id }) else { return }
                Task { await give(resource, reading: reading) }
            } label: {
                Image(systemName: "plus").font(IconMetrics.symbol(13)).foregroundStyle(FleetStyle.muted)
            }
            .buttonStyle(FleetIconButtonStyle(rest: true))
            .help(words)
            // In the column of the rows' −, which stand the rows' inset in from the card's edge.
            .padding(.trailing, FormMetrics.rowInset)
            .accessibilityIdentifier("access-give-\(kind)")
        }
    }

    /// What the + gives, in the owner's words: "Give Web-Lead a repository".
    private var words: String {
        let what = switch kind {
        case "repo": "a repository"
        case "drive": "a Drive account"
        case "gmail": "a Gmail account"
        case "tool": "an MCP server"
        default: "one more"
        }
        return "Give \(agent.agentLabel) \(what)"
    }

    private func give(_ resource: FleetResource, reading: ResourceList) async {
        guard let database = store.state?.db,
              let level = resource.levels.first ?? reading.kind(of: resource)?.levels.first else { return }
        giving = true
        defer { giving = false }
        let said = await AccessSettings.write(resource, to: agent, level: level, sha256: reading.sha256, store: store, database: database)
        store.keep(said, as: AccessSettings.saidName(agent, kind: kind))
        let hub = store.hub
        if let fresh = try? await AccessSettings.readResources(store, agent: agent, hub: hub, database: database),
           store.hub == hub, store.state?.db == database {
            store.keep(fresh, as: AccessSettings.name(agent))
        }
    }
}

extension FleetResource {
    /// A stand-in for a detail whose resource left the list between the click and the reading.
    static let placeholder = FleetResource(id: "secret:", kind: "secret", what: "", title: "", needs: "", levels: [],
                                           uses: [], credential: "none", connected: true, grant: nil, holders: [])
}

/// **"Manager may give: Reads it", whose level is never cut** (fix round 3, item 6): at 960 the rows of Apps, Secrets
/// and Can use cut it to "Manager may give:…". The words before the level give way first.
struct ManagerGives: View {
    let level: String
    var color: Color = FleetStyle.text

    var body: some View {
        HStack(spacing: 3) {
            Text("Manager may give:").lineLimit(1).truncationMode(.tail)
            Text(level).lineLimit(1).fixedSize().layoutPriority(1)
        }
        .font(FormMetrics.detail).foregroundStyle(color)
    }
}

/// **Who may give one item**: the owner alone, or the fleet manager too, up to a level — the select and, while the
/// manager may, the highest level it may give. A repository's, an MCP server's and an account's detail draw these two
/// rows, and so does a secret's detail on the Secrets page (the owner, 24 October 2026: "Yes, add the 'Who may give
/// it' row to a secret's detail on the Secrets page, like repositories and MCP servers have"), so one choice has one
/// control wherever its item is opened. The caller keeps the save, its spinner and its line.
struct StandingRows: View {
    /// The item's name, for the words of the selects.
    let title: String
    /// The item's kind, for the one name of each of its levels (`AccessSettings.levelName`).
    let kind: String
    let standing: ResourceStanding
    /// The kind's levels, from the lowest to the highest. Every one of them can be the highest the manager gives.
    let levels: [String]
    let reading: ResourceList
    let busy: Bool
    let canChange: Bool
    let save: (ResourceStanding) -> Void

    var body: some View {
        FormRow("Who may give it", symbol: "person.badge.key") {
            if busy { ProgressView().controlSize(.small) } else {
                FleetSelect("Who may give \(title)", options: Self.choices(levels: levels),
                            selection: Self.choice(standing)) { choice in
                    save(Self.standing(choice, levels: levels, from: standing))
                } label: {
                    FleetSelectLabel(title: Self.words(standing, reading: reading, kind: kind).title,
                                     mark: .symbol(Self.words(standing, reading: reading, kind: kind).symbol))
                }.disabled(!canChange).accessibilityIdentifier("resource-standing")
            }
        }
        if case .grantable(let max, let to) = standing {
            FormRow("At most", symbol: "arrow.up.to.line",
                    detail: "The manager may give this level and the ones under it.") {
                if levels.count < 2 {
                    // **One level is a value, not a choice** (fix round 3c): an MCP server's "Use" stood as a grey select.
                    Text(AccessSettings.levelName(max, kind: kind)).foregroundStyle(FleetStyle.muted)
                        .accessibilityIdentifier("resource-max")
                } else {
                    FleetSelect("The highest level of \(title)",
                                options: levels.map { FleetOption($0, AccessSettings.levelName($0, kind: kind)) },
                                selection: max) { level in
                        save(.grantable(max: level, to: to))
                    } label: { FleetSelectLabel(title: AccessSettings.levelName(max, kind: kind)) }
                        .disabled(!canChange)
                        .accessibilityIdentifier("resource-max")
                }
            }
        }
    }

    /// One standing in the owner's words: the dropdown's title, a short word for the list row, its mark and the
    /// footer that says what it means.
    static func words(_ standing: ResourceStanding, reading: ResourceList, kind: String) -> (title: String, short: String,
                                                                               symbol: String, color: Color,
                                                                               footer: String?) {
        switch standing {
        case .ownerOnly:
            return ("You alone", "You give it", "person.fill", FleetStyle.muted,
                    "Only you give it. The fleet manager must ask you for it with a Needs-you item.")
        case .grantable(let max, _):
            // No footer of 35 words on what the manager may do (D-2): the two rows above it say it.
            // The row's words (fix round 2): what the manager may give, by the level's one name.
            return ("You and the fleet manager", "Manager may give: \(AccessSettings.levelName(max, kind: kind))",
                    "person.2.fill", FleetStyle.text, nil)
        }
    }

    /// The rows of the first dropdown: you, or you and the manager.
    fileprivate static func choices(levels: [String]) -> [FleetOption<StandingChoice>] {
        var rows = [FleetOption(StandingChoice.owner, "You alone", subtitle: "The manager asks you for it.",
                                mark: .symbol("person.fill"))]
        if !levels.isEmpty {
            rows.append(FleetOption(StandingChoice.manager, "You and the fleet manager",
                                    subtitle: "The manager may hand it out, up to a level you set.",
                                    mark: .symbol("person.2.fill")))
        }
        return rows
    }

    fileprivate static func choice(_ standing: ResourceStanding) -> StandingChoice {
        switch standing {
        case .ownerOnly: .owner
        case .grantable: .manager
        }
    }

    /// The standing that a chosen row makes. The manager keeps the level and the audience that the resource had, so a
    /// change back and forth does not lose them; a resource that had none starts at the lowest level.
    fileprivate static func standing(_ choice: StandingChoice, levels: [String],
                                     from current: ResourceStanding) -> ResourceStanding {
        switch choice {
        case .owner: .ownerOnly
        case .manager: .grantable(max: current.max.flatMap { levels.contains($0) ? $0 : nil } ?? levels.first ?? "",
                                  to: current.audience ?? ResourceList.everyone)
        }
    }
}
