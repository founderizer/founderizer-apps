import AppKit
import FleetCore
import SwiftUI

struct FleetView: View {
    @Bindable var store: FleetStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @State private var addAgent = AddAgentModel()
    @State private var team = TeamModel()
    /// The chat's box has the keyboard: the guard of a pasted key watches it then (`KeyPasteGuard`).
    @FocusState private var composerFocused: Bool
    /// The composers whose key the owner chose to keep in the message: no second question while it is there.
    @State private var keyAllowed: Set<String> = []
    /// The agent whose chat just took the place of its setup: its box takes the keyboard as it shows (the owner, 26
    /// October 2026: "after activation, focus on the textbox so I can start typing").
    @State private var focusChat: String?
    /// The widths of the two side menus, which the owner sets by dragging their edges (`SideEdge`), kept on this Mac.
    @AppStorage("sidebarWidth") private var sidebarWidth = Double(FleetStyle.sidebarWidth)
    @AppStorage("panelWidth") private var panelWidth = Double(FleetStyle.panelWidth)
    /// The search card over the window, while it shows (`SearchPalette`).
    @State private var searching: SearchRequest?
    /// The agents whose rows the sidebar drew last: a row that comes into a list that had rows fades in (`sidebar`).
    @State private var listedAgents: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The zoom the window is drawn at (View › Bigger), for the band its buttons stand in.
    @Environment(\.viewZoom) private var zoom

    /// Before there is a hub, the window is the wizard and nothing else: no sidebar of pages that need a fleet, no
    /// banner about a hub the customer has not installed yet. One decision at a time means one thing on the screen.
    ///
    /// The wizard also keeps the window after the hub answers, while it holds it: its last screen — what this Mac
    /// proved — comes after the hub exists, and a window that went to the app the moment a hub answered would sweep
    /// it away as it became true.
    ///
    /// **A hub that answered this Mac before is never the wizard** (T-07): a launch draws the reading this Mac kept
    /// of it (`FleetStore`), and without one, after its first second, the window under the page's own title until
    /// the hub answers. "Set up your fleet" filled the window at every launch of a Mac with a fleet while that first
    /// read was on its way, and for good when it took more than a second.
    private var firstRun: Bool {
        ((store.state == nil && !store.hubAnsweredBefore) || store.firstRunHolds) && !isSettings
    }

    var body: some View {
        VStack(spacing: 0) {
            if !store.launched && store.state == nil {
                // The first read of this launch is on its way: the background only, so a fleet's window is never
                // the wizard for the length of that read.
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if firstRun {
                FirstRunView(store: store, window: true).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, FleetSpace.lights)
            } else {
            // **No bar.** Every pane below runs to the top edge of the window and the traffic lights float over
            // its own background; `FleetSpace.lights` is the room each one leaves for them. Every screen names
            // itself: a page by its own title, an agent's chat by the pill over the conversation, a task thread
            // by the head of the panel that carries the task's facts.
            HStack(spacing: 0) {
                sidebar.sideMenu(.leading, width: $sidebarWidth, range: FleetStyle.sidebarWidths)
                Rule(vertical: true)
                VStack(spacing: 0) {
                    // The band over the main view. **A page with a sidebar of its own draws it over its own column**, and
                    // its sidebar and the line beside it run to the window's top edge, as every other pane does (the
                    // margins of 30 October 2026, row 2, with the owner's crop: they began 36 pt down).
                    if !store.destination.ownsSidebar { Color.clear.frame(height: FleetSpace.lights) }
                    content.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let task = store.currentTask, store.state?.ui_features?.contains("task_controls") == true,
                       !task.isTerminal || store.state?.outcomes?.contains(where: { $0.task == task.id && $0.state == "unknown" }) == true {
                        // **Room under them where no guidance box stands under them** (the margins of 30 October 2026, row
                        // 7): a paused task's controls and an unconfirmed stop's stood on the window's bottom edge.
                        let boxUnder = !task.isTerminal && store.state?.ui_features?.contains("task_steering") == true
                            && TaskSteering.shows(task, in: store.state)
                        TaskControls(store: store, task: task)
                            .id("\(store.hub)/\(task.id)")
                            .chatColumn().padding(.top, 8).padding(.bottom, boxUnder ? 0 : FleetSpace.under)
                    }
                    if let task = store.currentTask, !task.isTerminal, store.state?.ui_features?.contains("task_steering") == true {
                        TaskSteering(store: store, task: task).id("\(store.hub)/\(task.id)/\(task.attempt)")
                    }
                    // **Only a request that is not on its way.** This panel is for one the hub did not confirm:
                    // it carries Retry, Discard and the request's own id, which are of no use while the request
                    // is in flight — and showing it then made it appear and vanish above the text box on every
                    // message, which is exactly what the owner reported. What a send looks like while it is
                    // happening is the composer's own business, where he is looking.
                    if pendingBarShows { pendingBar }
                    // A correction of a sent message takes the composer's place, in the chat of that message only: on
                    // another page it does not show, so it cannot look like a message to another agent.
                    if case .agent(let name) = store.destination, setupAgent == nil, startingAgent == nil {
                        if let editing = store.editingMessage, editing.chatRecipient == name { editMessagePanel(editing) }
                        else { composer() }
                    }
                }.frame(minWidth: FleetStyle.pageMinWidth, maxWidth: .infinity)
                // **The notice stands in the band over the main view and moves nothing** (`FleetNotices`): never over a
                // sidebar or the chat's panel (the owner, 21 October 2026: "warning should be aligned, so only do the
                // bar on the main view, not on the sidebars"; fix round 3c, where round 3 ran it over both). A page that
                // draws a sidebar of its own draws it itself, over its own column (`pageNotices`).
                .overlay(alignment: .top) { if !store.destination.ownsSidebar { FleetNotices(store: store) } }
                // The panel of an agent's chat, and the facts of a task in a task thread. Neither is hidden and
                // neither waits to be asked for: the two pages that have a panel show it, every other page has none.
                if let name = chatAgent, setupAgent == nil, startingAgent == nil, store.state != nil {
                    Rule(vertical: true)
                    AgentStatusPanel(store: store, agent: name) { openAgent(name, .settings) }
                        .id("\(store.hub)/\(name)")
                        .sideMenu(.trailing, width: $panelWidth, range: FleetStyle.panelWidths)
                } else if store.currentTask != nil {
                    Rule(vertical: true)
                    inspector.sideMenu(.trailing, width: $panelWidth, range: FleetStyle.panelWidths)
                }
            }
            }
        }
        .font(FleetStyle.body)
        .foregroundStyle(FleetStyle.text)
        .background(FleetStyle.canvas)
        .tint(FleetStyle.accent)
        // The window's three buttons on the band's middle line, at the zoom the window is drawn at (margins rows 1, 8).
        .windowButtonsCentred(inBand: FleetSpace.lights * zoom)
        // The glyphs of the agents come from the hub's list of agents, in its order.
        .environment(\.glyphTeam, store.state?.agents.map(\.name) ?? [])
        .environment(\.glyphPresence, glyphPresences)
        .ignoresSafeArea(.container, edges: .top)
        .onAppear { store.notifications.showWindow = { openWindow(id: "fleet") } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.refresh() } }
        }
        // A refused login text removes every draft, also the rule edits of the agent pages.
        .onChange(of: store.secretRefusals) { _, _ in team.clear() }
        // The profiles, read once for each hub generation before Behaviour or a rule first opens (`PagePrefetch`).
        .task(id: "\(store.hub)/\(store.state?.db ?? "")") { if store.state != nil { await team.read(store) } }
        .onChange(of: setupAgent ?? startingAgent) { before, after in
            if let before, after == nil, chatAgent == before { focusChat = before }
        }
        // Add secret over the window: a chat's key button, or the guard of a key that the owner pasted.
        .fleetModal(item: $store.secretForm) { preset in SecretFormCard(store: store, preset: preset) }
        // Delete… from an agent's menu, over the window as the search card is, with the glyphs the window gives.
        .fleetModal(item: $store.deleting) { request in
            AgentDeleteCard(store: store, agent: request.agent) { store.deleting = nil }
                .environment(\.glyphTeam, store.state?.agents.map(\.name) ?? [])
                .environment(\.glyphPresence, glyphPresences)
        }
        // The search card, from the sidebar's magnifier and ⌘K. It stands in a window of its own, so the glyphs get
        // the team and the presences the window gives every other glyph.
        .fleetModal(item: $searching) { _ in
            SearchPalette(store: store) { searching = nil }
                .environment(\.glyphTeam, store.state?.agents.map(\.name) ?? [])
                .environment(\.glyphPresence, glyphPresences)
        }
    }

    /// After an install: the agent's own page, which is its setup until it is active (`AgentSetupWizard`).
    private var configureAgent: ((String) -> Void)? {
        store.state?.ui_features?.contains("agent_setup") == true ? { name in
            openAgent(name, .chat)
            Task { await store.refresh() }
        } : nil
    }

    /// One agent at a section. Chat is the agent's own page: its conversation, with the composer under it and its
    /// status panel at the right. Every other section is in its details.
    private func openAgent(_ name: String, _ tab: AgentTab) {
        store.destination = tab == .chat ? .agent(name) : .agentDetail(name, tab)
    }

    /// The agent whose chat shows, or nil.
    private var chatAgent: String? { if case .agent(let name) = store.destination { name } else { nil } }

    /// Every agent's presence as its sidebar row reads it, for the glyphs that are given none (`AgentGlyph`).
    private var glyphPresences: [String: AgentPresence] {
        guard let state = store.state else { return [:] }
        var presences: [String: AgentPresence] = [:]
        for agent in state.agents {
            presences[agent.name] = agent.presence(isFresh: store.isFresh, serverTime: state.time,
                                                   openTasks: state.tasks.filter { $0.owner == agent.name && !$0.isTerminal },
                                                   holds: state.holds ?? [])
        }
        return presences
    }

    /// The agent whose setup shows in place of its chat (`AgentSetupWizard`): it is not active yet, it is signed out,
    /// or it gets its first server. Its page is the setup alone, with no composer and no panel, until the hub reports
    /// it active and signed in.
    private var setupAgent: String? {
        guard let name = chatAgent else { return nil }
        return store.setupShows(name) ? name : nil
    }

    /// The agent whose chat cannot answer yet, with "Setting up" in place of its chat (`ChatSettingUp`): no composer
    /// and no panel either, until the hub reports its session ready.
    private var startingAgent: String? {
        guard let name = chatAgent, setupAgent == nil, let state = store.state else { return nil }
        return AgentSetupFlow.chatStarts(state.agents.first { $0.name == name }, serverTime: state.time,
                                         fresh: store.isFresh) ? name : nil
    }

    /// Settings shows, also on a server's page and Add server, which are pages of its Servers.
    private var isSettings: Bool { store.destination.settingsTab != nil }

    /// Add agent: a new agent on a server. From the plus it opens on its first step, the servers; `server`, from a
    /// server's own page, opens it on the second for that server.
    private func openAddAgent(_ server: String? = nil) {
        addAgent.prepare(server: server, listed: store.state?.agents.map(\.name))
        store.destination = .addAgent
    }

    /// Add agent pressed for the owner, for a new Linux server, with the AI that he chose: its setup page opens next.
    /// False when the page with its button is the way on after all.
    private func addFirstAgent(server: String, runtime: String) async -> Bool {
        addAgent.prepare(server: server, listed: store.state?.agents.map(\.name))
        guard addAgent.receipt == nil else { return false }     // an install that failed stands on that page
        await addAgent.read(store: store)
        await addAgent.start(store: store, runtime: runtime)
        guard let agent = addAgent.receipt?.agent, let configureAgent,
              AgentSetupFlow.shows(store.state?.agents.first { $0.name == agent }, features: store.state?.ui_features ?? [])
        else { return false }
        store.addedAgent = agent
        configureAgent(agent)
        return true
    }

    /// Add agent, in the window: two steps, from the sidebar's plus. An install goes on while another page shows.
    private var addAgentPage: some View {
        AddAgentView(store: store, model: addAgent, configure: configureAgent) { store.destination = .addServer }
    }

    /// **The main sidebar, the owner's map of 28 October 2026** (D-4, "the whole map"): Needs you, only while something
    /// waits, Tasks and Agents at the top (the owner, 3 November 2026: "the usage section could be moved below tasks..
    /// and be renamed to Agents"); then the agents' chats, which are the app's one list of its agents, with no heading;
    /// at the bottom Settings, with Update over it only while an update waits. Back and Forward stand after the window's
    /// own buttons, Search and Add agent at its top right, all four level with them. Navigation rows of one style
    /// (`SidebarRow`), the chats as a chat app lists them (`ChatRow`); a mark only where something is not as usual. The
    /// servers, his devices and the updates are sections of Settings: they were rows here, settings he rarely opens.
    private var sidebar: some View {
        // The ones he pinned first, then the hub's own order.
        let listed = store.state?.agents ?? []
        let agents = ChatList.order(listed.map(\.name), pinned: store.pinned)
            .compactMap { name in listed.first { $0.name == name } }
        let names = Set(agents.map(\.name))
        return VStack(alignment: .leading, spacing: 2) {
            needsRow
            tasksRow
            agentsRow
            // The chats take the room that the window has, and scroll when it has too little.
            ScrollView {
                VStack(spacing: 2) { ForEach(agents) { agentRow($0) } }
                    // **A new agent's row fades in over 0.2 s, ease-out, and the rows under it move with it** (the polish
                    // of 30 October 2026, B-BRAND-22): it came in one frame. Only into a list that had rows: the rows of
                    // a launch's first reading, or of another hub, come at once; a pin moves no name in or out.
                    .animation(listedAgents.isEmpty || reduceMotion ? nil : .easeOut(duration: 0.2), value: names)
                    .onChange(of: names, initial: true) { _, now in listedAgents = now }
            }.scrollIndicators(.hidden)
                .background {
                    AgentKeys(names: agents.map(\.name)) { openAgent($0, .chat) } step: { stepAgent(agents.map(\.name), by: $0) }
                }
                .padding(.top, 10)
            // **From where the rows' marks begin to where their counts end** (the margins of 30 October 2026, row 30):
            // it began 4 pt before the one and ended 4 pt after the other.
            Rule().padding(.horizontal, 10).padding(.vertical, 8)
            // Only while a release of the fleet or a build of this Mac waits; it opens Settings › Updates, and leaves
            // when the update is taken.
            if store.updateWaits {
                SidebarRow("Update", symbol: "arrow.down.circle", selected: false) { store.destination = .settings(.updates) }
                    .accessibilityIdentifier("nav-update")
            }
            // Settings take the place of the connection popover. Its orange dot says what System status has to say, and
            // **while it shows, a press opens System status** (fix round 3c): it opened General, which says nothing of it.
            SidebarRow("Settings", selected: isSettings) {
                store.destination = .settings(settingsDot == nil ? .general : .status)
            } mark: {
                SidebarSymbol(name: "gearshape")
            } trailing: {
                if let dot = settingsDot {
                    Circle().fill(Color.orange).frame(width: 6, height: 6).help(dot).accessibilityHidden(true)
                }
            }.accessibilityIdentifier("hub-connection").accessibilityValue(store.connectionLabel)
        }
        // **Needs you comes and goes over 0.2 s, ease-out, and the rows under it move with it** (the second review of 30
        // October 2026: it came and went in one frame, and every row under it moved 34 pt), as a new agent's row does,
        // **under the same rule** (review B, round 3): the rows of a launch's first reading, or of another hub, come at
        // once, Needs you with them. With no kept reading, the agents' rows came at once and then slid down 34 pt while
        // Needs you faded in.
        .animation(listedAgents.isEmpty || reduceMotion ? nil : .easeOut(duration: 0.2),
                   value: (store.state?.needsYouCount ?? 0) > 0)
        .padding(.horizontal, 10).padding(.top, FleetSpace.underBand + FleetSpace.lights).padding(.bottom, FleetSpace.under)
            .overlay(alignment: .topLeading) { historyButtons }
            .overlay(alignment: .topTrailing) { sidebarButtons }
            .background(FleetStyle.rail)
    }

    /// **The Settings dot says what System status has to say** (fix round 3, item 18): the warnings of its last reading of
    /// the hub's health, and that the hub does not answer only while no notice says so. It stood beside the hub's own
    /// notice: two orange signs of one outage. **Until this launch reads the health, the reading kept with the fleet's**
    /// (`keptHealth`), so the dot draws in the launch's first frame (the polish of 30 October 2026), and not once a
    /// health read of this launch has failed (review B, round 4).
    private var settingsDot: String? {
        if !store.isFresh, store.connectionError == nil, !store.staleNoticeShows { return store.connectionLabel }
        let kept = store.keptHealth.reading(of: store.state?.db)
        guard let health = store.reading("servers.health") as FleetHealth? ?? kept, !health.warnings.isEmpty else { return nil }
        return FleetHealth.blocks(health.warnings).map(\.title).joined(separator: "\n")
    }

    /// **Search and the plus** at the sidebar's top right, level with the window's own buttons, in the band the traffic
    /// lights leave free. The magnifier and ⌘K open the search card (`SearchPalette`); **the plus offers Add agent and
    /// Add server** (the owner, 7 November 2026: "the + icon in the top bar should show Add Agent and Add Server to
    /// choose from").
    ///
    /// **No circle at rest, and room around them** (the owner, 3 November 2026, of the two 28-pt circles 4 pt under the
    /// window's top edge and 4 pt apart: "not enough margins!"): the four icons of the band are drawn as Codex draws its
    /// own, a muted symbol whose soft circle shows only under the pointer, 8 pt apart and 14 pt from the sidebar's edge.
    private var sidebarButtons: some View {
        HStack(spacing: 8) {
            bandButton("magnifyingglass", words: "Search") { searching = SearchRequest() }
                .keyboardShortcut("k", modifiers: .command)
                .accessibilityIdentifier("sidebar-search")
            if store.state != nil {
                // **The plus keeps the selected row's fill while Add agent shows** (T-32, fix round 2): Add agent was the
                // one page of the window with no row of the sidebar selected.
                let selected = store.destination == .addAgent
                FleetSelect("Add", options: [FleetOption(AddChoice.agent, "Add agent", mark: .symbol("person.badge.plus")),
                                             FleetOption(AddChoice.server, "Add server", mark: .symbol("server.rack"))],
                            onSelect: { choice in
                    switch choice {
                    case .agent: openAddAgent()
                    case .server: store.destination = .addServer
                    }
                }) {
                    Image(systemName: "plus").font(IconMetrics.symbol(14))
                        .foregroundStyle(selected ? FleetStyle.text : FleetStyle.muted)
                }
                .buttonStyle(FleetIconButtonStyle(side: Self.bandSide))
                .background(selected ? FleetStyle.bubble : .clear, in: Circle())
                .help("Add").accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("add-agent")
            }
        }
        .frame(height: FleetSpace.lights).padding(.trailing, 14)
    }

    /// **Back and Forward, after the window's own buttons** (the owner, 3 November 2026: "there should be 2 buttons to
    /// go back and forth between pages while navigating the app, like in codex"): the pages he opened, as a browser keeps
    /// them (`PageHistory`), with ⌘[ and ⌘]. One that has nowhere to go is dimmed, as Codex dims it. The traffic lights
    /// keep their place in the window's own points at every zoom, so the pair starts that far in, divided by the zoom.
    private var historyButtons: some View {
        HStack(spacing: 8) {
            bandButton("arrow.left", words: "Back", enabled: store.canGoBack) { store.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .accessibilityIdentifier("nav-back")
            bandButton("arrow.right", words: "Forward", enabled: store.canGoForward) { store.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .accessibilityIdentifier("nav-forward")
        }
        .frame(height: FleetSpace.lights).padding(.leading, Self.lightsEnd / zoom)
    }

    /// Where the window's three buttons end, and a gap, in the window's own points: the zoom button ends 62 pt in.
    private static let lightsEnd: CGFloat = 72

    /// One icon of the band: a muted symbol whose soft circle shows only under the pointer, and while `selected` the
    /// selected row's fill. A button with nowhere to go keeps its place, dimmed.
    private func bandButton(_ symbol: String, words: String, enabled: Bool = true, selected: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(IconMetrics.symbol(14))
                .foregroundStyle(selected ? FleetStyle.text : FleetStyle.muted.opacity(enabled ? 1 : 0.45))
        }
        .buttonStyle(FleetIconButtonStyle(side: Self.bandSide))
        .background(selected ? FleetStyle.bubble : .clear, in: Circle())
        .disabled(!enabled)
        .help(words).accessibilityLabel(words)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The side of a band icon's circle: 26 pt, so the band's 36 keeps 5 pt over and under it.
    private static let bandSide: CGFloat = 26

    /// What the plus adds.
    private enum AddChoice: Hashable { case agent, server }

    private func stepAgent(_ names: [String], by step: Int) {
        guard !names.isEmpty else { return }
        // From the agent whose row is selected: its chat, or a page of its details.
        let at = store.destination.agentName.flatMap { names.firstIndex(of: $0) }
        openAgent(names[at.map { min(max($0 + step, 0), names.count - 1) } ?? (step > 0 ? 0 : names.count - 1)], .chat)
    }

    /// **Needs you, only while something waits** (D-4): the manager's open requests and the tasks only the owner can
    /// move, with their number, read as an unread count is. It was a page that no row opened ("It is in Needs you.",
    /// the manager writes), and its count stood on the Activity row.
    ///
    /// **It stays while its page is open**, selected and with no count, after his last answer, and goes when he opens
    /// another page (fix round 2): the row went while the page stayed, and no row said where he was.
    @ViewBuilder private var needsRow: some View {
        let waiting = store.state?.needsYouCount ?? 0
        let words = waiting == 0 ? "Nothing needs you" : waiting == 1 ? "1 item needs you" : "\(waiting) items need you"
        if waiting > 0 || store.destination == .needs {
            SidebarRow("Needs you", selected: store.destination == .needs) { store.destination = .needs } mark: {
                SidebarSymbol(name: "exclamationmark.bubble")
            } trailing: {
                SidebarBadge(count: waiting, words: words)
            }
            .accessibilityIdentifier("nav-needs")
            .accessibilityValue(words)
        }
    }

    /// **Tasks**, the board that was Activity (the iPhone's word for it). It stays selected on the pages its board
    /// opens (T-32): Goals and a goal, and a task's thread, so every page has one row that says where he is.
    private var tasksRow: some View {
        let selected = switch store.destination { case .activity, .goals, .task: true; default: false }
        return SidebarRow("Tasks", symbol: "rectangle.split.3x1", selected: selected) { store.destination = .activity }
            .accessibilityIdentifier("nav-tasks")
    }

    /// **Agents, under Tasks** (the owner, 3 November 2026: "the usage section could be moved below tasks.. and be renamed
    /// to Agents"): every agent with its role, its server, its account and its usage on one page (`AgentsPage`).
    private var agentsRow: some View {
        SidebarRow("Agents", symbol: AgentsPage.symbol, selected: store.destination == .agents) { store.destination = .agents }
            .accessibilityIdentifier("nav-agents")
    }

    /// One agent's chat, as a chat app lists one: its glyph with its status dot on the glyph's corner, its name, under
    /// the name the newest thing it did — its last message, or what it is doing on an open task (`ChatList.preview`) —
    /// then at its right a provider setup that goes on and a new reply in its chat (and its name in semibold). A click
    /// opens its chat, also from its details; the right-click has the extras he chose (`agentMenu`).
    private func agentRow(_ agent: FleetAgent) -> some View {
        let providerSetup = store.providerSetup(hub: store.hub, database: store.state?.db, agent: agent.name)
        let presence = agent.presence(isFresh: store.isFresh, serverTime: store.state?.time ?? 0,
                                      openTasks: store.state?.tasks.filter { $0.owner == agent.name && !$0.isTerminal } ?? [],
                                      holds: store.state?.holds ?? [])
        let reply = store.hasNewReply(from: agent.name)
        let selected = store.destination.agentName == agent.name
        // An old reading keeps the agent's look (fix round 2, item 2): VoiceOver hears that it is the last reading.
        let marks = [SetupMark.words(providerSetup, subject: "The provider setup"), reply ? "New reply" : nil,
                     presence.label, store.isFresh ? nil : "Last reading"].compactMap { $0 }
        let preview = ChatList.preview(agent.name, last: store.chatTimeline.entries(for: agent.name, limit: 1).last,
                                       tasks: store.state?.tasks ?? [])
        return ChatRow(agent.name.agentLabel, preview: preview, selected: selected, emphasized: reply) {
            openAgent(agent.name, .chat)
        } mark: {
            // **Its status dot stands on its glyph's lower right corner, as everywhere else** (the owner's yes of 28
            // October 2026, D-8): green while it works, none while it is simply online. The ring under the dot is the
            // row's own colour, so it parts the dot from the glyph on the selected row too.
            AgentAvatar(name: agent.name, presence: presence, size: ChatRow<EmptyView, EmptyView>.glyph,
                        surface: selected ? FleetStyle.bubble : FleetStyle.rail, moves: true)
        } trailing: {
            // The row stays one button for assistive apps: the marks' words are its value.
            // **A new reply is the violet 6-point dot at the row's end, with its name in semibold**: the unread dot, the
            // one dot of the row that is no state of the agent, and of the one size of every dot (the owner, 27 October
            // 2026, of a larger blue reply dot over the violet ones: "why are they different?!?! they should all be
            // like the smaller ones").
            HStack(spacing: 6) {
                SetupMark(setup: providerSetup, subject: "The provider setup", place: "Open Agent details, then Change… under AI provider.")
                if reply { Circle().fill(FleetStyle.accent).frame(width: 6, height: 6).help("New reply in its chat") }
            }.accessibilityHidden(true)
        }
        .contextMenu { agentMenu(agent, reply: reply) }
        .accessibilityIdentifier("agent-row-\(agent.name)")
        .accessibilityValue(marks.joined(separator: ", "))
    }

    /// The right-click of an agent's row: **the agent's one menu** (`AgentMenu`, the owner's yes of 28 October 2026 to
    /// D-5), the same items as the "…" of its Runs on — Pin to top, Mark as unread, Rename…, Deactivate, Agent details
    /// and Server — in three groups. Rename is two clicks: this menu, and the name's field on its Runs on.
    @ViewBuilder private func agentMenu(_ agent: FleetAgent, reply: Bool) -> some View {
        let items = AgentMenu.items(agent.name, store: store)
        Group {
            ForEach(Array(items.enumerated()), id: \.element) { index, item in
                if index > 0, items[index - 1].group != item.group { Divider() }
                Button(item.title, systemImage: item.symbol, role: item.action == .delete ? .destructive : nil) {
                    AgentMenu.perform(item.action, agent: agent.name, store: store)
                }
            }
        }.labelStyle(.titleAndIcon)
    }

    /// **The generation is a version, not an identity.** Every write of the owner's that touches the configuration
    /// — a secret, a grant, a profile — commits it and gives the fleet a new one, so a page keyed by it was built
    /// again at the moment of his own save: he saw the screen blink, come back and blink again, and the third one
    /// took the app down, because a field still held the keyboard and SwiftUI's responder chain reached the view
    /// that had just gone (`swift_abortRetainUnowned`, 22 October 2026). Every `task(id:)` below still carries the
    /// generation, so the readings follow it; the views do not.
    @ViewBuilder private var content: some View {
        if let tab = store.destination.settingsTab {
            // Also without a hub state, so that the hub address can change.
            SettingsPage(store: store, tab: tab, detail: settingsDetail) { store.destination = .settings($0) }
        } else if store.state == nil {
            // The window itself is the wizard before there is a hub; this is only the moment after Settings opened
            // without one. A hub that answered before waits under the page's own title (`firstRun`).
            if store.hubAnsweredBefore { waitingPage } else { FirstRunView(store: store) }
        } else {
            switch store.destination {
            case .needs: needsView
            case .activity: ActivityBoard(store: store)
            case .goals: goalsView
            case .agents: AgentsPage(store: store) { openAgent($0, .chat) }
            case .addAgent: addAgentPage
            case .settings, .server, .addServer, .app: EmptyView()
            case .task: if let task = store.currentTask {
                TaskView(store: store, task: task, state: store.state!, hub: store.hub, isFresh: store.isFresh)
                    .id("\(store.hub)/\(task.id)")
            } else {
                // The strip the window used to draw said "Task · No current task" here. With no strip and no panel
                // — both need the task — the window would be blank, so the one line it carried stays.
                EmptyState(symbol: "folder", title: "Task not found",
                           detail: "This hub does not list that task. Tasks has the tasks it has.", centered: true)
            }
            // Signing a machine's runtime in: its own wizard, as adding a machine has one.
            case .signIn(let name): SignInWizard(store: store, agent: name).id("\(store.hub)/\(name)")
            // The chat directly: the composer is under it and the agent's status panel at its right.
            // Not the generation: his own message is in that composer, and an owner write must not take the view
            // it is typed into (`SettingsPage`).
            case .agent(let name):
                // The setup, "Setting up" and the chat cross-fade in 200 ms as one takes the other's place; a switch
                // to another agent still happens in one frame.
                Group {
                    if setupAgent == name {
                        AgentSetupWizard(store: store, agent: name).id("\(store.hub)/\(name)/setup")
                    } else if startingAgent == name {
                        ChatSettingUp(agent: name).id("\(store.hub)/\(name)/starting")
                    } else {
                        ManagerView(store: store, agent: name).id("\(store.hub)/\(name)")
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: setupAgent == name || startingAgent == name)
                .id("\(store.hub)/\(name)/page")
            // One case for every section and a rule's editor, so that the sidebar of the details stays.
            case .agentDetail(let name, _), .agentRule(let name, _):
                AgentPage(store: store, team: team, agent: name, destination: store.destination) { store.destination = $0 }
            }
        }
    }

    /// The page of Settings › Servers that takes the section's place: a server's page, or Add server. Settings keeps
    /// its sidebar beside them, with Servers selected, as a person's page keeps People's.
    private var settingsDetail: AnyView? {
        switch store.destination {
        case .server(let name):
            AnyView(ServerPage(store: store, name: name, addAgent: { openAddAgent($0) }) { server, job in
                openAddAgent(server.name)
                Task { await addAgent.retry(store: store, server: server, job: job) }
            }.id("\(store.hub)/\(name)"))
        case .addServer: AnyView(AddServerView(store: store, addAgent: { openAddAgent($0) }, addFirstAgent: addFirstAgent))
        case .app(let group): AnyView(AppsSettings(store: store, only: group).id("\(store.hub)/app/\(group.rawValue)"))
        default: nil
        }
    }

    /// The page he opens, under its own title and with nothing in it, while a hub that answered before has not
    /// answered this launch and this Mac kept no reading of it. What it holds comes with the hub's answer; a hub
    /// that does not answer says so over it (`FleetNotices`).
    @ViewBuilder private var waitingPage: some View {
        let title: String? = switch store.destination {
        case .activity: "Tasks"
        case .needs: "Needs you"
        case .goals: "Goals"
        case .agents: "Agents"
        default: nil
        }
        if let title { FleetPage(title) { EmptyView() } } else { Color.clear }
    }

    /// The edit of one sent message, in the composer's place of its own chat. It stays open while another page
    /// shows, with its text and its pending receipt, and shows again in this chat. While nothing has read the
    /// message it changes it where it stands; after that it sends a correction under it (`edit_in_place`).
    ///
    /// **It is the chat's own composer with one line over it** (the owner's yes of 28 October 2026, D-6, the phone's
    /// look): "Correcting your last message" with Cancel at its right, the message's words in the capsule and the round
    /// Send, while the message itself stays whole where it stands in the conversation above. It was a 190-point panel
    /// with a title, a box of its own, a sentence and a "Send correction" capsule. What Send will do — change the
    /// message where it stands, or go under it as a correction — is its hover, as it is the Correct arrow's. A
    /// correction carries no file, so the plus is not on its line (as on the phone).
    private func editMessagePanel(_ message: OwnerMessage) -> some View {
        // The phone's words (T-33). The phone corrects only his newest message; this Mac corrects any it sent, so an
        // older one is "your message".
        let newest = store.state?.messages.filter { $0.kind == "message" && $0.chatRecipient == message.chatRecipient }
            .max { $0.created < $1.created }
        let inPlace = store.editsInPlace(message)
        let canSend = store.canWrite && !store.editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && store.editText.count <= 16_000
        // A correction on its way takes Send away, as a message does; one the hub did not confirm is the request
        // line's, with its words and Try again (`pendingBar`).
        let agent = message.chatRecipient.agentLabel
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "pencil").accessibilityHidden(true)
                Text(newest?.request_id == message.request_id ? "Correcting your last message" : "Correcting your message")
                Spacer(minLength: 8)
                Button { store.cancelEdit() } label: {
                    Text("Cancel").foregroundStyle(FleetStyle.text)
                        .padding(.vertical, IconMetrics.reach).contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.vertical, -IconMetrics.reach)
                    .keyboardShortcut(.cancelAction).disabled(store.sending)
                    .accessibilityIdentifier("edit-message-cancel")
            }
            .font(ChatStyle.detail).foregroundStyle(FleetStyle.muted)
            .padding(.horizontal, ComposerCapsule<EmptyView, EmptyView>.inset)
            ComposerCapsule(focus: $composerFocused) {
                TextField("Correct your message", text: $store.editText, axis: .vertical)
                    .disabled(store.sending || store.pending != nil)
                    .focused($composerFocused)
                    .onAppear { composerFocused = true }
                    .accessibilityIdentifier("edit-message-text")
                    // The chat's keys: Return sends, Shift+Return makes a new line, Esc is Cancel.
                    .onKeyPress(keys: [.return], phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        if canSend { Task { await store.sendEdit() } }
                        return .handled
                    }
                    .composerField(alone: true)
                SendSlot(shows: canSend) {
                    Button { Task { await store.sendEdit() } } label: { SendMark(agent: message.chatRecipient) }
                        .buttonStyle(FleetIconButtonStyle(filled: true)).keyboardShortcut(.return, modifiers: .command)
                        .disabled(!canSend)
                        .help(inPlace ? "Change this message. \(agent) has not read it yet, so nothing is added under it."
                                      : "Send a correction under this message. The first one stays in the history.")
                        .accessibilityLabel(inPlace ? "Change message" : "Send correction")
                        .accessibilityIdentifier("send-correction")
                }
            }
        }
        .chatColumn().padding(.top, 10).padding(.bottom, FleetSpace.under)
    }

    /// **Needs you**: the manager's open requests, then the tasks that only the owner can move, then the requests he
    /// answered (`NeedsList`, which keeps a request he answers where it folded). The sidebar's row counts the first two,
    /// so the page shows what its row says (D-4).
    private var needsView: some View {
        let ownerTasks = store.state?.ownerTasks ?? []
        return FleetPage("Needs you") {
            NeedsList(store: store, hasTasks: !ownerTasks.isEmpty) {
                FormSection { ForEach(ownerTasks) { ownerTaskRow($0) } }
            }
        }
    }

    /// A task that only the owner can move, on the Needs you page: its mark, its title, its agent and what it waits
    /// for, and its number, as the Tasks board's Needs you column says it. The whole row opens the task.
    private func ownerTaskRow(_ task: FleetTask) -> some View {
        let unknown = store.state?.outcomes?.contains { $0.task == task.id && $0.state == "unknown" } == true
        let mark = unknown ? (symbol: "questionmark.circle", words: "Outcome not known: check it")
            : { let held = task.mark(in: store.state); return (symbol: held.symbol, words: held.words) }()
        return Button { store.destination = .task(task.id) } label: {
            HStack(spacing: 12) {
                // **Its title where the title of every row with a mark begins** (the margins of 30 October 2026, row 24:
                // 3 pt past it): the mark in the one mark column of the app (`RowMark`).
                HStack(spacing: 0) {
                    RowMark { Image(systemName: mark.symbol).font(IconMetrics.symbol(15)).foregroundStyle(.orange) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.title).font(FormMetrics.title).foregroundStyle(FleetStyle.text).lineLimit(1)
                        // **The agent's 16-pt glyph, with its dot, before its name** (D-8 items 2 and 4), as the same
                        // task's card on the Tasks board and the requests above it have it.
                        HStack(spacing: 6) {
                            AgentGlyph(name: task.owner, size: GlyphSize.inline)
                            Text("\(task.owner.agentLabel) · \(mark.words)").font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                                .lineLimit(1)
                        }
                    }
                }.padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, FormMetrics.rowInset).frame(minHeight: FormMetrics.twoLineRow)
        }
        .buttonStyle(FleetRowButtonStyle()).help(task.title)
        .accessibilityIdentifier("needs-task-\(task.id)")
        .opensTask(task.id, store: store)
    }

    /// Goals has no sidebar item: the Goals button of Tasks and a task's Goal controls open it. A hub without goals
    /// shows the task board in its place.
    @ViewBuilder private var goalsView: some View {
        if store.state?.ui_features?.contains("goals") == true { GoalsView(store: store) { taskButton($0) } }
        else { ActivityBoard(store: store) }
    }

    /// The task's one state word, the same rule as its panel's and its guidance box's (`FleetTask.stateWord`).
    private func taskStatus(_ task: FleetTask) -> String { task.stateWord(in: store.state) }

    private func taskButton(_ task: FleetTask) -> some View {
        let failed = ["failed", "rejected"].contains(task.state)
        return Button { store.destination = .task(task.id) } label: {
            HStack(spacing: 12) {
                // Its title where the title of every row with a mark begins (margins row 24: 1 pt short of it).
                HStack(spacing: 0) {
                    RowMark {
                        Image(systemName: failed ? "exclamationmark.circle" : task.accepted == 1 ? "checkmark.circle" : task.isTerminal ? "circle" : "circle.dotted")
                            .font(IconMetrics.symbol(14)).foregroundStyle(failed ? .orange : task.accepted == 1 ? FleetStyle.muted : !task.isTerminal && task.nudge_level > 0 ? .orange : FleetStyle.text)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.title).lineLimit(1).truncationMode(.tail)
                        Text("\(task.owner.agentLabel) · \(taskStatus(task))").font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(IconMetrics.symbol(9)).foregroundStyle(FleetStyle.muted)
            // A form's two-line row (T-27): Goals' Other work stood at a pitch of 56 under goal rows of 57.
            }.frame(minHeight: FormMetrics.twoLineRow).contentShape(Rectangle())
        }.buttonStyle(.plain).help(task.title).accessibilityIdentifier("task-\(task.id)")
            .opensTask(task.id, store: store)
    }

    /// The panel of a task thread: the task's own name at its head, then the facts of that task, which the thread
    /// itself does not say. It shows on a task and nowhere else; the summary it once held on the other pages is the
    /// Dashboard, and the connection and the hub generation it held at its foot are in Settings.
    ///
    /// **The head is what names the thread.** A task thread is the one screen no page title names (the sidebar's
    /// Activity row is selected under it, its list), and it was the last thing in the app to keep a strip at the top
    /// of the window for that one reason.
    /// The name belongs here and not over the conversation: the first thing in the thread is the owner's own request
    /// in his bubble, and the title is a short form of that request, so a capsule over it would add chrome to the
    /// reading column to say in fewer words what the row beneath it already says. It stands **above** the panel's
    /// scroll, because a name that scrolls out of reach is no name, and the panel is always there on a task.
    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let task = store.currentTask {
                taskName(task)
                Rule()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    if let task = store.currentTask {
                        if let database = store.state?.db, store.state?.ui_features?.contains("machines") == true {
                            TaskMachineAccess(store: store, agent: task.owner)
                                .id("\(store.hub)/\(database)/\(task.owner)")
                        }
                        // **The facts come with the thread, in one frame** (`TaskView.shows`): on a first open they
                        // wait for the thread's reads, so "Runtime used" and the models are never inserted above the
                        // rows that showed first.
                        if TaskView.shows(task, store: store) { taskFacts(task) }
                    }
                }.padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 16)
            }
        }.background(FleetStyle.rail)
    }

    /// The rows of the task panel: the facts of the task that its thread does not say.
    @ViewBuilder private func taskFacts(_ task: FleetTask) -> some View {
        // A task with no goal drew a "Goal" label over nothing, directly under the task's name.
        if !task.goal.isEmpty { DetailField(title: "Goal", value: task.goal) }
        if let project = task.project { DetailField(title: "Project", value: project) }
        // **His words, not the hub's** (T-12): the agents by their names as the sidebar writes them, the state as the
        // thread and Goals say it, and the provider by the word his Settings use. "Owner: atlas" put the agent under the
        // word that means him, and "State: input-required" the hub's own token beside the thread's "Waiting for an answer".
        // The agent's 16-point glyph before its name (D-8); the owner, who asked many a task, keeps his words alone.
        DetailField(title: "Asked by", value: task.requester.agentLabel, agent: task.requester)
        if let why = task.why, !why.isEmpty { DetailField(title: "Why this agent", value: why) }
        if let trigger = task.trigger_id {
            DetailField(title: "Schedule", value: "\(trigger)\(task.trigger_run.map { " · run \($0)" } ?? "")")
        }
        DetailField(title: "Agent", value: task.owner.agentLabel, agent: task.owner)
        DetailField(title: "State", value: taskStatus(task))
        // **A row only when it says something** (D-2): "Attempt 1 · 0 restarts", "Model used · Not reported" and
        // "Result check · No result yet" stood on every task.
        if task.attempt > 1 || task.restarts > 0 {
            DetailField(title: "Attempt", value: [task.attempt > 1 ? "Attempt \(task.attempt)" : nil,
                                                  task.restarts > 0 ? "Restarted \(task.restarts) time\(task.restarts == 1 ? "" : "s")" : nil]
                .compactMap { $0 }.joined(separator: " · "))
        }
        if let runtimes = store.taskRuntimes[task.attempt], !runtimes.isEmpty {
            DetailField(title: "AI provider", value: runtimes.sorted().map {
                switch $0 { case "claude": "Claude Code"; case "codex": "Codex"; case "grok": "Grok Build"; default: $0 }
            }.joined(separator: ", "))
        }
        let models = store.taskModels.filter { $0.attempt == task.attempt }
        if !models.isEmpty {
            ForEach(models) { model in
                VStack(alignment: .leading, spacing: 6) {
                    DetailField(title: "Model requested", value: model.requestedModel ?? automaticChoice)
                    DetailField(title: "Model used", value: model.model ?? "Not reported")
                    DetailField(title: "Reasoning requested", value: model.requestedEffort.map(reasoningName) ?? automaticChoice)
                    DetailField(title: "Reasoning used", value: model.effort.map(reasoningName) ?? "Not reported")
                    if model.differs { Label("The AI provider used other settings", systemImage: "exclamationmark.circle").font(FormMetrics.detail).foregroundStyle(.orange) }
                }
            }
        }
        DetailField(title: "Last activity", value: fleetDate(task.last_activity))
        DetailField(title: "Done when", value: task.done_when)
        if task.delivered != nil || task.accepted != nil { DetailField(title: "Result check", value: task.checkStatus) }
        if let follows = task.follows { DetailField(title: "Follow-up to", value: store.state?.tasks.first { $0.id == follows }?.title ?? "An earlier task") }
        if let parent = task.parent {
            // The click reaches over and under the words (`IconMetrics.reach`), and the panel does not move for it.
            Button { store.destination = .task(parent) } label: {
                Text(store.state?.tasks.first { $0.id == parent }.map { "Parent task · \($0.title)" } ?? "Parent task").padding(.vertical, IconMetrics.reach).contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.vertical, -IconMetrics.reach).font(FormMetrics.detail).foregroundStyle(FleetStyle.link)
                .opensTask(parent, store: store)
        }
        let subtasks = (store.state?.tasks ?? []).filter { $0.parent == task.id }
        if !subtasks.isEmpty {
            Text("Subtasks").font(FormMetrics.detailTitle)
            ForEach(subtasks) { child in
                Button { store.destination = .task(child.id) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(child.title).lineLimit(2)
                        Text(taskStatus(child)).foregroundStyle(FleetStyle.muted)
                    }.font(FormMetrics.detail)
                }.buttonStyle(.plain).opensTask(child.id, store: store)
            }
        }
        if !store.taskChildren.isEmpty {
            Rule()
            Text("Child agents").font(FormMetrics.detailTitle)
            ForEach(store.taskChildren.prefix(20)) { child in
                Button { store.childThreadRequest = child.id } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: child.status == "completed" ? "checkmark.circle" : child.status == "failed" ? "exclamationmark.circle" : "circle.dotted")
                            .foregroundStyle(child.status == "failed" ? .orange : FleetStyle.muted)
                        Text(child.name).lineLimit(2)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right").font(IconMetrics.symbol(9))
                    }.font(FormMetrics.detail).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Open child thread · Attempt \(child.id.attempt)")
            }
            if store.taskChildren.count > 20 { Text("More agents in the task thread").font(FormMetrics.detail).foregroundStyle(FleetStyle.muted) }
        }
        if !store.taskFiles.isEmpty {
            Rule()
            Text("Changed files").font(FormMetrics.detailTitle)
            ForEach(store.taskFiles) { change in
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: change.path).font(FormMetrics.detail).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text(change.action.capitalized)
                        if let added = change.added { Text("+\(added)").foregroundStyle(.green) }
                        if let removed = change.removed { Text("−\(removed)").foregroundStyle(.orange) }
                    }.font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                }
            }
            Text("Latest completed tool report per file.").font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
        }
    }

    /// The name of the task this thread is: its title, and no hub number under it (3 November 2026: "I dont want these
    /// codes, I just want human chats").
    private func taskName(_ task: FleetTask) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(task.title).font(FormMetrics.title).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.top, FleetSpace.underBand + FleetSpace.lights).padding(.bottom, 14)
        .accessibilityIdentifier("task-name")
    }

    /// The chat composer: the owner's message to the agent of this page. The answer of a Needs-you
    /// request has its own composer, `NeedAnswerBox`, on the request itself.
    ///
    /// **One capsule of one line at rest** (the owner's yes of 28 October 2026, D-6): 40 points, the plus at its left
    /// and Send at its right on the line he writes in, and it grows upward with his text to ten lines
    /// (`ComposerCapsule`). It was 120 points at rest — three lines of field, and the plus and Send on a row of their
    /// own — so 80 points of every chat come back to the conversation.
    private func composer() -> some View {
        // **Empty in the frame he sends**, with his bubble (fix round 3, item 11): while the draft is his message on its
        // way the field shows nothing, and what he writes meanwhile is his next draft.
        let text: Binding<String> = Binding(get: { store.composerText(for: store.chatAgent) }, set: { store.setDraft($0, for: store.chatAgent) })
        let trimmed = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let routeAvailable = store.canChat(with: store.chatAgent)
        // Owner feature attachments: the files that the owner picked for this composer.
        let composer = FleetStore.stageKey(agent: store.chatAgent)
        let files = store.readyFiles(for: composer)
        let filesWaiting = store.filesAreWaiting(for: composer)
        let canSend = store.canWrite && routeAvailable && !filesWaiting && trimmed.count <= 16_000
            && (!trimmed.isEmpty || !files.isEmpty)
        return ComposerCapsule(focus: $composerFocused) {
            // What the line needs said stands over it, inside the capsule, which grows upward for it: the files
            // that wait, why this chat takes no message, the guard of a pasted key, and what is wrong with the text.
            StagedFilesStrip(store: store, composer: composer)
            if !routeAvailable {
                Text(store.state?.agents.first(where: { $0.name == store.chatAgent })?.active == false ? "This agent is in setup. Activate it in Runs on before sending work." :
                     store.supportsDirectChat ? "Direct chat is unavailable for this agent. Send a task to Manager." : "This hub needs an update before direct chat is available.")
                    .font(ChatStyle.detail).foregroundStyle(FleetStyle.muted)
            }
            if let held = store.heldKey, held.composer == composer {
                KeyHoldBanner(hold: held.hold, agent: store.chatAgent) { saveHeldKey(held, text: text) } goOn: { keepHeldKey(held, text: text) }
            }
            // The number in this Mac's own format, as the phone writes it (T-33, fix round 2).
            if trimmed.count > 16_000 { Text("Use no more than \(16_000.formatted()) characters.").font(ChatStyle.detail).foregroundStyle(.orange) }
            if let words = store.fileError(for: composer) {
                Text(words).font(ChatStyle.detail).foregroundStyle(.orange).help(store.fileCause(for: composer) ?? "")
            }
        } line: {
            // No key button here (the owner, 24 October 2026): a key goes into the vault from Settings › Secrets,
            // from a request card, or from the paste guard above when one is typed into this box.
            if store.supportsAttachments { AttachFilesButton(store: store, composer: composer) }
            // The placeholder names the agent it writes to, as the pill over the conversation does (D-6, his yes of
            // 28 October 2026 to keeping "Message Atlas").
            TextField("Message \(store.chatAgent.agentLabel)", text: text, axis: .vertical)
                .disabled(!routeAvailable)
                .focused($composerFocused)
                .task(id: focusChat) {
                    guard let name = focusChat, name == store.chatAgent else { return }
                    focusChat = nil
                    composerFocused = true
                }
                .accessibilityIdentifier("manager-message")
                // Return sends, as in every chat; Shift+Return makes a new line. Command+Return still sends.
                .onKeyPress(keys: [.return], phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    guard canSend else { return .handled }
                    sendChat(text.wrappedValue, composer: composer)
                    return .handled
                }
                .composerField(alone: !store.supportsAttachments)
                .onChange(of: text.wrappedValue) { _, now in heldKeyCheck(now, composer: composer) }
            // No "Connection required" here (D-2, 28 October 2026): the notice over the page is the one sign of an
            // outage, and Send shows only while it can send.
            SendSlot(shows: canSend) {
                Button { sendChat(text.wrappedValue, composer: composer) } label: {
                    // A message on its way takes Send away with the words he sent: "Thinking" under his message says
                    // that it went, and Send comes back with the next words.
                    SendMark(agent: store.chatAgent)
                }.buttonStyle(FleetIconButtonStyle(filled: true)).keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSend)
                    .help("Send this message to \(store.chatAgent.agentLabel)")
                    .accessibilityLabel("Send message")
                    .accessibilityIdentifier("send-goal")
            }
        }
            // The clipboard reaches the composer that has the cursor: the chat can show a request's answer box too
            // (D-7), which takes a pasted picture while the owner writes in it, as on Needs you.
            .pasteAttachments(store: store, composer: composerFocused ? composer : nil)
            .keyPasteGuard(store: store, composer: composerFocused && SecretEntryView.isOffered(by: store) ? composer : nil)
            // A file dropped on the composer is picked, as one chosen with the plus.
            .stageDroppedFiles(store: store, composer: composer)
            .chatColumn().padding(.top, 10).padding(.bottom, FleetSpace.under)
    }

    // MARK: the guard of a key in the chat's text

    /// Sends the chat's message, unless it holds what looks like a key that the owner did not choose to keep.
    private func sendChat(_ text: String, composer: String) {
        if SecretEntryView.isOffered(by: store) && !keyAllowed.contains(composer) && KeyInText.contains(text) {
            store.heldKey = HeldKey(composer: composer, hold: .text)
            return
        }
        Task { await store.send() }
    }

    /// A text that holds a key, however it came in, gets the question once; a text without one ends it.
    private func heldKeyCheck(_ text: String, composer: String) {
        guard SecretEntryView.isOffered(by: store) else { return }
        if !KeyInText.contains(text) {
            keyAllowed.remove(composer)
            if store.heldKey == HeldKey(composer: composer, hold: .text) { store.heldKey = nil }
        } else if !keyAllowed.contains(composer) && store.heldKey == nil {
            store.heldKey = HeldKey(composer: composer, hold: .text)
        }
    }

    /// "Save it as a secret": the key goes into the secure form and out of the message. A paste reads the clipboard
    /// again now; a text gives up the part that looks like a key.
    private func saveHeldKey(_ held: HeldKey, text: Binding<String>) {
        store.heldKey = nil
        var key: String?
        if held.hold == .paste { key = KeyCut.onClipboard() }
        else if let cut = KeyCut.split(text.wrappedValue) { text.wrappedValue = cut.rest; key = cut.key }
        store.secretForm = SecretPreset(tell: store.chatAgent, key: key)
    }

    /// "Paste it anyway" or "Keep it": the owner's choice, and no second question while the key is in the message.
    private func keepHeldKey(_ held: HeldKey, text: Binding<String>) {
        store.heldKey = nil
        keyAllowed.insert(held.composer)
        if held.hold == .paste, let pasted = NSPasteboard.general.string(forType: .string) {
            text.wrappedValue += pasted
        }
    }

    /// **A write the hub did not confirm, in the phone's words** (review B7): "Not sent", and why — the hub's own words
    /// after it, "Not sent: Atlas is in setup.", or "Your hub did not confirm it. Sending it again does not send it
    /// twice." — with no request number (D-2 cut it on the phone). It said "Receipt not confirmed" or "Request refused"
    /// over a longer sentence of the Mac's own, and the request's id under its buttons.
    @ViewBuilder private var pendingBar: some View {
        if let pending = store.pending {
            VStack(alignment: .leading, spacing: 8) {
                Text(pending.refusal.map(Self.notSent) ?? "Not sent")
                    .font(FormMetrics.detailTitle).foregroundStyle(.orange).textSelection(.enabled)
                if pending.refusal == nil {
                    Text("Your hub did not confirm it. Sending it again does not send it twice.").font(FormMetrics.detail)
                }
                if pending.hub != store.hub || pending.database != store.state?.db {
                    Text("It belongs to another hub, so it is not sent again.")
                        .font(FormMetrics.detail).foregroundStyle(.orange)
                }
                Text(pending.name(hub: store.hub, state: store.state, schedules: (store.reading("triggers.list") as TriggerList?)?.triggers ?? []))
                    .font(FormMetrics.detail).lineLimit(3).textSelection(.enabled)
                if !pending.attachments.isEmpty {
                    StagedFilesStrip(store: store, composer: pending.needID.map { FleetStore.stageKey(need: $0) }
                        ?? FleetStore.stageKey(agent: pending.recipient ?? "manager"), sending: pending.attachments)
                }
                // **Each button only while it can act** (fix round 2, item 51), never grey: Refresh always can — a press
                // during a read loses nothing, the store reads once more after it (`refresh`) — and the bar stands only
                // while nothing is on its way, so Discard always can too; Try again needs a hub that answers now.
                HStack(spacing: 8) {
                    Button("Refresh receipt") { Task { await store.refresh() } }
                    if pending.refusal != nil {
                        Button("Discard") { store.discardRefused() }
                    } else if store.canRetry {
                        Button("Try again") { Task { await store.retry() } }
                    }
                }.buttonStyle(FleetOutlineButtonStyle())
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(FleetStyle.surface)
        }
    }

    /// The request line stands for a write that waits, **unless its own row on this page says it** (fix round 3c, the
    /// lead's call): an unanswered save of Runs on said so in its row with Try again, and here a second time with a
    /// second Try again.
    private var pendingBarShows: Bool {
        guard let pending = store.pending, !store.sending else { return false }
        guard let row = store.pendingInItsRow, row.id == pending.requestID else { return true }
        return store.destination.agentName != row.agent || store.destination.agentTab != row.tab
    }

    /// "Not sent: Atlas is in setup." — the hub's own words of a refusal as a sentence after "Not sent:", without its
    /// status ("Hub refused the request (409): …"), as the phone says it.
    private static func notSent(_ refusal: String) -> String {
        let words = (HubError.refusalWords(in: refusal) ?? refusal).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = words.last else { return "Not sent" }
        return "Not sent: " + words.prefix(1).uppercased() + words.dropFirst() + (".!?".contains(last) ? "" : ".")
    }

}

/// What the app says over the page, and what the owner can do about each of them. A message with nothing to press
/// was the owner's complaint of 19 October 2026, so every one of these carries its action: Try again and Settings
/// for a hub this Mac cannot reach, Refresh for a reading that has gone old, the manager's own page for what the
/// hub says about its session, and Report a problem for a write this Mac could not make. Everything else that is
/// not as usual has its own place — the Settings dot, the agent's row, the Activity count — and makes no strip
/// here.
struct FleetNotices: View {
    @Bindable var store: FleetStore
    @Environment(\.openWindow) private var openWindow

    var body: some View { notices.environment(\.noticeReading, reading) }

    /// The page under the notices stands in the column of prose: an agent's chat (not its setup, which is a page) and
    /// a task thread.
    private var reading: Bool {
        switch store.destination {
        case .agent(let name):
            !store.setupShows(name)
                && !AgentSetupFlow.chatStarts(store.state?.agents.first { $0.name == name },
                                              serverTime: store.state?.time ?? 0, fresh: store.isFresh)
        case .task: true
        default: false
        }
    }

    /// The page under the notices is the manager's own setup (`AgentSetupWizard`, at its chat's place or in its
    /// Settings) or its sign-in (`SignInWizard`), which already say that it is not signed in (`ManagerSession.bandShows`).
    private var managerSetupUnder: Bool {
        guard let manager = store.state?.agents.first(where: { $0.role == "manager" })?.name else { return false }
        switch store.destination {
        case .signIn(let name): return name == manager
        case .agent(let name), .agentDetail(let name, .settings), .agentDetail(let name, .chat):
            return name == manager && store.setupShows(manager)
        default: return false
        }
    }

    /// **Try again and Refresh can always be pressed** (T-14): they went grey for each read of the fleet's own
    /// three-second clock, and a press during a read loses nothing — the store reads once more after it (`refresh`).
    ///
    /// **One notice at a time, in the band over the page** (fix round 2, item 2): it pushed the whole page 46 pt down
    /// when a slow read made the reading old at 1.0 s, and back up when the read answered at 1.7 s. It stands now in
    /// the empty band where the window's own buttons are, as tall as that band, so nothing under it moves when it comes
    /// or goes, and it covers no control and no word of the page. One cause, one notice: a hub that does not answer or
    /// refuses has its own notice, and "This reading of your fleet is old" is only for a read that is slow, never for
    /// reads that fail (they said one outage twice in six seconds).
    @ViewBuilder private var notices: some View {
        if let error = store.connectionError {
            // **One way on** (T-35): Try again. Settings › System status, where the hub's address opens by itself
            // while the hub does not answer, is in the sidebar as always; a second button beside it made two ways on.
            BandNotice(error, symbol: "antenna.radiowaves.left.and.right.slash") {
                Button("Try again") { Task { await store.refresh() } }
                    .buttonStyle(FleetOutlineButtonStyle())
            }.accessibilityIdentifier("notice-connection")
        } else if store.staleNoticeShows {
            BandNotice("This reading of your fleet is old. Refresh it before you send.", symbol: "clock.arrow.circlepath") {
                Button("Refresh") { Task { await store.refresh() } }
                    .buttonStyle(FleetOutlineButtonStyle())
            }.accessibilityIdentifier("notice-stale")
            // Once it stood, it stays until a read answers or the hub's own notice takes its place (`staleNoticeStood`).
            .onAppear { store.staleNoticeStood = true }
        } else if let error = store.storageError {
            // The system's own words are on hover (T-35), and in the problem report.
            BandNotice(error, symbol: "externaldrive.badge.exclamationmark", color: .red) {
                Button("Report a problem") { openWindow(id: FounderizerApp.reportWindow) }
                    .buttonStyle(FleetOutlineButtonStyle())
            }.help(store.storageCause ?? "").accessibilityIdentifier("notice-storage")
        } else if let warning = store.state?.manager_flag, !warning.isEmpty, store.isFresh,
                  ManagerSession.bandShows(kind: store.state?.manager_warning?.kind, overItsSetup: managerSetupUnder) {
            let manager = store.state?.agents.first { $0.role == "manager" }?.name
            BandNotice(warning) {
                // "The manager session is not running. Start it again." now carries the start itself: the helper's
                // own loop starts a session that went by itself, and this is the owner's hand on the same switch
                // (`ManagerSession`). Its other warnings — a usage limit, a question on its screen, a silence, a
                // switch that has not finished — are not put right by a start, so they keep the page, which is
                // where its session is opened: the machine, the provider and Screen Sharing.
                if let manager, store.supportsManagerStart,
                   ManagerSession.startable(kind: store.state?.manager_warning?.kind) {
                    Button("Start the session") { Task { await store.command(.managerStart(agent: manager)) } }
                        .buttonStyle(FleetOutlineButtonStyle()).disabled(store.sending || !store.canWrite)
                        .accessibilityIdentifier("notice-manager-start")
                }
                if let manager {
                    Button("Open \(manager.agentLabel)") { store.destination = .agentDetail(manager, .settings) }
                        .buttonStyle(FleetOutlineButtonStyle())
                }
            }.accessibilityIdentifier("notice-manager")
        }
    }
}

/// **A notice in the band over the page**: the icon, its words on one line (all of them on hover) and its one way on,
/// on the notice's tint with a hairline under it — `FleetNotice`'s look, as tall as the band the window's buttons stand
/// in (`FleetSpace.lights`), so it covers nothing of the page and moves nothing when it comes or goes.
private struct BandNotice<Actions: View>: View {
    private let text: String
    private let symbol: String
    private let color: Color
    private let actions: Actions
    @Environment(\.noticeReading) private var reading

    init(_ text: String, symbol: String = "exclamationmark.triangle.fill", color: Color = .orange,
         @ViewBuilder actions: () -> Actions) {
        self.text = text; self.symbol = symbol; self.color = color; self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol).font(IconMetrics.symbol(12.5)).foregroundStyle(color).accessibilityHidden(true)
            // **Two lines in the band before any word is cut** (fix round 3, item 2): at 960 the chat's column cut it to
            // "Your hub did not answer. Che…"; where the main view is narrow its words go on to a second line.
            Text(text).font(FormMetrics.text).foregroundStyle(FleetStyle.text).lineLimit(2).truncationMode(.tail)
                .help(text)
            Spacer(minLength: 12)
            HStack(spacing: FleetSpace.actions) { actions }
        }
        .frame(height: FleetSpace.lights)
        .fleetColumn(reading: reading)
        .background(color.opacity(0.1))
        .overlay(alignment: .bottom) { Rule() }
        .accessibilityElement(children: .contain)
    }
}

extension View {
    /// **The notices belong over the page, never over a column of rows.** The two pages that draw a sidebar of
    /// their own — an agent's details and Settings — put them at the top of the section that is open, so the
    /// strip begins where the page's own words begin (the owner, 21 October 2026: "warning should be aligned, so
    /// only do the bar on the main view, not on the sidebars"). Every other page gets them from the window.
    func pageNotices(_ store: FleetStore) -> some View {
        // In the band over the page's own column, where nothing of the page stands, so the page does not move.
        padding(.top, FleetSpace.lights).overlay(alignment: .top) { FleetNotices(store: store) }
    }
}

/// **The round Send of a composer shows only while it can send** (the owner, 26 October 2026: "dont show the send
/// button if it's not clickable"). It was a grey circle in every chat with an empty field, and then a grey "…" for the
/// moment a message was on its way, with the field already empty (53–153 ms, the panel of 28 October): from the press
/// the slot is empty until there are words to send again. It stands in a slot of its own size, so the field beside it
/// never moves when it comes and goes. **It fades in over 0.15 s, and goes in the frame the field empties** (fix round
/// 2): its fade out drew a dim, disabled disc beside the empty field for 0.1 s after every send. One size in every
/// composer — a chat, a Needs-you answer and a task's guidance — the 28 points of an icon button (`IconMetrics.side`).
struct SendSlot<Content: View>: View {
    let shows: Bool
    let content: Content

    init(shows: Bool, @ViewBuilder content: () -> Content) {
        self.shows = shows; self.content = content()
    }

    var body: some View {
        ZStack { if shows { content.transition(.asymmetric(insertion: .opacity, removal: .identity)) } }
            .frame(width: IconMetrics.side, height: IconMetrics.side)
            .animation(.easeOut(duration: 0.15), value: shows)
    }
}

/// The face of the round Send: an arrow on a filled circle.
///
/// **In a chat the circle wears the colour of the agent it writes to** (the owner's yes of 28 October 2026, D-6):
/// Manager's lime, Nova's blue, Mia's coral, in its glyph's own colour (`AgentTint`). It shows only while it can send
/// (`SendSlot`), so the colour is the sign that it is ready. **Every other Send — a Needs-you answer, a task's guidance
/// — is the violet of what he presses** (D-8 item 1, fix round 2): there the Send took the colour of the agent that
/// asked, so one control had two looks, and the phone's was violet.
struct SendMark: View {
    /// The agent a chat's message goes to; nil for every other composer.
    var agent: String?
    @Environment(\.glyphTeam) private var team

    var body: some View {
        let tint = agent.map { AgentTint(agent: $0, team: team) }
        Image(systemName: "arrow.up")
            .font(IconMetrics.symbol(13, weight: .semibold)).foregroundStyle(tint?.ink ?? Color.white)
            .frame(width: IconMetrics.side, height: IconMetrics.side)
            .background(tint?.fill ?? FleetStyle.accent, in: Circle())
    }
}

/// **The chat's composer: one capsule of one line at rest** (the owner's yes of 28 October 2026, D-6, after Grok Bot's
/// 38-point capsule and the composer of his other product): 40 points high, the 28-point plus and Send at the two ends of the line
/// he writes in, 6 points inside its edge, and the field between them. It **grows upward** with his text to ten lines
/// and then scrolls (`.growingField`), the plus and Send staying on the last line; what the line needs said — the files
/// that wait, why the chat takes no message, a refusal — stands over it inside the capsule. Its corners are half its
/// height at rest, so one line is a capsule and more lines are a box with the same round ends.
struct ComposerCapsule<Above: View, Line: View>: View {
    /// Between the capsule's edge and the 28-point controls of its line.
    static var inset: CGFloat { 6 }
    /// Its height at rest: the line's controls and the inset over and under them.
    static var rest: CGFloat { IconMetrics.side + 2 * inset }
    private let above: Above
    private let line: Line
    /// The cursor of its field: **a click anywhere on the capsule puts the cursor in it** (T-21, fix round), as a one-line
    /// field's whole box does. Only the line of words took the click, 17 of a guidance box's 40 points.
    private let focus: FocusState<Bool>.Binding?
    @Environment(\.colorSchemeContrast) private var contrast

    init(focus: FocusState<Bool>.Binding? = nil, @ViewBuilder above: () -> Above, @ViewBuilder line: () -> Line) {
        self.focus = focus; self.above = above(); self.line = line()
    }

    var body: some View {
        // The circular style: a hairline on the continuous one draws short stray lines at a capsule's ends.
        let shape = RoundedRectangle(cornerRadius: Self.rest / 2, style: .circular)
        VStack(alignment: .leading, spacing: 8) {
            Group(subviews: above) { parts in
                if !parts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) { ForEach(parts) { $0 } }
                        .padding(.horizontal, 8).padding(.top, 6)
                }
            }
            HStack(alignment: .bottom, spacing: 8) { line }
        }
        .padding(Self.inset)
        .background(FleetStyle.composer, in: shape)
        // **The edge of a field, 3:1 on what it stands on** (fix round 2), as every field's (`fleetField`): it read 1.75:1.
        .overlay(shape.strokeBorder(FleetStyle.hairline(0.32), lineWidth: FleetStyle.edgeWidth(contrast)))
        // The plus, Send and the field itself take their own clicks first; the rest of the capsule gives the cursor.
        .contentShape(shape)
        .onTapGesture { focus?.wrappedValue = true }
    }
}

extension ComposerCapsule where Above == EmptyView {
    init(focus: FocusState<Bool>.Binding? = nil, @ViewBuilder line: () -> Line) {
        self.init(focus: focus, above: { EmptyView() }, line: line)
    }
}

extension View {
    /// The field of a `ComposerCapsule`: the chat's font, one line at rest that grows to ten and then scrolls (a task's
    /// guidance to five), and its line centred on the 28-point controls beside it. `alone`: no plus at its left, so its
    /// words keep the room from the capsule's round end that the plus would have given them.
    func composerField(alone: Bool, lines: ClosedRange<Int> = 1...10) -> some View {
        textFieldStyle(.plain).font(ChatStyle.font)
            .growingField(lines)
            .padding(.vertical, (IconMetrics.side - ChatStyle.line) / 2)
            .padding(.leading, alone ? 8 : 0)
    }
}

/// **The agents by keys** (T-16): ⌘1 … ⌘9 open the first nine chats of the sidebar's list, ⌥⌘↓ and ⌥⌘↑ the next one and
/// the one before. They are a watch on this window's own keys, with no view he can reach and no menu item: the
/// approved T-16 says "nothing on screen", and the hidden buttons they were took a Tab stop with Full Keyboard Access
/// and a click in the empty sidebar. A key in another window — a card over the page, Report a problem — is not theirs.
private struct AgentKeys: NSViewRepresentable {
    let names: [String]
    let open: (String) -> Void
    let step: (Int) -> Void

    func makeNSView(context: Context) -> KeyWatch { KeyWatch() }

    func updateNSView(_ view: KeyWatch, context: Context) {
        view.names = names; view.open = open; view.step = step
    }

    static func dismantleNSView(_ view: KeyWatch, coordinator: ()) { view.stop() }

    final class KeyWatch: NSView {
        var names: [String] = []
        var open: (String) -> Void = { _ in }
        var step: (Int) -> Void = { _ in }
        private var monitor: Any?

        // Nothing here takes a click, the keyboard's focus or a Tab stop.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var acceptsFirstResponder: Bool { false }
        override var canBecomeKeyView: Bool { false }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let watch = self else { return event }
                // The monitor runs on the main thread, before the window's own key equivalents.
                let taken = MainActor.assumeIsolated { () -> Bool in
                    guard let window = watch.window, event.window === window, window.isKeyWindow else { return false }
                    return watch.take(event)
                }
                return taken ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func take(_ event: NSEvent) -> Bool {
            let keys = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if keys == .command, let digit = event.charactersIgnoringModifiers.flatMap({ Int($0) }), (1...9).contains(digit) {
                guard digit <= names.count else { return false }
                open(names[digit - 1])
                return true
            }
            if keys == [.command, .option] {
                switch event.specialKey {
                case .downArrow?: step(1); return true
                case .upArrow?: step(-1); return true
                default: return false
                }
            }
            return false
        }
    }
}
