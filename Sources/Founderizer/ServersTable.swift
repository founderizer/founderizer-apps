import AppKit
import FleetCore
import SwiftUI

/// **The servers of Settings › Servers, in the style of the Agents page** (the owner, 20 November 2026: "I live the
/// Agents section but the Servers one is terrible. It should be exactly the same style!", and his choice B of the two
/// pictures the same day: each server's agents under it). One table, with the windows' short names over their columns
/// once at its top; for each server its row — its mark, its name ("Hub" beside the hub's own machine), its CPU, Memory
/// and Disk in whole percent, "No agent" where none runs on it, and the mark of its state only where it needs something
/// (`ServerStateMark`) — and under it a row for each agent on it, as the Agents page draws one: its glyph, its name with
/// its role under it, the provider's logo and its account, and a bar and the used share of each window with when it
/// resets under them. A click on a server's row opens the server's page; on an agent's row, its chat, as on Agents.
/// The cells stand in columns found by sums (`ServersRowLayout`, as `AgentsRowLayout`), never by measured shapes: the
/// Agents page took 2.3 s of the main thread to open while its rows chose a shape in a `ViewThatFits`.
struct ServersTable: View {
    @Bindable var store: FleetStore
    let list: ServerList
    let helpers: [FleetHealth.Helper]

    private var time: Double { store.state?.time ?? 0 }

    var body: some View {
        let agents = store.state?.agents ?? []
        let bars = UsageBar.bars(for: agents, time: time, isFresh: store.isFresh)
        let names = list.servers.flatMap(\.agents)
        let listed = names.compactMap { name in agents.first { $0.name == name } }
        // The name column holds each agent's name and role, and each server's name with "Hub", which stands one mark
        // further out: a fleet with no agent, or with short names only, must not cut a server's name.
        // (a server's words have the room of an agent's glyph as well, so they need one mark's room less).
        let servers = list.servers.map { Self.serverWidth($0) - 2 * (FormMetrics.markColumn + FormMetrics.markGap) }.max() ?? 0
        let table = Table(
            columns: UsageBar.columns(names.compactMap { bars[$0] }, at: time),
            names: max(Self.width(names.map(\.agentLabel) + names.compactMap { AgentNames.shared.role($0) }), servers),
            accounts: min(Self.accountMost, Self.width(listed.map { AgentAccount($0, store: store).name }) + 14 + 6),
            roles: names.contains { AgentNames.shared.role($0) != nil },
            figures: list.servers.map(Self.figuresWidth).max() ?? 0)
        FormSection {
            if !table.columns.isEmpty { heads(table) }
            ForEach(list.servers) { server in
                serverRow(server, table: table)
                ForEach(server.agents, id: \.self) { name in
                    agentRow(name, server: server.name, agent: agents.first { $0.name == name }, bar: bars[name], table: table)
                }
            }
        }
        // Each agent's own part of a shared account's week, as the Agents page reads it (`keepAccountShares`).
        .task(id: "\(store.hub)/\(store.state?.db ?? "")") { await store.keepAccountShares() }
    }

    /// What every row of the table shares: its windows' heads and the widths of its columns, so each column stands at
    /// one place in every row and under its head.
    private struct Table {
        let columns: [String]
        /// The widest name or role under it, at most 180, or a server's name with "Hub" where that is wider.
        let names: CGFloat
        /// The widest account and its mark, at most `accountMost`.
        let accounts: CGFloat
        /// Some agent has its role under its name: every agent's row has two lines.
        let roles: Bool
        /// The widest figures of a server (`figuresWidth`): every server's row has one shape at a width.
        let figures: CGFloat
    }

    /// The widths of the columns of an agent's row, after the room of its server's mark, so that its glyph stands under
    /// the server's name.
    private func columns(_ table: Table) -> ServersRowLayout.Columns {
        let mark = FormMetrics.markColumn + FormMetrics.markGap
        return ServersRowLayout.Columns(
            indent: mark, mark: mark, gap: Self.gap,
            name: (mark + min(table.names, Self.least), mark + table.names),
            account: (AgentAccountLine.accountLeast, max(AgentAccountLine.accountLeast, table.accounts)),
            windows: Self.windowsWidth(table.columns), figures: table.figures)
    }

    /// The one heading of the table: the short name of each window over its column, built as an agent's row is.
    private func heads(_ table: Table) -> some View {
        let blank = Color.clear.frame(height: 1)
        let windows = HStack(spacing: Self.gap) {
            ForEach(table.columns, id: \.self) {
                Text($0).frame(minWidth: Self.windowWidth, maxWidth: .infinity, alignment: .leading)
            }
        }
        return ServersRowLayout(columns: columns(table), heads: true, least: 0) {
            blank
            blank
            windows
        }
        .lineLimit(1)
        .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
        .padding(.horizontal, FormMetrics.rowInset).frame(minHeight: FormMetrics.headingRow)
        .accessibilityHidden(true)
    }

    // MARK: A server's row

    /// A server: its mark, its name ("Hub" beside the hub's own machine), its figures from where its agents' accounts
    /// stand, and the mark of its state at the end, or nothing while it is well. A click opens its page.
    private func serverRow(_ server: ServerEntry, table: Table) -> some View {
        let state = Servers.state(server, helpers: helpers, time: time, fresh: store.isFresh)
        let column = columns(table)
        return Button { store.destination = .server(server.name) } label: {
            // The figures stand where the agents' accounts do: the same sums place them (`ServersRowLayout.server`).
            ServersRowLayout(columns: column, heads: false, least: FormMetrics.row, server: true) {
                HStack(spacing: 0) {
                    RowMark { IconTile(symbol: server.symbol, size: FormMetrics.markColumn) }
                    HStack(spacing: 8) {
                        Text(server.name).font(FormMetrics.title).foregroundStyle(FleetStyle.text)
                            .lineLimit(1).truncationMode(.middle)
                        if server.hub {
                            Text("Hub").font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).lineLimit(1).fixedSize()
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                figures(server)
                ServerStateMark(state: state).frame(width: FormMetrics.markColumn, alignment: .trailing)
            }
            .font(FormMetrics.text)
            .padding(.horizontal, FormMetrics.rowInset)
        }
        .buttonStyle(FleetRowButtonStyle())
        .accessibilityLabel("\(server.name), \(state.words)").accessibilityHint("Opens the server")
        .accessibilityIdentifier("server-\(server.name)")
    }

    /// **A server's CPU, Memory and Disk** (the owner, 4 November 2026, and his yes to the mockup): each head and the
    /// share in use in whole percent, orange at 90% or more, gray for a reading older than ten minutes, and the amounts
    /// and the time of an old reading on hover; nothing where the hub read none. "No agent" after them where none runs.
    private func figures(_ server: ServerEntry) -> some View {
        let load = server.load
        let old = !store.isFresh || load?.isCurrent(at: time) != true
        let when = old ? load?.at.map { String(l10n: "Last reading \(fleetDate($0))") } : nil
        return HStack(spacing: Self.figureGap) {
            if let load {
                figure(String(l10n: "CPU"), load.cpu, help: when, old: old)
                figure(String(l10n: "Memory"), load.memory,
                       help: [ServerPage.used(load.memory_used, load.memory_total), when].compactMap { $0 }
                           .joined(separator: "\n"), old: old)
                figure(String(l10n: "Disk"), load.disk,
                       help: [ServerPage.used(load.disk_used, load.disk_total), when].compactMap { $0 }
                           .joined(separator: "\n"), old: old)
            }
            if server.agents.isEmpty {
                let none = String(l10n: "No agent")
                Text(none).foregroundStyle(FleetStyle.muted).frame(width: Self.detailWidth(none), alignment: .leading)
            }
        }
        .font(FormMetrics.detail).lineLimit(1)
    }

    /// One figure: its head, and its value in the room of "100%", so that the row keeps its width, and with it its
    /// shape, when a reading gains a digit (`figuresWidth`).
    private func figure(_ head: String, _ share: Double?, help: String?, old: Bool) -> some View {
        HStack(spacing: 4) {
            Text(head).foregroundStyle(FleetStyle.muted).frame(width: Self.detailWidth(head), alignment: .leading)
            Text(share.map(LoadWords.percent) ?? "–").monospacedDigit().rolls(words: share.map(LoadWords.percent) ?? "–")
                .foregroundStyle(old || share == nil ? FleetStyle.muted
                                 : ServerLoad.isHigh(share ?? 0) ? Color.orange : FleetStyle.text)
                .frame(width: Self.valueWidth, alignment: .leading)
        }
        .help(help ?? "")
    }

    // MARK: An agent's row

    /// One agent on the server, as the Agents page draws it: its glyph, its name with its role under it, its provider's
    /// mark and its account, then its windows. A click opens its chat, as on Agents. An agent that the fleet's state
    /// does not hold (a new one, or one removed a moment ago) has its glyph and name only, and a click opens its
    /// server.
    private func agentRow(_ name: String, server: String, agent: FleetAgent?, bar: UsageBar?, table: Table) -> some View {
        let account = agent.map { AgentAccount($0, store: store) }
        let label = HStack(spacing: 0) {
            RowMark { AgentGlyph(name: name, size: GlyphSize.row) }
            VStack(alignment: .leading, spacing: 2) {
                Text(name.agentLabel).foregroundStyle(FleetStyle.text)
                    .lineLimit(1).truncationMode(.middle)
                if let role = AgentNames.shared.role(name) {
                    Text(role).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).lineLimit(1).truncationMode(.tail)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        let provider = Group {
            if let agent, let account {
                HStack(spacing: 6) {
                    ProviderIcon(runtime: agent.runtime, provider: agent.modelProvider, size: 14)
                    Text(account.name).foregroundStyle(FleetStyle.muted).lineLimit(1).truncationMode(.middle)
                }.help(account.help)
            } else {
                Color.clear.frame(height: 1)
            }
        }
        return Button { store.destination = agent == nil ? .server(server) : .agent(name) } label: {
            ServersRowLayout(columns: columns(table), heads: false,
                             least: table.roles ? FormMetrics.twoLineRow : FormMetrics.row) {
                label
                provider
                windows(bar, columns: table.columns, known: agent != nil, agent: name)
            }
            .font(FormMetrics.text)
            .padding(.horizontal, FormMetrics.rowInset)
        }
        .buttonStyle(FleetRowButtonStyle())
        .accessibilityLabel([name.agentLabel, AgentNames.shared.role(name) ?? "", account?.name ?? "", account?.usage ?? ""]
            .filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityHint(agent == nil ? Text("Opens the server") : Text("Opens its chat"))
        .accessibilityIdentifier("servers-agent-\(name)")
    }

    /// The row's windows, each under its head, as the Agents page draws them: a bar and its used share, gray for an old
    /// reading, and when it resets under them. Without a window there is no bar: Not reported, never 0%. A local model
    /// has no account limits, and its row has no bar at all.
    @ViewBuilder private func windows(_ bar: UsageBar?, columns: [String], known: Bool, agent: String) -> some View {
        HStack(spacing: Self.gap) {
            if let reading = bar?.reading, !reading.windows.isEmpty {
                let old = !store.isFresh || reading.isStale(at: time)
                let own = reading.ownWindows(at: time)
                ForEach(columns, id: \.self) { title in
                    if let window = own.first(where: { $0.shortTitle == title }) {
                        let stale = old || window.resetIsPast(at: time)
                        // On the account's main window, the agent's own part of an account that other agents share is
                        // the bar's full fill, as on Agents (`AccountShares`).
                        let part = store.accountShares?.share(of: agent, account: reading.account_key, window: window.label)
                        // Two lines, as the name and its role: a window with no reset keeps its second line empty, so
                        // the bars of one row stand on one line.
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                AllowanceMeter(used: window.used_percent, stale: stale, width: nil, own: part)
                                Text("\(Int(window.used_percent.rounded()))%").monospacedDigit()
                                    .rolls(Int(window.used_percent.rounded()))
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
            } else if known, bar?.isLocalModel != true {
                Text("Not reported").foregroundStyle(FleetStyle.muted).lineLimit(1).help(bar?.problem ?? "")
            }
        }
    }

    /// The hover words of one window, as the Agents page gives them: its full name and used share, the agent's own part
    /// of it, the date and time it resets, and the age of an old reading and the end of a hold where there is one.
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

    // MARK: Measures, as the Agents page's

    /// The room between two columns.
    private static let gap: CGFloat = 12
    /// The least a name keeps in a narrow window.
    private static let least: CGFloat = 72
    /// The used share's column: "100%" in the row's figures.
    private static let percentWidth = ("100%" as NSString)
        .size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)]).width.rounded(.up)
    /// The least of one window: the meter, its share, or the reset under them where that is wider.
    private static let windowWidth: CGFloat = max(44 + 8 + percentWidth, ResetLine.widest)
    /// The most that an account takes before the windows take the rest: about 24 characters, cut in the middle.
    private static let accountMost: CGFloat = 170

    /// Every window of a row, and at least the words for none.
    private static func windowsWidth(_ columns: [String]) -> CGFloat {
        let none = (String(l10n: "Not reported") as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)])
            .width.rounded(.up)
        return max(none, CGFloat(columns.count) * windowWidth + CGFloat(max(columns.count - 1, 0)) * gap)
    }

    /// A server's name in a row's 13-point medium title, with "Hub" and its gap beside the hub's own machine, after
    /// the mark's column. Each part is rounded up, as each stands whole at a whole point.
    private static func serverWidth(_ server: ServerEntry) -> CGFloat {
        let name = (server.name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)])
            .width.rounded(.up)
        let hub = server.hub ? 8 + detailWidth(String(l10n: "Hub")) : 0
        return FormMetrics.markColumn + FormMetrics.markGap + name + hub
    }

    /// The room between two figures.
    private static let figureGap: CGFloat = 14
    /// A figure's value: "100%" in the row's 12-point figures.
    private static let valueWidth = detailWidth("100%", digits: true)

    /// **The figures of a server's row, a sum of fixed widths**: its CPU, Memory and Disk with their heads where the
    /// hub read its load, and "No agent" where none runs on it. A sum, never a measure of the drawn row: a figure that
    /// goes from 99% to 100% must not move the row to two lines and every row under it down (the review of 20 November
    /// 2026), and the table takes the widest, so that every server's row has one shape at a width.
    private static func figuresWidth(_ server: ServerEntry) -> CGFloat {
        var parts = server.load == nil ? [] : [String(l10n: "CPU"), String(l10n: "Memory"), String(l10n: "Disk")]
            .map { detailWidth($0) + 4 + valueWidth }
        if server.agents.isEmpty { parts.append(detailWidth(String(l10n: "No agent"))) }
        return parts.reduce(0, +) + CGFloat(max(parts.count - 1, 0)) * figureGap
    }

    /// Words in the row's 12-point details, rounded up: the width of the frame that holds them whole.
    private static func detailWidth(_ words: String, digits: Bool = false) -> CGFloat {
        let font = digits ? NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular) : NSFont.systemFont(ofSize: 12)
        return (words as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }

    /// The widest of some words in the row's 13 points, at most 180: a role such as "Platform Engineering" too.
    private static func width(_ texts: [String]) -> CGFloat {
        min(180, texts.map { ($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width.rounded(.up) }
            .max() ?? 0)
    }
}

/// **The places of an agent's cells in the Servers table, found by sums** (as `AgentsRowLayout`, which the Agents page
/// opens with in 72 ms where measured shapes took 2.3 s): its name, its account and its windows, after the room of its
/// server's mark (`indent`). **One line** where they fit with every name whole, the account taking up to its whole width
/// and the windows all that is left, so the bars grow with the window; else **two lines**: the name and the account, then
/// the windows under them from where the name's words begin. The heads take only the line that holds the windows.
/// **A server's row** (`server`) has its mark and name, its figures and the mark of its state: the name from the row's
/// start to where an agent's account begins, which the same sums give, so the figures stand at the accounts' place in
/// every width; the figures, whose width is a sum too (`Columns.figures`), go under the name where they do not fit
/// beside it, and the state's mark stays at the end of the first line.
struct ServersRowLayout: Layout {
    struct Columns {
        /// The room of the server's mark before an agent's glyph.
        let indent: CGFloat
        /// The glyph's column and its gap.
        let mark: CGFloat
        let gap: CGFloat
        /// The least and the most of a column that gives way in a narrow window.
        let name: (least: CGFloat, most: CGFloat)
        let account: (least: CGFloat, most: CGFloat)
        /// The least of the windows, which take the rest.
        let windows: CGFloat
        /// A server's row: the width of the widest server's figures, a sum (`ServersTable.figuresWidth`).
        var figures: CGFloat = 0
    }

    let columns: Columns
    /// The heads: they take only the line that holds the windows.
    let heads: Bool
    /// The least height of a row.
    let least: CGFloat
    /// A server's row: its mark and name, its figures, and the mark of its state.
    var server = false

    enum Shape { case one, two }

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

    /// The least width of each shape: the widest of its lines.
    func least(_ shape: Shape) -> CGFloat {
        let c = columns
        switch shape {
        case .one: return c.indent + c.name.most + c.account.least + c.windows + 2 * c.gap
        case .two: return max(c.indent + c.name.least + c.account.least + c.gap, c.indent + c.mark + c.windows)
        }
    }

    /// The shape for a width: one line where it fits. With no width (an ideal size), one line.
    func shape(for width: CGFloat?) -> Shape {
        guard let width, width.isFinite else { return .one }
        return width >= least(.one) ? .one : .two
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
        var flexible = [c.name.least, c.account.least]
        var lines: [(indent: CGFloat, cells: Line)]
        let shape = shape(for: proposed)
        switch shape {
        case .one:
            // Every name whole on one line; the account then takes up to its whole width, and the windows the rest.
            flexible[0] = c.name.most
            var account = [c.account.least]
            let left = grow(&account, [c.account], width - least(.one))
            flexible[1] = account[0]
            lines = [(c.indent, [(0, flexible[0]), (1, flexible[1]), (2, c.windows + left)])]
        case .two:
            _ = grow(&flexible, [c.name, c.account], width - (c.indent + c.name.least + c.account.least + c.gap))
            let windows = max(c.windows, width - c.indent - c.mark)
            lines = (heads ? [] : [(c.indent, [(0, flexible[0]), (1, flexible[1])])]) + [(c.indent + c.mark, [(2, windows)])]
        }
        if server {
            // The name to where an agent's account begins, the figures there up to the state's mark, which ends the line;
            // the figures under the name where they do not fit there.
            let name = c.indent + flexible[0]
            let mark = FormMetrics.markColumn
            let room = width - name - c.gap - mark - c.gap
            lines = c.figures <= room
                ? [(0, [(0, name), (1, max(0, room)), (2, mark)])]
                : [(0, [(0, max(0, width - mark - c.gap)), (2, mark)]), (c.indent, [(1, max(0, width - c.indent))])]
        }
        // Each cell is measured once, at its width; a line is as high as its highest cell, and each cell stands in the
        // middle of its line's height.
        var frames = Array(repeating: CGRect.zero, count: subviews.count)
        let pad: CGFloat = lines.count > 1 ? (heads ? 4 : 8) : 0
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
        var y = (height - rows) / 2
        var tops: [CGFloat] = []
        for high in heights { tops.append(y); y += high + 4 }
        for cell in placed {
            frames[cell.index] = CGRect(x: cell.x, y: tops[cell.line] + (heights[cell.line] - cell.height) / 2,
                                        width: cell.width, height: cell.height)
        }
        return Plan(frames: frames, size: CGSize(width: proposed.flatMap { $0.isFinite ? $0 : nil } ?? widest, height: height))
    }
}
