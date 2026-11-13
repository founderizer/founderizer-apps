import FleetCore
import SwiftUI

/// An agent's Settings as the hub has them (team.json and the machine reading), and the saves of its controls. Each
/// control saves itself. Saves go one at a time through the store; a newer value of a field that still waits replaces
/// the older one. Each save goes against the newest team.json. When the hub refuses it with 409 because team.json
/// changed elsewhere, the save reads team.json again and sends only this field's change again, with no question;
/// when that same field changed elsewhere, the control shows the new value instead.
@MainActor @Observable
final class AgentSettingsModel {
    typealias Field = AgentSettingEdit.Field
    let agent: String
    let hub: URL
    let database: String
    /// **What it reads is the store's** (`FleetStore.reading`), under the names that every page reading the same route
    /// shares: a page that opens draws team.json, the machines and the servers as any page read them last. The pages
    /// that take this model give it their store.
    @ObservationIgnored weak var store: FleetStore?
    private(set) var team: TeamSnapshot? {
        get { store?.reading("team.snapshot") } set { keep(newValue, as: "team.snapshot") }
    }
    private(set) var machines: MachineList? {
        get { store?.reading("machines") } set { keep(newValue, as: "machines") }
    }
    /// The servers, read while the hub can rename an agent (`agent_rename`): the newest job of the agent's server
    /// says whether its rename goes on or stopped.
    private(set) var servers: ServerList? {
        get { store?.reading("servers.list") } set { keep(newValue, as: "servers.list") }
    }
    private(set) var readError: String?
    /// The value of each field that waits or is sent now, or that the hub refused. The control shows it.
    private(set) var values: [Field: AgentSettingEdit] = [:]
    private(set) var states: [Field: SaveState] = [:]
    private var order: [Field] = []
    private var versions: [Field: Int] = [:]
    private var draining = false
    /// The save that waits for the hub's answer: its Retry sends the same request again.
    private var unanswered: (field: Field, id: UUID)?

    init(agent: String, hub: URL, database: String) { self.agent = agent; self.hub = hub; self.database = database }

    var line: ReportingLine? { team?.lines.first { $0.agent == agent } }
    var machine: MachineStatus? { machines?.machines.first { $0.agent == agent } }
    /// A field waits for its save.
    var isSaving: Bool { !order.isEmpty }

    /// Reads team.json. A first reading of a page that opened at `start` waits until a loading line that showed has
    /// stood half a second (`FleetStore.settle`).
    @discardableResult func readTeam(since start: ContinuousClock.Instant? = nil) async -> Bool {
        let first = team == nil
        do {
            let read = try await HubClient().team(hub: hub, database: database)
            if first, let start { await store?.settle(since: start) }
            team = read
            readError = nil
            return true
        } catch {
            if first, let start { await store?.settle(since: start) }
            if !Task.isCancelled { readError = String(l10n: "The settings could not be read. Check the connection.") }
            return false
        }
    }

    func readMachines() async {
        guard let list = try? await HubClient().machines(hub: hub, database: database) else { return }
        // **"Waiting for … to load the new settings." comes and goes with the motion of a save's line**
        // (`SaveState.lineMotion`; the reviews of 30 October 2026): after a save it came in one frame and moved the rows
        // under it.
        let pending = { (list: MachineList?) in list?.machines.first { $0.agent == self.agent }?.settings_pending == true }
        withAnimation(pending(machines) != pending(list) ? SaveState.lineMotion : nil) { machines = list }
    }

    func readServers() async {
        if let list = try? await HubClient().servers(hub: hub, database: database) { servers = list }
    }

    /// Keeps a reading for this model's hub generation only: a read that answers after the window moved to another
    /// keeps nothing there.
    private func keep(_ value: Any?, as name: String) {
        guard let store, store.hub == hub, store.state?.db == database else { return }
        store.keep(value, as: name)
    }

    /// Saves one field: at once when nothing else is sent, else after the requests before it.
    func save(_ edit: AgentSettingEdit, store: FleetStore) {
        let field = edit.field
        values[field] = edit
        versions[field, default: 0] += 1
        set(.saving, for: field)
        if !order.contains(field) { order.append(field) }
        if !draining { Task { await drain(store: store) } }
    }

    /// A field's save state, **with the motion of its line** (`SaveState.motion`): a failure's line and Try again come
    /// and go over 0.2 s, and the rows under them move with them.
    private func set(_ state: SaveState?, for field: Field) {
        withAnimation(SaveState.motion(from: states[field], to: state)) { states[field] = state }
    }

    /// The same request again while it waits for its answer; else the refused value as a new save.
    func retry(_ field: Field, store: FleetStore) {
        if let unanswered, unanswered.field == field { Task { await store.retry() } }
        else if let edit = values[field] { save(edit, store: store) }
    }

    /// **What a toggle or a choice shows**: the value on its way, or the hub's value once a save of it failed (fix round
    /// 3, item 16), with the row's failure line and Try again, which sends the refused value again (`values`). Browser
    /// stayed checked for 3 s after the hub refused it. A text field keeps what he typed (`values`).
    func shown(_ field: Field) -> AgentSettingEdit? {
        if states[field]?.failure != nil { return nil }
        return values[field]
    }

    /// Forgets a field's value that has not gone yet: after a provider switch, the hub gives the model its defaults.
    func drop(_ field: Field) {
        values[field] = nil; set(nil, for: field)
        versions[field, default: 0] += 1
        if order.first != field { order.removeAll { $0 == field } }
    }

    private func drain(store: FleetStore) async {
        guard !draining else { return }
        draining = true; defer { draining = false }
        while let field = order.first {
            guard let edit = values[field] else { order.removeFirst(); continue }
            let version = versions[field]
            set(.saving, for: field)
            let state = await send(edit, store: store)
            // A newer value of this field waits: it goes next.
            guard versions[field] == version else { continue }
            order.removeFirst()
            set(state, for: field)
            // A saved value or the value of another save is in team.json now; a refused one stays for Retry.
            if !state.retries { values[field] = nil }
            if state == .saved {
                Task { try? await Task.sleep(for: .seconds(3)); if states[field] == .saved, versions[field] == version { states[field] = nil } }
            }
        }
    }

    /// One field's save against the newest team.json, again after each 409 that a change elsewhere caused.
    private func send(_ edit: AgentSettingEdit, store: FleetStore) async -> SaveState {
        let can = store.state?.agents.first { $0.name == agent }?.can ?? []
        var sent: (sha256: String, line: ReportingLine)?
        var words = String(l10n: "Not saved.")
        for _ in 0..<3 {
            guard await readTeam(), let team, let line else { return .failed(readError ?? String(l10n: "Not saved.")) }
            // The same team.json after a 409: it was for another reason.
            if let sent, team.sha256 == sent.sha256 { return .failed(words) }
            if edit.isSaved(in: line, can: can) { return .saved }
            if let sent, AgentSettingEdit.changed(edit.field, from: sent.line, to: line) { return .changedElsewhere }
            let request: (command: OwnerCommand, payload: String)
            do { request = try edit.request(agent: agent, team: team, can: can) }
            catch { return .failed((error as? SettingProblem)?.words ?? String(l10n: "Not saved.")) }
            sent = (team.sha256, line)
            var result = await store.save(request.command, note: request.payload, queue: false)
            if case .unconfirmed(let id) = result {
                unanswered = (edit.field, id)
                // Its row says it, so the window's request line leaves it out on this part (`pendingInItsRow`).
                store.pendingInItsRow = (id, agent, .settings)
                set(.failed(String(l10n: "The hub has not answered. Try again sends the same request.")), for: edit.field)
                result = await store.answer(to: id)
                unanswered = nil
                if store.pendingInItsRow?.id == id { store.pendingInItsRow = nil }
                set(.saving, for: edit.field)
            }
            switch result {
            case .saved:
                await readTeam()
                return .saved
            case .conflict(let reason): words = reason
            case .refused(let reason): return .failed(reason)
            case .unconfirmed: return .failed(String(l10n: "The hub has not answered."))
            case .behind: return .behind
            }
        }
        return .failed(words)
    }
}

/// **An agent's Settings: its server, its AI provider, its account and its usage, and nothing else.** The owner,
/// 25 October 2026: "The Settings page for an agent needs to be simpler! ... Make it simple: Show Server, AI Provider,
/// Account and Usage, that's it!! Everything else is not needed or is already somewhere else", and the same day, from a
/// mockup, yes to one Settings page in place of Overview and Settings. So it is one card of four rows:
///
///   - **Server**: its name, which opens the server's page; a fault of that machine is the row's orange line.
///   - **AI provider**: the provider, its model and its reasoning, and Change. Change opens under the row what is
///     about the AI: the switch to the other provider, the model, the reasoning and what the agent may use. Each
///     control saves itself, and the mark beside it says Saving…, Saved or Retry.
///   - **Account** and **Usage** (`ProviderAccountSection`).
///
/// Its role and the agent it reports to are in Settings › Reporting lines; its name and Deactivate are behind the
/// page's one "…"; an agent in setup is activated by its setup, which stands in place of its chat. A select and a
/// checkbox save at once, a text field when it loses focus.
struct AgentSetupView: View {
    @Bindable var store: FleetStore
    let agent: String
    private let model: AgentSettingsModel
    @State private var busy = false
    @State private var error: String?
    @State private var modelName = ""
    /// The full model name he typed last and saved: after a refusal its field keeps it.
    @State private var typedName: String?
    /// What is about the AI, under its row. A provider setup that is going on opens it by itself.
    @State private var changing: Bool?
    @FocusState private var naming: Bool
    /// The new name while its field is open (Rename… of the "…").
    @State private var newName: String?
    /// A rename or a retry of one that the hub has not answered yet.
    @State private var renaming = false
    @State private var renameError: String?
    @FocusState private var renameFocus: Bool
    /// The role while Rename… is open (team.json `title`), and the hub's words when it refused it.
    @State private var newRole: String?
    @State private var roleError: String?
    @State private var savingRole = false
    /// When this visit opened, and whether its first second has gone by. The orange "No current machine reading" stood
    /// 222 ms at every visit, and "Use another account" was disabled as long, while the read that cleared both was on
    /// its way (the loading contract, C4.4). A row's warning is words, not a view, so the page holds it for that
    /// second itself, as `Held` does.
    @State private var opened = ContinuousClock.now
    @State private var quietOver = false

    /// The agent's machine, read before its Settings first open (`PagePrefetch`).
    static let prefetch = PagePrefetch("machines", feature: "machines") { try await HubClient().machines(hub: $0, database: $1) }

    init(store: FleetStore, agent: String) {
        self.store = store; self.agent = agent
        model = store.settingsModel(agent: agent)
        model.store = store
    }

    private var time: Double { store.state?.time ?? 0 }
    private var features: [String] { store.state?.ui_features ?? [] }
    /// The agent's provider in team.json, or nil when it is unknown.
    private var configuredRuntime: String? { store.state?.agents.first { $0.name == agent }?.runtime }
    /// The capabilities of a team line that has none: an older hub.
    private var fallbackCan: [String] { store.state?.agents.first { $0.name == agent }?.can ?? [] }
    /// **The plain hold** (D-1, the owner's yes of 28 October 2026: "a reading that Founderizer is reading again is not
    /// old until that read fails or takes more than one second"): the machine reading shown is the one kept from before
    /// this visit, which the page reads again, and that read has had less than a second (`FleetStore.readingWaits`), so
    /// it is not old yet — also when it was old as it was kept. A machine that was silent at the last visit and reports
    /// now drew the orange "No current server reading" for the 34–166 ms of that read.
    private var machineHeld: Bool { !quietOver && store.readingWaits("machines", since: opened) }

    var body: some View {
        FleetPage(AgentTab.settings.heading) {
            if let state = store.state?.agents.first(where: { $0.name == agent }) {
                FormSection {
                    if newName != nil || renaming || renameJob?.isOpen == true || renameJob?.state == "failed" { nameRow() }
                    if newName != nil && !renaming && renameJob?.isOpen != true { roleRow() }
                    serverRow(state)
                    providerRow(state)
                    if changeOpen(state) { changeRows(state) }
                    ProviderAccountSection(store: store, agent: agent, machine: model.machine, card: false)
                }
                // **"Switching to …" under the AI provider comes and goes with the motion of a save's line**
                // (`SaveState.lineMotion`, as the Name row's line; the reviews of 30 October 2026): it came in one frame
                // and moved the rows under it. It follows the readings, so the card animates when it changes.
                .animation(SaveState.lineMotion, value: providerSwitching(state))
                if let error {
                    Text(error).font(FormMetrics.detail).foregroundStyle(.orange).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                EmptyState(symbol: "person.slash", title: String(l10n: "No agent \(agent.agentLabel)"), detail: String(l10n: "This hub does not list the agent."))
            }
        } actions: {
            more
        }
        .task(id: "\(model.hub)/\(model.database)/\(agent)") {
            let start = ContinuousClock.now
            while !Task.isCancelled {
                async let team = model.readTeam(since: start)
                async let machines: Void = model.readMachines()
                _ = await (team, machines)
                if features.contains(AgentRename.feature) { await model.readServers() }
                // A sign-in, a machine check or a rename that he waits for is answered in seconds.
                let quick = model.machine?.check?.isPending == true || model.machine?.login?.isOpen == true ||
                    AgentRename.job(of: agent, in: model.servers)?.isOpen == true
                do { try await store.nap(quick ? 2 : 15) } catch { return }
            }
        }
        .task {
            do { try await Task.sleep(until: opened + LoadingLine.quiet, clock: .continuous) } catch { return }
            quietOver = true
        }
        // Rename… or Deactivate from the agent's row in the sidebar: this page opened for it, and does it here.
        .onChange(of: store.agentAction, initial: true) { _, request in
            guard let request, request.agent == agent else { return }
            store.agentAction = nil
            act(request.action)
        }
    }

    // MARK: Server

    /// The server it runs on, which opens that server's page. What is wrong with the machine is said in orange, only
    /// while it is wrong — **on the row's own line, beside the server's name**, so the row keeps its one height and
    /// nothing under it moves when the words come or go (the rows moved 12 pt). A provider that is signed out is the
    /// Account row's to say.
    @ViewBuilder private func serverRow(_ state: FleetAgent) -> some View {
        if features.contains("machines") {
            let machine = model.machine
            FormRow("Server", symbol: (machine?.os.name ?? "").hasPrefix("macOS") ? "desktopcomputer" : "server.rack") {
                HStack(spacing: FleetSpace.inside) {
                    if let warning = serverWarning(state) {
                        Text(warning).font(FormMetrics.detail).foregroundStyle(.orange).lineLimit(1)
                            .textSelection(.enabled).accessibilityIdentifier("settings-server-warning")
                    }
                    Button(machine?.machine ?? String(l10n: "Open")) { store.destination = .server(machine?.machine ?? agent) }
                        .buttonStyle(FleetOutlineButtonStyle())
                        .help("Its server: versions, network, security, updates and the server check")
                        .accessibilityIdentifier("settings-server")
                }
            }
        }
    }

    private func serverWarning(_ state: FleetAgent) -> String? {
        let words = AgentAttention.items(for: state, serverTime: time, isFresh: store.isFresh, machine: model.machine)
            .compactMap { item -> String? in
                switch item {
                case .signIn: nil
                // A kept reading that this visit reads again is not old yet.
                case .staleReading: machineHeld ? nil : String(l10n: "No current server reading")
                case .updateFailed: String(l10n: "Founderizer update failed")
                case .checkFailed: String(l10n: "Server check failed")
                case .restart: String(l10n: "Restart needed")
                }
            }
        return words.isEmpty ? nil : words.joined(separator: " · ")
    }

    // MARK: AI provider

    /// **The AI that runs it, its model and its reasoning, and Change.** Which provider an agent runs on is a different
    /// question from which account it runs on, so it is a row of its own over the account's.
    private func providerRow(_ state: FleetAgent) -> some View {
        let setup = store.providerSetup(hub: store.hub, database: store.state?.db, agent: agent)
        let open = changeOpen(state)
        let switching = providerSwitching(state)
        return FormRow("AI provider", mark: ProviderIcon(runtime: state.runtime, size: 18),
                       warning: switching ? String(l10n: "Switching to \(providerName(state.runtime))…") : nil) {
            HStack(spacing: FleetSpace.actions) {
                Text(providerWords(state)).foregroundStyle(FleetStyle.muted).lineLimit(1)
                if features.contains("agent_setup") {
                    if !open {
                        SetupMark(setup: setup, subject: String(l10n: "The provider setup"), place: String(l10n: "Select Change on the AI provider row to see it."))
                    }
                    Button(open ? "Hide" : "Change") { changing = !open }
                        .buttonStyle(FleetOutlineButtonStyle()).accessibilityIdentifier("change-provider")
                }
            }
        }
    }

    /// The agent's provider switches now: the AI provider row says "Switching to …" under its title.
    private func providerSwitching(_ state: FleetAgent) -> Bool {
        ProviderState(configured: state.runtime, machine: model.machine, at: time).switchingFrom != nil
    }

    /// The provider, then the model and the reasoning that the agent runs, its own or the owner's default where its
    /// server takes it (owner feature `default_models`): "Codex · GPT-6.1-Sol · High".
    private func providerWords(_ state: FleetAgent) -> String {
        let line = model.line
        let (own, level) = if case .model(let value, let level)? = model.shown(.model) { (value, level) } else { (line?.model, line?.effort) }
        let runs = followed(own, level)
        let shown = runs.model.map { chosen in model.machine?.models?.options.first { $0.model == chosen }?.display_name ?? chosen }
        return ([providerName(state.runtime)] + [shown, runs.effort.map(reasoningName)].compactMap { $0 }).joined(separator: " · ")
    }

    /// The model and the reasoning that this agent's next session gets with these of its own, on its server, the
    /// owner's default included (`DefaultModels.session`, as its helper picks them).
    private func followed(_ own: String?, _ effort: String?) -> ModelDefault {
        guard let runtime = configuredRuntime else { return ModelDefault(model: own, effort: effort) }
        return DefaultModels.session(model.team?.default_models[runtime], model: own, effort: effort,
                                     machine: model.machine?.models, runtime: runtime,
                                     takes: model.machine?.features?.contains(DefaultModels.feature) == true)
    }

    /// The same for the desktop runtime (Codex), whose default is the Codex row's.
    private func followedOnDesktop(_ screen: ScreenSettingsInput) -> ModelDefault {
        DefaultModels.session(model.team?.default_models["codex"], model: screen.model, effort: screen.effort,
                              machine: model.machine?.screen_models, runtime: "codex",
                              takes: model.machine?.features?.contains(DefaultModels.feature) == true)
    }

    private func changeOpen(_ state: FleetAgent) -> Bool {
        guard features.contains("agent_setup") else { return false }
        let setup = store.providerSetup(hub: store.hub, database: store.state?.db, agent: agent)
        return changing ?? setup.reopens(current: state.runtime)
    }

    /// **What Change opens under the AI provider row**: the other provider (an agent in setup gets its provider in its
    /// setup), the model and the reasoning, what the agent may use, and the desktop model of an agent that has one.
    private func changeRows(_ state: FleetAgent) -> some View {
        // Each of them stands under the row's title, not under its mark: they are the AI provider's, opened.
        Group { changeContent(state) }.padding(.leading, FormMetrics.markColumn + FormMetrics.markGap)
    }

    @ViewBuilder private func changeContent(_ state: FleetAgent) -> some View {
        if features.contains("profiles"), state.active != false {
            // After a switch the hub gives the model its defaults: a model of the old provider that waits to be saved
            // is forgotten, and the page reads the new values.
            ProviderView(store: store, agent: agent) { _, _ in
                model.drop(.model)
                Task { await model.readTeam() }
            }
        }
        if let line = model.line {
            modelRows(line, model.machine)
            capabilitiesRow(line)
            if features.contains("screen_model"), line.screen != nil, let machine = model.machine { screenRows(line, machine) }
            if model.machine?.settings_pending == true {
                FormRow("Waiting for \(agent.agentLabel) to load the new settings.", symbol: "clock")
            }
        } else if model.readError != nil || store.connectionError != nil {
            // While the hub does not answer nothing is read: the failed row, never "Reading the settings…". **Not while the
            // window's notice says the outage** (`FleetStore.hubNoticeShows`; fix round 3, item 33): it is said once.
            if !store.hubNoticeShows { FormRow("Settings not read", warning: model.readError) }
        } else {
            LoadingLine(String(l10n: "Reading the settings…"))
        }
    }

    /// What the agent may use. Each box saves at once.
    private func capabilitiesRow(_ line: ReportingLine) -> some View {
        let can = if case .capabilities(let value)? = model.shown(.capabilities) { value } else { line.can ?? fallbackCan }
        // "Tools" (fix round 2): "Can use" is the name of one of the agent's four parts, which lists other things.
        return FormRow("Tools", warning: model.states[.capabilities]?.failure) {
            // **A label never breaks inside a word** (fix round 2, item 98): "She ll" and "Brow ser" when Try again took
            // their room. Where the line cannot hold the mark and the four boxes, the mark goes under them, so the boxes
            // stay where they were; where it cannot hold the four, they go two by two.
            let boxes = AgentSettingsInput.capabilities
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { mark(.capabilities); toolBoxes(boxes, can: can) }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) { toolBoxes(boxes, can: can) }
                    mark(.capabilities)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) { toolBoxes(Array(boxes.prefix(2)), can: can) }
                    HStack(spacing: 10) { toolBoxes(Array(boxes.dropFirst(2)), can: can) }
                    mark(.capabilities)
                }
            }
        }
    }

    /// One box for each of `capabilities`, each as wide as its name.
    private func toolBoxes(_ capabilities: [String], can: [String]) -> some View {
        ForEach(capabilities, id: \.self) { capability in
            Toggle(capability.capitalized, isOn: Binding(get: { can.contains(capability) }, set: { on in
                var next = can.filter { $0 != capability }
                if on { next.append(capability) }
                model.save(.capabilities(next), store: store)
            })).toggleStyle(FleetCheckboxStyle()).fixedSize().accessibilityIdentifier("settings-can-\(capability)")
        }
    }

    // MARK: "…"

    /// **The page's one "…" is the agent's one menu** (`AgentMenu`, the owner's yes of 28 October 2026 to D-5): the same
    /// items as the right-click of its row, in the same three groups. Its name and Deactivate, which he uses about once a
    /// year, are not rows of the card; an agent in setup has no Deactivate, as its setup is what makes it active.
    @ViewBuilder private var more: some View {
        let items = AgentMenu.items(agent, store: store)
        let title = String(l10n: "More \(agent.agentLabel) actions")
        FleetSelect(title, options: items.map { item in
            // A line between two groups: a section with no words (`FleetSelect`).
            FleetOption(item.action, item.title, mark: .symbol(item.symbol),
                        section: item.group == 0 ? nil : String(repeating: " ", count: item.group),
                        destructive: item.action == .delete)
        }, onSelect: { action in act(action) }) {
            // **A 28-pt circle, as every icon button** (T-21; the sidebar's search and +): it was a 40.5 × 28 capsule.
            Image(systemName: "ellipsis").font(IconMetrics.symbol(13)).foregroundStyle(FleetStyle.muted)
        }
        .buttonStyle(FleetIconButtonStyle(rest: true)).disabled(busy).help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("settings-more")
    }

    /// One item of the agent's menu, done on this page: Rename… opens the name's field and Deactivate stops new work here,
    /// where their words are; the others do what they do from the row.
    private func act(_ action: AgentMenu.Action) {
        switch action {
        case .rename: newName = agent; newRole = currentRole ?? ""; renameError = nil; roleError = nil; renameFocus = true
        case .deactivate: Task { await setActive(false) }
        default: AgentMenu.perform(action, agent: agent, store: store)
        }
    }

    // MARK: Name

    private var renameJob: ServerJob? { AgentRename.job(of: agent, in: model.servers) }

    /// The agent's name while Rename… is open, and while a rename goes on or stopped (hub feature `agent_rename`).
    /// Rename sends the new name, and the row says Renaming… while the agent's server moves it there; then the page is
    /// the agent's under its new name. A rename that the server could not finish says why, with Retry. Nobody signs in
    /// again: the agent keeps the OS user it has.
    @ViewBuilder private func nameRow() -> some View {
        let job = renameJob
        let problem = nameProblem(newName)
        FormRow("Name", warning: renameError ?? problem ?? (job?.state == "failed" ? job?.detail ?? String(l10n: "The rename stopped.") : nil)) {
            if renaming || job?.isOpen == true {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Renaming…").foregroundStyle(FleetStyle.muted)
                }.accessibilityIdentifier("settings-renaming")
            } else if let typed = newName {
                HStack(spacing: 8) {
                    // A letter he types takes a refusal's line away. The field's own write of the same text, as it takes
                    // the keyboard, does not: the line went the moment the field came back with the keyboard.
                    TextField(text: Binding(get: { typed }, set: { if $0 != newName { setRenameError(nil) }; setNewName($0) }),
                              prompt: Text(verbatim: "")) {
                        Text("Agent name")
                    }
                        .fieldPlaceholder(String(l10n: "Agent name"), shows: typed.isEmpty)
                        .fleetField(focus: $renameFocus).frame(width: 180).onSubmit { saveIdentity() }
                        .accessibilityIdentifier("settings-name")
                    identityButtons
                }
            } else if let job, job.state == "failed" {
                HStack(spacing: 10) {
                    value(agent.capitalized)
                    Button("Try again") { retryRename(job) }.buttonStyle(FleetOutlineButtonStyle()).accessibilityIdentifier("settings-rename-retry")
                }
            }
        }
    }

    /// **Its role, under its name, while Rename… is open** (the owner's yes of 3 November 2026: "Rename… opens two fields
    /// on Runs on: Name and Role"): team.json `title`, the line under its name on Agents and in its chat's panel. The
    /// white button saves what changed, the role first and then the name: Rename while the name changed, else Save. It
    /// shows only once there is something it can save (T-05: no grey capsule).
    @ViewBuilder private func roleRow() -> some View {
        let typed = newRole ?? ""
        FormRow("Role", warning: roleError ?? roleProblem) {
            HStack(spacing: 8) {
                TextField(text: Binding(get: { typed }, set: { if $0 != newRole { roleError = nil }; newRole = $0 }),
                          prompt: Text(verbatim: "")) {
                    Text("Role")
                }
                    .fieldPlaceholder(String(l10n: "Role"), shows: typed.isEmpty)
                    .fleetField().frame(width: 180).onSubmit { saveIdentity() }
                    .accessibilityIdentifier("settings-role")
                // The Name row's buttons, unseen, so the two fields stand in one column.
                identityButtons.hidden().accessibilityHidden(true)
            }
        }
    }

    /// Cancel and the white Rename (Save while only the role changed), beside the name: they act on both fields.
    @ViewBuilder private var identityButtons: some View {
        HStack(spacing: 8) {
            Button("Cancel") { newName = nil; newRole = nil; renameError = nil; roleError = nil }
                .buttonStyle(FleetOutlineButtonStyle())
            if savingRole {
                ProgressView().controlSize(.small)
            } else if canSaveIdentity {
                Button(nameChanged ? "Rename" : "Save") { saveIdentity() }.buttonStyle(FleetPrimaryButtonStyle())
                    .accessibilityIdentifier("settings-rename")
            }
        }
    }

    /// The role it has now: its team line's, else the fleet state's.
    private var currentRole: String? {
        model.team?.members.first { $0.agent == agent }?.title ?? store.state?.agents.first { $0.name == agent }?.title
    }

    /// The role as the hub keeps it: one line, trimmed, and nil for none.
    private var typedRole: String? { AgentIdentityInput(title: newRole).normalized.title }
    private var roleChanged: Bool { newRole != nil && typedRole != currentRole }
    private var nameChanged: Bool { newName.map { $0 != agent } ?? false }
    private var roleProblem: String? {
        guard let role = typedRole else { return nil }
        return role.count > 60 || role.contains("\n") ? String(l10n: "Use one line of up to 60 characters.") : nil
    }
    private var canSaveIdentity: Bool {
        (nameChanged || roleChanged) && nameProblem(newName) == nil && roleProblem == nil && !savingRole && !renaming
    }

    /// Rename or Save: the role first, where it changed, then the name, where it changed.
    private func saveIdentity() {
        guard canSaveIdentity else { return }
        Task {
            if roleChanged { guard await saveRole() else { return } }
            if nameChanged { rename() } else { newName = nil; newRole = nil }
        }
    }

    /// The role, against a team.json read just before, with the agent's other identity fields as they are. A refusal is
    /// the hub's own words on the Role row.
    private func saveRole() async -> Bool {
        guard let database = store.state?.db else { return false }
        savingRole = true
        defer { savingRole = false }
        do {
            let team = try await HubClient().team(hub: store.hub, database: database)
            var input = team.members.first { $0.agent == agent }?.identity ?? AgentIdentityInput()
            input.title = typedRole
            switch await store.save(.agentIdentity(agent: agent, sha256: team.sha256), note: try input.payload()) {
            case .saved:
                await model.readTeam()
                return true
            case .refused(let words), .conflict(let words): roleError = words
            default: roleError = String(l10n: "The hub has not answered yet. Look at the role before you try again.")
            }
        } catch { roleError = String(l10n: "The hub has not answered. Look at the role before you try again.") }
        return false
    }

    /// The new name, against a team.json read just before. A team.json that changed in between is read once more;
    /// any other refusal is the hub's own words in the row.
    private func rename() {
        guard let typed = newName, typed != agent, !renaming, let database = store.state?.db,
              AgentRename.problem(typed, agent: agent, existing: (model.team?.lines ?? []).map(\.agent)) == nil else { return }
        setRenaming(true); setRenameError(nil)
        Task {
            defer { setRenaming(false) }
            for attempt in 0..<2 {
                do {
                    let team = try await HubClient().team(hub: store.hub, database: database)
                    let receipt = try await HubClient().renameAgent(hub: store.hub, database: database, client: store.installation,
                                                                    agent: agent, sha256: team.sha256, name: typed)
                    newName = nil
                    await store.refresh()
                    store.destination = .agentDetail(receipt.agent, .settings)
                    return
                } catch let HubError.refusal(status, words) {
                    if status == 409, attempt == 0, words.contains("team.json changed") { continue }
                    setRenameError(words); return
                } catch { setRenameError(String(l10n: "The hub has not answered. Look at the agent's name before you try again.")); return }
            }
        }
    }

    /// The Name row's line of a rename that stopped, **with the motion of a save's line** (`SaveState.lineMotion`): it
    /// fades in or out over 0.2 s, and the rows under it move with it (the second review of 30 October 2026: it came in one
    /// frame and moved Server, AI provider and the account's rows down), also when a letter typed in the field takes it
    /// away.
    private func setRenameError(_ words: String?) {
        withAnimation(words != renameError ? SaveState.lineMotion : nil) { renameError = words }
    }

    /// What is wrong with a name he types, or nil: the Name row's line under its field.
    private func nameProblem(_ typed: String?) -> String? {
        typed.flatMap { AgentRename.problem($0, agent: agent, existing: (model.team?.lines ?? []).map(\.agent)) }
    }

    /// The name he types, **with the same motion when its line comes, goes or changes its words** (the reviews of 30
    /// October 2026): the line came in one frame as he typed, and moved Server, AI provider and the account's rows.
    private func setNewName(_ text: String) {
        withAnimation(nameProblem(text) != nameProblem(newName) ? SaveState.lineMotion : nil) { newName = text }
    }

    /// The Name row between its field and "Renaming…", **with the same motion** (the reviews of 30 October 2026): the row
    /// changes its height by 12 pt, and the rows under it moved in one frame when Rename was pressed and when a rename
    /// that stopped gave the field back.
    private func setRenaming(_ on: Bool) {
        withAnimation(on != renaming ? SaveState.lineMotion : nil) { renaming = on }
    }

    /// The rename job again, after the server could not finish it: the hub gives the same job once more, and the server
    /// repeats only what is missing.
    private func retryRename(_ job: ServerJob) {
        guard !renaming, let database = store.state?.db, let server = model.servers?.server(of: agent)?.name,
              let line = model.line, let runtime = job.runtime else { return }
        setRenaming(true); setRenameError(nil)
        Task {
            defer { setRenaming(false) }
            do {
                let team = try await HubClient().team(hub: store.hub, database: database)
                _ = try await HubClient().addServerAgent(hub: store.hub, database: database, client: store.installation,
                                                         server: server, sha256: team.sha256, agent: agent, runtime: runtime,
                                                         role: line.role, reportsTo: nil)
                await model.readServers()
            } catch let HubError.refusal(_, words) { setRenameError(words) }
            catch { setRenameError(String(l10n: "The hub has not answered. Try again.")) }
        }
    }

    // MARK: Model

    /// The model, the full model name where the provider takes other names, and the reasoning. A new model takes the
    /// current reasoning when it offers it, else its default; the two are saved together.
    @ViewBuilder private func modelRows(_ line: ReportingLine, _ machine: MachineStatus?) -> some View {
        let (current, effort) = if case .model(let name, let level)? = model.shown(.model) { (name, level) } else { (line.model, line.effort) }
        // The full model name he typed stays in its field after a refusal; the selects show the hub's value.
        let typed: String? = if model.states[.model]?.failure != nil, case .model(let name, _)? = model.values[.model],
                                name == typedName { name } else { nil }
        let failure = model.states[.model]?.failure
        if let models = machine?.models, models.isFor(configuredRuntime) {
            let supported = current == nil && effort == nil ||
                models.supports(AgentSettingsInput(model: current ?? followed(nil, nil).model, effort: effort, can: []), at: time)
            let reported = line.reported_model.map { String(l10n: "Last used: \($0.model ?? String(l10n: "not reported")) · \($0.effort.map(reasoningName) ?? String(l10n: "default reasoning")), \(fleetDate($0.at))") }
            FormRow("Model", detail: reported, warning: failure) {
                HStack(spacing: 10) {
                    mark(.model)
                    FleetSelect("Model", selection: Binding(get: { current ?? "" }, set: { name in
                        let next = name.isEmpty ? nil : name
                        if next != current { model.save(.model(next, effort: models.effort(effort, with: next)), store: store) }
                    }), options: Self.modelOptions(models, current: current, default: followed(nil, effort).model))
                        .accessibilityIdentifier("setup-model")
                        .help(String(l10n: "New sessions use this. A desktop task uses the desktop model.") + "\n"
                              + String(l10n: "Options read \(fleetDate(models.read_at))."))
                }
            }
            if models.other_names {
                FormRow("Full model name") {
                    TextField(text: Binding(get: { naming ? modelName : typed ?? current ?? "" }, set: { modelName = $0 }),
                              prompt: Text(verbatim: "")) { Text("Leave empty for the default") }
                        .fieldPlaceholder(String(l10n: "Leave empty for the default"), shows: (naming ? modelName : typed ?? current ?? "").isEmpty)
                        .fleetField(focus: $naming).frame(width: 240).accessibilityIdentifier("setup-model-name")
                        .onChange(of: naming) { _, focused in
                            if focused { modelName = current ?? "" } else { saveName(models, current: current, effort: effort) }
                        }
                        .onSubmit { saveName(models, current: current, effort: effort) }
                }
            }
            FormRow("Reasoning", warning: supported ? nil : String(l10n: "Check this server, or select an available model and reasoning.")) {
                FleetSelect("Reasoning", selection: Binding(get: { effort ?? "" }, set: { level in
                    let next = level.isEmpty ? nil : level
                    if next != effort { model.save(.model(current, effort: next), store: store) }
                }), options: Self.effortOptions(models, model: current ?? followed(nil, nil).model, current: effort,
                                                default: followed(current, nil).effort)).accessibilityIdentifier("setup-effort")
            }
        } else {
            // Without a machine reading yet, the saved values only.
            FormRow("Model", warning: machine.map { $0.models?.ok == true ?
                        configuredRuntime.map { String(l10n: "No model list for \(providerName($0)) yet.") } ?? String(l10n: "No model list for its provider yet.") :
                        $0.models?.error ?? String(l10n: "Model options are not reported. Check this server.") }) {
                value(current ?? automaticChoice)
            }
            FormRow("Reasoning") { value(effort.map(reasoningName) ?? automaticChoice) }
        }
    }

    /// The rows of a model select: the owner's default where his Settings give one that this server takes ("Default
    /// (Opus)"), else the runtime's own; the offered models; and a saved model that is not offered.
    private static func modelOptions(_ models: RuntimeModels, current: String?, default chosen: String? = nil) -> [FleetOption<String>] {
        [first(chosen.map { name in models.options.first { $0.model == name }?.display_name ?? name })] +
            models.options.map { FleetOption($0.model, $0.display_name, subtitle: $0.default ? String(l10n: "The provider's default") : nil) } +
            (current.map { name in models.options.contains { $0.model == name } ? [] : [FleetOption(name, name, subtitle: String(l10n: "Not offered now"))] } ?? [])
    }

    /// The rows of a reasoning select: the owner's default ("Default (High)") or the runtime's own, the levels that
    /// the model offers, and a saved level that it does not offer.
    private static func effortOptions(_ models: RuntimeModels, model: String?, current: String?, default chosen: String? = nil) -> [FleetOption<String>] {
        let levels = models.efforts(for: model)
        return [first(chosen.map(reasoningName))] + levels.map { FleetOption($0, reasoningName($0)) } +
            (current.map { levels.contains($0) ? [] : [FleetOption($0, reasoningName($0), subtitle: String(l10n: "Not offered for this model"))] } ?? [])
    }

    /// The first row of a model or reasoning select, which follows the owner's Settings: "Default (Opus)" with his
    /// default's value, with no mark (his yes of 9 November 2026 was to these words), else "Automatic", as Settings ›
    /// General says it (his yes of 10 November 2026; it said "Provider's own", with the mark of none).
    private static func first(_ chosen: String?) -> FleetOption<String> {
        chosen.map { FleetOption("", "Default (\($0))") } ?? FleetOption("", automaticChoice)
    }

    /// The full model name, when its field loses focus or on Return.
    private func saveName(_ models: RuntimeModels, current: String?, effort: String?) {
        let name = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = name.isEmpty ? nil : name
        guard next != current else { return }
        typedName = next
        model.save(.model(next, effort: models.effort(effort, with: next)), store: store)
    }

    /// The model and reasoning of desktop tasks, which Codex runs with its own settings: two rows under the agent's
    /// own model, under the AI provider row.
    @ViewBuilder private func screenRows(_ line: ReportingLine, _ machine: MachineStatus) -> some View {
        let screen = if case .screen(let value)? = model.shown(.screen) { value } else { line.screen ?? ScreenSettingsInput() }
        let models = machine.screen_models
        let gets = ScreenSettingsInput(model: screen.model ?? followedOnDesktop(ScreenSettingsInput()).model, effort: screen.effort)
        let supported = models?.isCurrent(at: time) == true && models?.supportsScreen(gets, at: time) == true
        Group {
            if let models, models.ok {
                FormRow("Desktop model", detail: line.reported_screen_model.map { String(l10n: "Last used: \($0.model ?? String(l10n: "not reported")), \(fleetDate($0.at))") },
                        warning: model.states[.screen]?.failure) {
                    HStack(spacing: 10) {
                        mark(.screen)
                        FleetSelect("Desktop model", selection: Binding(get: { screen.model ?? "" }, set: { name in
                            let next = name.isEmpty ? nil : name
                            if next != screen.model {
                                model.save(.screen(ScreenSettingsInput(model: next, effort: models.effort(screen.effort, with: next))), store: store)
                            }
                        }), options: Self.modelOptions(models, current: screen.model,
                                                         default: followedOnDesktop(ScreenSettingsInput(model: nil, effort: screen.effort)).model))
                            .accessibilityIdentifier("setup-screen-model")
                    }
                }
                FormRow("Desktop reasoning", warning: supported || screen == ScreenSettingsInput() ? nil :
                            String(l10n: "Check this server, or select an available desktop model and reasoning.")) {
                    FleetSelect("Desktop reasoning", selection: Binding(get: { screen.effort ?? "" }, set: { level in
                        let next = level.isEmpty ? nil : level
                        if next != screen.effort { model.save(.screen(ScreenSettingsInput(model: screen.model, effort: next)), store: store) }
                    }), options: Self.effortOptions(models, model: screen.model ?? followedOnDesktop(ScreenSettingsInput()).model,
                                                    current: screen.effort,
                                                    default: followedOnDesktop(ScreenSettingsInput(model: screen.model, effort: nil)).effort))
                        .accessibilityIdentifier("setup-screen-effort")
                }
            } else {
                FormRow("Desktop model", warning: models?.error ?? String(l10n: "Check this server to read its desktop model options.")) {
                    value(screen.model ?? automaticChoice)
                }
                FormRow("Desktop reasoning") { value(screen.effort.map(reasoningName) ?? automaticChoice) }
            }
        }
    }

    // MARK: Deactivate

    private func setActive(_ active: Bool) async {
        busy = true; defer { busy = false }
        error = nil
        guard await model.readTeam(), let team = model.team else { error = model.readError; return }
        switch await store.save(.agentActivation(agent: agent, sha256: team.sha256, active: active)) {
        case .saved, .behind: break       // .behind: only with queue false
        case .conflict(let words), .refused(let words): error = words
        case .unconfirmed: error = String(l10n: "The hub has not answered. The request line at the bottom of the window can try again.")
        }
        await model.readTeam()
        await model.readMachines()
        await store.refresh()
    }

    // MARK: Parts

    private func mark(_ field: AgentSettingEdit.Field) -> some View {
        SaveMark(state: model.states[field]) { model.retry(field, store: store) }
    }

    private func value(_ text: String) -> some View {
        Text(text).foregroundStyle(FleetStyle.muted).multilineTextAlignment(.trailing).textSelection(.enabled)
    }
}

/// The small mark beside a control that saves itself: nothing for a second, then Saving… moving, Saved for a moment, Retry after a failed save (its
/// reason is the row's warning), Retry alone when another request waits in the window's request line (its reason on
/// hover only), or a note that another save changed the value meanwhile.
struct SaveMark: View {
    let state: SaveState?
    let retry: () -> Void
    /// The owner's words for `.behind`, 26 October 2026: on hover, and nowhere else.
    static let behind = String(l10n: "A saved request waits. Check it below.")

    var body: some View {
        Group {
            switch state {
            case .saving?:
                // **Nothing for a save that answers inside a second, then the moving words** (B-MOT-19, the one loading
                // look): a spinner and "Saving…" came at once for every save, and most answer in milliseconds.
                Held { ShimmeringWords(text: String(l10n: "Saving…")) }
            case .saved?:
                Label("Saved", systemImage: "checkmark").foregroundStyle(FleetStyle.muted)
            case .failed(let reason)?:
                Button("Try again", action: retry).buttonStyle(FleetOutlineButtonStyle()).help(reason).accessibilityHint(reason)
            case .changedElsewhere?:
                Text("Changed elsewhere").foregroundStyle(FleetStyle.muted)
                    .help("Another save changed this value meanwhile. The value shown is the saved one.")
            case .behind?:
                Button("Try again", action: retry).buttonStyle(FleetOutlineButtonStyle())
                    .help(Self.behind).accessibilityHint(Self.behind)
            case nil: EmptyView()
            }
        }.font(FormMetrics.detail)
    }
}

extension SaveState {
    /// **A save's line and its Try again come and go over 0.2 s, ease-out** (the round-3 panel, MOT): the line fades in or
    /// out, and the rows under it move with it. A refused save moved Account and Usage 34 pt in one frame, and an unanswered
    /// one moved the rows 16–50 pt. Nil for a change that adds or takes away neither — so a click shows its new value in its
    /// own frame — and with Reduce Motion.
    static func motion(from old: SaveState?, to new: SaveState?) -> Animation? {
        guard old?.failure != new?.failure || (old?.retries ?? false) != (new?.retries ?? false) else { return nil }
        return lineMotion
    }

    /// The one motion of a row's line that comes or goes: 0.2 s, ease-out; none with Reduce Motion.
    static var lineMotion: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.2)
    }
}
