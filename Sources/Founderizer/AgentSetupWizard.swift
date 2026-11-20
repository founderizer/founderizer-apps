import AppKit
import FleetCore
import FleetMark
import FleetOwnerAPI
import SwiftUI

/// **An agent that is not active yet shows its setup in place of its chat**, at the owner's own word (25 October 2026):
/// "If agent is in Setup, show an onboarding instead of the chat view! Onboarding needs to be super simple! Choose
/// the server, choose AI provider, sign in... and confirm! that's it!!" He approved these pages from a mockup the same
/// day: the AI provider, the install while it runs, and the sign-in. A worker's server is not a page: the agent got it
/// when it was added.
///
/// **There is nothing to confirm** (the owner, 26 October 2026: "why does it ask for confirmation when it's all done?
/// it should just activate it"): once he is signed in, the switch to another provider, the settings the machine
/// loads, the machine check and the activation all run by themselves under one moving "Setting up <Agent>", which is
/// also what the chat shows until it can answer (`ChatSettingUp`). Nothing on these pages goes back either: the
/// provider is chosen on its own page, and an install or a sign-in that goes on is the page whatever was pressed
/// before. Every page comes from the hub's own readings (`AgentSetupFlow`), so the screen can be left and opened
/// again at any step, and the chat, its composer and its panel come back the moment the hub reports the agent active.
///
/// An active agent whose machine reports it signed out shows the same pages without Activate: it is active already,
/// so the page it would reach is its own chat and Settings, which come back when the hub reports it signed in.
///
/// **The manager of a new fleet gets its server in its setup** (hub feature `manager_server`; the owner, 4 November 2026:
/// "The agent is done BY AGENT and here we're setting the fleet, no servers yet"): first its AI provider, then
/// "Manager's server", whose pages are Add server's (`AddServerView.Placing`) (the owner, 16 November 2026: "agent
/// onboarding should ask first for the name and AI provider before the server page"). This Mac keeps the provider of
/// the press (`FleetStore.chosenProvider`), and as soon as the server is there the setup gives the manager that server
/// and that provider in one command, by itself. Its install and its sign-in follow, then "Setting up Manager" until its
/// session runs. It is active from the start, so nothing checks or activates it here.
///
/// **In a fleet whose first run did not ask, its name and the fleet's servers come first** (`ManagerSetupStart`; the
/// owner, 15 November 2026, of a manager with no server: "no option to chnage the name of the manager etc... very bad",
/// "it misses many steps of the onboarding! like the name of the agent, fleet shape", "they look good" to the pictures
/// in `~/dev/founderizer-plans/manager-setup-steps/`, and "Yes, start it" to the hub's part): "Name your manager",
/// whose Continue renames the manager on the hub when the name changed, then its AI provider, then "Your fleet's
/// servers", whose Continue keeps the step on the hub. With "1 server" this Mac then runs one step as root on the hub's
/// own server (`OneServerRemote`), under the moving "Setting up <Name>", and the manager then gets the hub's server
/// with the provider he chose: its server's page does not show. The hub's kept step says that the slider's page is
/// done. **That root step runs only after his press on Continue on this Mac**: a setup that is opened again with "1
/// server" kept and no server service on the hub's server shows the slider on that step, and nothing that the hub says
/// starts the step.
///
/// **Each page is one centered step: its mark, its title and its one way on** (the owner, 26 October 2026: "centering
/// and only showing the next action (dont show the send button if it's not clickable ...)", approved from a mockup
/// the same day for every page). A button shows only while it can be pressed; while the machine works, the title is
/// the moving words of what it does, and Claude Code's code goes by itself when it is pasted (`CodeField`).
struct AgentSetupWizard: View {
    @Bindable var store: FleetStore
    let agent: String

    /// The servers, the machines and the team as the app read them last (`FleetStore.reading`), so the setup opens
    /// on its own page in its first frame. It opened on "Setting up" and changed to its page 48–112 ms later.
    private var servers: ServerList? {
        get { store.reading("servers.list") } nonmutating set { store.keep(newValue, as: "servers.list") }
    }
    private var machines: MachineList? {
        get { store.reading("machines") } nonmutating set { store.keep(newValue, as: "machines") }
    }
    private var team: TeamSnapshot? {
        get { store.reading("team.snapshot") } nonmutating set { store.keep(newValue, as: "team.snapshot") }
    }
    /// The other provider he chose on this visit, until the agent runs it.
    @State private var switchingTo: String?
    /// **The command that gives a manager with no server its server and its provider** went on this visit, by itself
    /// (`placeChosen`): once, and again only by a press on a provider.
    @State private var placeAsked = false
    /// The hub refused that command, or did not answer it: the provider's page shows again with its words, where a press
    /// tries again.
    @State private var placeRefused = false
    /// This view's own mark for the page that it tells the store (`WizardPages.tell`, `gone`).
    @State private var placeMark = UUID()
    /// A request is on its way.
    @State private var busy = false
    /// The hub's own words when it refused a step. They stay until the next step.
    @State private var refusal: String?
    /// He opened the provider's page, so the step after it (Claude Code's code) is the one in front of him.
    @State private var opened = false
    /// His press on a card, on this visit, asked for the sign-in that comes now or after its install or preparation:
    /// its page opens by itself, once (`AgentSetupFlow.opensByItself`).
    @State private var askedSignIn = false
    @State private var code = ""
    /// The code went to the hub, so the page says "Signing in" until the machine's reading moves on: the sign-in's own
    /// time (`updated_at`) when it went, or nil. A sign-in that waits for a code again since then lost it on the way
    /// (`MachineLogin.codeOnItsWay`), and the page asks for it again.
    @State private var sentFrom: Double?
    /// The activation is on its way to the hub.
    @State private var activating = false
    /// The machine check this visit asked for, by the check it followed, so each one is asked once.
    @State private var askedCheck: Int?
    /// This visit asked the hub to activate the agent: once, and again only by Try again.
    @State private var askedActivation = false
    /// The hub took the activation: the page waits for the state that says so.
    @State private var activated = false
    @State private var askedSwitch = false
    /// The hub's features at this visit's first read, which decide if the name and the servers come first: a hub that
    /// gets them while the server's page shows does not take that page away from under his hands.
    @State private var startFeatures: [String]?
    /// The words in the field of "Name your manager".
    @State private var typedName = ""
    /// The step of the slider of "Your fleet's servers".
    @State private var step = ServersStep.two
    /// This Mac's step on the hub's own server for "1 server", and the wait after it (`HubShareModel`): the store
    /// keeps it, so that it is the same after × and a new opening of this page.
    private var share: HubShareModel { store.hubShare() }
    /// The reads of this visit, one after the other, that had no list of the hub's servers while the hub answered its
    /// state: after `unreadReadsMost` of them the moving title says so.
    @State private var unreadReads = 0
    /// The page itself moves the slider to the kept step now, which is no move of his.
    @State private var standsOnKept = false
    /// The rename of this page's Continue is on its way or done: the page stays the name's until the view of the
    /// manager's new name takes its place, so that no slider shows for a moment under the old name.
    @State private var renaming = false

    private var time: Double { store.state?.time ?? 0 }
    private var line: FleetAgent? { store.state?.agents.first { $0.name == agent } }
    private var runtime: String { line?.runtime ?? "codex" }
    /// **The AI that he picked for an agent on a key or a model server** (picture 8): its install, then "Setting up",
    /// with no sign-in page and no provider page. nil for an agent on a plan.
    private var modelProvider: ModelProvider? { line?.modelProvider }
    private var server: ServerEntry? { servers?.server(of: agent) }
    private var job: ServerJob? { AgentSetupFlow.job(of: agent, on: server, active: signingInAgain) }
    private var machine: MachineStatus? { machines?.machines.first { $0.agent == agent } }
    private var teamLine: ReportingLine? { team?.lines.first { $0.agent == agent } }
    private var name: String { agent.agentLabel }
    /// It is active and only signed out: no Activate, no machine check, no way back to it.
    private var signingInAgain: Bool { line?.active == true && !placing }
    /// **It gets its first server** (`AgentSetupFlow.places`), from its server's page to its first session: its own
    /// install counts as an agent's in setup, and nothing activates it.
    private var placing: Bool {
        line.map { AgentSetupFlow.places($0, features: store.state?.ui_features ?? [], placing: store.placing(agent)) } ?? false
    }
    /// **The server that joined for an agent with no server yet** (`FleetStore.joinedServer`): it gets the agent with the
    /// provider that he chose before (`placeChosen`). A server that left the fleet, or that another agent took since, is
    /// not one to give it: the page is its server's again.
    private var placeOn: String? {
        // "1 server" is kept and the hub's own server is ready: the manager goes there.
        if case .onHub(let name) = start { return name }
        guard let joined = store.joinedServer(agent) else { return nil }
        guard let list = servers else { return joined }
        guard let entry = list.servers.first(where: { $0.name == joined }), !entry.hub,
              entry.agents.allSatisfy({ $0 == agent }) else { return nil }
        return joined
    }
    /// The server it goes on: before the command that gives it its first server, the one that command names.
    private var serverName: String { server?.name ?? machine?.machine ?? placeOn ?? String(l10n: "its server") }
    /// Its server is a Mac, which has no user step: also the server that it goes on before the hub lists it there, so
    /// that the install's bar has its number of parts before the install's first read (the manager's first setup).
    private var installsOnMac: Bool { (server ?? servers?.servers.first { $0.name == placeOn })?.isMac == true }
    /// Something goes on that the page is about: an install or a preparation, or a sign-in.
    private var running: Bool { job?.isOpen == true || machine?.login?.isOpen == true }

    /// **The page comes from this visit's own read.** An install and a sign-in move on in seconds, so a kept reading
    /// opened the setup on a page it had left ("Installing" for 251 ms, then "Sign in"). Until the read answers, the
    /// setup shows nothing for a second, then its moving title.
    private var readingsCurrent: Bool { answered }
    /// This visit's first read has answered.
    @State private var answered = false
    /// When this visit began: its "Setting up" shows a second later, and stands half a second once it showed.
    @State private var began = ContinuousClock.now

    /// **What comes before the server's page of a manager with no server** (`ManagerSetupStart`): nothing for another
    /// agent, on a hub without the parts, and once a server joined for it on this Mac, whose provider's page is next
    /// as before.
    private var start: ManagerSetupStart {
        ManagerSetupStart.page(role: line?.role, placed: line?.placed, joined: store.joinedServer(agent) != nil,
                               features: startFeatures, named: store.managerNamed, list: servers)
    }

    /// **The slider shows though "1 server" is kept**: the hub's own server has no server service and no step of this
    /// visit made one (only his press starts that step), or the step or the wait after it stopped. Else the page is the
    /// moving "Setting up <Name>": the step runs, or the hub's reading of the server's service is to come.
    private var sliderShowsAgain: Bool {
        guard case .sharing(let rootStep) = start, !share.running else { return false }
        return share.stopped || (rootStep && !share.done)
    }

    private var page: AgentSetupPage {
        // With no server yet: its name where the hub can rename it, its provider, the fleet's servers where the hub has
        // that part, then its server, and the install that the server and the provider start together.
        if line?.placed == false {
            return start.page(renaming: renaming, provider: store.chosenProvider(agent), placeOn: placeOn, refused: placeRefused)
        }
        if modelProvider != nil { return AgentSetupFlow.accountPage(job: job, runtime: runtime) }
        return AgentSetupFlow.page(runtime: runtime, job: job, machine: machine, switchingTo: switchingTo)
    }

    var body: some View {
        Group {
            // Add server's own pages, which are a setup page of their own.
            if readingsCurrent, page == .server { serverStep } else { steps }
        }
        .animation(.easeInOut(duration: 0.18), value: page)
        .task(id: "\(store.hub)/\(store.state?.db ?? "")/\(agent)") { await poll() }
        .onChange(of: page) { before, now in
            opened = false; code = ""; sentFrom = nil
            // The words of a stop on the name's page or on the slider's are about that page.
            if before == .name || before == .servers { refusal = nil }
            // His press asked for the sign-in at the end of these pages, and for nothing after they end.
            switch now {
            case .installing, .switching, .signIn: break
            default: askedSignIn = false
            }
        }
        // What stopped a step of the slider is about that step: another step takes its line away.
        // His move of the slider takes the words of a stop away, which were about the step before it. The page's
        // own move to the kept step (`stand`) is none of his, and leaves the words of a stop that the store kept.
        .onChange(of: step) {
            if standsOnKept { standsOnKept = false; return }
            share.words = nil
            if page == .servers { refusal = nil }
        }
        // The slider stands on the kept step whenever a read gives one, also one that the visit's first read did not
        // have: a Continue on another step would change the kept step.
        .onChange(of: servers?.keptStep) { _, kept in if let kept { stand(on: kept) } }
        .onChange(of: readingsCurrent ? Self.placeName(page) : nil, initial: true) { _, now in
            store.wizardPages.tell(agentSetup: now.map { .init(agent: agent, page: $0) }, by: placeMark)
        }
        .onDisappear { store.wizardPages.gone(placeMark) }
        // "Name your manager" is this setup's first page, with no Back: Esc closes the wizard there, as on Add
        // server's first page (the owner's yes of 12 November 2026: "On the first page, it closes the wizard.").
        .preference(key: SetupFirstPage.self, value: readingsCurrent && page == .name)
        .accessibilityIdentifier("agent-setup")
    }

    /// The page by its fixed name (`AppPlace`, `setup_state`'s `place`), with no default: a new page needs a name.
    private static func placeName(_ page: AgentSetupPage) -> AppPlace.SetupPage {
        switch page {
        case .name: .name
        case .servers: .servers
        case .server: .server
        case .provider: .provider
        case .installing: .installing
        case .switching: .switching
        case .signIn: .signIn
        case .activate: .activate
        }
    }

    /// **The manager's own setup shows its steps on Back's line** (`ManagerSetupSteps`; the owner, 15 November 2026, of
    /// a manager with no server: "no progress steps ... very bad", and "they look good" to their pictures): while the
    /// manager gets its first server, from its server's page to its first session. Another agent's setup, and a
    /// manager that ran before and signs in again, show none: he saw no picture of those.
    private var isFirstSetupOfManager: Bool { line?.role == "manager" && placing }
    private var progress: SetupProgress? {
        isFirstSetupOfManager ? SetupProgress(names: ManagerSetupSteps.names, current: ManagerSetupSteps.current(page)) : nil
    }

    private var steps: some View {
        SetupPage(progress: progress) {
            // Back on the provider's page goes to the name's page, and Back on the slider's page to the provider's, as
            // in the first run. No other page here goes back.
            if readingsCurrent, start == .servers, !busy {
                if page == .servers {
                    SetupBack { refusal = nil; store.noteProvider(nil, for: agent) }.keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("agent-setup-back")
                } else if page == .provider, line?.placed == false, startFeatures?.contains(FleetShapeHub.rename) == true {
                    SetupBack { refusal = nil; store.noteManagerNamed(false) }.keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("agent-setup-back")
                }
            }
        } step: {
            Group {
                if !readingsCurrent {
                    if store.addedAgent == agent {
                        // **"Adding Juno", as Add agent said it, until the page can draw** (fix round 3, item 12).
                        SetupStep(title: String(l10n: "Adding \(name)"), waits: true) {
                            AgentGlyph(name: agent, size: GlyphSize.making, making: String(l10n: "Adding \(name)"))
                        }
                    } else {
                        // Nothing for a second: the page it opens on comes with the first readings.
                        Held(since: began) { settingUp }
                    }
                } else {
                    switch page {
                    case .name: NameManagerPage(name: $typedName, stopped: refusal, busy: busy) { Task { await takeName() } }
                    case .servers: fleetServers
                    case .server: EmptyView()       // `serverStep`, in place of this page
                    case .provider: providers
                    case .installing(let provider):
                        SetupStep(title: title, waits: true) { mark(provider) } content: {
                            // The steps of the server's job as a bar, from the queue on; a new job starts it again.
                            if let bar = AgentSetupFlow.installBar(job, onMac: installsOnMac) {
                                SetupStepsBar(steps: bar.steps, running: bar.running).id(job?.id)
                            }
                        }
                    case .switching: settingUp
                    case .signIn(let provider): signIn(provider)
                    case .activate:
                        if signingInAgain {
                            SetupStep(title: String(l10n: "Signing in to \(providerName(runtime))"), waits: true) { mark(runtime) }
                        } else if placing {
                            // Active from the start: its session starts by itself once it is signed in.
                            settingUp
                        } else { activation }
                    }
                }
            }.animation(.easeInOut(duration: 0.18), value: page)
        }
    }

    // MARK: the server

    /// **"<Agent>'s server"**, Add server's own pages under the agent's glyph: a VPS or a Mac that joins for it. The one
    /// that joined gets the agent with the provider that he chose before, by itself, as soon as this page reads it.
    private var serverStep: some View {
        AddServerView(store: store, addAgent: { _ in },
                      placing: .init(agent: agent) { joined in
                          store.noteJoined(joined, for: agent)
                          Task { await read(); await follow() }
                      })
    }

    /// The provider's own icon, over the title of each page about it: for an agent on a key or a model server, the AI
    /// that he picked (picture 8: "Installing Gemini on app-1", Gemini's logo).
    private func mark(_ provider: String) -> some View { ProviderIcon(runtime: provider, provider: modelProvider, size: SetupMetrics.mark) }

    /// The name of the page he is on. Each one says what it asks, so no page needs a line to explain itself.
    private var title: String {
        switch page {
        case .name: String(l10n: "Name your manager")
        case .servers: String(l10n: "Your fleet's servers")
        case .server: String(l10n: "\(name)'s server")
        case .provider: String(l10n: "\(name)'s AI provider")
        // The step of the server's job that runs is the bar under it (`SetupStepsBar`), never a number in it.
        case .installing(let provider): AgentSetupFlow.installing(modelProvider?.label ?? providerName(provider), on: serverName)
        case .switching: String(l10n: "Setting up \(name)")
        case .signIn(let provider): String(l10n: "Sign in to \(providerName(provider))")
        case .activate: String(l10n: "Activate \(name)")
        }
    }

    /// **One moving title from the sign-in to the chat**: the switch to the other provider, the settings the machine
    /// loads, the machine check and the activation, and then the chat's own "Setting up" (`ChatSettingUp`), which
    /// looks the same, so the page does not change while the machine works.
    private var settingUp: some View {
        SetupStep(title: String(l10n: "Setting up \(name)"), waits: true) {
            AgentGlyph(name: agent, size: GlyphSize.making, making: String(l10n: "Setting up \(name)"))
        }
    }

    // MARK: its name and the fleet's servers

    /// **"Your fleet's servers"**, the first run's page: the fleet is the hub and the manager here, so the page draws
    /// the agents to come itself. While "1 server" is kept and the hub's own server is made ready, the page is the
    /// moving "Setting up <Name>", as each wait of this setup; when that stopped, the slider is back with the reason
    /// over Continue, which tries again, or keeps another step.
    @ViewBuilder private var fleetServers: some View {
        switch start {
        case .unread:
            // No list of the hub's servers yet: the moving title, and after eight reads with none, why, under it.
            // The reads go on, and the page goes on by itself with the first list.
            SetupStep(title: String(l10n: "Setting up \(name)"), waits: true) {
                AgentGlyph(name: agent, size: GlyphSize.making, making: String(l10n: "Setting up \(name)"))
            } content: {
                if unreadReads > Self.unreadReadsMost {
                    SetupWarning(String(l10n: "Founderizer cannot read \(name)'s server now."))
                        .accessibilityIdentifier("agent-setup-unread")
                }
            }
        case .sharing where !sliderShowsAgain: settingUp
        default:
            // The manager by its own name, as the page before asked for it.
            FleetServersPage(plan: FleetPlan(manager: agent.capitalized, agents: []), step: $step,
                             stopped: share.words ?? refusal, busy: busy || share.running) { Task { await keep() } }
        }
    }

    /// Continue of "Name your manager": the manager's new name on the hub, when it is another than the one it has, and
    /// then the page of the fleet's servers. The page that shows the manager goes with its new name by itself
    /// (`FleetStore.noteRenamed`). A team.json that changed between the read and the press is read again, once.
    private func takeName() async {
        guard !busy, let wanted = ManagerName.agentName(typedName), let database = store.state?.db else { return }
        busy = true; refusal = nil
        defer { busy = false }
        // The hub of the press: a store that goes to another hub meanwhile gets no command of this page.
        let hub = store.hub
        guard await store.writable(), store.hub == hub else { return }
        guard wanted != agent else {
            // He goes on with the name that it has: no rename, and no note of an earlier one that got no answer.
            store.noteRenamed(from: agent, to: nil)
            store.noteManagerNamed(true)
            return
        }
        renaming = true
        for attempt in 0..<2 {
            do {
                let team = try await HubClient().team(hub: hub, database: database)
                guard store.hub == hub, store.state?.db == database else { renaming = false; return }
                store.noteRenamed(from: agent, to: wanted)
                _ = try await HubClient().nameManager(hub: hub, database: database, client: store.installation,
                                                      agent: agent, sha256: team.sha256, name: wanted)
                // The next reading has the new name: the page goes to it, and its view opens on the slider. A store
                // that went to another hub meanwhile gets no mark: the name was this hub's.
                guard store.hub == hub, store.state?.db == database else { renaming = false; return }
                store.noteManagerNamed(true)
                await store.refresh()
                renaming = false
                return
            } catch let HubError.refusal(refused) {
                if refused.status == 409, attempt == 0, refused.means(.teamChanged) { continue }
                store.noteRenamed(from: agent, to: nil)
                refusal = refused.words; renaming = false; return
            } catch {
                // No answer: the hub can have the new name. The next reading says which name it is, and the page
                // goes with it.
                refusal = String(l10n: "The hub has not answered. Try again.")
                await store.refresh()
                renaming = false
                return
            }
        }
        renaming = false
    }

    /// Continue of "Your fleet's servers": the hub keeps the step. With "1 server" the same command lets the hub's own
    /// server take agents, and this Mac's step on that server follows when the server has no server service yet.
    private func keep() async {
        // The hub, its generation and its model of the press: the command goes to that hub, and this Mac's step
        // runs for it alone (`HubShareModel.run`), also when the store goes to another hub meanwhile.
        let hub = store.hub, share = self.share
        guard !busy, !share.running, let database = store.state?.db else { return }
        busy = true; refusal = nil; share.words = nil
        defer { busy = false }
        guard await store.writable(), store.hub == hub else { return }
        let chosen = step
        for attempt in 0..<2 {
            do {
                let team = try await HubClient().team(hub: hub, database: database)
                guard store.hub == hub, store.state?.db == database else { return }
                let receipt = try await HubClient().keepShape(hub: hub, database: database, client: store.installation,
                                                              sha256: team.sha256, step: chosen)
                // The hub took this Continue: what stopped before it is over.
                share.taken()
                await read()
                guard store.hub == hub, store.state?.db == database else { return }
                if chosen == .one, receipt.root_step == true || servers?.hubRow?.joined != true {
                    await share.run(store: store, server: servers?.hubRow?.name ?? "hub")
                    await read()
                }
                return
            } catch let HubError.refusal(refused) {
                if refused.status == 409, attempt == 0, refused.means(.teamChanged) { continue }
                refusal = refused.words; return
            } catch {
                // No answer: the hub can have the step. The read says so, and the page then goes on by it.
                refusal = String(l10n: "The hub has not answered. Try again.")
                await read()
                return
            }
        }
    }

    // MARK: the AI provider

    /// Two cards, and a click on one is the way on. The one the agent has now carries a check mark. Under them, in
    /// orange, why the setup stopped the last time, in the hub's own words.
    private var providers: some View {
        // One line under the title in the manager's first setup, which says what the page asks for (his pictures).
        SetupStep(title: title, detail: isFirstSetupOfManager
                    ? String(l10n: "The AI that \(name) works with. You sign in with your own account.") : nil) {
            AgentGlyph(name: agent, size: SetupMetrics.mark)
        } content: {
            VStack(spacing: FleetSpace.inside) {
                HStack(alignment: .top, spacing: 14) {
                    card("codex")
                    card("claude")
                }
                if let why = refusal ?? AgentSetupFlow.stopped(runtime: runtime, job: job, machine: machine).map(Self.lines) {
                    // The hub's own words of a failed install, with any code they carry, are behind the line.
                    SetupWarning(why).accessibilityIdentifier("agent-setup-stopped")
                        .help(refusal == nil && job?.state == "failed" ? job?.detail ?? "" : "")
                    // **A failed install says why over Try again** (D-3, his own Activate pattern: "a stop is one
                    // orange line over Try again"): the same install again, and the server repeats only what is
                    // missing. The cards stay for a switch to the other provider.
                    // Never gone for the moment another page's request is on its way: a press waits for the hub.
                    if job?.state == "failed", job?.kind == "install", !busy {
                        Button("Try again") { Task { await choose(runtime) } }.buttonStyle(FleetPrimaryButtonStyle())
                            .keyboardShortcut(.defaultAction).accessibilityIdentifier("agent-setup-install-again")
                    }
                }
            }
        }
    }

    /// **What stopped, over why, in two short lines** (T-35): the hub writes "Codex did not install: vps-2 could not
    /// reach the internet." as one line of ten words, so its words are split where they say why.
    static func lines(_ words: String) -> String {
        guard let colon = words.range(of: ": ") else { return words }
        let head = words[..<colon.lowerBound], tail = words[colon.upperBound...]
        guard !head.isEmpty, !tail.isEmpty else { return words }
        return head + ".\n" + tail
    }

    /// The provider with the check mark: for a manager with no server, the one that he chose on this Mac, when he chose
    /// one; else the one that the agent has now.
    private var markedProvider: String { line?.placed == false ? store.chosenProvider(agent) ?? runtime : runtime }

    /// A press while the hub cannot take a write waits for it (`choose`).
    private func card(_ provider: String) -> some View {
        ProviderCard(provider: provider, marked: provider == markedProvider, busy: busy,
                     id: "agent-setup-provider-\(provider)") { Task { await choose(provider) } }
    }

    // MARK: the sign-in

    /// The sign-in on the agent's machine: the one the setup started, or the one the server's install started for
    /// Claude Code.
    private var login: MachineLogin? { machine?.login.flatMap { $0.isOpen ? $0 : nil } }

    /// **One page for each sign-in, its steps over what he enters** (the owner, 10 November 2026: "this kind of
    /// onboarding with steps, key etc... needs to be applied the same way in other places, like AI provider
    /// onboardings"), as a VPS provider's token page has them (`SetupSteps`). **Claude Code**: open the sign-in page,
    /// sign in and copy the code it shows, then the field, which sends a pasted code by itself. **Codex**: open the
    /// sign-in page, sign in and enter the code under the steps, in large type in its box, with Copy beside it (the
    /// owner, 20 November 2026: "add a button to copy the code, more visual!"); the page goes on by itself when the
    /// machine reports the sign-in. The first step's link opens the page and copies Codex's code too; no "Open it
    /// again" stands under it. Until the provider has printed its link, and from the code's send until the
    /// machine reports, the title moves. **After his own press on a card the provider's page opens by itself**
    /// (`AgentSetupFlow.Start.signsIn`): the link is the press for a sign-in that he did not start on this visit.
    @ViewBuilder private func signIn(_ provider: String) -> some View {
        let prompt = job?.state == "needs_owner" ? job?.prompt : nil
        let link = prompt?.signInURL ?? login?.signInURL
        let shown = prompt?.deviceCode ?? login?.deviceCode
        if login?.codeOnItsWay(sentFrom: sentFrom) == true || login?.state == "signing_in" {
            // A wait names what it waits for (B-ONB-5, fix round 2): "Signing in to Claude Code".
            SetupStep(title: String(l10n: "Signing in to \(providerName(provider))"), waits: true) { mark(provider) } content: { refused }
        } else if let link {
            SetupStep(title: title) { mark(provider) } content: {
                // What he does on the provider's page comes before what he enters here, so its steps stand over it.
                Group {
                    if login?.waitsForCode == true { SetupSteps.signIn(at: link) } else { SetupSteps.deviceCode(at: link) }
                }
                .environment(\.openURL, OpenURLAction { _ in openSignIn(link, code: shown); return .handled })
                if login?.waitsForCode == true {
                    CodeField(code: $code) { send() }.accessibilityIdentifier("agent-setup-paste")
                } else if let shown {
                    SetupCode(shown, id: "agent-setup-code")
                }
                refused
            }
            // **His press on the card was the press to sign in**: its page opens as soon as the machine prints its link.
            .task(id: "\(link.absoluteString) \(askedSignIn)") {
                if AgentSetupFlow.opensByItself(askedHere: askedSignIn, opened: opened, link: link) { openSignIn(link, code: shown) }
            }
        } else {
            SetupStep(title: login?.isSigningOut == true ? String(l10n: "Signing out of \(providerName(provider))") : String(l10n: "Starting the sign-in"),
                      waits: true) {
                mark(provider)
            } content: { refused }
        }
    }

    /// The hub's own words when it refused a step, in orange under it.
    @ViewBuilder private var refused: some View {
        if let refusal { SetupWarning(refusal) }
    }

    /// The provider's own sign-in page in his browser, with Codex's code copied for its page: the first step's link, or
    /// his press on the card. Once open, his press asks for nothing more.
    private func openSignIn(_ link: URL, code shown: String?) {
        if let shown { copyMessage(shown) }
        opened = true
        askedSignIn = false
        NSWorkspace.shared.open(link)
    }

    // MARK: Activate

    /// **The activation runs by itself** (the owner, 26 October 2026: "why does it ask for confirmation when it's all
    /// done? it should just activate it"): the machine check, and the activation the moment the check passed, under
    /// the moving "Setting up <Agent>". What stopped them is one orange line over Try again, which runs both again.
    @ViewBuilder private var activation: some View {
        if case .stopped(let why) = activationState {
            SetupStep(title: title) { AgentGlyph(name: agent, size: SetupMetrics.mark) } content: {
                if let why { SetupWarning(why).accessibilityIdentifier("agent-setup-blocker") }
                if store.canWrite {
                    Button("Try again") { tryAgain() }.buttonStyle(FleetPrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction).accessibilityIdentifier("agent-setup-again")
                }
            }
        } else {
            settingUp
        }
    }

    private enum ActivationState: Equatable {
        /// The check or the activation goes on, or goes next by itself.
        case runs
        /// It stopped, with the hub's words or the check's own when there are any.
        case stopped(String?)
    }

    /// **The install of an agent on a key or a model server stopped**: the activation's page says why, in one orange
    /// line over Try again, which runs the install again (picture 8: "If the check stops: Activate Iris, one orange
    /// line, Try again, as today"). Such an agent has no provider page, where a plan's agent sees it.
    private var installStopped: String? {
        guard let modelProvider, let job, job.kind == "install", job.state == "failed" else { return nil }
        return AgentSetupFlow.stopped(runtime: runtime, job: job, machine: machine, provider: modelProvider)
    }

    private var activationState: ActivationState {
        if busy || activating || checking || loading { return .runs }
        if let refusal { return .stopped(refusal) }
        if let installStopped { return .stopped(installStopped) }
        if permits { return askedActivation && !activated ? .stopped(nil) : .runs }
        // The check goes next, or it has no answer yet.
        guard let asked = askedCheck, let check = machine?.check, check.id > asked, !check.isPending else { return .runs }
        return .stopped(checked ? AgentSetupFlow.blocker(machine?.verify) : check.detail)
    }

    /// The newest check of this machine passed for its saved settings, recently enough for the hub to activate it.
    private var permits: Bool {
        guard let machine, let verify = machine.verify else { return false }
        return verify.permitsActivation(machine: machine, desiredRevision: machines?.desired_revision, at: time)
    }

    private var checking: Bool { machine?.check?.isPending == true }
    /// The newest check of this machine has its result.
    private var checked: Bool { machine?.check?.state == "completed" && machine?.verify?.check == machine?.check?.id }

    /// The machine is still taking its new settings: a check now would check the old ones.
    private var loading: Bool {
        guard let machine else { return false }
        return machine.settings_pending == true || machine.update.state != "current"
    }

    // MARK: the hub

    /// What a provider card asks the hub to do, from what the hub has now (`AgentSetupFlow.start`).
    private func choose(_ provider: String) async {
        guard !busy, let database = store.state?.db else { return }
        busy = true; refusal = nil
        defer { busy = false }
        guard await store.writable() else { return }
        if line?.placed == false {
            // This Mac keeps the provider until the server is there, and the server's page or the slider's is next.
            // With the server there already, the command goes now.
            store.noteProvider(provider, for: agent)
            placeRefused = false
            await placeChosen(database: database)
            await read()
            return
        }
        let start = AgentSetupFlow.start(chosen: provider, runtime: runtime, job: job, machine: machine)
        switch start {
        case .activate:
            switchingTo = nil
        case .signIn:
            switchingTo = nil
            switch await store.save(.machineSignin(agent: agent, runtime: provider, replace: false)) {
            case .saved, .unconfirmed, .behind: break      // .behind: only with queue false
            case .refused(let words), .conflict(let words): refusal = words
            }
        case .installAgain:
            switchingTo = nil
            guard let server = server?.name else { refusal = String(l10n: "Founderizer cannot read \(name)'s server now."); break }
            // Its first server's install again: the same command, on the same server, with the provider it has.
            if placing { await place(on: server, runtime: provider, database: database); break }
            do {
                let team = try await HubClient().team(hub: store.hub, database: database)
                let role = team.lines.first { $0.agent == agent }?.role == "lead" ? "lead" : "worker"
                _ = try await HubClient().addServerAgent(hub: store.hub, database: database, client: store.installation,
                                                         server: server, sha256: team.sha256, agent: agent,
                                                         runtime: provider, role: role, reportsTo: nil)
            } catch let HubError.refusal(refused) { refusal = refused.words }
            catch { refusal = String(l10n: "The hub has not answered. Try again.") }
        case .prepare:
            switchingTo = provider; askedSwitch = false
            // Signed in there already: nothing to prepare, the switch goes now.
            if teamLine?.runtime_switch?.to == provider, teamLine?.runtime_switch?.ready == true { break }
            guard let server = server?.name else { refusal = String(l10n: "Founderizer cannot read \(name)'s server now."); break }
            do {
                _ = try await HubClient().prepareServerRuntime(hub: store.hub, database: database, client: store.installation,
                                                               server: server, agent: agent, runtime: provider)
            } catch let HubError.refusal(refused) { refusal = refused.words; switchingTo = nil }
            catch { refusal = String(l10n: "The hub has not answered. Try again."); switchingTo = nil }
        }
        askedSignIn = start.signsIn && refusal == nil
        await read()
    }

    /// **The server and the provider that he chose, once both are there** (`ManagerSetupStart.page`), for the manager of
    /// a new fleet: by itself once the server is there, and at once for a press when it is there already. A refusal, or
    /// no answer, shows the provider's page again with the words of it.
    private func placeChosen(database: String) async {
        guard line?.placed == false, let provider = store.chosenProvider(agent), let placeOn else { return }
        placeAsked = true
        await place(on: placeOn, runtime: provider, database: database)
        placeRefused = refusal != nil
        askedSignIn = refusal == nil            // its install ends in his sign-in
    }

    /// **Its server and its provider, in one command** (owner API 1.82): the hub sets its server and, for the other
    /// provider, that provider's start, and gives the server its install, which the next pages follow. A team.json that
    /// changed between the read and the press is read again, once.
    private func place(on server: String, runtime provider: String, database: String) async {
        for attempt in 0..<2 {
            do {
                let team = try await HubClient().team(hub: store.hub, database: database)
                _ = try await HubClient().moveAgent(hub: store.hub, database: database, client: store.installation,
                                                    agent: agent, sha256: team.sha256, server: server, runtime: provider)
                await store.refresh()
                return
            } catch let HubError.refusal(refused) {
                if refused.status == 409, attempt == 0, refused.means(.teamChanged) { continue }
                refusal = refused.words; return
            } catch { refusal = String(l10n: "The hub has not answered. Try again."); return }
        }
    }

    /// Claude Code's code, to the machine, and then forgotten here.
    private func send() {
        guard let login, !login.codeOnItsWay(sentFrom: sentFrom), let ready = MachineLogin.code(code) else { return }
        busy = true; refusal = nil; sentFrom = login.updated_at
        Task {
            defer { busy = false }
            if !(await store.command(.machineSigninCode(agent: agent, code: ready))) {
                sentFrom = nil
                refusal = store.sendError ?? String(l10n: "The code did not reach the hub. Paste it again.")
            }
            code = ""
            await read()
        }
    }

    private func check() async {
        guard !busy else { return }
        busy = true; refusal = nil
        defer { busy = false }
        askedCheck = machine?.check?.id ?? 0
        switch await store.save(.machineCheck(agent: agent)) {
        case .saved, .unconfirmed, .behind: break      // .behind: only with queue false
        case .refused(let words), .conflict(let words): refusal = words
        }
        await read()
    }

    /// Activation against the newest team.json: the hub takes it only after a passed check of the saved settings. The
    /// chat comes back by itself when the state says the agent is active.
    private func activate() async {
        guard !busy, permits, let database = store.state?.db else { return }
        busy = true; activating = true; refusal = nil
        defer { busy = false; activating = false }
        do {
            let team = try await HubClient().team(hub: store.hub, database: database)
            switch await store.save(.agentActivation(agent: agent, sha256: team.sha256, active: true)) {
            case .saved: activated = true
            case .behind: break               // only with queue false
            case .refused(let words), .conflict(let words): refusal = words
            case .unconfirmed: refusal = String(l10n: "The hub has not answered. The request line at the bottom of the window can try again.")
            }
        } catch { refusal = String(l10n: "Founderizer cannot read the team now. Try again.") }
        await store.refresh()
        await read()
    }

    /// **What runs by itself**, after each reading: the machine check, the activation once the check passed, and the
    /// switch once the hub says it is ready. A finished preparation of the other provider needs no check of its own:
    /// the hub has the agent's machine report as soon as the server's job ends.
    private func follow() async {
        guard !busy else { return }
        // "1 server" is kept and the page waits for the hub's reading of its own server's service: a count of reads
        // ends that wait. It is a read and no write, and it starts nothing on the server: only Continue does. While
        // this Mac's step runs, nothing counts. Another agent's setup never comes here, so that step holds none.
        if case .sharing = start {
            if page == .servers, !share.running, !sliderShowsAgain { share.countRead() }
            return
        }
        // The hub has the parts and answers its state, and its list of servers did not answer: the page counts those
        // reads, and after eight says so under its moving title. A hub that does not answer at all is the window's
        // own notice, and counts nothing here.
        if start == .unread {
            if store.isFresh { unreadReads += 1 }
            return
        }
        unreadReads = 0
        guard store.canWrite else { return }
        // A manager with no server whose provider he chose and whose server is there now: the command that gives both
        // goes by itself, once on this visit (`placeChosen`).
        if line?.placed == false, !placeAsked, !placeRefused, store.chosenProvider(agent) != nil, placeOn != nil,
           let database = store.state?.db {
            busy = true; refusal = nil
            defer { busy = false }
            guard await store.writable() else { return }
            await placeChosen(database: database)
            await read()
            return
        }
        // Once on each visit: a check that fails or an activation the hub refuses is asked again only by Try again.
        if page == .activate, !signingInAgain, !placing, !checking, !loading, refusal == nil, installStopped == nil {
            if permits, !askedActivation {
                askedActivation = true
                await activate()
                return
            }
            if !permits, askedCheck == nil {
                await check()
                return
            }
        }
        guard let switchingTo else { return }
        if !askedSwitch, runtime != switchingTo, teamLine?.runtime_switch?.to == switchingTo,
           teamLine?.runtime_switch?.ready == true, let sha256 = team?.sha256 {
            askedSwitch = true; busy = true
            defer { busy = false }
            if !(await store.command(.agentRuntime(agent: agent, sha256: sha256, runtime: switchingTo))) {
                refusal = store.sendError ?? String(l10n: "The switch was not confirmed.")
                self.switchingTo = nil
            }
            await store.refresh()
            return
        }
        // The agent runs the provider it was switched to: the switch is over.
        if runtime == switchingTo, machine?.runtime.name == switchingTo, machine?.settings_pending == false {
            self.switchingTo = nil
        }
    }

    /// The reads with no list of the hub's servers after which the page says so.
    private static let unreadReadsMost = 8

    /// The page's own move of the slider to the step that the hub keeps (`standsOnKept`).
    private func stand(on kept: ServersStep) {
        guard step != kept else { return }
        standsOnKept = true
        step = kept
    }

    /// After a stop: the check and the activation run again by themselves, as on a first visit; a stopped install of
    /// an agent on a key or a model server runs again first, on the same account.
    private func tryAgain() {
        refusal = nil; askedCheck = nil; askedActivation = false; activated = false
        if installStopped != nil { Task { await installAgain() }; return }
        // **A check that found no key gives the grant again first** (review M4), under the hood: a grant that failed
        // after the add left team.json and the vault without it. Then the check, as on a first visit.
        if let secret = noKeyGrant { Task { await grantAgain(secret); await follow() }; return }
        Task { await follow() }
    }

    /// The key of this agent's account, when its last check stopped on the account item's `no_key`.
    private var noKeyGrant: String? {
        guard modelProvider != nil, let item = machine?.verify?.items.first(where: { $0.kind == "account" }),
              item.state != "ok", item.code == "no_key" else { return nil }
        return team?.modelAccount(of: agent)?.secret
    }

    private func grantAgain(_ secret: String) async {
        guard !busy, let database = store.state?.db else { return }
        busy = true
        defer { busy = false }
        guard await store.writable() else { return }
        // A failure here leaves the check to say it again: no line of its own (no new element).
        try? await ModelAccountGrant.give(secret, to: agent, store: store, hub: store.hub, database: database)
    }

    /// The install of an agent on a key or a model server again: the same command, server and account. The server
    /// repeats only what is missing.
    private func installAgain() async {
        guard !busy, let database = store.state?.db, let server = server?.name else { return }
        busy = true
        defer { busy = false }
        guard await store.writable() else { return }
        do {
            let team = try await HubClient().team(hub: store.hub, database: database)
            guard let account = team.members.first(where: { $0.agent == agent })?.account else {
                refusal = String(l10n: "Founderizer cannot read the team now. Try again."); return
            }
            let role = team.lines.first { $0.agent == agent }?.role == "lead" ? "lead" : "worker"
            _ = try await HubClient().addServerAgent(hub: store.hub, database: database, client: store.installation, server: server,
                                                     sha256: team.sha256, agent: agent, account: account, role: role)
        } catch let HubError.refusal(refused) { refusal = refused.words }
        catch { refusal = String(l10n: "The hub has not answered. Try again.") }
        await read()
    }

    /// Reads the servers, the machines and the team: every 2 seconds while something goes on, else every 5.
    private func poll() async {
        while !Task.isCancelled {
            await read()
            // Nothing for a second, then "Setting up" moving, which stands half a second once it showed (`settle`),
            // then the page whole (fix round 2, item 97).
            if !answered { await store.settle(since: began) }
            if startFeatures == nil, let state = store.state {
                startFeatures = state.ui_features ?? []
                // The field opens on the manager's own name with capitals, never on its role, which is no name; and
                // on the suggestion when it has the hub's default. The slider opens on the kept step, or on the
                // middle one. Both are set before the page first draws.
                typedName = agent == ManagerName.fallback ? ManagerName.suggested : agent.capitalized
                if let kept = servers?.keptStep { stand(on: kept) }
            }
            answered = true
            if store.addedAgent == agent { store.addedAgent = nil }
            // Signed in again, or its session runs: the state's own reading of it ends these pages (`AgentSetupFlow.shows`).
            if page == .activate, signingInAgain || placing { await store.refresh() }
            await follow()
            let quick = running || switchingTo != nil || checking || page == .activate || page == .servers
            do { try await store.nap(quick ? 2 : 5) } catch { return }
        }
    }

    private func read() async {
        guard store.isFresh, let database = store.state?.db else { return }
        let hub = store.hub
        async let serverList = try? HubClient().servers(hub: hub, database: database)
        async let machineList = try? HubClient().machines(hub: hub, database: database)
        async let snapshot = try? HubClient().team(hub: hub, database: database)
        let (nextServers, nextMachines, nextTeam) = await (serverList, machineList, snapshot)
        guard !Task.isCancelled, store.hub == hub, store.state?.db == database else { return }
        if let nextServers { servers = nextServers }
        if let nextMachines { machines = nextMachines }
        if let nextTeam { team = nextTeam }
    }
}
