import AppKit
import FleetCore
import FleetMark
import FleetOwnerAPI
import SwiftUI

/// Add a machine, as the wizard of the first run is: **one decision on a page**, and the page after it asks only
/// what that decision needs (PRODUCT.md 2 and P3).
///
///   1. **How it joins**, as three cards and nothing else: a VPS, which this Mac installs over its own SSH connection;
///      a Mac mini or Studio that stays on, whose own installer waits there for a link code; or Install by hand, one
///      line the owner pastes on the machine himself, for a server that this Mac cannot reach over SSH.
///   2. **Which AI runs on a Mac**, the owner's one choice, as cards with the providers' logos: that Mac's sitting shows
///      only what it needs. **A VPS is asked for no AI and gets no agent by itself** (the owner, 13 November 2026: "on
///      the step about AI provider when adding a server... I think we should move that step to AFTER we have the
///      server, so it has less friction?"): its install puts no AI on it, so the page asked only for the runtime of an
///      agent that Add server then added, also on a server that he wanted for an agent he has. A VPS joins empty. The
///      AI is asked where an agent is placed on it: Add agent asks for it with the agent's name, and an agent that
///      moves there keeps its own.
///   3. **A Mac that stays on** first says where its installer comes from and to open it, with the one thing to answer
///      in Apple's own setup: without that answer, automatic login is not available and a restart stops at a password.
///   4. **The machine**: only what that way needs. **A VPS takes the first run's own pages** (the onboarding the owner
///      approved on 4 November 2026: "The same pages add the fleet's VPS and every server after it"): Hetzner,
///      DigitalOcean, Vultr, Akamai or Other VPS. A provider makes the server from its token, pasted once, and the
///      fleet's Tailscale key, made once where this Mac holds none; any other VPS is its address, the check, the
///      password once and Install. A Mac gives the address and link code its installer shows, and on a hub from before
///      `server_names` its name, which is filled in; a hub with it names the server by its name in Tailscale at its join.
///   5. **The install**, in the same rows as the hub's install (`MachineInstallRun`): each step with its state, the
///      last lines the machine printed, and its own checks at the end. Nothing to press while it runs, except
///      Tailscale's own link for a server that is not on the private network.
///   6. **A VPS that is installed** shows its two ways on and nothing else (`ServerInstalled`): Add agent, for a new
///      agent there, and Open server. Where Add agent's New server opened this wizard, it goes on to Add agent for the
///      new server by itself.
///
/// The hub itself is not added here: a fleet with no hub has no line to give, so `FirstRunView` installs the first
/// machine and claims it.
///
/// **The same pages are the first step of the manager's setup in a new fleet** (`placing`; hub feature
/// `manager_server`): "<Agent>'s server" under its glyph, a VPS or a Mac (the onboarding page he approved on 4 November
/// 2026, screen 8), with no AI to choose and no line to paste: its own provider is the next page, and the server that
/// joined goes there.
struct AddServerView: View {
    @Bindable var store: FleetStore
    /// Add agent, on the new server by its name; nil while the fleet has not named it.
    let addAgent: (String?) -> Void
    /// Add agent for the new server: it reads the servers first, so that the page has the new server in it, and opens
    /// only while Add server still shows. Its second argument is true where Add agent's New server opened this wizard:
    /// the agent then goes on the new server with the name and the AI that he chose before it.
    var goOnToAddAgent: (String, Bool) async -> Void = { _, _ in }
    /// **The name and the AI of the agent that Add agent's New server is for** (the owner, 16 November 2026: the name and
    /// the AI before the server): a Mac takes them for its first agent, with no AI page of its own, and the Mac card does
    /// not show for Other models, which no Mac takes. Read only where Add agent opened this wizard (`fromAddAgent`).
    var newAgent: NewAgent?

    /// An agent's name, as the hub keeps it, and its AI on a plan; nil for a provider after Other models.
    struct NewAgent {
        let name: String
        let ai: ServerAI?
    }
    /// The agent whose first server this is, or nil for Add server.
    var placing: Placing?

    /// An agent with no server: its name, and where the server that joined for it goes.
    struct Placing {
        let agent: String
        let place: (String) -> Void
    }

    /// Where the wizard stands. The install itself lives in the store, so this screen can be left and opened again
    /// while a ten-minute install goes on: `opened()` puts the wizard back on it. A VPS's `machine` is the first run's
    /// three cards, and `key`, `token` and `vps` are the first run's pages after them. `again` is "Start again", from
    /// the link under the two cards of the manager's server page (`StartAgainModel`).
    private enum Page: Equatable { case ways, ai, opening, machine, install, key(CloudProvider), token(CloudProvider), vps, again }
    /// The page by its fixed name (`AppPlace`, `setup_state`'s `place`), with no default: a new page needs a name.
    private static func placeName(_ page: Page) -> AppPlace.AddServerPage {
        switch page {
        case .ways: .ways
        case .ai: .ai
        case .opening: .opening
        case .machine: .machine
        case .install: .install
        case .key: .key
        case .token: .token
        case .vps: .vps
        case .again: .again
        }
    }

    @State private var page = Page.ways
    /// "Start again": what its page read, and its run (`StartAgainModel`). Nothing of it outlives this view.
    @State private var again = StartAgainModel()
    /// This view's own mark for the page that it tells the store (`WizardPages.tell`, `gone`).
    @State private var placeMark = UUID()
    /// The pasted line only: what that machine runs, which its line differs by.
    @State private var kind = "linux"
    /// Any VPS by its address, and the fleet's own Tailscale key, as the first run has them.
    @State private var vps = FleetVPSModel()
    @State private var net = FleetNetworkModel()
    /// **The VPS that a provider makes goes on while other pages show**, as the install does: it is the install's first
    /// minutes, a second press waits for it, and `opened()` puts the wizard back on it.
    @MainActor private static let cloudModel = FleetCloudModel()
    private var cloud: FleetCloudModel { Self.cloudModel }
    /// A provider makes a server for this wizard now, also behind another page: nothing may cover that work as if the
    /// setup stood still (`FleetStore.welcomeCovers`).
    @MainActor static var builds: Bool { cloudModel.stage == .making || cloudModel.stage == .joining }
    /// **What the provider's list needs to know of a server that the fleet holds already** (`CloudExisting.reuse`): the
    /// devices of this Mac's own network, and the fleet's servers whose install this Mac saw end. Both are read when
    /// the list opens.
    @State private var devices: [FleetOnTailscale.Device] = []
    /// The devices of that read when it says what the network is now, or nil (`FleetOnTailscale.live`): only they
    /// say where a server that Founderizer made stands to this fleet (`known`).
    @State private var live: [FleetOnTailscale.Device]?
    /// The installs that this Mac saw end for this hub, by server: the address that each reached (`InstallEnds`).
    @State private var ended: [String: String] = [:]
    /// The servers that this Mac made for this hub, with their ids at the provider (`MadeServers`).
    @State private var madeKept: [String: String] = [:]
    /// **The server of the provider's list that "Use this server" took**, by its provider, its id and the address that
    /// its install goes to: that install proves its build record by the id (`MachineInstallModel.provenServer`).
    @State private var reusedServer: (provider: CloudProvider, id: String, address: String)?
    /// The server that the first run made for this agent, once these pages looked at it (`installFirst`).
    @State private var firstTried: FleetStore.MadeServer?
    /// The list that shows already had its one suggestion of a server to take again.
    @State private var suggested = false
    /// The hub is asked whether it answers, before a server is made (`makeServer`); `makeAsked` counts the presses, and
    /// the question is the page's own task, so it ends with the page and makes nothing after it.
    @State private var asksHub = false
    @State private var makeAsked = 0
    /// The last press that the task took: a run of the page's tasks with no new press makes nothing.
    @State private var makeTaken = 0
    @State private var code: JoinCode?
    @State private var list: ServerList?
    @State private var busy = false
    @State private var error: String?
    @State private var copied = false
    /// Add agent's New server opened this wizard, so the new server goes on to Add agent by itself (`goesOn`). It is
    /// read when the wizard opens: the page history is the store's, and it moves while an install runs.
    @State private var fromAddAgent = false
    /// The hub did not offer the new server to Add agent in time, so the page with Add agent stands.
    @State private var addAgentWaits = false
    /// The new server for which he pressed Add agent on this wizard: Add agent opens for it, with the servers read first
    /// (`goOnToAddAgent`), from the page's own task, which ends with the page.
    @State private var addAgentFor: String?
    /// The install that this page hands over ended before the page opened (`opened`): its server joined long ago.
    @State private var handsOverAgain = false
    /// Add server fills the window (`FleetStore.fillsWindow`): its × closes it, so its first page has no Back.
    @Environment(\.fillsWindow) private var fillsWindow
    private var time: Double { store.state?.time ?? Date().timeIntervalSince1970 }
    private var taken: [String] { list?.servers.map(\.name) ?? [] }
    private var join: JoinState? { code?.state(in: list) }
    private var model: MachineInstallModel { store.installModel() }
    /// The owner names the new server: only on a hub from before `server_names`, which names it by its name in Tailscale.
    private var asksName: Bool { Servers.asksName(store.state?.ui_features) }
    private var nameProblem: String? { asksName ? Servers.nameProblem(model.name, taken: taken) : nil }
    /// The installed server by its name: the one typed, or the one the hub gave it at its join (nil until then). The
    /// words say "the server" while it has none.
    private var installed: String? { asksName ? model.name : model.server }
    /// The pasted line's server by its name: the one the line was made for, or, for a line made with no name, the one
    /// the hub gave the server that joined with it (nil until then).
    private var lineName: String? { code.flatMap { $0.name.isEmpty ? join?.server : $0.name } }

    /// **The manager whose first server these pages give** (`placing`, for the agent with the role manager), or nil.
    /// Its setup shows its steps on Back's line, and these pages are its step "Servers" (`ManagerSetupSteps`; the
    /// owner's "they look good" of 15 November 2026 to their pictures).
    private var manager: String? {
        guard let agent = placing?.agent, store.state?.agents.first(where: { $0.name == agent })?.role == "manager" else { return nil }
        return agent
    }

    /// The steps of the manager's setup, on each of these pages but a build and an install, which show their own
    /// steps and their minutes under their title: two lines of dots on one page had the word "Network" two times.
    private var progress: SetupProgress? {
        guard manager != nil, page != .install, page != .again, !building else { return nil }
        return SetupProgress(names: ManagerSetupSteps.names, current: ManagerSetupSteps.servers.rawValue)
    }

    /// One line under the title of the manager's server page, which has two cards and no other words.
    private var detail: String? {
        guard page == .ways, let manager else { return nil }
        return String(l10n: "\(manager.agentLabel) needs a server of its own that stays on.")
    }

    /// **Each page is a setup step, as the first run's are** (`SetupPage`, `SetupStep`): the product's muted mark at
    /// the size of every step's mark, the title under it, what the page asks under that, and Back at the page's top left.
    /// The page puts the whole step in the middle of the window, and a wait is the title's moving words.
    var body: some View {
        SetupPage(progress: progress) { back } step: {
            SetupStep(title: title, waits: waits, width: page == .machine && model.way == .linux ? SetupMetrics.cardsWidth
                        : SetupMetrics.width, detail: detail) { mark } content: {
                // The first run's own pages keep what they ask in the middle, as there; cards and forms read from their
                // own leading edge.
                if centred {
                    asked
                } else {
                    VStack(alignment: .leading, spacing: FleetSpace.block) { asked }
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onAppear { opened() }
        .onChange(of: page, initial: true) { _, now in store.wizardPages.tell(addServer: Self.placeName(now), by: placeMark) }
        .onDisappear { store.wizardPages.gone(placeMark); again.close() }
        // Its first page, also of the manager's setup: where it has no Back, Esc closes the wizard that fills the window.
        .preference(key: SetupFirstPage.self, value: page == .ways)
        .task(id: "\(store.hub)/\(store.state?.db ?? "")") { await poll() }
        // The install of a VPS that its provider made starts by itself once the server joined: also on this page opened
        // again during the build, which was not the page that pressed.
        .onChange(of: model.running) { _, running in if running, !again.running { page = .install } }
        // "Start again" is offered no more (another agent came, the manager got its server): its page goes, unless a
        // run began, whose steps and whose stop stay to be read.
        .onChange(of: offersStartAgain) { _, offers in
            if !offers, page == .again, !again.started { again.close(); page = .ways }
        }
        // What goes on by itself after an install runs from the page and not from a view under its title: a step
        // taller than its page takes that view out of the page (`SetupAction`), and its task would end with it.
        .task(id: handsOver) { if handsOver, let placing { await handOver(placing) } }
        .task(id: goesOn) { if goesOn { await goOn() } }
        .task(id: addAgentFor) {
            if let server = addAgentFor { await goOnToAddAgent(server, fromAddAgent); addAgentFor = nil }
        }
        // The provider's list of servers: what `reuse` reads, at each list that opens.
        .task(id: chooses) { if chooses { suggested = false; await readFleet() } }
        // One fleet's list and its network's devices say nothing of another fleet (`known`).
        .onChange(of: store.hub) { list = nil; live = nil }
        // **In an agent's own setup, a server that the fleet can take again is the chosen one when its list opens**:
        // "New server" stood chosen over the server of the install that stopped, so the press at hand made a second
        // one. Once for each list: "New server" stays his to choose.
        .task(id: firstToReuse) {
            if let firstToReuse, chooses, !suggested, cloud.chosen == nil { cloud.chosen = firstToReuse; suggested = true }
        }
        .task(id: makeAsked) { if makeAsked > makeTaken { makeTaken = makeAsked; await makeServer() } }
        // The server that the first run made for this agent: its install starts by itself (`installFirst`).
        .task(id: firstServer) { if let firstServer { await installFirst(firstServer) } }
    }

    /// The provider's list of servers shows.
    private var chooses: Bool {
        if case .token = page { return cloud.stage == .choosing }
        return false
    }

    @ViewBuilder private var asked: some View {
        switch page {
        case .ways:
            ways
            if offersStartAgain {
                SetupLink(StartAgain.Words.start) { again.open(hub: store.hub); page = .again }
                    .frame(maxWidth: .infinity).accessibilityIdentifier("start-again")
            }
        // The link's conditions hold at the press too: a fleet that got an agent meanwhile is not started again.
        case .again: StartAgainContent(model: again) { if offersStartAgain { again.run(store: store) } }
        case .ai: aiChoice
        case .opening: opening
        case .machine: machine
        case .install: install
        case .key(let provider): key(provider)
        case .token(let provider): token(provider)
        case .vps: vpsPages
        }
    }

    /// **The link "Start again" shows under the two cards** (`StartAgain.offers`; the owner's "Yes, build it" of 15
    /// November 2026): only while these pages give the manager its first server, with no install and no build that
    /// runs, while the page does not ask the hub, and while the reading that the window draws has no other agent
    /// than the manager and no agent on a server.
    private var offersStartAgain: Bool {
        guard let manager, let state = store.state else { return false }
        return StartAgain.offers(givesManagerItsServer: true, runs: model.running || Self.builds, asksHub: asksHub,
                                 otherAgents: state.agents.filter { $0.name != manager }.count,
                                 serversWithAnAgent: state.agents.filter(\.placed).count)
    }

    private var centred: Bool {
        switch page {
        case .key, .token, .vps: true
        default: false
        }
    }

    /// The mark of the page, as the first run has it: the product's own, muted; Tailscale's logo over its key; the
    /// provider's own logo over its token, its choice and its build (`CloudMark`); a server over any other VPS's pages,
    /// and a lock over its password.
    @ViewBuilder private var mark: some View {
        switch page {
        case .key: NetworkMark()
        case .token(let provider): CloudMark(provider: provider, size: SetupMetrics.mark)
        case .vps:
            IconTile(symbol: asksPassword ? "lock" : "server.rack", size: SetupMetrics.mark).accessibilityHidden(true)
        // The agent's own glyph over its server, as over every page of its setup.
        case .ways where placing != nil: AgentGlyph(name: placing?.agent ?? "", size: SetupMetrics.mark)
        default:
            // The mark of the first run, as quiet: this screen is that wizard again.
            FounderizerMark(size: SetupMetrics.mark, plate: Color.white.opacity(0.05), ink: Color.white.opacity(0.13))
                .accessibilityHidden(true)
        }
    }

    private var asksPassword: Bool {
        if case .password = vps.phase { return true }
        return false
    }

    /// The machine works and he has nothing to do: a line being made, an install that runs, a line that waits for
    /// its server, a VPS being made or checked. The title's words move then, and nothing spins.
    private var waits: Bool {
        switch page {
        case .ways, .ai, .opening: return false
        case .again: return again.reading || again.running
        case .machine: return busy
        case .key: return net.busy
        case .token: return building || asksHub || (cloud.stage == .choosing && cloud.offer == nil)
        case .vps:
            switch vps.phase {
            case .checking, .waiting: return true
            default: return false
            }
        case .install: return model.way != .line ? model.running || goesOn || handsOver : lineWaits
        }
    }

    /// The server is in, and goes to the agent's setup once the hub offers it (`handOver`): only the server of an
    /// install that this agent's setup started (`MachineInstallModel.forAgent`; the review of 17 November 2026).
    private var handsOver: Bool { placing != nil && model.checklist != nil && model.forAgent == placing?.agent }

    /// **The agent that an install of these pages is for** (`MachineInstallModel.forAgent`): the agent whose setup shows
    /// them, or the new agent of Add agent's New server; nil for Add server alone.
    private var installFor: String? { placing?.agent ?? (fromAddAgent ? newAgent?.name : nil) }

    /// The pasted line waits for its server: it is open and has not expired.
    private var lineWaits: Bool {
        guard let code else { return false }
        return (join?.state ?? "open") == "open" && code.expires_at > time
    }

    /// The name of the page the owner is on. Each one says what it asks, so no page needs a line to explain itself.
    private var title: String {
        switch page {
        case .ways: placing.map { String(l10n: "\($0.agent.agentLabel)'s server") } ?? String(l10n: "Add server")
        // A step that failed has a true title: what is still there.
        case .again: again.started ? again.failed?.failedTitle ?? StartAgain.Words.starting : StartAgain.Words.start
        case .ai: String(l10n: "Which AI runs on this Mac?")
        case .opening: String(l10n: "Open the installer on that Mac")
        case .machine:
            switch model.way {
            // The first run's "A VPS for your fleet": the fleet has its own, and the agents run on the servers he adds.
            case .linux: String(l10n: "A VPS for your agents")
            case .mac: String(l10n: "The Mac that stays on")
            case .line: String(l10n: "The server you install by hand")
            }
        case .key: net.busy ? String(l10n: "Connecting your network") : String(l10n: "Your Tailscale key")
        // The build is the install's first steps, under the install's own title, so the words stay when it goes on. The
        // hub names the server at its join, after the build.
        case .token(let provider):
            building ? String(l10n: "Installing the server")
                // After the token was taken, a stop leaves the page the server's: its title too.
                : cloud.stage == .choosing || cloud.tokenTaken
                    ? placing.map { String(l10n: "\($0.agent.agentLabel)'s server at \(provider.name)") }
                    ?? String(l10n: "A server at \(provider.name)")
                : String(l10n: "Your \(provider.name) token")
        case .vps:
            switch vps.phase {
            case .address: String(l10n: "Your VPS")
            case .checking: String(l10n: "Checking \(vps.host)")
            case .waiting: String(l10n: "Waiting for \(vps.host)")
            case .password: String(l10n: "Password for \(vps.target?.user ?? "root")@\(vps.host)")
            case .ready, .stopped: vps.host
            }
        case .install:
            switch model.way {
            // A stop has a true title (fix round 3, item 51): "Installing server-2" stood over it.
            // And so has an end: "Installing worker-5" stood over "worker-5 is in your fleet".
            // A server with no name yet has a whole sentence of its own when it did not install: inside "%@ did not
            // install" its words stood as a name, and Spanish read "No se pudo instalar El servidor" (the owner's photo
            // of a customer's page, 16 November 2026).
            case .linux: model.failure != nil && !model.running
                ? installed.map { String(l10n: "\($0) did not install") } ?? String(l10n: "The server did not install")
                : model.checklist != nil && !model.running ? String(l10n: "\(installed ?? String(l10n: "The server")) is installed")
                : String(l10n: "Installing \(installed ?? String(l10n: "the server"))")
            case .mac: model.failure != nil && !model.running
                ? installed.map { String(l10n: "\($0) did not link") } ?? String(l10n: "The server did not link")
                : model.checklist != nil && !model.running ? String(l10n: "\(installed ?? String(l10n: "The server")) is linked")
                : String(l10n: "Linking \(installed ?? String(l10n: "the server"))")
            // **The wait is the moving title** (T-36, fix round 2): "Waiting for server-2", where a row said "Waiting
            // for server-2 to join…" under a still "Your join line".
            case .line: lineWaits ? String(l10n: "Waiting for \(lineName ?? String(l10n: "the server"))") : String(l10n: "Your join line")
            }
        }
    }

    /// One step back, as the first run's wizard has it, and out of the wizard from its first page where the wizard does
    /// not fill the window (there its × closes it): at the page's top left, where every setup page has it, and Esc too.
    /// An install that runs has no way back: it is the page, and it keeps going whether this screen shows or not. So
    /// has a VPS that its provider makes, which is the install's first steps: a Back there would leave the server at the
    /// provider and not in the fleet.
    @ViewBuilder private var back: some View {
        if page == .ways {
            // An agent's setup starts here, so its first page has nothing to go back to; nor has Add server when it
            // fills the window, whose × closes it (`SetupClose`), unless Add agent's New server opened it.
            if placing == nil, store.history.back.last == .addAgent {
                SetupBack { store.destination = .addAgent }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("add-server-back")
            } else if placing == nil, !fillsWindow {
                SetupBack { store.destination = .settings(.servers) }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("add-server-back")
            }
        } else if !model.running && !building && !handsOver && !goesOn && !asksHub && !again.running {
            SetupBack {
                switch page {
                case .again: again.close()          // nothing of a run is kept: the page reads again when it opens
                // A Mac's stopped order: this page reads it no more. **An install that stopped goes with it**, as the
                // first run's Back has it (`install.again()`; a review of 17 November 2026): before, the next form
                // showed that install's stop in orange before any press. The form keeps what he typed, and the
                // install's record stays in its file. An install that ended well stays, so that the next opening
                // clears the form (`opened`), and so does another agent's hand-over (`forAgent`, `handsOver`) on Back:
                // taken away, it left that agent's setup with no hand-over of that server.
                case .install:
                    model.cancel()
                    if model.failure != nil, model.checklist == nil || model.forAgent == nil || model.forAgent == installFor {
                        model.again()
                    }
                case .token: cloud.cancel()
                case .vps: vps.reset()
                default: break
                }
                page = previous
            }.keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("add-machine-back")
        }
    }

    private var building: Bool {
        switch page {
        case .token: cloud.stage == .making || cloud.stage == .joining
        default: false
        }
    }

    /// The page before this one.
    private var previous: Page {
        switch page {
        case .install: .machine
        case .machine: model.way == .mac ? .opening : .ways
        case .opening: asksAI ? .ai : .ways
        case .key, .token, .vps: .machine
        default: .ways
        }
    }

    /// The hub keeps the owner's choice of AI, and the server is a Mac, whose sitting shows only what that AI needs. An
    /// agent's own server asks none: its provider is the next page of its setup. A VPS and a pasted line ask none: they
    /// join empty, and Add agent asks for the AI of the agent that it adds there.
    private var asksAI: Bool { placing == nil && Servers.choosesAI(store.state?.ui_features) && model.way == .mac && macAgent == nil }

    /// **The agent that Add agent's New server is for, with its AI on a plan**: the Mac that joins takes it as its first
    /// agent, so this wizard asks for no AI. nil for Add server that opened from elsewhere.
    private var macAgent: NewAgent? { fromAddAgent && newAgent?.ai != nil ? newAgent : nil }

    /// Add agent's New server for a provider after Other models: no Mac takes such an agent.
    private var noMac: Bool { placing == nil && fromAddAgent && newAgent != nil && newAgent?.ai == nil }

    // MARK: one: how this machine joins

    /// **Three cards of one line each, one under another** (the owner, 3 November 2026: "too much text, cards dont look
    /// good"): the mark and the way's name, as the AI provider's cards of an agent's setup have them
    /// (`AgentSetupWizard.card`). Each card's line, what that way does, is behind it on hover; everything else about it
    /// is on its own page. They were three tall cards side by side, each with a sentence that wrapped over four lines.
    /// **A VPS, and a Mac mini or Studio with the Apple logo** (the owner, 4 November 2026: "we need to support other vps
    /// providers, right?", and "for Mac mini/studio use an apple icon too").
    private var ways: some View {
        VStack(spacing: 10) {
            way(.linux, title: String(l10n: "VPS"), symbol: "server.rack",
                line: String(l10n: "Hetzner, DigitalOcean, Vultr, Akamai, or any VPS by its address."))
            if !noMac {
                way(.mac, title: String(l10n: "Mac mini or Studio"), symbol: "apple.logo",
                    line: String(l10n: "Its installer runs on that Mac and waits for one code."))
            }
            if placing == nil {
                // "Install by hand", with its line on hover: the owner's choice of 14 November 2026 for the card that was
                // "Paste a line" ("'paste a line' is confusing, does not make sense").
                way(.line, title: String(l10n: "Install by hand"), symbol: "terminal",
                    line: String(l10n: "For a server that this Mac cannot reach over SSH. You run one command on it yourself."))
            }
        }
    }

    /// One way, as a card: its mark and its name. Its line is on hover.
    private func way(_ way: MachineInstallModel.Way, title: String, symbol: String, line: String) -> some View {
        Button { choose(way) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(IconMetrics.symbol(18)).foregroundStyle(FleetStyle.text)
                    .frame(width: 28).accessibilityHidden(true)
                Text(title).font(SetupMetrics.choiceFont).foregroundStyle(FleetStyle.text)
                Spacer(minLength: 8)
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(FleetCardButtonStyle())
        .help(line)
        .accessibilityHint(line)
        .accessibilityIdentifier("add-machine-way-\(way.rawValue)")
    }

    private func choose(_ way: MachineInstallModel.Way) {
        model.way = way
        // The AI that he chose on Add agent, for a Mac that its New server adds: no AI page asks again.
        model.ai = way == .mac && Servers.choosesAI(store.state?.ui_features) ? macAgent?.ai : nil
        addAgentWaits = false
        page = asksAI ? .ai : way == .mac ? .opening : .machine
    }

    // MARK: two: which AI

    /// One card of one line for each AI of a Mac, as the ways' cards are: its real logo or logos and its name, with its
    /// line on hover. They were tall cards side by side with a sentence each, the look that the ways left on 3 November
    /// 2026.
    private var aiChoice: some View {
        VStack(spacing: 10) {
            ForEach(ServerAI.allCases, id: \.self) { ai in
                let line = ai.macLine
                Button { model.ai = ai; page = .opening } label: {
                    HStack(spacing: 12) {
                        HStack(spacing: 6) {
                            ForEach(ai.logos, id: \.self) { name in
                                ProviderLogo.image(name)?.resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                                    .frame(width: 28, height: 28).accessibilityHidden(true)
                            }
                        }
                        Text(ai.title).font(SetupMetrics.choiceFont).foregroundStyle(FleetStyle.text)
                        Spacer(minLength: 8)
                    }
                    .padding(18).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(FleetCardButtonStyle())
                .help(line)
                .accessibilityHint(line)
                .accessibilityIdentifier("add-machine-ai-\(ai.rawValue)")
            }
        }
    }

    /// The one line that Apple's setup needs before anything else: a Mac with FileVault on has no automatic login.
    private var opening: some View {
        VStack(spacing: SetupMetrics.gap) {
            Text("Get it at platform.founderizer.com/download.").font(SetupMetrics.textFont).foregroundStyle(FleetStyle.muted)
                .textSelection(.enabled)
            Text("In Apple's setup, say no to FileVault.").font(SetupMetrics.textFont).foregroundStyle(FleetStyle.muted)
            Button("Next") { page = .machine }.buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("add-machine-opened")
        }.frame(maxWidth: .infinity)
    }

    // MARK: two: the machine

    @ViewBuilder private var machine: some View {
        switch model.way {
        case .linux: providers
        case .mac: macMachine
        case .line: lineMachine
        }
    }

    // MARK: two: a VPS, by the first run's own pages

    /// **The first run's cards** (the owner, 4 November 2026: "we need to support other vps providers, right? so they can
    /// manually add servers, and it needs to work"; and his yes of 9 November 2026 to Vultr and Akamai): Hetzner,
    /// DigitalOcean, Vultr and Akamai make the server from one token, and any other VPS is its address ("maybe users will
    /// only have ssh access to that server.. with nothing else installed"). The old form of address, user, port and SSH
    /// key went with them: the address takes a name of `~/.ssh/config` with its user, port and key.
    private var providers: some View {
        CloudCards(id: "add-server", choose: choose) { vps.reset(); page = .vps }
    }

    /// A provider whose token this Mac holds makes the server at once; else its token page asks for it. A Mac that holds
    /// no Tailscale key of the fleet's own (a fleet from before the onboarding of 4 November 2026) is asked for it once
    /// first: the new server joins the private network with a key made from it, and with no press.
    private func choose(_ provider: CloudProvider) {
        if net.holdsKey { build(provider) } else { page = .key(provider) }
    }

    /// A provider whose token this Mac holds opens its choice at once: the account's servers and a new one, of which
    /// nothing is made before Make the server (the owner, 5 November 2026).
    private func build(_ provider: CloudProvider) {
        page = .token(provider)
        if cloud.holds(provider) { cloud.open(provider, use: .agent) }
    }

    /// **A server of the account, chosen in place of a new one**: the same check and the same Install press as Other
    /// VPS, at its public address.
    private func useExisting(_ server: CloudExisting) {
        var address = server.ipv4
        // Read before `cancel`, which forgets the provider.
        let provider = cloud.provider
        switch reuse(server) {
        // A free server of the fleet whose install this Mac saw end: the agent that waits takes it, with no install.
        case .place(let name):
            guard let placing else { return }
            cloud.cancel()
            placing.place(name)
            return
        // The server of an install that stopped. One that this Mac made for this hub lets only this Mac's own key in,
        // as root, on the private network: its install starts again as its build started it. Any other gets the check
        // first, at its address on the private network, for its user and its password.
        case .install(let onNetwork):
            if made.contains(server.name.lowercased()) {
                if let provider { reusedServer = (provider, server.id, onNetwork) }
                cloud.cancel()
                startInstall(InstallTarget(host: onNetwork, user: "root", port: 22, identityFile: AppSSHKey.path()))
                return
            }
            address = onNetwork
        // A row that the list's last read made unfit while it stood chosen is not a server to check.
        case nil:
            guard server.unfit(for: .join, fleet: Set(taken.map { $0.lowercased() })) == nil else { return }
        }
        guard let address else { return }
        reusedServer = provider.map { ($0, server.id, address) }
        cloud.cancel(); vps.reset()
        vps.addressText = address
        page = .vps
        Task {
            if vps.tailnet == nil { vps.tailnet = await MacNetwork.read().tailnet }
            vps.check(job: .join)
        }
    }

    /// What the fleet can do again with a server of the account's list (`CloudExisting.reuse`), from the hub's own list
    /// as this page read it: with no list yet, nothing.
    /// A hub from before `server_names` gives a server another name than its provider and its network do, so nothing
    /// there is known by its name.
    private func reuse(_ server: CloudExisting) -> CloudReuse? {
        guard !asksName else { return nil }
        return server.reuse(for: .join, servers: list?.servers, devices: devices, finished: finished, made: made,
                            placing: placing != nil)
    }

    /// **The fleet's servers whose install this Mac saw end**, by name in lower case: the address that the install
    /// reached is the address that the hub has for the server now (`InstallEnds`). A new server that took the name of a
    /// removed one has another address, and is not one of them.
    private var finished: Set<String> {
        Set((list?.servers ?? []).filter { $0.address != nil && ended[$0.name.lowercased()] == $0.address }
            .map { $0.name.lowercased() })
    }

    /// The servers of the account's list that this Mac made for this hub, by name in lower case (`MadeServers.holds`).
    private var made: Set<String> {
        // Never the fleet's own VPS, which a first run keeps in the same record since "Start again".
        let hubs = MadeServers.hubsOwn(hub: store.hub, builds: BuildRecords.shared.all())
        return Set(cloud.existing.filter { MadeServers.holds($0, in: madeKept) && !hubs.contains($0.id) }.map { $0.name.lowercased() })
    }

    /// **What a row may say of a server that Founderizer made and that the hub's list does not have by its name**
    /// (`CloudExisting.unfit`): only while the hub answers, from its own list, from a hub that names its servers as
    /// Tailscale does, and from this Mac's network as it was when the list opened (`FleetKnown`).
    private var known: FleetKnown? {
        guard !asksName, store.isFresh, let list else { return nil }
        return FleetKnown(servers: list.servers, hub: store.hub.host, devices: live)
    }

    /// The first server of the list that the fleet can take again, by its id at the provider: only in an agent's own
    /// setup, where a server is what the page is for. Add server makes no suggestion.
    private var firstToReuse: String? { placing == nil ? nil : cloud.existing.first { reuse($0) != nil }?.id }

    /// **The server that the first run made for this agent** (`FleetStore.madeServer`; slice 2 of the one wizard, where
    /// one press made every server of the fleet).
    private var firstServer: FleetStore.MadeServer? { placing.flatMap { store.madeServer($0.agent) } }

    /// **Its install starts by itself**, as "Use this server" starts the install of a server that this Mac made: as
    /// root, with this Mac's own key, at its address on the private network, with no VPS page and no second server.
    /// Only from the first page with nothing running, and once for each opening of these pages (`firstTried`). A
    /// server that is not on this Mac's network at that address now, or that the hub has already, leaves the pages as
    /// they were, and the provider's list offers it there (`MadeServers`, which the first run noted for this hub). The
    /// note goes only as the install starts, with no wait between the two: its change gives this task a new id, which
    /// ends the task that runs.
    private func installFirst(_ server: FleetStore.MadeServer) async {
        guard let placing, firstTried != server, page == .ways, !model.running, cloud.stage == .token else { return }
        firstTried = server
        let devices = FleetOnTailscale.devices(in: await MacNetwork.status() ?? "{}")
        guard devices.contains(where: {
            $0.name.lowercased() == server.name.lowercased() && $0.online && $0.address == server.address
        }) else { return }
        if let database = store.state?.db, let read = try? await HubClient().servers(hub: store.hub, database: database),
           read.servers.contains(where: { $0.name.lowercased() == server.name.lowercased() }) { return }
        guard !Task.isCancelled, page == .ways, !model.running, cloud.stage == .token else { return }
        store.noteMadeServer(nil, for: placing.agent)
        startInstall(InstallTarget(host: server.address, user: "root", port: 22, identityFile: AppSSHKey.path()))
    }

    /// This Mac's own network and what it kept of its installs, for `reuse`, and the hub's list where the page has
    /// none yet: its own read comes every 15 seconds.
    private func readFleet() async {
        ended = InstallEnds.ended(hub: store.hub)
        madeKept = MadeServers.kept(hub: store.hub)
        let status = await MacNetwork.status()
        devices = FleetOnTailscale.devices(in: status ?? "{}")
        live = FleetOnTailscale.live(in: status)
        if list == nil, store.isFresh, let database = store.state?.db {
            list = try? await HubClient().servers(hub: store.hub, database: database)
        }
    }

    /// **Make the server, once the hub has answered** (the owner's report of 14 November 2026: a new user's server was
    /// made and paid for, and its install could not start). The install needs a join line from the hub right after the
    /// build, so a hub that does not answer now leaves a server at the provider that nothing installs. The line over
    /// the press says why in the words of the window's own notice, and nothing is made.
    ///
    /// It is the page's own task (`makeAsked`): a page that closed while the hub was asked makes nothing. The server is
    /// made only when the list still shows what was pressed: the same provider, the same offer, and "New server".
    private func makeServer() async {
        guard !asksHub, chooses, store.state != nil, let provider = cloud.provider, let offer = cloud.offer,
              cloud.chosen == nil else { return }
        asksHub = true
        defer { asksHub = false }
        cloud.stop(nil)
        let hadList = list != nil, listing = cloud.listing
        // A hub that took the owner's own write since this page's state has a new generation: one more read of the
        // state, then the same question.
        for attempt in 0..<2 {
            guard let database = store.state?.db else { return }
            do {
                list = try await HubClient().servers(hub: store.hub, database: database)
                break
            } catch let error as HubError where error.conflict && attempt == 0 {
                await store.refresh()
            } catch {
                if !Task.isCancelled { cloud.stop(HubReach.words(error, hub: store.hub).says) }
                return
            }
        }
        guard !Task.isCancelled, chooses, cloud.listing == listing, cloud.provider == provider, cloud.offer == offer,
              cloud.chosen == nil else { return }
        // The hub's list came only now, and it shows a server that the fleet can take again: that row is chosen, and
        // the press is his again.
        if !hadList, let firstToReuse {
            cloud.chosen = firstToReuse; suggested = true
            return
        }
        let fleet = store.hub
        cloud.makeNew(for: fleet, made: { name, id in MadeServers.note(name, id: id, hub: fleet) }, then: installs())
    }

    /// What the build does once the new server is on the private network: its install, as the check's Install starts
    /// it. The build takes minutes, so a fleet that this Mac went to meanwhile is sent no server of this one.
    private func installs() -> (InstallTarget) -> Void {
        let fleet = store.hub
        return { target in if store.hub == fleet { startInstall(target) } }
    }

    /// The install of a server that the check proved or that a provider made: its address, user, port and key, and the
    /// password of its `sudo` when that asks for one.
    private func startInstall(_ target: InstallTarget, sudo: PasswordOnce.Password? = nil) {
        // A hub from before `server_names` takes the server's name, which no page asks for now: the one it suggests.
        if asksName, nameProblem != nil { model.name = Servers.suggestedName(taken: taken) }
        model.use(target, sudo: sudo)
        // The server of the list that "Use this server" took, when the install goes to its address.
        model.provenServer = reusedServer.flatMap { $0.address == target.host ? ($0.provider, $0.id) : nil }
        let ran = model.running
        model.installMachine(store: store)
        // The install page is the install: a start that the model refused (no hub to ask for a line) stays here. Only
        // a start that this press began names its agent (`forAgent`).
        if model.running, !ran { model.forAgent = installFor }
        if model.running { page = .install }
    }

    /// **The fleet's own Tailscale key, once**, the first run's page: Tailscale's Keys page makes an access token, and
    /// the app makes the lasting key from it and forgets the token.
    @ViewBuilder private func key(_ provider: CloudProvider) -> some View {
        if !net.busy {
            // What he does at Tailscale comes before the paste, so its steps stand over the field.
            SetupSteps.tailscaleKey
            PasteField(placeholder: String(l10n: "Paste it here"), text: $net.keyText, accepts: { $0.hasPrefix("tskey-api-") }) {
                // On to the provider only from this page: Back while the key was made leaves no server to make.
                Task { if await net.sendKey(), page == .key(provider) { build(provider) } }
            }
            .accessibilityIdentifier("add-server-tailscale-key")
        }
        if let lines = net.linesToAdd, let asks = net.asks {
            PolicyLines(says: asks, lines: lines, copied: net.copied) { net.copyLines() }
        }
        if let failure = net.failure { SetupWarning(failure) }
    }

    /// **The provider's token, once**, the first run's page: pasted, it goes by itself, and this Mac's keychain keeps it
    /// for the next server. While the server is made and joins the private network, the install's first two steps.
    @ViewBuilder private func token(_ provider: CloudProvider) -> some View {
        @Bindable var cloud = self.cloud
        if building {
            CloudBuilding(stage: cloud.stage, job: .join, provider: cloud.provider)
        } else if cloud.stage == .choosing {
            // Read here, in the page's own body, so that each row follows the page's readings.
            let again = Dictionary(cloud.existing.map { ($0.id, reuse($0)) }) { first, _ in first }
            CloudChoice(cloud: cloud, job: .join, fleet: Set(taken.map { $0.lowercased() }), known: known,
                        reuse: { again[$0.id] ?? nil },
                        makeNew: { if !asksHub { makeAsked += 1 } }, use: useExisting)
        } else if !cloud.tokenTaken {
            // A token that the provider took is never asked for again on this page (`FleetCloudModel.tokenTaken`).
            SetupSteps.token(provider)
            PasteField(placeholder: String(l10n: "Paste it here"), text: $cloud.tokenText,
                       accepts: { $0.count >= 20 && !$0.contains(" ") }) {
                cloud.sendToken(provider, use: .agent)
            }
            .accessibilityIdentifier("add-server-cloud-token")
        }
        // While the list shows, its own press carries the line (`CloudChoice`).
        if let failure = cloud.failure, cloud.stage != .choosing || cloud.offer == nil { SetupWarning(failure) }
    }

    /// **Any VPS, by its address**, the first run's pages: one field, the check, the password once when the VPS asks for
    /// one, then one Install press with the line of what changes, or one orange line of why not and Try again.
    @ViewBuilder private var vpsPages: some View {
        switch vps.phase {
        case .address:
            SetupField(placeholder: String(l10n: "Address"), text: $vps.addressText) { vps.check(job: .join) }
                .accessibilityIdentifier("add-server-vps-address")
                // This Mac's own network, for the stop of a server that is on another one.
                .task { if vps.tailnet == nil { vps.tailnet = await MacNetwork.read().tailnet } }
        case .checking:
            EmptyView()
        case .waiting(let why):
            Text(why).foregroundStyle(FleetStyle.muted).fixedSize(horizontal: false, vertical: true)
        case .password:
            SetupSecureField(placeholder: String(l10n: "Password"), text: $vps.passwordText) { vps.givePassword(job: .join) }
                .accessibilityIdentifier("add-server-vps-password")
            Text("Used once, to add this Mac's key. Never kept.").foregroundStyle(FleetStyle.muted)
        case .ready(let summary, let changes):
            Label { Text(summary) } icon: { Image(systemName: "checkmark").foregroundStyle(.green) }
                .foregroundStyle(FleetStyle.text)
            Button("Install") { if let target = vps.target { startInstall(target, sudo: vps.sudoPassword) } }
                .buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("add-server-vps-install")
            Text(changes).foregroundStyle(FleetStyle.muted).fixedSize(horizontal: false, vertical: true)
        case .stopped(let why):
            SetupWarning(why).accessibilityIdentifier("add-server-vps-stop")
            Button("Try again") { vps.again(job: .join) }
                .buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
        }
    }

    // MARK: two: a Mac, or the pasted line

    /// A Mac that stays on: what its own installer shows, typed here once.
    private var macMachine: some View {
        @Bindable var model = self.model
        return VStack(alignment: .leading, spacing: FleetSpace.block) {
            // No footer of 69 words (D-2): the installer on that Mac shows the address and the code its two rows ask for.
            FormSection {
                if asksName {
                    FormRow("Name", symbol: "character.cursor.ibeam", warning: model.name.isEmpty ? nil : nameProblem) {
                        field($model.name, placeholder: String(l10n: "Server name"), width: 220, identifier: "link-name")
                    }
                }
                FormRow("Address", symbol: "network", detail: String(l10n: "As the installer shows it, for example 192.168.1.42.")) {
                    field($model.macHost, placeholder: "192.168.1.42", width: 220, identifier: "link-host")
                }
                FormRow("Link code", symbol: "number",
                        warning: model.linkCode.isEmpty || ClaimCode.read(model.linkCode) != nil ? nil
                        : String(l10n: "A link code is twelve characters, in three groups of four.")) {
                    field($model.linkCode, placeholder: "ABCD-EFGH-JKLM", width: 180, identifier: "link-code")
                }
            }
            onwards(String(l10n: "Link this Mac"), identifier: "link-start", warning: model.failure,
                    disabled: model.running || nameProblem != nil
                    || MacInstallerClient.address(model.macHost) == nil || ClaimCode.read(model.linkCode) == nil) {
                let ran = model.running
                model.linkMac(store: store, withAgent: placing == nil, named: macAgent?.name)
                if model.running, !ran { model.forAgent = installFor }
                if model.running { page = .install }
            }
        }
    }

    /// The line the owner pastes himself: what that machine runs, which the line differs by, and on a hub from before
    /// `server_names` its name.
    private var lineMachine: some View {
        @Bindable var model = self.model
        return VStack(alignment: .leading, spacing: FleetSpace.block) {
            FormSection(footer: kind == "linux"
                        ? String(l10n: "Ubuntu 22.04, 24.04 or 26.04, or Debian 12 or 13, with root access. Founderizer sets up its user, security updates, private network and firewall.")
                        : String(l10n: "macOS 14 or later, with Tailscale signed in and Homebrew installed. The agents run as the Mac user that pastes the line.")) {
                if asksName {
                    FormRow("Name", symbol: "character.cursor.ibeam", warning: model.name.isEmpty ? nil : nameProblem) {
                        field($model.name, placeholder: String(l10n: "Server name"), width: 220, identifier: "add-server-name",
                              submit: { Task { await make() } })
                    }
                }
                FormRow("Kind", symbol: kind == "mac" ? "desktopcomputer" : "server.rack") {
                    FleetSelect("Kind", selection: $kind, options: [
                        FleetOption("linux", "A Linux server", mark: .symbol("server.rack")),
                        FleetOption("mac", "A Mac", mark: .symbol("desktopcomputer")),
                    ]).accessibilityIdentifier("add-server-kind")
                }
            }
            onwards(String(l10n: "Make the line"), identifier: "add-server-make", warning: error,
                    disabled: busy || list == nil || !store.writesNow || nameProblem != nil) {
                Task { await make() }
            }
        }
    }

    // MARK: three: the install

    @ViewBuilder private var install: some View {
        switch model.way {
        case .linux:
            MachineInstallRun(model: model, title: installed ?? String(l10n: "The server"), next: AnyView(joined),
                              again: { model.installMachine(store: store) }, report: { store.reportAsk = $0 },
                              hub: store.hub)
        case .mac:
            // Try again links the same Mac again (fix round 3, item 51): it emptied the page.
            MachineInstallRun(model: model, title: installed ?? String(l10n: "The server"), next: AnyView(joined),
                              again: { model.linkMac(store: store, withAgent: placing == nil, named: model.firstAgent) },
                              report: { store.reportAsk = $0 }, hub: store.hub)
        case .line:
            if let code, let line = code.line { joinLine(code, line) }
        }
    }

    /// **A VPS that Add agent's New server made goes on to Add agent by itself**: he asked for an agent on a new server,
    /// with its name and its AI, so the page of that server's two ways on would only ask for the press he already made.
    /// Only a server whose checks passed: one with a failed check keeps its page, which shows that check, and its two
    /// buttons.
    private var goesOn: Bool {
        model.way == .linux && placing == nil && fromAddAgent && !addAgentWaits && !model.running
            && model.checklist.map { $0.isReady || $0.onlyNeedsSignIn } == true && model.forAgent == installFor
    }

    /// Add agent for the new server, as soon as the hub offers that server: its first reading comes some seconds after
    /// its join. A count ends the wait, and the page with Add agent is the way on then. Add agent adds the agent there
    /// with the name and the AI that he chose before New server (`AddAgentModel.goOn`).
    private func goOn() async {
        guard let server = installed, let database = store.state?.db else { addAgentWaits = true; return }
        for _ in 0..<20 where !Task.isCancelled {
            if let read = try? await HubClient().servers(hub: store.hub, database: database),
               read.servers.first(where: { $0.name == server })?.available == true {
                // Add server that he closed meanwhile does not open Add agent over the page he went to.
                guard !Task.isCancelled, store.destination == .addServer else { return }
                await goOnToAddAgent(server, true)
                // Add agent opened, and this page went with it. Where the page still stands, its two buttons are
                // the way on.
                if !Task.isCancelled { addAgentWaits = true }
                return
            }
            try? await Task.sleep(for: .seconds(3))
        }
        if !Task.isCancelled { addAgentWaits = true }
    }

    /// Add agent pressed on this wizard, for a server that just joined: by its name, Add agent for that server, which
    /// adds the agent there where Add agent's New server opened this wizard; with no name yet, Add agent's first step.
    private func openAddAgent(on server: String?) {
        if let server { addAgentFor = server } else { addAgent(nil) }
    }

    /// **The server that joined goes on to the agent's setup by itself**, as soon as the hub offers it: its first
    /// reading comes some seconds after its join. A count ends the wait, and the provider page then says in the hub's
    /// words why the server cannot take the agent. With no name for the server, the first page shows again.
    private func handOver(_ placing: Placing) async {
        // Read once for this hand-over: a later install of this page's has its own end (`opened`).
        let reopened = handsOverAgain
        handsOverAgain = false
        guard let server = installed, let database = store.state?.db else {
            model.again(); page = .ways
            return
        }
        var free = false
        for _ in 0..<40 where !Task.isCancelled {
            if let read = try? await HubClient().servers(hub: store.hub, database: database) {
                let row = read.servers.first { $0.name == server }
                if let row, AgentSetupFlow.isFree(row) { free = true; break }
                // **An install that ended before this page opened** (`opened`): a server that another agent has now, or
                // that is the hub, gives no hand-over, and the page offers its ways at once. One that is not available
                // yet (its first reading comes seconds after its join) or not listed is waited for, as at its own end.
                if reopened, let row, !row.agents.isEmpty || row.hub { return leaveHandOver() }
            }
            try? await Task.sleep(for: .seconds(3))
        }
        guard !Task.isCancelled else { return }
        // That install's server that never came free leaves the ways page, with Back, and no moving title for good.
        if reopened, !free { return leaveHandOver() }
        placing.place(server)
        // Given, or the hub says why not: this install hands over no more, here or on a later opening (`opened`).
        model.forAgent = nil
    }

    /// An install that ended before this page opened, and that this agent can no longer take: cleared, and the page's
    /// ways show.
    private func leaveHandOver() {
        model.again()
        page = .ways
    }

    /// What is left after a machine reached its checklist: its agent, which only the owner adds.
    @ViewBuilder private var joined: some View {
        if handsOver {
            // It goes on to the agent's setup by itself (`handOver`, from the page's own task).
            Color.clear.frame(height: 0)
        // A Mac that the hub sets up has its first agent already, and the installer on it leads the rest. **An install
        // that is not this page's** (`MachineInstallModel.forAgent`; the review of 17 November 2026) is in the fleet and
        // is another agent's, or no agent's: its end here offers no Add agent, which put a new agent on the manager's
        // own server.
        } else if model.forAgent != installFor || (model.way == .mac && model.firstAgent != nil) {
            FormSection {
                FormRow("\(installed ?? String(l10n: "The server")) is in your fleet", symbol: "checkmark.circle") { openServer }
            }
        } else if goesOn {
            // It goes on to Add agent by itself (`goOn`, from the page's own task).
            Color.clear.frame(height: 0)
        } else {
            // The title says that it is installed. It has no agent, and none is added by itself.
            ServerInstalled(addAgent: { openAddAgent(on: installed) },
                            openServer: { store.destination = installed.map { .server($0) } ?? .settings(.servers) })
        }
    }

    private var openServer: some View {
        Button("Open server") { store.destination = installed.map { .server($0) } ?? .settings(.servers) }
            .buttonStyle(FleetOutlineButtonStyle())
    }

    /// The pasted line's own waiting page: the line, and what the hub has seen of it. It takes the place of the
    /// install's steps, because this install runs where the owner pasted it.
    @ViewBuilder private func joinLine(_ code: JoinCode, _ line: String) -> some View {
        let state = join?.state ?? "open"
        let expired = state == "expired" || code.expires_at <= time
        FormSection(code.kind == "linux" ? "Paste this line in a root shell on the VPS" :
                        "Paste this line in Terminal on the Mac, as the user that will run the agents",
                    footer: String(l10n: "The line works once, for 30 minutes. It makes \(lineName ?? String(l10n: "the server")) join your private network and Founderizer. A new line cancels this one.")) {
            FormBlock("Join line", detail: code.kind == "linux" ? String(l10n: "It installs Tailscale when the VPS has none: open the sign-in link that it shows.") : nil) {
                Text(line).font(FormMetrics.code).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(FleetStyle.canvas, in: RoundedRectangle(cornerRadius: FormMetrics.inner))
                    .overlay(RoundedRectangle(cornerRadius: FormMetrics.inner).strokeBorder(FleetStyle.line, lineWidth: 0.5))
                    .accessibilityIdentifier("add-server-line")
                    // How long it works, on hover: the title's moving words say that it waits.
                    .help(state == "open" && !expired
                          ? "Valid until \(Date(timeIntervalSince1970: code.expires_at).formatted(date: .omitted, time: .shortened))." : "")
            } accessory: {
                // Only while the line works: an expired or used line has New line under it, never a grey Copy.
                if !expired && state == "open" {
                    Button(copied ? "Copied" : "Copy") { copyMessage(line); copied = true }.buttonStyle(FleetOutlineButtonStyle())
                        .accessibilityIdentifier("add-server-copy")
                }
            }
            // While it waits, the title says so: the row is for what the line came to.
            if state != "open" || expired {
            FormRow(status(state: state, expired: expired), symbol: state == "joined" ? "checkmark.circle" : expired || state == "canceled" ?
                    "exclamationmark.circle" : "hourglass") {
                if state == "joined" {
                    HStack(spacing: FleetSpace.actions) {
                        Button("Open server") { store.destination = lineName.map { .server($0) } ?? .settings(.servers) }
                            .buttonStyle(FleetOutlineButtonStyle())
                        Button("Add agent") { openAddAgent(on: lineName) }.buttonStyle(FleetPrimaryButtonStyle()).accessibilityIdentifier("add-server-agent")
                    }
                } else if expired || state == "canceled" {
                    Button("New line") { self.code = nil; copied = false; page = .machine }.buttonStyle(FleetOutlineButtonStyle())
                }
            }
            }
        }
    }

    private func status(state: String, expired: Bool) -> String {
        if state == "joined" { return String(l10n: "\(lineName ?? String(l10n: "The server")) joined Founderizer.") }
        if state == "canceled" { return String(l10n: "A newer line replaced this line.") }
        if expired { return String(l10n: "This line expired. Make a new line.") }
        return String(l10n: "Waiting for \(lineName ?? String(l10n: "the server")) to join…")
    }

    // MARK: the pieces every page is built of

    /// The one field of this wizard, in the app's one field look (`FleetFieldLook`), as the first run's.
    private func field(_ text: Binding<String>, placeholder: String, width: CGFloat, identifier: String,
                       submit: (() -> Void)? = nil) -> some View {
        TextField(text: text, prompt: Text(verbatim: "")) { Text(placeholder) }
            .fieldPlaceholder(placeholder, shows: text.wrappedValue.isEmpty)
            .font(SetupMetrics.textFont)
            .fleetField()
            .frame(width: width)
            .accessibilityIdentifier(identifier)
            .onSubmit { submit?() }
    }

    /// The one way on from a page: what holds it back, in the owner's own words, and the button — only while it can
    /// be pressed, never grey (the owner: "dont show the send button if it's not clickable").
    @ViewBuilder private func onwards(_ title: String, identifier: String, warning: String?, disabled: Bool,
                                      go: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: FleetSpace.inside) {
            if let warning {
                Text(warning).font(SetupMetrics.textFont).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // In the middle, under the form, as every setup step's action; while the hub makes the line, the title's
            // words move and no spinner stands beside it.
            if !disabled {
                Button(title, action: go).buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(identifier)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// What the wizard opens on. An install that goes on is this screen's subject again, wherever the owner was
    /// when he left it, and so is a VPS that its provider makes. A machine installed before leaves its name and its
    /// address in the shared model, and the next machine is a new one, so that run is cleared instead of being offered
    /// as a form half filled in; a build that stopped is cleared the same way.
    private func opened() {
        fromAddAgent = placing == nil && store.history.back.last == .addAgent
        if cloud.onState == nil { cloud.onState = SetupChannel.reports(to: store, \.addServerBuild) }
        if model.running { page = .install; return }
        if cloud.stage != .token, let provider = cloud.provider { page = .token(provider); return }
        cloud.cancel()
        guard model.checklist != nil || model.failure != nil else { return }
        // **This agent's own install that ended while another page showed it** goes on to its hand-over here
        // (`handOver`): cleared, it left the manager with no server, and its setup's press made a second one.
        if handsOver { handsOverAgain = true; page = .install; return }
        model.again()
        model.name = ""; model.host = ""; model.macHost = ""; model.linkCode = ""
        model.user = "root"; model.port = "22"; model.identityFile = nil
    }

    private func make() async {
        guard !busy, let database = store.state?.db, nameProblem == nil else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let answer = try await HubClient().joinCode(hub: store.hub, database: database, client: store.installation,
                                                        name: asksName ? model.name : nil, kind: kind)
            guard answer.line != nil else { error = String(l10n: "The hub gave no line. Make a new line."); return }
            code = answer; copied = false
            page = .install
            list = try? await HubClient().servers(hub: store.hub, database: database)
        } catch let HubError.refusal(refused) { error = refused.words }
        catch { self.error = String(l10n: "The hub has not answered. Try again.") }
    }

    /// Reads the servers: once for the free names, then every 3 seconds while a line waits for its server. A hub with
    /// `server_names` asks for no name, and the suggested one is then only what a Mac's installer is sent.
    private func poll() async {
        while !Task.isCancelled {
            if let database = store.state?.db, store.isFresh {
                if let read = try? await HubClient().servers(hub: store.hub, database: database) {
                    guard !Task.isCancelled else { return }
                    list = read
                    // Add server for that machine on this Mac: the server that joined with this page's own line loses a
                    // removal mark of its name (package 4 of the vault's gates).
                    if let joined = code?.state(in: read), joined.state == "joined", let server = joined.server {
                        store.vaultModel().added(server)
                    }
                    if model.name.isEmpty, code == nil, !model.running {
                        model.name = Servers.suggestedName(taken: read.servers.map(\.name))
                    }
                }
            }
            do { try await store.nap(code == nil ? 15 : 3) } catch { return }
        }
    }
}

/// **A VPS that is installed: its two ways on, and nothing else** (the owner's rule for a setup step: only the next
/// action). The step's title says that the server is installed. It has no agent yet: Add agent opens Add agent for
/// this server, which asks for the new agent's name and its AI, and Open server opens the server's own page. An agent
/// that he has moves there with no question of this wizard's, and keeps its own AI.
struct ServerInstalled: View {
    let addAgent: () -> Void
    let openServer: () -> Void

    var body: some View {
        HStack(spacing: FleetSpace.actions) {
            Button("Open server", action: openServer).buttonStyle(FleetOutlineButtonStyle())
                .accessibilityIdentifier("install-open-server")
            Button("Add agent", action: addAgent).buttonStyle(FleetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("install-add-agent")
        }
        .frame(maxWidth: .infinity)
    }
}
