import FleetCore
import SwiftUI

/// **Take over** (owner feature `need_takeover`, API 1.217; the owner's "Yes, as drawn" of 16 November 2026 to the
/// pictures of `superbot-ideas/02-take-over-design.md`): the button of an agent's request for one step on its own
/// screen, at the right of the title of its card and under the title of its step on Needs you. **Its press opens the
/// take-over card over the window** (`TakeOverCard`; the owner's "Yes, build it" of 21 November 2026 to
/// `superbot-ideas/09-take-over-modal-design.md`): the agent's screen, through this Mac's SSH tunnel, with ✓ Done. It
/// looks as Run does on a command (`NeedRunViews`): one kind of action on a card, one look.
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

    /// His press of Take over: the machines' readings again, so the press uses the address of now, then the take-over
    /// card over the main window, while the item is still open (`TakeOverCard`). From the request's own window, the
    /// main window comes to the front and that window steps aside until the card closes; from a task's or a job's card
    /// over the window, the take-over card takes its place, and that card comes back at its close.
    func takeOver(_ need: OwnerNeed, from window: NeedWindowLink? = nil) async {
        await readRunMachines(now: true)
        await readTakeOverServers()     // the server and its address of now, as the machines' (S6)
        guard let now = state?.needs.first(where: { $0.id == need.id }), let way = now.takeOverWay(in: self) else {
            return          // answered meanwhile, or its machine has no way in now
        }
        if let card = takeOverCard, card.id == need.id, card.hub == hub, card.database == state?.db { return }
        if takeOverCard != nil { takeOverCard = nil }
        let under = detail, page = destination
        if let window {
            window.showMainWindow()
            window.stepAside()
        }
        let item = TakeOverItem(id: need.id, hub: hub, database: state?.db, agent: now.by, title: now.title, way: way,
                                window: window, detailUnder: under, page: page)
        let screen = TakeOverScreen(item: item, store: self)
        takeOverScreen = screen
        takeOverCard = item
        // after the card, so the chat under the covered card is not marked read while the take-over card covers it
        if under != nil { detail = nil }
        screen.start()
    }

    /// **The tunnel of the take-over card**: the local port of the SSH tunnel to the agent's screen and, for a Linux
    /// agent, the one-time password that the hub had its server make for this card (`takeover_linux`); the words of
    /// what went wrong otherwise. A tunnel that a take-over opened closes when its request is answered
    /// (`closeAnsweredTakeOvers`) or its card closes (`takeOverCard`); one that he opened before, from the machine's
    /// page, stays as he opened it.
    func openTakeOverScreen(_ item: TakeOverItem) async -> Result<(port: Int, password: String?), TakeOverRefusal> {
        let way = item.way
        let screen = ScreenSharingSession.shared
        let ours = !screen.opened.contains(way) || takeOvers.values.contains(way)
        // A Linux agent's screen (S6): the hub has its server share it with a new one-time password at each press, for
        // this agent and this port only.
        var secret: (@MainActor () async throws -> String)?
        if let agent = way.agent, let database = state?.db {
            let hub = hub, installation = installation, need = item.id
            let server = takeOverServers?.first(where: { $0.agents.contains(agent) })?.name
            secret = { @MainActor in
                let opened = try await TakeOverClient().takeOverScreen(hub: hub, database: database, need: need,
                                                                       client: installation)
                // the screen that the hub opened is the one that this tunnel reaches: its agent, its server, its port
                guard opened.opens(agent: agent, server: server, port: way.remotePort) else {
                    throw HubError.invalidResponse
                }
                return opened.password
            }
        }
        guard let tunnel = await screen.openTunnel(way, secret: secret) else {
            return .failure(TakeOverRefusal(text: screen.errors[way] ?? String(l10n: "The agent's screen cannot be reached.")))
        }
        if ours, screen.opened.contains(way) { takeOvers[item.id] = way }
        guard takeOverCard?.id == item.id, hub == item.hub, state?.db == item.database else {
            closeTakeOverTunnel(of: item.id)                     // the card closed while the tunnel opened
            return .failure(TakeOverRefusal(text: ""))
        }
        return .success(tunnel)
    }

    /// ✓ Done of the take-over card: the request's quick reply "Done", by the path of every answer (the outbox, its
    /// receipt and its retry), as the card's own quick reply sends it (`NeedAnswerBox.sendQuickReply`): words that he
    /// wrote in the request's box give way to it, and a press that comes while the hub cannot take it waits until it
    /// can, or until the request leaves (`waiting` tells the card at once that it waits). Nil once the hub has the
    /// answer, or once the request left meanwhile (its card then closes by the reading); otherwise the words of the
    /// card's line.
    func answerTakeOver(_ id: Int, waiting: () -> Void) async -> String? {
        if filesAreWaiting(for: Self.stageKey(need: id)) {
            return String(l10n: "A file waits in the request's answer box: answer it there.")
        }
        let before = answers[String(id)]
        answers[String(id)] = "Done"
        let hub = hub, database = state?.db
        if !canWrite { waiting() }
        while !canWrite {
            if let storageError { answers[String(id)] = before; return storageError }
            guard self.hub == hub, state?.db == database, openNeeds.contains(where: { $0.id == id }) else { return nil }
            do { try await Task.sleep(for: .milliseconds(300)) } catch {
                if answers[String(id)] == "Done" { answers[String(id)] = before }          // his words come back
                return nil
            }
        }
        guard self.hub == hub, state?.db == database else { return nil }
        guard answers[String(id)] == "Done" else { return String(l10n: "The answer did not reach the hub.") }
        await send(needID: id)
        if pending == nil, sendError == nil, storageError == nil { return nil }
        return sendError ?? storageError ?? String(l10n: "The answer did not reach the hub.")
    }

    /// Closes the card of this request, and no other.
    func closeTakeOverCard(_ id: Int) { if takeOverCard?.id == id { takeOverCard = nil } }

    /// The card closed (`takeOverCard`): its tunnel closes, unless another open take-over of the same machine uses it;
    /// the request's own window comes back while the request is open; a task's or a job's card that it covered comes
    /// back.
    func takeOverCardClosed(_ item: TakeOverItem) {
        if let screen = takeOverScreen, screen.item.id == item.id, screen.item.hub == item.hub {
            screen.stop()
            takeOverScreen = nil
        }
        closeTakeOverTunnel(of: item.id)
        let here = hub == item.hub && state?.db == item.database
        if here, let window = item.window, openNeeds.contains(where: { $0.id == item.id }) { window.comeBack() }
        if here, let under = item.detailUnder, detail == nil, destination == item.page, state?.has(under.shown) == true {
            detail = under
        }
    }

    private func closeTakeOverTunnel(of id: Int) {
        guard let way = takeOvers.removeValue(forKey: id), !takeOvers.values.contains(way) else { return }
        Task { await ScreenSharingSession.shared.close(way) }
    }

    /// The tunnels that a press of Take over opened, for items that the reading shows answered or gone (the design's
    /// R3: the way in closes at his answer), wherever he answered: in a card, on Needs you, on the iPhone, in a chat app.
    /// A record whose tunnel closed another way (Disconnect on the machine's page, a lost link) is dropped first, so
    /// that a tunnel he opened again from the machine's page stays; and a tunnel that another open take-over of the
    /// same machine still uses stays until that one is answered too.
    func closeAnsweredTakeOvers() {
        // answered in a card, on the iPhone or in a chat app; or the app reads another hub or fleet now
        if let card = takeOverCard, card.hub != hub || card.database != state?.db
            || state?.needs.first(where: { $0.id == card.id })?.isOpen != true {
            takeOverCard = nil
        }
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

/// Why the take-over card's screen did not open, in the words of its orange line.
struct TakeOverRefusal: Error {
    let text: String
}
