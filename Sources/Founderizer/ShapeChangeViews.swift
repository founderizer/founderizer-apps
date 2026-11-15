import AppKit
import FleetCore
import SwiftUI

// A later change of the fleet's shape (the owner's yes of 15 November 2026 to the pictures in
// `~/dev/founderizer-plans/shape-change-later/`, "Yes, new sizes (1)", then "Yes, build it"): the slider at the top of
// Settings › Servers (picture 2), and the page that it opens (pictures 3 to 5). The rules are `ShapeChange.swift` in
// FleetCore, the run is `ShapeChangeRun.swift`.

/// **The fleet as a change of its shape reads it**: where its agents run, its manager, the plan of the boxes' names,
/// and what its hub can do.
@MainActor struct ShapeFleet {
    let places: [ShapePlace]
    let manager: String
    let plan: FleetPlan
    let hubShared: Bool
    let joins: Bool
    /// The step that the hub keeps for the fleet (`fleet_shape`), the owner's last choice; nil on a hub that keeps none.
    let kept: ServersStep?
    /// The hub keeps the step (`fleet_shape`): a change writes its step there.
    let keeps: Bool

    /// The hub's word for a move onto a server that has agents (the lane "One OS user per agent", `move_agent` (c)).
    static let joinsFeature = "agent_move_beside"
    /// The hub's word for a move at all (owner API, `agent_move`): the slider shows only with it.
    static let moveFeature = "agent_move"

    init(store: FleetStore, list: ServerList) {
        let agents = store.state?.agents ?? []
        // An agent whose provider this app's move does not take stays where it is (`HubClient.moveAgent`).
        let stays = Set(agents.filter { !["claude", "codex"].contains($0.runtime) }.map(\.name))
        places = list.servers.map { ShapePlace($0, stays: stays) }
        let manager = agents.first { $0.role == "manager" }?.name ?? "manager"
        self.manager = manager
        plan = FleetPlan(manager: manager.agentLabel, agents: agents.filter { $0.name != manager }
            .map { FleetPlan.Agent(name: $0.name, role: $0.name.agentLabel) })
        hubShared = list.hub_shared == true
        joins = store.state?.ui_features?.contains(Self.joinsFeature) == true
        keeps = store.state?.ui_features?.contains(FleetShapeHub.kept) == true
        kept = keeps ? list.keptStep : nil
    }

    /// The step where the fleet stands now; nil between two steps. A tie (the manager alone on its server) takes the
    /// step that the hub keeps, the owner's last choice, and the first run's default on a hub that keeps none: the first
    /// run's choice on this Mac has no hub in its name, so it is not read here.
    var now: ServersStep? { ServersStep.now(places, kept: kept) }

    /// **The hub keeps the step** (`POST /ui/servers/shape`), on a hub that does: after a change, and when he lets go
    /// of the knob on a step that changes no server (a tie). A team.json that changed meanwhile is read again once.
    /// It never stops a change: a step that the hub could not keep leaves the fleet as it is.
    @MainActor @discardableResult static func keep(_ step: ServersStep, store: FleetStore) async -> Bool {
        guard store.state?.ui_features?.contains(FleetShapeHub.kept) == true else { return false }
        for _ in 0..<2 {
            guard let database = store.state?.db,
                  let team = try? await HubClient().team(hub: store.hub, database: database) else { return false }
            do {
                _ = try await HubClient().keepShape(hub: store.hub, database: database, client: store.installation,
                                                    sha256: team.sha256, step: step)
                return true
            } catch HubError.refusal(409, _) {
                continue
            } catch {
                return false
            }
        }
        return false
    }

    func change(to step: ServersStep) -> ShapeChangePlan {
        ShapeChange.plan(places, manager: manager, to: step, hubShared: hubShared, joins: joins)
    }

    /// The words under each step: its servers, and its Macs.
    var counts: [String] {
        var counts = ServersStep.allCases.map { step in
            let boxes = change(to: step).boxes
            return FleetCount(servers: boxes.filter { !$0.mac }.count, macs: boxes.filter(\.mac).count).words
        }
        // The manager alone: the last two steps make the same servers today, and differ when the next agent comes.
        if counts[1] == counts[2] { counts[2] = ServersSketch.words(.each) }
        return counts
    }
}

/// **The slider at the top of Settings › Servers** (picture 2): in a card of its own over the servers, its knob on the
/// step where the fleet stands now, its counts the fleet's own. When he lets go of the knob on another step, the page of
/// that change opens (`ShapeChangePage`); nothing changes before its press. While a change runs, letting go opens it.
struct ShapeServersCard: View {
    @Bindable var store: FleetStore
    let list: ServerList
    @State private var step = ServersStep.two

    /// The card shows on a hub that moves agents, in a fleet with an agent that the slider moves.
    static func shows(_ store: FleetStore, _ list: ServerList) -> Bool {
        store.state?.ui_features?.contains(ShapeFleet.moveFeature) == true && list.servers.contains { !$0.isMac && !$0.agents.isEmpty }
    }

    var body: some View {
        let fleet = ShapeFleet(store: store, list: list)
        ServersSlider(step: $step, counts: fleet.counts, settled: { chosen in
            let plan = fleet.change(to: chosen)
            if ShapeChangeRun.current?.hub == store.hub {
                store.destination = .shapeChange(chosen)
            } else if chosen != fleet.now, fleet.keeps, !plan.changes, plan.blocked == nil, plan.newServers == 0 {
                // A step that changes no server (the manager alone on its server): the hub keeps his choice, and no
                // page opens.
                // A step that the hub did not keep: the knob goes back to where the fleet stands.
                Task { if await !ShapeFleet.keep(chosen, store: store) { step = fleet.now ?? .two } }
            } else if chosen != fleet.now {
                store.destination = .shapeChange(chosen)
            }
        })
        .frame(width: ShapeMetrics.serversWidth)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(FleetStyle.surface, in: RoundedRectangle(cornerRadius: FormMetrics.radius))
        .overlay(RoundedRectangle(cornerRadius: FormMetrics.radius).strokeBorder(FleetStyle.line, lineWidth: 0.5))
        .accessibilityIdentifier("servers-shape")
        // The knob stands where the fleet stands, also when he comes back from a change that he did not press.
        .onAppear { step = fleet.now ?? .two }
        .onChange(of: fleet.now) { _, now in step = now ?? step }
    }
}

/// **The page of a change** (pictures 3 to 5): the first run's page "Your fleet's servers", on the step where he let go
/// of the knob. The card reads as on the first run: the step's headline, the servers after the change, what it risks.
/// Under it, who signs in again, what the new servers cost at the provider in one quiet line, and the one press, which
/// says what it makes. A change that the hub cannot do yet has one muted line in the press's place. While the change
/// runs (`ShapeChangeRun`), the page has no slider and no Back: its title says what goes on, in moving words with a
/// count, or what waits for him, with its one press. A stop is one orange line and Try again.
struct ShapeChangePage: View {
    @Bindable var store: FleetStore
    @State private var chosen: ServersStep
    @State private var list: ServerList?
    /// The offer of the provider whose token this Mac holds, for the price; nil while it is read, and when none is held.
    @State private var offer: CloudOffer?
    @State private var run: ShapeChangeRun?

    init(store: FleetStore, step: ServersStep) {
        self.store = store
        _chosen = State(initialValue: step)
    }

    var body: some View {
        SetupPage {
            if run == nil { SetupBack { store.closeWizard() } }
        } step: {
            if let run {
                running(run)
            } else if let list {
                choosing(ShapeFleet(store: store, list: list))
            } else {
                SetupStep(title: String(l10n: "Your fleet's servers"), waits: true) { mark }
            }
        }
        .task(id: store.hub) { await read() }
        .onChange(of: run?.phase) { _, phase in
            if phase == .done { store.closeWizard() }
        }
        // A change that stopped goes when he leaves its page: the slider is his again, and a server that it made and
        // left empty is the next change's to use.
        .onDisappear {
            if let run, run.stopped, ShapeChangeRun.current === run { ShapeChangeRun.current = nil }
        }
    }

    private var mark: some View { IconTile(symbol: "server.rack", size: SetupMetrics.mark).accessibilityHidden(true) }

    // MARK: Before the press

    @ViewBuilder private func choosing(_ fleet: ShapeFleet) -> some View {
        let plan = fleet.change(to: chosen)
        SetupStep(title: String(l10n: "Your fleet's servers"), width: ShapeMetrics.serversWidth,
                  detail: String(l10n: "Fewer servers cost less. More servers keep your agents apart.")) { mark } content: {
            ServersSlider(step: $chosen, counts: fleet.counts).padding(.top, 6)
            card(fleet.plan, plan, risk: true)
            if plan.changes {
                if let blocked = plan.blocked {
                    Text(Self.words(blocked)).foregroundStyle(FleetStyle.muted).fixedSize(horizontal: false, vertical: true)
                } else if plan.newServers > 0, offer == nil, Self.holdsProvider {
                    // The price comes before the press that pays for it.
                    EmptyView()
                } else if plan.newServers > 0, !Self.holdsProvider {
                    // A new server needs the provider's token, which Add server asks for once.
                    Text(String(l10n: "Make one server with Add server first: Founderizer then holds your provider's key."))
                        .foregroundStyle(FleetStyle.muted).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(Self.signIns(plan.signIns)).foregroundStyle(FleetStyle.text)
                    SetupAction {
                        VStack(spacing: 10) {
                            if plan.newServers > 0, let offer {
                                Text(String(l10n: "\(Self.newServers(plan.newServers)) · \(offer.monthly(times: plan.newServers))"))
                                    .font(ShapeMetrics.riskFont).foregroundStyle(FleetStyle.muted)
                            }
                            // No Return for a press that buys servers: a Return held since the slider would press it.
                            Button(Self.press(plan)) { start(plan) }
                                .buttonStyle(FleetPrimaryButtonStyle())
                                .accessibilityIdentifier("shape-change-press")
                        }
                    }
                }
            }
        }
    }

    // MARK: While it runs

    @ViewBuilder private func running(_ run: ShapeChangeRun) -> some View {
        switch run.phase {
        case .making(let number, let count):
            SetupStep(title: String(l10n: "Making a server · \(number) of \(count)"), waits: true,
                      width: ShapeMetrics.serversWidth) { mark } content: { card(run) }
        case .moving(let agent, let number, let count):
            SetupStep(title: String(l10n: "Moving \(agent.agentLabel) · \(number) of \(count)"), waits: true,
                      width: ShapeMetrics.serversWidth) { mark } content: { card(run) }
        case .signIn(let agent):
            SetupStep(title: String(l10n: "\(agent.agentLabel) needs your sign-in"), width: ShapeMetrics.serversWidth) { mark } content: {
                card(run, waits: [agent: .attention(String(l10n: "Sign-in needed"))])
                // The install's own element, as Add agent shows it: the sign-in that this provider asks for there.
                if let waiting = run.waitingJob {
                    ServerJobView(job: waiting.job, server: waiting.server, retry: nil,
                                  openSignIn: { store.destination = .signIn($0) })
                        .multilineTextAlignment(.leading)
                }
            }
        case .stopped(let why):
            SetupStep(title: String(l10n: "The change stopped"), width: ShapeMetrics.serversWidth) { mark } content: {
                card(run)
                SetupWarning(why)
                SetupAction {
                    // No Return: Try again can make a server, which costs money.
                    Button("Try again") { run.start(store: store) }
                        .buttonStyle(FleetPrimaryButtonStyle())
                }
            }
        case .done:
            SetupStep(title: String(l10n: "Your fleet's servers"), width: ShapeMetrics.serversWidth) { mark } content: { card(run) }
        }
    }

    private func card(_ run: ShapeChangeRun, waits: [String: AgentPresence] = [:]) -> some View {
        card(list.map { ShapeFleet(store: store, list: $0).plan } ?? FleetPlan(manager: "", agents: []), run.shown,
             risk: false, later: run.later, waits: waits)
    }

    /// The card of the first run's page: the step's headline, the servers, and what the step risks.
    private func card(_ names: FleetPlan, _ plan: ShapeChangePlan, risk: Bool, later: Set<String> = [],
                      waits: [String: AgentPresence] = [:]) -> some View {
        VStack(spacing: 16) {
            if risk { Text(plan.step.fact).font(ShapeMetrics.headlineFont).foregroundStyle(FleetStyle.text) }
            ServerBoxes(plan: names, step: plan.step, change: plan, later: later, waits: waits)
            if risk {
                Text(plan.step.risk).font(ShapeMetrics.riskFont).foregroundStyle(FleetStyle.muted).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: ShapeMetrics.riskHeight, alignment: .top)
            }
        }
        .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, risk ? 12 : 20)
        .frame(maxWidth: .infinity)
        .background(FleetStyle.surface, in: RoundedRectangle(cornerRadius: FormMetrics.radius))
        .overlay(RoundedRectangle(cornerRadius: FormMetrics.radius).strokeBorder(FleetStyle.line, lineWidth: 0.5))
        .environment(\.glyphTeam, store.state?.agents.map(\.name) ?? []).environment(\.onCard, true)
    }

    // MARK: Reads and the press

    /// The hub's list, and the offer of the provider whose token this Mac holds. A change that runs for this hub is
    /// the page's at once.
    private func read() async {
        if let current = ShapeChangeRun.current, current.hub == store.hub { run = current }
        if let database = store.state?.db { list = try? await HubClient().servers(hub: store.hub, database: database) }
        guard let provider = CloudProvider.allCases.first(where: { CloudServers(provider: $0).isHeld }) else { return }
        while offer == nil, !Task.isCancelled {
            offer = try? await CloudServers(provider: provider).offer(use: .agent)
            if offer == nil { try? await Task.sleep(for: .seconds(10)) }
        }
    }

    private func start(_ plan: ShapeChangePlan) {
        let run = ShapeChangeRun(hub: store.hub, plan: plan)
        ShapeChangeRun.current = run
        self.run = run
        run.start(store: store)
    }

    /// This Mac holds a server provider's token, with which the change makes its servers.
    static var holdsProvider: Bool {
        CloudProvider.allCases.contains { CloudServers(provider: $0).isHeld } && TailscaleFleetKey().isHeld
    }

    // MARK: Words

    static func words(_ blocked: ShapeChangePlan.Blocked) -> String {
        switch blocked {
        case .joins: String(l10n: "Founderizer cannot put agents together on one server yet.")
        case .hubTakesNone: String(l10n: "The hub's own server takes no agents in this fleet.")
        case .empties: String(l10n: "Founderizer cannot delete a server yet.")
        }
    }

    static func signIns(_ agents: [String]) -> String {
        let names = agents.map(\.agentLabel)
        return names.count == 1 ? String(l10n: "\(names[0]) signs in again.")
            : String(l10n: "\(ListFormatter.localizedString(byJoining: names)) sign in again.")
    }

    static func newServers(_ count: Int) -> String {
        count == 1 ? String(l10n: "1 new server") : String(l10n: "\(count) new servers")
    }

    static func press(_ plan: ShapeChangePlan) -> String {
        let moves = plan.moves.count
        switch (plan.newServers, moves) {
        case (0, 1): return String(l10n: "Move 1 agent")
        case (0, _): return String(l10n: "Move \(moves) agents")
        case (1, 1): return String(l10n: "Make 1 server and move 1 agent")
        case (1, _): return String(l10n: "Make 1 server and move \(moves) agents")
        default: return String(l10n: "Make \(plan.newServers) servers and move \(moves) agents")
        }
    }
}
