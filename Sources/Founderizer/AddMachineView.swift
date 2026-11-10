import AppKit
import FleetCore
import FleetMark
import SwiftUI

/// Add a machine, as the wizard of the first run is: **one decision on a page**, and the page after it asks only
/// what that decision needs (PRODUCT.md 2 and P3).
///
///   1. **How it joins**, as three cards and nothing else: a VPS, which this Mac installs over its own SSH connection;
///      a Mac mini or Studio that stays on, whose own installer waits there for a link code; or one line the owner
///      pastes on the machine himself.
///   2. **Which AI runs there**, the owner's one choice, as cards with the providers' logos, for a Linux server and a Mac
///      alike: its first agent runs on it, and a Mac's sitting shows only what it needs.
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
    /// Add agent pressed for the owner, on a new Linux server: false when its page is the way on after all.
    let addFirstAgent: (String, String) async -> Bool
    /// The agent whose first server this is, or nil for Add server.
    var placing: Placing?

    /// An agent with no server: its name, and where the server that joined for it goes.
    struct Placing {
        let agent: String
        let place: (String) -> Void
    }

    /// Where the wizard stands. The install itself lives in the store, so this screen can be left and opened again
    /// while a ten-minute install goes on: `opened()` puts the wizard back on it. A VPS's `machine` is the first run's
    /// three cards, and `key`, `token` and `vps` are the first run's pages after them.
    private enum Page: Equatable { case ways, ai, opening, machine, install, key(CloudProvider), token(CloudProvider), vps }

    @State private var page = Page.ways
    /// The pasted line only: what that machine runs, which its line differs by.
    @State private var kind = "linux"
    /// Any VPS by its address, and the fleet's own Tailscale key, as the first run has them.
    @State private var vps = FleetVPSModel()
    @State private var net = FleetNetworkModel()
    /// **The VPS that a provider makes goes on while other pages show**, as the install does: it is the install's first
    /// minutes, a second press waits for it, and `opened()` puts the wizard back on it.
    @MainActor private static let cloudModel = FleetCloudModel()
    private var cloud: FleetCloudModel { Self.cloudModel }
    @State private var code: JoinCode?
    @State private var list: ServerList?
    @State private var busy = false
    @State private var error: String?
    @State private var copied = false
    /// The hub did not offer the new server for its first agent, so the row with Add agent stands.
    @State private var firstAgentWaits = false
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

    /// **Each page is a setup step, as the first run's are** (`SetupPage`, `SetupStep`): the product's muted mark at
    /// the size of every step's mark, the title under it, what the page asks under that, and Back at the page's top left.
    /// The mark and the title stand where every setup step has them, and a wait is the title's moving words.
    var body: some View {
        SetupPage { back } step: {
            SetupStep(title: title, waits: waits, width: page == .machine && model.way == .linux ? SetupMetrics.cardsWidth
                        : SetupMetrics.width) { mark } content: {
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
        .task(id: "\(store.hub)/\(store.state?.db ?? "")") { await poll() }
        // The install of a VPS that its provider made starts by itself once the server joined: also on this page opened
        // again during the build, which was not the page that pressed.
        .onChange(of: model.running) { _, running in if running { page = .install } }
    }

    @ViewBuilder private var asked: some View {
        switch page {
        case .ways: ways
        case .ai: aiChoice
        case .opening: opening
        case .machine: machine
        case .install: install
        case .key(let provider): key(provider)
        case .token(let provider): token(provider)
        case .vps: vpsPages
        }
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
        case .machine: return busy
        case .key: return net.busy
        case .token: return building || (cloud.stage == .choosing && cloud.offer == nil)
        case .vps:
            switch vps.phase {
            case .checking, .waiting: return true
            default: return false
            }
        case .install: return model.way != .line ? model.running || addsFirstAgent || handsOver : lineWaits
        }
    }

    /// The server is in, and goes to the agent's setup once the hub offers it (`handOver`).
    private var handsOver: Bool { placing != nil && model.checklist != nil }

    /// The pasted line waits for its server: it is open and has not expired.
    private var lineWaits: Bool {
        guard let code else { return false }
        return (join?.state ?? "open") == "open" && code.expires_at > time
    }

    /// The name of the page the owner is on. Each one says what it asks, so no page needs a line to explain itself.
    private var title: String {
        switch page {
        case .ways: placing.map { "\($0.agent.agentLabel)'s server" } ?? "Add server"
        case .ai: model.way == .mac ? "Which AI runs on this Mac?" : "Which AI runs on this server?"
        case .opening: "Open the installer on that Mac"
        case .machine:
            switch model.way {
            // The first run's "A VPS for your fleet": the fleet has its own, and the agents run on the servers he adds.
            case .linux: "A VPS for your agents"
            case .mac: "The Mac that stays on"
            case .line: "The server you paste it on"
            }
        case .key: net.busy ? "Connecting your network" : "Your Tailscale key"
        // The build is the install's first steps, under the install's own title, so the words stay when it goes on. The
        // hub names the server at its join, after the build.
        case .token(let provider):
            building ? "Installing the server"
                : cloud.stage == .choosing ? placing.map { "\($0.agent.agentLabel)'s server at \(provider.name)" }
                    ?? "A server at \(provider.name)"
                : "Your \(provider.name) token"
        case .vps:
            switch vps.phase {
            case .address: "Your VPS"
            case .checking: "Checking \(vps.host)"
            case .waiting: "Waiting for \(vps.host)"
            case .password: "Password for \(vps.target?.user ?? "root")@\(vps.host)"
            case .ready, .stopped: vps.host
            }
        case .install:
            switch model.way {
            // A stop has a true title (fix round 3, item 51): "Installing server-2" stood over it.
            // And so has an end: "Installing worker-5" stood over "worker-5 is in your fleet".
            case .linux: model.failure != nil && !model.running ? "\(installed ?? "The server") did not install"
                : model.checklist != nil && !model.running ? "\(installed ?? "The server") is installed"
                : "Installing \(installed ?? "the server")"
            case .mac: model.failure != nil && !model.running ? "\(installed ?? "The server") did not link"
                : model.checklist != nil && !model.running ? "\(installed ?? "The server") is linked"
                : "Linking \(installed ?? "the server")"
            // **The wait is the moving title** (T-36, fix round 2): "Waiting for server-2", where a row said "Waiting
            // for server-2 to join…" under a still "Your join line".
            case .line: lineWaits ? "Waiting for \(lineName ?? "the server")" : "Your join line"
            }
        }
    }

    /// One step back, as the first run's wizard has it, and out of the wizard from its first page: at the page's top
    /// left, where every setup page has it, and Esc too. An install that runs has no way back: it is the page, and
    /// it keeps going whether this screen shows or not. So has a VPS that its provider makes, which is the install's
    /// first steps: a Back there would leave the server at the provider and not in the fleet.
    @ViewBuilder private var back: some View {
        if page == .ways {
            // An agent's setup starts here, so its first page has nothing to go back to.
            if placing == nil {
                SetupBack { store.destination = .settings(.servers) }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("add-server-back")
            }
        } else if !model.running && !building && !handsOver {
            SetupBack {
                switch page {
                case .install: model.cancel()       // a Mac's stopped order: this page reads it no more
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
        case .machine: model.way == .mac ? .opening : asksAI ? .ai : .ways
        case .opening: asksAI ? .ai : .ways
        case .key, .token, .vps: .machine
        default: .ways
        }
    }

    /// The hub keeps the owner's choice of AI, and this way is one that has a first agent. An agent's own server asks
    /// none: its provider is the next page of its setup.
    private var asksAI: Bool { placing == nil && Servers.choosesAI(store.state?.ui_features) && model.way != .line }

    // MARK: one: how this machine joins

    /// **Three cards of one line each, one under another** (the owner, 3 November 2026: "too much text, cards dont look
    /// good"): the mark and the way's name, as the AI provider's cards of an agent's setup have them
    /// (`AgentSetupWizard.card`). Each card's line, what that way does, is behind it on hover; everything else about it
    /// is on its own page. They were three tall cards side by side, each with a sentence that wrapped over four lines.
    /// **A VPS, and a Mac mini or Studio with the Apple logo** (the owner, 4 November 2026: "we need to support other vps
    /// providers, right?", and "for Mac mini/studio use an apple icon too").
    private var ways: some View {
        VStack(spacing: 10) {
            way(.linux, title: "VPS", symbol: "server.rack",
                line: "Hetzner, DigitalOcean, Vultr, Akamai, or any VPS by its address.")
            way(.mac, title: "Mac mini or Studio", symbol: "apple.logo",
                line: "Its installer runs on that Mac and waits for one code.")
            if placing == nil {
                way(.line, title: "Paste a line", symbol: "terminal", line: "One line that you paste in that server's own shell.")
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
        model.ai = nil
        firstAgentWaits = false
        page = asksAI ? .ai : way == .mac ? .opening : .machine
    }

    // MARK: two: which AI

    /// One card of one line for each AI, as the ways' cards are: its real logo or logos and its name, with its line on
    /// hover. They were tall cards side by side with a sentence each, the look that the ways left on 3 November 2026.
    private var aiChoice: some View {
        VStack(spacing: 10) {
            ForEach(model.way == .mac ? ServerAI.allCases : ServerAI.linuxChoices, id: \.self) { ai in
                let line = model.way == .mac ? ai.macLine : ai.linuxLine
                Button { model.ai = ai; page = model.way == .mac ? .opening : .machine } label: {
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
            Text("Get it at founderizer.com/download.").font(SetupMetrics.textFont).foregroundStyle(FleetStyle.muted)
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
        guard let address = server.ipv4 else { return }
        cloud.cancel(); vps.reset()
        vps.addressText = address
        page = .vps
        Task {
            if vps.tailnet == nil { vps.tailnet = await MacNetwork.read().tailnet }
            vps.check(job: .join)
        }
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
        model.installMachine(store: store)
        // The install page is the install: a start that the model refused (no hub to ask for a line) stays here.
        if model.running { page = .install }
    }

    /// **The fleet's own Tailscale key, once**, the first run's page: Tailscale's Keys page makes an access token, and
    /// the app makes the lasting key from it and forgets the token.
    @ViewBuilder private func key(_ provider: CloudProvider) -> some View {
        if !net.busy {
            // What he does at Tailscale comes before the paste, so its steps stand over the field.
            SetupSteps.tailscaleKey
            PasteField(placeholder: "Paste it here", text: $net.keyText, accepts: { $0.hasPrefix("tskey-api-") }) {
                // On to the provider only from this page: Back while the key was made leaves no server to make.
                Task { if await net.sendKey(), page == .key(provider) { build(provider) } }
            }
            .accessibilityIdentifier("add-server-tailscale-key")
        }
        if let lines = net.linesToAdd { PolicyLines(lines: lines, copied: net.copied) { net.copyLines() } }
        if let failure = net.failure { SetupWarning(failure) }
    }

    /// **The provider's token, once**, the first run's page: pasted, it goes by itself, and this Mac's keychain keeps it
    /// for the next server. While the server is made and joins the private network, the install's first two steps.
    @ViewBuilder private func token(_ provider: CloudProvider) -> some View {
        @Bindable var cloud = self.cloud
        if building {
            CloudBuilding(stage: cloud.stage, job: .join, provider: cloud.provider)
        } else if cloud.stage == .choosing {
            CloudChoice(cloud: cloud, job: .join, fleet: Set(taken.map { $0.lowercased() }),
                        makeNew: { cloud.makeNew(then: installs()) }, use: useExisting)
        } else {
            SetupSteps.token(provider)
            PasteField(placeholder: "Paste it here", text: $cloud.tokenText,
                       accepts: { $0.count >= 20 && !$0.contains(" ") }) {
                cloud.sendToken(provider, use: .agent)
            }
            .accessibilityIdentifier("add-server-cloud-token")
        }
        if let failure = cloud.failure { SetupWarning(failure) }
    }

    /// **Any VPS, by its address**, the first run's pages: one field, the check, the password once when the VPS asks for
    /// one, then one Install press with the line of what changes, or one orange line of why not and Try again.
    @ViewBuilder private var vpsPages: some View {
        switch vps.phase {
        case .address:
            SetupField(placeholder: "Address", text: $vps.addressText) { vps.check(job: .join) }
                .accessibilityIdentifier("add-server-vps-address")
                // This Mac's own network, for the stop of a server that is on another one.
                .task { if vps.tailnet == nil { vps.tailnet = await MacNetwork.read().tailnet } }
        case .checking:
            EmptyView()
        case .waiting(let why):
            Text(why).foregroundStyle(FleetStyle.muted).fixedSize(horizontal: false, vertical: true)
        case .password:
            SetupSecureField(placeholder: "Password", text: $vps.passwordText) { vps.givePassword(job: .join) }
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
                        field($model.name, placeholder: "Server name", width: 220, identifier: "link-name")
                    }
                }
                FormRow("Address", symbol: "network", detail: "As the installer shows it, for example 192.168.1.42.") {
                    field($model.macHost, placeholder: "192.168.1.42", width: 220, identifier: "link-host")
                }
                FormRow("Link code", symbol: "number",
                        warning: model.linkCode.isEmpty || ClaimCode.read(model.linkCode) != nil ? nil
                        : "A link code is twelve characters, in three groups of four.") {
                    field($model.linkCode, placeholder: "ABCD-EFGH-JKLM", width: 180, identifier: "link-code")
                }
            }
            onwards("Link this Mac", identifier: "link-start", warning: model.failure,
                    disabled: model.running || nameProblem != nil
                    || MacInstallerClient.address(model.macHost) == nil || ClaimCode.read(model.linkCode) == nil) {
                model.linkMac(store: store, withAgent: placing == nil)
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
                        ? "Ubuntu 22.04, 24.04 or 26.04, or Debian 12 or 13, with root access. Founderizer sets up "
                        + "its user, security updates, private network and firewall."
                        : "macOS 14 or later, with Tailscale signed in and Homebrew installed. The agents run as "
                        + "the Mac user that pastes the line.") {
                if asksName {
                    FormRow("Name", symbol: "character.cursor.ibeam", warning: model.name.isEmpty ? nil : nameProblem) {
                        field($model.name, placeholder: "Server name", width: 220, identifier: "add-server-name",
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
            onwards("Make the line", identifier: "add-server-make", warning: error,
                    disabled: busy || list == nil || !store.isFresh || nameProblem != nil) {
                Task { await make() }
            }
        }
    }

    // MARK: three: the install

    @ViewBuilder private var install: some View {
        switch model.way {
        case .linux:
            MachineInstallRun(model: model, title: installed ?? "The server", next: AnyView(joined),
                              again: { model.installMachine(store: store) })
        case .mac:
            // Try again links the same Mac again (fix round 3, item 51): it emptied the page.
            MachineInstallRun(model: model, title: installed ?? "The server", next: AnyView(joined),
                              again: { model.linkMac(store: store, withAgent: placing == nil) })
        case .line:
            if let code, let line = code.line { joinLine(code, line) }
        }
    }

    /// A Linux server whose AI the owner chose: the app presses Add agent for him.
    private var addsFirstAgent: Bool { model.way == .linux && model.ai != nil && !firstAgentWaits && model.checklist != nil }

    /// Add agent pressed for the owner, as soon as the hub offers the new server: its first reading comes some seconds
    /// after its join. A count ends the wait, and the row with Add agent is the way on then.
    private func addFirstAgent() async {
        guard let ai = model.ai, let server = installed, let database = store.state?.db else { return firstAgentWaits = true }
        for _ in 0..<40 where !Task.isCancelled {
            if let read = try? await HubClient().servers(hub: store.hub, database: database),
               read.servers.first(where: { $0.name == server })?.available == true {
                if !(await addFirstAgent(server, ai.runtime)) { firstAgentWaits = true }
                return
            }
            try? await Task.sleep(for: .seconds(3))
        }
        if !Task.isCancelled { firstAgentWaits = true }
    }

    /// **The server that joined goes on to the agent's setup by itself**, as soon as the hub offers it: its first
    /// reading comes some seconds after its join. A count ends the wait, and the provider page then says in the hub's
    /// words why the server cannot take the agent. With no name for the server, the first page shows again.
    private func handOver(_ placing: Placing) async {
        guard let server = installed, let database = store.state?.db else {
            model.again(); page = .ways
            return
        }
        for _ in 0..<40 where !Task.isCancelled {
            if let read = try? await HubClient().servers(hub: store.hub, database: database),
               read.servers.contains(where: { $0.name == server && AgentSetupFlow.isFree($0) }) { break }
            try? await Task.sleep(for: .seconds(3))
        }
        if !Task.isCancelled { placing.place(server) }
    }

    /// What is left after a machine reached its checklist: its agent, which only the owner adds.
    @ViewBuilder private var joined: some View {
        if let placing {
            Color.clear.frame(height: 0).task { await handOver(placing) }
        // A Mac that the hub sets up has its first agent already, and the installer on it leads the rest.
        } else if model.way == .mac, model.firstAgent != nil {
            FormSection {
                FormRow("\(installed ?? "The server") is in your fleet", symbol: "checkmark.circle") { openServer }
            }
        } else if addsFirstAgent {
            Color.clear.frame(height: 0).task { await addFirstAgent() }
        } else {
            FormSection(footer: "A server is signed in to its provider from its own page: Settings, Servers, the server, Sign in.") {
                FormRow("\(installed ?? "The server") is in your fleet", symbol: "checkmark.circle",
                        detail: "Add an agent to it, and sign that server in to your provider account.") {
                    HStack(spacing: FleetSpace.actions) {
                        openServer
                        Button("Add agent") { addAgent(installed) }.buttonStyle(FleetPrimaryButtonStyle())
                            .accessibilityIdentifier("install-add-agent")
                    }
                }
            }
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
                    footer: "The line works once, for 30 minutes. It makes \(lineName ?? "the server") join your private network and Founderizer. A new line cancels this one.") {
            FormBlock("Join line", detail: code.kind == "linux" ? "It installs Tailscale when the VPS has none: open the sign-in link that it shows." : nil) {
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
                        Button("Add agent") { addAgent(lineName) }.buttonStyle(FleetPrimaryButtonStyle()).accessibilityIdentifier("add-server-agent")
                    }
                } else if expired || state == "canceled" {
                    Button("New line") { self.code = nil; copied = false; page = .machine }.buttonStyle(FleetOutlineButtonStyle())
                }
            }
            }
        }
    }

    private func status(state: String, expired: Bool) -> String {
        if state == "joined" { return "\(lineName ?? "The server") joined Founderizer." }
        if state == "canceled" { return "A newer line replaced this line." }
        if expired { return "This line expired. Make a new line." }
        return "Waiting for \(lineName ?? "the server") to join…"
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
        // A Linux server that waits for its first agent: leaving this page must not lose the owner's choice.
        if model.running || addsFirstAgent { page = .install; return }
        if cloud.stage != .token, let provider = cloud.provider { page = .token(provider); return }
        cloud.cancel()
        guard model.checklist != nil || model.failure != nil else { return }
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
            guard answer.line != nil else { error = "The hub gave no line. Make a new line."; return }
            code = answer; copied = false
            page = .install
            list = try? await HubClient().servers(hub: store.hub, database: database)
        } catch let HubError.refusal(_, words) { error = words }
        catch { self.error = "The hub has not answered. Try again." }
    }

    /// Reads the servers: once for the free names, then every 3 seconds while a line waits for its server. A hub with
    /// `server_names` asks for no name, and the suggested one is then only what a Mac's installer is sent.
    private func poll() async {
        while !Task.isCancelled {
            if let database = store.state?.db, store.isFresh {
                if let read = try? await HubClient().servers(hub: store.hub, database: database) {
                    guard !Task.isCancelled else { return }
                    list = read
                    if model.name.isEmpty, code == nil, !model.running {
                        model.name = Servers.suggestedName(taken: read.servers.map(\.name))
                    }
                }
            }
            do { try await store.nap(code == nil ? 15 : 3) } catch { return }
        }
    }
}
