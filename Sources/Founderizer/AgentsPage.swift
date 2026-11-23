import AppKit
import FleetCore
import SwiftUI

/// **Agents**, the page of the sidebar's row under Tasks (the owner, 3 November 2026: "a new section above settings on
/// the left sidepanel: Usage. There we see the agents with the server they're in, the usage bars, ai provider (icon) with
/// account etc ... very minimalistic!", and his yes to its mockup the same day; then, the same evening, "the usage
/// section could be moved below tasks.. and be renamed to Agents. I would like each agent to have its own real name...
/// and also a subtitle like their role in the team"). One table of the agents, in the sidebar's order: each one's glyph,
/// its name with its role (team.json `title`) under it, the server it runs on, its provider's mark and its account, and a bar
/// and the used share of each window of that account, under the window's short name, which stands once over its
/// column, with when the window resets under its bar (`ResetLine`; the owner's yes of 10 November 2026). Agents on one
/// account show its newest reading (`UsageBar`). A click opens the agent's chat, as its sidebar row does. What a row
/// leaves out is on hover, as in an agent's panel: the plan, the reset's date in full, and the time of an old reading,
/// which is gray.
///
/// **How the fleet works and has worked** (the owner, 19 November 2026: "Agents tab should have longer usage progress
/// bars, so it is more visual, and also show the number of tasks each one is currently working on ... the idea is to
/// know how the fleet is and has been performing", and his answers to the two pictures that day: "A: table", "Counts
/// and chart", "Keep all columns"): the fleet's strip over the table (`AgentsStrip`); in each row its tasks in work
/// and its part of what needs him (Now) and its done tasks of each of the last 14 days (`HubState.work`); and bars
/// that take the table's free width, the week bar of a shared account with the agent's own part in full
/// (`AccountShares`).
struct AgentsPage: View {
    @Bindable var store: FleetStore
    let open: (String) -> Void
    /// The machines' readings, as an agent's panel and Settings › Servers read them last (`FleetStore.reading`).
    private var machines: MachineList? {
        get { store.reading("machines") } nonmutating set { store.keep(newValue, as: "machines") }
    }
    /// The read of this visit failed and none was kept: Not reported in the server's place.
    @State private var readFailed = false
    /// When the first of the reads that failed in a row failed: one break of them says nothing (`saysFailed`).
    @State private var readFailedSince: ContinuousClock.Instant?
    /// The machines' reads have failed one whole break, or the fleet's state is old (`FleetStore.pageReadingIsOld`;
    /// 17 November 2026): only then is the last reading gray, and "Not reported" said.
    private var saysFailed: Bool { readFailed && store.pageReadingIsOld(failedSince: readFailedSince) }
    @Environment(\.glyphTeam) private var team
    private var time: Double { store.state?.time ?? 0 }
    private var features: [String] { store.state?.ui_features ?? [] }

    var body: some View {
        let listed = store.state?.agents ?? []
        let agents = ChatList.order(listed.map(\.name), pinned: store.pinned).compactMap { name in listed.first { $0.name == name } }
        let bars = UsageBar.bars(for: listed, time: time, isFresh: store.isFresh)
        let work = store.state?.work()
        // **Its name over its role** (the owner, 22 November 2026: "the Agents page shows the name over the role"): the
        // name is the row's first line, and the role stands under it (`AgentNames`).
        let table = Table(
            columns: UsageBar.columns(agents.compactMap { bars[$0.name] }, at: time),
            names: Self.width(agents.map(\.name.agentLabel) + agents.compactMap { AgentNames.shared.role($0.name) }),
            servers: Self.width(agents.compactMap { server($0.name)?.name }),
            accounts: min(Self.accountMost, Self.width(agents.map { AgentAccount($0, store: store).name }) + 14 + 6),
            // The CPU and Memory columns where the helpers read them (the load readings, 4 November 2026).
            uses: machines?.machines.contains { $0.use != nil } == true,
            // One row height for the table: two lines for every row once any agent has its role under its name.
            roles: agents.contains { AgentNames.shared.role($0.name) != nil },
            most: work?.dayMost ?? 0)
        FleetPage("Agents", board: true) {
            if let work, !agents.isEmpty { AgentsStrip(work: work, order: agents.map(\.name), fresh: store.isFresh) }
            FormSection {
                if agents.isEmpty {
                    FormEmpty("No agents yet", symbol: Self.symbol)
                } else {
                    heads(table)
                    ForEach(agents) {
                        row($0, bar: bars[$0.name], work: work?.agents[$0.name], table: table)
                    }
                }
            }
        }
        .task(id: "\(store.hub)/\(store.state?.db ?? "")") { await poll() }
        .task(id: "\(store.hub)/\(store.state?.db ?? "")") { await store.keepAccountShares() }
    }

    /// The symbol of Agents: two people, which fits the sidebar's mark column ("person.3" stood 6 pt from its word).
    static let symbol = "person.2"

    /// What every row of the table shares: its windows' heads and the widths of its columns, so each column stands at
    /// one place in every row and under its head.
    private struct Table {
        let columns: [String]
        let names: CGFloat
        let servers: CGFloat
        /// The widest account and its mark, at most `accountMost`.
        let accounts: CGFloat
        let uses: Bool
        let roles: Bool
        /// The scale of every row's chart of 14 days (`FleetWork.dayMost`).
        let most: Int
    }

    /// **The cells of one row of the table, in their columns** (`AgentsRowLayout`). A row and the heads are both built
    /// from it, so a head stands over its column in each of the row's three shapes. Every cell is a view of its own,
    /// also where it is empty, so the layout finds each cell at its place.
    private func line(_ table: Table, name: some View, place: some View, use: some View, now: some View, days: some View,
                      provider: some View, windows: some View, heads: Bool = false) -> some View {
        AgentsRowLayout(columns: columns(table), heads: heads,
                        least: heads ? 0 : table.roles ? FormMetrics.twoLineRow : FormMetrics.row) {
            name
            place
            if table.uses { use } else { Color.clear.frame(width: 0, height: 0) }
            // Its own width, also where two counts of two figures need a little more than the column: it reaches into
            // the gap after it rather than cutting a count.
            ZStack(alignment: .leading) { now.fixedSize() }
            ZStack(alignment: .leading) { days }
            provider
            windows
        }
    }

    /// The widths of the table's columns, for `AgentsRowLayout`.
    private func columns(_ table: Table) -> AgentsRowLayout.Columns {
        let mark = FormMetrics.markColumn + FormMetrics.markGap
        return AgentsRowLayout.Columns(
            mark: mark, gap: Self.gap,
            name: (mark + min(table.names, Self.least), mark + table.names),
            place: (min(table.servers, Self.least), table.servers),
            use: table.uses ? Self.cpuWidth + Self.gap + Self.memoryWidth : nil,
            now: Self.nowWidth, days: Self.daysWidth,
            account: (AgentAccountLine.accountLeast, max(AgentAccountLine.accountLeast, table.accounts)),
            windows: Self.windowsWidth(table.columns))
    }

    /// The one heading of the table: the short name of each window over its column, CPU and Memory, Now and 14 days
    /// over theirs, built as a row is (`line`).
    private func heads(_ table: Table) -> some View {
        let blank = Color.clear.frame(height: 1)
        let use = HStack(spacing: Self.gap) {
            Text("CPU").frame(width: Self.cpuWidth, alignment: .leading)
                .help("Its own sessions' share of its server's processors")
            Text("Memory").frame(width: Self.memoryWidth, alignment: .leading)
                .help("The memory its own sessions hold")
        }
        let windows = HStack(spacing: Self.gap) {
            ForEach(table.columns, id: \.self) { Text($0).frame(minWidth: Self.windowWidth, maxWidth: .infinity, alignment: .leading) }
        }
        return line(table, name: blank, place: blank, use: use,
                    now: Text("Now").help("Its tasks in work, and its part of what needs you"),
                    days: Text("14 days").help("Its tasks done on each of the last 14 days"),
                    provider: blank, windows: windows, heads: true)
            .lineLimit(1)
            .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
            .padding(.horizontal, FormMetrics.rowInset).frame(minHeight: FormMetrics.headingRow)
            .accessibilityHidden(true)
    }

    /// One agent: its glyph, its name with its role under it, its server, its CPU and Memory, its tasks now and on each
    /// of the last 14 days, its provider's mark and its account, then its windows. An agent with no role, or whose role
    /// is its label, has that one line, in the middle of the row.
    private func row(_ agent: FleetAgent, bar: UsageBar?, work: AgentWork?, table: Table) -> some View {
        let account = AgentAccount(agent, store: store)
        let server = server(agent.name)
        let name = HStack(spacing: 0) {
            RowMark { AgentGlyph(name: agent.name, size: GlyphSize.row) }
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name.agentLabel).foregroundStyle(FleetStyle.text)
                    .lineLimit(1).truncationMode(.middle)
                if let role = AgentNames.shared.role(agent.name) {
                    Text(role).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).lineLimit(1).truncationMode(.tail)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        let place = Text(server?.name ?? "").foregroundStyle(FleetStyle.muted)
            .lineLimit(1).truncationMode(.middle)
            .help(server?.help ?? "")
        let provider = HStack(spacing: 6) {
            ProviderIcon(runtime: agent.runtime, provider: agent.modelProvider, size: 14)
            Text(account.name).foregroundStyle(FleetStyle.muted).lineLimit(1).truncationMode(.middle)
        }.help(account.help)
        return Button { open(agent.name) } label: {
            line(table, name: name, place: place, use: use(agent.name), now: now(work), days: days(agent.name, work: work, most: table.most),
                 provider: provider, windows: windows(bar, columns: table.columns, agent: agent.name))
                .font(FormMetrics.text)
                .padding(.horizontal, FormMetrics.rowInset)
        }
        .buttonStyle(FleetRowButtonStyle())
        .accessibilityLabel([agent.name.agentLabel, AgentNames.shared.role(agent.name) ?? "", server?.name ?? "",
                             work.map(nowWords) ?? "", work.map(daysWords) ?? "", account.name, account.usage]
            .filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityHint("Opens its chat")
        .accessibilityIdentifier("agents-\(agent.name)")
    }

    /// **Its tasks now** (Now): the mark of work and the count of its tasks in work, then the orange hand and its part of
    /// what needs him (`AgentWork.needsYou`, so the rows add up to the strip's Needs you); nothing where there is none of
    /// either. **The mark of work stands still** (`AgentGlyph.moves`: a table draws work at rest, so the screen does not
    /// move in several places for one agent; its glyph in the sidebar moves). Gray on an old reading.
    private func now(_ work: AgentWork?) -> some View {
        HStack(spacing: 8) {
            if let work, work.inWork > 0 {
                HStack(spacing: 3) {
                    WorkMark(size: AgentsStrip.mark, moves: false)
                    Text(verbatim: "\(work.inWork)").monospacedDigit().rolls(work.inWork)
                }.help(String(l10n: "In work: \(work.inWork)"))
            }
            if let work, work.needsYou > 0 {
                HStack(spacing: 3) {
                    AgentsStrip.needsYouMark
                    Text(verbatim: "\(work.needsYou)").monospacedDigit().rolls(work.needsYou)
                }.help(String(l10n: "Needs you: \(work.needsYou)"))
            }
        }.foregroundStyle(store.isFresh ? FleetStyle.text : FleetStyle.muted).lineLimit(1)
    }

    private func nowWords(_ work: AgentWork) -> String {
        [work.inWork > 0 ? String(l10n: "In work: \(work.inWork)") : nil,
         work.needsYou > 0 ? String(l10n: "Needs you: \(work.needsYou)") : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }

    private func daysWords(_ work: AgentWork) -> String {
        work.doneInDays > 0 ? String(l10n: "Done in 14 days: \(work.doneInDays)") : ""
    }

    /// **Its done tasks of each of the last 14 days**, one small column a day in its own colour (`AgentTint`), on the one
    /// scale of every row, so two rows compare by their height; how many on hover. Nothing for an agent that did none.
    @ViewBuilder private func days(_ agent: String, work: AgentWork?, most: Int) -> some View {
        if let work, work.doneInDays > 0, most > 0 {
            let tint = AgentTint(agent: agent, team: team).fill
            HStack(alignment: .bottom, spacing: Self.dayGap) {
                ForEach(work.done.indices, id: \.self) { day in
                    let count = work.done[day]
                    RoundedRectangle(cornerRadius: 1).fill(tint)
                        .frame(width: Self.dayWidth,
                               height: count == 0 ? 0 : max(2, Self.daysHeight * CGFloat(count) / CGFloat(most)))
                }
            }
            .frame(height: Self.daysHeight, alignment: .bottom)
            .contentShape(Rectangle())
            .help(daysWords(work))
        }
    }

    /// **What the agent's own sessions use** (the owner's yes of 4 November 2026 to the mockup: "Each agent's own
    /// use"): its share of its server's processors and the memory they hold, as its helper read them, so the agent that
    /// loads a server that several share stands out. What a figure is stands behind its head; an old reading is gray,
    /// with its time on hover; a dash where its helper read nothing yet.
    private func use(_ agent: String) -> some View {
        let machine = machines?.machines.first { $0.agent == agent }
        let old = saysFailed || !store.isFresh || machine?.isCurrent(at: time) != true
        let when = old ? machine?.reported_at.map { String(l10n: "Last reading \(fleetDate($0))") } : nil
        let cpu = machine?.use?.cpu, memory = machine?.use?.memory
        return HStack(spacing: Self.gap) {
            // A new reading rolls to its digits (`rolls`), as each number of a reading on this page does.
            Text(cpu.map(LoadWords.percent) ?? "–").monospacedDigit().rolls(words: cpu.map(LoadWords.percent) ?? "–")
                .foregroundStyle(cpu == nil || old ? FleetStyle.muted : FleetStyle.text)
                .frame(width: Self.cpuWidth, alignment: .leading)
                .help(when ?? "")
            Text(memory.map(LoadWords.memory) ?? "–").monospacedDigit().rolls(words: memory.map(LoadWords.memory) ?? "–")
                .foregroundStyle(memory == nil || old ? FleetStyle.muted : FleetStyle.text)
                .frame(width: Self.memoryWidth, alignment: .leading)
                .help(when ?? "")
        }.lineLimit(1)
    }

    /// The row's windows, each under its head: a bar and its used share, gray for an old reading, and when it resets
    /// under them, on the line of the role under the name. Without a window there is no bar: Not reported, never 0%. A
    /// local model has no account limits, and its row has no bar at all. Each window takes an equal part of the room that
    /// the table leaves its windows, and its meter all of it but its share's figures. On the account's main window, the
    /// agent's own part of an account that other agents share is the bar's full fill (`AccountShares`).
    @ViewBuilder private func windows(_ bar: UsageBar?, columns: [String], agent: String) -> some View {
        HStack(spacing: Self.gap) {
            if let reading = bar?.reading, !reading.windows.isEmpty {
                let old = !store.isFresh || reading.isStale(at: time)
                let own = reading.ownWindows(at: time)
                ForEach(columns, id: \.self) { title in
                    if let window = own.first(where: { $0.shortTitle == title }) {
                        let stale = old || window.resetIsPast(at: time)
                        let part = store.accountShares?.share(of: agent, account: reading.account_key, window: window.label)
                        // Two lines, as the name and its role: a window with no reset keeps its second line empty, so
                        // the bars of one row stand on one line.
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                AllowanceMeter(used: window.used_percent, stale: stale, width: nil, own: part)
                                Text("\(Int(window.used_percent.rounded()))%").monospacedDigit().rolls(Int(window.used_percent.rounded()))
                                    .foregroundStyle(stale ? FleetStyle.muted : FleetStyle.text)
                                    .frame(width: Self.percentWidth, alignment: .trailing)
                            }
                            ResetLine(window: window, now: time, holdsLine: true)
                        }
                        .frame(minWidth: Self.windowWidth, maxWidth: .infinity, alignment: .leading)
                        .help(words(window, reading: reading, old: old, limit: bar?.limit, part: part, agent: agent))
                    } else {
                        Color.clear.frame(minWidth: Self.windowWidth, maxWidth: .infinity, maxHeight: 1)
                    }
                }
            } else if bar?.isLocalModel != true {
                Text("Not reported").foregroundStyle(FleetStyle.muted).lineLimit(1).help(bar?.problem ?? "")
            }
        }
    }

    /// The hover words of one window, as an agent's panel gives them: its full name and used share, the date and time
    /// it resets, the agent's own part of it, and the age of an old reading and the end of a hold where there is one.
    private func words(_ window: UsageWindow, reading: AccountLimits, old: Bool, limit: RuntimeLimit?, part: Double?,
                       agent: String) -> String {
        var words = String(l10n: "\(window.label): \(window.used_percent.formatted(.number.precision(.fractionLength(0...1))))% used")
        if let part {
            words += " · " + String(l10n: "\(part.formatted(.number.precision(.fractionLength(0...1))))% by \(agent.agentLabel)")
        }
        if let resets = window.resets_at { words += " · " + String(l10n: "resets \(fleetDate(ResetLine.minute(resets)))") }
        if old { words += " · " + String(l10n: "last reading \(fleetDate(reading.collected_at))") }
        if let limit { words += " · " + String(l10n: "limited until \(fleetComingTime(limit.until, now: time))") }
        return words
    }

    /// The server an agent runs on, by the machines' reading, with the time of an old reading on hover; nil while the
    /// first read goes on, which takes less than a second once the app has read its fleet.
    private func server(_ agent: String) -> (name: String, help: String)? {
        guard features.contains("machines") else { return nil }
        guard let machines else { return saysFailed ? (String(l10n: "Not reported"), "") : nil }
        guard let machine = machines.machines.first(where: { $0.agent == agent }) else { return (String(l10n: "Not reported"), "") }
        let old = saysFailed || !store.isFresh || !machine.isCurrent(at: time)
        return (machine.machine, old ? String(l10n: "Last reading \(fleetDate(machine.reported_at))") : "")
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
    } + [(String(l10n: "Memory") as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width]).max()!.rounded(.up)
    /// The least of one window: the meter at the length it had before it grew with the window, and its share, or the
    /// reset under them where that is wider.
    private static let windowWidth: CGFloat = max(44 + 8 + percentWidth, ResetLine.widest)
    /// The most that an account takes before the windows take the rest: about 24 characters, cut in the middle.
    private static let accountMost: CGFloat = 170
    /// Now: the mark of work and two figures, then the mark of what needs him and two figures, or its head; a mark is a
    /// little wider than its 13 points.
    private static let nowWidth: CGFloat = max(2 * (AgentsStrip.mark + 2 + 3 + figures("99")) + 8,
                                               (String(l10n: "Now") as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width.rounded(.up))
    /// 14 days: one small column a day. Settings › Stats draws its rows' days with the same measures (`StatsPage`).
    static let dayWidth: CGFloat = 3, dayGap: CGFloat = 1.5, daysHeight: CGFloat = 20
    private static let daysWidth: CGFloat = max(CGFloat(FleetWork.days) * dayWidth + CGFloat(FleetWork.days - 1) * dayGap,
                                                (String(l10n: "14 days") as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width.rounded(.up))
    private static func figures(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)]).width.rounded(.up)
    }
    /// Every window of a row, and at least the words for none.
    private static func windowsWidth(_ columns: [String]) -> CGFloat {
        let none = (String(l10n: "Not reported") as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width.rounded(.up)
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
                    if let list { machines = list; readFailed = false; readFailedSince = nil }
                    else { readFailed = true; readFailedSince = readFailedSince ?? .now }
                }
            }
            guard !Task.isCancelled else { return }
            // 3 s after a read that failed, as the lists do: the gray goes as soon as the hub is back.
            do { try await store.nap(readFailed ? 3 : machines != nil ? 30 : 5) } catch { return }
        }
    }
}

/// **The places of one row's cells, found by sums, never by measuring shapes** (the owner, 19 November 2026: "after
/// clicking on the page it takes a while to respond and load, it needs to be instant and smooth!"). The row's three
/// shapes stood in a `ViewThatFits` in each row, in the heads and in the strip, and each measurement of the page
/// measured every shape again: on his fleet the page took 2.3 s of the main thread to open, where the page before
/// these columns took 0.13 s. This layout takes the width that the table gives the row, picks the shape whose least
/// widths fit, and measures each cell once at its width.
///
/// The shapes, as before: **one line**, where it fits; **two lines**, the name, the server, Now and 14 days, then under
/// them the CPU and Memory, the account and the windows (a wide sidebar in a small window); **three lines**, the name
/// and the server, then CPU, Memory, Now and 14 days, then the account and the windows (960 pt with a 520-pt sidebar).
/// The name, the server and the account take up to their whole width first, in that order, and the windows all that is
/// left: **the bars grow with the window**. The heads take the lines of a row that hold a head. The cells are, in this
/// order: the name, the server, CPU and Memory, Now, 14 days, the account and the windows.
struct AgentsRowLayout: Layout {
    struct Columns {
        let mark: CGFloat
        let gap: CGFloat
        /// The least and the most of a column that gives way in a narrow window.
        let name: (least: CGFloat, most: CGFloat)
        let place: (least: CGFloat, most: CGFloat)
        /// CPU and Memory; nil where no helper reads them, which takes their column and its gap away.
        let use: CGFloat?
        let now: CGFloat
        let days: CGFloat
        let account: (least: CGFloat, most: CGFloat)
        /// The least of the windows, which take the rest.
        let windows: CGFloat
    }

    let columns: Columns
    /// The heads: they take only the lines that hold a head, with less room above and under them.
    let heads: Bool
    /// The least height of a row.
    let least: CGFloat

    enum Shape { case one, two, three }

    /// Where each cell stands, and the row's size.
    struct Plan {
        var frames: [CGRect]
        var size: CGSize
    }

    struct Cache {
        var width: CGFloat?
        var plan: Plan?
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        plan(width: proposal.width, subviews: subviews, cache: &cache).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let plan = plan(width: bounds.width, subviews: subviews, cache: &cache)
        for (index, subview) in subviews.enumerated() {
            let frame = index < plan.frames.count ? plan.frames[index] : .zero
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    // MARK: the sums

    private var useRoom: CGFloat { columns.use.map { $0 + columns.gap } ?? 0 }

    /// The least width of each shape: the widest of its lines.
    func least(_ shape: Shape) -> CGFloat {
        let c = columns
        switch shape {
        case .one:
            return c.name.least + c.place.least + useRoom + c.now + c.days + c.account.least + c.windows + 5 * c.gap
        case .two:
            return max(c.name.least + c.place.least + c.now + c.days + 3 * c.gap,
                       c.mark + useRoom + c.account.least + c.windows + c.gap)
        case .three:
            return max(c.name.least + c.place.least + c.gap,
                       c.mark + useRoom + c.now + c.days + c.gap,
                       c.mark + c.account.least + c.windows + c.gap)
        }
    }

    /// The shape for a width: the one with the fewest lines whose least width fits. With no width (an ideal size), one
    /// line.
    func shape(for width: CGFloat?) -> Shape {
        guard let width, width.isFinite else { return .one }
        if width >= least(.one) { return .one }
        if width >= least(.two) { return .two }
        return .three
    }

    private func plan(width: CGFloat?, subviews: Subviews, cache: inout Cache) -> Plan {
        if let plan = cache.plan, cache.width == width { return plan }
        let plan = make(width: width, subviews: subviews)
        cache.width = width
        cache.plan = plan
        return plan
    }

    /// One line of cells: each cell's index and width, from the left edge of the line.
    private typealias Line = [(index: Int, width: CGFloat)]

    private func make(width proposed: CGFloat?, subviews: Subviews) -> Plan {
        let c = columns
        let shape = shape(for: proposed)
        let width = proposed.flatMap { $0.isFinite ? $0 : nil } ?? least(.one)
        /// Gives `extra` to the columns in order, each up to its most, and says what is left.
        func grow(_ widths: inout [CGFloat], _ ranges: [(least: CGFloat, most: CGFloat)], _ extra: CGFloat) -> CGFloat {
            var left = max(0, extra)
            for index in widths.indices {
                let more = min(left, max(0, ranges[index].most - ranges[index].least))
                widths[index] += more
                left -= more
            }
            return left
        }
        let use: Line = c.use.map { [(2, $0)] } ?? []
        var lines: [(indent: CGFloat, cells: Line)] = []
        switch shape {
        case .one:
            var flexible = [c.name.least, c.place.least, c.account.least]
            let left = grow(&flexible, [c.name, c.place, c.account], width - least(.one))
            lines = [(0, [(0, flexible[0]), (1, flexible[1])] + use + [(3, c.now), (4, c.days), (5, flexible[2]),
                                                                       (6, c.windows + left)])]
        case .two:
            var first = [c.name.least, c.place.least]
            _ = grow(&first, [c.name, c.place], width - (c.name.least + c.place.least + c.now + c.days + 3 * c.gap))
            var account = [c.account.least]
            let left = grow(&account, [c.account], width - (c.mark + useRoom + c.account.least + c.windows + c.gap))
            // The heads' first line holds Now and 14 days over theirs, with the empty name and server as its room.
            lines = [(0, [(0, first[0]), (1, first[1]), (3, c.now), (4, c.days)]),
                     (c.mark, use + [(5, account[0]), (6, c.windows + left)])]
        case .three:
            var first = [c.name.least, c.place.least]
            _ = grow(&first, [c.name, c.place], width - (c.name.least + c.place.least + c.gap))
            var account = [c.account.least]
            let left = grow(&account, [c.account], width - (c.mark + c.account.least + c.windows + c.gap))
            lines = (heads ? [] : [(0, [(0, first[0]), (1, first[1])])])
                + [(c.mark, use + [(3, c.now), (4, c.days)]), (c.mark, [(5, account[0]), (6, c.windows + left)])]
        }
        // Each cell is measured once, at its width; a line is as high as its highest cell, and each cell stands in the
        // middle of its line's height.
        var frames = Array(repeating: CGRect.zero, count: subviews.count)
        let pad: CGFloat = lines.count > 1 ? (heads ? 4 : 8) : 0
        var y = pad
        var widest: CGFloat = 0
        var placed: [(index: Int, x: CGFloat, width: CGFloat, height: CGFloat, line: Int)] = []
        var heights: [CGFloat] = []
        for (number, line) in lines.enumerated() {
            var x = line.indent
            var high: CGFloat = 0
            for cell in line.cells where cell.index < subviews.count {
                let size = subviews[cell.index].sizeThatFits(ProposedViewSize(width: cell.width, height: nil))
                placed.append((cell.index, x, cell.width, size.height, number))
                high = max(high, size.height)
                x += cell.width + c.gap
            }
            widest = max(widest, x - c.gap)
            heights.append(high)
        }
        let rows = heights.reduce(0, +) + CGFloat(max(lines.count - 1, 0)) * 4
        let height = max(least, rows + 2 * pad)
        // A row higher than its lines (its least height) keeps its lines in its middle.
        y = (height - rows) / 2
        var tops: [CGFloat] = []
        for high in heights { tops.append(y); y += high + 4 }
        for cell in placed {
            frames[cell.index] = CGRect(x: cell.x, y: tops[cell.line] + (heights[cell.line] - cell.height) / 2,
                                        width: cell.width, height: cell.height)
        }
        return Plan(frames: frames, size: CGSize(width: proposed.flatMap { $0.isFinite ? $0 : nil } ?? widest, height: height))
    }
}

