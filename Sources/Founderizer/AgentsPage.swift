import AppKit
import FleetCore
import SwiftUI

/// **Agents**, the page of the sidebar's row under Tasks (the owner, 3 November 2026: "a new section above settings on
/// the left sidepanel: Usage. There we see the agents with the server they're in, the usage bars, ai provider (icon) with
/// account etc ... very minimalistic!", and his yes to its mockup the same day; then, the same evening, "the usage
/// section could be moved below tasks.. and be renamed to Agents. I would like each agent to have its own real name...
/// and also a subtitle like their role in the team"). One table of the agents, in the sidebar's order: each one's glyph,
/// its role (team.json `title`) with its name under it, the server it runs on, its provider's mark and its account, and a bar
/// and the used share of each window of that account, under the window's short name, which stands once over its
/// column, with when the window resets under its bar (`ResetLine`; the owner's yes of 10 November 2026). Agents on one
/// account show its newest reading (`UsageBar`). A click opens the agent's chat, as its sidebar row does. What a row
/// leaves out is on hover, as in an agent's panel: the plan, the reset's date in full, and the time of an old reading,
/// which is gray.
struct AgentsPage: View {
    @Bindable var store: FleetStore
    let open: (String) -> Void
    /// The machines' readings, as an agent's panel and Settings › Servers read them last (`FleetStore.reading`).
    private var machines: MachineList? {
        get { store.reading("machines") } nonmutating set { store.keep(newValue, as: "machines") }
    }
    /// The read of this visit failed and none was kept: Not reported in the server's place.
    @State private var readFailed = false
    private var time: Double { store.state?.time ?? 0 }
    private var features: [String] { store.state?.ui_features ?? [] }

    var body: some View {
        let listed = store.state?.agents ?? []
        let agents = ChatList.order(listed.map(\.name), pinned: store.pinned).compactMap { name in listed.first { $0.name == name } }
        let bars = UsageBar.bars(for: listed, time: time, isFresh: store.isFresh)
        let columns = UsageBar.columns(agents.compactMap { bars[$0.name] }, at: time)
        // **Its role over its name** (the owner, 10 November 2026: the role is an agent's main label): the role is the
        // row's name, and the agent's own name stands under it (`AgentNames`).
        let names = Self.width(agents.map(\.name.agentLabel) + agents.compactMap { AgentNames.shared.under($0.name) })
        // One row height for the table: two lines for every row once any agent has a line under its role.
        let roles = agents.contains { AgentNames.shared.under($0.name) != nil }
        let servers = Self.width(agents.compactMap { server($0.name)?.name })
        // The CPU and Memory columns where the helpers read them (the load readings, 4 November 2026).
        let uses = machines?.machines.contains { $0.use != nil } == true
        FleetPage("Agents", board: true) {
            FormSection {
                if agents.isEmpty {
                    FormEmpty("No agents yet", symbol: Self.symbol)
                } else {
                    // No heading row where it would say nothing: no reading has a window, and no helper its use.
                    if !columns.isEmpty || uses { heads(columns, uses: uses, names: names, servers: servers) }
                    ForEach(agents) {
                        row($0, bar: bars[$0.name], columns: columns, names: names, servers: servers, roles: roles, uses: uses)
                    }
                }
            }
        }
        .task(id: "\(store.hub)/\(store.state?.db ?? "")") { await poll() }
    }

    /// The symbol of Agents: two people, which fits the sidebar's mark column ("person.3" stood 6 pt from its word).
    static let symbol = "person.2"

    /// The short name of each window, once, over its column, and CPU and Memory over theirs: the one heading of the
    /// table. It is built as a row is, with empty columns in the other places, so each head stands over its column on
    /// the row's one line; where the rows take two lines (a narrow window), CPU and Memory stand at the start of their
    /// second line, and the windows at its end.
    private func heads(_ columns: [String], uses: Bool, names: CGFloat, servers: CGFloat) -> some View {
        let mark = FormMetrics.markColumn + FormMetrics.markGap
        let windows = HStack(spacing: Self.gap) {
            ForEach(columns, id: \.self) { Text($0).lineLimit(1).frame(width: Self.windowWidth, alignment: .leading) }
        }.frame(width: Self.windowsWidth(columns), alignment: .leading)
        let use = HStack(spacing: Self.gap) {
            Text("CPU").frame(width: Self.cpuWidth, alignment: .leading)
                .help("Its own sessions' share of its server's processors")
            Text("Memory").frame(width: Self.memoryWidth, alignment: .leading)
                .help("The memory its own sessions hold")
        }.lineLimit(1)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: Self.gap) {
                Color.clear.frame(height: 1).frame(minWidth: mark + min(names, Self.least), idealWidth: mark + min(names, Self.least),
                                                   maxWidth: mark + names).layoutPriority(1)
                Color.clear.frame(height: 1).frame(minWidth: min(servers, Self.least), idealWidth: min(servers, Self.least),
                                                   maxWidth: servers).layoutPriority(1)
                if uses { use }
                Color.clear.frame(height: 1).frame(minWidth: AgentAccountLine.accountLeast, idealWidth: AgentAccountLine.accountLeast)
                windows
            }
            HStack(spacing: Self.gap) {
                if uses { use }
                Spacer(minLength: 0)
                windows
            }.padding(.leading, mark)
        }
        .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
        .padding(.horizontal, FormMetrics.rowInset).frame(height: FormMetrics.headingRow)
        .accessibilityHidden(true)
    }

    /// One agent: its glyph, its role with its name under it, its server, its provider's mark and its account, then its
    /// windows. An agent with no role has its name alone, in the middle of the row. The name and
    /// the server columns are as wide as their widest entry, so every row's columns stand at one place; in a narrow
    /// window they give up width with the account, which keeps its mark and eight characters. **Where even that does
    /// not fit** (a wide sidebar in a small window), the account and the windows go on a second line under the name,
    /// and the windows still stand under their heads.
    private func row(_ agent: FleetAgent, bar: UsageBar?, columns: [String], names: CGFloat, servers: CGFloat,
                     roles: Bool, uses: Bool) -> some View {
        let account = AgentAccount(agent, store: store)
        let server = server(agent.name)
        let mark = FormMetrics.markColumn + FormMetrics.markGap
        let name = HStack(spacing: 0) {
            RowMark { AgentGlyph(name: agent.name, size: GlyphSize.row) }
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name.agentLabel).foregroundStyle(FleetStyle.text)
                    .lineLimit(1).truncationMode(.middle)
                if let name = AgentNames.shared.under(agent.name) {
                    Text(name).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).lineLimit(1).truncationMode(.tail)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        let place = Text(server?.name ?? "").foregroundStyle(FleetStyle.muted)
            .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            .help(server?.help ?? "")
        let provider = HStack(spacing: 6) {
            ProviderIcon(runtime: agent.runtime, size: 14)
            Text(account.name).foregroundStyle(FleetStyle.muted).lineLimit(1).truncationMode(.middle)
        }.frame(maxWidth: .infinity, alignment: .leading).help(account.help)
        // The least widths are the ideal ones too, so the one line is the row's shape for as long as they fit; the
        // name and the server keep their whole width first, and the account gives way to "…" in their place.
        return Button { open(agent.name) } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Self.gap) {
                    name.frame(minWidth: mark + min(names, Self.least), idealWidth: mark + min(names, Self.least),
                               maxWidth: mark + names).layoutPriority(1)
                    place.frame(minWidth: min(servers, Self.least), idealWidth: min(servers, Self.least), maxWidth: servers)
                        .layoutPriority(1)
                    if uses { use(agent.name) }
                    provider.frame(minWidth: AgentAccountLine.accountLeast, idealWidth: AgentAccountLine.accountLeast)
                    windows(bar, columns: columns)
                }.frame(minHeight: roles ? FormMetrics.twoLineRow : FormMetrics.row)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: Self.gap) {
                        name.frame(maxWidth: mark + names)
                        place
                    }
                    HStack(spacing: Self.gap) {
                        if uses { use(agent.name) }
                        provider.frame(minWidth: AgentAccountLine.accountLeast, idealWidth: AgentAccountLine.accountLeast)
                        windows(bar, columns: columns)
                    }.padding(.leading, mark)
                }.padding(.vertical, 8).frame(minHeight: FormMetrics.twoLineRow)
                // **The narrowest window** (960 pt with a 520-pt sidebar): CPU and Memory take a line of their own, at
                // the start of the line as on two lines, so their heads still stand over them and nothing is cut.
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: Self.gap) {
                        name.frame(maxWidth: mark + names)
                        place
                    }
                    if uses { use(agent.name).padding(.leading, mark) }
                    HStack(spacing: Self.gap) {
                        provider.frame(minWidth: AgentAccountLine.accountLeast)
                        windows(bar, columns: columns)
                    }.padding(.leading, mark)
                }.padding(.vertical, 8).frame(minHeight: FormMetrics.twoLineRow)
            }
            .font(FormMetrics.text)
            .padding(.horizontal, FormMetrics.rowInset)
        }
        .buttonStyle(FleetRowButtonStyle())
        .accessibilityLabel([agent.name.agentLabel, AgentNames.shared.under(agent.name) ?? "", server?.name ?? "", account.name,
                             account.usage]
            .filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityHint("Opens its chat")
        .accessibilityIdentifier("agents-\(agent.name)")
    }

    /// **What the agent's own sessions use** (the owner's yes of 4 November 2026 to the mockup: "Each agent's own
    /// use"): its share of its server's processors and the memory they hold, as its helper read them, so the agent that
    /// loads a server that several share stands out. What a figure is stands behind its head; an old reading is gray,
    /// with its time on hover; a dash where its helper read nothing yet.
    private func use(_ agent: String) -> some View {
        let machine = machines?.machines.first { $0.agent == agent }
        let old = readFailed || !store.isFresh || machine?.isCurrent(at: time) != true
        let when = old ? machine?.reported_at.map { "Last reading \(fleetDate($0))" } : nil
        let cpu = machine?.use?.cpu, memory = machine?.use?.memory
        return HStack(spacing: Self.gap) {
            Text(cpu.map(LoadWords.percent) ?? "–").monospacedDigit()
                .foregroundStyle(cpu == nil || old ? FleetStyle.muted : FleetStyle.text)
                .frame(width: Self.cpuWidth, alignment: .leading)
                .help(when ?? "")
            Text(memory.map(LoadWords.memory) ?? "–").monospacedDigit()
                .foregroundStyle(memory == nil || old ? FleetStyle.muted : FleetStyle.text)
                .frame(width: Self.memoryWidth, alignment: .leading)
                .help(when ?? "")
        }.lineLimit(1)
    }

    /// The row's windows, each under its head: a bar and its used share, gray for an old reading, and when it resets
    /// under them, on the line of the role under the name. Without a window there is no bar: Not reported, never 0%. A
    /// local model has no account limits, and its row has no bar at all.
    @ViewBuilder private func windows(_ bar: UsageBar?, columns: [String]) -> some View {
        HStack(spacing: Self.gap) {
            if let reading = bar?.reading, !reading.windows.isEmpty {
                let old = !store.isFresh || reading.isStale(at: time)
                let own = reading.ownWindows(at: time)
                ForEach(columns, id: \.self) { title in
                    if let window = own.first(where: { $0.shortTitle == title }) {
                        let stale = old || window.resetIsPast(at: time)
                        // Two lines, as the name and its role: a window with no reset keeps its second line empty, so
                        // the bars of one row stand on one line.
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                AllowanceMeter(used: window.used_percent, stale: stale)
                                Text("\(Int(window.used_percent.rounded()))%").monospacedDigit()
                                    .foregroundStyle(stale ? FleetStyle.muted : FleetStyle.text)
                                    .frame(width: Self.percentWidth, alignment: .trailing)
                            }
                            ResetLine(window: window, now: time, holdsLine: true)
                        }
                        .frame(width: Self.windowWidth, alignment: .leading)
                        .help(words(window, reading: reading, old: old, limit: bar?.limit))
                    } else {
                        Color.clear.frame(width: Self.windowWidth, height: 1)
                    }
                }
            } else if bar?.isLocalModel != true {
                Text("Not reported").foregroundStyle(FleetStyle.muted).lineLimit(1).help(bar?.problem ?? "")
            }
        }.frame(width: Self.windowsWidth(columns), alignment: .leading)
    }

    /// The hover words of one window, as an agent's panel gives them: its full name and used share, the date and time
    /// it resets, and the age of an old reading and the end of a hold where there is one.
    private func words(_ window: UsageWindow, reading: AccountLimits, old: Bool, limit: RuntimeLimit?) -> String {
        var words = "\(window.label): \(window.used_percent.formatted(.number.precision(.fractionLength(0...1))))% used"
        if let resets = window.resets_at { words += " · resets \(fleetDate(ResetLine.minute(resets)))" }
        if old { words += " · last reading \(fleetDate(reading.collected_at))" }
        if let limit { words += " · limited until \(fleetComingTime(limit.until, now: time))" }
        return words
    }

    /// The server an agent runs on, by the machines' reading, with the time of an old reading on hover; nil while the
    /// first read goes on, which takes less than a second once the app has read its fleet.
    private func server(_ agent: String) -> (name: String, help: String)? {
        guard features.contains("machines") else { return nil }
        guard let machines else { return readFailed ? ("Not reported", "") : nil }
        guard let machine = machines.machines.first(where: { $0.agent == agent }) else { return ("Not reported", "") }
        let old = readFailed || !store.isFresh || !machine.isCurrent(at: time)
        return (machine.machine, old ? "Last reading \(fleetDate(machine.reported_at))" : "")
    }

    // MARK: measures

    /// The room between two columns, as in the Servers table.
    private static let gap: CGFloat = 12
    /// The least a name or a server keeps in a narrow window.
    private static let least: CGFloat = 72
    /// The used share's column: "100%" in the row's figures.
    private static let percentWidth = ("100%" as NSString)
        .size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)]).width.rounded(.up)
    /// The CPU column: "100%" in the row's figures, or its head.
    private static let cpuWidth = max(percentWidth,
                                      ("CPU" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width.rounded(.up))
    /// The Memory column: "999 MB" or "99,9 GB" in the row's figures, or its head.
    private static let memoryWidth = (["999 MB", "99,9 GB"].map {
        ($0 as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)]).width
    } + [("Memory" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width]).max()!.rounded(.up)
    /// One window: the meter at its one length and its share, or the reset under them where that is wider.
    private static let windowWidth: CGFloat = max(44 + 8 + percentWidth, ResetLine.widest)
    /// Every window of a row, and at least the words for none.
    private static func windowsWidth(_ columns: [String]) -> CGFloat {
        let none = ("Not reported" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width.rounded(.up)
        return max(none, CGFloat(columns.count) * windowWidth + CGFloat(max(columns.count - 1, 0)) * gap)
    }
    /// The widest of some words in the row's 13 points, at most 180: a role such as "Platform Engineering" too.
    private static func width(_ texts: [String]) -> CGFloat {
        min(180, texts.map { ($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width.rounded(.up) }.max() ?? 0)
    }

    /// Reads the machines every 30 seconds while the page shows, and every 5 seconds until the first answer. The usage
    /// readings are in the fleet's own state, which the store reads every three seconds.
    private func poll() async {
        while !Task.isCancelled {
            if features.contains("machines"), store.isFresh, let database = store.state?.db {
                let hub = store.hub
                let list = try? await HubClient().machines(hub: hub, database: database)
                guard !Task.isCancelled else { return }
                if store.hub == hub, store.state?.db == database {
                    if let list { machines = list; readFailed = false } else { readFailed = true }
                }
            }
            guard !Task.isCancelled else { return }
            do { try await store.nap(machines != nil || readFailed ? 30 : 5) } catch { return }
        }
    }
}
