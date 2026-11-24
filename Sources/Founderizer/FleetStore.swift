import AppKit
import FleetCore
import FleetOwnerAPI
import Foundation
import Observation
import OSLog

struct TaskChild: Identifiable, Equatable {
    let id: RuntimeToolKey
    let name: String
    let status: String?
}

enum Destination: Hashable {
    /// `activity` is the task board, which the sidebar names Tasks. One agent's page is `agent`, its chat with its
    /// status panel; `agentDetail`, a part of its details; and `agentRule`, the editor of one rule of its Behaviour,
    /// or of a new rule (nil). The servers and the owner's own devices are Settings › Servers (`settings(.servers)`);
    /// `server` is one server's page there (by its name, or the name of an agent on it), and `addServer` its wizard.
    /// People, their conversations and an agent's duties belong to one agent, so they are parts of `agentDetail` and
    /// have no case of their own. **A task and a job are no pages** (the owner, 21 November 2026: "task details to open
    /// as a modal ... even for the tasks page!"): they open as the detail card over the page that shows
    /// (`FleetStore.detail`), and the page under it stays as it is.
    ///
    /// **No Dashboard and no Agents table** (the owner's yes of 28 October 2026 to D-4, "the whole map"): the agents'
    /// rows of the sidebar are the one list of the agents, and the app opens on Needs you while a request waits, else on
    /// the manager's chat (`FleetStore.home`). `agents` is every agent with its role, server, account and usage, from the
    /// sidebar's row under Tasks (`AgentsPage`). `app` is one app's own page of Settings › Apps (the owner's yes of 10
    /// November 2026 to its split), as `server` is one server's page of Settings › Servers. `connectKey` is his Tailscale
    /// key page of Turn on for the connected apps (`ConnectAppKeyStep`), a page of Settings › Servers too.
    case needs, activity, agents, addAgent, server(String), addServer, agent(String),
         agentDetail(String, AgentTab),
         /// The sign-in page of an agent's server (`SignInWizard`). Its second value is the provider that the page was
         /// opened for, from "Sign in again" on the error row of a task's thread (`RuntimeErrorLine`; the owner's "Yes,
         /// build it" of 18 November 2026): the provider of that task's attempt, which can be another one than the
         /// server's own choice (`MachineStatus.signInRuntime`, the agent's own provider), such as Codex of the screen
         /// tasks of an agent on Claude Code. It is a part of the page, so a step of Back or Forward opens the page for
         /// the provider that it was opened for, and the page's Back and Done go to the page that he came from. Nil for
         /// every other opening (`signIn(_:)`), which signs in the server's own choice.
         signIn(String, String?), agentRule(String, ProfileSectionID?), settings(SettingsTab),
         app(AppsGroup), connectKey

    /// **Tasks, opened from an agent's chat panel** (View all of its card Asked): the board of `activity`, with that
    /// agent's back link over its title, which goes back to its chat (the owner's "Yes, build both" of 17 November 2026
    /// to "when you open Tasks from an agent's panel, '‹ Fleet Manager' (the agent's name) shows at the top left, as on
    /// the agent's other pages"). The sidebar's Tasks row opens `activity`, with no back link. The page is Tasks, so the
    /// sidebar selects Tasks on it, it has no `agentName`, and Back opens it also when the hub lists that agent no more
    /// (renamed or deleted elsewhere): then it is Tasks with no back link (`ActivityBoard`).
    case activityFrom(String)

    /// The agent whose chat panel opened Tasks (`activityFrom`), for the board's back link; nil on every other page.
    var tasksFrom: String? { if case .activityFrom(let name) = self { name } else { nil } }

    /// The sign-in page of an agent's server for the server's own choice of provider.
    static func signIn(_ agent: String) -> Destination { .signIn(agent, nil) }

    /// The agent whose page shows, or nil on every other page.
    var agentName: String? {
        switch self {
        case .agent(let name), .agentDetail(let name, _), .agentRule(let name, _), .signIn(let name, _): name
        default: nil
        }
    }

    /// The section of Settings that shows: a server's page and Add server are pages of Settings › Servers.
    var settingsTab: SettingsTab? {
        switch self {
        case .settings(let tab): tab
        case .server, .addServer, .connectKey: .servers
        case .app: .apps
        default: nil
        }
    }

    /// **This page draws a sidebar of its own**, so it draws the window's notices too, beside that sidebar and not
    /// over it (`pageNotices`).
    var ownsSidebar: Bool {
        switch self {
        case .agentDetail, .agentRule, .settings, .server, .addServer, .app, .connectKey: true
        default: false
        }
    }

    /// The section of the agent that shows, or nil. A rule's editor is in Behaviour.
    var agentTab: AgentTab? {
        switch self {
        case .agent: .chat
        case .agentDetail(_, let tab): tab
        case .agentRule: .behaviour
        default: nil
        }
    }
}

/// One entry of an agent's chat to show: its `ChatEntry.id`, or `need-<n>` for a request's card, and its time, which
/// says how far back the chat must draw to hold it.
struct ChatFocus: Equatable {
    let agent: String
    let entry: String
    let at: Double
}

/// The state of a control that saves itself, for the small mark beside it.
enum SaveState: Equatable {
    case saving
    case saved
    /// Not saved, with the reason. Retry sends it again.
    case failed(String)
    /// Another save changed the same value meanwhile: the control shows that value now.
    case changedElsewhere
    /// Not sent, because another request waits in the window's request line and is not on its way (refused, or
    /// without an answer). Only Retry shows, with the reason on hover, and the row says nothing (the owner's choice,
    /// 26 October 2026: "No line, only Retry"). It used to say Saving… for as long as that request waited.
    case behind

    /// The row's warning: a failed save only.
    var failure: String? { if case .failed(let reason) = self { reason } else { nil } }
    /// The value did not go and stays for Retry.
    var retries: Bool { failure != nil || self == .behind }
}

/// What one save of a control that saves itself did.
enum SaveResult: Equatable {
    /// The hub took it. `sha256` is the new version of the file that it changed.
    case saved(sha256: String?)
    /// 409, in the hub's words: the base changed elsewhere, or the hub cannot take a change now.
    case conflict(String)
    /// Another refusal in the hub's words, or a save that could not go.
    case refused(String)
    /// The request waits in the outbox for its answer. Retry sends it again.
    case unconfirmed(UUID)
    /// Not sent: another request waits in the outbox and is not on its way (`save(_:note:queue:)` with queue false).
    case behind
}

@MainActor @Observable
final class FleetStore {
    /// The claim key of the website's Open Founderizer link, traded once a fleet answers (`ClaimFromLink`).
    @ObservationIgnored private let claimFromLink = ClaimFromLink()

    /// A `founderizer://` link that macOS opened in this app.
    func openLink(_ url: URL) { claimFromLink.take(url, store: self) }

    let notifications = FleetNotifications()
    /// The copy of his fleet that this Mac keeps for him, on the schedule he set (`CopyKeeper.swift`).
    let copies = FleetCopyKeeper()
    /// This app's own update, put in place without a press while he is away from it (`AppUpdateModel.swift`).
    let updates = AppAutoUpdate()
    /// What each page read last, so a page that opens again draws it at once (`PageReadings.swift`).
    let readings = PageReadings()
    /// **The first read of this launch has answered, or a second has gone by.** Until then the window draws its
    /// background only: the first-run wizard showed for the 75–86 ms of that read at every launch of an app that
    /// has a fleet (`FleetView.firstRun`).
    private(set) var launched = false
    /// **The launch's first read of the fleet's state has ended**, with an answer or without one. Until then the
    /// reading that this Mac kept from its last launch is current (`isFresh`, `StateReading`).
    private(set) var firstReadEnded = false
    /// **This hub address has answered this Mac before**, at this launch or an earlier one. A Mac that has read its
    /// hub never shows the first-run wizard while it waits for it (`FleetView.firstRun`): "Set up your fleet" filled
    /// the window at 8 of 8 launches until the first read answered.
    private(set) var hubAnsweredBefore = false
    /// **This Mac was never given a hub address**: the store reads the address of no hub (`HubClient.defaultAddress`),
    /// which never answers. A read of it fails as every read of a lost hub does, and the window says nothing about
    /// that failure (`FleetView.notices`): there is no hub to find yet.
    var hubIsUnset: Bool { HubClient.isUnset(hub) }
    /// The window's notice has nothing to say: the read that failed was a read of the address of no hub. An address
    /// that the owner typed in Settings and that is no hub address still gets its line.
    var quietAboutNoHub: Bool {
        guard hubIsUnset else { return false }
        if case .invalidAddress? = lastReadError as? HubError { return false }
        return true
    }
    /// The provider setups of the agents, by hub address, hub generation and agent name. A setup stays with its agent
    /// while other pages of that hub generation show. An agent of the same name on another hub has its own setup.
    @ObservationIgnored private var providerSetups: [AgentKey: ProviderSetup] = [:]
    private struct AgentKey: Hashable { let hub: URL; let database: String?; let agent: String }
    func providerSetup(hub: URL, database: String?, agent: String) -> ProviderSetup {
        let key = AgentKey(hub: hub, database: database, agent: agent)
        if let setup = providerSetups[key] { return setup }
        let setup = ProviderSetup(); providerSetups[key] = setup
        return setup
    }
    /// The checks of one machine (PRODUCT.md 4.1), one model for each machine of this hub. A check that runs stays
    /// while another page shows.
    @ObservationIgnored private var checksModels: [String: MachineChecksModel] = [:]
    func checksModel(machine: String, kind: MachineCheckout, linux: Bool = false) -> MachineChecksModel {
        let key = checksKey(machine)
        // The kind is the hub's own answer about that machine, and a later reading can settle it (a server whose
        // system no reading had yet). A kept model takes the newer answer; nothing else about it changes. So does
        // `linux` (`ServerEntry.reportsLinux`), which says whether a first host key at port 22 may be kept.
        if let model = checksModels[key] {
            if model.kind != kind { model.kind = kind }
            if model.linux != linux { model.linux = linux }
            return model
        }
        let model = MachineChecksModel(machine: machine, hub: hub, kind: kind, linux: linux)
        checksModels[key] = model
        return model
    }

    /// What one machine's checks hold in this launch, for Report a problem: the checklist its page shows, and whether
    /// a closer look of this launch read it (`MachineChecksModel.lookedNow`). A machine whose page made no model in
    /// this launch has neither.
    func look(machine: String) -> (checklist: VerifyChecklist?, lookedNow: Bool) {
        guard let model = checksModels[checksKey(machine)] else { return (nil, false) }
        return (model.checklist, model.lookedNow)
    }

    private func checksKey(_ machine: String) -> String { "\(hub.absoluteString)|\(machine)" }

    /// **A server renamed in Tailscale keeps what this Mac knows of it** (`server_names`: the hub renames it in Fleet by
    /// itself, and its private address stays). The connection and the checks kept under its old name go to the name
    /// that a servers reading gives that address now, and its page, while it shows, follows it. A name's address is the
    /// one the reading before gave it, else the address its kept connection reaches: a checklist kept with no
    /// connection, for a name this launch did not read, stays under the old name, where nothing shows it.
    func followRenames(from before: ServerList?, to list: ServerList) {
        var known = InstallTargets.hosts(hub: hub)
        for server in before?.servers ?? [] { known[server.name] = server.address ?? "" }
        let after = Dictionary(list.servers.map { ($0.name, $0.address ?? "") }) { first, _ in first }
        let moves = Servers.renames(before: known, after: after)
        guard !moves.isEmpty else { return }
        for (old, new) in moves {
            InstallTargets.move(old, to: new, hub: hub)
            MachineChecks.move(old, to: new, hub: hub)
        }
        // A page of a server that took a new name: under its new name, in Back and Forward too, and no step of its own.
        history.rename { page in if case .server(let name) = page, let new = moves[name] { .server(new) } else { page } }
        if case .server(let shown) = destination, let new = moves[shown] {
            stepping = true; destination = .server(new); stepping = false
        }
    }

    /// The install of a machine of this fleet (PRODUCT.md P3), one for each hub address. It stays while other pages
    /// show, as a provider setup does, because an install takes minutes and a click must not lose it.
    @ObservationIgnored private var installModels: [URL: MachineInstallModel] = [:]
    func installModel() -> MachineInstallModel {
        if let model = installModels[hub] { return model }
        let model = MachineInstallModel()
        installModels[hub] = model
        return model
    }

    /// **A hub's install stays the install at the address it claimed** (the proof run of 5 November 2026). The claim
    /// moves this store to the new hub, where no install was kept, so the first run read an empty one there: "Your
    /// server" again, and it never went on. The install is kept under that address before the store goes to it, so no
    /// frame of the first run reads another one.
    func keepInstall(_ model: MachineInstallModel, at address: String) {
        guard let claimed = try? HubClient.address(address) else { return }
        installModels[claimed] = model
    }

    /// The central vault of this hub (owner feature `central_vault`), one for each hub address. The poll ticks it on
    /// every page, because the app keeps the vault in order by itself and its install takes minutes.
    @ObservationIgnored private var vaultModels: [URL: CentralVaultModel] = [:]
    func vaultModel() -> CentralVaultModel {
        if let model = vaultModels[hub] { return model }
        let model = CentralVaultModel(hub: hub)
        vaultModels[hub] = model
        return model
    }

    /// Turn on and Turn off of the connected apps (`ConnectSwitchModel`), one for each hub address: its steps take
    /// minutes and go on whatever page shows, and a second Turn on cannot start beside the first.
    @ObservationIgnored private var connectSwitches: [URL: ConnectSwitchModel] = [:]
    func connectSwitch() -> ConnectSwitchModel {
        if let model = connectSwitches[hub] { return model }
        let model = ConnectSwitchModel(hub: hub)
        connectSwitches[hub] = model
        return model
    }

    /// This Mac's step on the hub's own server for "1 server" (`HubShareModel`), one for each hub address and
    /// generation: it takes a minute or more and goes on whatever page shows, and a second step cannot start beside
    /// the first.
    @ObservationIgnored private var hubShares: [String: HubShareModel] = [:]
    func hubShare() -> HubShareModel {
        let database = state?.db ?? ""
        let key = "\(hub.absoluteString)|\(database)"
        if let model = hubShares[key] { return model }
        let model = HubShareModel(hub: hub, database: database)
        hubShares[key] = model
        return model
    }

    /// The owner's access key on this hub's servers, put there by itself: one model for each hub address.
    @ObservationIgnored private var accessModels: [URL: OwnerAccessModel] = [:]
    func accessModel() -> OwnerAccessModel {
        if let model = accessModels[hub] { return model }
        let model = OwnerAccessModel(hub: hub)
        accessModels[hub] = model
        return model
    }

    /// This Mac's key for this hub, registered by itself (`OwnerMacKey`): one model for each hub address.
    @ObservationIgnored private var keyModels: [URL: OwnerKeyModel] = [:]
    func keyModel() -> OwnerKeyModel {
        if let model = keyModels[hub] { return model }
        let model = OwnerKeyModel(hub: hub)
        keyModels[hub] = model
        return model
    }

    /// The join's hardening of this hub's Linux servers, put right by itself: one model for each hub address.
    @ObservationIgnored private var hardeningModels: [URL: ServerHardeningModel] = [:]
    func hardeningModel() -> ServerHardeningModel {
        if let model = hardeningModels[hub] { return model }
        let model = ServerHardeningModel(hub: hub)
        hardeningModels[hub] = model
        return model
    }

    /// The door's access file of this hub (owner feature `server_access`), kept by itself: one for each hub address.
    @ObservationIgnored private var doorModels: [URL: DoorSyncModel] = [:]
    func doorModel() -> DoorSyncModel {
        if let model = doorModels[hub] { return model }
        let model = DoorSyncModel(hub: hub)
        doorModels[hub] = model
        return model
    }

    /// The Settings of each agent of this hub generation, with their saves. A save goes on, and its mark stays, while
    /// another page shows.
    @ObservationIgnored private var settingsModels: [AgentKey: AgentSettingsModel] = [:]
    func settingsModel(agent: String) -> AgentSettingsModel {
        let key = AgentKey(hub: hub, database: state?.db, agent: agent)
        if let model = settingsModels[key] { return model }
        let model = AgentSettingsModel(agent: agent, hub: hub, database: state?.db ?? "")
        settingsModels[key] = model
        return model
    }
    /// After the connection goes to another hub or hub generation, no page has the Stop setup control of a provider
    /// setup, so its local installer stops, as it did when its view closed. Set up continues from its saved steps.
    /// The Settings of that generation go too.
    private func endProviderSetups() {
        for setup in providerSetups.values where setup.session.running { Task { await setup.session.cancel() } }
        providerSetups = [:]
        settingsModels = [:]
    }
    /// Shared by the chat rows and agent icons until the next fleet reading.
    private(set) var openTasksByAgent: [String: [FleetTask]] = [:]
    private var newestReplies: [String: Int] = [:]

    var state: HubState? {
        // Each agent's role, for every line of the app that names an agent (`AgentNames`): its name, and its role
        // beside it where the agent is an entry of its own (the owner's answers of 22 November 2026).
        didSet {
            AgentNames.shared.read((state?.agents ?? []).map { ($0.name, $0.title) })
            askCache = nil
            openTasksByAgent = Dictionary(grouping: (state?.tasks ?? []).lazy.filter { !$0.isTerminal }, by: \.owner)
            newestReplies = (state?.reports ?? []).reduce(into: [:]) { newest, reply in
                let agent = reply.chatAgent
                newest[agent] = max(newest[agent] ?? reply.id, reply.id)
            }
            closeAnsweredTakeOvers()        // owner feature need_takeover: the way in closes at his answer
            forgetFilesOfAnotherFleet()     // a new hub or database numbers its files from 1 again
            dropUnsendableGuidanceFiles()   // a task's box that can send no more keeps no file
            JobColumns.shared.note(state)   // each job card's time in its column, at every reading (ColumnTimes)
            // **The card over the window shows only what this reading lists** (`DetailCard.kept`): a task or a job that
            // the hub lists no more, another hub or generation, or a moment with no reading closes it, and nothing opens
            // it again. `-openPage task.<id>` opens it at the first reading (`askedCard`).
            readingCount += 1
            if let asked = askedCard, state != nil {
                askedCard = nil
                keepDetail(DetailCard(asked).kept(in: state, before: nil))
            } else if let card = detail {
                keepDetail(card.kept(in: state, before: oldValue))
            }
        }
    }
    /// The card as a reading kept it, with the job levels that it worked out for it (`detailLevels`).
    private func keepDetail(_ kept: (card: DetailCard, levels: DetailLevels)?) {
        if let kept { levelsCache = (kept.card, readingCount, kept.levels) }
        if kept?.card != detail { detail = kept?.card }
    }
    /// One more at each reading of the hub: the job levels of the card are worked out once for each (`detailLevels`).
    @ObservationIgnored private var readingCount = 0
    @ObservationIgnored private var levelsCache: (card: DetailCard, reading: Int, levels: DetailLevels)?
    /// **The job levels of the card that shows, worked out once for each reading and each change of the card**
    /// (`DetailLevels`), as `asks` is read once for each reading: a job of the board is found by working out that whole
    /// board, and the card's two builds (`fleetModal`'s card as high as its content) and its back link read it at each
    /// draw.
    var detailLevels: DetailLevels? {
        guard let detail, let state else { return nil }
        if let kept = levelsCache, kept.card == detail, kept.reading == readingCount { return kept.levels }
        let levels = state.levels(of: detail)
        levelsCache = (detail, readingCount, levels)
        return levels
    }
    /// The card that this start was asked to open on (`FleetStore.askedDetail`), until the first reading.
    @ObservationIgnored private var askedCard = FleetStore.askedDetail
    /// **What he asked for (`HubState.asks`), read once for each reading**: an agent's chat reads it at each of its
    /// frames, and it walks every task of the fleet.
    var asks: [Ask] {
        // The view that asks reads `state`, so a new reading draws it again.
        guard let state else { return [] }
        if let askCache { return askCache }
        let read = state.asks
        askCache = read
        return read
    }
    @ObservationIgnored private var askCache: [Ask]?
    private(set) var chatTimeline = ChatTimeline()
    /// The page this app opens on when somebody asked for one with
    /// `-openPage settings.<tab> | agent.<name>.<section> | task.<id> | needs | tasks | …`, which is how one screen can
    /// be looked at without clicking to it; otherwise `home`. The argument domain is not written to the app's settings,
    /// so it leaves no trace. Every page that a sidebar row opens is here, because a screen that cannot be opened on its
    /// own is a screen that nobody checks. The names of the pages that became sections of Settings (servers, devices,
    /// updates, mcps, subscription) still open them there.
    static var asked: Destination? {
        // Only a word of this start's arguments, never a kept setting: a kept one (`defaults write`) opened each
        // start of the app on a chosen page, also on one that acts when it opens, and so went around the rules of
        // `setup_show`. The other lane did the same for `firstRunStep` on 15 November 2026. (The page he left, which
        // this Mac keeps, opens only as one of `setup_show`'s places: `keptPage`.)
        askedName.flatMap(page(named:))
    }
    /// The card that this start opens on over `asked` (`-openPage task.<id>`), or nil.
    static var askedDetail: DetailPlace? { askedName.flatMap(detail(named:)) }
    private static var askedName: String? {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["openPage"] as? String
    }

    /// A page by its name of `-openPage`, or nil for a name that names none.
    static func page(named name: String) -> Destination? {
        switch name {
        case "settings": return .settings(.general)
        // `app.<github|drive|gmail|mcp>`: one app's page of Settings › Apps; its MCP servers were once a section, `mcps`.
        case "settings.mcps", "mcps": return .app(.mcp)
        case let page where page.hasPrefix("app."): return AppsGroup(rawValue: String(page.dropFirst("app.".count))).map { .app($0) }
        case let page where page.hasPrefix("settings."):
            // `settings.<tab>`, by the tab's own name: servers, updates, secrets, knowledge, apps, people, team, status.
            return SettingsTab.named(String(page.dropFirst("settings.".count))).map { .settings($0) }
        case "needs": return .needs
        case "activity", "tasks": return .activity
        case "agents", "usage": return .agents
        case "servers", "devices": return .settings(.servers)
        // `server.<name>`: one server's page, which no sidebar row opens on its own.
        case let page where page.hasPrefix("server."): return .server(String(page.dropFirst("server.".count)))
        // Settings › Updates is gone (15 November 2026): its versions and its switch are in General.
        case "updates", "updates.subscription": return .settings(.general)
        // `task.<id>`: the thread of one task, as the detail card over Tasks (`detail(named:)`). It is no sidebar row,
        // so nothing else opens it on its own — and it was the one screen of the app nobody could look at without a
        // task to click to.
        case let page where page.hasPrefix("task."): return detail(named: page) == nil ? nil : .activity
        case let page where page.hasPrefix("agent."):
            // `agent.<name>` is the agent's chat, as its row in the sidebar is; `agent.<name>.<section>` is one
            // section of its details, so any one of them can be looked at on its own.
            let parts = page.dropFirst("agent.".count).split(separator: ".", maxSplits: 1)
            guard let name = parts.first, !name.isEmpty else { return nil }
            // The sections that are in one of the four parts now open that part (`AgentTab.named`).
            guard parts.count > 1, let tab = AgentTab.named(String(parts[1])) else { return .agent(String(name)) }
            return .agentDetail(String(name), tab)
        default: return nil
        }
    }

    /// The detail card that a name of `-openPage` and of the page he left opens over its page (`page(named:)`): the task
    /// level of `task.<id>`, or nil for every other name.
    static func detail(named name: String) -> DetailPlace? {
        guard name.hasPrefix("task.") else { return nil }
        return Int(name.dropFirst("task.".count)).map { .task($0) }
    }

    /// The first-run wizard holds the window, after the hub it installed has answered. It is set and cleared by
    /// the wizard itself, and never kept: a later start of the app begins with no hold.
    var firstRunHolds = false
    /// **What the first run shows, for the owner's own agent** (`setup_state` on the link, `SetupChannel.swift`): its
    /// page by a fixed name, its title, whether its work runs. The window's wizard keeps it current; `.none` when no
    /// first run shows. Typed values only, never a value of a field.
    var setupSnapshot = SetupFirstRun.none
    /// **The first run's build at a provider, and Add server's** (`setup_diagnosis`), kept by their writer, because both
    /// can be in work at one time: nil while that model told nothing (`SetupChannel.reports`).
    var firstRunBuild: ReachFacts.BuildFacts?
    var addServerBuild: ReachFacts.BuildFacts?
    /// **The page that each wizard shows now, by its fixed name** (`setup_state`'s `place`): Add server, Add agent, an
    /// agent's setup and a sign-in each write their own when their page changes and clear it when they go.
    var wizardPages = WizardPages()
    /// **A page of the first run that the owner's own agent asked to see** (`setup_show`): the window's wizard takes it
    /// and writes its outcome; the link then clears it.
    var setupAsk: SetupAsk?
    /// **A text of the owner's own agent for the report form** (`prepare_problem_report`, `LinkTools.showReport`): the
    /// form takes it and says how. `openReportWindow` opens that window from outside a view; the main window's view
    /// sets it, as it sets `notifications.showWindow`.
    var reportAsk: ReportAsk?
    @ObservationIgnored var openReportWindow: (() -> Void)?
    /// **The hub's address had answered this Mac in an earlier start of the app.** Only then can a setup be one that
    /// an earlier start left unfinished (`welcomeCovers`): a first run of this start went through the welcome page
    /// already.
    @ObservationIgnored private var startedWithFleet = false
    /// A program for the welcome page's second way is on this Mac (`AgentPrograms`), read one time, when the page
    /// could first show: without one that page has only the way that leads to the page behind it.
    @ObservationIgnored private lazy var offersAgent = !AgentPrograms.found().isEmpty
    /// **The welcome page of an unfinished setup was passed in this start of the app**: by the end of one of its two
    /// ways (`passWelcome`), when the owner left the manager's page (`WelcomeRules.leaves`), when an install or a
    /// build of a server ran (`watchWork`), when the manager got its server, or by another hub's address. It is only
    /// ever set, so the page never comes back in the same start,
    /// whatever comes after (a second sign of `founderizer-cli guide` too).
    private(set) var welcomePassed = false
    /// "Set it up yourself" on that welcome page, and the sign that the owner's own agent started the guide: the
    /// window goes on to the manager's setup, where the setup stands.
    func passWelcome() { welcomePassed = true }
    /// **An install or a build of a server that runs passes the welcome page for this start of the app**, at the
    /// moment it starts, with the window open or closed: the page never stands in front of work (`coversSetup`), and
    /// it must not come in front of the manager's setup when that work ends, or when the owner opens the manager
    /// after work that they did in this start. It watches the install of this hub and Add server's build until one of
    /// them runs; another hub's address passes the page by itself (`connect`).
    private func watchWork() {
        guard startedWithFleet, !welcomePassed else { return }
        withObservationTracking {
            _ = (installModel().running, AddServerView.builds)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.welcomePassed else { return }
                if self.installModel().running || AddServerView.builds { self.welcomePassed = true } else { self.watchWork() }
            }
        }
    }
    /// The manager's own page, where its setup shows in place of its chat; nil while no reading names a manager.
    private var managerPage: Destination? {
        state?.agents.first { $0.role == "manager" }.map { .agent($0.name) }
    }
    /// **An unfinished setup opens on the welcome page** (the owner, 14 November 2026, of a new user whose manager's
    /// server did not install and whom an updated app showed "Manager's server" with no way to the prompt for their
    /// own agent: "yes there should be always a way to see it"). In each start of the app, the first time that the
    /// window would show the setup of a manager that has no server yet, it shows the welcome page in front of it
    /// (`WelcomeRules.coversSetup`, which decides). It reads the reading that the window draws, also the one that this
    /// Mac kept: a hub that does not answer at the start is the case that the page's second way helps with. A page
    /// asked for with a launch argument (`-openPage`, `-firstRunStep`) shows as asked.
    var welcomeCovers: Bool {
        // The common cases first, with no other read: a start with no fleet, a page that was passed, and a manager
        // that has its server.
        guard startedWithFleet, !welcomePassed, let state,
              let manager = state.agents.first(where: { $0.role == "manager" }), !manager.placed else { return false }
        let asked = FleetStore.asked != nil || FirstRunModel.asked != nil
        func covers(runs: Bool) -> Bool {
            WelcomeRules.coversSetup(hadFleet: startedWithFleet, passed: welcomePassed || asked, offersAgent: offersAgent,
                                     unplaced: !manager.placed,
                                     setupFills: destination == .agent(manager.name) && fillsWindow(destination),
                                     runs: runs)
        }
        // The models of the work are read only for a page that would show: a read of the install's model makes it.
        return covers(runs: false) && covers(runs: installModel().running || AddServerView.builds)
    }
    /// The first option of a Needs-you item for his phone (API 1.95) asked for the Add device picture: the Devices
    /// group of Settings › Servers makes its code at once, as its own Add device does, and clears this.
    var addDeviceAsked = false
    /// Owner feature `need_run`: each item's Run while it runs, and the line of a run that did not reach its Mac, by
    /// the item's id. A quit forgets them, and an item whose command ran is answered.
    var needRuns: [Int: NeedRunState] = [:]
    /// The machines' readings that Run takes a Mac of the fleet from (`NeedRun.place`): read while a card shows a
    /// command for one, and again at each press.
    var runMachines: [MachineStatus]?
    /// owner feature need_takeover: the Screen Sharing tunnel that a press of Take over opened, by its item, which
    /// `closeAnsweredTakeOvers` closes once a reading shows that item answered or gone.
    @ObservationIgnored var takeOvers: [Int: ScreenSharingConnection] = [:]
    /// **The take-over card over the window, or nil** (`TakeOverCard`; the owner's "Yes, build it" of 21 November 2026):
    /// Take over opens it (`takeOver`); Done, Esc, a click on the dimmed window and the request's answer anywhere close
    /// it, and its close ends its tunnel and brings back what it covered (`takeOverCardClosed`).
    var takeOverCard: TakeOverItem? {
        didSet {
            guard let old = oldValue else { return }
            let same = takeOverCard.map { $0.id == old.id && $0.hub == old.hub && $0.database == old.database } ?? false
            guard !same else { return }
            takeOverCardClosed(old)
            if detail == nil { markRepliesSeen() }          // the chat that the card covered shows again
        }
    }
    /// What the open take-over card does (`TakeOverScreen`): made and started with the card, stopped at its close.
    var takeOverScreen: TakeOverScreen?
    /// The lane "Give on a card": the names that requests' words link, with the key of what they were made of, by the
    /// repositories of a card's own Give, and by none for every other card (`cardNames(for:)`); the same names by a
    /// chat's rules (`chatNames`), and the servers' symbols for its badges. New names drop the books of every Give.
    @ObservationIgnored var cardBook: (key: Int, cards: [[String]: CardNames], chat: ChatNames,
                                       symbols: [String: String])?
    /// build plan 04, S6: the hub's servers, read for a take-over's card, whose readings name a Linux agent's
    /// screen-sharing port (`readTakeOverServers`).
    var takeOverServers: [ServerEntry]?
    @ObservationIgnored private var runJobs: [Int: NeedRunJob] = [:]
    @ObservationIgnored private var runMachinesRead: ContinuousClock.Instant?
    @ObservationIgnored private var runQuitWatch: NSObjectProtocol?
    var destination: Destination = FleetStore.asked ?? .agent("manager") {
        didSet {
            // The first page the app chose for itself is no step he can go back to; a step of Back or Forward is not
            // one he opened.
            if homeChosen, !stepping { history.went(from: oldValue, to: destination) }
            // The owner left the manager's page: the welcome page in front of its setup is passed for this start
            // (`WelcomeRules.leaves`; before `homeChosen` is set, so the app's own first page passes nothing).
            if startedWithFleet, !welcomePassed,
               WelcomeRules.leaves(chosen: homeChosen, fromManager: oldValue == managerPage,
                                   changed: destination != oldValue) { welcomePassed = true }
            homeChosen = true
            // The page he left opens at the next start (`keptPage`); every other page leaves none.
            let kept = Self.keptName(destination, detail: detail)
            if keptPages[hub.absoluteString] != kept { keptPages[hub.absoluteString] = kept }
            if destination != oldValue { childThreadRequest = nil; keptUnread = nil }
            // **A page that opens closes the card over the window** (`detail`), also the page that shows under it: a row
            // of the card that leads out of it (the agent's chat, the server's page, "Sign in again", a name or "Open"
            // in a request's words) opens its page, and the card would stand over it. Every writer of the page is a
            // press of the owner's, but these, which keep it: a page that only takes another name or shows as another
            // page (`stepping`: Back, Forward, a server's new name, `standIn`; `keepsDetail`: the manager's new name).
            if !stepping, !keepsDetail, detail != nil { detail = nil }
            // A secret's card over the page goes with the page that it stood over (`secretCard`).
            if destination != oldValue, secretCard != nil { secretCard = nil }
            // A chat that `setup_show` just opened keeps its mark; every other change of page ends it (`ShownPage`).
            if shown.chat != nil { shown.went(to: destination.agentTab == .chat ? destination.agentName : nil) }
            markRepliesSeen()
            // The launch's first read reads the pages; a page chosen before it needs no read of its own.
            if launched { prefetch(fleet: PagePrefetch.fleet, agent: PagePrefetch.agent) }
        }
    }
    /// The app has its first page: the one asked for, the one `home` chose from a reading, or one he went to first.
    @ObservationIgnored private var homeChosen = FleetStore.asked != nil

    /// **The detail card over the window, or nil** (`DetailCard` in FleetCore, which has the rules and their tests; the
    /// owner, 20 November 2026, of the Tasks board: "we should probably consider showing the cards here as modals once
    /// clicked instead of moving pages", and 21 November 2026: "task details to open as a modal ... even for the tasks
    /// page!"): a task or a job over the page that shows, which stays as it is under it. Every place that opened the
    /// page of a task or of a job opens it (`show(_:)` of a `DetailPlace`); `FleetView` draws it (`DetailCardView`).
    /// A new reading closes it when the hub lists what it shows no more (`state`), and a page that opens closes it
    /// (`destination`).
    var detail: DetailCard? {
        didSet {
            guard detail != oldValue else { return }
            childThreadRequest = nil
            detailHoldsEscape = false
            detailKeyForms = [:]
            // The task level is the place that he left, and opens at the next start (`keptName`).
            let kept = Self.keptName(destination, detail: detail)
            if keptPages[hub.absoluteString] != kept { keptPages[hub.absoluteString] = kept }
            // The chat under a card was not read while the card covered it (`markRepliesSeen`): it is now.
            if detail == nil { markRepliesSeen() }
        }
    }
    /// **The forms of key requests in the job level of the card**, outside its two builds (`keptKeyForm`): memory only,
    /// and they go with the card and with each change of its level.
    @ObservationIgnored var detailKeyForms: [Int: SecretValueKept] = [:]
    /// A page that takes another name while the card shows: it keeps the card (`destination`).
    @ObservationIgnored private var keepsDetail = false

    /// **Opens the detail card at `place`** (`DetailCard.showing`). `inCard`: the press is a row of the card itself (a
    /// task's row of the job level, Follow-up to, Parent task, a subtask), so a task from the job level stands over that
    /// job, and a task from the task level takes its place with the same job under it; every other opener opens the
    /// card fresh. A place that the reading does not list opens nothing: the card would have nothing to show.
    func show(_ place: DetailPlace, inCard: Bool = false) {
        guard state?.has(place) == true else { return }
        detail = DetailCard.showing(place, over: detail, inCard: inCard)
    }
    /// The back link of the task level, and Esc: the job level it came from, else the card closes.
    func detailBack() { detail = detail?.back }
    /// **Esc that reaches the card's own window** (`fleetModal`'s `escape`: a field passes it up when no button of
    /// the card took it): one level back, but never while the check of a result has its form open, whose Cancel is
    /// Esc's (`TaskDetail`): one Esc would drop the check with the level.
    func detailEscape() { if !detailHoldsEscape { detailBack() } }
    /// The card's check of a result has its form open (`TaskDetail`, `OutcomeFormOpen`).
    @ObservationIgnored var detailHoldsEscape = false
    /// Done, and a click on the dimmed window.
    func closeDetail() { detail = nil }
    /// **`setup_show`'s `task.<number>`**: the task level over the page that shows, noted as a show before the card
    /// changes, as a change of page is (`show(_:)` of a `Destination`), so no second show comes before the owner acts
    /// in the app's main window or in this card. Its name has no word of Swift's concurrency in it: the rule that
    /// `showPlace` checks and changes in one turn reads its body for none (`OwnerShowRulesTests`).
    func showLinked(_ place: DetailPlace) {
        shown.shows(nil)
        show(place)
    }

    /// **What a `setup_show` that changed the page leaves open until the owner acts in the app's main window**
    /// (`ShownPage` in FleetOwnerAPI, which has the rules and their tests; the plan "The app's pages and actions for
    /// the owner's own agent", part 2): one change of page for each click of the owner that reached the app, and the
    /// chat that a show opened does not count as read until the owner acted with that chat still on the page. The
    /// link reads it for `setup_state`'s `show`, and the app's watch reads its number of the latest show.
    private(set) var shown = ShownPage()
    /// `setup_show`'s change of page (`SetupChannel.showPlace`, after its rules): through `destination`, so that Back
    /// returns to the page before and the sidebar's row follows. It marks no chat as read.
    func show(_ page: Destination) {
        guard page != destination else { return }
        shown.shows(page.agentTab == .chat ? page.agentName : nil)
        destination = page
    }
    /// The app handled a click or a key of the owner in its main window (`AppFront.ownerHandled`). `ShownPage.handled`
    /// has the rule: a click that reached the app frees the next show; a click or a key that reached it marks the
    /// chat that a show opened as read, when it still shows; a click that the app dropped, and an event that began
    /// before the latest show, do nothing.
    func ownerHandled(_ act: ShownPage.Act) {
        guard shown.waitsForOwner || shown.chat != nil else { return }
        // A chat under the card over the window does not show (`detail`): an act in the card marks it not read.
        let chat = detail == nil && destination.agentTab == .chat ? destination.agentName : nil
        if shown.handled(act, showing: chat) { markRepliesSeen() }
    }

    /// **The pages he opened, for Back and Forward** (the owner, 3 November 2026: "2 buttons to go back and forth between
    /// pages while navigating the app, like in codex"), as a browser keeps them (`PageHistory`).
    private(set) var history = PageHistory<Destination>()
    /// A step of Back or Forward is under way: it is not a page he opened himself.
    @ObservationIgnored private var stepping = false
    var canGoBack: Bool { !history.back.isEmpty }
    var canGoForward: Bool { !history.forward.isEmpty }

    /// One page back, ⌘[: the newest page he left that can still open. **With the card over the window, Back closes
    /// it**: the page under it is the page that he opened it from, where Back from a task's page went.
    func goBack() {
        if detail != nil { closeDetail(); return }
        guard let page = history.goBack(from: destination, canOpen: canOpen) else { return }
        stepping = true; destination = page; stepping = false
    }

    /// **A place that shows as another page**: the window goes to `page`, and the history takes no step for it. An agent
    /// on a key or a model server has no chat in version 1, so its chat place shows as its detail page (review M2): an
    /// ordinary write there put the chat place on the Back list, so Back opened it, the move ran again, and Back did
    /// nothing (review N1). With this, Back goes to the page before the chat place.
    func standIn(_ page: Destination) {
        guard page != destination else { return }
        stepping = true; destination = page; stepping = false
    }

    /// One page forward, ⌘], after a step back. The card over the window closes with it, as it does for every page
    /// that opens.
    func goForward() {
        guard let page = history.goForward(from: destination, canOpen: canOpen) else { return }
        closeDetail()
        stepping = true; destination = page; stepping = false
    }

    /// **Adding a server or an agent fills the window** (the owner, 12 November 2026: "while we're adding a server or an
    /// agent, it should be like a full screen modal for the wizard? instead of showing the agents, the settings etc?",
    /// and the owner's yes to its two pictures): Add server, Add agent, the setup and "Setting up" of an agent that Add
    /// agent added on this Mac (`isAdding`) until its chat opens, and the setup of the manager of a new fleet, drawn
    /// alone, as the first run is (`AgentSetupFlow.fillsWindow`). An agent that ran before keeps its setup in its page.
    func fillsWindow(_ page: Destination) -> Bool {
        guard let state else { return false }
        switch page {
        case .addServer, .addAgent: return true
        case .agent(let name):
            return AgentSetupFlow.fillsWindow(state.agents.first { $0.name == name }, adding: isAdding(name),
                                              features: state.ui_features ?? [], placing: placing(name),
                                              serverTime: state.time, fresh: isFresh)
        default: return false
        }
    }

    /// **The agents that Add agent added on this Mac, until their chat opens** (hub address, generation and name, as
    /// `unplaced`): their setup, then their "Setting up", fill the window, also after × and after the app starts again.
    /// A fresh reading ends them (`noteAdded`); a deactivated or signed-out agent that ran before is never on it.
    private var adding = Set(AppDefaults.store.stringArray(forKey: "addingAgents") ?? []) {
        didSet { AppDefaults.store.set(adding.sorted(), forKey: "addingAgents") }
    }
    func isAdding(_ agent: String) -> Bool { state.map { adding.contains(placingKey(agent, database: $0.db)) } ?? false }
    /// Add agent handed this agent to its setup.
    func noteAdding(_ agent: String) {
        guard let database = state?.db else { return }
        adding.insert(placingKey(agent, database: database))
    }
    /// An agent whose setup ended and whose chat can answer, or that the hub no longer lists, leaves the list, and so
    /// does this hub's other generations'. Only on a reading that answered: an old one proves nothing.
    private func noteAdded(_ fresh: HubState) {
        let prefix = "\(hub.absoluteString)|"
        let here = "\(prefix)\(fresh.db)|"
        let ended = adding.filter { key in
            guard key.hasPrefix(prefix) else { return false }
            guard key.hasPrefix(here) else { return true }
            return AgentSetupFlow.addingEnds(fresh.agents.first { $0.name == String(key.dropFirst(here.count)) },
                                             features: fresh.ui_features ?? [], placing: unplaced.contains(key))
        }
        if !ended.isEmpty { adding.subtract(ended) }
    }

    /// **The × of a wizard that fills the window**: back to the newest page left before it that does not fill the
    /// window, and the wizard goes on no list (`PageHistory.leave`); Settings › Servers from Add server, or the home
    /// page, when there is none. What runs goes on: a server being made or installed (Add server opens on it again), and
    /// the install of an agent being added, whose row opens its setup again.
    func closeWizard() {
        let wizard = destination
        let page = history.leave(from: wizard) { self.canOpen($0) && !self.fillsWindow($0) }
        let home = FleetStore.home(state)
        stepping = true
        destination = page ?? (wizard == .addServer ? .settings(.servers) : fillsWindow(home) ? .agents : home)
        stepping = false
    }

    /// A page of an agent the hub no longer lists cannot open again: Back passes over it.
    private func canOpen(_ page: Destination) -> Bool {
        guard let state else { return true }
        if let agent = page.agentName { return state.agents.contains { $0.name == agent } }
        // His Tailscale key page of Turn on is a page only while that turn waits for the key: Back and Forward pass
        // over it afterwards, so that no token is pasted into a page that would drop it.
        if page == .connectKey { return connectSwitch().run == .keyPage }
        return true
    }

    /// **Where the app opens** (the owner's yes of 28 October 2026 to D-4): Needs you while a request of the manager is
    /// open, else the manager's chat. The Dashboard it opened on is gone; the sidebar is the one list of the agents.
    static func home(_ state: HubState?) -> Destination {
        if state?.needs.contains(where: \.isOpen) == true { return .needs }
        return .agent(state?.agents.first { $0.role == "manager" }?.name ?? "manager")
    }

    /// Opens the first page once there is a reading to choose it from: the one this Mac kept, in the first frame, or the
    /// launch's first answer. A page he opened before it stays. The page he left at his last quit comes first, when
    /// this start may open it (`keptPage`).
    private func chooseHome() {
        guard !homeChosen, state != nil else { return }
        // The card of the page he left, read before the page itself writes the name of the page that it opens.
        let card = keptDetail()
        destination = keptPage() ?? Self.home(state)
        if let card { detail = DetailCard(card) }
    }

    /// **The page he left, by hub address** (the owner's "Build ideas 1–5" of 16 November 2026, of "The app opens on
    /// the page you left when you quit"; it opened on `home` each time): its name of `-openPage` (`keptName`), kept on
    /// this Mac for the next start.
    private var keptPages = AppDefaults.store.dictionary(forKey: "lastPages") as? [String: String] ?? [:] {
        didSet { AppDefaults.store.set(keptPages, forKey: "lastPages") }
    }

    /// The name of a page that the next start may open (`page(named:)` reads it back), or nil: only the places that
    /// `setup_show` opens (`SetupShow.targetForms`), whose pages do nothing by themselves when they show. **A task's card
    /// is the place that he left**, as its page was: `task.<id>`, which opens that task's card over Tasks
    /// (`detail(named:)`); a job's card is not, and the page under it is.
    static func keptName(_ page: Destination, detail: DetailCard?) -> String? {
        if let task = detail?.shown.task { return "task.\(task)" }
        switch page {
        case .needs: return "needs"
        // Tasks that an agent's panel opened opens at the next start as Tasks, with no back link.
        case .activity, .activityFrom: return "tasks"
        case .agents: return "agents"
        case .agent(let name): return "agent.\(name)"
        case .agentDetail(let name, let tab) where [.behaviour, .tasks, .people, .canUse].contains(tab):
            return "agent.\(name).\(tab.rawValue)"
        case .settings(let tab) where ![.servers, .backup].contains(tab): return "settings.\(tab.rawValue)"
        default: return nil
        }
    }

    /// **The page he left, when this start may open it**: a page that a kept setting names opens only as a place of
    /// `setup_show` would, as it shows now and with its checks (`SetupChannel.opensAtStart`), so never a setup, a wizard
    /// or a page that acts by itself when it shows (`asked` says why). Not the chat of an agent whose chat place shows
    /// its Runs on (`chatShowsDetail`), not while the manager's setup fills the window, which its welcome page may
    /// cover (`welcomeCovers`), and not Needs you with nothing in it: then `home` decides.
    private func keptPage() -> Destination? {
        guard let name = keptPages[hub.absoluteString], let page = Self.page(named: name),
              managerPage.map({ !fillsWindow($0) }) ?? true, canOpen(page), !fillsWindow(page),
              SetupChannel.opensAtStart(page, in: self) else { return nil }
        if case .agent(let agent) = page, chatShowsDetail(agent) { return nil }
        if page == .needs, state?.needs.contains(where: \.isOpen) != true { return nil }
        return page
    }

    /// **The task's card of the page he left** (`task.<id>`), when this start may open it: over Tasks, which `keptPage`
    /// opens for that name by its own checks, and only for a task that the reading has.
    private func keptDetail() -> DetailPlace? {
        guard let name = keptPages[hub.absoluteString], let place = Self.detail(named: name),
              keptPage() == .activity, state?.has(place) == true else { return nil }
        return place
    }
    /// The newest chat reply that the owner has seen from each agent, for one hub generation (`seenContext`).
    private var seenReplies: [String: Int] = [:]
    @ObservationIgnored private var seenContext = ""
    /// An agent whose chat he marked unread while that chat was open. An open chat counts as read, so without this
    /// the next reading would take his mark away again under his pointer; it stays until he goes to another page.
    @ObservationIgnored private var keptUnread: String?
    /// The agents he pinned to the top of the sidebar, newest pin first, by hub address. This Mac keeps them.
    private var pins = AppDefaults.store.dictionary(forKey: "pinnedAgents") as? [String: [String]] ?? [:]
    /// The open task's thread as it was read last (`TaskActivity`). Its panel draws from it the files the task
    /// changed, its child agents and the runtimes and models it used, so a task opened again has them in its first
    /// frame, and one of another task or generation is never drawn.
    private var taskActivity: TaskActivity? { currentTask.flatMap { reading(TaskActivity.name($0.id)) } }
    var taskFiles: [FileChange] { taskActivity?.files ?? [] }
    var taskChildren: [TaskChild] { taskActivity?.children ?? [] }
    var taskRuntimes: [Int: Set<String>] { taskActivity?.timeline.runtimes ?? [:] }
    var taskModels: [RuntimeModelUse] { taskActivity?.timeline.models ?? [] }
    var childThreadRequest: RuntimeToolKey?
    var selectedNeed: Int?
    /// **The card of a chat whose Needs clarification field is open, with its words** (owner feature `need_clarify`;
    /// the owner, 21 November 2026, of his first message under a card: "I clicked on discuss and typed, dont remember
    /// where", and his words went to the chat's box): a key that the chat would send to its box goes to that field
    /// (`FleetView.typeIntoBox`), and `clarifyKeys` tells the field to take the keyboard. Memory only.
    var clarifying: (need: Int, words: String)?
    /// A count that the open Needs clarification field of a chat watches: at each change it takes the keyboard.
    var clarifyKeys = 0
    /// A message of one agent's chat that the chat scrolls to as it shows, then forgets: a match of the search card
    /// (`SearchPalette`, "In messages").
    var chatFocus: ChatFocus?
    private(set) var secretRefusals = 0
    /// Add secret over the window, from a chat's key button or from the guard of a pasted key: memory only, because a
    /// pasted key is in it until the form takes it.
    var secretForm: SecretPreset?
    /// **A secret's own card over the page where he is** (`showSecret(named:)`, `SecretsPage(card:)`): the key badge of
    /// a request's card opens it. Memory only. A change of page closes it (`destination`), and nothing else moves: Done,
    /// Esc and a click outside leave him on the page that he was on.
    var secretCard: SecretCard?
    /// The question of the guard of a pasted or typed key, for one composer.
    var heldKey: HeldKey?
    var editingMessage: OwnerMessage?
    var editText = ""
    /// **Each correction that opens is one of its own** (`beginEdit`): the guard of a key keeps his "Keep it" for it
    /// alone (`correctionKey`), and a press that waits goes only while it is still open (`sendEdit`). A new correction
    /// of the same message is another one.
    private(set) var editID = UUID()
    /// Rename… or Deactivate from an agent's row (`AgentMenu`): its Runs on takes it when it opens, and clears it.
    var agentAction: AgentActionRequest?
    /// Delete… from an agent's menu: its confirmation stands over the window until he answers it (`AgentDeleteCard`).
    var deleting: AgentDeleteRequest?
    /// The knowledge file whose text Settings › Knowledge opens, asked by the eye of a file's card on an agent's Can use
    /// or by a press of the file's badge in a request's words (`openCardLink`): the page takes it when it shows, and
    /// clears it.
    var knowledgeRead: String?
    var agentDrafts: [String: String] {
        didSet { AppDefaults.store.set(agentDrafts, forKey: "agentDrafts") }
    }
    /// **The words of each task's guidance box** (`TaskSteering`), by its key (`stageKey(task:database:)`): the store's,
    /// as a chat's draft is, so a guidance that a later read confirms also empties its box (`finish`), and a second
    /// press cannot send it again.
    var guidanceDrafts: [String: String] = [:]
    /// **The words of each card's feedback box** (`FeedbackBox`), by its key (`stageKey(about:database:)`): what the
    /// message is about, so the draft of a task's or a job's card stays through a change of the card's level and a
    /// close of the card, as a guidance's draft stays with its task, and the hub's receipt empties it (`finish`).
    var feedbackDrafts: [String: String] = [:]
    /// **The badge of what his message is about, in the agent's chat** (`HubState.badge(about:jobs:)`, `AboutBadgeView`).
    /// A badge reads the jobs of the board of every agent (a job's name and mark, and whether later work took a task
    /// over), which are worked out once for each reading, and only when a message names a task or a job that the reading
    /// has: each draw of a message would work out the whole board again.
    func aboutBadge(_ about: MessageAbout) -> AboutBadge? {
        guard let state else { return nil }
        return state.badge(about: about, jobs: jobsByTask(of: state))
    }
    private func jobsByTask(of state: HubState) -> [Int: Job] {
        if let kept = jobsKept, kept.reading == readingCount { return kept.jobs }
        let jobs = state.jobsByTask
        jobsKept = (readingCount, jobs)
        return jobs
    }
    @ObservationIgnored private var jobsKept: (reading: Int, jobs: [Int: Job])?
    var supportsDirectChat: Bool { state?.ui_features?.contains("direct_chat") == true }
    func canChat(with agent: String) -> Bool { state?.supportsChat(with: agent) == true }
    var supportsCorrections: Bool { state?.ui_features?.contains("corrections") == true }
    /// **The @ tags of a chat with `agent`** (owner feature `agent_tags`, API 1.288; `AgentTags`): every other agent of
    /// the team, in the sidebar's order (`ChatList.order`). Nil on a hub without the feature, where the box opens no
    /// list and a message sends no `mentions`. **Made again only when what it is made of changes** (`tagBook`): the box
    /// asks for it at each key of words with an "@".
    func agentTags(except agent: String) -> AgentTags? {
        guard state?.ui_features?.contains(AgentTags.feature) == true, let agents = state?.agents else { return nil }
        let order = ChatList.order(agents.map(\.name), pinned: pinned)
        let titles = Dictionary(agents.map { ($0.name, $0.title) }, uniquingKeysWith: { first, _ in first })
        var hasher = Hasher()
        hasher.combine(agent)
        for name in order { hasher.combine(name); hasher.combine(titles[name] ?? nil) }
        let key = hasher.finalize()
        if let kept = tagBook, kept.key == key { return kept.tags }
        let tags = AgentTags(agents: order.map { (name: $0, role: titles[$0] ?? nil) }, except: agent)
        tagBook = (key, tags)
        return tags
    }
    /// The last table of `agentTags(except:)`, with the key of what it was made of.
    @ObservationIgnored private var tagBook: (key: Int, tags: AgentTags)?
    func draft(for agent: String) -> String { agent == "manager" ? draft : agentDrafts[agent] ?? "" }
    func setDraft(_ text: String, for agent: String) {
        if agent == "manager" { draft = text } else { agentDrafts[agent] = text }
    }
    // MARK: The files that the owner picked (owner feature attachments)

    /// One file that the owner picked for one composer. Its own number is the number of its upload, so a repeat is
    /// one file on the hub and never a second one.
    struct StagedFile: Codable, Identifiable, Equatable, Sendable {
        let requestID: UUID
        let name: String
        let mime: String
        let size: Int
        var attachmentID: Int?
        var failure: String?
        /// When the hub took its upload, by the hub's own clock (`MessageAttachment.created`); nil for a file that is
        /// not on the hub, or one that an older version of this app kept.
        var hubCreated: Double?
        /// Another read on upload can find a replaced or restored file under this request id.
        var previewRead: UUID?
        /// **A skill that he gives the agent** (owner feature `message_skills`; `SkillPackage`): its name, which the chip
        /// shows with the bolt in place of the ZIP's name. nil for every other file, and for one that a version before it
        /// kept.
        var skill: String?
        enum CodingKeys: String, CodingKey { case requestID, name, mime, size, attachmentID, failure, hubCreated, skill }
        var id: UUID { requestID }
        var isOnHub: Bool { attachmentID != nil }
    }

    /// **How long an upload stays the file that its number names**: the hub lets a file that no message carries go an
    /// hour after its upload (`hub.py` `ATTACH_WAIT`), and a later upload can then get the same number. So a file that
    /// went up longer ago than this goes up again before it is sent (`freshFiles`), with a margin for the sweep's
    /// ten minutes and the send itself.
    static let uploadStaysFor: Double = 45 * 60

    var supportsAttachments: Bool { state?.ui_features?.contains("attachments") == true }
    /// The hub takes Word, Excel and PowerPoint files from the owner too (owner feature `office_files`, UI-API.md 1.251).
    var supportsOfficeFiles: Bool { state?.ui_features?.contains("office_files") == true }
    /// **The composer takes a skill that he gives** (owner feature `message_skills`): a chat's box, on a hub that lists
    /// the feature (the owner's "Yes, as drawn" of 22 November 2026 names the chat box). Elsewhere, and until the hub
    /// lists it, a skill's ZIP is a file and a folder is a type that the hub does not take, as before.
    func takesSkills(_ composer: String) -> Bool {
        state?.ui_features?.contains(SkillPackage.feature) == true && composer.hasPrefix("agent:")
    }
    /// The skill's name of a staged file, while its composer takes skills: its chip shows the bolt and this name, and
    /// the message gives it. nil for a file that goes as a file.
    func skillName(of file: StagedFile, in composer: String) -> String? { takesSkills(composer) ? file.skill : nil }
    /// The composer of one chat, or of one open request of Needs you.
    static func stageKey(agent: String) -> String { "agent:\(agent)" }
    static func stageKey(need: Int) -> String { "need:\(need)" }
    /// The box of the open correction, for the guard of a key (`KeyHoldBanner`) only: a correction takes no file, and its
    /// request's files are the chat's (`stageKey(of:)`). It is the correction's own (`editID`), never its message's: a
    /// "Keep it" of an earlier correction of the same message does not let a key of a later one go with no question.
    var correctionKey: String { "correction:\(editID.uuidString)" }
    /// The composer of one task's guidance (owner API 1.223, feature `steer_files`), with its hub's database: a task
    /// of another database with the same number never shows these files.
    static func stageKey(task: Int, database: String) -> String { "task:\(database):\(task)" }
    /// The composer of the feedback on a card (owner feature `message_about`), by what it is about, with its hub's
    /// database.
    static func stageKey(about place: MessagePlace, database: String) -> String {
        switch place {
        case .task(let id): "about:\(database):task:\(id)"
        case .job(let id): "about:\(database):job:\(id)"
        }
    }
    /// The composer whose files a request carries: a guidance's, a request's answer's, a card's feedback's or a chat's.
    static func stageKey(of request: PendingRequest) -> String {
        if case .steer(let task, _) = request.command { return stageKey(task: task, database: request.database) }
        // a correction of a feedback message is the chat's: it takes no file and no draft of the card's box
        if let about = request.about, request.needID == nil, request.replacesRequestID == nil {
            return stageKey(about: about, database: request.database)
        }
        return request.needID.map { stageKey(need: $0) } ?? stageKey(agent: request.recipient ?? "manager")
    }

    /// The composer of this task's guidance, or nil while it takes no file (`FleetTask.guidanceTakesFiles`).
    func guidanceComposer(for task: FleetTask) -> String? {
        guard let state, task.guidanceTakesFiles(in: state) else { return nil }
        return Self.stageKey(task: task.id, database: state.db)
    }

    /// The task of a guidance's composer in the current database, or nil for any other composer.
    private func guidanceTask(_ composer: String) -> FleetTask? {
        guard let state, composer.hasPrefix("task:\(state.db):"),
              let id = Int(composer.dropFirst("task:\(state.db):".count)) else { return nil }
        return state.tasks.first { $0.id == id }
    }

    /// The files that this composer takes (`FleetTask.guidanceFiles`): every kind, but in the guidance of a task whose
    /// session opens only some.
    func filesTaken(by composer: String) -> GuidanceFiles { guidanceTask(composer)?.guidanceFiles(in: state) ?? .any }

    /// Why this composer refuses a kind of file, or nil while it takes every kind.
    func refusedKindWords(_ composer: String) -> String? {
        switch filesTaken(by: composer) {
        case .any: nil
        case .shown: String(l10n: "This agent's Shell box is off: it opens only pictures and text files.")
        case .texts: String(l10n: "This agent opens only text files: its Shell box is off, and its AI program shows no pictures.")
        }
    }

    /// The words of a picture too large for a tool's answer, in a box whose session has no shell.
    private var largePictureWords: String {
        String(l10n: "This picture is too large for this agent, whose Shell box is off: take it out and pick it again.")
    }

    /// **Why this composer holds a file that it takes no more**, or nil: the agent's Shell box went off after the owner
    /// picked it, and its kind, or a picture's size, is more than its session opens. Picked again, a picture is made
    /// small enough (`imageForSending`).
    func refusedFileWords(_ composer: String) -> String? {
        let taken = filesTaken(by: composer), files = stagedFiles(for: composer)
        // a Word, Excel or PowerPoint file that waits while its hub no longer takes them (`office_files` went away)
        if files.contains(where: { !MessageAttachment.sendable($0.mime, office: supportsOfficeFiles) }) {
            return MessageAttachment.typeWords(office: supportsOfficeFiles)
        }
        if files.contains(where: { !taken.takes($0.mime) }) { return refusedKindWords(composer) }
        if taken == .shown, files.contains(where: { $0.mime.hasPrefix("image/") && $0.size > MessageAttachment.shownPictureBytes }) {
            return largePictureWords
        }
        return nil
    }

    /// The words of the most files that one composer sends at once: a message's, or a guidance's.
    func atMostFiles(_ composer: String) -> String {
        composer.hasPrefix("task:") ? String(l10n: "Guidance carries at most \(MessageAttachment.perMessage) files.")
                                    : String(l10n: "A message carries at most \(MessageAttachment.perMessage) files.")
    }
    func stagedFiles(for composer: String) -> [StagedFile] { staged[composer] ?? [] }
    func readyFiles(for composer: String) -> [Int] { stagedFiles(for: composer).compactMap(\.attachmentID) }
    /// A file that is not on the hub, or a skill whose gift the hub refused (`skillRefused`): its chip says why, and
    /// Send waits until he takes it out.
    func filesAreWaiting(for composer: String) -> Bool {
        stagedFiles(for: composer).contains { !$0.isOnHub || $0.failure != nil }
    }
    func composerOf(_ file: StagedFile) -> String? {
        staged.first { $0.value.contains(where: { $0.requestID == file.requestID }) }?.key
    }

    /// The owner picked a file. The bytes are written beside the Outbox **before** anything is sent, then the file
    /// goes up with its own number; the message that carries it names only that number.
    func stage(_ data: Data, name: String, mime: String, for composer: String, skill: String? = nil) async {
        guard storageError == nil else { return }
        guard stagedFiles(for: composer).count < MessageAttachment.perMessage else {
            fileErrors[composer] = atMostFiles(composer)
            return
        }
        guard MessageAttachment.sendable(mime, office: supportsOfficeFiles) else {
            fileErrors[composer] = MessageAttachment.typeWords(office: supportsOfficeFiles)
            return
        }
        // A dropped or pasted file takes the same rule as the plus's own list.
        guard filesTaken(by: composer).takes(mime) else {
            fileErrors[composer] = refusedKindWords(composer)
            return
        }
        guard filesTaken(by: composer) != .shown || !mime.hasPrefix("image/") || data.count <= MessageAttachment.shownPictureBytes
        else {
            fileErrors[composer] = largePictureWords
            return
        }
        guard !data.isEmpty, data.count <= MessageAttachment.sizeLimit else {
            fileErrors[composer] = AttachmentError.tooLarge.errorDescription
            return
        }
        let file = StagedFile(requestID: UUID(), name: MessageAttachment.safeName(name, mime: mime), mime: mime,
                              size: data.count, skill: skill)
        do {
            try FileManager.default.createDirectory(at: stagedDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: stagedURL(file), options: [.atomic])
        } catch {
            fileFailed(String(l10n: "Cannot keep this file on this Mac. Nothing was sent."), cause: error, for: composer)
            return
        }
        staged[composer, default: []].append(file)
        keepStaged()
        await upload(file, for: composer)
    }

    /// One file from a place on this Mac: a picture becomes the bytes that travel well, another file goes as it is. **A
    /// skill's folder or ZIP, in a box that takes skills, is a skill** (`takesSkills`, `SkillPackage`): the folder
    /// becomes one ZIP first; any other folder gets the words of a type that the hub does not take, as before.
    func stage(contentsOf url: URL, for composer: String) async {
        if takesSkills(composer) {
            let opened = url.startAccessingSecurityScopedResource()
            defer { if opened { url.stopAccessingSecurityScopedResource() } }
            if SkillPackage.isSkillFolder(url) {
                await stageSkill(folder: url, for: composer)
                return
            }
        }
        guard let mime = MessageAttachment.mime(forName: url.lastPathComponent, office: supportsOfficeFiles) else {
            fileErrors[composer] = MessageAttachment.typeWords(office: supportsOfficeFiles)
            return
        }
        let opened = url.startAccessingSecurityScopedResource()
        defer { if opened { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            fileErrors[composer] = String(l10n: "That file did not open.")
            return
        }
        let shown = filesTaken(by: composer) == .shown
        if mime.hasPrefix("image/"), let picture = try? MessageAttachment.imageForSending(data, shown: shown) {
            await stage(picture.data, name: url.lastPathComponent, mime: picture.mime, for: composer)
        } else if mime.hasPrefix("image/"), shown {
            // A picture that could not be made small enough would not reach a session with no shell as it is.
            fileErrors[composer] = String(l10n: "That file did not open.")
        } else {
            // a ZIP whose SKILL.md stands at its root or under its one top folder is a skill (`SkillPackage.isSkill`)
            let skill = mime == "application/zip" && takesSkills(composer)
                ? SkillPackage.name(inZip: data, fileName: url.lastPathComponent) : nil
            await stage(data, name: url.lastPathComponent, mime: mime, for: composer, skill: skill)
        }
    }

    /// **A skill's folder becomes one ZIP, staged as a skill** (`SkillPackage.zip`), off the main thread: its copy and
    /// the Mac's ZIP of it read the disk. Its name is its `SKILL.md`'s, else the folder's. Plain files of more than a
    /// file's limit get the words of a file too large, and a folder that the Mac does not read or zip the words of a
    /// file that did not open.
    private func stageSkill(folder: URL, for composer: String) async {
        guard storageError == nil else { return }
        guard stagedFiles(for: composer).count < MessageAttachment.perMessage else {
            fileErrors[composer] = atMostFiles(composer)
            return
        }
        let made = await Task.detached(priority: .userInitiated) { () -> Result<(Data, String), SkillPackage.FolderRefusal> in
            do { return .success((try SkillPackage.zip(folder: folder, atMost: MessageAttachment.sizeLimit),
                                  SkillPackage.name(ofFolder: folder))) }
            catch { return .failure(error as? SkillPackage.FolderRefusal ?? .unreadable) }
        }.value
        switch made {
        case .success(let (data, name)):
            await stage(data, name: folder.resolvingSymlinksInPath().lastPathComponent + ".zip", mime: "application/zip",
                        for: composer, skill: name)
        case .failure(.tooLarge): fileErrors[composer] = AttachmentError.tooLarge.errorDescription
        case .failure(.unreadable): fileErrors[composer] = String(l10n: "That file did not open.")
        }
    }

    /// Sends one staged file up, with its own number. A file that is already on the hub never goes again.
    func upload(_ file: StagedFile, for composer: String) async {
        guard let state, !file.isOnHub, !uploading.contains(file.requestID) else { return }
        // Only a regular file of a staged file's size is read, with no wait (`KeptFile`). A larger file there is not
        // one that this app staged: it gets the words that the upload gave it before, with no read of it.
        func readForUpload(_ failure: String?) {
            change(file, in: composer) {
                $0.failure = failure
                if $0.mime.hasPrefix("image/") { $0.previewRead = UUID() }
            }
        }
        let found = KeptFile.read(stagedURL(file), atMost: MessageAttachment.sizeLimit)
        if found == .refused(.tooLarge) {
            readForUpload(AttachmentError.tooLarge.errorDescription)
            return
        }
        guard case .bytes(let data) = found else {
            readForUpload(String(l10n: "The bytes of this file are gone. Pick it again."))
            return
        }
        uploading.insert(file.requestID)
        defer { uploading.remove(file.requestID) }
        readForUpload(nil)
        do {
            let sent = try await client.upload(data, name: file.name, mime: file.mime, requestID: file.requestID,
                                               client: installation, hub: hub, database: state.db)
            change(file, in: composer) { $0.attachmentID = sent.id; $0.hubCreated = sent.created; $0.failure = nil }
        } catch {
            change(file, in: composer) {
                $0.failure = (error as? LocalizedError)?.errorDescription ?? String(l10n: "The file did not go up.")
            }
        }
    }

    func removeStaged(_ file: StagedFile, for composer: String) {
        guard !uploading.contains(file.requestID) else { return }
        try? FileManager.default.removeItem(at: stagedURL(file))
        staged[composer] = stagedFiles(for: composer).filter { $0.requestID != file.requestID }
        if staged[composer]?.isEmpty == true { staged[composer] = nil }
        keepStaged()
    }

    /// **The numbers of a composer's files, each one still the file that the hub holds under it**: a file that went
    /// up longer ago than `uploadStaysFor` goes up again first, under its own request number, so the hub makes a new
    /// row for it once its sweep took the old one. nil while a file is not on the hub, or did not go up again: its
    /// chip says why, and Send stays.
    func freshFiles(for composer: String) async -> [Int]? {
        let now = state?.time ?? 0
        for file in stagedFiles(for: composer) where file.isOnHub && now - (file.hubCreated ?? 0) > Self.uploadStaysFor {
            change(file, in: composer) { $0.attachmentID = nil; $0.hubCreated = nil }
            if let again = stagedFiles(for: composer).first(where: { $0.requestID == file.requestID }) {
                await upload(again, for: composer)
            }
        }
        guard !filesAreWaiting(for: composer) else { return nil }
        return readyFiles(for: composer)
    }

    /// **A task's box that can send no more keeps no file**: its task ended or is now a person's, or it belongs to
    /// another database, whose numbers name other files. Their bytes would stay on this Mac with nothing to send them.
    /// A task that the reading does not list keeps its box: a reading need not list every task.
    private func dropUnsendableGuidanceFiles() {
        guard let state else { return }
        let here = "task:\(state.db):"
        for composer in Array(staged.keys) where composer.hasPrefix("task:") {
            if composer.hasPrefix(here), let id = Int(composer.dropFirst(here.count)) {
                let task = state.tasks.first { $0.id == id }
                guard task?.isTerminal == true || task?.from_conversation == true else { continue }
            }
            for file in stagedFiles(for: composer) { removeStaged(file, for: composer) }
            fileErrors[composer] = nil
        }
    }

    /// The files that the hub took leave the composer; one that the owner picked while the message was on its way
    /// stays for the next message.
    private func clearStaged(_ composer: String, sent: [Int]) {
        guard !sent.isEmpty else { return }
        for file in stagedFiles(for: composer) where file.attachmentID.map(sent.contains) == true {
            try? FileManager.default.removeItem(at: stagedURL(file))
        }
        staged[composer] = stagedFiles(for: composer).filter { file in
            file.attachmentID.map { !sent.contains($0) } ?? true
        }
        if staged[composer]?.isEmpty == true { staged[composer] = nil }
        keepStaged()
    }

    /// **The hub refused the gift of a skill** (`refused_gift`, owner API 1.304: the number of its ZIP; what the skill
    /// holds, such as a link, no SKILL.md or a login, or what its agent cannot take): that skill's chip says so, as a
    /// failed file's chip does, and Send waits until he takes it out (`filesAreWaiting`). The request is refused as any
    /// message is, with the hub's words. **A 409 or a 5xx leaves the chip as it is**: it can follow a gift that landed,
    /// or a hub that was busy, and the same skill sent again is given from its same bytes.
    private func skillRefused(_ request: PendingRequest, _ refusal: HubRefusal) {
        guard let gift = refusal.refusedGift, request.givenFiles.contains(gift), refusal.status < 500,
              refusal.status != 409 else { return }
        let box = Self.stageKey(of: request)
        for file in stagedFiles(for: box) where file.attachmentID == gift {
            change(file, in: box) { $0.failure = refusal.words }
        }
    }

    private func change(_ file: StagedFile, in composer: String, _ edit: (inout StagedFile) -> Void) {
        guard var list = staged[composer],
              let at = list.firstIndex(where: { $0.requestID == file.requestID }) else { return }
        edit(&list[at])
        staged[composer] = list
        keepStaged()
    }

    private func keepStaged() {
        guard let data = try? JSONEncoder().encode(staged) else { return }
        AppDefaults.store.set(data, forKey: "stagedFiles")
    }

    func stagedURL(_ file: StagedFile) -> URL {
        stagedDirectory.appendingPathComponent(file.requestID.uuidString.lowercased())
    }

    /// The bytes held for this file, for a view that draws them (`PictureTile`): only bytes whose read checked this
    /// file's size and SHA-256. A number can name another file: the hub can give a number again after its file went.
    func heldBytes(of file: MessageAttachment) -> Data? {
        guard let data = fileData[file.id], data.count == file.size, fileSums[file.id] == file.sha256 else { return nil }
        return data
    }

    /// The bytes of one file of a message, for the chat that shows it. Nothing is kept before its size and its
    /// SHA-256 match what the hub said.
    func load(_ file: MessageAttachment) async {
        // Bytes held under this number for another file go, so that this file is read.
        if fileData[file.id] != nil, heldBytes(of: file) == nil {
            fileData[file.id] = nil
            fileSums[file.id] = nil
            fileOrder.removeAll { $0 == file.id }
        }
        guard let state, fileData[file.id] == nil, !fileReads.contains(file.id) else { return }
        let generation = filesGeneration
        fileReads.insert(file.id)
        defer { if generation == filesGeneration { fileReads.remove(file.id) } }
        do {
            let data = try await client.attachment(file, hub: hub, database: state.db)
            // A read that a change of hub or database overtook keeps nothing: its number names another file now.
            guard generation == filesGeneration else { return }
            fileData[file.id] = data
            fileSums[file.id] = file.sha256
            fileOrder.append(file.id)
            while fileOrder.count > 16, let oldest = fileOrder.first {
                fileData[oldest] = nil
                fileSums[oldest] = nil
                fileOrder.removeFirst()
            }
            unloadedFiles.remove(file.id)
        } catch {
            if generation == filesGeneration { unloadedFiles.insert(file.id) }
        }
    }

    /// The bytes of one file of a message for a press on it (open, save): read now, or by the read that is already on
    /// its way, such as the one that its row started when it came on the screen. nil when the read failed.
    func bytes(of file: MessageAttachment) async -> Data? {
        // Bytes held under this number that are not this file's go, and the file is read: a new fleet numbers its
        // files from 1 again, and open, save and a drag would give out the other file.
        if let held = fileData[file.id] {
            if file.matches(held) { return held }
            fileData[file.id] = nil
            fileOrder.removeAll { $0 == file.id }
        }
        await load(file)
        while fileData[file.id] == nil, fileReads.contains(file.id) {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return nil }
        }
        return fileData[file.id].flatMap { file.matches($0) ? $0 : nil }
    }

    // MARK: Keeping a file he attached (owner feature attachment_knowledge)

    /// Whether this hub takes either way of keeping a file (`attachment_knowledge`, UI-API.md 1.30 and 1.31). One
    /// name gates both controls, because the two are one promise to him -- this file stays -- and a hub that serves
    /// one serves the other.
    var supportsKeptFiles: Bool { state?.ui_features?.contains("attachment_knowledge") == true }

    /// The files whose keeping is being sent now, so a second press cannot send a second command.
    private(set) var keeping: Set<Int> = []

    /// The hub keeps this file past the ninety days, or stops keeping it (`POST /ui/attachments/<id>/keep`). It is
    /// the way to keep what cannot become a knowledge file -- a picture, a mockup, a zip, a PDF -- and, pressed
    /// again, the way back: a kept file otherwise stays in that folder for ever, and that folder is in no copy.
    func keep(_ file: MessageAttachment, _ on: Bool) async {
        await keepingWork(file) { [self] state in
            _ = try await client.keep(file, on, client: installation, hub: hub, database: state.db)
        }
    }

    /// The words of this text file become one of his own knowledge files, and the original is kept with it (`POST
    /// /ui/knowledge` `{attachment}`). The hub takes the title from the file's own first heading, or from its name.
    func keepAsKnowledge(_ file: MessageAttachment) async {
        await keepingWork(file) { [self] state in
            _ = try await knowledge.add(attachment: file.id, hub: hub, database: state.db, client: installation)
        }
    }

    /// One press of either control: once at a time for one file, the hub's own words where it refused, and the
    /// state read again, because the mark the chat draws is `kept` on the attachment of that message.
    private func keepingWork(_ file: MessageAttachment, _ send: (HubState) async throws -> Void) async {
        guard let state, supportsKeptFiles, !keeping.contains(file.id) else { return }
        keeping.insert(file.id)
        defer { keeping.remove(file.id) }
        // After a change of hub or database the number is another file's: its line is not this press's.
        let generation = filesGeneration
        do {
            try await send(state)
            if generation == filesGeneration { fileProblems[file.id] = nil }
            await refresh()
        } catch {
            guard generation == filesGeneration else { return }
            fileProblems[file.id] = HubError.said(error) ?? String(l10n: "This file could not be kept. Try again.")
        }
    }

    /// His newest message of one agent's chat: the one that "Correcting your last message" and ↑ in an empty box take.
    /// nil while the one that the hub just took is not in the reading yet (until the next read): the newest is then
    /// not known, and the one before it is not his last.
    func newestMessage(to agent: String) -> OwnerMessage? {
        guard let state else { return nil }
        if let taken = lastReceipt, taken.replaces_request_id == nil, (taken.recipient ?? "manager") == agent,
           !state.messages.contains(where: { $0.request_id.caseInsensitiveCompare(taken.request_id) == .orderedSame }) {
            return nil
        }
        return state.messages.filter { $0.kind == "message" && $0.chatRecipient == agent }.max { $0.created < $1.created }
    }

    func canEdit(_ message: OwnerMessage) -> Bool {
        supportsCorrections && message.kind == "message" && message.client == installation && canWrite && canChat(with: message.chatRecipient)
    }
    /// Owner feature `edit_in_place`: the arrow changes this message where it stands, instead of sending a
    /// correction under it. The button is on for both, because the hub takes both.
    func editsInPlace(_ message: OwnerMessage) -> Bool { state?.editsInPlace(message) == true }
    /// What the arrow says it will do. A Needs-you answer keeps its own words: it is no chat message, and the
    /// button is off for it.
    func editHelp(_ message: OwnerMessage) -> String {
        message.kind == "answer" ? String(l10n: "This request was already answered") : state?.editHelp(message) ?? String(l10n: "Correct")
    }
    func beginEdit(_ message: OwnerMessage) {
        guard canEdit(message) else { return }
        editText = message.text
        editingMessage = message
        editID = UUID()
    }
    func cancelEdit() { editingMessage = nil; editText = "" }
    /// Sends the correction that is open, with `words`: the words of his press, which the press checked for a key
    /// (`FleetView.sendCorrection`); nil takes the box's words now. **The press decides once**: a write that is on its
    /// way when the press comes makes the correction wait, as a held answer waits (`writable`), and then it goes only
    /// while the same correction is open with the words of the press. When he changed the box meanwhile (a key that he
    /// kept and then took out, more words), pressed Cancel, or opened another correction, nothing goes, and the box
    /// keeps what he wrote for a new press, as a quick reply does not send words that he changed while it waited
    /// (`NeedRequestCard.sendQuickReply`). The hub's confirmation closes the correction (`finish`); a send that did not
    /// go leaves the box and its words as they are. Until 22 November 2026 a send refused by its own checks emptied the
    /// box, and nothing went.
    func sendEdit(_ words: String? = nil) async {
        guard editingMessage != nil else { return }
        let edit = editID, words = words ?? editText
        guard await writable(), editID == edit, let message = editingMessage, editText == words, canEdit(message)
        else { return }
        // a correction is about what its message is about (`HubState.correctionAbout`), and goes also where it is not
        await sendText(words, recipient: message.chatRecipient, replaces: message.id,
                       about: state?.correctionAbout(of: message))
    }
    var chatAgent: String {
        if case .agent(let name) = destination { return name }
        return "manager"
    }
    var addressText: String
    private(set) var hub: URL
    private(set) var pending: PendingRequest?
    private(set) var refreshing = false
    /// A request of this Mac is on its way to the hub.
    ///
    /// **It is set where `pending` is set, and not only inside `transmit`.** Those two lines have an `await`
    /// between them, so a frame can be drawn in the gap — and in that frame there is a saved request that nothing
    /// is sending, which is what the screen draws a recovery panel for. The owner saw that panel blink over his
    /// text box on every message he sent (20 October 2026). Setting both together closes the gap: no frame can
    /// ever see one without the other.
    private(set) var sending = false
    private(set) var connectionError: String?
    /// The reads of `/ui/state` that failed in a row; the connection error waits for enough of them (`HubReach.tells`).
    @ObservationIgnored private var failedReads = 0
    /// Why the last read of `/ui/state` failed, or nil after one that answered: the first run tries again only a hub
    /// that refused at once (`HubReach.worthAgain`).
    @ObservationIgnored private(set) var lastReadError: Error?
    /// **The last read of `/ui/state` failed**: the reading is old because the hub refused or did not answer, which is
    /// the connection's notice and never "This reading of your fleet is old" (one cause, one notice).
    private(set) var readsFail = false
    /// **The old-reading notice, once it stood, stays** until a read answers or the hub's own notice takes its place (fix
    /// round 3, item 17): a read that hangs fails only at its 10-s limit, and the notice went then, about 20 s before the
    /// hub's own came, so that nothing but the Settings dot said the reading was old.
    var staleNoticeStood = false
    /// The agent that Add agent has just added: its setup page says "Adding <Name>" until its first reading.
    var addedAgent: String?
    /// **The agents this Mac saw with no server of their own** (hub feature `manager_server`: the manager of a new
    /// fleet), as hub address, hub generation and name: their setup goes on after the press that gives them one, through
    /// the install and the sign-in, until they run (`AgentSetupFlow.places`). This Mac keeps them, so an app that starts
    /// again during an install of minutes opens on that install, and not on a chat that cannot answer yet.
    private var unplaced = Set(AppDefaults.store.stringArray(forKey: "unplacedAgents") ?? []) {
        didSet { AppDefaults.store.set(unplaced.sorted(), forKey: "unplacedAgents") }
    }
    private func placingKey(_ agent: String, database: String) -> String { "\(hub.absoluteString)|\(database)|\(agent)" }
    /// This Mac saw the agent with no server on this hub generation, and has not seen it run since.
    func placing(_ agent: String) -> Bool { state.map { unplaced.contains(placingKey(agent, database: $0.db)) } ?? false }
    /// **The first setup of a manager that the installer placed** (a fleet on one server, which this Mac's first run
    /// just installed): the hub never showed it with no server, so this Mac puts it on the same list itself. Its setup
    /// then fills the window and shows its steps until it runs, as for a manager that gets its first server.
    func noteFirstSetup(of agent: String) {
        guard let database = state?.db else { return }
        unplaced.insert(placingKey(agent, database: database))
    }
    /// **He went on from "Name your manager" in the manager's own setup**, on this run of the app and for this hub
    /// generation: the page of the fleet's servers is next, until the hub keeps a step (`ManagerSetupStart`). Back on
    /// that page takes it away.
    private var namedManagers: Set<String> = []
    var managerNamed: Bool { state.map { namedManagers.contains("\(hub.absoluteString)|\($0.db)") } ?? false }
    func noteManagerNamed(_ named: Bool) {
        guard let database = state?.db else { return }
        let key = "\(hub.absoluteString)|\(database)"
        if named { namedManagers.insert(key) } else { namedManagers.remove(key) }
    }
    /// **A manager that gets its name in its own setup** (`HubClient.nameManager`): the page that shows it goes to its
    /// new name in the same step as the reading that has that name (`notePlacing`), so that no chat of an agent that is
    /// not there shows between the two. The note is for this hub and this generation, and a reading of another one
    /// does nothing with it. nil takes the note away: after a rename that the hub refused, and when he goes on with
    /// the name that the manager has.
    @ObservationIgnored private var renamedManager: (hub: URL, database: String, was: String, now: String)?
    func noteRenamed(from was: String, to now: String?) {
        guard let now, let database = state?.db else { renamedManager = nil; return }
        renamedManager = (hub, database, was, now)
    }
    /// The same page of the agent under its new name: its chat, a part of its details, its sign-in, a rule's editor.
    private static func renamed(_ page: Destination, was: String, now: String) -> Destination? {
        switch page {
        case .agent(was): .agent(now)
        case .agentDetail(was, let tab): .agentDetail(now, tab)
        case .signIn(was, let runtime): .signIn(now, runtime)
        case .agentRule(was, let rule): .agentRule(now, rule)
        default: nil
        }
    }
    /// **The setup takes the place of this agent's chat and of its Runs on** (`AgentSetupFlow.shows`).
    func setupShows(_ agent: String) -> Bool {
        AgentSetupFlow.shows(state?.agents.first { $0.name == agent }, features: state?.ui_features ?? [], placing: placing(agent))
    }
    /// **This agent's chat place shows as its detail page**: it is on a key or a model server, which has no chat in
    /// version 1 (review M2), and its setup does not show there. The window moves there (`standIn`), and the detail page
    /// has no "Back to chat", which would lead to the same page (the live test's finding F4; the owner's "Yes, hide it"
    /// of 16 November 2026).
    func chatShowsDetail(_ agent: String) -> Bool {
        state?.agents.first { $0.name == agent }?.modelProvider != nil && !setupShows(agent)
    }
    /// **The server that joined for an agent with no server yet**, by the same key: the setup gives it that server with
    /// its provider. This Mac keeps it, so an app that starts again between the join and that command goes on with that
    /// server, and does not open on the server's page, where a press would make another server.
    private var joinedFor = AppDefaults.store.dictionary(forKey: "serversJoinedFor") as? [String: String] ?? [:] {
        didSet { AppDefaults.store.set(joinedFor, forKey: "serversJoinedFor") }
    }
    func joinedServer(_ agent: String) -> String? { state.flatMap { joinedFor[placingKey(agent, database: $0.db)] } }
    func noteJoined(_ server: String, for agent: String) {
        guard let database = state?.db else { return }
        joinedFor[placingKey(agent, database: database)] = server
    }
    /// **The AI provider that he chose for an agent with no server yet**, by the same key (the owner, 16 November 2026:
    /// "agent onboarding should ask first for the name and AI provider before the server page"): the setup gives it to
    /// the agent with its server, as soon as that server is there. This Mac keeps it, so an app that starts again
    /// between the press and the server goes on to the server, and does not ask for the provider again.
    private var providerFor = AppDefaults.store.dictionary(forKey: "providersChosenFor") as? [String: String] ?? [:] {
        didSet { AppDefaults.store.set(providerFor, forKey: "providersChosenFor") }
    }
    func chosenProvider(_ agent: String) -> String? { state.flatMap { providerFor[placingKey(agent, database: $0.db)] } }
    /// nil takes the choice away: Back from the page after it.
    func noteProvider(_ provider: String?, for agent: String) {
        guard let database = state?.db else { return }
        providerFor[placingKey(agent, database: database)] = provider
    }
    /// **The server that the first run made for an agent with no server yet** (slice 2 of the one wizard: one press
    /// makes every server of the fleet), by the same key: its name and its address on the private network. The agent's
    /// setup installs it by itself and takes the note away as that install starts (`AddServerView`). This Mac keeps
    /// it, so an app that starts again before that install still has it.
    struct MadeServer: Equatable {
        let name: String
        let address: String
    }
    /// Its own key: `MadeServers` keeps a list of another form under "serversMadeFor".
    private var madeFor = AppDefaults.store.dictionary(forKey: "firstRunServerFor") as? [String: [String]] ?? [:] {
        didSet { AppDefaults.store.set(madeFor, forKey: "firstRunServerFor") }
    }
    func madeServer(_ agent: String) -> MadeServer? {
        guard let kept = state.flatMap({ madeFor[placingKey(agent, database: $0.db)] }), kept.count == 2 else { return nil }
        return MadeServer(name: kept[0], address: kept[1])
    }
    /// nil takes the note away: the install that it was for starts.
    func noteMadeServer(_ server: MadeServer?, for agent: String) {
        guard let database = state?.db else { return }
        madeFor[placingKey(agent, database: database)] = server.map { [$0.name, $0.address] }
    }
    /// An agent with no server goes on the list, and one that runs leaves it. One that has its server needs no joined
    /// server, no chosen provider and no made server any more.
    private func notePlacing(_ fresh: HubState) {
        // The reading that has a manager under its new name, and no more under its old one (`noteRenamed`).
        if let renamed = renamedManager, renamed.hub == hub, renamed.database == fresh.db,
           fresh.agents.contains(where: { $0.name == renamed.now }),
           !fresh.agents.contains(where: { $0.name == renamed.was }) {
            shown.renamed(from: renamed.was, to: renamed.now)       // a chat that `setup_show` opened stays not read
            if let page = Self.renamed(destination, was: renamed.was, now: renamed.now) {
                keepsDetail = true; destination = page; keepsDetail = false
            }
            renamedManager = nil
        }
        guard fresh.ui_features?.contains(AgentSetupFlow.serverFeature) == true else { return }
        for agent in fresh.agents {
            let key = placingKey(agent.name, database: fresh.db)
            if !agent.placed, !unplaced.contains(key) { unplaced.insert(key) }
            if AgentSetupFlow.runs(agent), unplaced.contains(key) { unplaced.remove(key) }
            if agent.placed, joinedFor[key] != nil { joinedFor[key] = nil }
            if agent.placed, providerFor[key] != nil { providerFor[key] = nil }
            if agent.placed, madeFor[key] != nil { madeFor[key] = nil }
        }
    }
    /// **A write that its own row says it waits for** (fix round 3c, the lead's call): the request, and the agent's part
    /// whose row says "The hub has not answered." with its Try again. The window's request line leaves that write out on
    /// that part, so one unanswered save is said once; on any other page, and for every other write, the line says it.
    var pendingInItsRow: (id: UUID, agent: String, tab: AgentTab)?
    /// **A read has taken more than eight seconds, and none has answered since** (`readPatience`; fix round 3b, item
    /// 17). It outlives the read that failed: the notice never goes before an answer. Only the launch's first read
    /// makes the reading old with it: while the app runs, a slow read is part of one break of the hub
    /// (`StateReading.limit`), and the end of the break says it (`watchBreak`).
    private(set) var readHeld = false
    /// The reads of `/ui/state` so far, to tell the one on its way from the next.
    @ObservationIgnored private var readCount = 0
    /// How long this hub's last answered read took. **A read is held after eight seconds, or after twice that time on
    /// a hub whose reads take longer**, so a slow hub's reading does not turn old for part of every read (fix round 3b).
    @ObservationIgnored private var lastReadTook: Duration = .zero
    /// **How long a read of the fleet's state goes before its reading is old: eight seconds** (`StateReading.patience`;
    /// the owner, 27 October 2026: "never for one short break"; and 10 November 2026: "loading certain screens like
    /// Servers flicker before they are fully loaded"). It was one second, from when a read took 80 ms. A read of his
    /// fleet's state now takes 0.7 s, and under load on this Mac 2 to 7 s for some reads: each of those put the notice
    /// "This reading of your fleet is old" over the page and drew every mark of every page as its last reading, for the
    /// rest of that read, and then took both away (seen on his own app on 10 November 2026: once in 150 s, for 2 s). A
    /// reading that is 3 to 11 seconds old while its read goes on is no news. Since 17 November 2026 this holds the
    /// launch's first read only: a slow read of a running app is part of one break (`StateReading.limit`).
    private static let readPatience: Duration = .seconds(StateReading.patience)
    /// The old-reading notice shows: the reading is old with no failed read before the notice stood — the launch's
    /// first read is slow, or the hub left the app one whole break (`StateReading.limit`) and no read failed.
    var staleNoticeShows: Bool { !isFresh && state != nil && connectionError == nil && (!readsFail || staleNoticeStood) }
    /// A notice of the window says that the hub does not answer or that the reading is old: a page says it no more
    /// (fix round 3, item 33: Servers said one outage three times).
    var hubNoticeShows: Bool { connectionError != nil || staleNoticeShows }
    private(set) var sendError: String?
    private(set) var storageError: String?
    /// **The system's own words behind a line of this Mac's** (T-35), for its hover and for a problem report: the line
    /// says what failed in a few plain words. Kept with the line it explains, so a later line never shows them.
    private var storageCauses: (words: String, cause: String)?
    var storageCause: String? { storageCauses.flatMap { $0.words == storageError ? $0.cause : nil } }
    private(set) var lastSuccess: Date?
    private(set) var clock = Date()
    var lastReceipt: SendReceipt?
    private(set) var lastControlReceipt: ControlReceipt?
    var draft: String {
        didSet { AppDefaults.store.set(draft, forKey: "managerDraft") }
    }
    var answers: [String: String] {
        didSet { AppDefaults.store.set(answers, forKey: "answerDrafts") }
    }
    /// Owner feature `attachments`: the files that the owner picked for each composer, by its key. They are kept
    /// across a restart, as the drafts are; the bytes of a file that is not on the hub yet wait beside the Outbox,
    /// so nothing is lost and nothing is sent twice. The phone keeps them the same way (`MobileStore`).
    private(set) var staged: [String: [StagedFile]] = [:]
    private(set) var uploading: Set<UUID> = []
    /// **What went wrong with a file he picked, in the composer he picked it for and in no other** (T-14). One line
    /// for the whole app said "This file did not come." in every chat's composer, Atlas's too, when one picture of
    /// one message in Manager's chat did not load while the hub was away.
    private(set) var fileErrors: [String: String] = [:]
    func fileError(for composer: String) -> String? { fileErrors[composer] }
    func setFileError(_ words: String?, for composer: String) { fileErrors[composer] = words }
    private var fileCauses: [String: (words: String, cause: String)] = [:]
    /// The system's own words behind a composer's file line (`storageCause`).
    func fileCause(for composer: String) -> String? {
        fileCauses[composer].flatMap { $0.words == fileErrors[composer] ? $0.cause : nil }
    }

    private func storageFailed(_ words: String, cause error: Error) {
        storageError = words
        storageCauses = (words, error.localizedDescription)
    }

    private func fileFailed(_ words: String, cause error: Error, for composer: String) {
        fileErrors[composer] = words
        fileCauses[composer] = (words, error.localizedDescription)
    }
    /// The files of messages whose read failed: each one's own tile says "Not loaded", and it is read again when the
    /// hub answers (`MessageFilesView`).
    private(set) var unloadedFiles: Set<Int> = []
    /// What went wrong when he opened or kept one file of a message, on that file's own tile.
    private(set) var fileProblems: [Int: String] = [:]
    func setFileProblem(_ words: String?, for file: Int) { fileProblems[file] = words }
    /// The bytes of the files that the chat shows, by attachment number, oldest first.
    @ObservationIgnored private(set) var picturePreviews = PicturePreviews()
    private(set) var fileData: [Int: Data] = [:]
    /// The SHA-256 that the read of each file of `fileData` checked (`heldBytes(of:)`).
    private var fileSums: [Int: String] = [:]
    private var fileOrder: [Int] = []
    private var fileReads: Set<Int> = []
    /// The hub and the database whose files this store holds, and one more at each change of them: a picture reads
    /// its file again at a change (`PictureTile`), also when the new database has the same file under the same number.
    @ObservationIgnored private var filesFleet: String?
    private(set) var filesGeneration = 0

    /// After a change of hub or database (`connect()`, "Start again", a new database) the same number names another
    /// file, so what this store holds of the files before goes, and a read on its way keeps nothing (`load`).
    private func forgetFilesOfAnotherFleet() {
        let fleet = state.map { "\(hub.absoluteString)\n\($0.db)" }
        guard fleet != filesFleet else { return }
        filesFleet = fleet
        filesGeneration += 1
        picturePreviews = PicturePreviews()
        // A chip that went up to the hub before names a file of that hub: it goes up again before its send
        // (`freshFiles`). A chip of the same hub gets its own row back, under its own request number.
        for (composer, files) in staged where files.contains(where: { $0.hubCreated != nil }) {
            staged[composer] = files.map { var file = $0; file.hubCreated = nil; return file }
        }
        keepStaged()
        fileData = [:]; fileSums = [:]; fileOrder = []; fileReads = []
        unloadedFiles = []; fileProblems = [:]
    }
    private let client = HubClient()
    private let knowledge = KnowledgeClient()
    private let outbox: Outbox
    /// Where the bytes of a file that is not on the hub yet wait, beside the Outbox.
    private let stagedDirectory: URL
    let installation: String
    private var polling: Task<Void, Never>?

    // MARK: Live changes (owner feature `live_changes`)

    /// The page loops' one alarm clock: a wake ends every nap that is on (`nap`).
    private let wakes = PageWakes()
    /// The reads of `/ui/state`: one that is asked for while one is on its way runs once more, and none is dropped.
    private let reads = RunAgain()
    /// When the last read of `/ui/state` ended, on a clock that only goes forward. The read on the clock counts from it.
    @ObservationIgnored private var lastRead: TimeInterval?
    /// The hub's token in the newest read of `/ui/state`, and in the newest wake.
    @ObservationIgnored private var stateToken: LiveToken?
    @ObservationIgnored private var wakeToken: LiveToken?
    /// The watcher of `/ui/wait`, for one hub address and one generation.
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var watched: Watched?
    @ObservationIgnored private var watches = 0
    private struct Watched: Equatable { let hub: URL; let database: String; let id: Int }
    /// At most one wake of the watcher in two seconds; the one held for later, while it waits.
    @ObservationIgnored private var cap = WakeCap()
    @ObservationIgnored private var heldWake: Task<Void, Never>?
    /// The observer of `HubWrites`: a write of this Mac got its answer.
    @ObservationIgnored private var writes: NSObjectProtocol?

    // MARK: The ended tasks that a read of the state leaves out (`OlderTasks`; owner API 1.254)

    /// The blocks of older tasks that this Mac holds for this hub: each reading is its window read joined with them
    /// (`OlderTasks.join`), so the pages draw every task, as they did when the hub sent every task in each read.
    @ObservationIgnored private var older = OlderTasks()
    /// The newest window read as the hub gave it, which a block that comes later is joined to.
    @ObservationIgnored private var lastWindow: HubState?
    /// The one read of the blocks that runs now, with its number: a read that `forgetOlder` ended takes no block
    /// and clears no handle of a later read. And when a block that a read took last came to the pages.
    @ObservationIgnored private var olderRead: Task<Void, Never>?
    @ObservationIgnored private var olderReads = 0
    @ObservationIgnored private var olderShown = ContinuousClock.now
    /// The newest write or removal of a block's file, each after the one before it: a later answer of a block is
    /// never under an earlier one on the disk, and `forgetFleet` removes the folder again after the last of them.
    @ObservationIgnored private var olderWrite: Task<Void, Never>?
    private static let olderLog = Logger(subsystem: "com.founderizer.app", category: "older-tasks")

    // MARK: The items, reports and messages that a read of the state leaves out (`OlderRows`; owner API 1.258)

    /// The blocks of older Needs-you items, reports and messages that this Mac holds for this hub, which each reading
    /// joins after the blocks of older tasks (`joined`), so the pages draw every row, as they did. Their read runs as
    /// the tasks' does, and their files go after the same writes (`afterOlderWrites`).
    @ObservationIgnored private var olderRows = OlderRows()
    @ObservationIgnored private var olderRowsRead: Task<Void, Never>?
    @ObservationIgnored private var olderRowsReads = 0
    /// The hub generation whose read of the lists of older rows failed (not one block's answer): a new generation's
    /// marks of seen replies then wait no longer for every report (`markRepliesSeen`).
    @ObservationIgnored private var rowsReadFailed: String?

    // MARK: The last reading, kept between launches

    /// Where the last reading of each hub address waits for the next launch.
    private let readingsFolder: URL
    /// The newest reading that is not on disk yet, with its file, and when a reading was last written.
    @ObservationIgnored private var unwrittenReading: (data: Data, file: URL)?
    @ObservationIgnored private var readingWritten: Date?
    /// The newest readings kept for the next launch that are not on disk yet, by their kind, with their files: they are
    /// written with the fleet's (`keepForNextLaunch`).
    @ObservationIgnored private var unwrittenKept: [String: (data: Data, file: URL)] = [:]
    /// **The health reading this Mac kept from its last launch** (`FleetHealth.kept`), for the hub generation of the
    /// reading kept with it: the Settings dot draws from it until this launch reads the health (`settingsDot`). **A
    /// health read of this launch that fails takes it away** (`KeptReading`; review B, round 4): the dot showed the last
    /// launch's warnings until System status or Servers read the health again.
    private(set) var keptHealth = KeptReading<FleetHealth>()
    /// **The releases reading this Mac kept from its last launch** (`ReleaseState.kept`), for the hub generation of the
    /// reading kept with it: the sidebar's Update row draws from it until this launch reads the releases (`updateWaits`).
    /// **A releases read of this launch that fails takes it away** (`KeptReading`; review A, rounds 4 and 5): the row
    /// stood 300 s more, until the next read, for a release that may have been taken meanwhile. The hub's revision does
    /// not take it away: it is the head of the fleet's configuration branch, which every setting and every delivered
    /// task output moves, and a waiting release's row went at the health read and came back at the releases read.
    private(set) var keptReleases = KeptReading<ReleaseState>()

    /// A read of this launch failed: the reading kept from the last launch under that page reading's name goes with it,
    /// the health (`servers.health`) or the releases (`releases`).
    func keptReadingFailed(_ name: String) {
        switch name {
        case "servers.health": keptHealth.readFailed()
        case "releases": keptReleases.readFailed()
        default: break
        }
    }
    /// The newest write of a reading that went away from the window's work (`writeReading`), for `forgetFleet`, which
    /// removes a fleet's readings also when such a write is still on its way.
    @ObservationIgnored private var lastWrite: Task<Void, Never>?
    /// The observer of the app's quit, which writes the newest reading.
    @ObservationIgnored private var quitting: NSObjectProtocol?
    /// **When the Mac last woke from sleep**, and its observer: a page's reads that failed before it count from then
    /// (`pageReadingIsOld`), as the break of the hub does (`sinceAnswer`), so a Mac that wakes starts no break; and
    /// an agent's work moves again only by an answer after it (`marksMove`).
    private(set) var wokeAt: ContinuousClock.Instant?
    @ObservationIgnored private var waking: NSObjectProtocol?

    /// The hub addresses that have answered this Mac, kept between launches.
    private static var answeredHubs: [String] {
        get { AppDefaults.store.stringArray(forKey: "hubsAnswered") ?? [] }
        set { AppDefaults.store.set(newValue, forKey: "hubsAnswered") }
    }

    /// The file of the last reading of this hub address: one for each address, so a reading of another hub is never
    /// drawn. The hub generation is inside it. The readings kept with it stand beside it, one file for each kind.
    private var lastReadingFile: URL { keptFile("state") }

    private func keptFile(_ kind: String) -> URL {
        let address = [hub.host ?? "hub", hub.port.map(String.init)].compactMap { $0 }.joined(separator: "-")
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return readingsFolder.appendingPathComponent("\(kind)-\(address).json")
    }

    /// **The last reading of the fleet stays on this Mac** (T-07), so the next launch draws the window as he left it
    /// in its first frame, and the hub's answer replaces it: at most once a minute, and when the app quits.
    private func keepReading(_ data: Data) {
        unwrittenReading = (data, lastReadingFile)
        if let written = readingWritten, Date().timeIntervalSince(written) < 60 { return }
        writeReading(now: false)
    }

    /// **A reading that the next launch draws in its first frame stays on this Mac with the fleet's**, written when the
    /// fleet's is: the health (`health`, the Settings dot; the polish of 30 October 2026: it came 0.2–0.3 s after the
    /// window), the releases (`releases`, the sidebar's Update row; the second review of the same day: it came after
    /// the launch's first reads, and moved the line and Settings under it), and the build of this app that waits
    /// (`app-update`, the same row for this Mac; review B, round 3).
    func keepForNextLaunch(_ value: some Encodable, as kind: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        unwrittenKept[kind] = (data, keptFile(kind))
    }

    /// Writes the newest reading, and the readings kept with it: away from the window's work while the app runs, at once
    /// when it quits.
    private func writeReading(now: Bool) {
        let files = [unwrittenReading].compactMap { $0 } + unwrittenKept.values
        guard !files.isEmpty else { return }
        unwrittenReading = nil; unwrittenKept = [:]; readingWritten = Date()
        let write: @Sendable () -> Void = {
            for (data, file) in files {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                         attributes: [.posixPermissions: 0o700])
                try? data.write(to: file, options: [.atomic])
            }
        }
        if now { write() } else { lastWrite = Task.detached(priority: .utility, operation: write) }
    }

    // MARK: The blocks of older tasks

    /// **Reads the blocks of older tasks that this Mac does not hold as the hub has them now**, one read at a time,
    /// away from the reads of the state: the list first, then each block whose mark differs, the newest first. It
    /// runs after a read of the state whose mark is not the one that the held blocks are current at: at the first
    /// read of a launch, when a task ended below the window, and when the window moved up a block.
    private func readOlder() {
        guard olderRead == nil, let window = lastWindow, older.isBehind(window) else { return }
        let hub = hub, database = window.db
        olderReads += 1
        let number = olderReads
        olderRead = Task { [weak self] in
            await self?.readOlderBlocks(number, hub: hub, database: database)
            if self?.olderReads == number { self?.olderRead = nil }
        }
    }

    /// **A block whose answer cannot be read does not stop the others** (`OlderTasks.blockFailed`): it is counted
    /// (`OlderTasks.fail`), written to the log, and asked for again at the next reads, three times in all at its
    /// mark; then the read rests while the state's mark stands, with one more try at each new mark, and the pages
    /// keep what they showed of its tasks. Every other failure ends this read (the hub did not answer, the
    /// generation moved, the window came down over the block), and the next read of the state starts it again.
    ///
    /// The blocks come to the pages as a reading does: when a scroll rests (`readingsRest`), about once a second
    /// while many blocks come, and at the end.
    private func readOlderBlocks(_ number: Int, hub: URL, database: String) async {
        func mine() -> Bool { number == olderReads && hub == self.hub && lastWindow?.db == database }
        do {
            let list = try await client.olderList(at: hub, database: database)
            guard mine() else { return }
            for entry in older.wanted(list) {
                do {
                    let (block, data) = try await client.olderBlock(at: hub, database: database, from: entry.from)
                    guard mine() else { return }
                    older.take(block)
                    keepBlock(data, from: entry.from, hub: hub)
                } catch where OlderTasks.blockFailed(error) {
                    guard mine() else { return }
                    older.fail(entry)
                    // The kind of the fault and no word of the hub's answer: the log can go into a report.
                    let fault = if case HubError.refusal(let refusal) = error { "status \(refusal.status)" } else { "an answer that this app cannot read" }
                    Self.olderLog.error("the block of older tasks from \(entry.from, privacy: .public) could not be read: \(fault, privacy: .public)")
                }
                if ContinuousClock.now - olderShown > .seconds(1) {
                    await readingsRest()
                    guard mine() else { return }
                    showOlder()
                }
            }
            older.finish(list)
            tidyBlocks(keeping: Set(list.blocks.map(\.from)), hub: hub)
        } catch {
            // Nothing to say: the pages keep what they show, and the next read of the state asks again.
        }
        await readingsRest()
        if mine() { showOlder() }
    }

    /// The pages draw the newest window read with the blocks as they are now.
    private func showOlder() {
        olderShown = .now
        guard let window = lastWindow, let shown = state, shown.db == window.db else { return }
        let fresh = joined(window, shown: shown)
        state = fresh
        // The chats draw from the timeline, and a new generation's marks of seen replies wait for every report
        // (`markRepliesSeen`): both follow the blocks as they come, and not only the next read of the state.
        var timeline = chatTimeline
        if timeline.update(messages: fresh.messages, reports: fresh.reports) { chatTimeline = timeline }
        markRepliesSeen()
    }

    /// The reading that the pages draw for a window read: joined with the blocks of older tasks, and then with the
    /// blocks of older items, reports and messages, which touch none of the tasks' lists.
    private func joined(_ window: HubState, shown: HubState?) -> HubState {
        olderRows.join(older.join(window, shown: shown), shown: shown)
    }

    /// Another hub, or no fleet: no block of the hub of before is joined to a reading again, and a read of its
    /// blocks that is on its way takes none. Its files stay for the next connect to it (`readState` reads them
    /// then), and `forgetFleet` removes them.
    private func forgetOlder() {
        olderRead?.cancel(); olderRead = nil
        olderReads += 1
        launchHistory?.cancel(); launchHistory = nil
        older = OlderTasks(); lastWindow = nil
        olderRowsRead?.cancel(); olderRowsRead = nil
        olderRowsReads += 1
        olderRows = OlderRows(); rowsReadFailed = nil
    }

    private func blockFile(_ from: Int, hub: URL) -> URL {
        StartAgain.olderFolder(of: hub, in: readingsFolder).appendingPathComponent("\(from).json")
    }

    /// One step on the disk for the blocks, after the step before it, away from the window's work.
    private func afterOlderWrites(_ step: @escaping @Sendable () -> Void) {
        let before = olderWrite
        olderWrite = Task.detached(priority: .utility) {
            await before?.value
            step()
        }
    }

    /// **A block of older tasks stays on this Mac** beside the last reading, as the hub sent it, so that a launch
    /// reads from the hub only the blocks that changed since.
    private func keepBlock(_ data: Data, from: Int, hub: URL) {
        let file = blockFile(from, hub: hub)
        afterOlderWrites {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            try? data.write(to: file, options: [.atomic])
        }
    }

    /// The files of the blocks that the hub's list does not name leave the disk: the window came down over them, or
    /// they are of a generation of before.
    private func tidyBlocks(keeping named: Set<Int>, hub: URL) {
        let folder = StartAgain.olderFolder(of: hub, in: readingsFolder)
        afterOlderWrites {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
                guard name.hasSuffix(".json"), let from = Int(name.dropLast(5)), !named.contains(from) else { continue }
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
        }
    }

    // MARK: The blocks of older rows

    /// **Reads the blocks of older items, reports and messages that this Mac does not hold as the hub has them now**,
    /// as `readOlder` reads the tasks': one read at a time, for each list whose mark is not the one that its held
    /// blocks are current at, its list first, then each block whose mark differs, the newest first.
    private func readOlderRows() {
        guard olderRowsRead == nil, let window = lastWindow, !olderRows.behind(window).isEmpty else { return }
        let hub = hub, database = window.db
        olderRowsReads += 1
        let number = olderRowsReads
        olderRowsRead = Task { [weak self] in
            await self?.readOlderRowBlocks(number, hub: hub, database: database)
            if self?.olderRowsReads == number { self?.olderRowsRead = nil }
        }
    }

    /// The read of `readOlderRows`, by the rules of `readOlderBlocks`: a block whose answer cannot be read does not stop
    /// the others, and every other failure ends this read, which the next read of the state starts again.
    private func readOlderRowBlocks(_ number: Int, hub: URL, database: String) async {
        func mine() -> Bool { number == olderRowsReads && hub == self.hub && lastWindow?.db == database }
        lists: for list in lastWindow.map(olderRows.behind) ?? [] {
            do {
                let index = try await client.olderRows(at: hub, database: database, list: list)
                guard mine() else { return }
                for entry in olderRows.wanted(index) {
                    do {
                        let (block, data) = try await client.olderRowsBlock(at: hub, database: database, list: list,
                                                                            from: entry.from)
                        guard mine() else { return }
                        olderRows.take(block, size: index.block)
                        keepRowBlock(data, list: list, from: entry.from, hub: hub)
                    } catch where OlderTasks.blockFailed(error) {
                        guard mine() else { return }
                        olderRows.fail(entry, of: list)
                        // The kind of the fault and no word of the hub's answer: the log can go into a report.
                        let fault = if case HubError.refusal(let refusal) = error { "status \(refusal.status)" } else { "an answer that this app cannot read" }
                        Self.olderLog.error("the block of older \(list.rawValue, privacy: .public) from \(entry.from, privacy: .public) could not be read: \(fault, privacy: .public)")
                    }
                    if ContinuousClock.now - olderShown > .seconds(1) {
                        await readingsRest()
                        guard mine() else { return }
                        showOlder()
                    }
                }
                olderRows.finish(index)
                tidyRowBlocks(list, keeping: Set(index.blocks.map(\.from)), hub: hub)
            } catch {
                if mine() { rowsReadFailed = database }
                break lists     // the pages keep what they show, and the next read of the state asks again
            }
        }
        await readingsRest()
        if mine() { showOlder() }
    }

    private func rowBlockFile(_ list: OlderRowsList, _ from: Int, hub: URL) -> URL {
        StartAgain.olderRowsFolder(of: hub, list: list.rawValue, in: readingsFolder).appendingPathComponent("\(from).json")
    }

    /// **A block of older rows stays on this Mac** beside the last reading, as the hub sent it (`keepBlock`).
    private func keepRowBlock(_ data: Data, list: OlderRowsList, from: Int, hub: URL) {
        let file = rowBlockFile(list, from, hub: hub)
        afterOlderWrites {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            try? data.write(to: file, options: [.atomic])
        }
    }

    /// The files of the blocks of a list that the hub's list does not name leave the disk (`tidyBlocks`).
    private func tidyRowBlocks(_ list: OlderRowsList, keeping named: Set<Int>, hub: URL) {
        let folder = StartAgain.olderRowsFolder(of: hub, list: list.rawValue, in: readingsFolder)
        afterOlderWrites {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
                guard name.hasSuffix(".json"), let from = Int(name.dropLast(5)), !named.contains(from) else { continue }
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
        }
    }

    /// The complete disk cache for this launch, ready before the first live window can need a later block.
    @ObservationIgnored private var launchHistory: Task<(OlderTasks, OlderRows), Never>?

    init() {
        // **A launch's `-hubAddress` that is no hub address stops the app** (review B9, fix round 2): it fell back to his
        // own hub without a word, so a test copy with a typo in it read his real fleet, and could write to it.
        if let asked = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["hubAddress"] as? String,
           (try? HubClient.address(asked)) == nil {
            fatalError("-hubAddress \(asked) is not a hub address. Founderizer stops here rather than read another hub.")
        }
        let kept = AppDefaults.store.string(forKey: "hubAddress")
        let address = kept ?? HubClient.defaultAddress
        // The field of the hub's address is empty on a Mac that was never given one: the address of no hub is not a
        // thing to show or to correct (the onboarding test of 13 November 2026, Settings › System status).
        addressText = kept ?? ""
        let installationID = AppDefaults.store.string(forKey: "installationID") ?? UUID().uuidString.lowercased()
        AppDefaults.store.set(installationID, forKey: "installationID")
        installation = "founderizer-swift/1/\(installationID)"
        hub = (try? HubClient.address(address)) ?? (try! HubClient.address(HubClient.defaultAddress))
        draft = AppDefaults.store.string(forKey: "managerDraft") ?? ""
        agentDrafts = AppDefaults.store.dictionary(forKey: "agentDrafts") as? [String: String] ?? [:]
        answers = AppDefaults.store.dictionary(forKey: "answerDrafts") as? [String: String] ?? [:]
        // Settings and rules save themselves now: no profile draft is kept, and the drafts of earlier versions go.
        AppDefaults.store.removeObject(forKey: "profileDrafts")
        if let seen = AppDefaults.store.dictionary(forKey: "chatRepliesSeen"), let context = seen["context"] as? String,
           let replies = seen["seen"] as? [String: Int] {
            seenContext = context; seenReplies = replies
        }
        let support = AppFolders.support          // Application Support, or a test's folder (`AppFolders`)
        outbox = Outbox(file: support.appendingPathComponent("Founderizer/pending.json"))
        stagedDirectory = support.appendingPathComponent("Founderizer/staged")
        readingsFolder = support.appendingPathComponent("Founderizer")
        hubAnsweredBefore = Self.answeredHubs.contains(hub.absoluteString)
        startedWithFleet = hubAnsweredBefore
        if let kept = AppDefaults.store.data(forKey: "stagedFiles"),
           let files = try? JSONDecoder().decode([String: [StagedFile]].self, from: kept) {
            staged = files
        }
        do { pending = try outbox.load() }
        catch { storageFailed(String(l10n: "Cannot read the saved request. Sending is blocked."), cause: error) }
        notifications.openRequest = { [weak self] context, id in
            guard let self, let state = self.state,
                  context == FleetNotifications.context(hub: self.hub, database: state.db) else { return }
            // The page that it opens is the one in front: no card stands over it.
            if let id {
                guard state.needs.contains(where: { $0.id == id }) else { return }
                self.closeDetail(); self.destination = .needs; self.selectedNeed = id
            } else { self.closeDetail(); self.destination = Self.home(state) }
        }
        // **Every write wakes the page loops as soon as its answer comes**: the outbox's sends, the saves, and every
        // POST a page makes itself, through any client of the hub. It is the owner's own action, so no cap holds it
        // back.
        writes = NotificationCenter.default.addObserver(forName: HubWrites.answered, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.wakes.wake() }
        }
        // **The window as he left it, in its first frame** (T-07): the last reading of this hub that this Mac kept.
        // The launch's first read replaces it; until that read answers, fails or has taken eight seconds it is not old
        // (`isFresh`), so nothing on the page marks it for the moment it stands.
        // Each kept file is read only when it is a regular file of a reading's size, with no wait (`KeptFile`):
        // these reads hold the window's first frame. What is not read is no kept reading: the window waits for the
        // hub's first answer, as on a Mac that kept none.
        if let data = KeptFile.bytes(of: lastReadingFile, atMost: KeptFile.largestReading), let kept = try? HubState.decode(data) {
            let files = KeptHistory(window: kept, hub: hub, folder: readingsFolder, tasks: true, rows: true)
            let first = KeptHistory.read(files.needed)
            if kept.older_tasks?.isValid == true { older = OlderTasks(kept: first.tasks, db: kept.db) }
            if kept.older_rows?.isValid == true { olderRows = OlderRows(kept: first.rows, db: kept.db) }
            if !files.later.isEmpty {
                let db = kept.db, hasTasks = older.db == kept.db, hasRows = olderRows.db == kept.db
                launchHistory = Task.detached(priority: .utility) {
                    let rest = KeptHistory.read(files.later, priority: .utility)
                    return (hasTasks ? OlderTasks(kept: first.tasks + rest.tasks, db: db) : OlderTasks(),
                            hasRows ? OlderRows(kept: first.rows + rest.rows, db: db) : OlderRows())
                }
            }
            lastWindow = kept
            let shown = joined(kept, shown: nil)
            state = shown
            var timeline = ChatTimeline()
            // The joined reading's lines: the window's and those of the blocks of older rows that this Mac kept.
            if timeline.update(messages: shown.messages, reports: shown.reports) { chatTimeline = timeline }
            keptHealth = KeptReading(KeptFile.bytes(of: keptFile("health"), atMost: KeptFile.largestReading)
                .flatMap { FleetHealth.kept($0, database: kept.db) })
            keptReleases = KeptReading(KeptFile.bytes(of: keptFile("releases"), atMost: KeptFile.largestReading)
                .flatMap { ReleaseState.kept($0, database: kept.db) })
            updates.start(kept: KeptFile.bytes(of: keptFile("app-update"), atMost: KeptFile.largestReading).flatMap(WaitingBuild.kept))
        }
        chooseHome()
        quitting = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.writeReading(now: true) }
        }
        waking = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                   queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wokeAt = .now }
        }
        // The link's answers come from this store (`SetupChannel`, which listens from the app's start).
        SetupChannel.shared.attach(self)
        // Work that runs in this start passes the welcome page of an unfinished setup (`welcomeCovers`).
        watchWork()
    }

    /// **The state is current** (`StateReading.isCurrent`). A reading this Mac kept from an earlier launch is current
    /// while the launch's first read is on its way, and old as soon as that read fails or has taken eight seconds: a
    /// reading that is being read again is not old yet (the loading contract's rule, D-1). It was current for one second
    /// at most, and a launch whose first read took 1.4 s had the old-reading notice over its page from 1.2 to 1.6 s (10
    /// November 2026). **While the app runs, one break of the hub says nothing** (`StateReading.limit`; the owner, 27
    /// October 2026: "never for one short break", and 17 November 2026): a reading is old once the hub has left the app
    /// for 30 seconds with no answer, whatever its reads did meanwhile, and the hub's own notice comes at that moment
    /// (`watchBreak`, `HubReach.tells`). A control writes only within 12 seconds of the last answer (`writesNow`).
    var isFresh: Bool {
        guard state != nil, connectionError == nil else { return false }
        return StateReading.isCurrent(held: readHeld, sinceAnswer: sinceAnswer, firstReadEnded: firstReadEnded)
    }
    /// **The seconds since the hub's last answer of this launch**, or nil before the first one. They are counted on the
    /// Mac's uptime, which stops while the Mac sleeps: a Mac that wakes up starts no break, its first read comes at
    /// once, and the reading on the screen is old only when the hub then leaves it one whole break with no answer. Its
    /// agents' work rests until the hub's first answer after the wake (`marksMove`).
    var sinceAnswer: TimeInterval? {
        // Read, so that a view that asks draws again at the end of each read and of each break (`clock`).
        _ = clock
        return answeredUptime.map { max(0, ProcessInfo.processInfo.systemUptime - $0) }
    }
    /// The Mac's uptime at the hub's last answer of this launch (`sinceAnswer`).
    @ObservationIgnored private var answeredUptime: TimeInterval?
    /// When the read that brought the hub's last answer of this launch began, on the clock that counts the Mac's sleep
    /// (`marksMove`): an answer to a read sent before the sleep is from before the wake.
    @ObservationIgnored private var lastAnswer: ContinuousClock.Instant?
    /// **An agent's work moves on the screen** (`StateReading.workMoves`): the reading is current, and the hub answered
    /// to a read that began after the Mac's last wake. Only the motion of an agent's work reads it: its glyph, the line
    /// of its sidebar row, the chat's "Thinking" and the marks of its work, which rest in their colour, with no dot,
    /// while it is false. Every look follows `isFresh`, so a wake shows nothing new.
    var marksMove: Bool { StateReading.workMoves(stateIsCurrent: isFresh, readBegan: lastAnswer, wokeAt: wokeAt) }
    /// The task that says the hub at the end of a break with no answer (`watchBreak`).
    @ObservationIgnored private var breakEnds: Task<Void, Never>?
    /// The hub answered this launch, within the last 12 seconds on the wall clock, and no connection notice stands. A
    /// read that is slow or failed once leaves a write as it was (fix round 3b): the old look is the reading's, and a
    /// write has its own answer. **Not one break** (`StateReading.limit`): a write waits quietly for the hub's next
    /// answer, and never goes on a reading that is 25 seconds old, or one from before the Mac slept.
    private var answersWrites: Bool {
        guard state != nil, connectionError == nil, let lastSuccess else { return false }
        return max(clock, Date()).timeIntervalSince(lastSuccess) < Self.writesWithin
    }
    /// How long after the hub's last answer the app still writes (`answersWrites`, `writesNow`), on the wall clock.
    static let writesWithin: TimeInterval = 12
    /// **A control may write now** (its `canChange`, `canWrite`, its `.disabled`): the reading is current, and while
    /// the app runs the hub answered within the last 12 seconds. A reading is current for one break of the hub
    /// (`StateReading.limit`, 30 s), and a write never went on one more than 12 seconds old: 12 to 30 seconds into a
    /// break, a control waits greyed, as it does while a change of it is on its way, and says nothing. Before the
    /// launch's first answer it follows the reading, as before: no control greys out for the moment of that read.
    var writesNow: Bool {
        guard isFresh else { return false }
        guard let lastSuccess else { return true }
        return max(clock, Date()).timeIntervalSince(lastSuccess) < Self.writesWithin
    }
    /// Nothing is written on a kept reading alone: a write waits for the hub's own answer of this launch.
    var canWrite: Bool { answersWrites && !sending && pending == nil && storageError == nil }
    var openNeeds: [OwnerNeed] { state?.needs.filter(\.isOpen) ?? [] }
    /// The task of the card's task level, for its thread's reading (`taskFiles` and its kin).
    var currentTask: FleetTask? {
        guard let id = detail?.shown.task else { return nil }
        return state?.tasks.first { $0.id == id }
    }
    var canRetry: Bool {
        guard let pending else { return false }
        return answersWrites && !sending && storageError == nil && pending.refusal == nil &&
            pending.hub == hub && pending.database == state?.db
    }
    var connectionLabel: String {
        if isFresh { return String(l10n: "Connected") }
        if lastSuccess != nil { return String(l10n: "Disconnected · last state") }
        return refreshing ? String(l10n: "Connecting") : String(l10n: "Disconnected")
    }

    func start() {
        guard polling == nil else { return }
        Task { [weak self] in
            try? await Task.sleep(for: LoadingLine.quiet)
            self?.launched = true
        }
        // The app owns polling; closing its window must not stop owner notifications.
        polling = Task { [weak self] in
            while !Task.isCancelled {
                var wait = LiveChanges.poll
                if let self {
                    // The readings that a page judges against the hub's clock, every 15 seconds, beside the state's
                    // own read and on every page (`keepLive`).
                    self.keepLive(PagePrefetch.live)
                    // The fleet's own read every three seconds, **counted from the last read, whoever ran it**: a
                    // read that a change of the hub asked for takes the place of this one instead of adding one.
                    if self.untilRead == 0 { await self.refresh() }
                    // The copy he asked for, if one is due. This app runs only while he runs it, so the fleet's own
                    // poll is the only clock there is; until a copy is due this is two dates compared. **Beside the
                    // poll, never in it**: a copy takes minutes, and no read of the fleet ran while it did, so the
                    // reading turned old over a hub that answered. `busy` holds the ticks while one runs.
                    Task { await self.copies.tick(store: self) }
                    // A new build of this app, read every 5 minutes and when he comes back, in place while he is away.
                    self.updates.tick(store: self)
                    // The fleet's central vault, read once a minute and kept in order by itself, on every page.
                    self.vaultModel().tick(store: self)
                    // The door's access file, from this Mac's own Tailscale, by itself and with nothing on a page.
                    self.doorModel().tick(store: self)
                    // This Mac's own key for the hub, which a VM or a container on this Mac does not have: registered
                    // over the SSH connection to the hub's server, with nothing on a page while it works.
                    self.keyModel().tick(store: self)
                    // The owner's access key on each Linux server, his way back after a lost Mac, with nothing on a page.
                    self.accessModel().tick(store: self)
                    // The join's hardening of each Linux server, put right again as root, with nothing on a page.
                    self.hardeningModel().tick(store: self)
                    // This app's crashes, to our own site while his Error reports switch is on, with nothing on a page.
                    ErrorReportsSender.shared.tick(store: self)
                    // The answer of the first run's page "Help improve Founderizer", to the hub, with nothing on a page.
                    FirstRunReportsSender.tick(store: self)
                    self.releasesTick()
                    // The Mac's language and name for the agents, once for each hub generation, with nothing on a page.
                    self.ownerProfileTick()
                    wait = self.untilRead
                }
                do { try await Task.sleep(for: .seconds(max(wait, 0.1))) } catch { return }
            }
        }
    }

    /// **An update waits for his press** (D-4): a release of the fleet that the hub offers to take, or a build of this
    /// app that installs itself or waits for its press. Nothing else marks it.
    var updateWaits: Bool {
        // A release that waits only for running work, with automatic updates on, waits for nothing of his: the hub
        // takes it at the first moment no turn runs (fix round 3, item 20; `ReleaseState.waitsForPress`).
        // Until this launch reads the releases, the reading kept with the fleet's, while it is of this hub generation.
        let releases = reading("releases") as ReleaseState? ?? keptReleases.reading(of: state?.db)
        let fleet = releases?.waitsForPress != nil
        // Until this launch's own read of our channel decides, the build of this app kept with the fleet's (`buildWaits`).
        return fleet || updates.buildWaits
    }

    /// **The sidebar's Update stands** (`UpdateBanner`; the owner, 15 November 2026: "if I had an update available I
    /// wanted to see a button above the settings one"): while an update waits for his press, while his press goes on —
    /// this Mac's build going in, the fleet's run that a press started. A press that stopped leaves its update waiting,
    /// so the Update stands with Try again.
    var updateShows: Bool { updateWaits || updates.pressed != nil || fleetUpdateWords != nil }

    /// **What the sidebar's Update says of the fleet's update while a press of it goes on**, or nil: what a press that
    /// waits for running work waits for, then Updating… until the run ends. A run that a press started — his, or one
    /// of this Mac's before the app started again for its own build — goes on in the hub, so the releases reading says
    /// it after a restart of the app too: its row is `updating` and not automatic.
    var fleetUpdateWords: String? {
        if let words = UpdatesModel.of(self).working { return words }
        guard let run = (reading("releases") as ReleaseState?)?.newestRun, run.isRunning, !run.automatic else { return nil }
        return String(l10n: "Updating…")
    }

    /// When the fleet's release was last read for the Update row.
    @ObservationIgnored private var releasesRead: Date?

    /// The fleet's release, read every five minutes under the hood for the Update row, into the reading the Updates
    /// page and System status draw. Nothing of it is on the screen: a read that fails keeps the last one of this launch,
    /// and takes away the one kept from the last launch (`keptReadingFailed`).
    private func releasesTick() {
        guard isFresh, let database = state?.db, state?.ui_features?.contains(ReleaseState.feature) == true,
              releasesRead.map({ Date().timeIntervalSince($0) >= 300 }) ?? true else { return }
        releasesRead = Date()
        let hub = hub
        Task { [weak self] in
            let read = try? await HubClient().releases(hub: hub, database: database)
            guard let self, self.hub == hub, self.state?.db == database else { return }
            if let read { self.keep(read, as: "releases") } else { self.keptReadingFailed("releases") }
        }
    }

    /// The hub and generation whose name and language this launch has looked at (`ownerProfileTick`).
    @ObservationIgnored private var profileLooked: String?

    /// **The Mac's language and name for the agents** (owner feature `owner_profile`; the owner, 16 November 2026: "when
    /// the fleet is setup on an app with spanish language, bots should talk in Spanish", and "Mac account + Settings
    /// row" to the picture of his name): once for each hub generation in a launch, a setting that the fleet has not set
    /// gets the Mac's own value — the first of its preferred languages, the first name of its account (`OwnerProfile`).
    /// Under the hood: nothing of it is on a page, and a read or a write that fails goes again at the next launch. His
    /// Name row is in Settings › General › Your profile.
    private func ownerProfileTick() {
        guard isFresh, let database = state?.db, state?.ui_features?.contains(OwnerProfile.feature) == true else { return }
        let looked = "\(hub.absoluteString)|\(database)"
        guard profileLooked != looked else { return }
        profileLooked = looked
        let language = OwnerProfile.languageTag(), name = OwnerProfile.accountName()
        guard language != nil || name != nil else { return }
        let hub = hub, client = installation
        Task {
            _ = try? await OwnerProfileClient().fill(hub: hub, database: database, client: client, language: language,
                                                     name: name)
        }
    }

    /// How long the read on the clock waits now.
    private var untilRead: TimeInterval {
        LiveChanges.untilRead(after: lastRead, now: ProcessInfo.processInfo.systemUptime)
    }

    func connect() async {
        do {
            let next = try HubClient.address(addressText)
            guard !sending else { return }
            if next != hub { childThreadRequest = nil; cancelEdit(); endProviderSetups(); state = nil; chatTimeline = ChatTimeline(); lastSuccess = nil; answeredUptime = nil; lastAnswer = nil; lastReceipt = nil; stopWatching(); stateToken = nil; forgetOlder() }
            // Another hub is not the fleet that this start of the app opened on (`welcomeCovers`), and its error
            // reports go on no answer of the hub before it (W17).
            if next != hub { welcomePassed = true; ErrorReportsDay.forget() }
            hub = next
            // A connect is the owner's own ask (the first run's own search never asks for a hub that "Start again"
            // left): that hub is passed over no more.
            StartAgain.LeftHubs.forget(next)
            hubAnsweredBefore = Self.answeredHubs.contains(next.absoluteString)
            AppDefaults.store.set(next.absoluteString, forKey: "hubAddress")
            connectionError = nil; failedReads = 0; readsFail = false; staleNoticeStood = false; readHeld = false
            await refresh()
        } catch { lastReadError = error; connectionError = HubReach.words(error, hub: nil).line }
    }

    /// **The app forgets this fleet** (the last step of "Start again", `StartAgain.run`; the owner's "Yes, build it"
    /// of 15 November 2026): what it keeps by this hub's address goes, in memory, in its settings and in its own
    /// folder, and the store is as on a Mac that was never given a hub, so the window is the first run on its welcome
    /// page. It asks the hub nothing. `hubServerDeleted`: the run deleted the hub's own server, so this Mac's key for
    /// that hub goes too; a hub that stays alive keeps it, and the first run passes over that hub's address until the
    /// owner connects to it himself (`StartAgain.LeftHubs`).
    ///
    /// **Never touched here**: a provider's token, the key of the private network, the app's own SSH key, the owner's
    /// own key, the backup's folder and its settings, the installation id and the app's own settings.
    ///
    /// `fleet` is the hub that the page of "Start again" read: when the store is at another hub by now, nothing is
    /// forgotten.
    func forgetFleet(_ fleet: URL, hubServerDeleted: Bool) {
        guard fleet == hub else { return }
        let old = hub, address = old.absoluteString
        // In memory first: a value that this store writes itself would come back with its next write.
        childThreadRequest = nil; cancelEdit(); endProviderSetups(); stopWatching()
        state = nil; chatTimeline = ChatTimeline(); lastSuccess = nil; answeredUptime = nil; lastAnswer = nil; lastReceipt = nil
        stateToken = nil
        forgetOlder()
        unwrittenReading = nil; unwrittenKept = [:]
        keptHealth = KeptReading(); keptReleases = KeptReading()
        let bar = "\(address)|"
        unplaced = unplaced.filter { !$0.hasPrefix(bar) }
        adding = adding.filter { !$0.hasPrefix(bar) }
        joinedFor = joinedFor.filter { !$0.key.hasPrefix(bar) }
        madeFor = madeFor.filter { !$0.key.hasPrefix(bar) }
        pins[address] = nil
        keptPages[address] = nil
        if seenContext.hasPrefix("\(address)\n") { seenContext = ""; seenReplies = [:] }
        // This hub's install model, also under the address of no hub: a first run's install is kept under both
        // (`keepInstall`), and the address of no hub is this store's address again after this step. None runs now.
        installModels[old] = nil
        if let none = try? HubClient.address(HubClient.defaultAddress) { installModels[none] = nil }
        firstRunBuild = nil; addServerBuild = nil
        // The models that this store keeps for this hub: none of them writes for it again.
        vaultModels[old] = nil; connectSwitches[old] = nil; accessModels[old] = nil; keyModels[old] = nil
        hardeningModels[old] = nil; doorModels[old] = nil
        checksModels = checksModels.filter { !$0.key.hasPrefix(bar) }
        if let waiting = pending, waiting.hub == old, !sending {
            try? outbox.clear(matching: waiting.requestID)
            pending = nil
        }
        // In the app's own folder: the kept readings of this hub, and its records of installs and builds.
        let readings = StartAgain.readingFiles(of: old, in: readingsFolder)
        for file in readings { try? FileManager.default.removeItem(at: file) }
        // A write of a reading or of a block that is on its way lands after this line: its files go once it ended.
        let late = [lastWrite, olderWrite].compactMap { $0 }
        if !late.isEmpty {
            Task.detached(priority: .utility) {
                for write in late { await write.value }
                for file in readings { try? FileManager.default.removeItem(at: file) }
            }
        }
        BuildRecords.shared.remove { $0.hub == address }
        InstallRecords.shared.remove { $0.hub == address }
        // In the app's settings: every value under this hub's address.
        StartAgain.forgetKept(hub: old, hubServerDeleted: hubServerDeleted)
        if hubServerDeleted { StartAgain.forgetMacKey(hub: old) } else { StartAgain.LeftHubs.note(old) }
        // As on a Mac that was never given a hub.
        hub = (try? HubClient.address(HubClient.defaultAddress)) ?? old
        addressText = ""
        hubAnsweredBefore = false; startedWithFleet = false; firstRunHolds = false
        // The next first run opens on its welcome page, with none of an earlier one's work (`FirstRunWork`).
        FirstRunWork.drop()
        connectionError = nil; lastReadError = nil; failedReads = 0; readsFail = false; staleNoticeStood = false; readHeld = false
        history = PageHistory(); homeChosen = false
    }

    // MARK: A reading waits while he scrolls

    /// The scroll views of chats, threads and knowledge files that move now, and the readings that wait for them
    /// (`ScrollHold`).
    @ObservationIgnored private let scrollHold = ScrollHold()

    /// The scroll view of a chat, a thread or a knowledge file began to move, or came to rest (`scrollsAsAChat`).
    func scroll(_ view: ObjectIdentifier, moving: Bool) { scrollHold.scroll(view, moving: moving) }

    /// **A new reading waits while a chat, a thread or a knowledge file scrolls** (`ScrollHold`): a reading draws again
    /// every view that reads it, and a scroll lost frames to it every three seconds. It comes in when the scroll rests,
    /// and at the latest nine seconds after the hub's last answer (`StateReading.scrollWaitMost`).
    func readingsRest() async {
        await scrollHold.rest(sinceAnswer: sinceAnswer)
    }

    /// Reads the fleet's state. **A call while a read is on its way is never dropped**: that read runs once more when
    /// it ends, and this call comes back after that one, so what the caller just did is in the state it sees.
    func refresh() async {
        await reads.run { [self] in await readState() }
    }

    private func readState() async {
        refreshing = true
        let requestedHub = hub
        // Eight seconds into this read, it is held until a read answers (`readPatience`; fix round 3b, item 17).
        readCount += 1
        let count = readCount, began = ContinuousClock.now
        let held = Task { [weak self, lastReadTook] in
            do { try await Task.sleep(for: max(Self.readPatience, lastReadTook * 2)) } catch { return }
            guard let self, self.readCount == count, self.refreshing, self.hub == requestedHub else { return }
            self.readHeld = true
        }
        defer {
            held.cancel()
            refreshing = false; clock = Date(); lastRead = ProcessInfo.processInfo.systemUptime; launched = true
            if !firstReadEnded { firstReadEnded = true }
        }
        do {
            let (window, data) = try await client.stateReading(at: requestedHub, present: OwnerPresenceProbe.now())
            guard requestedHub == hub else { return }
            // The hub answered, so this read is not slow, whatever waits now (`readPatience`), and the reading's age
            // counts from this answer (`lastSuccess`, `sinceAnswer`). A read that is slow already comes in at once.
            let answered = ContinuousClock.now, answeredAt = Date(), answeredUp = ProcessInfo.processInfo.systemUptime
            held.cancel()
            if !readHeld { await readingsRest() }
            guard requestedHub == hub else { return }
            // The window of the tasks, joined with the blocks of older tasks that this Mac holds (`OlderTasks`): at
            // the first read of a fleet in this start (a connect, a launch that kept no reading), the ones on its disk.
            let generation = olderReads
            if let loading = launchHistory {
                if window.db == lastWindow?.db {
                    let all = await loading.value
                    guard requestedHub == hub, generation == olderReads else { return }
                    (older, olderRows) = all
                }
                launchHistory = nil
            }
            let needsTasks = window.older_tasks?.isValid == true && older.db != window.db
            let needsRows = window.older_rows?.isValid == true && olderRows.db != window.db
            if needsTasks || needsRows {
                let folder = readingsFolder
                let blocks = await Task.detached(priority: .userInitiated) {
                    let files = KeptHistory(window: window, hub: requestedHub, folder: folder,
                                            tasks: needsTasks, rows: needsRows)
                    return KeptHistory.read(files.needed + files.later)
                }.value
                guard requestedHub == hub, generation == olderReads else { return }
                if needsTasks { older = OlderTasks(kept: blocks.tasks, db: window.db) }
                if needsRows { olderRows = OlderRows(kept: blocks.rows, db: window.db) }
            }
            let fresh = joined(window, shown: state)
            lastWindow = window
            if let state, state.db != fresh.db { childThreadRequest = nil; cancelEdit(); endProviderSetups(); lastReceipt = nil }
            var timeline = chatTimeline
            if timeline.update(messages: fresh.messages, reports: fresh.reports) { chatTimeline = timeline }
            notePlacing(fresh)
            // A manager that has its server is no setup that an earlier start left unfinished: the welcome page in
            // front of it is passed for this start, whatever a later reading says.
            if startedWithFleet, !welcomePassed, fresh.agents.first(where: { $0.role == "manager" })?.placed == true {
                welcomePassed = true
            }
            noteAdded(fresh)
            state = fresh
            chooseHome()
            follow(fresh)
            markRepliesSeen()
            lastSuccess = answeredAt
            answeredUptime = answeredUp
            lastAnswer = began
            watchBreak()
            lastReadTook = answered - began
            if readHeld { readHeld = false }
            connectionError = nil
            lastReadError = nil
            staleNoticeStood = false
            failedReads = 0
            if readsFail { readsFail = false }
            keepReading(data)
            readOlder()
            readOlderRows()
            claimFromLink.tryNow(store: self)
            if !hubAnsweredBefore {
                hubAnsweredBefore = true
                Self.answeredHubs = Self.answeredHubs.filter { $0 != requestedHub.absoluteString } + [requestedHub.absoluteString]
            }
            prefetch(fleet: PagePrefetch.fleet, agent: PagePrefetch.agent)
            if let pending, pending.hub == hub, (fresh.receipt(for: pending) != nil || fresh.hasSteeringReceipt(for: pending)) {
                try finish(pending)
            }
            await notifications.update(hub: requestedHub, state: fresh)
        } catch {
            guard requestedHub == hub else { return }
            // A read of the address of no hub always fails, and that is no news: it does not take away the line about
            // an address that the owner typed in Settings and that was refused (`quietAboutNoHub`).
            if hubIsUnset, case .invalidAddress? = lastReadError as? HubError { return }
            lastReadError = error
            failedReads += 1
            if !readsFail { readsFail = true }
            if HubReach.tells(failedReads: failedReads, answeredBefore: state != nil, sinceAnswer: sinceAnswer) {
                connectionError = HubReach.words(error, hub: requestedHub).line
            }
        }
    }

    /// **At the end of one break with no answer, the screen says it** (`StateReading.limit`): the reading turns old at
    /// that moment, and when reads failed meanwhile the hub's own notice stands at once, in the words of the last one
    /// ("Your hub did not answer.", "Your hub took too long to answer"). Without this, a hub whose reads hang (10
    /// seconds each) was said only at the next read that failed, up to 13 seconds after the break. The clock stops while
    /// the Mac sleeps, as `sinceAnswer` does.
    private func watchBreak() {
        breakEnds?.cancel()
        let answered = answeredUptime, watched = hub
        // From the answer itself: a scroll can hold the answer for some seconds before it comes in (`readingsRest`).
        let left = StateReading.limit - (sinceAnswer ?? 0)
        breakEnds = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, left)), clock: .suspending) } catch { return }
            guard let self, self.hub == watched, self.answeredUptime == answered else { return }
            self.clock = Date()
            if self.connectionError == nil, let error = self.lastReadError,
               HubReach.tells(failedReads: self.failedReads, answeredBefore: self.state != nil, sinceAnswer: self.sinceAnswer) {
                self.connectionError = HubReach.words(error, hub: watched).line
            }
        }
    }

    // MARK: Live changes

    /// **A page loop that reads the hub naps here between two reads**, in place of a sleep. The nap ends after
    /// `seconds`, or as soon as a wake comes after it began: a change that the hub announced (at most one in two
    /// seconds) or the answer to a write of this Mac. True for a wake. It throws when its loop is cancelled, as a
    /// sleep does.
    @discardableResult
    func nap(_ seconds: Double) async throws -> Bool { try await wakes.nap(seconds) }

    /// Starts the watcher of `/ui/wait` while the hub offers it, from the token of this read, and stops it when the
    /// feature goes away or the generation changes. A hub without it is read on the clocks, as before.
    private func follow(_ fresh: HubState) {
        stateToken = fresh.liveToken
        let token = fresh.offersLiveChanges ? fresh.liveToken : nil
        if let watched, watched.hub == hub, watched.database == fresh.db, token != nil { return }
        guard watched != nil || token != nil else { return }
        stopWatching()
        guard let token else { return }
        watches += 1
        let key = Watched(hub: hub, database: fresh.db, id: watches)
        watched = key
        watcher = Task { [weak self] in await self?.watchChanges(key, from: token) }
    }

    private func stopWatching() {
        watcher?.cancel(); watcher = nil; watched = nil
        heldWake?.cancel(); heldWake = nil
        cap.reset(); wakeToken = nil
    }

    /// One wait after another, each from the newest token, and a wake for each change. **Nothing of it is ever on the
    /// screen**: a wait that failed sets no connection error and no state, and the next one waits 1 to 30 seconds.
    /// A changed generation ends it, because only the next read of the state learns the new one, and that read starts
    /// the next watcher.
    private func watchChanges(_ key: Watched, from token: LiveToken) async {
        var watch = LiveWatch(from: token)
        let changes = LiveChangesClient()
        while !Task.isCancelled, watched == key {
            do {
                let started = ProcessInfo.processInfo.systemUptime
                let answer = try await changes.wait(hub: key.hub, database: key.database, since: watch.since)
                guard !Task.isCancelled, watched == key else { return }
                switch answer {
                case .token(let next):
                    switch watch.answered(next, took: ProcessInfo.processInfo.systemUptime - started, jitter: .random(in: 0...1)) {
                    case .wake: woke(next)
                    case .wait: break
                    case .pause(let delay): do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    }
                case .generationChanged:
                    watcher = nil; watched = nil
                    woke(nil)
                    return
                }
            } catch {
                guard !Task.isCancelled, watched == key else { return }
                do { try await Task.sleep(for: .seconds(watch.failed(jitter: .random(in: 0...1)))) } catch { return }
            }
        }
    }

    /// A change that the hub announced, or a generation it no longer has (nil). **At most one wake goes out in two
    /// seconds**: the ones inside them fold into one at their end, which carries the newest token.
    private func woke(_ token: LiveToken?) {
        wakeToken = token
        let now = ProcessInfo.processInfo.systemUptime
        switch cap.wake(at: now) {
        case .now: wake()
        case .at(let time):
            heldWake = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, time - now)))
                guard !Task.isCancelled, let self else { return }
                self.heldWake = nil
                self.cap.fired(at: ProcessInfo.processInfo.systemUptime)
                self.wake()
            }
        case .folded: break
        }
    }

    /// One wake: the state is read, unless its newest read already shows the change, and every page loop that naps
    /// reads its own part now. The central vault reads again as well.
    private func wake() {
        let covered = wakeToken.flatMap { change in stateToken.map { $0.covers(change) } } ?? false
        if !covered { Task { await refresh() } }
        wakes.wake()
        vaultModel().tick(store: self, woken: true)
    }

    /// **His feedback from a card** (`FeedbackBox`): the chat's own send (`sendText`), to the agent that the card's rule
    /// names, with what it is about, from the card's own draft and files.
    func sendFeedback(_ feedback: Feedback) async {
        guard let state else { return }
        let composer = Self.stageKey(about: feedback.about, database: state.db)
        guard let files = await freshFiles(for: composer) else { return }
        await sendText(feedbackDrafts[composer] ?? "", recipient: feedback.recipient, files: files, about: feedback.about)
    }

    /// His words to the chat's agent, or his answer to a request in words: the box's words, or `words` where the app
    /// gives them (a reply that he pressed, `NeedAnswerBox.sendQuickReply`), with the box's files either way. Words
    /// given here leave his box's own words as they are.
    func send(needID: Int? = nil, words: String? = nil) async {
        let text = words ?? needID.map { answers[String($0)] ?? "" } ?? draft(for: chatAgent)
        let recipient = needID.flatMap { id in state?.needs.first { $0.id == id }?.by } ?? chatAgent
        let composer = needID.map { Self.stageKey(need: $0) } ?? Self.stageKey(agent: chatAgent)
        // A file that went up an hour ago may be another file under its number by now: it goes up again first.
        guard let ready = await freshFiles(for: composer) else { return }
        let (files, gifts) = outgoing(ready, of: composer)
        await sendText(text, needID: needID, recipient: recipient, files: files, gifts: gifts)
    }

    /// **The files of a composer as a message carries them**: a skill that he gives, in a box that takes skills, goes
    /// in `skills` (`MessageSkill.give`) and never also in `attachments`; every other file is a file.
    func outgoing(_ ready: [Int], of composer: String) -> (files: [Int], gifts: [Int]) {
        let gifts = Set(stagedFiles(for: composer).filter { skillName(of: $0, in: composer) != nil }.compactMap(\.attachmentID))
        return (ready.filter { !gifts.contains($0) }, ready.filter(gifts.contains))
    }

    /// A message of the owner's that the app writes for him: the line that names a secret he saved from this chat, its
    /// reference and who holds it, never its value. It goes the way of every message — the outbox, its receipt and its
    /// retry — and the chat's draft stays as it is. True once the hub confirmed it.
    func say(_ text: String, to agent: String) async -> Bool {
        guard canWrite, canChat(with: agent) else { return false }
        await sendText(text, recipient: agent)
        return pending == nil && sendError == nil && storageError == nil
    }

    /// The owner pressed one of a Needs-you item's own options (API 1.18): the hub takes the index and writes that
    /// option's own words as the answer. Nothing else of the path changes — the same outbox, receipt and replay.
    func answer(_ need: OwnerNeed, choice: Int) async {
        guard canWrite, let state, openNeeds.contains(where: { $0.id == need.id }) else { return }
        let options = need.choices
        guard options.indices.contains(choice) else { return }
        var approval: (statement: String, signature: String)?
        switch await DoorCallSigning.approval(for: need, choice: choice, store: self, hub: hub, database: state.db) {
        case .none: break
        case .signed(let statement, let signature): approval = (statement, signature)
        case .refused(let line):
            // Review point 5.6: this Mac signs Run it once only for the script that its card shows. Nothing was
            // signed and nothing is sent: the line stands where a write that the hub refused stands, with Discard.
            var refused = PendingRequest(hub: hub, database: state.db, client: installation, needID: need.id,
                                         choice: choice, approval: nil, text: options[choice])
            refused.refusal = line
            do { try outbox.save(refused); pending = refused; sendError = line }
            catch { storageFailed(String(l10n: "Cannot save this answer. Nothing was sent."), cause: error) }
            return
        }
        // API 1.94: the first option of an item that names an account makes a GitHub App there (GitHubManifestFlow)
        if choice == 0, let owner = need.github_app {
            Task { await GitHubManifestFlow.start(owner: owner, store: self) }
        }
        // API 1.95: the first option of an item for his phone opens the Add device picture (`DevicesSection`)
        if choice == 0, need.add_device == 1 {
            addDeviceAsked = true
            destination = .settings(.servers)
        }
        let request = PendingRequest(hub: hub, database: state.db, client: installation, needID: need.id,
                                     choice: choice, approval: approval, text: options[choice])
        do {
            try outbox.save(request)
            pending = request
            sending = true
        } catch {
            storageFailed(String(l10n: "Cannot save this answer. Nothing was sent."), cause: error)
            return
        }
        await transmit(request)
    }

    /// The options he ticked on a Needs-you item whose options combine (owner feature `need_talk`, API 1.106): the hub
    /// joins their own words as the answer. The same outbox, receipt and replay as a press.
    func answer(_ need: OwnerNeed, choices: [Int]) async {
        guard canWrite, let state, openNeeds.contains(where: { $0.id == need.id }), need.combines else { return }
        let ticked = Array(Set(choices)).sorted()
        guard !ticked.isEmpty, ticked.allSatisfy(need.choices.indices.contains) else { return }
        let request = PendingRequest(hub: hub, database: state.db, client: installation, needID: need.id,
                                     choices: ticked, text: ticked.map { need.choices[$0] }.joined(separator: "; "))
        do {
            try outbox.save(request)
            pending = request
            sending = true
        } catch {
            storageFailed(String(l10n: "Cannot save this answer. Nothing was sent."), cause: error)
            return
        }
        await transmit(request)
    }

    // MARK: Run on the command of a hand step (owner feature need_run, API 1.197)

    /// **Where this Mac runs the command of `need` at a press of Run, or nil: its card shows no Run.** A hub that names
    /// `need_run`, an item whose command passes this Mac's own checks (`NeedRun.command`), and a place that this Mac
    /// reaches: itself, or a Mac of the fleet by the machines' readings (`NeedRun.place`).
    func runPlace(_ need: OwnerNeed) -> NeedRun.Place? {
        guard state?.ui_features?.contains(NeedRun.feature) == true, NeedRun.command(of: need) != nil else { return nil }
        return NeedRun.place(of: need, machines: runMachines)
    }

    /// Reads the machines for the cards whose command runs on a Mac of the fleet: at most once in 30 seconds while
    /// such a card shows, and at once (`now`) at a press, so that a press takes the address of now.
    func readRunMachines(now: Bool = false) async {
        guard let state else { return }
        let clock = ContinuousClock()
        if !now, let read = runMachinesRead, clock.now - read < .seconds(30) { return }
        runMachinesRead = clock.now
        let hub = hub, database = state.db
        guard let list = try? await client.machines(hub: hub, database: database),
              (try? list.validate(database: database)) != nil, self.hub == hub, self.state?.db == database else { return }
        runMachines = list.machines
    }

    /// **His press of Run on the command of `need`**: this Mac runs it where the item says, and its exit status and the
    /// end of its output go as his answer, through the outbox as every answer goes (the hook). A run that did not
    /// reach its Mac sends nothing, and the card says so under the command. Stop ends the run and sends nothing. Each
    /// press has its own id: after every wait the press goes on only while the state is still its own.
    func run(_ need: OwnerNeed) async {
        guard answersWrites, state?.ui_features?.contains(NeedRun.feature) == true,
              let command = NeedRun.command(of: need), needRuns[need.id]?.busy != true, pending?.needID != need.id
        else { return }
        let press = UUID()
        needRuns[need.id] = .running(press)
        watchRunsAtQuit()
        if need.run_on != NeedRun.ownMac { await readRunMachines(now: true) }
        guard needRuns[need.id] == .running(press) else { return }      // Stop came while the machines were read
        guard let place = NeedRun.place(of: need, machines: runMachines) else {
            needRuns[need.id] = .notReached("")
            return
        }
        let job = NeedRunJob(command: command, place: place)
        runJobs[need.id] = job
        let outcome = await job.run()
        if runJobs[need.id] === job { runJobs[need.id] = nil }
        guard needRuns[need.id] == .running(press) else { return }
        switch outcome {
        case .stopped:
            needRuns[need.id] = nil
        case .notReached(let said):
            needRuns[need.id] = .notReached(said)
        case .ran(let status, let output):
            // The command ran: its answer waits for the outbox as a pressed option waits, with no Stop.
            needRuns[need.id] = .sending
            await answer(need, ran: NeedRunResult(status: status, output: output))
            if needRuns[need.id] == .sending { needRuns[need.id] = nil }
        }
    }

    /// His press of Stop on a run of `need`: the job ends, and its outcome clears the state. Before the job started
    /// (the machines are read), the press ends there.
    func stopRun(_ need: OwnerNeed) {
        guard case .running? = needRuns[need.id] else { return }
        if let job = runJobs[need.id] { job.stop() } else { needRuns[need.id] = nil }
    }

    /// A quit of the app stops the runs on this Mac, as a closed Terminal window ends its commands.
    private func watchRunsAtQuit() {
        guard runQuitWatch == nil else { return }
        runQuitWatch = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.runJobs.values.forEach { $0.stop() } }
        }
    }

    /// What this Mac read of a run of `need`'s command, as his answer: the hub writes the words of the answer itself
    /// (owner feature `need_run`), so `text` holds them only for this app. It waits while another request is on its
    /// way, as a press waits. An item that closed meanwhile (withdrawn, replaced, answered on the phone) takes
    /// nothing: the hub refuses an answer to a closed item, and nothing waits for this one any more.
    func answer(_ need: OwnerNeed, ran: NeedRunResult) async {
        guard await writable(), let state, let on = need.run_on,
              let open = openNeeds.first(where: { $0.id == need.id }), open.signsTheSame(as: need) else { return }
        let request = PendingRequest(hub: hub, database: state.db, client: installation, needID: need.id, ran: ran,
                                     text: NeedRun.answerWords(on: on, status: ran.status))
        do {
            try outbox.save(request)
            pending = request
            sending = true
        } catch {
            storageFailed(String(l10n: "Cannot save this answer. Nothing was sent."), cause: error)
            return
        }
        await transmit(request)
    }

    private func sendText(_ value: String, needID: Int? = nil, recipient: String, replaces: String? = nil,
                          files: [Int] = [], gifts: [Int] = [], about: MessagePlace? = nil) async {
        guard canWrite, let state else { return }
        guard needID != nil || canChat(with: recipient) else { return }
        guard files.isEmpty || supportsAttachments else { return }
        // A skill goes only in a message, to a hub that takes it (`outgoing`).
        guard gifts.isEmpty || needID == nil && replaces == nil && state.ui_features?.contains(SkillPackage.feature) == true
        else { return }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // A message carries text, or files, or both. Without a file it must carry text, as the hub asks.
        guard !text.isEmpty || !files.isEmpty || !gifts.isEmpty, text.count <= 16_000 else { return }
        if let needID, !openNeeds.contains(where: { $0.id == needID }) { return }
        // `about` only on a hub that takes it: an older hub refuses a field that it does not know.
        let about = state.ui_features?.contains("message_about") == true ? about : nil
        // The @ tags of the words that go, read from them now (`AgentTags.mentions`), a correction's too: the final
        // words decide, so a tag typed in full counts and a broken one is words. [] stops the hub's own reading.
        let mentions = needID == nil ? agentTags(except: recipient)?.mentions(in: text) : nil
        let request = PendingRequest(hub: hub, database: state.db, client: installation, needID: needID,
                                     recipient: needID == nil && supportsDirectChat ? recipient : nil,
                                     replacesRequestID: replaces, attachments: files, about: about, mentions: mentions,
                                     skills: gifts.isEmpty ? nil : gifts.map { .give($0) }, text: text)
        do {
            try outbox.save(request)
            pending = request
            sending = true
        } catch {
            storageFailed(String(l10n: "Cannot save this request. Nothing was sent."), cause: error)
            return
        }
        await transmit(request)
    }

    @discardableResult
    func command(_ command: OwnerCommand, note: String = "", attachments: [Int] = []) async -> Bool {
        guard canWrite, let state, state.ui_features?.contains(command.requiredFeature) == true else { return false }
        lastControlReceipt = nil
        // `attachments`: a guidance's files, which the hub already holds (owner API 1.223).
        let request = PendingRequest(hub: hub, database: state.db, client: installation, command: command,
                                     attachments: attachments, text: note)
        do {
            guard try request.body().count <= 65_536 else { sendError = String(l10n: "This request is too large. Shorten it before saving."); return false }
        } catch { sendError = String(l10n: "The command fields are invalid. Nothing was sent."); return false }
        do { try outbox.save(request); pending = request; sending = true }
        catch { storageError = String(l10n: "Cannot save this command. Nothing was sent."); return false }
        await transmit(request)
        return pending == nil && storageError == nil && sendError == nil
    }

    /// **How long a request's own files stay the files that it names**: each went up at most `uploadStaysFor` before
    /// its send (`freshFiles`), and the hub lets an uncarried upload go an hour after it went up, after which a later
    /// file can take its number. So a Try again later than this could carry another file.
    static let retryKeepsFilesFor: Double = 10 * 60

    func retry() async {
        guard canRetry, let pending else { return }
        // A request with files that waited longer than that is not sent again as it is: a read first finishes it if
        // the hub took it after all; else it stands refused with Discard, and a new Send takes its files up again.
        if !(pending.attachments + pending.givenFiles).isEmpty,
           Date().timeIntervalSince(pending.createdAt) > Self.retryKeepsFilesFor {
            await refresh()
            guard var late = self.pending, late.requestID == pending.requestID, late.refusal == nil else { return }
            let line = String(l10n: "Its files waited too long. Discard it and send it again: its files go up again first.")
            late.refusal = line
            do { try outbox.save(late); self.pending = late; sendError = line }
            catch { storageFailed(String(l10n: "Cannot save the refusal. The original request is retained."), cause: error) }
            return
        }
        await transmit(pending)
    }

    /// Sends one save of a control that saves itself, when no other request waits, so saves go one at a time. A
    /// refusal of the hub leaves the outbox at once, so the next save can go; the control shows the hub's words. A
    /// refused login text stays in the window's request line until the owner discards it. A request without an answer
    /// stays in the outbox: Retry, here or in the window's request line, sends it again.
    ///
    /// queue false: a control that saves itself does not wait behind a request that waits in the outbox and is not on
    /// its way, which a refusal leaves there until the owner discards it; it comes back `.behind` at once. It still
    /// waits behind a request that is on its way, which ends in seconds.
    func save(_ command: OwnerCommand, note: String = "", queue: Bool = true) async -> SaveResult {
        let hub = hub, database = state?.db
        while !canWrite {
            guard self.hub == hub, state?.db == database, storageError == nil else { return .refused(String(l10n: "Not saved. The hub connection changed.")) }
            if !queue, !sending, pending != nil { return .behind }
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return .refused(String(l10n: "Not saved.")) }
        }
        if await self.command(command, note: note) { return .saved(sha256: lastControlReceipt?.sha256) }
        guard let request = pending, request.command == command else {
            return .refused(sendError ?? storageError ?? String(l10n: "Not saved. This hub does not offer this change."))
        }
        return request.refusal == nil ? .unconfirmed(request.requestID) : refused(request)
    }

    /// **Waits while this Mac cannot write**, as a save does, and says whether it can now: false when the hub or its
    /// generation changed meanwhile, or this Mac cannot keep a request. A control that writes stays as it is while
    /// another request is on its way, and its press goes when the hub can take it.
    func writable() async -> Bool {
        let hub = hub, database = state?.db
        while !canWrite {
            guard self.hub == hub, state?.db == database, storageError == nil else { return false }
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return false }
        }
        return true
    }

    /// Waits while the request `id` waits for its answer, then says what came of it.
    func answer(to id: UUID) async -> SaveResult {
        let hub = hub
        while let request = pending, request.requestID == id, request.refusal == nil {
            guard self.hub == hub else { return .refused(String(l10n: "Not saved. The hub connection changed.")) }
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return .unconfirmed(id) }
        }
        if let request = pending, request.requestID == id { return refused(request) }
        let receipt = lastControlReceipt
        return .saved(sha256: receipt?.request_id.lowercased() == id.uuidString.lowercased() ? receipt?.sha256 : nil)
    }

    /// Removes a save that the hub refused from the outbox, and gives the hub's words.
    private func refused(_ request: PendingRequest) -> SaveResult {
        guard let refusal = request.refusedByHub else { return .refused(request.refusal ?? "") }
        discardRefused()
        return refusal.status == 409 ? .conflict(refusal.words) : .refused(refusal.words)
    }

    /// A reply came in this agent's chat after the owner last had that chat open: by the marks of this reading's hub
    /// generation, and none while that generation has no marks yet (`markRepliesSeen`).
    func hasNewReply(from agent: String) -> Bool {
        guard let state, seenContext == "\(hub.absoluteString)\n\(state.db)" else { return false }
        return newestReply(agent) > (seenReplies[agent] ?? 0)
    }

    private func newestReply(_ agent: String) -> Int {
        newestReplies[agent] ?? 0
    }

    /// The agent has written in its chat at least once, so Mark as unread has a reply to mark.
    func hasReply(from agent: String) -> Bool {
        newestReply(agent) > 0
    }

    /// Mark as read, from the right-click of the agent's row: its newest reply counts as seen, as if he had opened
    /// the chat.
    func markRead(_ agent: String) {
        guard let state else { return }
        markRepliesSeen()
        guard seenContext == "\(hub.absoluteString)\n\(state.db)" else { return }   // its marks wait (markRepliesSeen)
        if keptUnread == agent { keptUnread = nil }
        var seen = seenReplies
        seen[agent] = newestReply(agent)
        keep(seen, context: seenContext)
    }

    /// Mark as unread: the agent's newest reply is new again, so its dot comes back until he opens the chat.
    func markUnread(_ agent: String) {
        guard let state, newestReply(agent) > 0 else { return }
        markRepliesSeen()
        guard seenContext == "\(hub.absoluteString)\n\(state.db)" else { return }   // its marks wait (markRepliesSeen)
        if case .agent(let open) = destination, open == agent { keptUnread = agent }
        var seen = seenReplies
        seen[agent] = newestReply(agent) - 1
        keep(seen, context: seenContext)
    }

    /// The agents pinned to the top of the sidebar on this hub, newest pin first.
    var pinned: [String] { pins[hub.absoluteString] ?? [] }

    /// Pin to top, or Unpin, from the right-click of the agent's row.
    func togglePin(_ agent: String) {
        let list = (pinned.contains(agent) ? [] : [agent]) + pinned.filter { $0 != agent }
        pins[hub.absoluteString] = list.isEmpty ? nil : list
        AppDefaults.store.set(pins, forKey: "pinnedAgents")
    }

    /// The open chat's replies are seen. A new hub generation takes the replies that it has as seen, so that only later
    /// replies are new: **once its reading holds every report** (owner API 1.258). Before the blocks of older reports
    /// came, an agent whose newest reply is in one of them would take an older reply as seen, and its chat would show
    /// that reply as new when the block comes (a restore, a first connect). Until then no chat shows a new reply. A read
    /// of the lists of older rows that failed ends the wait: then the marks take the reading as it is.
    private func markRepliesSeen() {
        guard takeOverCard == nil else { return }       // the take-over card covers the chat: not read yet
        guard let state else { return }
        let context = "\(hub.absoluteString)\n\(state.db)"
        if seenContext != context, let window = lastWindow, window.db == state.db, rowsReadFailed != state.db,
           olderRows.behind(window).contains(.reports) { return }
        var seen = seenContext == context ? seenReplies : [:]
        if seenContext != context { for agent in state.agents { seen[agent.name] = newestReply(agent.name) } }
        // **Not while the card over the window covers the chat** (`detail`): its replies are read when it closes.
        if detail == nil, case .agent(let name) = destination, name != keptUnread, shown.countsAsRead(name) {
            seen[name] = newestReply(name)
        }
        keep(seen, context: context)
    }

    private func keep(_ seen: [String: Int], context: String) {
        guard seen != seenReplies || seenContext != context else { return }
        seenContext = context; seenReplies = seen
        AppDefaults.store.set(["context": context, "seen": seen], forKey: "chatRepliesSeen")
    }

    func discardRefused() {
        guard !sending, let pending, pending.refusal != nil else { return }
        do {
            try outbox.clear(matching: pending.requestID)
            self.pending = nil
            sendError = nil
        } catch { storageError = error.localizedDescription }
    }

    /// **How often a message sends its gift again, and after how long**: a 409, 500, 502 or 503 of a gift
    /// (`refused_gift`, owner API 1.304) can follow a commit that landed, or a hub that was busy checking another file,
    /// and the same request again (its id, its words, its skills) is given from the same bytes and written once. After
    /// the last try the request stands as any message does: refused, with Discard and the hub's words, or with Try
    /// again; its skill stays in the box. A count, so a refusal that lasts (the agent's Shell box is off) ends.
    static let giftTries = 3
    static var giftPause: Duration = .seconds(2)

    /// `rebased` is true for the one send that follows a stale-base 409, so it is never tried twice. `giftTry`: the
    /// sends of the same request that came before this one, after a gift's 409 or 5xx (`giftTries`).
    private func transmit(_ request: PendingRequest, rebased: Bool = false, giftTry: Int = 0) async {
        sending = true
        sendError = nil
        defer { sending = false }
        do {
            if request.command != nil { lastControlReceipt = try await client.command(request) }
            else { lastReceipt = try await client.send(request) }
            try finish(request)
        } catch {
            // A concurrent read may already have reconciled this exact request.
            guard pending?.requestID == request.requestID else { return }
            if let error = error as? HubError, error.conflict, !rebased, let next = await rebase(request) {
                await transmit(next, rebased: true)
                return
            }
            if case HubError.refusal(let refused) = error, let gift = refused.refusedGift,
               request.givenFiles.contains(gift), [409, 500, 502, 503].contains(refused.status), giftTry + 1 < Self.giftTries {
                try? await Task.sleep(for: Self.giftPause * (giftTry + 1))
                guard pending?.requestID == request.requestID, pending?.refusal == nil else { return }
                await transmit(request, rebased: rebased, giftTry: giftTry + 1)
                return
            }
            // A gift that the hub refused (`refused_gift`, owner API 1.304) is about the skill, never about login text in
            // his words: it is refused as any message is, and its chip says so too (`skillRefused`).
            if case HubError.refusal(let refused) = error, refused.refusedGift != nil { skillRefused(request, refused) }
            if case HubError.refusal(let refused) = error, refused.status == 422, refused.refusedGift == nil {
                secretRefusals += 1
                draft = ""
                answers = [:]
                agentDrafts = [:]
                guidanceDrafts = [:]
                cancelEdit()
                do { pending = try outbox.rejectSecret(matching: request.requestID, drafts: AppDefaults.store) }
                catch { storageError = String(l10n: "Cannot remove rejected text from local storage. Sending is blocked.") }
                sendError = String(l10n: "The hub refused registered login text.")
            } else if let error = error as? HubError, case .refusal(let refusal) = error, error.definitiveRefusal || error.conflict {
                var refused = request
                refused.refuse(refusal)
                do { try outbox.save(refused); pending = refused }
                catch { storageError = String(l10n: "Cannot save the refusal. The original request is retained.") }
                sendError = error.localizedDescription
            } else {
                sendError = String(l10n: "Receipt not confirmed. The saved request is kept; refresh to check it or retry the same request.")
            }
        }
        await refresh()
    }

    /// The one retry a 409 deserves, and only when the base really moved.
    ///
    /// The hub refuses a write whose `base_revision` or `base_sha256` is not the current one and keeps the current
    /// one, so the owner's own command against that base is exactly what he meant; it used to be dropped here as a
    /// final refusal, and his press was lost to an agent's commit he never saw. So this reads the base again and,
    /// when it has moved and the command still means the same against it, saves the same command against the fresh
    /// base with a new request UUID — the hub refuses the old UUID with another body — and that one is sent once.
    /// A base that did not move means the 409 was one of the final kinds, and nothing is retried.
    private func rebase(_ request: PendingRequest) async -> PendingRequest? {
        guard let command = request.command, let base = command.base, command.rebasesSafely,
              let fresh = try? await client.currentBase(for: command, hub: request.hub, database: request.database),
              fresh != base, let rebuilt = command.rebased(to: fresh),
              pending?.requestID == request.requestID else { return nil }
        let next = PendingRequest(hub: request.hub, database: request.database, client: request.client,
                                  command: rebuilt, attachments: request.attachments, text: request.text)
        do {
            try outbox.clear(matching: request.requestID)
            try outbox.save(next)
        } catch {
            try? outbox.save(request)
            return nil
        }
        pending = next
        return next
    }

    private func finish(_ request: PendingRequest) throws {
        try outbox.clear(matching: request.requestID)
        if let command = request.command {
            // Commands have no chat draft and are acknowledged by their own receipt. A guidance's files that the hub
            // took leave its box.
            if case .steer = command {
                let box = Self.stageKey(of: request)
                clearStaged(box, sent: request.attachments)
                if guidanceDrafts[box] == request.text { guidanceDrafts[box] = nil }
            }
        } else if request.replacesRequestID != nil {
            if editingMessage?.id == request.replacesRequestID { cancelEdit() }
        } else if request.needID == nil, let about = request.about {
            // A card's feedback empties its own box, and leaves the chat's draft as it is.
            let box = Self.stageKey(about: about, database: request.database)
            if feedbackDrafts[box]?.trimmingCharacters(in: .whitespacesAndNewlines) == request.text { feedbackDrafts[box] = nil }
            clearStaged(box, sent: request.attachments)
        } else if request.needID == nil {
            let agent = request.recipient ?? "manager"
            if draft(for: agent).trimmingCharacters(in: .whitespacesAndNewlines) == request.text { setDraft("", for: agent) }
            clearStaged(Self.stageKey(agent: agent), sent: request.attachments + request.givenFiles)
        } else if let id = request.needID {
            if answers[String(id)]?.trimmingCharacters(in: .whitespacesAndNewlines) == request.text {
                answers[String(id)] = nil
            }
            clearStaged(Self.stageKey(need: id), sent: request.attachments)
        }
        pending = nil
        sendError = nil
    }
}
