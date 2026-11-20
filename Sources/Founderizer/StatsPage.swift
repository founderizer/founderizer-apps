import FleetCore
import FleetMark
import SwiftUI

/// **Settings › Stats** (the owner, 20 November 2026: "maybe there could be a separated Stats page under settings?",
/// then "Yes, as drawn" to its picture, list price in dollars for the columns, Agents and Models for the switch, and
/// "also make sure it works with any ai model provider!!"): the tokens of the fleet's sessions on any runtime in the
/// last 7, 30 or 90 days, from the hub's 15-minute slots (`GET /ui/costs` with `by`, UI-API.md 1.260). One card of the
/// period's totals; the list dollars of each day as a column, its agents' or its models' parts stacked (the five of the
/// most, then all the others in gray), as the Agents page draws its days (`AgentsStrip`); and each agent's or model's
/// own totals in a table whose rows the Agents page's are the model of (`table`). A model of the owner's own server or
/// machine is `own/<model>`, and costs nothing. On a subscription a list price is a weight of the work, not money spent.
struct StatsPage: View {
    @Bindable var store: FleetStore
    @State private var period = 30
    @State private var split: TokenStats.Split = .agents
    /// The words of the page's last read that failed, and when the reads began to fail.
    @State private var failure: String?
    @State private var failedSince: ContinuousClock.Instant?
    @Environment(\.glyphTeam) private var team

    /// The name of the page's reading in the store (`PageReadings`): the last 90 days, read once for every period, so
    /// a change of period draws at once and the page is whole in its first frame.
    static let name = "stats.tokens"
    /// Read before the page first opens (`PagePrefetch.fleet`), with this Mac's own days.
    static let prefetch = PagePrefetch(name, feature: TokenSeries.feature) {
        try await HubClient().tokenSeries(hub: $0, database: $1, from: from(zone: .current))
    }

    private var time: Double { store.state?.time ?? Date().timeIntervalSince1970 }
    private var features: [String] { store.state?.ui_features ?? [] }
    /// The numbers are gray where they are the last ones known, as each page's reading is (`pageReadingIsOld`).
    private var fresh: Bool { !store.pageReadingIsOld(failedSince: failedSince) }

    var body: some View {
        FleetPage(String(l10n: "Stats"), board: true) {
            // the store keeps a reading for this hub and these records alone: after a change of either, the next read
            if let series: TokenSeries = store.reading(Self.name) {
                let stats = TokenStats(series: series,
                                       days: TokenStats.days(count: period, at: time, zone: zone(of: series)),
                                       team: Set(store.state?.agents.map(\.name) ?? []))
                if stats.totals.tokens == 0 {
                    FormSection { FormEmpty(String(l10n: "No tokens"), symbol: "chart.bar.xaxis") }
                } else {
                    // a new period draws at once, as another list of Tasks stands at once; only a new reading of the
                    // same period rolls its numbers (UI-PATTERNS, "Short motions")
                    totals(stats.totals).id(period)
                    chart(stats)
                    table(stats).id(period)
                }
            } else if let failure {
                // said once, over the page, while the window's notice says that the hub does not answer
                if !store.hubNoticeShows { FormSection { FormRow(failure, symbol: "exclamationmark.triangle") } }
            } else {
                LoadingLine(String(l10n: "Reading the tokens…"))
            }
        } actions: {
            FleetSegmented(String(l10n: "Period"), selection: $period,
                           options: [7, 30, 90].map { FleetOption($0, String(l10n: "\($0) days")) })
        }
        .task(id: "\(store.hub)/\(store.state?.db ?? "")") { await poll() }
    }

    // MARK: the three cards

    /// The period's totals in one card, side by side: the four kinds of tokens, the model calls and the list price.
    private func totals(_ sum: TokenStats.Totals) -> some View {
        FormSection {
            HStack(alignment: .top, spacing: Self.gap) {
                tile(String(l10n: "Input"), TokenFormat.tokens(sum.input))
                tile(String(l10n: "Cache read"), TokenFormat.tokens(sum.cacheRead))
                tile(String(l10n: "Cache write"), TokenFormat.tokens(sum.cacheWrite))
                tile(String(l10n: "Output"), TokenFormat.tokens(sum.output))
                tile(String(l10n: "Calls"), TokenFormat.count(sum.calls))
                tile(String(l10n: "List price"), TokenFormat.money(sum.cost))
            }
            .padding(FormMetrics.rowInset)
        }
    }

    private func tile(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).lineLimit(1)
            // a new reading rolls to its digits, as each number of a reading on the Agents page does
            Text(verbatim: value).font(FormMetrics.pageTitle).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                .rolls(words: value)
                .foregroundStyle(fresh ? FleetStyle.text : FleetStyle.muted)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }

    /// The card of the days, with the switch of the chart and the table over it: the columns, or the empty card where no
    /// token has a price (a fleet of the owner's own models), so that the switch stays for the table.
    private func chart(_ stats: TokenStats) -> some View {
        FormSection(String(l10n: "Per day")) {
            if (stats.totals.cost ?? 0) > 0 {
                perDay(stats)
            } else {
                FormEmpty(String(l10n: "No list prices"), symbol: "chart.bar.xaxis")
            }
        } accessory: {
            FleetSegmented(String(l10n: "Group by"), selection: $split,
                           options: [FleetOption(.agents, String(l10n: "Agents")), FleetOption(.models, String(l10n: "Models"))])
        }
    }

    /// The list dollars of each day, a column a day, its parts stacked from the bottom in the order of the series,
    /// under the series' names and over three dates: the first day's, the middle one's, and Today.
    private func perDay(_ stats: TokenStats) -> some View {
        let (series, columns) = stats.chart(split)
        let colors = tints(series, models: stats.models)
        let top = max(columns.map { $0.costs.reduce(0, +) }.max() ?? 0, 0.01)
        let middle = columns.count / 2
        let gap: CGFloat = columns.count > 31 ? 2 : 4
        return VStack(alignment: .leading, spacing: 8) {
            legend(series, colors: colors)
            // **The scale in a column of its own at the right**, the most of a day at the top and the base at the
            // bottom, so that no number stands on a column or on the names over them.
            HStack(alignment: .top, spacing: 8) {
                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(columns.indices, id: \.self) { at in
                        column(columns[at], series: series, colors: colors, top: top).frame(maxWidth: .infinity)
                    }
                }
                .frame(height: Self.chartHeight, alignment: .bottom)
                .overlay(alignment: .top) { Rectangle().fill(FleetStyle.line).frame(height: 1) }
                .overlay(alignment: .bottom) { Rectangle().fill(FleetStyle.line).frame(height: 1) }
                VStack(alignment: .leading) {
                    Text(verbatim: TokenFormat.money(top))
                    Spacer(minLength: 0)
                    Text(verbatim: TokenFormat.money(0))
                }
                .frame(width: Self.scaleWidth, height: Self.chartHeight, alignment: .leading)
                .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).accessibilityHidden(true)
            }
            HStack(spacing: 8) {
                HStack(spacing: gap) {
                    ForEach(columns.indices, id: \.self) { at in
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                            .overlay(alignment: at == 0 ? .leading : at == middle ? .center : .trailing) {
                                if at == 0 || at == middle { Text(verbatim: Self.date(columns[at].day)).fixedSize() }
                                else if at == columns.count - 1 { Text("Today").fixedSize() }
                            }
                    }
                }
                Color.clear.frame(width: Self.scaleWidth, height: 1)
            }
            .frame(height: 15)
            .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
        }
        .padding(FormMetrics.rowInset)
    }

    private func legend(_ series: [TokenStats.Series], colors: [Color]) -> some View {
        HStack(spacing: 14) {
            ForEach(series.indices, id: \.self) { at in
                HStack(spacing: 5) {
                    // an agent's own glyph, whose colour its part of the columns has; a model's colour, then the logo of
                    // its provider; the others' gray
                    if split == .agents, case .group(let key?) = series[at] {
                        AgentGlyph(name: key, size: Self.legendMark, dot: false)
                    } else {
                        RoundedRectangle(cornerRadius: 2).fill(colors[at]).frame(width: 9, height: 9)
                        if split == .models, case .group(let key?) = series[at] { modelMark(key, size: Self.legendMark) }
                    }
                    Text(verbatim: name(series[at])).lineLimit(1)
                }
            }
        }
        .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
    }

    /// One day: each series' part from the bottom, its height its list dollars on the chart's one scale, and the day's
    /// numbers on hover.
    private func column(_ day: TokenStats.Column, series: [TokenStats.Series], colors: [Color],
                        top: Double) -> some View {
        let total = day.costs.reduce(0, +)
        let parts = series.indices.filter { day.costs[$0] > 0 }
        let height = total <= 0 ? 0 : max(2, Self.chartHeight * CGFloat(total / top))
        let room = max(0, height - CGFloat(max(parts.count - 1, 0)) * 1.5)
        return VStack(spacing: 1.5) {
            Spacer(minLength: 0)
            ForEach(parts.reversed(), id: \.self) { at in
                let tall = room * CGFloat(day.costs[at] / max(total, 0.000_001))
                RoundedRectangle(cornerRadius: min(2, tall / 2)).fill(colors[at]).frame(height: tall)
            }
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .help(words(day, series: series))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(words(day, series: series))
    }

    /// A day's hover words: its date and its list price, then each part's, the most first, then its tokens.
    private func words(_ day: TokenStats.Column, series: [TokenStats.Series]) -> String {
        var lines = [String(l10n: "\(Self.date(day.day)) · \(TokenFormat.money(day.totals.cost))")]
        lines += series.indices.filter { day.costs[$0] > 0 }.sorted { day.costs[$0] > day.costs[$1] }
            .map { "\(name(series[$0])) \(TokenFormat.money(day.costs[$0]))" }
        lines.append(String(l10n: "\(TokenFormat.tokens(day.totals.tokens)) tokens, \(TokenFormat.count(day.totals.calls)) calls"))
        return lines.joined(separator: "\n")
    }

    /// **Each agent's or model's own totals, the most list dollars first, as the Agents page draws its rows** (the owner,
    /// 20 November 2026: "the same effects you did on the Agents tab", "more logos"): the agent's glyph with its role over
    /// its name, or the logo of the model's provider; the row's list dollars of each day of the period as small columns
    /// in its own colour, on the one scale of every row, so two rows compare by their height; then each number whole,
    /// with the language's thousands separator, and the dollars with their cents, right-aligned, so the numbers of a
    /// column line up digit under digit as a sheet's do ("column units should be properly aligned ... like in excel").
    /// A new reading rolls each number to its digits.
    private func table(_ stats: TokenStats) -> some View {
        let groups = stats.groups(split)
        let days = stats.dayCosts(split)
        let most = days.values.lazy.flatMap { $0 }.max() ?? 0
        let looks = modelLooks(stats.models)
        // one row height for the table: two lines for every row once an agent has its name under its role
        let height = split == .agents && groups.contains { $0.key.flatMap { AgentNames.shared.under($0) } != nil }
            ? FormMetrics.twoLineRow : FormMetrics.row
        return FormSection(split == .agents ? String(l10n: "Agents") : String(l10n: "Models")) {
            Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 0) {
                GridRow {
                    Color.clear.frame(height: 1).gridColumnAlignment(.leading)
                    if most > 0 { Text(verbatim: String(l10n: "Per day")).gridColumnAlignment(.leading) }
                    ForEach(Self.columns, id: \.self) { Text($0) }
                }
                .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                .padding(.bottom, 6)
                ForEach(groups) { group in
                    Divider().overlay(FleetStyle.line).gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        rowName(group.key).frame(minHeight: height)
                        if most > 0 { strip(days[group.id] ?? [], most: most, tint: tint(of: group.key, looks: looks)) }
                        cell(TokenFormat.count(group.totals.input))
                        cell(TokenFormat.count(group.totals.cacheRead))
                        cell(TokenFormat.count(group.totals.cacheWrite))
                        cell(TokenFormat.count(group.totals.output))
                        cell(TokenFormat.count(group.totals.calls))
                        cell(TokenFormat.money(group.totals.cost, cents: true))
                    }
                    .font(FormMetrics.text).monospacedDigit()
                    .foregroundStyle(fresh ? FleetStyle.text : FleetStyle.muted)
                }
            }
            .padding(.horizontal, FormMetrics.rowInset).padding(.top, FormMetrics.rowInset).padding(.bottom, 4)
        }
    }

    /// A row's name: an agent's glyph and its role over its own name, as the Agents page has them, or the logo of the
    /// model's provider and the model's name; the agents no longer in the team with no mark, under their gray name.
    private func rowName(_ key: String?) -> some View {
        HStack(spacing: 0) {
            RowMark {
                if split == .models {
                    modelMark(key ?? "", size: GlyphSize.row)
                } else if let key {
                    AgentGlyph(name: key, size: GlyphSize.row)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name(.group(key))).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(key == nil ? FleetStyle.muted : FleetStyle.text)
                if split == .agents, let key, let under = AgentNames.shared.under(key) {
                    Text(verbatim: under).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
        }
        .gridColumnAlignment(.leading)
    }

    /// The logo of a model's provider (`TokenStats.provider(of:)`), as the Agents page shows an agent's AI, with the
    /// maker's or the seller's own name on hover, never the program's.
    private func modelMark(_ model: String, size: CGFloat) -> some View {
        let source = TokenStats.provider(of: model)
        let words = source?.name ?? (source?.provider == .own ? String(l10n: "Own model")
                                     : model.isEmpty ? String(l10n: "Unknown model") : String(l10n: "Unknown provider"))
        return ProviderIcon(runtime: source?.runtime ?? "", provider: source?.provider, size: size, label: words)
    }

    /// One number of the table, which rolls to its digits when a new reading changes it.
    private func cell(_ words: String) -> some View {
        Text(verbatim: words).lineLimit(1).rolls(words: words)
    }

    /// **A row's list dollars of each day of the period**, as the Agents page draws an agent's done tasks of each day:
    /// small columns in its colour on the one scale of every row, a day with none at no height, and the strip as wide in
    /// each period, so the table keeps its columns from one period to another.
    private func strip(_ costs: [Double], most: Double, tint: Color) -> some View {
        let count = max(costs.count, 1)
        // a third of the Agents page's gap between columns where 90 days stand in the strip of 30
        let gap = count > 31 ? AgentsPage.dayGap / 3 : AgentsPage.dayGap
        let width = max(gap, (Self.stripWidth - gap * CGFloat(count - 1)) / CGFloat(count))
        return HStack(alignment: .bottom, spacing: gap) {
            ForEach(costs.indices, id: \.self) { day in
                RoundedRectangle(cornerRadius: min(1, width / 2)).fill(tint)
                    .frame(width: width, height: costs[day] <= 0 ? 0 : max(2, AgentsPage.daysHeight * CGFloat(costs[day] / most)))
            }
        }
        .frame(width: Self.stripWidth, height: AgentsPage.daysHeight, alignment: .bottomLeading)
        .gridColumnAlignment(.leading)
        .accessibilityHidden(true)
    }

    // MARK: names, tints and numbers

    private func name(_ part: TokenStats.Series) -> String {
        switch part {
        case .others: String(l10n: "Other")
        case .group(nil): String(l10n: "No longer in the team")
        case .group(let key?):
            split == .agents ? key.agentLabel : key.isEmpty ? String(l10n: "Unknown model") : key
        }
    }

    /// The colour of each series: an agent's own, as its glyph has it; **the models as a team of their own in the
    /// glyphs' nine hues** (`GlyphLook.team`), so that two models differ as two agents do, with no second palette; the
    /// agents no longer in the team and the others in gray.
    private func tints(_ series: [TokenStats.Series], models names: [String]) -> [Color] {
        let looks = modelLooks(names)
        return series.map { part in
            switch part {
            case .others: FleetStyle.muted
            case .group(let key): tint(of: key, looks: looks)
            }
        }
    }

    /// The models' looks as a team of their own, of every model of the reading, the same names in each period, so that
    /// a model keeps its colour in each of them (`TokenStats.models`).
    private func modelLooks(_ names: [String]) -> [String: GlyphLook] {
        split == .models ? GlyphLook.team(names.map { "model " + $0 }) : [:]
    }

    /// The colour of one group, in the chart and in its row: an agent's own, a model's of the team of models, gray for
    /// the agents no longer in the team.
    private func tint(of key: String?, looks: [String: GlyphLook]) -> Color {
        guard let key else { return FleetStyle.muted }
        return split == .agents ? AgentTint(agent: key, team: team).fill
            : AgentTint(look: looks["model " + key] ?? GlyphLook(name: "model " + key)).fill
    }

    private static let columns = [String(l10n: "Input"), String(l10n: "Cache read"), String(l10n: "Cache write"),
                                  String(l10n: "Output"), String(l10n: "Calls"), String(l10n: "List price")]

    /// A day of the hub (`2026-11-19`) as the Agents page writes a date: 19 Nov.
    static func date(_ day: String) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = Calendar(identifier: .gregorian).date(
            from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return day }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    private func zone(of series: TokenSeries) -> TimeZone { TimeZone(identifier: series.zone) ?? .current }

    /// The first of the 90 days that the page reads, a date in `zone`.
    static func from(zone: TimeZone) -> String {
        TokenStats.days(count: 90, at: Date().timeIntervalSince1970, zone: zone).first ?? ""
    }

    /// Reads the last 90 days when the page opens and then every minute, on a clock of its own (`AgentsPage.pollShares`
    /// says why not the store's nap), and keeps them in the store. Its first read asks for this Mac's days; when the
    /// hub's own time zone is another, it reads again at once with that zone's days. A read that failed keeps the last
    /// reading, gray once the reads have failed for a whole break, and says the hub's words where there is none.
    private func poll() async {
        let clock = ContinuousClock()
        while !Task.isCancelled {
            var wait: Double = 60
            if features.contains(TokenSeries.feature), store.isFresh, let database = store.state?.db {
                let hub = store.hub
                let asked = (store.reading(Self.name) as TokenSeries?)?.zone ?? TimeZone.current.identifier
                do {
                    let answer = try await HubClient().tokenSeries(hub: hub, database: database,
                                                                   from: Self.from(zone: TimeZone(identifier: asked) ?? .current))
                    guard !Task.isCancelled else { return }
                    guard store.hub == hub, store.state?.db == database else { continue }
                    store.keep(answer, as: Self.name)
                    failure = nil; failedSince = nil
                    if answer.zone != asked && TimeZone(identifier: answer.zone) != nil { continue }
                } catch {
                    guard !Task.isCancelled else { return }
                    failure = HubError.said(error) ?? String(l10n: "The tokens could not be read.")
                    failedSince = failedSince ?? .now
                }
            } else {
                wait = 3
            }
            do { try await clock.sleep(for: .seconds(wait)) } catch { return }
        }
    }

    private static let gap: CGFloat = 8
    /// A row's strip of days: as wide as 30 of the Agents page's day columns (`AgentsPage.dayWidth`, `dayGap`), in each
    /// period, and as high as them.
    private static let stripWidth = 30 * AgentsPage.dayWidth + 29 * AgentsPage.dayGap
    /// The legend's glyph or logo: the size of the Agents strip's marks beside their words.
    private static let legendMark = AgentsStrip.mark
    private static let chartHeight: CGFloat = 140
    /// The scale's column: "$99.99" and "$10,000" fit in it.
    private static let scaleWidth: CGFloat = 56
}
