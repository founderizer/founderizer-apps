import FleetCore
import SwiftUI

/// One agent's setup of another provider on one hub generation, kept by the store so that it outlives the view that
/// started it: the local installer over SSH (`session`), or on a server that joined with a join line the preparation
/// by the server's own service (`job`, owner feature `servers`).
@MainActor @Observable final class ProviderSetup {
    let session = ServerSetupSession()
    /// A machine check was asked after this session's finished setup.
    var checked = false
    /// The server's newest job when it prepares a provider for this agent, from the last read of the servers. The hub
    /// keeps the job; this copy shows it.
    private(set) var job: ServerJob?
    /// The agent's server and whether it joined with a join line, from the same read.
    private(set) var server: String?
    private(set) var joined = false
    @ObservationIgnored private var watching = false

    /// The setup goes on: the local installer runs, or the server's preparation is open.
    var running: Bool { session.running || job?.isOpen == true }
    /// It waits for the owner: a prompt of the installer, or the sign-in of the server's preparation.
    var waits: Bool { (session.running && session.timeline.prompt != nil) || job?.state == "needs_owner" }

    /// The Provider row opens the provider form by itself: a setup that goes on, that stopped, or that prepared a
    /// provider which the agent does not use yet (`current`, its provider in team.json).
    func reopens(current: String?) -> Bool {
        if running { return true }
        if let job { return job.state == "failed" || (job.state == "done" && job.runtime != current) }
        return session.timeline.run != nil && !(session.timeline.result?.status == "ok" && session.configuration.runtime == current)
    }

    func follow(_ list: ServerList, agent: String) {
        let entry = list.server(of: agent)
        server = entry?.name; joined = entry?.joined == true; job = entry?.preparation(of: agent)
    }

    /// Reads the servers every 2 seconds while the preparation is open, also while another page shows, so that the
    /// agent's marks show it.
    func watch(store: FleetStore, agent: String) {
        guard !watching, job?.isOpen == true else { return }
        watching = true
        let hub = store.hub, database = store.state?.db ?? ""
        Task { [weak self] in
            while let self, !Task.isCancelled, store.hub == hub, store.state?.db == database {
                if let read = try? await HubClient().servers(hub: hub, database: database) {
                    self.follow(read, agent: agent)
                    if self.job?.isOpen != true { break }
                }
                _ = try? await store.nap(2)
            }
            self?.watching = false
        }
    }
}

/// Change an agent's provider (`runtime_switch`): Codex or Claude Code, the only providers that Fleet switches. The hub
/// decides whether the agent can switch now and says why not. This view sends the one command and shows the new
/// provider as ready only after the agent's helper has loaded it. When the target provider is not installed or not
/// signed in on the agent's machine, its setup runs here first; the switch stays a separate step. On a server that
/// joined with a join line, the server's own service prepares it (`server_prepare`, with `ServerJobView`); on a
/// machine that this Mac set up, the local installer does it over SSH (`prepare_runtime`).
struct ProviderView: View {
    @Bindable var store: FleetStore
    let agent: String
    /// After a switch that changed team.json from `base` to `result`: the agent's Settings read the new defaults.
    var onSwitched: ((_ base: String, _ result: String) -> Void)?
    @State private var line: ReportingLine?
    @State private var configured: String?
    @State private var teamHash: String?
    @State private var machine: MachineStatus?
    /// The last reading failed. A later good reading clears it.
    @State private var readError: String?
    /// The switch failed. It stays until the next switch.
    @State private var writeError: String?
    /// The hub refused the server's preparation, or did not answer. It stays until the next request.
    @State private var prepareError: String?
    @State private var preparing = false
    @State private var busy = false
    /// The provider that this view switched to, until its helper has loaded it.
    @State private var asked: String?
    /// The agent's own setup of the target provider on this view's hub generation. The store keeps it, so it goes on
    /// while another tab or page shows; Stop setup stops it.
    private let held: ProviderSetup
    private var setup: ServerSetupSession { held.session }
    @State private var secret = ""
    /// The agent's machine in team.json, which binds its setup.
    @State private var placement: String?
    private let hub: URL
    private let database: String?

    /// The provider change, under the provider row of the agent's Settings tab. The row's own button hides it.
    init(store: FleetStore, agent: String, onSwitched: ((_ base: String, _ result: String) -> Void)? = nil) {
        self.store = store; self.agent = agent; self.onSwitched = onSwitched
        hub = store.hub; database = store.state?.db
        held = store.providerSetup(hub: hub, database: database, agent: agent)
    }

    private var matches: Bool { store.hub == hub && store.state?.db == database }
    private var time: Double { store.state?.time ?? 0 }
    private var runtime: String { configured ?? store.state?.agents.first { $0.name == agent }?.runtime ?? "" }
    private var provider: ProviderState { ProviderState(configured: runtime, machine: machine, at: time) }
    /// A refused switch of this agent that the outbox keeps.
    private var refusal: String? {
        guard let pending = store.pending, case .agentRuntime(let name, _, _)? = pending.command, name == agent else { return nil }
        return pending.refusal
    }
    /// Why the store cannot send now, when nothing else says it. **A request on its way is not a reason** (fix round
    /// 2, item 99): a save of the same card said "A saved request is waiting." here in orange while it went, and the
    /// buttons went with it. That save says "Saving…" in its own row after a second; a press here waits for it.
    /// **Nor is another row's request that waits** (fix round 3b): an unanswered save of Tools said so in its own row
    /// and in the window's request line, and here a third time. Only this row's own switch is said here.
    private var sendBlock: String? {
        if !matches { return "The connection changed. Open this tab again." }
        if !store.isFresh { return "No current hub status." }
        if let refusal { return refusal }
        if let pending = store.pending, !store.sending, case .agentRuntime(let name, _, _)? = pending.command, name == agent {
            return "A saved request is waiting."
        }
        return nil
    }
    /// **The one row that the Provider row opens**: the other provider, what stands between the agent and it, and
    /// the one thing to press now. Nothing else — the steps of a setup are on the server's own page, and the line
    /// that said "Model and reasoning use provider defaults." is behind the Switch button, where the decision is.
    var body: some View {
        let readiness = line?.runtime_switch
        let blocker = RuntimeSwitch.unavailable(offered: store.state?.ui_features?.contains(RuntimeSwitch.feature) == true,
                                                readiness: readiness)
        Group {
            if line == nil && readError == nil {
                // The row stands with its name while it is read, and what it says comes in its place: no spinner,
                // which is the pages' one loading look (the Change form's own line says that it reads).
                FormRow("The other provider")
            } else if let blocker {
                FormRow("The other provider", detail: blocker)
            } else if let readiness, let to = readiness.to {
                targetRow(readiness, to: to)
                askView(to)
            } else {
                FormRow("The other provider", detail: "\(providerName(runtime)) cannot switch.")
            }
        }
        .onChange(of: setup.timeline.prompt?.id) { _, _ in secret = "" }
        .onChange(of: setup.timeline.result?.status) { _, status in if status == "ok" { Task { await afterSetup() } } }
        // A running setup stays with its agent while another tab or page shows: the agent's row in the sidebar has
        // a progress mark, and Stop is its stop control. A refused switch leaves the outbox with this view.
        .onDisappear { secret = ""; discardRefused() }
        .task {
            // A run keeps its text: a new availability reading would remove the text of a run that failed while this
            // view did not show.
            if setup.timeline.run == nil || !setup.available { await setup.check() }
            await setup.checkExecutor()
            // A setup that finished while this view did not show still gets its machine check.
            if setup.timeline.result?.status == "ok" { await afterSetup() }
            await poll()
        }
    }

    /// The other provider, in one row: its name, one line of where it stands, one orange line when something went
    /// wrong, and one control.
    @ViewBuilder private func targetRow(_ readiness: RuntimeSwitch, to: String) -> some View {
        let place = machineName
        FormRow(providerName(to), mark: ProviderIcon(runtime: to, size: 18),
                detail: detailWords(readiness, to: to, machine: place), warning: warningWords(to: to, machine: place)) {
            control(readiness, to: to)
        }.help(helpWords(readiness, to: to))
    }

    /// Where the other provider stands, in one line and in his own words. A reason the hub gave is the hub's own
    /// sentence; a setup that runs says what it is doing and never which of its steps it is on.
    private func detailWords(_ readiness: RuntimeSwitch, to: String, machine: String) -> String? {
        if provider.switchingFrom != nil { return "Switching…" }
        if asked == to && !provider.isConfirmed { return "Waiting for the agent to load it…" }
        if preparing || held.job?.state == "queued" { return "Starting the setup on \(machine)…" }
        if held.job?.state == "needs_owner" || (setup.running && setup.timeline.prompt != nil) { return "Waiting for you" }
        if setupRunning { return "Setting up on \(machine)…" }
        if readiness.ready { return "Ready to switch" }
        // The first reason, in a few words; the others are on the row's hover (`helpWords`), not a pointer to them.
        return readiness.rowReasons(current: runtime, machine: machine, agent: agent).first
    }

    /// The one orange line: a setup that stopped, or a switch the hub refused. **Never the installer's own
    /// sentence** — that one names a hub's worker user at him (the owner, 20 October 2026: "look at the messages,
    /// what do they even mean, they dont make any sense!"). It stays in the row's hover text, where a reason that
    /// he cannot act on belongs.
    private func warningWords(to: String, machine: String) -> String? {
        if let message = writeError ?? prepareError ?? sendBlock { return message }
        if held.job?.state == "failed" { return "Founderizer could not set up \(providerName(to)) on \(machine)." }
        if !held.joined, setupStarted, !setup.running, setup.timeline.result?.status != "ok",
           setup.timeline.result != nil || setup.error != nil {
            return "Founderizer could not set up \(providerName(to)) on \(machine)."
        }
        return readError
    }

    /// Behind the row: what a switch would change, and the words of whatever stopped a setup — the installer's own
    /// sentence and the hub's reasons, which are true and are not his to act on.
    private func helpWords(_ readiness: RuntimeSwitch, to: String) -> String {
        var lines: [String] = []
        let reasons = readiness.rowReasons(current: runtime, machine: machineName, agent: agent)
        if reasons.count > 1 { lines += reasons }
        if let summary = setup.timeline.result?.summary, !summary.isEmpty, setup.timeline.result?.status != "ok" {
            lines.append(summary)
        }
        if let error = setup.error, !held.joined { lines.append(error) }
        if let detail = held.job?.detail, held.job?.state == "failed" { lines.append(detail) }
        if readiness.ready {
            lines.append("Switching sets the model and the reasoning back to the defaults of \(providerName(to)).")
        }
        return lines.joined(separator: "\n")
    }

    /// One control, the one that applies now.
    @ViewBuilder private func control(_ readiness: RuntimeSwitch, to: String) -> some View {
        if setup.running && !held.joined {
            Button("Stop") { secret = ""; Task { await setup.cancel() } }
                .buttonStyle(FleetOutlineButtonStyle()).accessibilityIdentifier("stop-provider-setup")
                .help("Stops the setup. Set up again continues from its saved steps.")
        } else if held.job?.isOpen == true {
            Button("Open \(held.server ?? "server")") { store.destination = .server(held.server ?? agent) }
                .buttonStyle(FleetOutlineButtonStyle()).accessibilityIdentifier("open-provider-server")
                .help("The steps of the setup are on the server's own page.")
        } else if setupRunning {
            ProgressView().controlSize(.small)
        } else if readiness.needsSetup, canSetUp {
            // **Only while it can act** (never grey; the owner: "dont show the send button if it's not clickable").
            if !busy && sendBlock == nil && (held.joined || placement != nil) {
                Button(setupTried ? "Try again" : "Set up") { Task { await startTarget(to) } }
                    .buttonStyle(FleetOutlineButtonStyle()).accessibilityIdentifier("setup-provider")
                    .accessibilityLabel("Set up \(providerName(to)) on \(machineName)")
                    .help("Founderizer installs \(providerName(to)) on this agent's server. You sign in yourself.")
            }
        } else if readiness.to != nil {
            if readiness.ready && !busy && sendBlock == nil && provider.switchingFrom == nil && !setupRunning {
                Button("Switch") { Task { await switchTo(to) } }
                    .buttonStyle(FleetOutlineButtonStyle()).accessibilityIdentifier("switch-provider")
                    .accessibilityLabel("Switch to \(providerName(to))")
            }
        }
    }

    /// The one thing a setup can ask him, under the row: a server identity to confirm, or the provider's own
    /// sign-in page and its code. Everything else a setup does it does by itself.
    @ViewBuilder private func askView(_ to: String) -> some View {
        if held.joined, held.job?.state == "needs_owner", let prompt = held.job?.prompt,
           let url = prompt.signInURL, let code = prompt.deviceCode {
            // **The steps over the code, as on every sign-in** (`SetupSteps`, the owner's rule of 10 November 2026): the
            // first one's link opens the provider's page with the code copied for it.
            FormBlock("Sign in to \(providerName(to))") {
                VStack(alignment: .leading, spacing: 12) {
                    SetupSteps.deviceCode(at: url, width: nil)
                        .environment(\.openURL, OpenURLAction { _ in copyMessage(code); NSWorkspace.shared.open(url); return .handled })
                    Text(code).font(FormMetrics.oneTimeCode).textSelection(.enabled)
                        .accessibilityIdentifier("provider-code")
                }
            }
        } else if !held.joined, setup.running, (setup.timeline.prompt ?? setup.timeline.signIn) != nil {
            FormBlock("The setup needs you") { SetupPromptView(session: setup, secret: $secret) }
        }
    }

    /// Set up the other provider: the server's own service where the server joined with a join line, else the local
    /// installer over SSH. One button, one meaning.
    private func startTarget(_ runtime: String) async {
        if held.joined { await prepare(runtime) } else { await startSetup(runtime) }
    }

    /// A setup of this provider has already been tried and did not finish.
    private var setupTried: Bool {
        held.job?.state == "failed" || (!held.joined && setupStarted && setup.timeline.result?.status != "ok")
    }

    /// Founderizer can run the setup: the server does it itself, or this Mac's bundled installer can.
    private var canSetUp: Bool {
        if held.joined { return store.state?.ui_features?.contains(Servers.prepareFeature) == true }
        return setupOffered
    }

    /// The agent's machine, as the hub names it: every line of this row says where, because the owner has four.
    private var machineName: String { placement ?? held.server ?? "its server" }

    private var setupRunning: Bool { setup.running || setup.busy || held.job?.isOpen == true || preparing }
    private var setupStarted: Bool { setup.running || setup.busy || setup.timeline.run != nil }

    /// Asks the hub for the preparation of `runtime` on the agent's server. The server's own service does it, and its
    /// job shows here and on the server's page.
    private func prepare(_ runtime: String) async {
        guard matches, let database, let server = held.server, !preparing else { return }
        preparing = true; defer { preparing = false }
        prepareError = nil
        do {
            _ = try await HubClient().prepareServerRuntime(hub: hub, database: database, client: store.installation,
                                                           server: server, agent: agent, runtime: runtime)
        } catch let HubError.refusal(_, words) { prepareError = words }
        catch { prepareError = "The hub has not answered. Look at the server's page before you try again." }
        await refresh()
    }

    /// The bundled installer can set up a provider, and the hub reports machines.
    private var setupOffered: Bool {
        setup.executor?.supportsRuntimePreparation == true && store.state?.ui_features?.contains("machines") == true
    }

    /// The target provider's setup on the agent's own machine, bound to this hub generation and that machine. A second
    /// start is the same command: the installer continues its own saved run.
    private func startSetup(_ runtime: String) async {
        guard matches, let database, let placement else { return }
        var configuration = ServerConfiguration()
        configuration.hub = hub.absoluteString; configuration.auth = "agent"
        configuration.prepareRuntime = agent; configuration.runtime = runtime
        configuration.generation = database; configuration.machine = placement
        setup.configuration = configuration
        setup.hubReady = store.isFresh && store.state?.ui_features?.contains("machines") == true
        held.checked = false
        await setup.start()
    }

    /// A finished setup over SSH changes nothing on the hub by itself, and the hub has no job of it to follow: a fresh
    /// machine check updates the readiness. It is a save, so a request that is on its way when the setup ends makes
    /// it wait, and never drops it; it runs on its own, so this view goes on reading meanwhile, and its answer wakes
    /// this view's read.
    private func afterSetup() async {
        guard !held.checked else { return }
        held.checked = true
        if matches {
            let store = store, agent = agent
            Task { _ = await store.save(.machineCheck(agent: agent)) }
        }
        await refresh()
    }

    /// Reads again every 3 seconds while a switch waits for its helper or the server prepares a provider, else every 15
    /// seconds.
    private func poll() async {
        while !Task.isCancelled {
            await refresh()
            let state = provider
            // After a finished setup, only its own reasons (install, sign-in) keep the fast reads; another blocker, such
            // as an unlinked chat, waits at the usual interval.
            let prepared = setup.timeline.result?.status == "ok" ||
                (held.job?.state == "done" && held.job?.runtime == line?.runtime_switch?.to)
            let waiting = state.switchingFrom != nil || (asked != nil && !state.isConfirmed) || held.job?.isOpen == true ||
                (prepared && line?.runtime_switch?.needsSetup == true)
            do { try await store.nap(waiting ? 3 : 15) } catch { return }
        }
    }

    private func refresh() async {
        guard matches, let database else { return }
        let client = HubClient()
        // The agent's server first, so that a server that joined with a join line never shows the SSH setup.
        if store.state?.ui_features?.contains(Servers.feature) == true,
           let list = try? await client.servers(hub: hub, database: database) {
            guard !Task.isCancelled, matches else { return }
            held.follow(list, agent: agent)
            held.watch(store: store, agent: agent)
        }
        do {
            let team = try await client.team(hub: hub, database: database)
            guard !Task.isCancelled, matches else { return }
            line = team.lines.first { $0.agent == agent }; teamHash = team.sha256
            configured = team.members.first { $0.agent == agent }?.placement?.runtime
            placement = team.members.first { $0.agent == agent }?.placement?.machine
            if store.state?.ui_features?.contains("machines") == true {
                let list = try? await client.machines(hub: hub, database: database)
                guard !Task.isCancelled, matches else { return }
                machine = list?.machines.first { $0.agent == agent }
            }
            readError = nil
        } catch { if !Task.isCancelled { readError = "No current provider reading." } }
    }

    /// One command. A receipt that changed the runtime tells the agent's Settings, which then show the new provider's
    /// defaults. A refusal stays shown; the readiness then comes from the hub again.
    private func switchTo(_ runtime: String) async {
        guard let base = teamHash, matches else { return }
        busy = true; defer { busy = false }
        writeError = nil
        // Another save on its way goes first, as the store sends one request at a time.
        guard await store.writable() else { return }
        if await store.command(.agentRuntime(agent: agent, sha256: base, runtime: runtime)) {
            if let receipt = store.lastControlReceipt, let result = receipt.sha256, receipt.changed?.settingChanges?.isEmpty == false {
                asked = runtime
                onSwitched?(base, result)
            }
            await store.refresh()
        } else {
            writeError = refusal ?? store.sendError ?? "The switch was not confirmed."
        }
        await refresh()
    }

    /// A refused switch of this agent stays in the outbox only while this view shows it.
    private func discardRefused() {
        guard refusal != nil else { return }
        store.discardRefused()
    }
}
