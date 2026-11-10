import FleetCore
import SwiftUI

/// The parts of one agent. Chat is the agent's own page (`.agent(name)`, with its status panel); the other parts are
/// its details, with a sidebar of their own.
///
/// **Five parts** (the owner's yes of 28 October 2026 to D-5 ("All") for four of them, and of 6 November 2026 to Tasks):
/// Runs on, Behaviour, Tasks, People and Can use — the manager has Runs on, Behaviour and People. They were twelve
/// sections that took the chat's place, six of which held nothing for most agents. **Runs on** is the page that was
/// Settings (its server, its AI provider, its account and its usage, and the one "…"), which is no longer a second
/// "Settings" beside the app's own. **Behaviour** is its rules, with its duties under "Responsible for", its schedules and
/// its memory. **Tasks** is the task board of the main sidebar with this agent's tasks only (`ActivityBoard.scope`); the
/// manager owns no task — it gives them — so it has none. **People** is its channels, the people who can talk to it and
/// its conversations: with people, and with the other agents it wrote to or heard from (`AgentConversationPage`). **Can
/// use** is the secrets, the knowledge and the apps it has, as rows of the fleet's own that open the same card as
/// Settings, where each kind is given and taken back.
enum AgentTab: String, CaseIterable, Hashable {
    case settings, chat, behaviour, tasks, people, canUse = "canuse"

    /// A part by its name, also by the names of the sections that are in one of the parts now: `-openPage
    /// agent.<name>.memory` opens Behaviour, `.secrets` Can use, `.channels` People.
    static func named(_ name: String) -> AgentTab? {
        switch name {
        case "overview", "runson": .settings
        case "memory", "notes", "duties": .behaviour
        case "channels", "conversations": .people
        case "secrets", "knowledge", "mcps", "apps": .canUse
        default: AgentTab(rawValue: name)
        }
    }

    var title: String {
        switch self {
        case .settings: "Runs on"
        case .chat: "Chat"
        case .behaviour: "Behaviour"
        case .tasks: "Tasks"
        case .people: "People"
        case .canUse: "Can use"
        }
    }

    /// The title over the open part.
    var heading: String { title }

    /// The part is a `FleetPage` of its own: it brings its title and the actions at its right, and it scrolls as a
    /// whole. Every part is.
    var ownsPage: Bool { self != .chat }

    /// The symbol of the part in the sidebar of the details.
    var symbol: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .settings: "desktopcomputer"
        case .behaviour: "text.book.closed"
        // The symbol of Tasks in the main sidebar: one board, one mark.
        case .tasks: "rectangle.split.3x1"
        case .people: "person.2"
        case .canUse: "key"
        }
    }

    /// The parts of the details that this hub offers for an agent of this role. Chat is not one of them. The manager has
    /// no Tasks, because it owns no task, and no Can use, because it holds no secret, file or app of its own. People
    /// stands for every agent on a hub with messages between agents: its conversations with the others are there.
    static func available(features: [String], role: String?) -> [AgentTab] {
        let worker = role == "worker" || role == "lead"
        return allCases.filter { tab in
            switch tab {
            case .chat: false
            // Always: its server, its provider, its account and its usage are read on every hub.
            case .settings: true
            case .behaviour: features.contains("profiles") || features.contains(AgentNotes.feature)
                || features.contains(AgentMemory.feature) || features.contains(Duties.feature) || features.contains("triggers")
            // Every hub sends its tasks in its state.
            case .tasks: worker
            case .people: features.contains(ChatApps.feature) || features.contains(AgentMessages.feature)
                || worker && (features.contains(People.feature) || features.contains(People.conversationsFeature))
            case .canUse: worker && (features.contains(ResourceList.feature) || features.contains(KnowledgeClient.feature)
                || features.contains(MCP.feature) || features.contains(Google.feature) || features.contains(Integrations.feature))
            }
        }
    }
}

/// One agent's details: a sidebar of their own at the left (Back to chat, the agent, and a row with a symbol for each
/// part) and the open part at the right, under its title. The editor of one rule of Behaviour (`.agentRule`) takes the
/// place of the part, with Behaviour selected. People has an orange dot in the sidebar while a channel needs the owner:
/// the details read the accounts every 15 seconds, and at each reading of the channels.
struct AgentPage: View {
    @Bindable var store: FleetStore
    let team: TeamModel
    let agent: String
    /// `.agentDetail(name, tab)`, or `.agentRule(name, id)`.
    let destination: Destination
    /// Opens the chat, another section, or a rule of Behaviour.
    let open: (Destination) -> Void
    /// The accounts, for the Channels dot. They are the store's (`FleetStore.reading`), one reading of the whole fleet:
    /// the dot is there in the first frame when he comes back.
    private var channels: ChatAppsSnapshot? {
        get { store.reading("channels.snapshot") } nonmutating set { store.keep(newValue, as: "channels.snapshot") }
    }

    private var channelsOffered: Bool { store.state?.ui_features?.contains(ChatApps.feature) == true }
    /// The accounts, read before the agent's page first opens (`PagePrefetch`).
    static let prefetch = PagePrefetch("channels.snapshot", feature: ChatApps.feature) { try await ChatAppsClient().read(hub: $0, database: $1) }

    var body: some View {
        // Its sections keep their identity across a generation: an owner write gives the fleet a new one, and a
        // page rebuilt under a field that holds the keyboard took the app down (`SettingsPage`, 22 October 2026).
        let tab = destination.agentTab ?? .settings
        let attention = channelsOffered && channels?.db == store.state?.db && channels?.needsOwner(agent, serverTime: store.state?.time) == true
        HStack(spacing: 0) {
            PageSidebar(items: AgentTab.available(features: store.state?.ui_features ?? [],
                                                  role: store.state?.agents.first { $0.name == agent }?.role).map {
                .init(value: $0, title: $0.title, symbol: $0.symbol, attention: $0 == .people && attention ? "A channel needs you" : nil)
            }, selection: tab, identifier: "agent-tab", select: select) { head }
            Rule(vertical: true)
            Group {
                if case .agentRule(_, let id) = destination {
                    RuleEditor(store: store, team: team, agent: agent, id: id, open: open)
                        .id("\(store.hub)/\(agent)/\(id.map { "\($0.key)/\($0.occurrence)" } ?? "new")")
                } else {
                    // Each part is a `FleetPage` of its own and brings its title and its actions.
                    part(tab).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .id("\(store.hub)/\(agent)/\(tab.rawValue)")
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).pageNotices(store)
            // The title and the header's button stand where every page has them (`columnPull`).
            .environment(\.columnPull, (FleetStyle.pageSidebarWidth + 1) / 2)
        }
        .task(id: "\(store.hub)/\(store.state?.db ?? "")/\(agent)/\(store.state?.chat_apps?.problems ?? -1)") { await readChannels() }
    }

    /// The accounts every 15 seconds, and at once when the hub's count of accounts that need the owner changes.
    private func readChannels() async {
        while !Task.isCancelled {
            if channelsOffered, store.isFresh, let db = store.state?.db {
                let hub = store.hub
                if let fresh = try? await ChatAppsClient().read(hub: hub, database: db), store.hub == hub, store.state?.db == db {
                    channels = fresh
                }
            }
            do { try await store.nap(15) } catch { return }
        }
    }

    @ViewBuilder private func part(_ tab: AgentTab) -> some View {
        switch tab {
        // An agent in setup or signed out has its setup here too: its rows would only say what the setup does.
        case .settings, .chat:
            if store.setupShows(agent) {
                AgentSetupWizard(store: store, agent: agent)
            } else {
                AgentSetupView(store: store, agent: agent)
            }
        case .behaviour: BehaviourView(store: store, team: team, agent: agent, open: open)
        case .tasks: ActivityBoard(store: store, scope: agent)
        case .people: AgentPeoplePart(store: store, agent: agent) { channels = $0 }
        case .canUse: AgentCanUsePart(store: store, agent: agent)
        }
    }

    private func select(_ tab: AgentTab) { open(tab == .chat ? .agent(agent) : .agentDetail(agent, tab)) }

    /// Back to chat, then the agent: its glyph with its status, and its name.
    private var head: some View {
        let presence = store.state?.agents.first { $0.name == agent }?.presence(
            isFresh: store.isFresh, serverTime: store.state?.time ?? 0,
            openTasks: store.state?.tasks.filter { $0.owner == agent && !$0.isTerminal } ?? [], holds: store.state?.holds ?? []) ?? .unknown
        return ZStack(alignment: .topLeading) {
            Button { open(.agent(agent)) } label: {
                Label("Back to chat", systemImage: "chevron.left").font(FormMetrics.text).foregroundStyle(FleetStyle.muted)
                    .padding(.vertical, IconMetrics.reach).contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.vertical, -IconMetrics.reach).accessibilityIdentifier("agent-back-to-chat")
            // **The name on the page title's line, as Settings' heading** (margins rows 3 and 4): its glyph stands in
            // front of it, centred on its line, so the glyph's height moves no word. **The name begins where the rows'
            // words begin** (row 16: 3.5 pt after them), with the glyph at a row's size.
            Text(agent.agentLabel).font(FormMetrics.title).foregroundStyle(FleetStyle.text).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .padding(.leading, FleetStyle.pageSidebarMark + FleetStyle.pageSidebarGap)
                .overlay(alignment: .leading) {
                    AgentAvatar(name: agent, presence: presence, size: GlyphSize.row, surface: FleetStyle.canvas)
                }
                .help(presence.label)
                .padding(.top, FormMetrics.sidebarHeadingTop - FleetSpace.lights - FleetSpace.back)
        }
    }
}

/// **People, one part of an agent** (D-5): its channels, the people who can talk to it, and its conversations, each a
/// group of one page under its heading. The people are the fleet's rows with this agent's share, read-only: a person is
/// added in Settings › People, and a row opens the person's page, where "Can talk to" is the one editor. A group with
/// nothing in it is an empty card, as on Can use (the owner's yes of 3 November 2026). Its conversations are those with
/// people and those with the other agents (6 November 2026); the manager, which no person talks to, has the second kind.
///
/// The Discord page, a person, a conversation and a chat with another agent each take the part's place, with their own
/// way back, as a sub-page does; the part keeps which one is open, so the page it came from is there when he comes back.
struct AgentPeoplePart: View {
    @Bindable var store: FleetStore
    let agent: String
    /// Each reading of the accounts, for the People dot of the agent's sidebar.
    var onChannels: (ChatAppsSnapshot) -> Void = { _ in }
    @State private var discord: Bool?
    @State private var route: [PeoplePage.Route] = []
    @State private var conversation: Int?
    /// The other agent whose chat with this one is open.
    @State private var agentChat: String?

    private var features: [String] { store.state?.ui_features ?? [] }
    private var worker: Bool { ["worker", "lead"].contains(store.state?.agents.first { $0.name == agent }?.role ?? "") }

    var body: some View {
        if discord != nil {
            ChannelsPage(store: store, agent: agent, onRead: onChannels, grouped: true, discord: $discord)
        } else if !route.isEmpty {
            PeoplePage(store: store, agent: agent, grouped: true, route: $route)
        } else if let id = conversation {
            ConversationPage(store: store, id: id, backTitle: "People", back: { conversation = nil })
        } else if let other = agentChat {
            AgentConversationPage(store: store, agent: agent, other: other, back: { agentChat = nil })
        } else {
            FleetPage(AgentTab.people.heading) {
                if features.contains(ChatApps.feature) {
                    ChannelsPage(store: store, agent: agent, onRead: onChannels, grouped: true, discord: $discord)
                }
                if worker && features.contains(People.feature) {
                    PeoplePage(store: store, agent: agent, grouped: true, route: $route)
                }
                let people = worker && features.contains(People.conversationsFeature)
                if people || features.contains(AgentMessages.feature) {
                    ConversationsPage(store: store, scope: agent, grouped: true, people: people, open: $conversation,
                                      openAgent: $agentChat)
                }
            }
        }
    }
}

/// **Can use, one part of an agent** (D-5): the secrets, the knowledge and the apps — with their MCP servers — that it
/// has, each a group of one page: the fleet's own rows with this agent's share, and a row opens the same card as
/// Settings. **Managed from here too** (the owner, 3 November 2026: "we should be able to MANAGE the existing ones for
/// the Agent from its own screen too", and his yes to a + on each heading and a − on each row): the + gives this agent
/// one of the fleet's existing items of that kind, the − takes one back from this agent alone, with the write of the
/// item's own card. A group with nothing in it is an empty card ("it is weird to show the categories there like
/// empty... show like an empty card").
struct AgentCanUsePart: View {
    @Bindable var store: FleetStore
    let agent: String

    private var features: [String] { store.state?.ui_features ?? [] }

    var body: some View {
        FleetPage(AgentTab.canUse.heading) {
            if features.contains(ResourceList.feature) || features.contains(SecretEntryView.feature) {
                SecretsPage(store: store, agent: agent, grouped: true)
            }
            if features.contains(KnowledgeClient.feature) { KnowledgePage(store: store, agent: agent, grouped: true) }
            if features.contains(Google.feature) || features.contains(Integrations.feature) || features.contains(MCP.feature) {
                AppsSettings(store: store, agent: agent)
            }
        }
    }
}

/// **One menu for an agent** (the owner's yes of 28 October 2026 to D-5): the same items on the right-click of its row
/// in the sidebar and behind the "…" of its Runs on — Pin to top · Mark as unread · Rename… · Deactivate · Agent
/// details · Server, in three groups. Rename was four clicks deep, behind the details' "…", and the right-click had the
/// other four: two menus to remember. **Delete… ends it, in a group of its own** (the owner's yes of 7 November 2026 to
/// the mockup), then a confirmation over the window (`AgentDeleteCard`).
enum AgentMenu {
    enum Action: Hashable { case pin, markRead, markUnread, rename, deactivate, details, server, delete }

    /// The words of Delete…, which the app's menu draws in red on the right-click too (`FleetContextMenus.destructive`).
    static let deleteTitle = "Delete…"

    struct Item: Hashable {
        let action: Action
        let title: String
        let symbol: String
        /// The group it stands in: a line between two groups.
        let group: Int
        var enabled = true
    }

    /// The items for one agent, in the menu's order. Rename and Deactivate only where the hub takes them, and never for
    /// the manager, which keeps its name and its activity; Deactivate only for an active agent.
    ///
    /// **Only the items that can act** (T-05, fix round 2): Mark as unread for an agent with no reply, and Rename… and
    /// Deactivate while the hub cannot take a write, were grey in the right-click and did nothing in Runs on's "…".
    @MainActor static func items(_ agent: String, store: FleetStore) -> [Item] {
        all(agent, store: store).filter(\.enabled)
    }

    @MainActor private static func all(_ agent: String, store: FleetStore) -> [Item] {
        let features = store.state?.ui_features ?? []
        let state = store.state?.agents.first { $0.name == agent }
        let pinned = store.pinned.contains(agent)
        var items = [Item(action: .pin, title: pinned ? "Unpin" : "Pin to top", symbol: pinned ? "pin.slash" : "pin", group: 0)]
        if store.hasNewReply(from: agent) {
            items.append(Item(action: .markRead, title: "Mark as read", symbol: "envelope.open", group: 0))
        } else {
            items.append(Item(action: .markUnread, title: "Mark as unread", symbol: "envelope.badge", group: 0,
                              enabled: store.hasReply(from: agent)))
        }
        if features.contains(AgentRename.feature) && state?.role != "manager" {
            items.append(Item(action: .rename, title: "Rename…", symbol: "pencil", group: 1, enabled: store.canWrite))
        }
        if state?.active == true && state?.role != "manager" {
            items.append(Item(action: .deactivate, title: "Deactivate", symbol: "pause.circle", group: 1, enabled: store.canWrite))
        }
        items.append(Item(action: .details, title: "Agent details", symbol: AgentTab.settings.symbol, group: 2))
        if features.contains(Servers.feature) || features.contains("machines") {
            items.append(Item(action: .server, title: "Server", symbol: "server.rack", group: 2))
        }
        if AgentRemoval.offered(role: state?.role, features: features) {
            items.append(Item(action: .delete, title: deleteTitle, symbol: "trash", group: 3, enabled: store.canWrite))
        }
        return items
    }

    /// What an item does where the menu does not stand on its Runs on: Rename and Deactivate open it and act there,
    /// where the name's field and a refusal's words are.
    @MainActor static func perform(_ action: Action, agent: String, store: FleetStore) {
        switch action {
        case .pin: store.togglePin(agent)
        case .markRead: store.markRead(agent)
        case .markUnread: store.markUnread(agent)
        case .rename, .deactivate:
            store.agentAction = AgentActionRequest(agent: agent, action: action)
            store.destination = .agentDetail(agent, .settings)
        case .details: store.destination = .agentDetail(agent, .settings)
        case .server: store.destination = .server(agent)
        case .delete: store.deleting = AgentDeleteRequest(agent: agent)
        }
    }
}

/// Rename… or Deactivate, asked from the agent's row: its Runs on takes it when it opens (`AgentSetupView`).
struct AgentActionRequest: Equatable {
    let agent: String
    let action: AgentMenu.Action
}
