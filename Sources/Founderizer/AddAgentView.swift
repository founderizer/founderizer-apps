import AppKit
import FleetCore
import FleetMark
import FleetOwnerAPI
import Observation
import SwiftUI

/// Add agent (owner feature `servers`): **first its name and its AI, then the server** (the owner, 16 November 2026: "agent
/// onboarding should ask first for the name and AI provider before the server page", and his choice of the same day
/// that the manager's own setup asks in that order too). Until then the server came first (the owner, 7 November 2026:
/// "Why doesn't it ask me first if I want to use an existing server or a new one?!"). A server with agents takes one
/// more (the owner, 3 November 2026: "we allow multiple agents per server"). The hub registers the agent, inactive and
/// with no credential access, as a worker that reports to the manager, and the server's service installs it: the AI he
/// pressed when the server has none, the agent's checkout and service, and the AI's sign-in when the server is not
/// signed in. Nothing installs before his press on a server, or on an AI when the form came with its server (a
/// server's own page, Add server's end). New server keeps his name and his AI, and the server that it makes gets the
/// agent by itself (`goOn`). The model stays while other pages show, so the install's progress goes on.
@MainActor @Observable
final class AddAgentModel {
    var server: String?
    /// **What he pressed on the first step**: an AI on a plan, by its runtime, or a provider after Other models, whose
    /// key, address and model `other` keeps. The server step shows while it is set.
    enum Choice: Equatable {
        case plan(String)
        case account(ModelProvider)
    }
    var choice: Choice?
    /// The form came with its server (a server's own page, or Add server's end): it has no server step, and the press on
    /// an AI adds the agent there.
    private(set) var given = false
    /// The server that Add agent's New server made, for the choice that he made before it: the view adds the agent
    /// there by itself (`goOn`), once.
    var startsOn: String?
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
    /// **The pages after Other models** (the AI providers build): the page he is on, and Back goes one page back.
    let other = OtherModels()

    /// The install goes on, or waits for the owner's sign-in.
    var running: Bool { receipt != nil && (job == nil || job?.isOpen == true) }
    var selected: ServerEntry? { list?.servers.first { $0.name == server } }

    /// A form with no install, or an install that ended in success: a new form, on its first step, the name and the AI,
    /// with the server that a server's page gave or with none. A failed install stays for Try again, unless its agent
    /// has left the fleet (`listed`: the agents the hub lists now), which he deleted: that install is over.
    func prepare(server: String?, listed: [String]? = nil) {
        if let receipt, let listed, !listed.contains(receipt.agent) { forget() }
        if job?.state == "done" || job?.state == "canceled" { reset() }
        guard receipt == nil else { return }
        self.server = server
        given = server != nil
        choice = nil; startsOn = nil
        error = nil
        // A name that an agent has now (a Mac that New server made took it as its first agent) makes way for a new
        // suggestion.
        if let listed, listed.contains(key) { name = "" }
        // A new form starts at its own step: the pages after Other models of a visit before are gone.
        other.leave()
    }

    /// **The server that Add agent's New server made**, for the name and the AI that he chose before it: the agent goes
    /// there by itself (`startsOn`), as his press on that server would add it. With no choice, a new form for that
    /// server.
    func goOn(on server: String, listed: [String]? = nil) {
        guard receipt == nil, choice != nil else { prepare(server: server, listed: listed); return }
        self.server = server; given = true; error = nil
        startsOn = server
    }

    /// His press on the first step: the AI, or the last page after Other models.
    func choose(_ chosen: Choice) { choice = chosen; error = nil }

    /// Back from the server step: the first step, or the last page after Other models, as he left it.
    func unchoose() {
        choice = nil; error = nil
        if !given { server = nil }
    }

    /// The name and the AI, with the name's own problem only: the server is the next step.
    var nameProblem: String? { Servers.agentNameProblem(name: key, existing: team?.lines.map(\.agent) ?? []) }

    /// **His own model server at a loopback address with no key**: only an agent alone on its server reaches it, so the
    /// server step offers only a server with no agent (`Servers.offered`).
    var alone: Bool { choice == .account(.own) && other.secret == nil }

    func reset() {
        guard !running else { return }
        forget()
    }

    /// A new form, whatever the last install did.
    private func forget() {
        watch?.cancel(); watch = nil
        receipt = nil; job = nil; error = nil; name = ""; server = nil; given = false; choice = nil; startsOn = nil
        role = "worker"; reportsTo = nil
        other.leave()
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

    /// The servers of the server step: those that can take the agent with the AI that he chose.
    var offered: [ServerEntry] { Servers.offered(open, onAccount: onAccount, alone: alone) }

    /// **The agent that New server is for**: its name and its AI on a plan, or no AI for a provider after Other models
    /// (`AddServerView.newAgent`). nil while he chose nothing, and while an install of this form stands.
    var newServerAgent: AddServerView.NewAgent? {
        guard receipt == nil, let choice else { return nil }
        switch choice {
        case .plan(let runtime): return .init(name: key, ai: runtime == ServerAI.chatGPT.runtime ? .chatGPT : .claude)
        case .account: return .init(name: key, ai: nil)
        }
    }

    /// He chose a provider after Other models.
    var onAccount: Bool { if case .account? = choice { return true }; return false }

    /// Why Add agent cannot go now, or nil.
    var problem: String? {
        Servers.agentProblem(name: key, server: selected, existing: team?.lines.map(\.agent) ?? [])
    }

    /// The agent on the chosen server with `runtime`, the AI he pressed.
    func start(store: FleetStore, runtime chosen: String) async {
        guard !busy, let server, let database = store.state?.db else { return }
        // The name or the server changed since his press (another agent took the name, the server can take none now):
        // why, where he pressed.
        if let problem { error = problem; return }
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
            } catch let HubError.refusal(refused) {
                if refused.status == 409, attempt == 0, refused.means(.teamChanged) { continue }
                error = refused.words; return
            } catch { self.error = String(l10n: "The hub has not answered. Look at the server's page before you try again."); return }
        }
    }

    /// **The agent on an account with a kind, in the order of spec 3.1** (the key is in the vault already, by the
    /// vault's own form): the account, then the agent with it, then the agent's read grant of the key, which this Mac
    /// signs as it signs each grant. Nil when the agent is added; else the line for the last page, in the app's own
    /// words for a refusal whose code it knows (round 2, sentences 4, 6, 7 and 8).
    func start(store: FleetStore, provider: ModelProvider, secret: String?, address: String?, model: String?) async -> String? {
        guard !busy, let server, let database = store.state?.db else { return nil }
        if let problem {
            if given { other.leave(); choice = nil }
            error = problem; return ""
        }
        busy = true; error = nil
        defer { busy = false }
        let name = key, hub = store.hub
        runtime = provider.runtime; role = "worker"; reportsTo = nil
        // A change of team.json elsewhere between the read and the request: read it again, and send once more.
        for attempt in 0..<2 {
            do {
                let team = try await HubClient().team(hub: hub, database: database)
                self.team = team
                let id = other.account ?? provider.accountID(agent: name, taken: Set((team.accounts ?? [:]).keys))
                other.account = id
                let entry = TeamAccount(provider: provider.rawValue, title: provider.title, kind: provider.kind, secret: secret,
                                        address: address, model: model)
                let saved = try await HubClient().saveModelAccount(hub: hub, database: database, client: store.installation,
                                                                   sha256: team.sha256, id: id, entry: entry)
                receipt = try await HubClient().addServerAgent(hub: hub, database: database, client: store.installation,
                                                               server: server, sha256: saved, agent: name, account: id)
                job = nil
                watchJob(store: store)
                if let secret {
                    // The grant needs the agent, so it comes after it (`ModelAccountGrant`: signed first, then the
                    // hub's). One that fails leaves the agent added: its check then says that the vault gave no key, and
                    // Try again on its setup page gives the grant again before it asks for the check (review M4).
                    try? await ModelAccountGrant.give(secret, to: name, store: store, hub: hub, database: database)
                }
                await store.refresh()
                return nil
            } catch let HubError.refusal(refused) {
                if refused.status == 409, attempt == 0, refused.means(.teamChanged) { continue }
                // **Sentence 3 stands where he chose the server** (round 2, item 14), where Add agent shows a refusal
                // of the server: on the server step, with his choice kept; on the first step for a form that came with
                // its server, where the pages after Other models go ("" to the page).
                if refused.isOpenServer {
                    if given { other.leave(); choice = nil }
                    error = refused.words; return ""
                }
                return refused.words
            } catch { return String(l10n: "The hub has not answered. Look at the server's page before you try again.") }
        }
        return nil
    }

    /// The install again, after a failure: the same agent, server and provider.
    func retry(store: FleetStore, server: ServerEntry, job: ServerJob) async {
        guard let agent = job.agent, let runtime = job.runtime else { return }
        let role = team?.lines.first { $0.agent == agent }?.role ?? "worker"
        self.server = server.name; given = true; choice = .plan(runtime); name = agent; self.runtime = runtime
        self.role = role == "lead" ? "lead" : "worker"
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
        } catch let HubError.refusal(refused) { error = refused.words }
        catch { self.error = String(l10n: "The hub has not answered. Try again.") }
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
    /// This view's own mark for the page that it tells the store (`WizardPages.tell`, `gone`).
    @State private var placeMark = UUID()

    var body: some View {
        Group {
            if !(store.state?.ui_features?.contains(Servers.feature) == true) {
                FleetPage("Add agent") {
                    FormSection { FormEmpty("Update the Founderizer hub to add agents on servers.", symbol: "arrow.triangle.2.circlepath") }
                }
            } else if let receipt = model.receipt, !handingOff {
                FleetPage("Add agent") { progress(receipt) }
            } else if model.choice == nil, model.other.page != nil {
                // The pages after Other models, under their own marks and titles.
                OtherModelsPages(store: store, model: model, add: chooseAccount, adding: model.busy || handingOff)
            } else {
                step
            }
        }
        // Its first page, the name and the AI (or the hub's line that it cannot add agents): Esc closes the wizard there.
        .preference(key: SetupFirstPage.self, value: model.receipt == nil && model.choice == nil && model.other.page == nil
                    && !model.busy && !handingOff)
        .onChange(of: placeStep, initial: true) { _, now in store.wizardPages.tell(addAgent: now, by: placeMark) }
        .onDisappear { store.wizardPages.gone(placeMark) }
        // **The server that New server made gets the agent by itself** (`AddAgentModel.goOn`): he chose its name and its
        // AI, and then that new server.
        .task(id: model.startsOn) {
            guard model.startsOn != nil else { return }
            model.startsOn = nil
            add()
        }
        .task(id: "\(store.hub)/\(store.state?.db ?? "")") {
            while !Task.isCancelled {
                if model.receipt == nil { await model.read(store: store) }
                do { try await store.nap(10) } catch { return }
            }
        }
    }

    /// The step by its fixed name (`AppPlace`, `setup_state`'s `place`): nil on the hub's line that it cannot add agents,
    /// and **nil on the pages after Other models** (review M5): a key, an address or a model is typed there, so the
    /// owner's own agent reads "add_agent" (the page is not known) and never takes such a page for the name step.
    private var placeStep: AppPlace.AddAgentStep? {
        guard store.state?.ui_features?.contains(Servers.feature) == true else { return nil }
        if model.receipt != nil || model.busy || handingOff { return .progress }
        if model.choice == nil, model.other.page != nil { return nil }
        return model.choice == nil ? .name : .server
    }

    /// **Add agent is two centred steps under one mark and one title** (D-3 of 28 October 2026, and the owner's yes of
    /// 7 November 2026 to the mockup): the new agent's glyph and "Add agent" stay over both, and under them first its
    /// name and its AI, then the servers (the owner, 16 November 2026: "agent onboarding should ask first for the name
    /// and AI provider before the server page"). It is a worker that reports to the manager, which Settings › Reporting
    /// lines changes.
    private var step: some View {
        let list = model.list ?? store.reading("servers.list")
        let team = store.state?.agents.map(\.name) ?? []
        let adding = model.busy || handingOff
        // Back from the servers to its name and its AI stands at the page's top left, where every setup page has it.
        return SetupPage {
            if !handingOff, list != nil, model.choice != nil, !model.given, !model.busy {
                SetupBack { model.unchoose() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("add-agent-back")
            }
        } step: {
            SetupStep(title: adding ? String(l10n: "Adding \(model.name)") : String(l10n: "Add agent"), waits: adding) {
                // The glyph it will wear: its name, at the end of the hub's list.
                AgentGlyph(name: model.key, size: SetupMetrics.mark).environment(\.glyphTeam, team + [model.key])
            } content: {
                // **While it adds and hands over, the moving title alone** (fix round 3b): the server it took was busy
                // with it, and "No free server." with a white Add server stood under "Adding Juno" for a frame.
                if !handingOff, list != nil {
                    if model.choice == nil { naming } else if !adding, !model.given { servers }
                }
            }
        }
    }

    // MARK: two: where it runs

    /// **A card for each server that can take one more agent with the AI that he chose**, the one with the fewest agents
    /// first, with its agents' glyphs (the owner, 7 November 2026: "agents should always come with their icon"), then
    /// **New server**, which opens Add server and keeps his name and his AI for the server that it makes. Only New
    /// server while no server can take one. The press on a server adds the agent there. What the hub refused stands
    /// under the cards.
    @ViewBuilder private var servers: some View {
        VStack(spacing: 10) {
            ForEach(model.offered) { server in
                card(symbol: server.symbol, title: server.name, help: server.agents.count > 2 ? People.agentWords(server.agents) : nil) {
                    place(on: server.name)
                } trailing: {
                    agents(server.agents)
                }
                .accessibilityLabel("\(server.name), \(People.agentWords(server.agents))")
                .accessibilityIdentifier("add-agent-server-\(server.name)")
            }
            card(symbol: "plus", title: String(l10n: "New server"), help: nil) { addServer() } trailing: { EmptyView() }
                .accessibilityIdentifier("add-agent-add-server")
        }
        if let error = model.error { SetupWarning(error) }
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

    // MARK: one: its name and its AI

    /// **Its name, then a card for each AI: the press on one goes on to the servers** (the owner, 16 November 2026), or
    /// adds the agent with that AI on the server that the form came with (the owner, 7 November 2026: "I just chose Juno
    /// and it installed claude code??! why?? it should have asked me first"). The field holds a name already, and Return
    /// in it adds nothing. The AIs are Add server's, in its cards' look.
    @ViewBuilder private var naming: some View {
        // The server's own problem waits for the server step, unless the form came with its server.
        let problem = model.given ? model.problem : model.nameProblem
        SetupField(placeholder: String(l10n: "Agent name"), text: $model.name, wrong: !model.name.isEmpty && problem != nil) {}
            .accessibilityIdentifier("add-agent-name")
        if let error = model.error ?? (model.name.isEmpty ? nil : problem) {
            SetupWarning(error)
        }
        // Only once it can go: no grey card (the owner: "dont show the send button if it's not clickable").
        if !model.busy && problem == nil && store.canWrite {
            VStack(spacing: 10) {
                ForEach(ServerAI.linuxChoices, id: \.self) { ai in
                    let line = model.selected?.isMac == true ? ai.macLine : ai.linuxLine
                    card(logos: ai.logos, title: ai.title, help: line) { choose(.plan(ai.runtime)) }
                        .accessibilityHint(line)
                        .accessibilityIdentifier("add-agent-ai-\(ai.rawValue)")
                }
                // **Other models** (picture 1, his "Yes, as shown"): under Claude and ChatGPT, in their cards' look, where
                // the hub takes such an agent; on a form that came with its server, only for a Linux server that the hub
                // says takes one. A Mac server keeps its two cards, and the server step offers only servers that take one.
                if !model.given || model.selected?.takesModelAccounts == true,
                   store.state?.ui_features?.contains(ModelProvider.feature) == true {
                    let line = String(l10n: "With an API key, or on your own model server.")
                    card(mark: "ellipsis", title: String(l10n: "Other models"), help: line) { model.other.open(.choices) }
                        .accessibilityHint(line)
                        .accessibilityIdentifier("add-agent-ai-other")
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
                // A server's name cut in the middle: names of one fleet share their start ("hel1-worker-…").
                Text(title).font(SetupMetrics.choiceFont).foregroundStyle(FleetStyle.text).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                trailing()
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(FleetCardButtonStyle())
        .help(help ?? "")
    }

    /// An AI's card whose mark is a symbol (Other models): in a 28-point square, as a logo stands, so its card has the
    /// height of the cards over it.
    private func card(mark symbol: String, title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(IconMetrics.symbol(18)).foregroundStyle(FleetStyle.text)
                    .frame(width: 28, height: 28).accessibilityHidden(true)
                Text(title).font(SetupMetrics.choiceFont).foregroundStyle(FleetStyle.text)
                Spacer(minLength: 8)
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(FleetCardButtonStyle())
        .help(help)
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

    /// **His press on an AI, or on the last page after Other models**: the server step is next, or, on a form that came
    /// with its server, the agent is added there.
    private func choose(_ chosen: AddAgentModel.Choice) {
        model.choose(chosen)
        if model.given { add() }
    }

    private func chooseAccount(_ provider: ModelProvider) { choose(.account(provider)) }

    /// His press on a server of the server step: the agent goes there with the AI that he chose.
    private func place(on server: String) {
        model.server = server
        add()
    }

    /// The agent on its server with what he chose.
    private func add() {
        switch model.choice {
        case .plan(let runtime)?: add(runtime: runtime)
        case .account(let provider)?: addOnAccount(provider)
        case nil: break
        }
    }

    /// **Add agent, then the agent's own page**, whose setup takes it from the install to its chat one centered step at
    /// a time (`AgentSetupWizard`). The install's rows show here only on a hub without those pages. **"Adding Juno"
    /// stays until the setup can draw** (fix round 3, item 12): the install's page showed 198 ms after it, and then the
    /// agent's page stood empty 745 ms; the setup page goes on saying it until its first reading (`FleetStore.addedAgent`).
    private func add(runtime: String) {
        Task {
            handingOff = configure != nil
            // A press while another request is on its way goes when the hub can take it, under "Adding Juno". With no
            // hub to take it, a form that came with its server shows its first step again.
            guard await store.writable() else { if model.given { model.choice = nil }; handingOff = false; return }
            await model.start(store: store, runtime: runtime)
            // What the hub refused stands where he pressed: on the server step, or on the first step of a form that came
            // with its server, whose AI he presses again there.
            if model.receipt == nil, model.given { model.choice = nil }
            handOff()
        }
    }

    /// **The agent on an account with the provider of the pages after Other models**, then its setup page, as for an
    /// agent on a plan. A refusal of the account is the last of those pages' one orange line, and that page shows again;
    /// a refusal of the server stands where he chose the server (`AddAgentModel.start`).
    private func addOnAccount(_ provider: ModelProvider) {
        let other = model.other
        Task {
            handingOff = configure != nil
            guard await store.writable() else { if model.given { model.choice = nil }; handingOff = false; return }
            let line = await model.start(store: store, provider: provider,
                                         secret: other.secretOf == provider ? other.secret : nil,
                                         address: provider == .own ? other.checkedAddress : nil,
                                         model: provider.sellsManyMakers ? provider.accountModel(other.modelName) : nil)
            // No agent: the account's refusal on the last page after Other models, with that page again; else the
            // words stand where he pressed, and a form that came with its server shows its first step again.
            guard model.receipt != nil else {
                if let line, !line.isEmpty { other.line = line; model.unchoose() }
                else if model.given { model.choice = nil }
                handingOff = false; return
            }
            handOff()
        }
    }

    /// The agent is added: its own setup page takes the window, or the install's rows on a hub without those pages.
    private func handOff() {
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
                    ShimmeringWords(text: String(l10n: "Starting")).accessibilityElement().accessibilityLabel("Starting")
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
                FormRow("Try again", detail: String(l10n: "The server checks each step again and repeats only what is missing.")) {
                    Button("Try again") { retry() }.buttonStyle(FleetPrimaryButtonStyle()).accessibilityIdentifier("job-retry")
                }
            }
        }
    }

    /// **The AI that the owner picked**, for the install of an agent on a key or a model server (his answer 12: "The
    /// name I picked"), else the program's name, as before.
    private var providerWords: String { job.provider_label.map(Servers.providerLabel) ?? providerName(job.runtime ?? "") }

    private var title: String {
        let agent = job.agent?.agentLabel ?? String(l10n: "The agent"), provider = providerWords
        if job.kind == "prepare" {
            return job.state == "done" ? String(l10n: "\(provider) is ready on \(server)") : job.state == "failed" ?
                String(l10n: "The preparation of \(provider) stopped") : String(l10n: "Preparing \(provider) on \(server)")
        }
        if job.kind == "remove" {
            return job.state == "done" ? String(l10n: "\(agent) is removed from \(server)") : job.state == "failed" ?
                String(l10n: "The removal of \(agent) stopped") : String(l10n: "Removing \(agent) from \(server)")
        }
        return job.state == "done" ? String(l10n: "\(agent) is installed on \(server)") : job.state == "failed" ? String(l10n: "The install of \(agent) stopped") :
            String(l10n: "Installing \(agent) on \(server)")
    }

    private func stepTitle(_ id: String, _ title: String) -> String {
        id == "runtime" ? String(l10n: "AI provider: \(providerWords)") : title
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
            FormBlock("Sign in to Claude Code", detail: String(l10n: "Run this command in a terminal on \(server). Sign in with /login, then type /exit. Founderizer goes on by itself.")) {
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
            FormRow("The server asks for a sign-in that this app does not know.", warning: String(l10n: "Update the app."))
        }
    }
}
