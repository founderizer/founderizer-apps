import AppKit
import FleetCore
import FleetMark
import Observation
import SwiftUI

/// Add agent (owner feature `servers`): **first the server, then its name and its AI** (the owner, 7 November 2026: "Why
/// doesn't it ask me first if I want to use an existing server or a new one?!" and "it should have asked me first", and
/// his yes to the mockup the same day). A server with agents takes one more (the owner, 3 November 2026: "we allow
/// multiple agents per server"). The hub registers the agent, inactive and with no credential access, as a worker that
/// reports to the manager, and the server's service installs it: the AI he pressed when the server has none, the agent's
/// checkout and service, and the AI's sign-in when the server is not signed in. Nothing installs before that press. The
/// model stays while other pages show, so the install's progress goes on.
@MainActor @Observable
final class AddAgentModel {
    var server: String?
    /// He chose the server, on the first step or on a server's own page: the second step shows.
    private(set) var picked = false
    var name = ""
    var runtime = "codex"
    var role = "worker"
    /// nil: the manager.
    var reportsTo: String?
    private(set) var list: ServerList?
    private(set) var team: TeamSnapshot?
    private(set) var receipt: ServerAgentReceipt?
    private(set) var job: ServerJob?
    private(set) var busy = false
    private(set) var error: String?
    @ObservationIgnored private var watch: Task<Void, Never>?

    /// The install goes on, or waits for the owner's sign-in.
    var running: Bool { receipt != nil && (job == nil || job?.isOpen == true) }
    var selected: ServerEntry? { list?.servers.first { $0.name == server } }

    /// A form with no install, or an install that ended in success: a new form, on its first step, or on its second for
    /// the server that a server's page gave. A failed install stays for Try again, unless its agent has left the fleet
    /// (`listed`: the agents the hub lists now), which he deleted: that install is over.
    func prepare(server: String?, listed: [String]? = nil) {
        if let receipt, let listed, !listed.contains(receipt.agent) { forget() }
        if job?.state == "done" || job?.state == "canceled" { reset() }
        guard receipt == nil else { return }
        self.server = server
        picked = server != nil
        error = nil
    }

    /// The server he pressed on the first step.
    func pick(_ server: String) { self.server = server; picked = true; error = nil }

    /// Back to the first step.
    func unpick() { picked = false; error = nil }

    func reset() {
        guard !running else { return }
        forget()
    }

    /// A new form, whatever the last install did.
    private func forget() {
        watch?.cancel(); watch = nil
        receipt = nil; job = nil; error = nil; name = ""; server = nil; picked = false; role = "worker"; reportsTo = nil
    }

    func read(store: FleetStore) async {
        guard let database = store.state?.db else { return }
        // The servers the Servers page read last, while this form has none: the form shows with them at once.
        if list == nil, let kept: ServerList = store.reading("servers.list") { list = kept }
        suggest(store: store)
        async let servers = try? HubClient().servers(hub: store.hub, database: database)
        async let lines = try? HubClient().team(hub: store.hub, database: database)
        let (readServers, readTeam) = await (servers, lines)
        if let readServers { list = readServers; follow(); store.keep(readServers, as: "servers.list") }
        if let readTeam { team = readTeam }
        suggest(store: store)
    }

    /// **A name already in the field** (D-3, the owner's yes of 28 October 2026): the first of a list of short names
    /// that no agent of this hub has, as he would write it. Typing replaces it.
    func suggest(store: FleetStore) {
        guard name.isEmpty, receipt == nil else { return }
        let taken = Set((team?.lines.map(\.agent) ?? []) + (store.state?.agents.map(\.name) ?? []))
        name = Self.freeName(taken: taken).capitalized
    }

    /// The first of the suggested names that no agent has.
    static func freeName(taken: Set<String>) -> String { names.first { !taken.contains($0) } ?? "agent-\(taken.count + 1)" }

    /// The names Add agent suggests, in their order.
    static let names = ["juno", "iris", "otto", "remy", "sage", "luna", "milo", "ezra", "nora", "theo", "vera", "kai",
                        "lena", "orion", "ada", "felix", "hugo", "ines", "elio", "maya"]

    /// The name as the hub keeps it: what he typed, in small letters.
    var key: String { name.trimmingCharacters(in: .whitespaces).lowercased() }

    /// The servers that can take an agent, the one with the fewest agents first, in the hub's order between equals.
    var open: [ServerEntry] {
        (list?.available ?? []).enumerated().sorted { ($0.element.agents.count, $0.offset) < ($1.element.agents.count, $1.offset) }
            .map(\.element)
    }

    /// Why Add agent cannot go now, or nil.
    var problem: String? {
        Servers.agentProblem(name: key, server: selected, existing: team?.lines.map(\.agent) ?? [])
    }

    /// The agent on the chosen server with `runtime`, the AI he pressed (or chose in Add server for a new server's
    /// first agent).
    func start(store: FleetStore, runtime chosen: String) async {
        guard !busy, problem == nil, let server, let database = store.state?.db else { return }
        busy = true; error = nil
        defer { busy = false }
        let name = key
        runtime = chosen; role = "worker"; reportsTo = nil
        // A change of team.json elsewhere between the read and the request: read it again, and send once more.
        for attempt in 0..<2 {
            do {
                let team = try await HubClient().team(hub: store.hub, database: database)
                self.team = team
                receipt = try await HubClient().addServerAgent(hub: store.hub, database: database, client: store.installation,
                                                               server: server, sha256: team.sha256, agent: name, runtime: runtime,
                                                               role: role, reportsTo: reportsTo)
                job = nil
                watchJob(store: store)
                await store.refresh()
                return
            } catch let HubError.refusal(status, words) {
                if status == 409, attempt == 0, words.contains("team.json changed") { continue }
                error = words; return
            } catch { self.error = "The hub has not answered. Look at the server's page before you try again."; return }
        }
    }

    /// The install again, after a failure: the same agent, server and provider.
    func retry(store: FleetStore, server: ServerEntry, job: ServerJob) async {
        guard let agent = job.agent, let runtime = job.runtime else { return }
        let role = team?.lines.first { $0.agent == agent }?.role ?? "worker"
        self.server = server.name; picked = true; name = agent; self.runtime = runtime; self.role = role == "lead" ? "lead" : "worker"
        receipt = nil; self.job = nil
        busy = true; error = nil
        defer { busy = false }
        guard let database = store.state?.db else { return }
        do {
            let team = try await HubClient().team(hub: store.hub, database: database)
            receipt = try await HubClient().addServerAgent(hub: store.hub, database: database, client: store.installation,
                                                           server: server.name, sha256: team.sha256, agent: agent, runtime: runtime,
                                                           role: self.role, reportsTo: nil)
            watchJob(store: store)
        } catch let HubError.refusal(_, words) { error = words }
        catch { self.error = "The hub has not answered. Try again." }
    }

    private func follow() {
        guard let receipt else { return }
        job = list?.servers.first { $0.name == receipt.server }?.job.flatMap { $0.id == receipt.job ? $0 : nil } ?? job
    }

    /// Reads the job every 2 seconds until it ends, also while another page shows.
    private func watchJob(store: FleetStore) {
        watch?.cancel()
        let hub = store.hub, database = store.state?.db ?? ""
        watch = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, store.hub == hub, store.state?.db == database else { return }
                if let read = try? await HubClient().servers(hub: hub, database: database) {
                    self.list = read; self.follow()
                    if let job = self.job, !job.isOpen { await store.refresh(); return }
                }
                do { try await store.nap(2) } catch { return }
            }
        }
    }
}

struct AddAgentView: View {
    @Bindable var store: FleetStore
    @Bindable var model: AddAgentModel
    let configure: ((String) -> Void)?
    let addServer: () -> Void
    /// The agent is added and its own setup page opens next: "Adding <Name>" stays until then.
    @State private var handingOff = false

    var body: some View {
        Group {
            if !(store.state?.ui_features?.contains(Servers.feature) == true) {
                FleetPage("Add agent") {
                    FormSection { FormEmpty("Update the Founderizer hub to add agents on servers.", symbol: "arrow.triangle.2.circlepath") }
                }
            } else if let receipt = model.receipt, !handingOff {
                FleetPage("Add agent") { progress(receipt) }
            } else {
                step
            }
        }
        // Its first page, the servers (or the hub's line that it cannot add agents): Esc closes the wizard there.
        .preference(key: SetupFirstPage.self, value: model.receipt == nil && !model.picked && !model.busy && !handingOff)
        .task(id: "\(store.hub)/\(store.state?.db ?? "")") {
            while !Task.isCancelled {
                if model.receipt == nil { await model.read(store: store) }
                do { try await store.nap(10) } catch { return }
            }
        }
    }

    /// **Add agent is two centred steps under one mark and one title** (D-3 of 28 October 2026, and the owner's yes of
    /// 7 November 2026 to the mockup): the new agent's glyph and "Add agent" stand still, and under them first the
    /// servers, then its name and its AI. It is a worker that reports to the manager, which Settings › Reporting lines
    /// changes.
    private var step: some View {
        let list = model.list ?? store.reading("servers.list")
        let team = store.state?.agents.map(\.name) ?? []
        // Back from its name to the servers stands at the page's top left, where every setup page has it.
        return SetupPage {
            if !handingOff, list != nil, model.picked, !model.busy {
                SetupBack { model.unpick() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("add-agent-back")
            }
        } step: {
            SetupStep(title: model.busy || handingOff ? "Adding \(model.name)" : "Add agent", waits: model.busy || handingOff) {
                // The glyph it will wear: its name, at the end of the hub's list.
                AgentGlyph(name: model.key, size: SetupMetrics.mark).environment(\.glyphTeam, team + [model.key])
            } content: {
                // **While it hands over, the moving title alone** (fix round 3b): the server it took was busy with it,
                // and "No free server." with a white Add server stood under "Adding Juno" for a frame.
                if !handingOff, list != nil {
                    if model.picked { naming } else { servers }
                }
            }
        }
    }

    // MARK: one: where it runs

    /// **A card for each server that can take one more agent**, the one with the fewest agents first, with its agents'
    /// glyphs (the owner, 7 November 2026: "agents should always come with their icon"), then **New server**, which
    /// opens Add server. Only New server while no server can take one.
    private var servers: some View {
        VStack(spacing: 10) {
            ForEach(model.open) { server in
                card(symbol: server.symbol, title: server.name, help: server.agents.count > 2 ? People.agentWords(server.agents) : nil) {
                    model.pick(server.name)
                } trailing: {
                    agents(server.agents)
                }
                .accessibilityLabel("\(server.name), \(People.agentWords(server.agents))")
                .accessibilityIdentifier("add-agent-server-\(server.name)")
            }
            card(symbol: "plus", title: "New server", help: nil) { addServer() } trailing: { EmptyView() }
                .accessibilityIdentifier("add-agent-add-server")
        }
    }

    /// The agents of a server at its card's right end: each glyph with its name, and the glyphs alone where three or
    /// more would not fit beside the server's name (their names are on the card's hover).
    private func agents(_ names: [String]) -> some View {
        HStack(spacing: names.count > 2 ? 4 : 12) {
            ForEach(names, id: \.self) { name in
                HStack(spacing: 6) {
                    AgentGlyph(name: name, size: GlyphSize.inline, dot: false)
                    if names.count <= 2 { Text(People.agentWord(name)).foregroundStyle(FleetStyle.muted).lineLimit(1) }
                }
            }
        }.accessibilityHidden(true)
    }

    // MARK: two: its name and its AI

    /// **Its name, then a card for each AI: the press on one adds the agent with that AI** (the owner, 7 November 2026:
    /// "I just chose Juno and it installed claude code??! why?? it should have asked me first"). The field holds a name
    /// already, and Return in it adds nothing. The AIs are Add server's, in its cards' look.
    @ViewBuilder private var naming: some View {
        SetupField(placeholder: "Agent name", text: $model.name, wrong: !model.name.isEmpty && model.problem != nil) {}
            .accessibilityIdentifier("add-agent-name")
        if let error = model.error ?? (model.name.isEmpty ? nil : model.problem) {
            SetupWarning(error)
        }
        // Only once it can go: no grey card (the owner: "dont show the send button if it's not clickable").
        if !model.busy && model.problem == nil && store.canWrite {
            VStack(spacing: 10) {
                ForEach(ServerAI.linuxChoices, id: \.self) { ai in
                    let line = model.selected?.isMac == true ? ai.macLine : ai.linuxLine
                    card(logos: ai.logos, title: ai.title, help: line) { add(runtime: ai.runtime) }
                        .accessibilityHint(line)
                        .accessibilityIdentifier("add-agent-ai-\(ai.rawValue)")
                }
            }
        }
    }

    /// One card of one line, as Add server's are: its mark, its name, and what stands at its right end.
    private func card<Trailing: View>(symbol: String, title: String, help: String?, action: @escaping () -> Void,
                                      @ViewBuilder trailing: () -> Trailing) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(IconMetrics.symbol(18)).foregroundStyle(FleetStyle.text)
                    .frame(width: 28).accessibilityHidden(true)
                Text(title).font(SetupMetrics.choiceFont).foregroundStyle(FleetStyle.text).lineLimit(1)
                Spacer(minLength: 8)
                trailing()
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(FleetCardButtonStyle())
        .help(help ?? "")
    }

    /// An AI's card: its real logo or logos and its name.
    private func card(logos: [String], title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    ForEach(logos, id: \.self) { name in
                        ProviderLogo.image(name)?.resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                            .frame(width: 28, height: 28).accessibilityHidden(true)
                    }
                }
                Text(title).font(SetupMetrics.choiceFont).foregroundStyle(FleetStyle.text)
                Spacer(minLength: 8)
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(FleetCardButtonStyle())
        .help(help)
    }

    /// **Add agent, then the agent's own page**, whose setup takes it from the install to its chat one centered step at
    /// a time (`AgentSetupWizard`). The install's rows show here only on a hub without those pages. **"Adding Juno"
    /// stays until the setup can draw** (fix round 3, item 12): the install's page showed 198 ms after it, and then the
    /// agent's page stood empty 745 ms; the setup page goes on saying it until its first reading (`FleetStore.addedAgent`).
    private func add(runtime: String) {
        Task {
            handingOff = configure != nil
            await model.start(store: store, runtime: runtime)
            guard let agent = model.receipt?.agent, let configure,
                  AgentSetupFlow.shows(store.state?.agents.first { $0.name == agent }, features: store.state?.ui_features ?? [])
            else { handingOff = false; return }
            // Add agent that he closed meanwhile does not open again: the agent's row opens its setup, which fills the
            // window as adding it does.
            store.noteAdding(agent)
            guard store.destination == .addAgent else { handingOff = false; return }
            store.addedAgent = agent
            configure(agent)
        }
    }

    @ViewBuilder private func progress(_ receipt: ServerAgentReceipt) -> some View {
        if let job = model.job {
            ServerJobView(job: job, server: receipt.server, retry: job.state == "failed" ? {
                if let server = model.list?.servers.first(where: { $0.name == receipt.server }) {
                    Task { await model.retry(store: store, server: server, job: job) }
                }
            } : nil, onMac: model.list?.servers.first { $0.name == receipt.server }?.isMac == true,
            openSignIn: { store.destination = .signIn($0) })
        } else {
            FormSection("Installing \(receipt.agent.agentLabel) on \(receipt.server)") {
                // The app's one loading look (T-13): moving words, no spinner.
                FormRow("The hub registered \(receipt.agent.agentLabel). The server starts the install in a few seconds.") {
                    ShimmeringWords(text: "Starting").accessibilityElement().accessibilityLabel("Starting")
                }
            }
        }
        if let error = model.error { Text(error).font(FormMetrics.detail).foregroundStyle(.orange) }
        HStack {
            if !model.running {
                Button("Another agent") { model.reset(); Task { await model.read(store: store) } }.buttonStyle(FleetOutlineButtonStyle())
            }
            Spacer()
            if model.job?.state == "done", let configure {
                Button("Continue") { configure(receipt.agent) }.buttonStyle(FleetPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction).accessibilityIdentifier("add-agent-settings")
            }
        }
    }
}

/// One job of a server: the install of an agent, the preparation of a provider before a switch (Change provider), or
/// what was the own of an agent he deleted (Delete…). Its steps, the owner's sign-in while it waits, and Try again after
/// a failure.
struct ServerJobView: View {
    let job: ServerJob
    let server: String
    let retry: (() -> Void)?
    /// A Mac keeps one user for its agents, so a Mac install has no user step of its own to draw.
    var onMac = false
    /// Opens the sign-in screen of an agent (`SignInWizard`), for a job whose sign-in the hub runs as the machine's own.
    var openSignIn: ((String) -> Void)?
    @State private var copied = false

    var body: some View {
        FormSection(title, footer: job.state == "needs_owner" && job.prompt != nil ? nil : Servers.jobWords(job)) {
            ForEach(Servers.steps(job, onMac: onMac), id: \.id) { step in
                FormRow(stepTitle(step.id, step.title), symbol: mark(step.id)) { stepState(step.id) }
            }
            if job.state == "needs_owner", let prompt = job.prompt { signIn(prompt) }
            if let retry {
                FormRow("Try again", detail: "The server checks each step again and repeats only what is missing.") {
                    Button("Try again") { retry() }.buttonStyle(FleetPrimaryButtonStyle()).accessibilityIdentifier("job-retry")
                }
            }
        }
    }

    private var title: String {
        let agent = job.agent?.agentLabel ?? "The agent", provider = providerName(job.runtime ?? "")
        if job.kind == "prepare" {
            return job.state == "done" ? "\(provider) is ready on \(server)" : job.state == "failed" ?
                "The preparation of \(provider) stopped" : "Preparing \(provider) on \(server)"
        }
        if job.kind == "remove" {
            return job.state == "done" ? "\(agent) is removed from \(server)" : job.state == "failed" ?
                "The removal of \(agent) stopped" : "Removing \(agent) from \(server)"
        }
        return job.state == "done" ? "\(agent) is installed on \(server)" : job.state == "failed" ? "The install of \(agent) stopped" :
            "Installing \(agent) on \(server)"
    }

    private func stepTitle(_ id: String, _ title: String) -> String {
        id == "runtime" ? "AI provider: \(providerName(job.runtime ?? ""))" : title
    }

    private var order: [String] { Servers.steps(job, onMac: onMac).map(\.id) }

    private func position(_ id: String) -> (before: Bool, current: Bool) {
        let index = order.firstIndex(of: id) ?? 0, at = order.firstIndex(of: job.step ?? "") ?? -1
        return (index < at, index == at)
    }

    private func mark(_ id: String) -> String {
        if job.state == "done" { return "checkmark.circle" }
        let place = position(id)
        if place.before { return "checkmark.circle" }
        if place.current { return job.state == "failed" ? "exclamationmark.circle" : job.state == "needs_owner" ? "person.crop.circle.badge.exclamationmark" : "circle.dotted" }
        return "circle"
    }

    @ViewBuilder private func stepState(_ id: String) -> some View {
        let place = position(id)
        if job.state == "done" || place.before { Text("Done").foregroundStyle(FleetStyle.muted) }
        else if place.current {
            switch job.state {
            case "failed": Text("Failed").foregroundStyle(.orange)
            case "needs_owner": Text("Waits for you").foregroundStyle(.orange)
            // The step that runs says so in moving words, as a thread's running step does (T-13: no spinner).
            default: ShimmeringWords(text: "Running").accessibilityElement().accessibilityLabel("Running")
            }
        } else { Text(job.state == "failed" ? "Not done" : "Next").foregroundStyle(FleetStyle.muted) }
    }

    @ViewBuilder private func signIn(_ prompt: ServerJob.Prompt) -> some View {
        if let url = prompt.signInURL, let code = prompt.deviceCode {
            // **The steps over the code, as on every sign-in** (`SetupSteps`, the owner's rule of 10 November 2026): the
            // first one's link opens the provider's page with the code copied for it, and the job goes on by itself.
            FormBlock("Sign in to \(providerName(job.runtime ?? "codex"))") {
                VStack(alignment: .leading, spacing: 12) {
                    SetupSteps.deviceCode(at: url, width: nil)
                        .environment(\.openURL, OpenURLAction { _ in copyMessage(code); NSWorkspace.shared.open(url); return .handled })
                    Text(code).font(FormMetrics.oneTimeCode).textSelection(.enabled)
                        .accessibilityIdentifier("job-code")
                }
            }
        } else if let command = prompt.terminalCommand {
            FormBlock("Sign in to Claude Code", detail: "Run this command in a terminal on \(server). Sign in with /login, then type /exit. Founderizer goes on by itself.") {
                Text(command).font(FormMetrics.code).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(FleetStyle.canvas, in: RoundedRectangle(cornerRadius: FormMetrics.inner))
                    .overlay(RoundedRectangle(cornerRadius: FormMetrics.inner).strokeBorder(FleetStyle.line, lineWidth: 0.5))
            } accessory: {
                Button(copied ? "Copied" : "Copy") { copyMessage(command); copied = true }.buttonStyle(FleetOutlineButtonStyle())
                    .accessibilityIdentifier("job-copy")
            }
        } else if prompt.kind == "signin", let agent = job.agent, let openSignIn {
            // Claude Code's sign-in is the machine's own now (`{kind: "signin", login}`, UI-API.md): the hub starts it,
            // and the agent's sign-in screen shows its page and takes its code, as it does for any sign-in.
            FormRow("Sign in to \(providerName(job.runtime ?? "claude"))", symbol: "person.crop.circle") {
                Button("Sign in") { openSignIn(agent) }.buttonStyle(FleetPrimaryButtonStyle())
                    .accessibilityIdentifier("job-sign-in")
            }
        } else {
            FormRow("The server asks for a sign-in that this app does not know.", warning: "Update the app.")
        }
    }
}
