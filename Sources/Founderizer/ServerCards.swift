import AppKit
import FleetCore
import SwiftUI

/// **The servers of Settings › Servers, a card for each** (the owner's choice C1 of 13 November 2026, after "is this
/// really a screen? it is such a mess", of the list that broke each server into four lines in a window under about 900
/// points): the server's mark, its name and its CPU, memory and disk, in columns whose heads stand once over the cards;
/// under it, each agent on one line: its glyph, its role, the provider's logo in one column (the owner: "VERY
/// IMPORTANTLY the ai provider logos ALIGNED too!"), its account, and a bar and a share for each window of that account
/// under the windows' heads, with the reset on hover.
///
/// **A well server has no mark** (his answer "Nothing" the same day): a server that needs something has one mark at the
/// end of its first line, with its words on hover (`Servers.mark`). Its system and its address are on its own page,
/// which a click on the card opens. The columns come from the cards' width (`ServerCardLayout`): in a narrow window the
/// account goes behind the logo, every cell names its window, and the bars go last, so that nothing is cut.
struct ServerCards: View {
    @Bindable var store: FleetStore
    let list: ServerList
    let helpers: [FleetHealth.Helper]

    private var time: Double { store.state?.time ?? 0 }

    var body: some View {
        let bars = UsageBar.bars(for: store.state?.agents ?? [], time: time, isFresh: store.isFresh)
        let names = list.servers.flatMap(\.agents)
        let columns = UsageBar.columns(names.compactMap { bars[$0] }, at: time)
        let load = list.servers.contains { $0.load != nil }
        let parts = Self.parts(columns)
        let layouts = ServerCardLayout.candidates(role: Self.roleWidth(names), account: Self.accountWidth(names, store: store),
                                                  parts: parts)
        // **The first layout whose lines fit the page**, every card in that one layout, so that a column stands at one
        // place in every card; the last one where none fits.
        ViewThatFits(in: .horizontal) {
            cards(layouts[0], parts: parts, columns: columns, bars: bars, load: load)
            if layouts.count > 3 { cards(layouts[1], parts: parts, columns: columns, bars: bars, load: load) }
            cards(layouts[layouts.count - 2], parts: parts, columns: columns, bars: bars, load: load)
            cards(layouts[layouts.count - 1], parts: parts, columns: columns, bars: bars, load: load)
        }
    }

    /// The heads and the cards in one layout.
    private func cards(_ layout: ServerCardLayout, parts: ServerCardLayout.Parts, columns: [String],
                       bars: [String: UsageBar], load: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if load || (layout.mode == .wide && !columns.isEmpty) {
                heads(layout, parts: parts, columns: columns, load: load)
            }
            ForEach(list.servers) { server in
                FormSection { card(server, layout: layout, parts: parts, columns: columns, bars: bars, load: load) }
            }
        }
    }

    // MARK: The heads

    /// **The heads, once over the cards, each over its column**: CPU, Memory and Disk over the servers' figures, and on
    /// wide cards each window's name over its cells. Hidden from assistive apps: each figure and each cell has its words.
    private func heads(_ layout: ServerCardLayout, parts: ServerCardLayout.Parts, columns: [String], load: Bool)
        -> some View {
        let figures = HStack(spacing: CGFloat(parts.gap)) {
            Text("CPU").frame(width: Self.figureWidth, alignment: .leading)
            Text("Memory").frame(width: Self.figureWidth, alignment: .leading)
            Text("Disk").frame(width: Self.figureWidth, alignment: .leading)
        }.opacity(load ? 1 : 0)
        return HStack(spacing: 0) {
            if layout.mode == .wide, let role = layout.role, let account = layout.account {
                Color.clear.frame(width: Self.lead(role, parts), height: 1)
                figures.frame(width: CGFloat(account), alignment: .leading)
                if !columns.isEmpty {
                    HStack(spacing: CGFloat(parts.gap)) {
                        ForEach(columns, id: \.self) { title in
                            Text(title).lineLimit(1).frame(width: CGFloat(parts.wideCell), alignment: .leading)
                        }
                    }.padding(.leading, CGFloat(parts.gap))
                }
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                figures
            }
            Color.clear.frame(width: CGFloat(parts.end), height: 1)
        }
        .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).lineLimit(1)
        .padding(.horizontal, FormMetrics.rowInset)
        .accessibilityHidden(true)
    }

    // MARK: A card

    /// One server's card: its line, and one line for each agent on it. A click anywhere on it opens the server's page.
    private func card(_ server: ServerEntry, layout: ServerCardLayout, parts: ServerCardLayout.Parts, columns: [String],
                      bars: [String: UsageBar], load: Bool) -> some View {
        let state = Servers.state(server, helpers: helpers, time: time, fresh: store.isFresh)
        return Button { store.destination = .server(server.name) } label: {
            VStack(alignment: .leading, spacing: 6) {
                serverLine(server, state: state, layout: layout, parts: parts, columns: columns, load: load)
                ForEach(server.agents, id: \.self) { name in
                    agentLine(name, layout: layout, parts: parts, columns: columns, bar: bars[name])
                }
            }
            .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(FleetRowButtonStyle())
        .accessibilityLabel("\(server.name), \(state.words)").accessibilityHint("Opens the server")
        .accessibilityIdentifier("server-\(server.name)")
    }

    /// The server's line: its mark, its name ("Hub" beside the hub's own machine), its figures in their columns, and the
    /// mark of its state at the end, or nothing while it is well.
    private func serverLine(_ server: ServerEntry, state: (words: String, attention: Bool), layout: ServerCardLayout,
                            parts: ServerCardLayout.Parts, columns: [String], load: Bool) -> some View {
        let name = HStack(spacing: CGFloat(parts.gap)) {
            IconTile(symbol: server.symbol)
            Text(server.name).font(FormMetrics.title).foregroundStyle(FleetStyle.text)
                .lineLimit(1).truncationMode(.middle)
            // On a wide card only: on a compact one the server's name needs the room (it lost its middle at 420 points).
            if server.hub, layout.mode == .wide {
                Text("Hub").font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).lineLimit(1).fixedSize()
            }
        }
        return HStack(spacing: 0) {
            if layout.mode == .wide, let role = layout.role, let account = layout.account {
                name.frame(width: Self.lead(role, parts), alignment: .leading)
                figures(server.load, parts: parts).opacity(load ? 1 : 0).frame(width: CGFloat(account), alignment: .leading)
                Color.clear.frame(width: CGFloat(parts.cells(columns.count, cell: parts.wideCell)), height: 1)
                Spacer(minLength: 0)
            } else {
                name.frame(maxWidth: .infinity, alignment: .leading)
                if load { figures(server.load, parts: parts).padding(.leading, CGFloat(parts.gap)) }
            }
            ServerStateMark(state: state).frame(width: CGFloat(parts.mark)).padding(.leading, CGFloat(parts.gap))
        }
    }

    /// One agent's line in a card: the room of the server's mark, the agent (`AgentUsageLine`), and the mark's column.
    private func agentLine(_ name: String, layout: ServerCardLayout, parts: ServerCardLayout.Parts,
                           columns: [String], bar: UsageBar?) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: CGFloat(parts.tile + parts.gap), height: 1)
            AgentUsageLine(store: store, name: name, layout: layout, parts: parts, columns: columns, bar: bar)
            if layout.mode == .wide { Spacer(minLength: 0) }
            Color.clear.frame(width: CGFloat(parts.end), height: 1)
        }
    }

    // MARK: The server's figures and its mark

    /// **A server's CPU, memory and disk** (the owner, 4 November 2026, and his yes to the mockup): the share in use in
    /// whole percent, orange at 90% or more, gray for a reading older than ten minutes, and the amounts and the time of
    /// an old reading on hover. Nothing where a figure was not read.
    private func figures(_ load: ServerLoad?, parts: ServerCardLayout.Parts) -> some View {
        let old = !store.isFresh || load?.isCurrent(at: time) != true
        let when = old ? load?.at.map { "Last reading \(fleetDate($0))" } : nil
        return HStack(spacing: CGFloat(parts.gap)) {
            figure(load?.cpu, help: when, old: old)
            figure(load?.memory, help: [ServerPage.used(load?.memory_used, load?.memory_total), when].compactMap { $0 }
                .joined(separator: "\n"), old: old)
            figure(load?.disk, help: [ServerPage.used(load?.disk_used, load?.disk_total), when].compactMap { $0 }
                .joined(separator: "\n"), old: old)
        }.font(FormMetrics.detail)
    }

    private func figure(_ share: Double?, help: String?, old: Bool) -> some View {
        Text(share.map(LoadWords.percent) ?? "").monospacedDigit().lineLimit(1)
            .foregroundStyle(old ? FleetStyle.muted : ServerLoad.isHigh(share ?? 0) ? Color.orange : FleetStyle.text)
            .frame(width: Self.figureWidth, alignment: .leading)
            .help(help ?? "")
    }

    // MARK: Words on hover

    /// The logo's hover: the provider, the plan and the account, and why no usage shows where none was read.
    static func accountHelp(_ account: AgentAccount, bar: UsageBar?) -> String {
        guard bar?.isLocalModel != true, bar?.reading?.windows.isEmpty ?? true else { return account.help }
        return [account.help, [String(l10n: "Usage not reported"), bar?.problem].compactMap { $0 }.joined(separator: ": ")]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// A window's hover, as the Agents page gives it: its full name and used share, the date and time it resets, and the
    /// age of an old reading and the end of a hold where there is one.
    static func words(_ window: UsageWindow, reading: AccountLimits, old: Bool, limit: RuntimeLimit?,
                              now: Double) -> String {
        var words = "\(window.label): \(window.used_percent.formatted(.number.precision(.fractionLength(0...1))))% used"
        if let resets = window.resets_at { words += " · resets \(fleetDate(ResetLine.minute(resets)))" }
        if old { words += " · last reading \(fleetDate(reading.collected_at))" }
        if let limit { words += " · limited until \(fleetComingTime(limit.until, now: now))" }
        return words
    }

    // MARK: Sizes

    /// A figure's column: "100%" in the line's 12-pt figures, or the head "Memory", whichever is wider.
    static let figureWidth: CGFloat = max(width("100%", figures: true), width("Memory")).rounded(.up)

    /// The parts of the cards' lines, with the words of these columns measured in the lines' 12 points.
    static func parts(_ columns: [String]) -> ServerCardLayout.Parts {
        ServerCardLayout.Parts(percent: Double(width("100%", figures: true).rounded(.up)),
                               label: Double((columns.map { width($0) }.max() ?? 0).rounded(.up)),
                               figures: Double(figureWidth * 3 + 12 * 2),
                               accountLeast: Double(width("founder@").rounded(.up)))
    }

    /// The widest role of the cards' agents, at most 200 points.
    static func roleWidth(_ names: [String]) -> Double {
        Double(min(200, (names.map { width($0.agentLabel) }.max() ?? 0).rounded(.up)))
    }

    /// The widest account that a card shows, at most 280 points.
    static func accountWidth(_ names: [String], store: FleetStore) -> Double {
        let agents = names.compactMap { name in store.state?.agents.first { $0.name == name } }
        return Double(min(280, (agents.map { width(shown(AgentAccount($0, store: store))) }.max() ?? 0)
            .rounded(.up)))
    }

    /// The words of an account's column: its address, or "Local model"; nothing without an address.
    static func shown(_ account: AgentAccount?) -> String {
        account.map { $0.name == $0.provider ? "" : $0.name } ?? ""
    }

    /// The start of a wide line before the account's column: the server's mark and gap, the glyph, the role and the logo.
    private static func lead(_ role: Double, _ parts: ServerCardLayout.Parts) -> CGFloat {
        CGFloat(parts.beforeRole + role + parts.roleToAccount)
    }

    private static func width(_ words: String, figures: Bool = false) -> CGFloat {
        let font = figures ? NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular) : NSFont.systemFont(ofSize: 12)
        return (words as NSString).size(withAttributes: [.font: font]).width
    }
}

/// **One agent on one line, in the columns of the Servers cards** (the owner's choice C1 of 13 November 2026): its glyph
/// and its role; the provider's logo, at one place on every line (the owner: "VERY IMPORTANTLY the ai provider logos
/// ALIGNED too!"); on a wide line its account; and its windows, each under its head. The account is on the logo's hover
/// too, and it is the only place of it on a compact line. No words where a figure is missing: an empty cell, with the
/// reason on the logo's hover. A server's card and a server's page draw it, each with its own start and end.
struct AgentUsageLine: View {
    @Bindable var store: FleetStore
    let name: String
    let layout: ServerCardLayout
    let parts: ServerCardLayout.Parts
    let columns: [String]
    let bar: UsageBar?

    private var time: Double { store.state?.time ?? 0 }

    var body: some View {
        let agent = store.state?.agents.first { $0.name == name }
        let account = agent.map { AgentAccount($0, store: store) }
        HStack(spacing: 0) {
            AgentGlyph(name: name, size: GlyphSize.inline).frame(width: CGFloat(parts.glyph))
            Group {
                if let role = layout.role {
                    Text(name.agentLabel).frame(width: CGFloat(role), alignment: .leading)
                } else {
                    Text(name.agentLabel).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            // **Cut in the middle**: the roles of one team often differ only at their end ("Growth Lead", "Growth Writer"),
            // and a cut at the end gave five lines that read the same at 420 points.
            .foregroundStyle(FleetStyle.text).lineLimit(1).truncationMode(.middle).help(name.agentLabel)
            .padding(.leading, CGFloat(parts.small))
            Group {
                if let agent, let account {
                    ProviderIcon(runtime: agent.runtime, size: CGFloat(parts.logo)).help(ServerCards.accountHelp(account, bar: bar))
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            .frame(width: CGFloat(parts.logo)).padding(.leading, CGFloat(parts.gap))
            if let column = layout.account {
                // The account's address, or "Local model"; nothing where the hub read no address: the logo says the
                // provider, so its name does not stand here a second time.
                Text(ServerCards.shown(account)).foregroundStyle(FleetStyle.muted).lineLimit(1).truncationMode(.middle)
                    .frame(width: CGFloat(column), alignment: .leading).padding(.leading, CGFloat(parts.logoGap))
            }
            if !columns.isEmpty {
                HStack(spacing: CGFloat(parts.gap)) {
                    ForEach(columns, id: \.self) { title in cell(title) }
                }.padding(.leading, CGFloat(parts.gap))
            }
        }
        .font(FormMetrics.detail)
    }

    /// One window of the agent's account under its head: the bar and the used share, gray for an old reading; on a
    /// compact line the window's name first; its full name, its reset and the age of an old reading on hover. Empty
    /// without that window, so that the next cell stays under its own head.
    @ViewBuilder private func cell(_ title: String) -> some View {
        let width = CGFloat(layout.mode == .wide ? parts.wideCell : parts.compactCell(meters: layout.meters))
        if let reading = bar?.reading, let window = reading.ownWindows(at: time).first(where: { $0.shortTitle == title }) {
            let stale = !store.isFresh || reading.isStale(at: time) || window.resetIsPast(at: time)
            HStack(spacing: 0) {
                if layout.mode == .compact {
                    Text(window.shortTitle).foregroundStyle(FleetStyle.muted).lineLimit(1)
                        .frame(width: CGFloat(parts.label), alignment: .leading).padding(.trailing, CGFloat(parts.small))
                }
                if layout.meters {
                    AllowanceMeter(used: window.used_percent, stale: stale, width: CGFloat(parts.meter))
                        .padding(.trailing, CGFloat(parts.meterGap))
                }
                Text("\(Int(window.used_percent.rounded()))%").monospacedDigit()
                    .foregroundStyle(stale ? FleetStyle.muted : FleetStyle.text)
                    .frame(width: CGFloat(parts.percent), alignment: .trailing)
            }
            .frame(width: width, alignment: .leading)
            .help(ServerCards.words(window, reading: reading, old: stale, limit: bar?.limit, now: time))
        } else {
            Color.clear.frame(width: width, height: 1)
        }
    }
}

/// **The mark of a server's state** (`Servers.mark`), with the state's words on hover: nothing while it is well (the
/// owner's answer "Nothing" of 13 November 2026), the update mark muted, a job at work a small spinner, what needs him
/// orange, and a last reading the unknown mark.
struct ServerStateMark: View {
    let state: (words: String, attention: Bool)

    var body: some View {
        switch Servers.mark(state) {
        case nil:
            Color.clear.frame(height: 1)
        case .update?:
            Image(systemName: "arrow.up.circle").font(IconMetrics.symbol(12)).foregroundStyle(FleetStyle.muted)
                .help(state.words).accessibilityLabel(state.words)
        case .working?:
            ProgressView().controlSize(.mini).help(state.words).accessibilityLabel(state.words)
        case .attention?:
            Image(systemName: "exclamationmark.circle").font(IconMetrics.symbol(12)).foregroundStyle(.orange)
                .help(state.words).accessibilityLabel(state.words)
        case .unknown? where state.words == Servers.lastReading:
            RowStateMark(state: .unknown).help("Last reading: Founderizer reads this server again when the hub answers.")
        case .unknown?:
            RowStateMark(state: .unknown).help(state.words)
        }
    }
}
