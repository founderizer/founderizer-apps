import AppKit
import FleetCore
import SwiftUI

/// The four apps of Settings › Apps, each with its own page (`Destination.app`).
enum AppsGroup: String, CaseIterable, Hashable {
    case github, drive, gmail, mcp

    var title: String {
        switch self {
        case .github: "GitHub"
        case .drive: "Google Drive"
        case .gmail: "Gmail"
        case .mcp: "MCP servers"
        }
    }

    /// The kind of the resources that its page lists.
    var kind: String {
        switch self {
        case .github: "repo"
        case .drive: GoogleService.drive.rawValue
        case .gmail: GoogleService.gmail.rawValue
        case .mcp: "tool"
        }
    }

    var service: GoogleService? { self == .drive ? .drive : self == .gmail ? .gmail : nil }
}

/// Settings › Apps, the page: **one row for each app, and each app has its own page** (the owner, 10 November 2026:
/// "performance of certain pages like the Apps one, maybe we should split it?", and his yes to the drawing). The four
/// groups stood on one page, and Google Drive, Gmail and MCP servers stood under the 213 repositories of his fleet. A row
/// is the app's mark, its name and how many it holds, with the chevron of a row that opens; the app's page
/// (`AppsSettings(only:)`) has what its group had, under its own title, with Apps as its back link, as a server's page
/// has Servers.
struct AppsPage: View {
    @Bindable var store: FleetStore
    /// When this visit began: "Last reading" waits for this visit's read to have its second (`Held`).
    @State private var opened = ContinuousClock.now

    private var features: [String] { store.state?.ui_features ?? [] }
    private var groups: [AppsGroup] {
        AppsGroup.allCases.filter { group in
            switch group {
            case .github: features.contains(Integrations.feature)
            case .drive, .gmail: features.contains(Google.feature)
            case .mcp: features.contains(MCP.feature)
            }
        }
    }
    private var offered: Bool { features.contains(ResourceList.feature) }
    private var reading: ResourceList? { store.reading(AccessSettings.name(nil)) }
    private var failed: Bool { store.reading(AccessSettings.name(nil) + ".failed") ?? false }

    var body: some View {
        FleetPage("Apps") { rows } actions: { AccessSettings.lastReading(store, agent: nil, since: opened) }
            // The counts are the resources' reading, read as the lists read it (`AccessSettings.readOnce`).
            .task(id: "\(store.hub)/\(store.state?.db ?? "")/\(offered)") {
                let start = ContinuousClock.now
                while !Task.isCancelled {
                    let current = await AccessSettings.readOnce(store, agent: nil, since: start)
                    do { try await store.nap(current || !offered ? 15 : 3) } catch { return }
                }
            }
    }

    /// **Nothing of the apps until the first reading is in, then all of them in one frame** (the loading contract, C5.1),
    /// as the page of four groups had it.
    @ViewBuilder private var rows: some View {
        if groups.isEmpty {
            FormSection { FormEmpty("This hub offers no app yet.", symbol: "puzzlepiece.extension") }
        } else if offered && reading == nil {
            if failed || !store.isFresh {
                if !store.hubNoticeShows {
                    FormSection { FormRow("Founderizer cannot read the resources now.", detail: "It reads again when the hub answers.") }
                }
            } else {
                LoadingLine("Reading the resources…")
            }
        } else {
            FormSection { ForEach(groups, id: \.self) { row($0) } }
        }
    }

    /// One app: its mark, its name and how many it holds; a click opens its page. GitHub's row carries the orange mark
    /// of its rows while the GitHub App does not reach a repository, so that one is not a page deeper than it was.
    private func row(_ group: AppsGroup) -> some View {
        let words = count(group)
        let unreached = group == .github && !(reading?.unreachedPages().isEmpty ?? true)
        return Button { store.destination = .app(group) } label: {
            FormRow(group.title, mark: mark(group)) {
                HStack(spacing: 8) {
                    if unreached {
                        Image(systemName: "exclamationmark.triangle.fill").font(IconMetrics.symbol(13)).foregroundStyle(.orange)
                            .help(AccessSettings.unreachedWords)
                    }
                    if let words { Text(words).foregroundStyle(FleetStyle.muted).lineLimit(1) }
                    Image(systemName: "chevron.right").font(IconMetrics.symbol(11, weight: .semibold)).foregroundStyle(FleetStyle.muted)
                }
            }
        }
        .buttonStyle(FleetRowButtonStyle())
        .accessibilityLabel(group.title)
        .accessibilityValue([words, unreached ? AccessSettings.unreachedWords : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Opens its page")
        .accessibilityIdentifier("apps-\(group.rawValue)")
    }

    /// How many the fleet holds of it: "213 repositories", "No accounts", "3". None while the hub lists no resources.
    private func count(_ group: AppsGroup) -> String? {
        guard let reading else { return nil }
        let held = reading.resources.filter { $0.kind == group.kind }.count
        switch group {
        case .github: return held == 0 ? "No repositories" : held == 1 ? "1 repository" : "\(held) repositories"
        case .drive, .gmail: return held == 0 ? "No accounts" : held == 1 ? "1 account" : "\(held) accounts"
        case .mcp: return held == 0 ? "None" : "\(held)"
        }
    }

    @ViewBuilder private func mark(_ group: AppsGroup) -> some View {
        switch group {
        case .github: GitHubMark(size: 15).foregroundStyle(FleetStyle.text)
        case .drive: ServiceMark(service: .drive, size: 15)
        case .gmail: ServiceMark(service: .gmail, size: 15)
        case .mcp: Image(systemName: "puzzlepiece.extension").font(IconMetrics.symbol(13)).foregroundStyle(FleetStyle.text)
        }
    }
}

/// Settings › Apps: the apps the fleet works in — GitHub, Google Drive and Gmail — and its MCP servers, each its own
/// group with its own mark and its own action on its heading, the things the fleet holds in it, and which agents may
/// use each. The MCP servers were a section of their own, MCPs, beside this one, and GitHub stood in both (the owner's
/// map of 28 October 2026: one Apps, with "a group MCP servers with Add MCP server").
///
/// The unit is the account or the repository, never the agent. One account is connected once and belongs to the
/// fleet; then as many agents as the owner wants are given it, each at its own level, from the account's own
/// control. An agent's own Apps are this same view scoped to that agent, in its Can use: the same rows, each of which
/// opens the same card (D-5, one editor for each kind), with a − that takes it back from that agent, a + on each heading
/// that gives it one more the fleet already holds (`AccessGive`), and the empty card where it has nothing (the owner's
/// yes of 3 November 2026).
struct AppsSettings: View {
    @Bindable var store: FleetStore
    /// One agent's own, or nil for the fleet's.
    var agent: String?
    /// **One app's own page of Settings › Apps** (the owner's yes of 10 November 2026): its group alone, under the page's
    /// title in place of its heading, with the heading's buttons at the right of that title and Apps as its back link.
    var only: AppsGroup?
    /// `GET /ui/team`, for the GitHub App: the store's (`FleetStore.reading`), the fleet's and each agent's under its own
    /// name, so the card he saw last is there in the first frame when he comes back.
    private var integrations: IntegrationsSnapshot? {
        get { store.reading("apps.integrations.\(agent ?? "fleet")") }
        nonmutating set { store.keep(newValue, as: "apps.integrations.\(agent ?? "fleet")") }
    }
    /// The resources of the three lists (`AccessSettings`), which each list reads for itself once there is a reading.
    private var resources: ResourceList? {
        get { store.reading(AccessSettings.name(agent)) } nonmutating set { store.keep(newValue, as: AccessSettings.name(agent)) }
    }
    /// Changes when an account is connected, so the item list reads again.
    @State private var connects = 0
    /// When this visit began: the lists' reading is not old before this visit's read has had a second (`Held`).
    @State private var opened = ContinuousClock.now
    /// The width of a form page's cards, which every heading here takes too (`FormSection`).
    @Environment(\.formMeasure) private var measure
    /// The Connect of each service on the fleet's page, whose button stands on the service's heading.
    @State private var drive = GoogleConnecting()
    @State private var gmail = GoogleConnecting()
    /// Adding an MCP server on the fleet's page, whose Add stands on the group's heading (`MCPAddSection`).
    @State private var mcp = MCPAdding()
    /// This visit has read the GitHub App.
    @State private var appRead = false
    /// This visit's first read of the resources failed: the lists' own line says so once, in the place of the three.
    @State private var unread = false
    /// The GitHub App, read before the page first opens (`PagePrefetch`); the resources are `AccessSettings.prefetch`.
    static let prefetch = PagePrefetch("apps.integrations.fleet", feature: Integrations.feature) {
        try await IntegrationsClient().read(hub: $0, database: $1)
    }

    private var hasGitHub: Bool { store.state?.ui_features?.contains(Integrations.feature) == true }
    private var hasGoogle: Bool { store.state?.ui_features?.contains(Google.feature) == true }
    private var hasMCP: Bool { store.state?.ui_features?.contains(MCP.feature) == true }
    /// The resources can be read and are not yet.
    private var listsWait: Bool {
        store.state?.ui_features?.contains(ResourceList.feature) == true && store.isFresh && resources == nil
    }
    /// **Nothing of the apps until the first reading is in, then all of them in one frame** (the loading contract, C5.1).
    /// Three headings stood each over a reading row of its own, and the rows' going moved Google Drive up 44 pt and
    /// Gmail 88 pt on the owner's Mac. The fleet's page waits for its GitHub App too, whose card is under the first heading.
    /// The GitHub App's card is on this page: the fleet's page of every group, or GitHub's own.
    private var drawsApp: Bool { agent == nil && hasGitHub && (only == nil || only == .github) }
    private var waits: Bool {
        (hasGitHub || hasGoogle || hasMCP) && (listsWait || drawsApp && integrations == nil && !appRead)
    }

    var body: some View {
        Group {
            if let only {
                FleetPage(only.title, back: FleetBack("Apps") { store.destination = .settings(.apps) }) {
                    if waits { waiting } else { page(only) }
                } actions: {
                    lastReading
                    actions(only)
                }
            } else {
                // A section of a page, never a page: an agent's Apps brings its own title.
                VStack(alignment: .leading, spacing: FleetSpace.block) {
                    if waits {
                        waiting
                    } else {
                        if hasGitHub { github }
                        if hasGoogle {
                            service(.drive)
                            service(.gmail)
                        }
                        if hasMCP { mcpServers }
                    }
                    if !hasGitHub && !hasGoogle && !hasMCP {
                        FormSection { FormEmpty("This hub offers no app yet.", symbol: "puzzlepiece.extension") }
                    }
                }
            }
        }
        .task(id: "\(store.hub)/\(store.state?.db ?? "")/apps") { await readFirst() }
        // The MCP servers' form keeps its state here, where the page always is (`MCPAdding`).
        .task(id: "\(store.hub)/\(store.state?.db ?? "")/mcp") {
            if agent == nil && hasMCP && (only == nil || only == .mcp) { await mcp.start(store: store) }
        }
    }

    /// While the hub does not answer nothing is read: the lists' failed line, never "Reading…". **Not while the
    /// window's notice says the outage** (`FleetStore.hubNoticeShows`; fix round 3, item 33): it is said once, over the
    /// page.
    @ViewBuilder private var waiting: some View {
        if unread || store.connectionError != nil {
            if !store.hubNoticeShows {
                FormSection { FormRow("Founderizer cannot read the resources now.", detail: "It reads again when the hub answers.") }
            }
        } else {
            LoadingLine("Reading the resources…")
        }
    }

    /// One app's page, under its title: what its group had under its heading, and its list.
    @ViewBuilder private func page(_ group: AppsGroup) -> some View {
        switch group {
        case .github:
            GitHubAppSection(store: store, app: integrations?.github) { await readIntegrations() }
            AccessSettings(store: store, kinds: [group.kind], agent: nil)
        case .drive, .gmail:
            if let service = group.service, connecting(service).shows { GoogleConnectStatus(model: connecting(service)) }
            AccessSettings(store: store, kinds: [group.kind], agent: nil).id("\(group.kind)/\(connects)")
        case .mcp:
            if mcp.shows { MCPAddSection(store: store, shared: mcp) }
            AccessSettings(store: store, kinds: [group.kind], agent: nil)
        }
    }

    /// One app's page's buttons, at the right of its title: its group's heading had them.
    @ViewBuilder private func actions(_ group: AppsGroup) -> some View {
        switch group {
        case .github: addOnGitHub
        case .drive, .gmail: if let service = group.service { connectButton(service) }
        case .mcp: addMCPServer
        }
    }

    /// **Add on GitHub, only while a row of this page has the orange mark** (the owner's yes of 2 November 2026): a
    /// repository that the hub's GitHub App does not reach. GitHub lets only a person add one to the App's installation,
    /// so the button opens that page (each page once; usually the one installation's).
    @ViewBuilder private var addOnGitHub: some View {
        let pages = resources?.unreachedPages(of: agent) ?? []
        if !pages.isEmpty {
            Button { pages.forEach { NSWorkspace.shared.open($0) } } label: {
                Label("Add on GitHub", systemImage: "arrow.up.right")
            }
            .buttonStyle(FleetOutlineButtonStyle())
            .accessibilityIdentifier("github-add-on-github")
        }
    }

    /// Bringing another account of one Google service into the fleet.
    private func connectButton(_ service: GoogleService) -> some View {
        let connect = connecting(service)
        return Button { connect.start(store: store, service: service, giveTo: nil) { connects += 1 } } label: {
            Label("Connect account", systemImage: "plus")
        }
        .buttonStyle(FleetOutlineButtonStyle()).disabled(!connect.canConnect(store))
        .accessibilityIdentifier("google-connect-\(service.rawValue)")
    }

    @ViewBuilder private var addMCPServer: some View {
        if agent == nil && mcp.offered(store) {
            Button { mcp.open() } label: { Label("Add MCP server", systemImage: "plus") }
                .buttonStyle(FleetOutlineButtonStyle())
                .disabled(mcp.adding || !mcp.canOpen(store))
                .accessibilityIdentifier("mcp-add")
        }
    }

    private func connecting(_ service: GoogleService) -> GoogleConnecting { service == .drive ? drive : gmail }

    /// **The MCP servers, one group of Apps**: the servers the fleet holds, each with the agents that use it, and Add
    /// MCP server on the group's heading, where every group of a page has its add. The form opens under the heading.
    private var mcpServers: some View {
        // The list brings its own room over it (`AccessSettings.lead`), and none while it draws nothing (margins row 20).
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: FleetSpace.inside) {
                heading("MCP servers") {
                    Image(systemName: "puzzlepiece.extension").font(IconMetrics.symbol(13)).foregroundStyle(FleetStyle.text)
                } accessory: {
                    if !hasGitHub && !hasGoogle { lastReading }
                    addMCPServer
                    if let agent { AccessGive(store: store, agent: agent, kind: "tool") }
                }
                if agent == nil && mcp.shows { MCPAddSection(store: store, shared: mcp) }
            }
            AccessSettings(store: store, kinds: ["tool"], agent: agent, lead: FleetSpace.inside)
        }
    }

    private var github: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: FleetSpace.inside) {
                heading("GitHub") { GitHubMark(size: Self.markSide).foregroundStyle(FleetStyle.text) } accessory: {
                    lastReading
                    addOnGitHub
                    if let agent { AccessGive(store: store, agent: agent, kind: "repo") }
                }
                // Whether this card is there at all is the card's own business. The condition was here, and it took
                // the whole section out of the tree the moment a save succeeded — so the one line that tells him to
                // delete the .pem file he had just downloaded was the one line he never saw. The card now hides
                // itself when it has nothing to ask and nothing to say, which is the same quiet page without that.
                if agent == nil {
                    GitHubAppSection(store: store, app: integrations?.github) { await readIntegrations() }
                }
            }
            AccessSettings(store: store, kinds: ["repo"], agent: agent, lead: FleetSpace.inside)
        }
    }

    /// One Google service: the accounts the fleet holds, each with the agents that use it. Bringing another account
    /// in is the heading's own button on the fleet's page — where a group of a page has its action — and no longer a
    /// row of its own over the list. An agent's has none: an account is connected and given here, in Settings.
    private func service(_ service: GoogleService) -> some View {
        let connect = connecting(service)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: FleetSpace.inside) {
                heading(service == .drive ? "Google Drive" : "Gmail") { ServiceMark(service: service, size: Self.markSide) } accessory: {
                    if service == .drive && !hasGitHub { lastReading }
                    if agent == nil {
                        connectButton(service)
                    } else if let agent {
                        AccessGive(store: store, agent: agent, kind: service.rawValue)
                    }
                }
                if agent == nil, connect.shows { GoogleConnectStatus(model: connect) }
            }
            // The three lists draw one reading, and the first of them on the page says when it is the last one.
            AccessSettings(store: store, kinds: [service.rawValue], agent: agent, lead: FleetSpace.inside)
                .id("\(service.rawValue)/\(connects)")
        }
    }

    /// The lists' "Last reading", in the heading row of the page's first group (`AccessSettings.lastReading`).
    private var lastReading: some View { AccessSettings.lastReading(store, agent: agent, since: opened) }

    /// **The side of a heading's mark**: the brand marks' 15 points, and the frame of every heading's mark, so the words of
    /// the four headings begin at one x (margins row 21). The MCP servers' symbol is 19 points wide at its 13 and put its
    /// words 4 points to the right of the others.
    private static let markSide: CGFloat = 15

    private func heading(_ words: String, @ViewBuilder mark: () -> some View,
                         @ViewBuilder accessory: () -> some View) -> some View {
        // **Its button ends on its card's edge** (D-8 item 8): the heading took the page's 1,100 pt while its card took
        // the form's 680, so "Connect account" and "Add MCP server" stood 330–420 pt right of their cards.
        HStack(spacing: 8) {
            mark().frame(width: Self.markSide)
            Text(words).font(FormMetrics.heading).foregroundStyle(FleetStyle.text).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            accessory()
        }.frame(minHeight: FormMetrics.headingRow).padding(.leading, 2)
            .frame(maxWidth: measure ?? .infinity, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func readIntegrations() async {
        guard hasGitHub, let database = store.state?.db else { return }
        let hub = store.hub
        let fresh = try? await IntegrationsClient().read(hub: hub, database: database)
        if store.hub == hub, store.state?.db == database, let fresh { integrations = fresh }
    }

    /// The page's first reading: the GitHub App, once for this hub generation as before, and the resources while the
    /// lists have none, again every 3 seconds while that read fails. Both are kept in one frame; from then on each list
    /// reads for itself.
    private func readFirst() async {
        guard let database = store.state?.db else { return }
        let hub = store.hub, start = ContinuousClock.now, first = waits
        let app = drawsApp ? try? await IntegrationsClient().read(hub: hub, database: database) : nil
        let list = listsWait ? try? await AccessSettings.readResources(store, agent: agent, hub: hub, database: database) : nil
        if first { await store.settle(since: start) }
        guard !Task.isCancelled, store.hub == hub, store.state?.db == database else { return }
        if let app { integrations = app }
        if let list { resources = list }
        appRead = true; unread = listsWait
        while unread {
            do { try await store.nap(3) } catch { return }
            let list = listsWait ? try? await AccessSettings.readResources(store, agent: agent, hub: hub, database: database) : nil
            guard !Task.isCancelled, store.hub == hub, store.state?.db == database else { return }
            if let list { resources = list }
            unread = listsWait
        }
    }
}
