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
    /// **A mark and a control of the page's own at the end of a row** (Settings › Apps › MCP servers: the warning mark
    /// and Sign in again of a server whose access ended, `MCPSignInAgain`), or nil for a row that has none. It stands
    /// over the row as the − does, so its click is its own, in the room that the row keeps for it. nil draws every row
    /// as before.
    var accessory: ((FleetResource) -> AnyView?)? = nil
    /// The store's (`FleetStore.reading`), the fleet's pages' and each agent's under its own name (`name`): the list he
    /// saw last shows in the first frame when he comes back, and the read that starts then changes only what changed.
    private var reading: ResourceList? {
        get { store.reading(Self.name(agent)) } nonmutating set { store.keep(newValue, as: Self.name(agent)) }
    }
    /// When the first of the reads that failed in a row failed, or nil while the last read answered: `reading` is then
    /// the last good one, or nil. One break of them says nothing (`FleetStore.pageReadingIsOld`). It is the reading's,
    /// kept beside it, so the lists that draw one reading (an agent's Apps has three) agree on it whichever of them read
    /// last.
    private var failedSince: ContinuousClock.Instant? {
        get { store.reading(Self.name(agent) + ".failedSince") }
        nonmutating set { store.keep(newValue, as: Self.name(agent) + ".failedSince") }
    }
    @State private var shown: ShownResource?
    /// The resource whose standing the hub works on now, or "<resource> <agent>" while a hold ends.
    @State private var working: String?
    /// The result or the problem of the last change, in its resource's detail.
    @State private var note: (resource: String, text: String, warning: Bool)?
    /// The rows of an agent's repositories that he opened, each "<agent> <owner>/<level>" (`repositoryRows`): closed again
    /// when the page opens again.
    @State private var opened: Set<String> = []
    /// The Google account whose Disconnect asks its one line now (`disconnectRow`), by its resource id.
    @State private var disconnecting: String?
    /// **Add folder** (owner API 1.255; the owner's "Yes, as drawn" of 20 November 2026 to its three pictures): the
    /// account card whose field shows now, by its resource id, and the link in the field.
    @State private var addingFolder: String?
    @State private var folderLink = ""
    /// The folder that Add folder found, which no agent holds yet, by its key (`FleetResource.folderKey`): its card
    /// stands on it until an agent gets it. Nothing of it is kept when the owner closes the card first.
    @State private var addedFolder: (key: String, folder: DriveFolder)?

    private var offered: Bool { store.state?.ui_features?.contains(ResourceList.feature) == true }
    /// A hub that takes a folder of a Drive account (owner API 1.255).
    private var foldersOffered: Bool { store.state?.ui_features?.contains("drive_folders") == true }
    private var canChange: Bool { offered && store.writesNow && working == nil }

    /// The name of the fleet's resources, or of one agent's: the MCPs and Apps lists and the Secrets page draw it.
    nonisolated static func name(_ agent: String?) -> String { "resources.\(agent ?? "fleet")" }
    /// The words behind the orange mark of a repository that the hub's GitHub App does not reach.
    static let unreachedWords = String(l10n: "The GitHub App cannot reach this repository")
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
    /// every group under it moved down 37 pt and back. **One break of the hub says nothing** (17 November 2026): it
    /// stood from the first read that a restart of the hub refused. Not while the window's notice says the outage (fix
    /// round 3, item 33: an outage is said once).
    @ViewBuilder static func lastReading(_ store: FleetStore, agent: String?, since opened: ContinuousClock.Instant) -> some View {
        let failedSince: ContinuousClock.Instant? = store.reading(name(agent) + ".failedSince")
        if (store.reading(name(agent)) as ResourceList?) != nil && store.pageReadingIsOld(failedSince: failedSince)
            && !store.hubNoticeShows {
            Held(since: opened) {
                Label("Last reading", systemImage: "clock.arrow.circlepath")
                    .font(FormMetrics.detail).foregroundStyle(.orange).lineLimit(1)
                    .help("Founderizer reads the resources again when the hub answers.")
            }
        }
    }

    /// **A new visit of a page that draws the resources counts its own break** (`failedSince`): reads that failed in an
    /// earlier visit, which nothing read again since, say nothing to it at its first failed read.
    static func visited(_ store: FleetStore, agent: String?) {
        if (store.reading(name(agent) + ".failedSince") as ContinuousClock.Instant?) != nil {
            store.keep(nil, as: name(agent) + ".failedSince")
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
        else if store.pageReadingIsOld(failedSince: failedSince) {
            // **Not while the window's notice says the outage** (`FleetStore.hubNoticeShows`; fix round 3, item 33: an
            // outage is said once): the line stands only where no notice over the page says why. **One break of the hub
            // says nothing** (17 November 2026): "Reading the resources…" stays until the reads have failed one whole
            // break, or the fleet's state is old.
            if !store.hubNoticeShows {
                FormSection { FormRow("Founderizer cannot read the resources now.", detail: String(l10n: "It reads again when the hub answers.")) }
            }
        } else { LoadingLine(String(l10n: "Reading the resources…")) }
    }

    // MARK: list

    /// The list draws nothing: a list with no reading says nothing while the window's notice says why it cannot read
    /// (`items`). An agent's list of one kind always draws its card, empty or not (`agentList`).
    private var drawsNothing: Bool {
        guard offered else { return false }
        guard let reading else { return store.pageReadingIsOld(failedSince: failedSince) && store.hubNoticeShows }
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
                    ForEach(items) { resource in
                        // An agent that holds only folders of a Drive account has the folders' rows, not the account's.
                        if agent.map({ name in resource.holders.contains { $0.agent == name } }) ?? true {
                            row(resource, kind: group.kind, reading: reading)
                        }
                        ForEach(folders(of: resource)) { folderRow($0, of: resource) }
                    }
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
        let held = reading.resources.filter { $0.kind == kind && $0.reaches(agent) }
        let info = reading.kinds.first { $0.kind == kind }
        VStack(alignment: .leading, spacing: FleetSpace.inside) {
            FormSection(lazy: true) {
                if held.isEmpty { FormEmpty(Self.emptyForAgent(kind), symbol: Self.symbol(kind)) }
                if let info {
                    if kind == "repo" { repositoryRows(held, agent: agent, kind: info, reading: reading) }
                    else {
                        ForEach(held) { resource in
                            if resource.holders.contains(where: { $0.agent == agent }) { row(resource, kind: info, reading: reading) }
                            ForEach(folders(of: resource)) { folderRow($0, of: resource) }
                        }
                    }
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
        .accessibilityLabel(unreached ? String(l10n: "\(account), \(group.repos.count) repositories, \(level), \(Self.unreachedWords)")
                            : String(l10n: "\(account), \(group.repos.count) repositories, \(level)"))
        .accessibilityValue(open ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("access-repo-group-\(group.id)")
        // The account as GitHub writes it, from the list that the + reads; until then, as team.json keeps it.
        .task(id: "\(store.hub)/\(store.state?.db ?? "")") { await RepositoryPicking.keepNames(store) }
    }

    /// The empty card of one kind on an agent's Can use, under its heading, which already names the kind.
    private static func emptyForAgent(_ kind: String) -> String {
        switch kind {
        case "tool": String(l10n: "No MCP servers")
        case "repo": String(l10n: "No repositories")
        case "gmail", "drive": String(l10n: "No accounts")
        case "secret": String(l10n: "No secrets")
        default: String(l10n: "None")
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
        return resources.filter { $0.reaches(agent) }
    }

    /// The folders of a Drive account that this list shows under the account's row: every one that an agent holds on
    /// the fleet's page, and this agent's own on its page.
    private func folders(of resource: FleetResource) -> [DriveFolder] {
        guard let agent else { return resource.folders ?? [] }
        return (resource.folders ?? []).filter { $0.holders.contains { $0.agent == agent } }
    }

    /// One line for an empty list, the same on the fleet's page and on an agent's: "No <things> yet", as every empty
    /// list of the app says it.
    private func empty(_ kind: ResourceKind) -> String {
        switch kind.kind {
        case "tool": String(l10n: "No MCP servers yet")
        case "repo": String(l10n: "No repositories yet")
        case "gmail", "drive": String(l10n: "No accounts yet")
        case "secret": String(l10n: "No secrets yet")
        default: String(l10n: "None yet")
        }
    }

    /// One resource: its mark, its name, who holds it now, and its standing in a few words. A click opens its detail.
    private func row(_ resource: FleetResource, kind: ResourceKind, reading: ResourceList) -> some View {
        let standing = StandingRows.words(resource.standing, reading: reading, kind: resource.kind)
        let unreached = reading.unreachedPage(resource) != nil
        let extra = accessory?(resource)
        return Button { note = nil; disconnecting = nil; forgetDisconnect(resource); shown = ShownResource(id: resource.id) } label: {
            HStack(spacing: 12) {
                IconTile(symbol: Self.symbol(resource.kind))
                VStack(alignment: .leading, spacing: 3) {
                    Text(resource.title).font(Self.isCode(resource.kind) ? FormMetrics.title.monospaced()
                                              : FormMetrics.title)
                        .foregroundStyle(FleetStyle.text).lineLimit(1).truncationMode(.middle)
                    if let who = who(resource) {
                        Text(who).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).lineLimit(1)
                    }
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
                // The room of the page's accessory, which stands over the row (`accessory`).
                if let extra { extra.hidden().accessibilityHidden(true) }
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
        .overlay(alignment: .trailing) {
            // In its room: the row's last mark stands after it, as in the row.
            if let extra {
                HStack(spacing: 12) {
                    extra
                    accessoryRoom
                }.padding(.trailing, FormMetrics.rowInset)
            }
        }
    }

    /// What stands after the page's accessory in a row, unseen: the room of the fleet's ⓘ, or of an agent's −, so the
    /// accessory over the row stands where the row keeps its room.
    @ViewBuilder private var accessoryRoom: some View {
        if agent == nil {
            Image(systemName: "info.circle").font(IconMetrics.symbol(14)).hidden().accessibilityHidden(true)
        } else {
            Color.clear.frame(width: IconMetrics.side, height: IconMetrics.side)
        }
    }

    /// **The − of a row on an agent's Can use** (the owner's yes of 3 November 2026): it takes the item back from this
    /// agent alone, with the write its card's No access makes. It stands over the row, never inside its button, so its
    /// click is its own; while its write goes on, a spinner stands in its place.
    @ViewBuilder private func take(_ resource: FleetResource, from agent: String) -> some View {
        if working == "\(resource.id) \(agent)" {
            ProgressView().controlSize(.small).frame(width: IconMetrics.side, height: IconMetrics.side)
        } else {
            IconButton(symbol: "minus", words: String(l10n: "Take \(resource.title) back from \(agent.agentLabel)")) {
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
            .disabled(!canChange || !store.writesNow)
            .accessibilityIdentifier("access-take-\(resource.id)")
        }
    }

    /// **A folder of a Drive account, in a row under the account's own, set in from it** (the owner's "Yes, as drawn"
    /// of 20 November 2026), so the relation shows with no word: its name as Google gives it, and who holds it. A click
    /// opens its card. The row stands while an agent holds the folder: the hub lists no other. A folder that the
    /// account can no longer open keeps its row, with the warning mark and its link.
    private func folderRow(_ folder: DriveFolder, of resource: FleetResource) -> some View {
        let key = resource.folderKey(folder.id)
        let unseen = String(l10n: "\(resource.what) cannot open this folder now")
        return Button { note = nil; addingFolder = nil; shown = ShownResource(id: key) } label: {
            HStack(spacing: 12) {
                IconTile(symbol: Self.symbol("drive"))
                VStack(alignment: .leading, spacing: 3) {
                    Text(folder.gone ? folder.link : folder.title).font(FormMetrics.title).foregroundStyle(FleetStyle.text)
                        .lineLimit(1).truncationMode(.middle)
                    if let who = who(holders: folder.holders) {
                        Text(who).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                if folder.gone {
                    Image(systemName: "exclamationmark.triangle.fill").font(IconMetrics.symbol(13)).foregroundStyle(.orange)
                        .help(unseen).accessibilityHidden(true)
                }
                if agent == nil {
                    Image(systemName: "info.circle").font(IconMetrics.symbol(14)).foregroundStyle(FleetStyle.muted).accessibilityHidden(true)
                } else {
                    Color.clear.frame(width: IconMetrics.side, height: IconMetrics.side)
                }
            }.padding(.leading, FormMetrics.rowInset + Self.folderInset).padding(.trailing, FormMetrics.rowInset)
                .padding(.vertical, 10)
        }
        .buttonStyle(FleetRowButtonStyle())
        .help("Show \(folder.title) and who may use it")
        .accessibilityLabel(folder.gone ? "\(folder.link), \(unseen)" : folder.title)
        .accessibilityHint("Shows its detail")
        .accessibilityIdentifier("resource-folder-\(folder.id)")
        .overlay(alignment: .trailing) {
            if let agent { takeFolder(folder, of: resource, from: agent).padding(.trailing, FormMetrics.rowInset) }
        }
    }

    /// How far a folder's row stands in from its account's: the width of the row's mark and its space.
    static let folderInset: CGFloat = 42

    /// The − of a folder's row on an agent's Can use: it takes the folder back from this agent alone.
    @ViewBuilder private func takeFolder(_ folder: DriveFolder, of resource: FleetResource, from agent: String) -> some View {
        let key = resource.folderKey(folder.id)
        if working == "\(key) \(agent)" {
            ProgressView().controlSize(.small).frame(width: IconMetrics.side, height: IconMetrics.side)
        } else {
            IconButton(symbol: "minus", words: String(l10n: "Take \(folder.title) back from \(agent.agentLabel)")) {
                Task {
                    guard let reading, let database = store.state?.db else { return }
                    working = "\(key) \(agent)"
                    defer { working = nil }
                    let said = await Self.writeFolder(resource, folder: folder.id, access: folder.access(giving: agent, level: nil),
                                                      sha256: reading.sha256, store: store, database: database)
                    store.keep(said.refused, as: Self.saidName(agent, kind: resource.kind))
                    await read()
                }
            }
            .disabled(!canChange || !store.writesNow)
            .accessibilityIdentifier("access-take-folder-\(folder.id)")
        }
    }

    /// Who has this item: the agents that hold it, or all of them. The level each one has is in the item's detail. **On an
    /// agent's own list, the other agents** (the owner, 13 November 2026: "review all other pages for the same
    /// issues!!"): this agent holds every item there, so its name on every row told nothing; an item of this agent
    /// alone has no line.
    private func who(_ resource: FleetResource) -> String? { who(holders: resource.holders) }

    private func who(holders held: [ResourceHolder]) -> String? {
        let all = givable.sorted()
        let holders = held.map(\.agent).sorted()
        if holders.isEmpty { return String(l10n: "No agent") }
        if !all.isEmpty && Set(all) == Set(holders) { return String(l10n: "All agents") }
        let others = holders.filter { $0 != agent }
        return others.isEmpty ? nil : agentWords(others)
    }

    /// **The agents that can hold an item: the workers and the leads.** The hub gives a resource to no other role
    /// (`grant_fits`), so a level chosen for the fleet manager was refused, and its row went back to No access (a
    /// customer, 21 November 2026, whose one agent was the manager).
    private var givable: [String] {
        (store.state?.agents ?? []).filter { ["worker", "lead"].contains($0.role) }.map(\.name)
    }

    /// The key of `note` for a write of the card's agents, which stands under them, apart from Who may give it.
    private static func agentsNote(_ id: String) -> String { "agents \(id)" }

    // MARK: detail

    /// The card of one resource, or of one folder of a Drive account (its key, `FleetResource.folderKey`).
    @ViewBuilder private func detail(_ id: String) -> some View {
        if let parts = FleetResource.folderParts(id) {
            folderDetail(id, resource: reading?.resource(parts.resource), folderID: parts.folder)
        } else {
            resourceDetail(id)
        }
    }

    /// The detail of one resource: what it is, where its credential is, who may give it, and the agents that hold it.
    private func resourceDetail(_ id: String) -> some View {
        let resource = reading?.resource(id)
        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                IconTile(symbol: Self.symbol(resource?.kind ?? "secret"))
                // No line of the kind under the title (the owner, 21 November 2026: "remove unnecessary explanations
                // and subtitles!! Make it simple!"): the mark says it.
                Text(resource?.title ?? id)
                    .font(Self.isCode(resource?.kind ?? "") ? FormMetrics.title.monospaced()
                          : FormMetrics.title)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                Button("Done") { shown = nil }.buttonStyle(FleetOutlineButtonStyle()).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("resource-done")
            }
            if let resource, let reading, let kind = reading.kind(of: resource) {
                agentsSection(resource, kind: kind, reading: reading)
                if resource.kind == "drive", foldersOffered, resource.connected { addFolder(resource) }
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
                if disconnects(resource.id, connected: resource.connected) { disconnectRow(resource.id) }
            } else {
                Text("This resource is no longer in the list.").font(FormMetrics.text).foregroundStyle(FleetStyle.muted)
                // A Disconnect whose last write was refused after this card's own service had left the list.
                if disconnects(id, connected: false) { disconnectRow(id) }
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
        let agents = givable
        // **No line of explanation here** (the owner, 21 November 2026: "Make it simple!"): no footer, no detail under
        // All agents, and no "Has it at …" under an agent, whose control says its level.
        FormSection("Which agents may use it") {
            if let level = kind.levels.last, !agents.isEmpty {
                // "All agents" is one click and the highest level of the kind; each agent's control then shows it.
                FormRow("All agents", symbol: "person.3") {
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
            if agents.isEmpty { FormEmpty("Add an agent first. The fleet manager cannot use it.", symbol: "person.slash") }
            ForEach(agents, id: \.self) { agent in
                let level = resource.holders.first { $0.agent == agent }?.level
                let busy = working == "\(resource.id) \(agent)"
                // **The agent's glyph, with its dot, before its name** (the owner, 30 October 2026: "Marks on every agent
                // row"; margins row 15), as a secret's card has it: one agent row in every card, its name at the edge
                // of "All agents".
                FormRow(agent.agentLabel, mark: AgentGlyph(name: agent, size: GlyphSize.inline)) {
                    if busy { ProgressView().controlSize(.small) } else {
                        FleetSelect("What \(agent.agentLabel) may do with \(resource.title)",
                                    options: [FleetOption("", "No access")]
                                        + kind.levels.map { FleetOption($0, Self.levelName($0, kind: resource.kind)) },
                                    selection: level ?? "") { chosen in
                            Task { await give(resource, to: agent, level: chosen.isEmpty ? nil : chosen) }
                        } label: { FleetSelectLabel(title: level.map { Self.levelName($0, kind: resource.kind) } ?? String(l10n: "No access")) }
                            .disabled(!canChange).accessibilityIdentifier("access-agent-\(agent)")
                    }
                }
            }
            // A refused or done write of an agent's level stands at the agents, not under Who may give it.
            if let note, note.resource == Self.agentsNote(resource.id) {
                FormRow(note.text, symbol: note.warning ? "exclamationmark.triangle" : "checkmark.circle") { EmptyView() }
            }
        }
    }

    /// **One name for each level, wherever it stands** (fix round 2): a secret's level was "Reads it" on its row, "read"
    /// in At most and "Manager: up to read". A secret's are the words of its own control ("Uses it", "Reads it"), every
    /// other kind's the hub's own name for it as he reads it ("Read", "Write").
    static func levelName(_ level: String, kind: String) -> String {
        if kind == "secret" {
            switch level {
            case SecretGrant.use.rawValue: return String(l10n: "Uses it")
            case SecretGrant.read.rawValue: return String(l10n: "Reads it")
            default: break
            }
        }
        // A Drive or Gmail level by its own title, in the app's language ("Write, shared files too", not the raw
        // "Write shared" that a customer asked about on 21 November 2026).
        if kind == "drive" || kind == "gmail", let google = GoogleLevel(rawValue: level) { return google.title }
        return levelWords(level)
    }

    /// One level as the owner reads it: the hub's own name for it, without the underscore a raw value carries.
    static func levelWords(_ level: String) -> String {
        let words = level.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
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
            note = (Self.agentsNote(resource.id), refused, true)
            return
        }
        note = (Self.agentsNote(resource.id), level.map {
            String(l10n: "\(agent.agentLabel) has \(resource.title) at \(Self.levelName($0, kind: resource.kind)).")
        } ?? String(l10n: "\(agent.agentLabel) no longer has \(resource.title)."), false)
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
                // The owner, 15 November 2026 ("Yes, give the keys too"): the server's keys go with it (MCPKeyGrants).
                try await MCPKeyGrants.follow(resource.what, agent: agent, giving: level != nil, store: store,
                                              hub: hub, database: database)
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
                return String(l10n: "Founderizer cannot give this kind yet.")
            }
            return nil
        } catch let HubError.refusal(refused) {
            return refused.words
        } catch let stop as GrantSigning.Stop {
            return stop.errorDescription ?? String(l10n: "The hub did not take this change. Try again.")
        } catch {
            return String(l10n: "The hub did not take this change. Try again.")
        }
    }

    // MARK: Disconnect of a Google account

    /// The account of a Google resource id (`gmail:<email>`, `drive:<email>`), or nil for another kind.
    private static func googleAccount(_ id: String) -> String? {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        return parts.count == 2 && ["gmail", "drive"].contains(parts[0]) ? parts[1].lowercased() : nil
    }

    /// The name of a Disconnect of this account that did not end well, on the hub and generation that the page shows.
    private func leftName(_ account: String) -> String {
        GoogleDisconnectLeft.name(account, hub: store.hub, database: store.state?.db ?? "")
    }

    /// A Disconnect of this account that did not end well (`GoogleDisconnectLeft`), or nil.
    private func left(_ account: String) -> GoogleDisconnectLeft? { store.reading(leftName(account)) }

    /// A card that opens anew forgets the line of a Disconnect of an account that is still connected, as it forgets its
    /// other lines. An account that is no longer connected keeps it: its line and Disconnect end what is left of it.
    private func forgetDisconnect(_ resource: FleetResource) {
        guard resource.connected, let account = Self.googleAccount(resource.id), left(account) != nil else { return }
        store.keep(nil, as: leftName(account))
    }

    /// **Disconnect stands on the card** of the fleet's page in Settings › Apps only, where the owner said yes to it: of
    /// a Google account that the hub holds a token of, on a hub with Google; while its own Disconnect goes on (the
    /// account reads as not connected once the hub has dropped its token, and the card's spinner stays); and of one whose
    /// Disconnect did not end well while something of it is left, so that its line and a new press stay (the reviews of
    /// 16 November 2026).
    private func disconnects(_ id: String, connected: Bool) -> Bool {
        guard agent == nil, let account = Self.googleAccount(id),
              store.state?.ui_features?.contains(Google.feature) == true else { return false }
        return connected || working == "\(id) Disconnect"
            || left(account) != nil && !(reading?.cleanup(account: account).isEmpty ?? true)
    }

    /// The Disconnect of this account's card in its step (`GoogleDisconnectRow`).
    private func disconnectRow(_ id: String) -> some View {
        let account = Self.googleAccount(id) ?? ""
        return GoogleDisconnectRow(step: working == "\(id) Disconnect" ? .working : disconnecting == id ? .asking : .button,
                                   refused: left(account)?.refused, enabled: canChange,
                                   press: { disconnecting = id },
                                   cancel: { disconnecting = nil },
                                   confirm: { Task { await disconnect(id: id, account: account) } })
    }

    /// The hub revokes the account's access at Google and drops its token (`POST /ui/google/disconnect`); then what is
    /// left of the account here goes, one write at a time (`GoogleDisconnect.clear`): each agent's level and the
    /// manager's standing of each service. Then the account's card closes, and the next reading has no row of it. One
    /// that does not end well is kept under the account (`GoogleDisconnectLeft`), for the hub and generation that it
    /// ran on: while the page shows another, its line goes.
    private func disconnect(id: String, account: String) async {
        guard canChange, !account.isEmpty, let database = store.state?.db else { return }
        let hub = store.hub, client = store.installation
        let name = GoogleDisconnectLeft.name(account, hub: hub, database: database)
        working = "\(id) Disconnect"
        note = nil
        defer { working = nil }
        var refused: String?
        do {
            _ = try await GoogleClient().disconnect(hub: hub, database: database, client: client, account: account)
            try await GoogleDisconnect.clear(account: account) {
                try await ResourcesClient().read(hub: hub, database: database)
            } write: { item, sha256 in
                switch item {
                case .access(let service):
                    try await GoogleClient().saveAccess(hub: hub, database: database, client: client, sha256: sha256,
                                                        account: account, service: service, access: [:])
                case .standing(let service):
                    _ = try await ResourcesClient().saveStanding(hub: hub, database: database, client: client,
                                                                 sha256: sha256, resource: "\(service.rawValue):\(account)",
                                                                 standing: .ownerOnly)
                case .folder(let folder):
                    _ = try await GoogleClient().saveFolder(hub: hub, database: database, client: client, sha256: sha256,
                                                            account: account, folder: folder, access: [:])
                }
            }
        } catch let HubError.refusal(refusal) {
            refused = refusal.words
        } catch {
            refused = String(l10n: "The hub did not take this change. Try again.")
        }
        disconnecting = nil
        if store.hub == hub, store.state?.db == database {
            store.keep(refused.map(GoogleDisconnectLeft.init(refused:)), as: name)
            if refused == nil, let open = shown?.id, Self.googleAccount(open) == account { shown = nil }
        }
        await read()
    }

    // MARK: Drive folders

    /// **Add folder, in a Drive account's card, under its agents** (the owner's "Yes, as drawn" of 20 November 2026): a
    /// link, and after the click the field for a folder's link in its place, with Add. The account is the card's, so
    /// there is no account choice. The hub reads the folder with the account (`saveFolder` with no agent), and its card
    /// opens in this one's place, to give it to agents.
    @ViewBuilder private func addFolder(_ resource: FleetResource) -> some View {
        if addingFolder == resource.id {
            HStack(spacing: 8) {
                TextField(text: $folderLink, prompt: Text(verbatim: "")) { Text("Paste the link of a Drive folder") }
                    .fieldPlaceholder(String(l10n: "Paste the link of a Drive folder"), shows: folderLink.isEmpty).fleetField()
                    .onSubmit { Task { await findFolder(resource) } }
                    .accessibilityIdentifier("drive-folder-link")
                if working == "\(resource.id) folder" {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Add") { Task { await findFolder(resource) } }.buttonStyle(FleetPrimaryButtonStyle())
                        .disabled(!canChange || folderLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("drive-folder-add")
                }
            }
        } else {
            Button { folderLink = ""; note = nil; addingFolder = resource.id } label: {
                Text("Add folder").padding(.vertical, IconMetrics.reach).contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.vertical, -IconMetrics.reach).font(FormMetrics.detail)
            .foregroundStyle(FleetStyle.muted).disabled(!canChange).accessibilityIdentifier("drive-folder-start")
        }
    }

    /// The hub reads the folder of the field's link with the card's account, and its card opens.
    private func findFolder(_ resource: FleetResource) async {
        guard let reading, let database = store.state?.db else { return }
        let link = folderLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty, working == nil else { return }
        // A folder that agents hold already opens its card: a write with no agent would take it from all of them.
        if let id = DriveFolder.id(in: link), let held = resource.folders?.first(where: { $0.id == id }) {
            addingFolder = nil
            folderLink = ""
            shown = ShownResource(id: resource.folderKey(held.id))
            return
        }
        working = "\(resource.id) folder"
        note = nil
        defer { working = nil }
        do {
            let saved = try await GoogleClient().saveFolder(hub: store.hub, database: database, client: store.installation,
                                                            sha256: reading.sha256, account: resource.what, folder: link,
                                                            access: [:])
            let key = resource.folderKey(saved.folder.id)
            addingFolder = nil
            folderLink = ""
            addedFolder = (key, saved.folder)
            shown = ShownResource(id: key)
        } catch let HubError.refusal(refused) {
            note = (resource.id, refused.words, true)
        } catch {
            note = (resource.id, String(l10n: "The hub did not take this change. Try again."), true)
        }
    }

    /// **The card of one folder of a Drive account**: the account card's sections for this folder alone. Its title is
    /// the folder's name, and the line under it the account's email. Each agent's control offers No access and the
    /// levels that add something to its whole Drive (`FleetResource.folderLevels`). No standing and no Remove: a folder
    /// goes when its last agent goes to No access.
    private func folderDetail(_ key: String, resource: FleetResource?, folderID: String) -> some View {
        let folder = resource?.folders?.first(where: { $0.id == folderID }) ?? (addedFolder?.key == key ? addedFolder?.folder : nil)
        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                IconTile(symbol: Self.symbol("drive"))
                VStack(alignment: .leading, spacing: 3) {
                    Text(folder?.title ?? folderID).font(FormMetrics.title)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled).accessibilityAddTraits(.isHeader)
                    Text(resource?.what ?? "").font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                }
                Spacer(minLength: 12)
                Button("Done") { shown = nil; addedFolder = nil }.buttonStyle(FleetOutlineButtonStyle())
                    .keyboardShortcut(.cancelAction).accessibilityIdentifier("resource-done")
            }
            if let resource, let folder, let kind = reading?.kind(of: resource) {
                folderAgents(resource, folder: folder, key: key, kind: kind)
                if !folder.history.isEmpty {
                    FormSection("Who gave it") {
                        ForEach(folder.history) { record in
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

    /// Which agents may use one folder, as the account card's "Which agents may use it" says it for the whole Drive.
    @ViewBuilder private func folderAgents(_ resource: FleetResource, folder: DriveFolder, key: String,
                                           kind: ResourceKind) -> some View {
        // Workers and leads: the hub gives a folder to no other role, and a write that named one would be refused whole.
        let agents = givable
        // A sharing that the hub has not read yet offers what a shared folder offers: Write could give nothing there.
        let shared = folder.shared != false
        FormSection("Which agents may use it") {
            if let top = GoogleService.drive.levels.filter({ shared ? $0 != .write : true }).last, !agents.isEmpty {
                FormRow("All agents", symbol: "person.3") {
                    if working == "\(key) all" { ProgressView().controlSize(.small) }
                    else {
                        Toggle("All agents", isOn: Binding(
                            get: { !agents.isEmpty && Set(folder.holders.map(\.agent)) == Set(agents) },
                            set: { on in Task { await giveFolderAll(resource, folder: folder, key: key, agents: agents,
                                                                    level: on ? top : nil) } }))
                            .toggleStyle(.switch).controlSize(.small).labelsHidden()
                            .disabled(!canChange).accessibilityIdentifier("folder-all-agents")
                    }
                }
            }
            if agents.isEmpty { FormEmpty("Add an agent first. The fleet manager cannot use it.", symbol: "person.slash") }
            ForEach(agents, id: \.self) { agent in
                let level = folder.holders.first { $0.agent == agent }?.level
                let options = resource.folderLevels(for: agent, shared: shared)
                FormRow(agent.agentLabel, mark: AgentGlyph(name: agent, size: GlyphSize.inline)) {
                    if working == "\(key) \(agent)" { ProgressView().controlSize(.small) } else {
                        FleetSelect("What \(agent.agentLabel) may do with \(folder.title)",
                                    options: [FleetOption("", "No access")]
                                        + options.map { FleetOption($0.rawValue, Self.levelName($0.rawValue, kind: resource.kind)) },
                                    selection: level ?? "") { chosen in
                            Task { await giveFolder(resource, folder: folder, key: key, to: agent,
                                                    level: GoogleLevel(rawValue: chosen)) }
                        } label: { FleetSelectLabel(title: level.map { Self.levelName($0, kind: resource.kind) } ?? String(l10n: "No access")) }
                            .disabled(!canChange || (options.isEmpty && level == nil))
                            .accessibilityIdentifier("folder-agent-\(agent)")
                    }
                }
            }
            if let note, note.resource == key {
                FormRow(note.text, symbol: note.warning ? "exclamationmark.triangle" : "checkmark.circle") { EmptyView() }
            }
        }
    }

    /// One agent's level of one folder, or none.
    private func giveFolder(_ resource: FleetResource, folder: DriveFolder, key: String, to agent: String,
                            level: GoogleLevel?) async {
        guard let reading, let database = store.state?.db else { return }
        working = "\(key) \(agent)"
        note = nil
        defer { working = nil }
        let said = await Self.writeFolder(resource, folder: folder.id, access: folder.access(giving: agent, level: level),
                                          sha256: reading.sha256, store: store, database: database)
        let done = level.map { String(l10n: "\(agent.agentLabel) has \(folder.title) at \($0.title).") }
            ?? String(l10n: "\(agent.agentLabel) no longer has \(folder.title).")
        note = (key, said.refused ?? said.tookPlaceOf ?? done, said.refused != nil)
        await read()
    }

    /// Every agent that can hold the folder at this level gets it, in one write; or none of them keeps it.
    private func giveFolderAll(_ resource: FleetResource, folder: DriveFolder, key: String, agents: [String],
                               level: GoogleLevel?) async {
        guard let reading, let database = store.state?.db else { return }
        working = "\(key) all"
        note = nil
        defer { working = nil }
        var access: [String: GoogleLevel] = [:]
        if let level {
            for agent in agents where resource.folderLevels(for: agent, shared: folder.shared != false).contains(level) {
                access[agent] = level
            }
        }
        let said = await Self.writeFolder(resource, folder: folder.id, access: access, sha256: reading.sha256, store: store,
                                          database: database)
        if let words = said.refused ?? said.tookPlaceOf { note = (key, words, said.refused != nil) }
        await read()
    }

    /// **The one write of one folder's agents** (`POST /ui/team/google` with the folder): the hub's words when it
    /// refused, else the line for each agent whose Drive of another account the write took the place of, or nil.
    static func writeFolder(_ resource: FleetResource, folder: String, access: [String: GoogleLevel], sha256: String,
                            store: FleetStore, database: String) async -> (refused: String?, tookPlaceOf: String?) {
        do {
            let saved = try await GoogleClient().saveFolder(hub: store.hub, database: database, client: store.installation,
                                                            sha256: sha256, account: resource.what, folder: folder,
                                                            access: access)
            let lines = saved.tookPlaceOf.sorted { $0.key < $1.key }.map { agent, account in
                String(l10n: "\(agent.agentLabel) no longer has the Drive of \(account).")
            }
            return (nil, lines.isEmpty ? nil : lines.joined(separator: " "))
        } catch let HubError.refusal(refused) {
            return (refused.words, nil)
        } catch {
            return (String(l10n: "The hub did not take this change. Try again."), nil)
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

    private static func text(_ error: Error) -> String { (error as? LocalizedError)?.errorDescription ?? String(l10n: "The hub did not answer.") }

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
                note = (resource.id, String(l10n: "The fleet manager may give \(resource.title) to \(reading.audienceWords(to)), at most \(AccessSettings.levelName(max, kind: resource.kind))."), false)
            }
        } catch {
            await read()
            note = (resource.id, String(l10n: "Founderizer could not change this. \(Self.text(error))"), true)
        }
    }

    // MARK: reading

    /// Reads the resources every 15 seconds while the page shows, and again after 3 seconds when a read failed.
    private func poll() async {
        failedSince = nil; note = nil
        // `-openResource <id>` opens one item's detail, so that card can be looked at without clicking to it.
        shown = AppDefaults.store.string(forKey: "openResource").map(ShownResource.init)
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
            if !Task.isCancelled, store.hub == hub, store.state?.db == database {
                if (store.reading(name(agent) + ".failedSince") as ContinuousClock.Instant?) == nil {
                    store.keep(ContinuousClock.now, as: name(agent) + ".failedSince")
                }
            }
            return false
        }
        guard !Task.isCancelled else { return false }
        if first, let start { await store.settle(since: start) }
        guard store.hub == hub, store.state?.db == database else { return false }
        store.keep(list, as: name(agent))
        store.keep(nil, as: name(agent) + ".failedSince")
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
        } else if let reading, store.state?.ui_features?.contains(ResourceList.feature) == true, store.writesNow, !open.isEmpty {
            FleetSelect(words, options: open.map { FleetOption($0.id, $0.title, mark: .symbol(AccessSettings.symbol(kind))) }) { id in
                guard let resource = open.first(where: { $0.id == id }) else { return }
                Task { await give(resource, reading: reading) }
            } label: {
                Image(systemName: "plus").font(IconMetrics.symbol(13)).foregroundStyle(FleetStyle.muted)
            }
            .buttonStyle(FleetIconButtonStyle())
            .help(words)
            // In the column of the rows' −, which stand the rows' inset in from the card's edge.
            .padding(.trailing, FormMetrics.rowInset)
            .accessibilityIdentifier("access-give-\(kind)")
        }
    }

    /// What the + gives, in the owner's words: "Give Web-Lead a repository".
    private var words: String {
        switch kind {
        case "repo": String(l10n: "Give \(agent.agentLabel) a repository")
        case "drive": String(l10n: "Give \(agent.agentLabel) a Drive account")
        case "gmail": String(l10n: "Give \(agent.agentLabel) a Gmail account")
        case "tool": String(l10n: "Give \(agent.agentLabel) an MCP server")
        default: String(l10n: "Give \(agent.agentLabel) one more")
        }
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
            FormRow("At most", symbol: "arrow.up.to.line") {
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
            // No footer (the owner, 21 November 2026: "Make it simple!"): the choice's own words say it.
            return (String(l10n: "You alone"), String(l10n: "You give it"), "person.fill", FleetStyle.muted, nil)
        case .grantable(let max, _):
            // No footer of 35 words on what the manager may do (D-2): the two rows above it say it.
            // The row's words (fix round 2): what the manager may give, by the level's one name.
            return (String(l10n: "You and the fleet manager"), String(l10n: "Manager may give: \(AccessSettings.levelName(max, kind: kind))"),
                    "person.2.fill", FleetStyle.text, nil)
        }
    }

    /// The rows of the first dropdown: you, or you and the manager.
    fileprivate static func choices(levels: [String]) -> [FleetOption<StandingChoice>] {
        var rows = [FleetOption(StandingChoice.owner, "You alone", mark: .symbol("person.fill"))]
        if !levels.isEmpty {
            rows.append(FleetOption(StandingChoice.manager, "You and the fleet manager", mark: .symbol("person.2.fill")))
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
