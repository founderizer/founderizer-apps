import AppKit
import FleetCore
import FleetMark
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
/// **The manager of a new fleet starts with its server** (hub feature `manager_server`; the owner, 4 November 2026: "The
/// agent is done BY AGENT and here we're setting the fleet, no servers yet"): "Manager's server", whose pages are Add
/// server's (`AddServerView.Placing`), then its AI provider, where a press gives it that server and that provider in one
/// command. Its install and its sign-in follow, then "Setting up Manager" until its session runs. It is active from
/// the start, so nothing checks or activates it here.
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

    private var time: Double { store.state?.time ?? 0 }
    private var line: FleetAgent? { store.state?.agents.first { $0.name == agent } }
    private var runtime: String { line?.runtime ?? "codex" }
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
    /// **The server that joined for an agent with no server yet** (`FleetStore.joinedServer`): its provider's press gives
    /// it this one. A server that left the fleet, or that another agent took since, is not one to give it: the page is
    /// its server's again.
    private var placeOn: String? {
        guard let joined = store.joinedServer(agent) else { return nil }
        guard let list = servers else { return joined }
        guard let entry = list.servers.first(where: { $0.name == joined }), !entry.hub,
              entry.agents.allSatisfy({ $0 == agent }) else { return nil }
        return joined
    }
    private var serverName: String { server?.name ?? machine?.machine ?? String(l10n: "its server") }
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

    private var page: AgentSetupPage {
        // With no server yet: its server, then its provider once he took one.
        if line?.placed == false { return placeOn == nil ? .server : .provider }
        return AgentSetupFlow.page(runtime: runtime, job: job, machine: machine, switchingTo: switchingTo)
    }

    var body: some View {
        Group {
            // Add server's own pages, which are a setup page of their own.
            if readingsCurrent, page == .server { serverStep } else { steps }
        }
        .animation(.easeInOut(duration: 0.18), value: page)
        .task(id: "\(store.hub)/\(store.state?.db ?? "")/\(agent)") { await poll() }
        .onChange(of: page) { _, now in
            opened = false; code = ""; sentFrom = nil
            // His press asked for the sign-in at the end of these pages, and for nothing after they end.
            switch now {
            case .installing, .switching, .signIn: break
            default: askedSignIn = false
            }
        }
        .accessibilityIdentifier("agent-setup")
    }

    private var steps: some View {
        SetupPage {
            Group {
                if !readingsCurrent {
                    if store.addedAgent == agent {
                        // **"Adding Juno", as Add agent said it, until the page can draw** (fix round 3, item 12).
                        SetupStep(title: String(l10n: "Adding \(name)"), waits: true) { AgentGlyph(name: agent, size: SetupMetrics.mark) }
                    } else {
                        // Nothing for a second: the page it opens on comes with the first readings.
                        Held(since: began) { settingUp }
                    }
                } else {
                    switch page {
                    case .server: EmptyView()       // `serverStep`, in place of this page
                    case .provider: providers
                    case .installing(let provider): SetupStep(title: title, waits: true) { mark(provider) }
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
    /// that joined is the server of the provider page that follows, as soon as this page reads it.
    private var serverStep: some View {
        AddServerView(store: store, addAgent: { _ in }, addFirstAgent: { _, _ in false },
                      placing: .init(agent: agent) { joined in
                          store.noteJoined(joined, for: agent)
                          Task { await read() }
                      })
    }

    /// The provider's own icon, over the title of each page about it.
    private func mark(_ provider: String) -> some View { ProviderIcon(runtime: provider, size: SetupMetrics.mark) }

    /// The name of the page he is on. Each one says what it asks, so no page needs a line to explain itself.
    private var title: String {
        switch page {
        case .server: String(l10n: "\(name)'s server")
        case .provider: String(l10n: "\(name)'s AI provider")
        // With the step of the server's job that runs, once it reports one: "Installing Codex on app-1 · 2 of 5".
        case .installing(let provider):
            AgentSetupFlow.installing(providerName(provider), on: serverName, job: job, onMac: server?.isMac == true)
        case .switching: String(l10n: "Setting up \(name)")
        case .signIn(let provider): String(l10n: "Sign in to \(providerName(provider))")
        case .activate: String(l10n: "Activate \(name)")
        }
    }

    /// **One moving title from the sign-in to the chat**: the switch to the other provider, the settings the machine
    /// loads, the machine check and the activation, and then the chat's own "Setting up" (`ChatSettingUp`), which
    /// looks the same, so the page does not change while the machine works.
    private var settingUp: some View {
        SetupStep(title: String(l10n: "Setting up \(name)"), waits: true) { AgentGlyph(name: agent, size: SetupMetrics.mark) }
    }

    // MARK: the AI provider

    /// Two cards, and a click on one is the way on. The one the agent has now carries a check mark. Under them, in
    /// orange, why the setup stopped the last time, in the hub's own words.
    private var providers: some View {
        SetupStep(title: title) { AgentGlyph(name: agent, size: SetupMetrics.mark) } content: {
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

    private func card(_ provider: String) -> some View {
        Button { Task { await choose(provider) } } label: {
            HStack(spacing: 12) {
                ProviderIcon(runtime: provider, size: 28)
                Text(providerName(provider)).font(SetupMetrics.choiceFont).foregroundStyle(FleetStyle.text)
                Spacer(minLength: 8)
                if provider == runtime {
                    Image(systemName: "checkmark").font(IconMetrics.symbol(12, weight: .semibold)).foregroundStyle(FleetStyle.muted)
                        .accessibilityLabel("Now")
                }
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(FleetCardButtonStyle())
        // **They keep their look while the page reads** (T-01): they went grey for 40 ms whenever another page's request
        // was on its way. A press while the hub cannot take a write waits for it (`choose`).
        .disabled(busy)
        .accessibilityIdentifier("agent-setup-provider-\(provider)")
    }

    // MARK: the sign-in

    /// The sign-in on the agent's machine: the one the setup started, or the one the server's install started for
    /// Claude Code.
    private var login: MachineLogin? { machine?.login.flatMap { $0.isOpen ? $0 : nil } }

    /// **One page for each sign-in, its steps over what he enters** (the owner, 10 November 2026: "this kind of
    /// onboarding with steps, key etc... needs to be applied the same way in other places, like AI provider
    /// onboardings"), as a VPS provider's token page has them (`SetupSteps`). **Claude Code**: open the sign-in page,
    /// sign in and copy the code it shows, then the field, which sends a pasted code by itself. **Codex**: open the
    /// sign-in page, sign in and enter the code under the steps, in large type; the page goes on by itself when the
    /// machine reports the sign-in. The first step's link opens the page and copies Codex's code; no button and no
    /// "Open it again" stand under it. Until the provider has printed its link, and from the code's send until the
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
                    SetupCode(shown).accessibilityIdentifier("agent-setup-code")
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

    private var activationState: ActivationState {
        if busy || activating || checking || loading { return .runs }
        if let refusal { return .stopped(refusal) }
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
            if let placeOn {
                await place(on: placeOn, runtime: provider, database: database)
                askedSignIn = refusal == nil            // its install ends in his sign-in
            }
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
            } catch let HubError.refusal(_, words) { refusal = words }
            catch { refusal = String(l10n: "The hub has not answered. Try again.") }
        case .prepare:
            switchingTo = provider; askedSwitch = false
            // Signed in there already: nothing to prepare, the switch goes now.
            if teamLine?.runtime_switch?.to == provider, teamLine?.runtime_switch?.ready == true { break }
            guard let server = server?.name else { refusal = String(l10n: "Founderizer cannot read \(name)'s server now."); break }
            do {
                _ = try await HubClient().prepareServerRuntime(hub: store.hub, database: database, client: store.installation,
                                                               server: server, agent: agent, runtime: provider)
            } catch let HubError.refusal(_, words) { refusal = words; switchingTo = nil }
            catch { refusal = String(l10n: "The hub has not answered. Try again."); switchingTo = nil }
        }
        askedSignIn = start.signsIn && refusal == nil
        await read()
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
            } catch let HubError.refusal(status, words) {
                if status == 409, attempt == 0, words.contains("team.json changed") { continue }
                refusal = words; return
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
        guard store.canWrite else { return }
        // Once on each visit: a check that fails or an activation the hub refuses is asked again only by Try again.
        if page == .activate, !signingInAgain, !placing, !checking, !loading, refusal == nil {
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

    /// After a stop: the check and the activation run again by themselves, as on a first visit.
    private func tryAgain() {
        refusal = nil; askedCheck = nil; askedActivation = false; activated = false
        Task { await follow() }
    }

    /// Reads the servers, the machines and the team: every 2 seconds while something goes on, else every 5.
    private func poll() async {
        while !Task.isCancelled {
            await read()
            // Nothing for a second, then "Setting up" moving, which stands half a second once it showed (`settle`),
            // then the page whole (fix round 2, item 97).
            if !answered { await store.settle(since: began) }
            answered = true
            if store.addedAgent == agent { store.addedAgent = nil }
            // Signed in again, or its session runs: the state's own reading of it ends these pages (`AgentSetupFlow.shows`).
            if page == .activate, signingInAgain || placing { await store.refresh() }
            await follow()
            let quick = running || switchingTo != nil || checking || page == .activate
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
