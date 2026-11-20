import FleetCore
import SwiftUI

/// **Take over** (owner feature `need_takeover`, API 1.217; the owner's "Yes, as drawn" of 16 November 2026 to the
/// pictures of `superbot-ideas/02-take-over-design.md`): the button of an agent's request for one step on its own
/// screen, at the right of the title of its card and under the title of its step on Needs you. Its press opens that
/// agent's machine in Screen Sharing through this Mac's SSH tunnel, as the machine's page does
/// (`MachineAccessButtons`), and it shows a spinner while it connects. It looks as Run does on a command
/// (`NeedRunViews`): one kind of action on a card, one look.
struct NeedTakeOverButton: View {
    let need: Int
    let connection: ScreenSharingConnection
    let press: () -> Void
    private var screen: ScreenSharingSession { .shared }

    var body: some View {
        let busy = screen.busy.contains(connection)
        Button(action: press) {
            HStack(spacing: 5) {
                if busy {
                    ProgressView().controlSize(.mini).frame(width: 10, height: 10)
                } else {
                    Image(systemName: "display").font(IconMetrics.symbol(10, weight: .semibold))
                }
                Text("Take over")
            }
            .font(FormMetrics.detail).foregroundStyle(FleetStyle.text).lineLimit(1).fixedSize()
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(FleetStyle.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(FleetStyle.hairline(0.16), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel(Text("Take over"))
        .accessibilityIdentifier("need-takeover-\(need)")
    }
}

/// What went wrong with a press of Take over on this view, in the orange line of a card's small size and the words of
/// the machine's page. Only after a press here: an error of the same machine from another press is that place's.
struct NeedTakeOverLine: View {
    let connection: ScreenSharingConnection
    let pressed: Bool

    var body: some View {
        if pressed, let detail = ScreenSharingSession.shared.errors[connection] {
            Text(detail).font(FormMetrics.detail).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension OwnerNeed {
    /// The Screen Sharing way to the machine of the agent that asks, on an open take-over whose machine has one, from
    /// the machines' readings that the store keeps (`FleetStore.runMachines`); for an agent on a Linux server, the way
    /// to the screen of its own browser there (`FleetStore.linuxTakeOverWay`); nil on every other item.
    @MainActor func takeOverWay(in store: FleetStore) -> ScreenSharingConnection? {
        guard isOpen, asksForTakeover else { return nil }
        // an agent on a Linux server has only the way to its own browser's screen, also where team.json names a Screen
        // Sharing way to that server: such a way goes to the server's 5900, which no password and no rule guard there
        if store.onLinuxServer(by) { return store.linuxTakeOverWay(of: by) }
        return store.runMachines?.first { $0.agent == by }?.screenSharingConnection
    }
}

extension FleetStore {
    /// The machines' readings for a take-over's card: read once, and a few times more while no reading came (a
    /// count, not a clock: the card then shows no Take over, and he answers in words).
    func readTakeOverMachines() async {
        await readRunMachines()
        await readTakeOverServers()
        var tries = 0
        let servers = state?.ui_features?.contains(TakeOverLinux.feature) == true
        while runMachines == nil || (servers && takeOverServers == nil), tries < 3 {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }      // the card went away
            tries += 1
            await readRunMachines(now: true)
            if servers && takeOverServers == nil { await readTakeOverServers() }
        }
    }

    /// The hub's list of servers for a take-over's card, where the hub opens a Linux agent's screen (build plan 04,
    /// S6): the server's own reading names the agent's screen-sharing port.
    func readTakeOverServers() async {
        guard let state, state.ui_features?.contains(TakeOverLinux.feature) == true else { return }
        let hub = hub, database = state.db
        guard let list = try? await HubClient().servers(hub: hub, database: database), self.hub == hub,
              self.state?.db == database else { return }
        takeOverServers = list.servers
    }

    /// Whether this agent runs on a Linux server (build plan 04, S6; `TakeOverLinux.onLinuxServer`).
    func onLinuxServer(_ agent: String) -> Bool {
        TakeOverLinux.onLinuxServer(agent, servers: takeOverServers,
                                    systemName: runMachines?.first(where: { $0.agent == agent })?.os.name)
    }

    /// **The way to a Linux agent's screen** (build plan 04, S6): the hub opens it (`takeover_linux`), the agent's
    /// server reads its screen-sharing port, and this Mac reaches that server as root, with the connection that it
    /// keeps from an install or the fleet's own record of the server (`ServerRecords.target`). nil otherwise: the card
    /// then has no Take over, and he answers in words.
    func linuxTakeOverWay(of agent: String) -> ScreenSharingConnection? {
        guard state?.ui_features?.contains(TakeOverLinux.feature) == true,
              TakeOverLinux.helperReady(runMachines?.first(where: { $0.agent == agent })),
              let server = takeOverServers?.first(where: { $0.agents.contains(agent) }),
              let port = server.screenPort(of: agent),
              let target = ServerRecords.target(server, kept: InstallTargets.target(machine: server.name, hub: hub),
                                                record: ServerRecords.held(of: server, machines: runMachines ?? [],
                                                                           own: nil)) else { return nil }
        return .linux(target: target, port: port, agent: agent)
    }

    /// His press of Take over: the machines' readings again, so the press uses the address of now, then Screen Sharing
    /// of the asking agent's machine, while the item is still open. A tunnel that a press of Take over opened is
    /// closed when its items are answered (`closeAnsweredTakeOvers`); one that he opened before, from the machine's
    /// page, stays as he opened it.
    func takeOver(_ need: OwnerNeed) async {
        await readRunMachines(now: true)
        await readTakeOverServers()     // the server and its address of now, as the machines' (S6)
        guard let now = state?.needs.first(where: { $0.id == need.id }), let way = now.takeOverWay(in: self) else {
            return          // answered meanwhile, or its machine has no way in now
        }
        let screen = ScreenSharingSession.shared
        let ours = !screen.opened.contains(way) || takeOvers.values.contains(way)
        // A Linux agent's screen (S6): the hub has its server share it with a new one-time password at each press, for
        // this agent and this port only.
        var secret: (@MainActor () async throws -> String)?
        if let agent = way.agent, let database = state?.db {
            let hub = hub, installation = installation
            let server = takeOverServers?.first(where: { $0.agents.contains(agent) })?.name
            secret = { @MainActor in
                let opened = try await TakeOverClient().takeOverScreen(hub: hub, database: database, need: need.id,
                                                                       client: installation)
                // the screen that the hub opened is the one that this tunnel reaches: its agent, its server, its port
                guard opened.opens(agent: agent, server: server, port: way.remotePort) else {
                    throw HubError.invalidResponse
                }
                return opened.password
            }
        }
        await screen.open(way, secret: secret)
        if ours, screen.opened.contains(way) { takeOvers[need.id] = way }
    }

    /// The tunnels that a press of Take over opened, for items that the reading shows answered or gone (the design's
    /// R3: the way in closes at his answer), wherever he answered: in a card, on Needs you, on the iPhone, in a chat app.
    /// A record whose tunnel closed another way (Disconnect on the machine's page, a lost link) is dropped first, so
    /// that a tunnel he opened again from the machine's page stays; and a tunnel that another open take-over of the
    /// same machine still uses stays until that one is answered too.
    func closeAnsweredTakeOvers() {
        guard !takeOvers.isEmpty, let needs = state?.needs else { return }
        let screen = ScreenSharingSession.shared
        takeOvers = takeOvers.filter { screen.opened.contains($0.value) }
        let answered = takeOvers.filter { record in needs.first(where: { $0.id == record.key })?.isOpen != true }
        for id in answered.keys { takeOvers[id] = nil }
        for way in Set(answered.values) where !takeOvers.values.contains(way) {
            Task { await screen.close(way) }
        }
    }
}
