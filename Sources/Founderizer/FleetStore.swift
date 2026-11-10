import AppKit
import FleetCore
import Foundation
import Observation

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
    /// have no case of their own.
    ///
    /// **No Dashboard and no Agents table** (the owner's yes of 28 October 2026 to D-4, "the whole map"): the agents'
    /// rows of the sidebar are the one list of the agents, and the app opens on Needs you while a request waits, else on
    /// the manager's chat (`FleetStore.home`). `agents` is every agent with its role, server, account and usage, from the
    /// sidebar's row under Tasks (`AgentsPage`). `app` is one app's own page of Settings › Apps (the owner's yes of 10
    /// November 2026 to its split), as `server` is one server's page of Settings › Servers.
    case needs, activity, goals, agents, addAgent, server(String), addServer, task(Int), agent(String),
         agentDetail(String, AgentTab), signIn(String), agentRule(String, ProfileSectionID?), settings(SettingsTab),
         app(AppsGroup)

    /// The agent whose page shows, or nil on every other page.
    var agentName: String? {
        switch self {
        case .agent(let name), .agentDetail(let name, _), .agentRule(let name, _), .signIn(let name): name
        default: nil
        }
    }

    /// The section of Settings that shows: a server's page and Add server are pages of Settings › Servers.
    var settingsTab: SettingsTab? {
        switch self {
        case .settings(let tab): tab
        case .server, .addServer: .servers
        case .app: .apps
        default: nil
        }
    }

    /// **This page draws a sidebar of its own**, so it draws the window's notices too, beside that sidebar and not
    /// over it (`pageNotices`).
    var ownsSidebar: Bool {
        switch self {
        case .agentDetail, .agentRule, .settings, .server, .addServer, .app: true
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
    func checksModel(machine: String, kind: MachineCheckout) -> MachineChecksModel {
        let key = checksKey(machine)
        // The kind is the hub's own answer about that machine, and a later reading can settle it (a server whose
        // system no reading had yet). A kept model takes the newer answer; nothing else about it changes.
        if let model = checksModels[key] {
            if model.kind != kind { model.kind = kind }
            return model
        }
        let model = MachineChecksModel(machine: machine, hub: hub, kind: kind)
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

    /// The owner's access key on this hub's servers, put there by itself: one model for each hub address.
    @ObservationIgnored private var accessModels: [URL: OwnerAccessModel] = [:]
    func accessModel() -> OwnerAccessModel {
        if let model = accessModels[hub] { return model }
        let model = OwnerAccessModel(hub: hub)
        accessModels[hub] = model
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
    var state: HubState? {
        // Each agent's role, for every line of the app that names an agent (`AgentNames`): the owner, 10 November
        // 2026, chose the role as an agent's main label.
        didSet { AgentNames.shared.read((state?.agents ?? []).map { ($0.name, $0.title) }) }
    }
    private(set) var chatTimeline = ChatTimeline()
    /// The page this app opens on when somebody asked for one with
    /// `-openPage settings.<tab> | agent.<name>.<section> | task.<id> | needs | tasks | …`, which is how one screen can
    /// be looked at without clicking to it; otherwise `home`. The argument domain is not written to the app's settings,
    /// so it leaves no trace. Every page that a sidebar row opens is here, because a screen that cannot be opened on its
    /// own is a screen that nobody checks. The names of the pages that became sections of Settings (servers, devices,
    /// updates, mcps, subscription) still open them there.
    static var asked: Destination? {
        switch UserDefaults.standard.string(forKey: "openPage") {
        case "settings": return .settings(.general)
        // `app.<github|drive|gmail|mcp>`: one app's page of Settings › Apps; its MCP servers were once a section, `mcps`.
        case "settings.mcps", "mcps": return .app(.mcp)
        case let page? where page.hasPrefix("app."): return AppsGroup(rawValue: String(page.dropFirst("app.".count))).map { .app($0) }
        case let page? where page.hasPrefix("settings."):
            // `settings.<tab>`, by the tab's own name: servers, updates, secrets, knowledge, apps, people, team, status.
            return SettingsTab.named(String(page.dropFirst("settings.".count))).map { .settings($0) }
        case "needs": return .needs
        case "activity", "tasks": return .activity
        case "goals": return .goals
        case "agents", "usage": return .agents
        case "servers", "devices": return .settings(.servers)
        // `server.<name>`: one server's page, which no sidebar row opens on its own.
        case let page? where page.hasPrefix("server."): return .server(String(page.dropFirst("server.".count)))
        case "updates", "updates.subscription": return .settings(.updates)
        // `task.<id>`: the thread of one task. It is no sidebar row, so nothing else opens it on its own — and it
        // was the one screen of the app nobody could look at without a task to click to.
        case let page? where page.hasPrefix("task."): return Int(page.dropFirst("task.".count)).map { .task($0) }
        case let page? where page.hasPrefix("agent."):
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

    /// The first-run wizard holds the window, after the hub it installed has answered. It is set and cleared by
    /// the wizard itself, and never kept: a later start of the app begins with no hold.
    var firstRunHolds = false
    /// The first option of a Needs-you item for his phone (API 1.95) asked for the Add device picture: the Devices
    /// group of Settings › Servers makes its code at once, as its own Add device does, and clears this.
    var addDeviceAsked = false
    var destination: Destination = FleetStore.asked ?? .agent("manager") {
        didSet {
            // The first page the app chose for itself is no step he can go back to; a step of Back or Forward is not
            // one he opened.
            if homeChosen, !stepping { history.went(from: oldValue, to: destination) }
            homeChosen = true
            if destination != oldValue { childThreadRequest = nil; keptUnread = nil }
            markRepliesSeen()
            // The launch's first read reads the pages; a page chosen before it needs no read of its own.
            if launched { prefetch(fleet: PagePrefetch.fleet, agent: PagePrefetch.agent) }
        }
    }
    /// The app has its first page: the one asked for, the one `home` chose from a reading, or one he went to first.
    @ObservationIgnored private var homeChosen = FleetStore.asked != nil

    /// **The pages he opened, for Back and Forward** (the owner, 3 November 2026: "2 buttons to go back and forth between
    /// pages while navigating the app, like in codex"), as a browser keeps them (`PageHistory`).
    private(set) var history = PageHistory<Destination>()
    /// A step of Back or Forward is under way: it is not a page he opened himself.
    @ObservationIgnored private var stepping = false
    var canGoBack: Bool { !history.back.isEmpty }
    var canGoForward: Bool { !history.forward.isEmpty }

    /// One page back, ⌘[: the newest page he left that can still open.
    func goBack() {
        guard let page = history.goBack(from: destination, canOpen: canOpen) else { return }
        stepping = true; destination = page; stepping = false
    }

    /// One page forward, ⌘], after a step back.
    func goForward() {
        guard let page = history.goForward(from: destination, canOpen: canOpen) else { return }
        stepping = true; destination = page; stepping = false
    }

    /// A page of an agent the hub no longer lists, or of a task it no longer has, cannot open again: Back passes over it.
    private func canOpen(_ page: Destination) -> Bool {
        guard let state else { return true }
        if let agent = page.agentName { return state.agents.contains { $0.name == agent } }
        if case .task(let id) = page { return state.tasks.contains { $0.id == id } }
        return true
    }

    /// **Where the app opens** (the owner's yes of 28 October 2026 to D-4): Needs you while a request of the manager is
    /// open, else the manager's chat. The Dashboard it opened on is gone; the sidebar is the one list of the agents.
    static func home(_ state: HubState?) -> Destination {
        if state?.needs.contains(where: \.isOpen) == true { return .needs }
        return .agent(state?.agents.first { $0.role == "manager" }?.name ?? "manager")
    }

    /// Opens the first page once there is a reading to choose it from: the one this Mac kept, in the first frame, or the
    /// launch's first answer. A page he opened before it stays.
    private func chooseHome() {
        guard !homeChosen, state != nil else { return }
        destination = Self.home(state)
    }
    /// The newest chat reply that the owner has seen from each agent, for one hub generation (`seenContext`).
    private var seenReplies: [String: Int] = [:]
    @ObservationIgnored private var seenContext = ""
    /// An agent whose chat he marked unread while that chat was open. An open chat counts as read, so without this
    /// the next reading would take his mark away again under his pointer; it stays until he goes to another page.
    @ObservationIgnored private var keptUnread: String?
    /// The agents he pinned to the top of the sidebar, newest pin first, by hub address. This Mac keeps them.
    private var pins = UserDefaults.standard.dictionary(forKey: "pinnedAgents") as? [String: [String]] ?? [:]
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
    private(set) var secretRefusals = 0
    /// Add secret over the window, from a chat's key button or from the guard of a pasted key: memory only, because a
    /// pasted key is in it until the form takes it.
    var secretForm: SecretPreset?
    /// The question of the guard of a pasted or typed key, for one composer.
    var heldKey: HeldKey?
    var editingMessage: OwnerMessage?
    var editText = ""
    /// Rename… or Deactivate from an agent's row (`AgentMenu`): its Runs on takes it when it opens, and clears it.
    var agentAction: AgentActionRequest?
    /// Delete… from an agent's menu: its confirmation stands over the window until he answers it (`AgentDeleteCard`).
    var deleting: AgentDeleteRequest?
    /// The knowledge file whose text Settings › Knowledge opens, asked by the eye of a file's card on an agent's Can use:
    /// the page takes it when it shows, and clears it.
    var knowledgeRead: String?
    var agentDrafts: [String: String] {
        didSet { UserDefaults.standard.set(agentDrafts, forKey: "agentDrafts") }
    }
    var supportsDirectChat: Bool { state?.ui_features?.contains("direct_chat") == true }
    func canChat(with agent: String) -> Bool { state?.supportsChat(with: agent) == true }
    var supportsCorrections: Bool { state?.ui_features?.contains("corrections") == true }
    /// Whether this hub takes the start of the manager's standing session (`ManagerSession`), so that the warning
    /// band draws no control an older hub would refuse.
    var supportsManagerStart: Bool { state?.ui_features?.contains(ManagerSession.feature) == true }
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
        var id: UUID { requestID }
        var isOnHub: Bool { attachmentID != nil }
    }

    var supportsAttachments: Bool { state?.ui_features?.contains("attachments") == true }
    /// The composer of one chat, or of one open request of Needs you.
    static func stageKey(agent: String) -> String { "agent:\(agent)" }
    static func stageKey(need: Int) -> String { "need:\(need)" }
    func stagedFiles(for composer: String) -> [StagedFile] { staged[composer] ?? [] }
    func readyFiles(for composer: String) -> [Int] { stagedFiles(for: composer).compactMap(\.attachmentID) }
    func filesAreWaiting(for composer: String) -> Bool { stagedFiles(for: composer).contains { !$0.isOnHub } }
    func composerOf(_ file: StagedFile) -> String? {
        staged.first { $0.value.contains(where: { $0.requestID == file.requestID }) }?.key
    }

    /// The owner picked a file. The bytes are written beside the Outbox **before** anything is sent, then the file
    /// goes up with its own number; the message that carries it names only that number.
    func stage(_ data: Data, name: String, mime: String, for composer: String) async {
        guard storageError == nil else { return }
        guard stagedFiles(for: composer).count < MessageAttachment.perMessage else {
            fileErrors[composer] = "A message carries at most \(MessageAttachment.perMessage) files."
            return
        }
        guard MessageAttachment.types[mime] != nil else { fileErrors[composer] = AttachmentError.type.errorDescription; return }
        guard !data.isEmpty, data.count <= MessageAttachment.sizeLimit else {
            fileErrors[composer] = AttachmentError.tooLarge.errorDescription
            return
        }
        let file = StagedFile(requestID: UUID(), name: MessageAttachment.safeName(name, mime: mime), mime: mime,
                              size: data.count)
        do {
            try FileManager.default.createDirectory(at: stagedDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: stagedURL(file), options: [.atomic])
        } catch {
            fileFailed("Cannot keep this file on this Mac. Nothing was sent.", cause: error, for: composer)
            return
        }
        fileErrors[composer] = nil
        staged[composer, default: []].append(file)
        keepStaged()
        await upload(file, for: composer)
    }

    /// One file from a place on this Mac: a picture becomes the bytes that travel well, another file goes as it is.
    func stage(contentsOf url: URL, for composer: String) async {
        guard let mime = MessageAttachment.mime(forName: url.lastPathComponent) else {
            fileErrors[composer] = AttachmentError.type.errorDescription
            return
        }
        let opened = url.startAccessingSecurityScopedResource()
        defer { if opened { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            fileErrors[composer] = "That file did not open."
            return
        }
        if mime.hasPrefix("image/"), let picture = try? MessageAttachment.imageForSending(data) {
            await stage(picture.data, name: url.lastPathComponent, mime: picture.mime, for: composer)
        } else {
            await stage(data, name: url.lastPathComponent, mime: mime, for: composer)
        }
    }

    /// Sends one staged file up, with its own number. A file that is already on the hub never goes again.
    func upload(_ file: StagedFile, for composer: String) async {
        guard let state, !file.isOnHub, !uploading.contains(file.requestID) else { return }
        guard let data = try? Data(contentsOf: stagedURL(file)) else {
            change(file, in: composer) { $0.failure = "The bytes of this file are gone. Pick it again." }
            return
        }
        uploading.insert(file.requestID)
        defer { uploading.remove(file.requestID) }
        change(file, in: composer) { $0.failure = nil }
        do {
            let sent = try await client.upload(data, name: file.name, mime: file.mime, requestID: file.requestID,
                                               client: installation, hub: hub, database: state.db)
            change(file, in: composer) { $0.attachmentID = sent.id; $0.failure = nil }
        } catch {
            change(file, in: composer) {
                $0.failure = (error as? LocalizedError)?.errorDescription ?? "The file did not go up."
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

    private func change(_ file: StagedFile, in composer: String, _ edit: (inout StagedFile) -> Void) {
        guard var list = staged[composer],
              let at = list.firstIndex(where: { $0.requestID == file.requestID }) else { return }
        edit(&list[at])
        staged[composer] = list
        keepStaged()
    }

    private func keepStaged() {
        guard let data = try? JSONEncoder().encode(staged) else { return }
        UserDefaults.standard.set(data, forKey: "stagedFiles")
    }

    func stagedURL(_ file: StagedFile) -> URL {
        stagedDirectory.appendingPathComponent(file.requestID.uuidString.lowercased())
    }

    /// The bytes of one file of a message, for the chat that shows it. Nothing is kept before its size and its
    /// SHA-256 match what the hub said.
    func load(_ file: MessageAttachment) async {
        guard let state, fileData[file.id] == nil, !fileReads.contains(file.id) else { return }
        fileReads.insert(file.id)
        defer { fileReads.remove(file.id) }
        do {
            let data = try await client.attachment(file, hub: hub, database: state.db)
            fileData[file.id] = data
            fileOrder.append(file.id)
            while fileOrder.count > 16, let oldest = fileOrder.first {
                fileData[oldest] = nil
                fileOrder.removeFirst()
            }
            unloadedFiles.remove(file.id)
        } catch {
            unloadedFiles.insert(file.id)
        }
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
        do {
            try await send(state)
            fileProblems[file.id] = nil
            await refresh()
        } catch {
            fileProblems[file.id] = HubError.said(error) ?? "This file could not be kept. Try again."
        }
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
        message.kind == "answer" ? "This request was already answered" : state?.editHelp(message) ?? "Correct"
    }
    func beginEdit(_ message: OwnerMessage) {
        guard canEdit(message) else { return }
        editText = message.text
        editingMessage = message
    }
    func cancelEdit() { editingMessage = nil; editText = "" }
    func sendEdit() async {
        guard let message = editingMessage, canEdit(message) else { return }
        await sendText(editText, recipient: message.chatRecipient, replaces: message.id)
        if pending == nil { cancelEdit() }
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
    private var unplaced = Set(UserDefaults.standard.stringArray(forKey: "unplacedAgents") ?? []) {
        didSet { UserDefaults.standard.set(unplaced.sorted(), forKey: "unplacedAgents") }
    }
    private func placingKey(_ agent: String, database: String) -> String { "\(hub.absoluteString)|\(database)|\(agent)" }
    /// This Mac saw the agent with no server on this hub generation, and has not seen it run since.
    func placing(_ agent: String) -> Bool { state.map { unplaced.contains(placingKey(agent, database: $0.db)) } ?? false }
    /// **The setup takes the place of this agent's chat and of its Runs on** (`AgentSetupFlow.shows`).
    func setupShows(_ agent: String) -> Bool {
        AgentSetupFlow.shows(state?.agents.first { $0.name == agent }, features: state?.ui_features ?? [], placing: placing(agent))
    }
    /// **The server that joined for an agent with no server yet**, by the same key: its provider's press gives it that
    /// server. This Mac keeps it, so an app that starts again between the join and that press opens on the provider, and
    /// not on the server's page, where a press would make another server.
    private var joinedFor = UserDefaults.standard.dictionary(forKey: "serversJoinedFor") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(joinedFor, forKey: "serversJoinedFor") }
    }
    func joinedServer(_ agent: String) -> String? { state.flatMap { joinedFor[placingKey(agent, database: $0.db)] } }
    func noteJoined(_ server: String, for agent: String) {
        guard let database = state?.db else { return }
        joinedFor[placingKey(agent, database: database)] = server
    }
    /// An agent with no server goes on the list, and one that runs leaves it. One that has its server needs no joined
    /// server any more.
    private func notePlacing(_ fresh: HubState) {
        guard fresh.ui_features?.contains(AgentSetupFlow.serverFeature) == true else { return }
        for agent in fresh.agents {
            let key = placingKey(agent.name, database: fresh.db)
            if !agent.placed, !unplaced.contains(key) { unplaced.insert(key) }
            if AgentSetupFlow.runs(agent), unplaced.contains(key) { unplaced.remove(key) }
            if agent.placed, joinedFor[key] != nil { joinedFor[key] = nil }
        }
    }
    /// **A write that its own row says it waits for** (fix round 3c, the lead's call): the request, and the agent's part
    /// whose row says "The hub has not answered." with its Try again. The window's request line leaves that write out on
    /// that part, so one unanswered save is said once; on any other page, and for every other write, the line says it.
    var pendingInItsRow: (id: UUID, agent: String, tab: AgentTab)?
    /// **A read has taken more than eight seconds, and none has answered since** (`readPatience`; fix round 3b, item
    /// 17): the reading it reads again is old from then on, and the old-reading notice stands until a read answers or
    /// the hub's own notice takes its place. A running app marked its reading old only 12 s after the last answer, so a
    /// read that hung failed at its 10-s limit first, and no notice stood for about 30 s. It outlives the read that
    /// failed: the notice never goes before an answer.
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
    /// reading that is 3 to 11 seconds old while its read goes on is no news; a read that hangs still says so before it
    /// fails at its 10-second limit, and a reading is old 12 seconds after the last answer in any case.
    private static let readPatience: Duration = .seconds(StateReading.patience)
    /// The old-reading notice shows: a slow read left the reading old, and no read had failed before the notice stood.
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
        didSet { UserDefaults.standard.set(draft, forKey: "managerDraft") }
    }
    var answers: [String: String] {
        didSet { UserDefaults.standard.set(answers, forKey: "answerDrafts") }
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
    private(set) var fileData: [Int: Data] = [:]
    private var fileOrder: [Int] = []
    private var fileReads: Set<Int> = []
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
    /// The observer of the app's quit, which writes the newest reading.
    @ObservationIgnored private var quitting: NSObjectProtocol?

    /// The hub addresses that have answered this Mac, kept between launches.
    private static var answeredHubs: [String] {
        get { UserDefaults.standard.stringArray(forKey: "hubsAnswered") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "hubsAnswered") }
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
        if now { write() } else { Task.detached(priority: .utility, operation: write) }
    }

    init() {
        // **A launch's `-hubAddress` that is no hub address stops the app** (review B9, fix round 2): it fell back to his
        // own hub without a word, so a test copy with a typo in it read his real fleet, and could write to it.
        if let asked = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["hubAddress"] as? String,
           (try? HubClient.address(asked)) == nil {
            fatalError("-hubAddress \(asked) is not a hub address. Founderizer stops here rather than read another hub.")
        }
        let address = UserDefaults.standard.string(forKey: "hubAddress") ?? HubClient.defaultAddress
        addressText = address
        let installationID = UserDefaults.standard.string(forKey: "installationID") ?? UUID().uuidString.lowercased()
        UserDefaults.standard.set(installationID, forKey: "installationID")
        installation = "founderizer-swift/1/\(installationID)"
        hub = (try? HubClient.address(address)) ?? (try! HubClient.address(HubClient.defaultAddress))
        draft = UserDefaults.standard.string(forKey: "managerDraft") ?? ""
        agentDrafts = UserDefaults.standard.dictionary(forKey: "agentDrafts") as? [String: String] ?? [:]
        answers = UserDefaults.standard.dictionary(forKey: "answerDrafts") as? [String: String] ?? [:]
        // Settings and rules save themselves now: no profile draft is kept, and the drafts of earlier versions go.
        UserDefaults.standard.removeObject(forKey: "profileDrafts")
        if let seen = UserDefaults.standard.dictionary(forKey: "chatRepliesSeen"), let context = seen["context"] as? String,
           let replies = seen["seen"] as? [String: Int] {
            seenContext = context; seenReplies = replies
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        outbox = Outbox(file: support.appendingPathComponent("Founderizer/pending.json"))
        stagedDirectory = support.appendingPathComponent("Founderizer/staged")
        readingsFolder = support.appendingPathComponent("Founderizer")
        hubAnsweredBefore = Self.answeredHubs.contains(hub.absoluteString)
        if let kept = UserDefaults.standard.data(forKey: "stagedFiles"),
           let files = try? JSONDecoder().decode([String: [StagedFile]].self, from: kept) {
            staged = files
        }
        do { pending = try outbox.load() }
        catch { storageFailed("Cannot read the saved request. Sending is blocked.", cause: error) }
        notifications.openRequest = { [weak self] context, id in
            guard let self, let state = self.state,
                  context == FleetNotifications.context(hub: self.hub, database: state.db) else { return }
            if let id {
                guard state.needs.contains(where: { $0.id == id }) else { return }
                self.destination = .needs; self.selectedNeed = id
            } else { self.destination = Self.home(state) }
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
        if let data = try? Data(contentsOf: lastReadingFile), let kept = try? HubState.decode(data) {
            state = kept
            var timeline = ChatTimeline()
            if timeline.update(messages: kept.messages, reports: kept.reports) { chatTimeline = timeline }
            keptHealth = KeptReading((try? Data(contentsOf: keptFile("health"))).flatMap { FleetHealth.kept($0, database: kept.db) })
            keptReleases = KeptReading((try? Data(contentsOf: keptFile("releases"))).flatMap { ReleaseState.kept($0, database: kept.db) })
            updates.start(kept: (try? Data(contentsOf: keptFile("app-update"))).flatMap(WaitingBuild.kept))
        }
        chooseHome()
        quitting = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.writeReading(now: true) }
        }
    }

    /// **The state is current** (`StateReading.isCurrent`). A reading this Mac kept from an earlier launch is current
    /// while the launch's first read is on its way, and old as soon as that read fails or has taken eight seconds: a
    /// reading that is being read again is not old yet (the loading contract's rule, D-1). It was current for one second
    /// at most, and a launch whose first read took 1.4 s had the old-reading notice over its page from 1.2 to 1.6 s (10
    /// November 2026). **While the app runs** (fix round 3b, item 17), a reading is old once a read of it has taken more
    /// than eight seconds (`readHeld`, `readPatience`), until a read answers; and 12 seconds after the last answer in
    /// any case. **One read that fails at once says nothing** (the owner, 27 October 2026: "never for one short break"):
    /// three in a row bring the hub's own notice, and with it the old look.
    var isFresh: Bool {
        guard state != nil, connectionError == nil else { return false }
        return StateReading.isCurrent(held: readHeld,
                                      sinceAnswer: lastSuccess.map { max(clock, Date()).timeIntervalSince($0) },
                                      firstReadEnded: firstReadEnded)
    }
    /// The hub answered this launch, within the last 12 seconds, and no connection notice stands. A read that is slow or
    /// failed once leaves a write as it was (fix round 3b): the old look is the reading's, and a write has its own answer.
    private var answersWrites: Bool {
        guard state != nil, connectionError == nil, let lastSuccess else { return false }
        return max(clock, Date()).timeIntervalSince(lastSuccess) < 12
    }
    /// Nothing is written on a kept reading alone: a write waits for the hub's own answer of this launch.
    var canWrite: Bool { answersWrites && !sending && pending == nil && storageError == nil }
    var openNeeds: [OwnerNeed] { state?.needs.filter(\.isOpen) ?? [] }
    var currentNeed: OwnerNeed? { state?.needs.first { $0.id == selectedNeed } }
    var currentTask: FleetTask? {
        if case .task(let id) = destination { return state?.tasks.first { $0.id == id } }
        return nil
    }
    var canRetry: Bool {
        guard let pending else { return false }
        return answersWrites && !sending && storageError == nil && pending.refusal == nil &&
            pending.hub == hub && pending.database == state?.db
    }
    var connectionLabel: String {
        if isFresh { return "Connected" }
        if lastSuccess != nil { return "Disconnected · last state" }
        return refreshing ? "Connecting" : "Disconnected"
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
                    // poll is the only clock there is; until a copy is due this is two dates compared.
                    await self.copies.tick(store: self)
                    // A new build of this app, read every four hours and put in place while he is away from it.
                    self.updates.tick(store: self)
                    // The fleet's central vault, read once a minute and kept in order by itself, on every page.
                    self.vaultModel().tick(store: self)
                    // The door's access file, from this Mac's own Tailscale, by itself and with nothing on a page.
                    self.doorModel().tick(store: self)
                    // The owner's access key on each Linux server, his way back after a lost Mac, with nothing on a page.
                    self.accessModel().tick(store: self)
                    self.releasesTick()
                    wait = self.untilRead
                }
                do { try await Task.sleep(for: .seconds(max(wait, 0.1))) } catch { return }
            }
        }
    }

    /// **The sidebar's Update row stands only while an update waits** (D-4): a release of the fleet that the hub offers
    /// to take, or a build of this app that installs itself or waits for its press. Nothing else marks it.
    var updateWaits: Bool {
        // A release that waits only for running work, with automatic updates on, waits for nothing of his: the hub
        // takes it at the first moment no turn runs (fix round 3, item 20).
        // Until this launch reads the releases, the reading kept with the fleet's, while it is of this hub generation.
        let releases = reading("releases") as ReleaseState? ?? keptReleases.reading(of: state?.db)
        let fleet = releases.map { $0.stand.take != nil && !($0.stand.waiting && $0.automatic) } ?? false
        // Until this launch's own read of our channel decides, the build of this app kept with the fleet's (`buildWaits`).
        return fleet || updates.buildWaits
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

    /// How long the read on the clock waits now.
    private var untilRead: TimeInterval {
        LiveChanges.untilRead(after: lastRead, now: ProcessInfo.processInfo.systemUptime)
    }

    func connect() async {
        do {
            let next = try HubClient.address(addressText)
            guard !sending else { return }
            if next != hub { childThreadRequest = nil; cancelEdit(); endProviderSetups(); state = nil; chatTimeline = ChatTimeline(); lastSuccess = nil; lastReceipt = nil; stopWatching(); stateToken = nil }
            hub = next
            hubAnsweredBefore = Self.answeredHubs.contains(next.absoluteString)
            UserDefaults.standard.set(next.absoluteString, forKey: "hubAddress")
            connectionError = nil; failedReads = 0; readsFail = false; staleNoticeStood = false; readHeld = false
            await refresh()
        } catch { lastReadError = error; connectionError = HubReach.words(error, hub: nil).line }
    }

    /// Reads the fleet's state. **A call while a read is on its way is never dropped**: that read runs once more when
    /// it ends, and this call comes back after that one, so what the caller just did is in the state it sees.
    func refresh() async {
        await reads.run { [self] in await readState() }
    }

    private func readState() async {
        refreshing = true
        let requestedHub = hub
        // Eight seconds into this read, its reading is old until a read answers (`readPatience`; fix round 3b, item 17).
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
            let (fresh, data) = try await client.stateReading(at: requestedHub)
            guard requestedHub == hub else { return }
            if let state, state.db != fresh.db { childThreadRequest = nil; cancelEdit(); endProviderSetups() }
            var timeline = chatTimeline
            if timeline.update(messages: fresh.messages, reports: fresh.reports) { chatTimeline = timeline }
            notePlacing(fresh)
            state = fresh
            chooseHome()
            follow(fresh)
            markRepliesSeen()
            lastSuccess = Date()
            lastReadTook = ContinuousClock.now - began
            if readHeld { readHeld = false }
            connectionError = nil
            lastReadError = nil
            staleNoticeStood = false
            failedReads = 0
            if readsFail { readsFail = false }
            keepReading(data)
            claimFromLink.tryNow(store: self)
            if !hubAnsweredBefore {
                hubAnsweredBefore = true
                Self.answeredHubs = Self.answeredHubs.filter { $0 != requestedHub.absoluteString } + [requestedHub.absoluteString]
            }
            prefetch(fleet: PagePrefetch.fleet, agent: PagePrefetch.agent)
            if let pending, pending.hub == hub, (fresh.receipt(for: pending) != nil || fresh.hasSteeringReceipt(for: pending)) {
                try finish(pending)
            }
            if selectedNeed == nil { selectedNeed = openNeeds.first?.id }
            await notifications.update(hub: requestedHub, state: fresh)
        } catch {
            guard requestedHub == hub else { return }
            lastReadError = error
            failedReads += 1
            if !readsFail { readsFail = true }
            if HubReach.tells(failedReads: failedReads, answeredBefore: state != nil) {
                connectionError = HubReach.words(error, hub: requestedHub).line
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

    func send(needID: Int? = nil) async {
        let text = needID.map { answers[String($0)] ?? "" } ?? draft(for: chatAgent)
        let recipient = needID.flatMap { id in state?.needs.first { $0.id == id }?.by } ?? chatAgent
        let composer = needID.map { Self.stageKey(need: $0) } ?? Self.stageKey(agent: chatAgent)
        await sendText(text, needID: needID, recipient: recipient, files: readyFiles(for: composer))
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
        let approval = await DoorCallSigning.approval(for: need, choice: choice, store: self, hub: hub, database: state.db)
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
            storageFailed("Cannot save this answer. Nothing was sent.", cause: error)
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
            storageFailed("Cannot save this answer. Nothing was sent.", cause: error)
            return
        }
        await transmit(request)
    }

    /// His message in the discussion of one open Needs-you item (owner feature `need_talk`): it goes to the manager,
    /// which replies under the item, and the item stays open. True once the hub took it.
    func talk(_ need: OwnerNeed, text: String) async -> Bool {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, words.count <= NeedTalk.most, openNeeds.contains(where: { $0.id == need.id }) else { return false }
        let sent = await command(.needTalk(need: need.id), note: words)
        if sent { await refresh() }
        return sent
    }

    private func sendText(_ value: String, needID: Int? = nil, recipient: String, replaces: String? = nil,
                          files: [Int] = []) async {
        guard canWrite, let state else { return }
        guard needID != nil || canChat(with: recipient) else { return }
        guard files.isEmpty || supportsAttachments else { return }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // A message carries text, or files, or both. Without a file it must carry text, as the hub asks.
        guard !text.isEmpty || !files.isEmpty, text.count <= 16_000 else { return }
        if let needID, !openNeeds.contains(where: { $0.id == needID }) { return }
        let request = PendingRequest(hub: hub, database: state.db, client: installation, needID: needID,
                                     recipient: needID == nil && supportsDirectChat ? recipient : nil,
                                     replacesRequestID: replaces, attachments: files, text: text)
        do {
            try outbox.save(request)
            pending = request
            sending = true
        } catch {
            storageFailed("Cannot save this request. Nothing was sent.", cause: error)
            return
        }
        await transmit(request)
    }

    @discardableResult
    func command(_ command: OwnerCommand, note: String = "") async -> Bool {
        guard canWrite, let state, state.ui_features?.contains(command.requiredFeature) == true else { return false }
        lastControlReceipt = nil
        let request = PendingRequest(hub: hub, database: state.db, client: installation, command: command, text: note)
        do {
            guard try request.body().count <= 65_536 else { sendError = "This request is too large. Shorten it before saving."; return false }
        } catch { sendError = "The command fields are invalid. Nothing was sent."; return false }
        do { try outbox.save(request); pending = request; sending = true }
        catch { storageError = "Cannot save this command. Nothing was sent."; return false }
        await transmit(request)
        return pending == nil && storageError == nil && sendError == nil
    }

    func retry() async {
        guard canRetry, let pending else { return }
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
            guard self.hub == hub, state?.db == database, storageError == nil else { return .refused("Not saved. The hub connection changed.") }
            if !queue, !sending, pending != nil { return .behind }
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return .refused("Not saved.") }
        }
        if await self.command(command, note: note) { return .saved(sha256: lastControlReceipt?.sha256) }
        guard let request = pending, request.command == command else {
            return .refused(sendError ?? storageError ?? "Not saved. This hub does not offer this change.")
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
            guard self.hub == hub else { return .refused("Not saved. The hub connection changed.") }
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return .unconfirmed(id) }
        }
        if let request = pending, request.requestID == id { return refused(request) }
        let receipt = lastControlReceipt
        return .saved(sha256: receipt?.request_id.lowercased() == id.uuidString.lowercased() ? receipt?.sha256 : nil)
    }

    /// Removes a save that the hub refused from the outbox, and gives the hub's words.
    private func refused(_ request: PendingRequest) -> SaveResult {
        let refusal = request.refusal ?? ""
        guard let status = HubError.refusalStatus(in: refusal) else { return .refused(refusal) }
        discardRefused()
        let words = HubError.refusalWords(in: refusal) ?? refusal
        return status == 409 ? .conflict(words) : .refused(words)
    }

    /// A reply came in this agent's chat after the owner last had that chat open.
    func hasNewReply(from agent: String) -> Bool {
        guard let state else { return false }
        return Self.newestReply(agent, in: state) > (seenReplies[agent] ?? 0)
    }

    private static func newestReply(_ agent: String, in state: HubState) -> Int {
        state.reports.lazy.filter { $0.chatAgent == agent }.map(\.id).max() ?? 0
    }

    /// The agent has written in its chat at least once, so Mark as unread has a reply to mark.
    func hasReply(from agent: String) -> Bool {
        guard let state else { return false }
        return Self.newestReply(agent, in: state) > 0
    }

    /// Mark as read, from the right-click of the agent's row: its newest reply counts as seen, as if he had opened
    /// the chat.
    func markRead(_ agent: String) {
        guard let state else { return }
        markRepliesSeen()
        if keptUnread == agent { keptUnread = nil }
        var seen = seenReplies
        seen[agent] = Self.newestReply(agent, in: state)
        keep(seen, context: seenContext)
    }

    /// Mark as unread: the agent's newest reply is new again, so its dot comes back until he opens the chat.
    func markUnread(_ agent: String) {
        guard let state, Self.newestReply(agent, in: state) > 0 else { return }
        markRepliesSeen()
        if case .agent(let open) = destination, open == agent { keptUnread = agent }
        var seen = seenReplies
        seen[agent] = Self.newestReply(agent, in: state) - 1
        keep(seen, context: seenContext)
    }

    /// The agents pinned to the top of the sidebar on this hub, newest pin first.
    var pinned: [String] { pins[hub.absoluteString] ?? [] }

    /// Pin to top, or Unpin, from the right-click of the agent's row.
    func togglePin(_ agent: String) {
        let list = (pinned.contains(agent) ? [] : [agent]) + pinned.filter { $0 != agent }
        pins[hub.absoluteString] = list.isEmpty ? nil : list
        UserDefaults.standard.set(pins, forKey: "pinnedAgents")
    }

    /// The open chat's replies are seen. A new hub generation takes the replies that it has as seen, so that only later
    /// replies are new.
    private func markRepliesSeen() {
        guard let state else { return }
        let context = "\(hub.absoluteString)\n\(state.db)"
        var seen = seenContext == context ? seenReplies : [:]
        if seenContext != context { for agent in state.agents { seen[agent.name] = Self.newestReply(agent.name, in: state) } }
        if case .agent(let name) = destination, name != keptUnread { seen[name] = Self.newestReply(name, in: state) }
        keep(seen, context: context)
    }

    private func keep(_ seen: [String: Int], context: String) {
        guard seen != seenReplies || seenContext != context else { return }
        seenContext = context; seenReplies = seen
        UserDefaults.standard.set(["context": context, "seen": seen], forKey: "chatRepliesSeen")
    }

    func discardRefused() {
        guard !sending, let pending, pending.refusal != nil else { return }
        do {
            try outbox.clear(matching: pending.requestID)
            self.pending = nil
            sendError = nil
        } catch { storageError = error.localizedDescription }
    }

    /// `rebased` is true for the one send that follows a stale-base 409, so it is never tried twice.
    private func transmit(_ request: PendingRequest, rebased: Bool = false) async {
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
            if case HubError.refusal(422, _) = error {
                secretRefusals += 1
                draft = ""
                answers = [:]
                agentDrafts = [:]
                cancelEdit()
                do { pending = try outbox.rejectSecret(matching: request.requestID, drafts: .standard) }
                catch { storageError = "Cannot remove rejected text from local storage. Sending is blocked." }
                sendError = "The hub refused registered login text."
            } else if let error = error as? HubError, error.definitiveRefusal || error.conflict {
                var refused = request
                refused.refusal = error.localizedDescription
                do { try outbox.save(refused); pending = refused }
                catch { storageError = "Cannot save the refusal. The original request is retained." }
                sendError = error.localizedDescription
            } else {
                sendError = "Receipt not confirmed. The saved request is kept; refresh to check it or retry the same request."
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
                                  command: rebuilt, text: request.text)
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
        if request.command != nil {
            // Commands have no chat draft and are acknowledged by their own receipt.
        } else if request.replacesRequestID != nil {
            if editingMessage?.id == request.replacesRequestID { cancelEdit() }
        } else if request.needID == nil {
            let agent = request.recipient ?? "manager"
            if draft(for: agent).trimmingCharacters(in: .whitespacesAndNewlines) == request.text { setDraft("", for: agent) }
            clearStaged(Self.stageKey(agent: agent), sent: request.attachments)
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
