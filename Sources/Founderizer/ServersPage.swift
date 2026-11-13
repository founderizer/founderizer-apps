import AppKit
import FleetCore
import SwiftUI

/// Settings › Servers: **the servers, and under them the owner's own devices** (the owner's map of 28 October 2026,
/// D-4: "Servers and devices are one section of Settings"; they were two pages of the main sidebar). Two groups, each
/// with its add on its heading: Servers with Add server, Your devices with Add device (`DevicesSection`).
///
/// The servers (owner feature `servers`, `GET /ui/servers` and `GET /ui/health` every 15 seconds while it shows): one row
/// for each machine that runs agents or can run them, also one with no agent, with a mark for its kind, its name, its
/// system and address, its agents and its state in a few words. A click opens the server's page. Add server opens the wizard
/// that adds one (`AddServerView` in `AddMachineView.swift`). A hub without `servers` shows the machines of its
/// agents (`GET /ui/machines`), as before.
struct ServersPage: View {
    @Bindable var store: FleetStore
    /// The readings are the store's (`FleetStore.reading`): the list he saw last shows in the first frame when he comes
    /// back, and the read that starts then changes only what changed. A server's page draws from the same list.
    private var list: ServerList? {
        get { store.reading("servers.list") } nonmutating set { store.keep(newValue, as: "servers.list") }
    }
    private var machines: MachineList? {
        get { store.reading("machines") } nonmutating set { store.keep(newValue, as: "machines") }
    }
    /// The hub's health, which a server's page draws too: each row's word goes by its helpers, as that page's does.
    private var health: FleetHealth? {
        get { store.reading("servers.health") } nonmutating set { store.keep(newValue, as: "servers.health") }
    }
    private var helpers: [FleetHealth.Helper] { health?.currentHelpers(at: time) ?? [] }
    @State private var failed = false
    /// The hub's own line about the read it refused, when it wrote one. The row that says the servers cannot be
    /// read says it, instead of leaving the owner with nothing about why.
    @State private var reason: String?
    /// The connected apps' readings and the one-time code of this visit: the page's own state, which goes with it.
    @State private var connect = ConnectedAppsModel()
    @Environment(\.openWindow) private var openWindow
    private var time: Double { store.state?.time ?? 0 }
    private var offered: Bool { store.state?.ui_features?.contains(Servers.feature) == true }
    private var older: Bool { !offered && store.state?.ui_features?.contains("machines") == true }
    /// The list, read before the page first opens (`PagePrefetch`).
    static let prefetch = PagePrefetch("servers.list", feature: Servers.feature) { try await HubClient().servers(hub: $0, database: $1) }

    var body: some View {
        // **A table, at the column's 1,100 pt** (D-8 item 8: "boards and tables keep 1,100"; the D-4 mockup, panel 3):
        // it was a 680-pt card list whose rows took 102–109 pt.
        FleetPage("Servers", board: true) {
            Group {
                if offered, let list {
                    if (failed || !store.isFresh) && !store.hubNoticeShows { lastReading }
                    // No line under the list about what a click does: every row says it with its own pointer,
                    // and the other lists of the app (Apps, Devices) carry none.
                    // The CPU, Memory and Disk columns where the hub reads them (the load readings, 4 November 2026).
                    let load = list.servers.contains { $0.load != nil }
                    FormSection("Servers") {
                        if list.servers.isEmpty {
                            FormEmpty("No servers yet", symbol: "server.rack")
                        } else if load {
                            loadHeads(stateWidth: stateWidth(list))
                        }
                        ForEach(list.servers) { row($0, stateWidth: stateWidth(list), load: load) }
                    } accessory: { addServer }
                } else if older, let machines {
                    if (failed || !store.isFresh) && !store.hubNoticeShows { lastReading }
                    FormSection("Servers", footer: "Update the Founderizer hub to add servers here.") {
                        ForEach(Self.groups(machines), id: \.name) { olderRow($0.name, $0.rows) }
                    }
                } else if !offered && !older {
                    if !devices {
                        FormSection { FormEmpty("This hub does not report its servers yet.", symbol: "server.rack") }
                    }
                } else if failed || store.connectionError != nil {
                    // **While the hub does not answer, nothing is being read**, so the page says it cannot read the
                    // servers instead of a "Reading the servers…" that would stand for as long as the hub is down.
                    // **Not while the window's notice says the outage** (`FleetStore.hubNoticeShows`; fix round 3, item
                    // 33: it is said once, over the page): the heading and its Add server stand alone, as while it reads.
                    FormSection("Servers") {
                        if !store.hubNoticeShows {
                            FormRow("Founderizer cannot read the servers now.",
                                    detail: ([reason] + ["It reads again when the hub answers."]).compactMap { $0 }.joined(separator: " "))
                        }
                    } accessory: { addServer }
                } else {
                    // The heading and its Add server from the first frame; the wait is the line under them.
                    FormSection("Servers") { EmptyView() } accessory: { addServer }
                    LoadingLine("Reading the servers…")
                }
            }
            // His own devices beside this Mac, the section's second group: drawn with the servers, and read meanwhile.
            if devices {
                // Held, it draws no loading line of its own, which took the page's first slot while the group was
                // hidden, so the page showed no line at all (fix round 3b): the servers' line is the one he sees.
                DevicesSection(store: store, held: holdsDevices)
                    .frame(height: holdsDevices ? 0 : nil, alignment: .top).clipped()
                    .opacity(holdsDevices ? 0 : 1).accessibilityHidden(holdsDevices)
            }
            // The connected apps under his devices (hub feature `connected_apps`): only while one of their two groups
            // has something to show, so that the page gets no empty block; and with the devices, after the servers.
            if connectedApps, !holdsDevices, connect.draws(now: connectNow) {
                let running = switchModel.running
                ConnectedAppsGroups(model: connect, now: connectNow, canAct: store.canWrite && connect.isFor(store),
                                    choose: { level in Task { await connect.choose(level, store: store) } },
                                    revoke: { connection in Task { await connect.revoke(connection, store: store) } },
                                    turnOff: running ? nil : { switchModel.turnOff(store: store) },
                                    offStop: switchModel.offStop,
                                    report: { openWindow(id: FounderizerApp.reportWindow) })
            }
            // Turn on, its wait and its failure row (the owner's yes of 13 November 2026 to the pictures 2a to 2d): only
            // while the hub names `connect_offer`, and never while it serves `connected_apps`.
            if !holdsDevices, offerShows != .nothing {
                ConnectAppOffer(show: offerShows, canAct: store.canWrite && connect.isFor(store),
                                turnOn: { switchModel.turnOn(store: store) },
                                tryAgain: { switchModel.tryAgain(store: store) },
                                report: { openWindow(id: FounderizerApp.reportWindow) })
            }
        }
        .task(id: "\(store.hub)/\(store.state?.db ?? "")/\(offered)") { await poll() }
        .task(id: "\(store.hub)/\(store.state?.db ?? "")/\(connectedApps)/\(connectOffer)/\(switchModel.ended)") {
            await connect.run(store: store)
        }
        // A stop that only work on the server repairs goes when he leaves the page, so that Turn on is there again.
        .onDisappear { switchModel.left() }
        // The hub serves them: a Turn on that stopped has nothing left to do.
        .onChange(of: connectedApps, initial: true) { _, serves in if serves { switchModel.served() } }
        // A code that ended while the app was in the background is replaced when it comes to the front.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if connectedApps { Task { await connect.activated(store: store) } }
        }
    }

    /// The hub serves the connected apps of its remote MCP address. No hub names the feature yet.
    private var connectedApps: Bool { store.state?.ui_features?.contains(ConnectedApps.feature) == true }
    /// The hub lets this Mac turn them on, or waits for them to be ready (UI-API.md, version 1.151). No hub names it yet.
    private var connectOffer: Bool { store.state?.ui_features?.contains(ConnectedApps.offer) == true }
    /// Turn on and Turn off: the run is the store's, so that it goes on whatever page shows.
    private var switchModel: ConnectSwitchModel { store.connectSwitch() }
    /// What the group of Turn on shows, from the hub's answer and the store's run.
    private var offerShows: ConnectGate.Show {
        ConnectGate.show(features: store.state?.ui_features, state: connect.isFor(store) ? connect.state : nil,
                         run: switchModel.run, canAct: store.canWrite && connect.isFor(store))
    }
    private var connectNow: Double { store.state?.time ?? Date().timeIntervalSince1970 }

    /// The hub serves the owner's own devices (`mobile`).
    private var devices: Bool { store.state?.ui_features?.contains(OwnerDevices.feature) == true }

    /// **"Your devices" never moves down when the servers come** (fix round 3, items 9 and 13): until the server list's
    /// first read answers, its one line stands in the first slot and the devices' group waits under it, read but drawn
    /// as nothing; then both come in one frame, or the devices' group keeps its own place under the list. It stood
    /// under the line, with a line of its own, and went 536 pt down when the list came on a slow hub.
    private var holdsDevices: Bool { offered && list == nil && !failed && store.connectionError == nil }

    /// **The section's one main button**, on the heading of its servers, where the mockup he approved puts it.
    @ViewBuilder private var addServer: some View {
        if offered {
            Button { store.destination = .addServer } label: { Label("Add server", systemImage: "plus") }
                .buttonStyle(FleetPrimaryButtonStyle()).accessibilityIdentifier("servers-add")
        }
    }

    private var lastReading: some View {
        Label("Last reading. Founderizer reads the servers again when the hub answers.", systemImage: "clock.arrow.circlepath")
            .font(FormMetrics.detail).foregroundStyle(.orange)
    }

    /// One server: a mark for its kind, its name, its system and address, its agents with what each runs on, and its
    /// state.
    ///
    /// **One two-line row per server, as the D-4 mockup draws it** (fix round 2): the name over its system and address in
    /// the first column, then the agent, its account, its usage and the state, each in a column of its own, so the
    /// columns stand at one place in every row. **Nothing is cut in a narrow window** (at 960 pt the card keeps about 370
    /// pt, where the table's columns need about 500): the agents go under the name, an account gives up its width to "…"
    /// but keeps eight characters (it was cut to one or two letters), and **the state stays on the name's line** (fix
    /// round 3, item 8: it stood alone on the row's last line, in rows of 101–127 pt).
    private func row(_ server: ServerEntry, stateWidth: CGFloat, load: Bool) -> some View {
        let state = Servers.state(server, helpers: helpers, time: time, fresh: store.isFresh)
        return Button { store.destination = .server(server.name) } label: {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    IconTile(symbol: server.symbol)
                    names(server).frame(minWidth: 96, idealWidth: 120, maxWidth: .infinity, alignment: .leading)
                    if load { figures(server.load) }
                    agentColumns(server.agents).layoutPriority(1)
                    stateColumn(state).frame(width: stateWidth, alignment: .trailing)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 12) {
                        IconTile(symbol: server.symbol)
                        names(server)
                        Spacer(minLength: 8)
                        // **The state keeps its words whole** (fix round 3b, item 8): at 960 the name's column took
                        // the line first, and "Sign-in needed" shrank to a 4-pt sliver, "Installing Echo…" to
                        // "Instal…cho…". The system and address give way with "…" instead.
                        stateColumn(state).fixedSize().layoutPriority(2)
                    }
                    // Under the name, where the heads stand in a narrow window (`loadHeads`).
                    if load { figures(server.load).padding(.leading, 34 + 12) }
                    agents(server.agents, alignment: .leading).padding(.leading, 34 + 12)
                }
            }.padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 10).frame(minHeight: FormMetrics.twoLineRow)
        }
        .buttonStyle(FleetRowButtonStyle())
        .accessibilityLabel("\(server.name), \(state.words)").accessibilityHint("Opens the server")
        .accessibilityIdentifier("server-\(server.name)")
    }

    /// **A server's CPU, memory and disk, each under its head** (the owner, 4 November 2026: "do we have data of
    /// cpu/memory/disk usage for the different fleet servers? THAT would be useful for the Servers section", and his yes
    /// to the mockup): the share in use in whole percent, orange at 90% or more, gray for a reading older than ten
    /// minutes, and the amounts and the time of an old reading on hover. A dash where a figure was not read.
    private func figures(_ load: ServerLoad?) -> some View {
        let old = !store.isFresh || load?.isCurrent(at: time) != true
        let when = old ? load?.at.map { "Last reading \(fleetDate($0))" } : nil
        return HStack(spacing: 12) {
            figure(load?.cpu, help: when, old: old)
            figure(load?.memory, help: [ServerPage.used(load?.memory_used, load?.memory_total), when].compactMap { $0 }
                .joined(separator: "\n"), old: old)
            figure(load?.disk, help: [ServerPage.used(load?.disk_used, load?.disk_total), when].compactMap { $0 }
                .joined(separator: "\n"), old: old)
        }.font(FormMetrics.detail)
    }

    private func figure(_ share: Double?, help: String?, old: Bool) -> some View {
        Text(share.map(LoadWords.percent) ?? "–").monospacedDigit().lineLimit(1)
            .foregroundStyle(share == nil || old ? FleetStyle.muted
                : ServerLoad.isHigh(share ?? 0) ? Color.orange : FleetStyle.text)
            .frame(width: Self.figureWidth, alignment: .leading)
            .help(help ?? "")
    }

    /// **The heads of CPU, Memory and Disk, once, over their columns**: the table's first row, built as a server's
    /// row is, with empty columns in the other places, so each head stands over its column. In a window too narrow
    /// for the table's one line, every row takes its figures under its name, and the heads stand there.
    private func loadHeads(stateWidth: CGFloat) -> some View {
        let heads = HStack(spacing: 12) {
            ForEach(["CPU", "Memory", "Disk"], id: \.self) { Text($0).frame(width: Self.figureWidth, alignment: .leading) }
        }
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                Color.clear.frame(width: 34, height: 1)
                Color.clear.frame(height: 1).frame(minWidth: 0).layoutPriority(1)
                    .frame(minWidth: 96, idealWidth: 120, maxWidth: .infinity, alignment: .leading)
                heads
                HStack(spacing: 12) {
                    Color.clear.frame(width: Self.agentWidth, height: 1)
                    HStack(spacing: 12) {
                        Color.clear.frame(minWidth: AgentAccountLine.accountLeast, idealWidth: AgentAccountLine.accountLeast,
                                          maxWidth: AgentAccountLine.accountWidth, maxHeight: 1)
                        Color.clear.frame(width: AgentAccountLine.usageWidth, height: 1)
                    }
                }.layoutPriority(1)
                Color.clear.frame(width: stateWidth, height: 1)
            }
            HStack(spacing: 0) {
                heads.padding(.leading, 34 + 12)
                Spacer(minLength: 0)
            }
        }
        .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).lineLimit(1)
        .padding(.horizontal, FormMetrics.rowInset).frame(height: FormMetrics.headingRow)
        .accessibilityHidden(true)
    }

    /// A figure's column: "100%" in the row's 12-pt figures, or the head "Memory", whichever is wider.
    private static let figureWidth: CGFloat = max(
        ("100%" as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)]).width,
        ("Memory" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width).rounded(.up)

    /// The server's name, which keeps its room before every other column, and its system and address.
    private func names(_ server: ServerEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(server.name).font(FormMetrics.title).foregroundStyle(FleetStyle.text)
                .lineLimit(1).truncationMode(.middle)
            // **Cut at its end** (the polish of 30 October 2026): a cut in its middle kept the system's last ")" alone,
            // "Debian GNU/L…)", at 960.
            Text(Self.systemLine(server)).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                .lineLimit(1).truncationMode(.tail)
        }.frame(minWidth: 0).layoutPriority(1)
    }

    /// **Connected is a tick**, with the word behind it (the owner, 27 October 2026: "instead of "Connected" a check
    /// icon would be enough"). **The last reading of a hub that does not answer is the unknown mark**, muted, with its
    /// words behind it: the app does not know the state then (`Servers.lastReading`). Every other state keeps its few
    /// words, because each one says what goes on or what to do. `Servers.state` says "Connected" for a machine that is
    /// well.
    @ViewBuilder private func stateColumn(_ state: (words: String, attention: Bool)) -> some View {
        if state.words == "Connected" {
            RowStateMark(state: .good).help(state.words)
        } else if state.words == Servers.lastReading {
            RowStateMark(state: .unknown).help("Last reading: Founderizer reads this server again when the hub answers.")
        } else {
            Text(state.words).font(FormMetrics.detail)
                .foregroundStyle(state.attention ? Color.orange : FleetStyle.muted).lineLimit(1).truncationMode(.middle)
        }
    }

    /// The state column is as wide as its widest state: a column of marks takes the width of one mark, so the agents'
    /// columns stand at one place in every row either way.
    private func stateWidth(_ list: ServerList) -> CGFloat {
        list.servers.allSatisfy {
            [Servers.lastReading, "Connected"].contains(Servers.state($0, helpers: helpers, time: time, fresh: store.isFresh).words)
        } ? 22 : 200
    }

    /// The table's columns of the agents here, one line each: the agent's glyph and name, its account and its usage,
    /// each column as wide in every row. A server with no agent says so in the agent's column.
    @ViewBuilder private func agentColumns(_ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if names.isEmpty {
                Text("No agent").foregroundStyle(FleetStyle.muted)
                    .frame(minWidth: Self.agentWidth + 12 + AgentAccountLine.accountLeast + 12 + AgentAccountLine.usageWidth,
                           maxWidth: Self.agentWidth + 12 + AgentAccountLine.accountWidth + 12 + AgentAccountLine.usageWidth,
                           alignment: .leading)
            }
            ForEach(names, id: \.self) { name in
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        AgentGlyph(name: name, size: GlyphSize.inline)
                        Text(name.agentLabel).foregroundStyle(FleetStyle.text).lineLimit(1).truncationMode(.middle)
                    }.frame(width: Self.agentWidth, alignment: .leading)
                    if let agent = store.state?.agents.first(where: { $0.name == name }) {
                        AgentAccountLine(store: store, agent: agent, table: true)
                    } else {
                        Color.clear.frame(width: AgentAccountLine.accountWidth + 12 + AgentAccountLine.usageWidth, height: 1)
                    }
                }
            }
        }.font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
    }

    /// The agent's column of the table: a glyph and a name of about ten letters.
    private static let agentWidth: CGFloat = 110

    /// The agents here, one line each: the agent's glyph and name, then what it runs on (`AgentAccountLine`).
    @ViewBuilder private func agents(_ names: [String], alignment: HorizontalAlignment) -> some View {
        if names.isEmpty {
            Text("No agent").font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
        } else {
            VStack(alignment: alignment, spacing: 6) {
                ForEach(names, id: \.self) { name in
                    HStack(spacing: 12) {
                        HStack(spacing: 6) {
                            AgentGlyph(name: name, size: GlyphSize.inline)
                            Text(name.agentLabel).lineLimit(1).truncationMode(.middle)
                        }.frame(minWidth: 0, idealWidth: 96, maxWidth: 96, alignment: .leading)
                        if let agent = store.state?.agents.first(where: { $0.name == name }) {
                            AgentAccountLine(store: store, agent: agent)
                        }
                    }
                }
            }.font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
        }
    }

    static func systemLine(_ server: ServerEntry) -> String {
        let line = [server.reading?.os.name, server.address].compactMap { $0 }.joined(separator: " · ")
        return line.isEmpty ? "System not reported" : line
    }

    // MARK: A hub without servers

    /// The machines in the hub's order, each with the readings of its agents.
    static func groups(_ reading: MachineList) -> [(name: String, rows: [MachineStatus])] {
        var names: [String] = [], rows: [String: [MachineStatus]] = [:]
        for status in reading.machines {
            if rows[status.machine] == nil { names.append(status.machine) }
            rows[status.machine, default: []].append(status)
        }
        return names.map { ($0, rows[$0] ?? []) }
    }

    private func olderRow(_ name: String, _ rows: [MachineStatus]) -> some View {
        let first = rows[0]
        let mac = first.os.name?.localizedCaseInsensitiveContains("mac") == true
        let words = first.reported_at == nil ? "No reading yet" : !store.isFresh || !first.isCurrent(at: time) ?
            "Last reading \(activityAge(first.reported_at ?? 0, now: time).lowercased())" : "Reported"
        return Button { store.destination = .server(name) } label: {
            HStack(spacing: 12) {
                IconTile(symbol: mac ? "desktopcomputer" : "server.rack")
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(FormMetrics.title).foregroundStyle(FleetStyle.text).lineLimit(1)
                    Text([first.os.name, first.address].compactMap { $0 }.joined(separator: " · "))
                        .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).lineLimit(1)
                }.padding(.vertical, 10)
                Spacer(minLength: 12)
                agents(rows.map(\.agent), alignment: .trailing).padding(.vertical, 8)
                Text(words).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).frame(minWidth: 110, alignment: .trailing)
            }.padding(.horizontal, FormMetrics.rowInset).frame(minHeight: FormMetrics.twoLineRow)
        }.buttonStyle(FleetRowButtonStyle()).accessibilityIdentifier("server-\(name)")
    }

    /// Reads the servers and the health every 15 seconds while the page shows. A failed read keeps the last reading.
    private func poll() async {
        let start = ContinuousClock.now
        while !Task.isCancelled {
            if store.isFresh, let database = store.state?.db {
                let hub = store.hub
                if offered {
                    let first = list == nil
                    do {
                        let read = try await HubClient().servers(hub: hub, database: database)
                        guard !Task.isCancelled else { return }
                        if first { await store.settle(since: start) }
                        if store.hub == hub, store.state?.db == database { list = read; failed = false; reason = nil }
                    } catch {
                        guard !Task.isCancelled else { return }
                        if first { await store.settle(since: start) }
                        if store.hub == hub, store.state?.db == database { failed = true; reason = HubError.said(error) }
                    }
                    if let read = try? await HubClient().health(hub: hub, database: database),
                       store.hub == hub, store.state?.db == database { health = read }
                } else if older {
                    let first = machines == nil
                    do {
                        let read = try await HubClient().machines(hub: hub, database: database)
                        guard !Task.isCancelled else { return }
                        if first { await store.settle(since: start) }
                        if store.hub == hub, store.state?.db == database { machines = read; failed = false; reason = nil }
                    } catch {
                        guard !Task.isCancelled else { return }
                        if first { await store.settle(since: start) }
                        if store.hub == hub, store.state?.db == database { failed = true; reason = HubError.said(error) }
                    }
                }
            }
            do { try await store.nap(15) } catch { return }
        }
    }
}

/// One server's page: **the machine in one card, and each agent on it in one card under it.**
///
/// The owner, 27 October 2026, of the page it replaces: "This page is a mess, machine data is duplicated, we need to
/// simplify it a lot!" — and of the server list beside it: "here I should see the AI provider and the account being
/// used as well as the usage % value!" So a machine that is connected has a tick beside its name and no card that
/// says so; the standing card is there only when something goes on or waits for him (a restart, a helper to update,
/// what a closer look found, a machine that is not connected). Then the Server card — system, private address,
/// Founderizer, security — and one card for each agent: its provider, its account and the used share of each window,
/// and the way into the machine as that agent. There is no Details line any more: the server's own list of providers
/// is gone, because it looks for them as another user and showed two crosses on a machine whose agent was signed in,
/// and so is the second copy of the machine's facts that each agent's reading drew under it. Nor is there a Look
/// closer in the header (the owner, 6 November 2026: "I dont like it, we should remove it from the UI"): a closer look
/// runs only from the standing card's Find out why, and after a restart or an update that this Mac drives.
///
/// `name` is a server's name, or, from a place that knows only the agent, the agent's name: the page then shows
/// that agent's server.
struct ServerPage: View {
    @Bindable var store: FleetStore
    @Environment(\.openWindow) private var openWindow
    let name: String
    let addAgent: (String) -> Void
    let retry: (ServerEntry, ServerJob) -> Void
    /// The servers, as the Servers list read them last: a click on a row opens this page whole in its first frame.
    private var list: ServerList? {
        get { store.reading("servers.list") } nonmutating set { store.keep(newValue, as: "servers.list") }
    }
    @State private var machine: String?
    /// The reading of each agent's machine (`GET /ui/machines`). This page needs it for four things: the link and
    /// the code of a sign-in live there, and only while that sign-in waits; whether a helper here runs the fleet's
    /// own revision, which only the hub can say; **how this Mac reaches the machine** — its address, and the user
    /// and port the fleet has on record (`MachineReach`), so the page asks the owner for none of them; and the
    /// system a server reports, which says which machine it is for the checks.
    private var readings: [MachineStatus] { (store.reading("machines") as MachineList?)?.machines ?? [] }
    /// The hub's own live answer about every helper (`GET /ui/health`): whether it is reporting, when it was last
    /// heard from, and the hub's own line where something is wrong. **This is what the page's one word comes
    /// from.** It costs nothing, it is current, and it needs neither the owner's SSH nor a button he must press.
    private var health: FleetHealth? {
        get { store.reading("servers.health") } nonmutating set { store.keep(newValue, as: "servers.health") }
    }
    @State private var failed = false
    @State private var removing = false
    @State private var error: String?
    /// The hub's words when it refused Try again on a deleted agent's removal.
    @State private var againRefused: String?
    private var time: Double { store.state?.time ?? 0 }
    private var offered: Bool { store.state?.ui_features?.contains(Servers.feature) == true }
    private var signInOffered: Bool { store.state?.ui_features?.contains(MachineLogin.feature) == true }
    private var server: ServerEntry? { list?.servers.first { $0.name == name } ?? list?.server(of: name) }
    /// The server's own name; before anything is read, **never a key** (fix round 3, item 34): opened from an agent, the
    /// page said "atlas" over nothing; it says that agent's name as everywhere, "Atlas".
    private var title: String {
        if let server { return server.name }
        if !offered, let machine { return machine }
        return store.state?.agents.contains { $0.name == name } == true ? name.agentLabel : name
    }

    var body: some View {
        FleetPage(title, back: FleetBack("Servers") { store.destination = .settings(.servers) }, mark: server.flatMap(tick)) {
            Group {
                if let server {
                    if let job = server.job, job.kind == "install", job.isOpen || job.state == "failed" && server.agents.contains(job.agent ?? "") {
                        ServerJobView(job: job, server: server.name,
                                      retry: job.state == "failed" ? { retry(server, job) } : nil,
                                      onMac: server.isMac, openSignIn: { store.destination = .signIn($0) })
                    }
                    // A provider's preparation shows while it goes on; after a failure, its agent's Change provider has
                    // Try again.
                    if let job = server.job, job.kind == "prepare", job.isOpen {
                        ServerJobView(job: job, server: server.name, retry: nil, openSignIn: { store.destination = .signIn($0) })
                    }
                    // **A deleted agent's removal** (the owner's yes of 7 November 2026 to Delete…) shows while it goes
                    // on, and after a failure with Try again, which is the same Delete again: the agent has left the
                    // fleet, so this page is the one place that still names it.
                    if let job = server.job, job.kind == "remove", job.isOpen || job.state == "failed", let agent = job.agent {
                        ServerJobView(job: job, server: server.name, retry: job.state == "failed" ? { removeAgain(agent) } : nil,
                                      onMac: server.isMac)
                        if let againRefused {
                            Text(againRefused).font(FormMetrics.detail).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    // The standing card only when it has something to say: a machine that is well has its tick
                    // beside its name. An install that goes on is the page's own subject while it runs, and it
                    // already says where the machine stands, so the standing waits for it to end.
                    if server.job?.isOpen != true {
                        if !MachineStandingSection.isWell(standing(server), model: model(server)) {
                            MachineStandingSection(store: store, model: model(server), server: server, readings: readings,
                                                   connected: connection(server))
                        }
                        signIn(server)
                    }
                    serverCard(server)
                    ForEach(server.agents, id: \.self) { agentCard($0) }
                    if server.agents.isEmpty && server.joined && !server.hub { removal(server) }
                } else if offered && list != nil {
                    FormSection { FormEmpty("Founderizer has no server named \(name).", symbol: "server.rack") }
                } else if !offered {
                    TechnicalDetails(store: store, agent: name)
                } else if failed || store.connectionError != nil {
                    // Not while the window's notice says the outage (`FleetStore.hubNoticeShows`; fix round 3, item 33).
                    if !store.hubNoticeShows {
                        FormSection { FormRow("Founderizer cannot read this server now.", detail: "It reads again when the hub answers.") }
                    }
                } else {
                    LoadingLine("Reading the server…")
                }
            }
        } actions: {
            if let server { serverActions(server) }
        }
        .task(id: "\(store.hub)/\(store.state?.db ?? "")/\(name)") { await poll() }
    }

    /// The hub's own answer about one server: are its helpers reporting? A reading of the hub that is not current
    /// gives no answer at all, which the page says rather than calling an old reading "Connected".
    private func connection(_ server: ServerEntry) -> MachineConnection {
        guard let health else { return failed ? .unknown : .waiting }
        return MachineConnection.of(server, helpers: health.helpers, warnings: health.warnings,
                                    time: time, fresh: store.isFresh)
    }

    /// The sign-in of every agent here whose machine says it is not signed in — the commonest thing to put right
    /// after an install, and the owner's own step, which no installer can take for him. So it is under the state
    /// row that asks for it and not behind Details, where an agent that is signed in keeps its card: signing in
    /// again is a rare thing to want. The row says nothing the state row said already.
    @ViewBuilder private func signIn(_ server: ServerEntry) -> some View {
        // The machine readings now come whatever the hub offers, because the connection is read from them. The
        // sign-in itself is still the hub's own route, so it is offered only where the hub has it.
        let waiting = signInOffered ? server.signIns(readings) : []
        ForEach(waiting) { reading in
            MachineSignInSection(store: store, agent: reading.agent, reading: reading,
                                 fresh: store.isFresh && reading.isCurrent(at: time), refresh: readMachines,
                                 title: waiting.count > 1 ? reading.agent.agentLabel : nil, alreadySaid: true)
        }
    }

    /// Which machine this is, for the checks: the hub's own, a Linux machine that joined, or a Mac. **The hub's
    /// own report says it** — the hub names its own machine, and every machine reports the system it runs — so
    /// the page derives it and asks the owner nothing about where a checkout lives. A server whose kind no
    /// reading has set yet is told by the system the machines of its agents report.
    static func checkout(_ server: ServerEntry, readings: [MachineStatus] = []) -> MachineCheckout {
        if server.hub { return .hub }
        if server.isMac { return .macWorker }
        if server.kind == nil,
           readings.first(where: { $0.machine == server.name })?.os.name?
            .localizedCaseInsensitiveContains("mac") == true { return .macWorker }
        return .linuxWorker
    }

    /// The page's actions: one button for each agent on the server, then Add agent.
    @ViewBuilder private func serverActions(_ server: ServerEntry) -> some View {
        Group {
            ForEach(server.agents, id: \.self) { agent in
                Button { store.destination = .agentDetail(agent, .settings) } label: {
                    HStack(spacing: 7) { AgentGlyph(name: agent, size: GlyphSize.inline); Text(agent.agentLabel) }
                }.buttonStyle(FleetOutlineButtonStyle()).help("Open the agent").accessibilityIdentifier("server-agent-\(agent)")
            }
            if server.available {
                Button { addAgent(server.name) } label: { Label("Add agent", systemImage: "plus") }
                    .buttonStyle(FleetPrimaryButtonStyle()).accessibilityIdentifier("server-add-agent")
            }
        }
    }

    /// The checks of this machine, which the standing card reads.
    private func model(_ server: ServerEntry) -> MachineChecksModel {
        store.checksModel(machine: server.name, kind: Self.checkout(server, readings: readings))
    }

    private func standing(_ server: ServerEntry) -> ServerStanding {
        MachineStandingSection.standing(store: store, model: model(server), server: server, readings: readings,
                                        connected: connection(server))
    }

    /// **Connected is a tick beside the name**, with the word and its line behind it, as on the Servers list. A
    /// machine that is not connected has none: the card under the name says what is wrong.
    private func tick(_ server: ServerEntry) -> AnyView? {
        let connected = connection(server)
        guard connected.isConnected else { return nil }
        return AnyView(StateMark(state: .good, words: connected.words, detail: connected.says(server.name, now: time),
                                 size: 18))
    }

    /// **The machine, in one card**: its system, its private address, Founderizer on it and its security, each a
    /// mark or a value with its words behind it. The providers are not here: each agent's card names the one it runs
    /// on, from that agent's own reading.
    @ViewBuilder private func serverCard(_ server: ServerEntry) -> some View {
        let reasons = server.available || server.why.contains("has_agent") ? nil
            : server.why.map(Servers.reason).joined(separator: " ")
        FormSection("Server", footer: reasons) {
            if let reading = server.reading {
                let fresh = store.isFresh && reading.isCurrent(at: time)
                // A reading's age is a yes-or-no fact — is this current? — so it is a mark, and the date it was read
                // is behind it. The system name stays the row's own title.
                FormMarkRow(title: reading.os.name ?? "System not reported", state: fresh ? .good : .warn,
                            symbol: server.symbol, words: fresh ? "Current" : "Last reading",
                            detail: "Read \(fleetDate(reading.reported_at)).",
                            whoActs: fresh ? nil : "The server sends its own reading every few minutes.",
                            identifier: "server-reading")
                if let address = server.address { FormRow("Private address", symbol: "network") { value(address) } }
                FormMarkRow(title: "Founderizer", state: reading.current == false ? .warn
                            : reading.current == true ? .good : .unknown,
                            symbol: "arrow.triangle.2.circlepath",
                            words: reading.current == false ? "Update available"
                                : reading.current == true ? "Up to date" : "Not reported",
                            detail: reading.revision.map { "It runs \($0.prefix(12))." } ?? "It reported no revision.",
                            whoActs: reading.current == false && server.joined
                                ? "The server updates itself when it has no job." : nil,
                            identifier: "server-revision")
                if let security = reading.security { securityRow(server, security) }
            } else if server.load == nil || server.joined {
                FormRow("No reading yet", detail: server.joined ? "Its server service sends one within a minute of its start." : nil)
            }
            // The hub's own machine has its figures with no reading of its own: the hub reads them itself. One that
            // joined still owes its service's reading, and says so.
            if let load = server.load { loadRows(load) }
        }
    }

    /// **CPU, Memory and Disk, one row each** (the owner's yes of 4 November 2026 to the mockup: "A server's own page gets
    /// three rows"): the share of the processors in use, and how much of the memory and of the disk, orange at 90% or
    /// more, gray for a reading older than ten minutes, with its time on hover.
    @ViewBuilder private func loadRows(_ load: ServerLoad) -> some View {
        let old = !store.isFresh || !load.isCurrent(at: time)
        let when = old ? load.at.map { "Last reading \(fleetDate($0))" } : nil
        FormRow("CPU", symbol: "cpu") { loadValue(load.cpu.map(LoadWords.percent), share: load.cpu, old: old, help: when) }
            .accessibilityIdentifier("server-cpu")
        FormRow("Memory", symbol: "memorychip") {
            loadValue(Self.used(load.memory_used, load.memory_total), share: load.memory, old: old, help: when)
        }.accessibilityIdentifier("server-memory")
        FormRow("Disk", symbol: "internaldrive") {
            loadValue(Self.used(load.disk_used, load.disk_total), share: load.disk, old: old, help: when)
        }.accessibilityIdentifier("server-disk")
    }

    /// "11,9 of 74,8 GB used", or nil where a part was not read.
    static func used(_ used: Double?, _ total: Double?) -> String? {
        guard let used, let total, total > 0 else { return nil }
        return LoadWords.used(used, of: total)
    }

    private func loadValue(_ words: String?, share: Double?, old: Bool, help: String?) -> some View {
        Text(words ?? "Not reported").multilineTextAlignment(.trailing).textSelection(.enabled)
            .foregroundStyle(!old && ServerLoad.isHigh(share ?? 0) ? Color.orange : FleetStyle.muted)
            .help(help ?? "")
    }

    /// **Security in one row**: the private network, the firewall and, on a server, its automatic security updates.
    /// A tick when all are on; a cross that names what is off, with Report a problem, because the fix is work on the
    /// machine itself. Each one, and the security updates that wait, are behind the mark.
    private func securityRow(_ server: ServerEntry, _ security: ServerReading.Security) -> some View {
        let parts = server.securityParts(security, at: time)
        let off = parts.filter { $0.on == false }.map(\.name)
        let state: MarkState = !off.isEmpty ? .bad : parts.contains { $0.on == nil } ? .unknown : .good
        let waiting = (security.pending_security ?? 0) > 0 ? " · \(security.pending_security ?? 0) security updates are waiting." : ""
        return FormMarkRow(title: "Security", state: state, symbol: "lock.shield",
                           words: !off.isEmpty ? Servers.offWords(parts) : state == .good ? "All on" : "Not reported",
                           detail: parts.map { "\($0.name): \($0.words)" }.joined(separator: " · ") + waiting,
                           act: state == .bad ? problem : nil,
                           whoActs: state == .unknown ? "The server reports these with its own reading." : nil,
                           identifier: "server-security")
    }

    /// **Each agent here, in one card**: what it runs on — its provider, the address of its account and the used share
    /// of each window of that account — and the way into the machine as that agent, Terminal and, on a Mac, Screen
    /// Sharing.
    @ViewBuilder private func agentCard(_ name: String) -> some View {
        let reading = readings.first { $0.agent == name }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) { AgentGlyph(name: name, size: GlyphSize.inline); Text(name.agentLabel) }
                .font(FormMetrics.heading).foregroundStyle(FleetStyle.text)
                .frame(minHeight: FormMetrics.headingRow).padding(.leading, 2)
            FormSection {
                if let agent = store.state?.agents.first(where: { $0.name == name }) {
                    let account = AgentAccount(agent, store: store)
                    FormRow(account.provider, mark: ProviderIcon(runtime: agent.runtime, size: 18)) {
                        HStack(spacing: 16) {
                            Text(account.name).foregroundStyle(FleetStyle.muted).lineLimit(1).truncationMode(.middle)
                                .textSelection(.enabled).help(account.help)
                            Text(account.usage).monospacedDigit()
                                .foregroundStyle(account.old ? FleetStyle.muted : FleetStyle.text).help(account.usageHelp)
                        }
                    }.accessibilityIdentifier("server-agent-account-\(name)")
                }
                if let reading, reading.sshURL != nil || reading.screenSharingConnection != nil || reading.screenSharingURL != nil {
                    MachineAccessButtons(reading: reading, fresh: store.isFresh && reading.isCurrent(at: time))
                        .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 11)
                }
            }
        }
    }

    /// The one thing a cross carries when the work is on the machine itself and no button of this app does it:
    /// the report window, which reads the whole fleet and carries this reading to one of his own agents.
    private var problem: (words: String, run: () -> Void) {
        ("Report a problem", { openWindow(id: FounderizerApp.reportWindow) })
    }

    /// Remove server, a danger button at the end of the page, with the hub's refusal under it: no row of its own named
    /// the same as its button, and no line under it (D-2).
    @ViewBuilder private func removal(_ server: ServerEntry) -> some View {
        VStack(alignment: .leading, spacing: FleetSpace.inside) {
            Button("Remove server") { Task { await remove(server) } }.buttonStyle(FleetDangerButtonStyle())
                .disabled(removing || !store.canWrite || server.job?.isOpen == true)
                .help("It leaves Founderizer. Its files stay on the server, and it can join again with a new line.")
                .accessibilityIdentifier("server-remove")
            if let error {
                Text(error).font(FormMetrics.detail).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Try again on a deleted agent's removal that stopped: the hub gives its server the job again.
    private func removeAgain(_ agent: String) {
        againRefused = nil
        Task { againRefused = await AgentDeletion.send(store: store, agent: agent) }
    }

    private func remove(_ server: ServerEntry) async {
        guard let database = store.state?.db else { return }
        removing = true; error = nil
        defer { removing = false }
        do {
            let team = try await HubClient().team(hub: store.hub, database: database)
            _ = try await HubClient().removeServer(hub: store.hub, database: database, client: store.installation,
                                                   server: server.name, sha256: team.sha256)
            store.destination = .settings(.servers)
        } catch let HubError.refusal(_, words) { error = words }
        catch { self.error = "The hub has not answered. Try again." }
    }

    private func value(_ text: String) -> some View {
        Text(text).foregroundStyle(FleetStyle.muted).multilineTextAlignment(.trailing).textSelection(.enabled)
    }


    /// Reads the per-agent machine readings once. A read that fails keeps the last ones, so a sign-in waiting on
    /// the face does not come and go with one unanswered request.
    ///
    /// It takes the hub's `machines` feature and nothing narrower. The sign-in was once the only thing here that
    /// needed these readings; the connection this page reads the checks over now comes from them too, and a page
    /// that asked the owner to type an address because his hub offers no machine sign-in would be asking him for
    /// a fact it is holding.
    private func readMachines() async {
        guard store.isFresh, store.state?.ui_features?.contains("machines") == true,
              let database = store.state?.db else { return }
        let hub = store.hub
        guard let read = try? await HubClient().machines(hub: hub, database: database), !Task.isCancelled,
              store.hub == hub, store.state?.db == database else { return }
        store.keep(read, as: "machines")
    }

    /// Reads the servers every 5 seconds while the page shows, every 2 seconds while a job of this server goes on
    /// or a sign-in waits for the owner — the link and the code must be on the screen as soon as the machine has
    /// them. The machine readings come in this same loop, never in one of their own.
    private func poll() async {
        while !Task.isCancelled {
            if let database = store.state?.db, store.isFresh {
                let hub = store.hub
                if offered {
                    let read = try? await HubClient().servers(hub: hub, database: database)
                    guard !Task.isCancelled else { return }
                    if store.hub == hub, store.state?.db == database { if let read { list = read; failed = false } else { failed = true } }
                    await readMachines()
                    // The one word of each server's page comes from this reading. A read that fails keeps the
                    // last one, so the word does not come and go with one unanswered request.
                    if let read = try? await HubClient().health(hub: hub, database: database),
                       store.hub == hub, store.state?.db == database { health = read }
                } else if store.state?.ui_features?.contains("machines") == true, machine == nil {
                    machine = try? await HubClient().machines(hub: hub, database: database).machines.first { $0.agent == name }?.machine
                }
            }
            let signingIn = signInOffered && server?.signIns(readings).contains { $0.login?.isOpen == true } == true
            do { try await store.nap(server?.job?.isOpen == true || signingIn ? 2 : 5) } catch { return }
        }
    }
}

/// **What an agent runs on**, as the Servers list and a server's page say it: the provider, the address of its
/// account (the provider's name where no address is read) and the used share of each window of that account, in
/// words and without a bar (the owner, 27 October 2026: "here I should see the AI provider and the account being used
/// as well as the usage % value!", and of the bars: "both %, no bar"). The provider, the plan, each window's full
/// name and reset, and the age of an old reading are on hover.
struct AgentAccount {
    let provider: String
    /// The account's address, the provider's name without one, or Local model.
    let name: String
    /// "5 h 0% · 7 d 12%", Not reported, or nothing for a local model.
    let usage: String
    /// The reading is old: its numbers are muted, and its time is on hover.
    let old: Bool
    let help: String
    let usageHelp: String

    @MainActor init(_ agent: FleetAgent, store: FleetStore) {
        let time = store.state?.time ?? 0
        provider = providerName(agent.runtime)
        let address = AccountEmail(limits: agent.accountLimits, at: time, fresh: store.isFresh,
                                   features: store.state?.ui_features ?? [])
            .flatMap { email -> String? in
                switch email {
                case .current(let value), .old(let value): value
                case .unknown: nil
                }
            }
        name = agent.local_model == true ? "Local model" : address ?? provider
        let bar = UsageBar.bars(for: store.state?.agents ?? [], time: time, isFresh: store.isFresh)[agent.name]
        help = [provider, bar?.reading?.plan, address].compactMap { $0 }.joined(separator: " · ")
        guard bar?.isLocalModel != true else {
            usage = ""; old = false; usageHelp = ""; return
        }
        guard let reading = bar?.reading, !reading.windows.isEmpty else {
            usage = "Not reported"; old = false; usageHelp = bar?.problem ?? ""; return
        }
        let windows = reading.ownWindows(at: time)
        old = !store.isFresh || reading.isStale(at: time)
        usage = windows.map { "\($0.shortLabel) · \(Int($0.used_percent.rounded()))%" }.joined(separator: " · ")
        usageHelp = (windows.map { window in
            "\(window.label): \(window.used_percent.formatted(.number.precision(.fractionLength(0...1))))% used"
                + (window.resets_at.map { ", resets \(fleetDate(ResetLine.minute($0)))" } ?? "")
        } + [old ? "Last reading \(fleetDate(reading.collected_at))" : nil,
             bar?.limit.map { "Usage limit until \(fleetComingTime($0.until, now: time))" }].compactMap { $0 })
            .joined(separator: "\n")
    }
}

/// One agent's `AgentAccount` in a row of the Servers list: the provider's mark and the account, then the shares in
/// one column, so that the shares of every row stand at one place.
struct AgentAccountLine: View {
    @Bindable var store: FleetStore
    let agent: FleetAgent
    /// A column of the Servers table: the account and the shares each in a column as wide in every row.
    var table = false
    /// The shares' column: the width of "5 h · 100% · 7 d · 100%" in the row's 12-pt figures.
    static let usageWidth: CGFloat = ("5 h · 100% · 7 d · 100%" as NSString)
        .size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)]).width.rounded(.up)
    /// The account's column at its widest.
    static let accountWidth: CGFloat = 230
    /// **The least an account keeps: its mark and eight characters** (T-17, fix round 2: "fo", "v", "s" at 960 pt).
    static let accountLeast: CGFloat = 14 + 6 + ("founder@" as NSString)
        .size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width.rounded(.up) + 10

    var body: some View {
        let account = AgentAccount(agent, store: store)
        let name = HStack(spacing: 6) {
            ProviderIcon(runtime: agent.runtime, size: 14)
            Text(account.name).lineLimit(1).truncationMode(.middle)
        }.help(account.help)
        // **The shares are never cut** (T-17: "5 h · 34…" at every width): their column is as wide as two windows at
        // their widest and never narrower than its own words, and the account gives way to "…" in their place.
        let usage = Text(account.usage).monospacedDigit().lineLimit(1).fixedSize()
            .foregroundStyle(account.old ? FleetStyle.muted : FleetStyle.text).help(account.usageHelp)
        if table {
            HStack(spacing: 12) {
                name.frame(minWidth: Self.accountLeast, idealWidth: Self.accountLeast, maxWidth: Self.accountWidth,
                           alignment: .leading)
                usage.frame(width: Self.usageWidth, alignment: .leading)
            }
        } else {
            // Under the server's name, in a narrow window: the account keeps its eight characters, and the shares go
            // on a line of their own when the two do not fit side by side.
            ViewThatFits(in: .horizontal) {
                // Side by side while its eight characters and the shares fit; the account gives way to "…" first.
                HStack(spacing: 12) {
                    name.frame(minWidth: Self.accountLeast, idealWidth: Self.accountLeast, maxWidth: Self.accountWidth,
                               alignment: .leading)
                    usage
                }
                VStack(alignment: .leading, spacing: 4) {
                    name.frame(minWidth: Self.accountLeast, maxWidth: Self.accountWidth, alignment: .leading)
                    usage
                }
            }
        }
    }
}
