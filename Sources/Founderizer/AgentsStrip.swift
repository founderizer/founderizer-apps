import FleetCore
import SwiftUI

/// **The fleet's strip over the Agents table** (the owner, 19 November 2026: "the idea is to know how the fleet is and
/// has been performing", and "Counts and chart" to the picture of it that day): four counts at the left — the tasks in
/// work, what needs him (the sidebar's Needs you count, under its name), the tasks done in the last 7 days with the 7
/// days before them, and the results of those 7 days that did not succeed with their share — and the tasks done on
/// each of the last 14 days at the right, one column a day, each agent's part in its own colour (`AgentTint`) and the
/// agents that left in gray. The counts are tasks, by the Tasks board's rules for a task (`HubState.work`). A day's
/// column says its counts on hover. On an old reading the numbers are gray, as every reading of the page is.
struct AgentsStrip: View {
    let work: FleetWork
    /// The team's agents in the table's order: the chart stacks them from the bottom in that order.
    let order: [String]
    /// The hub state is current: else the numbers are the last ones known.
    let fresh: Bool
    @Environment(\.glyphTeam) private var team
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        // The chart beside the counts where it keeps its least width, else under them, by `StripLayout`'s sums: the
        // strip never makes the page wider than the table under it needs, and the chart's card is as high as the counts.
        StripLayout(tiles: Self.tilesWidth, chart: Self.chartLeast, gap: Self.gap) {
            tiles
            chart.card(contrast)
        }
    }

    /// The four counts, two by two.
    private var tiles: some View {
        Grid(horizontalSpacing: Self.gap, verticalSpacing: Self.gap) {
            GridRow {
                tile("In work", count: work.inWork) { if work.inWork > 0 { WorkMark(size: AgentsStrip.mark, moves: false) } }
                tile("Needs you", count: work.needsYou) { if work.needsYou > 0 { Self.needsYouMark } }
            }
            GridRow {
                tile("Done · 7 days", count: work.doneWeek, line: String(l10n: "\(work.doneWeekBefore) the week before")) {}
                tile("Failed · 7 days", count: work.failedWeek, line: work.failedPercent.map { String(l10n: "\($0)% of results") }) {
                    if work.failedWeek > 0 {
                        Image(systemName: "exclamationmark.circle.fill").font(IconMetrics.symbol(Self.mark))
                            .foregroundStyle(FleetTask.MarkTint.failed.color)
                    }
                }
            }
        }
    }

    /// **The mark of what needs him**, here and in the Now column of the table: the orange raised hand of a request
    /// that waits for him, as an agent's panel draws it.
    static var needsYouMark: some View {
        Image(systemName: "hand.raised.fill").font(IconMetrics.symbol(mark)).foregroundStyle(.orange)
    }

    /// The size of the marks of the strip and of the table's Now column: one size for one kind of mark.
    static let mark: CGFloat = 13

    /// One count: its name, its mark and its number, and one line under them where there is one; one element for
    /// VoiceOver, its marks hidden, as the name says what they say.
    private func tile(_ name: LocalizedStringKey, count: Int, line: String? = nil,
                      @ViewBuilder mark: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).lineLimit(1)
            HStack(spacing: 6) {
                mark().accessibilityHidden(true)
                Text(verbatim: "\(count)").font(FormMetrics.pageTitle).monospacedDigit().rolls(count)
                    .foregroundStyle(fresh ? FleetStyle.text : FleetStyle.muted)
            }
            // **Every count has three lines**, an empty one where it has nothing to say under its number: the grid
            // gives its two rows one height, so a count with two lines beside one with three made the counts draw
            // taller than the strip gave them (the review of 19 November 2026).
            Text(verbatim: line ?? " ").font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).lineLimit(1)
                .accessibilityHidden(line == nil)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card(contrast)
        .accessibilityElement(children: .combine)
    }

    /// The done tasks of each day as a column, its agents stacked, under the chart's one heading and over three dates:
    /// the first day's under its column, the middle one's under its column's middle, and Today under the last.
    private var chart: some View {
        let totals = work.dayTotals
        let top = max(totals.max() ?? 0, 1)
        let middle = FleetWork.days / 2
        return VStack(alignment: .leading, spacing: 6) {
            Text("Tasks done each day").font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).lineLimit(1)
            HStack(alignment: .bottom, spacing: Self.columnGap) {
                ForEach(work.dayStarts.indices, id: \.self) { day in
                    column(day, top: top).frame(maxWidth: .infinity)
                }
            }
            .frame(height: Self.chartHeight, alignment: .bottom)
            HStack(spacing: Self.columnGap) {
                ForEach(work.dayStarts.indices, id: \.self) { day in
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                        .overlay(alignment: day == 0 ? .leading : day == middle ? .center : .trailing) {
                            if day == 0 { Text(verbatim: date(work.dayStarts[day])).fixedSize() }
                            else if day == middle { Text(verbatim: date(work.dayStarts[day])).fixedSize() }
                            else if day == FleetWork.days - 1 { Text("Today").fixedSize() }
                        }
                }
            }
            .frame(height: Self.labelHeight)
            .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
        }
    }

    /// One day: each agent's part from the bottom in the table's order, then the agents that left. **The column's height
    /// is its count on the chart's one scale**, and its parts share that height by their counts after the gaps between
    /// them, so a day of four agents with one task each stands lower than a day of one agent with ten. A day with nothing
    /// done is an empty column, which still says its day on hover.
    private func column(_ day: Int, top: Int) -> some View {
        let parts = order.compactMap { name in work.agents[name].flatMap { $0.done[day] > 0 ? (name, $0.done[day]) : nil } }
        let others = work.others[day]
        let total = parts.reduce(others) { $0 + $1.1 }
        let segments = parts.count + (others > 0 ? 1 : 0)
        let height = total == 0 ? 0 : max(2, Self.chartHeight * CGFloat(total) / CGFloat(top))
        let room = max(0, height - CGFloat(max(segments - 1, 0)) * Self.segmentGap)
        func part(_ count: Int) -> CGFloat { room * CGFloat(count) / CGFloat(max(total, 1)) }
        return VStack(spacing: Self.segmentGap) {
            Spacer(minLength: 0)
            if others > 0 { segment(part(others), fill: FleetStyle.muted) }
            ForEach(parts.reversed(), id: \.0) { name, count in
                segment(part(count), fill: AgentTint(agent: name, team: team).fill)
            }
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .help(words(day, parts: parts, others: others, total: total))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(words(day, parts: parts, others: others, total: total))
    }

    private func segment(_ height: CGFloat, fill: Color) -> some View {
        RoundedRectangle(cornerRadius: min(2, height / 2)).fill(fill).frame(height: height)
    }

    /// A day's hover words: its date and its count, then each agent's count, the most first.
    private func words(_ day: Int, parts: [(String, Int)], others: Int, total: Int) -> String {
        var lines = [String(l10n: "\(date(work.dayStarts[day])) · done: \(total)")]
        lines += parts.sorted { $0.1 > $1.1 }.map { "\($0.0.agentLabel) \($0.1)" }
        if others > 0 { lines.append(String(l10n: "Agents no longer in the team \(others)")) }
        return lines.joined(separator: "\n")
    }

    private func date(_ start: Double) -> String {
        Date(timeIntervalSince1970: start).formatted(.dateTime.day().month(.abbreviated))
    }

    // MARK: measures

    private static let gap: CGFloat = 8
    /// The two columns of counts: "Needs you" and "174 the week before" fit in each.
    private static let tilesWidth: CGFloat = 300
    /// The least width of the chart beside the counts, in its card: its heading and its three dates in full, and room
    /// for it beside the counts in the smallest window with the usual sidebar.
    private static let chartLeast: CGFloat = 230
    private static let chartHeight: CGFloat = 96
    private static let labelHeight: CGFloat = 15
    private static let columnGap: CGFloat = 6
    private static let segmentGap: CGFloat = 1.5
}

private extension View {
    /// A card of the page, as a section's: its fill, its corners and its edge, as high as the cards beside it.
    func card(_ contrast: ColorSchemeContrast) -> some View {
        padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(FleetStyle.surface, in: RoundedRectangle(cornerRadius: FormMetrics.radius))
            .overlay(RoundedRectangle(cornerRadius: FormMetrics.radius)
                .strokeBorder(FleetStyle.hairline(0.08), lineWidth: FleetStyle.edgeWidth(contrast)))
    }
}

/// **The strip's two parts, placed by sums** (the owner, 19 November 2026: "it needs to be instant and smooth!"): the
/// counts at their width and the chart beside them, as high as the counts, where the chart keeps its least width; else
/// the chart under the counts, both as wide as the page. Each part is measured once. The `ViewThatFits` that chose
/// before measured both shapes at every measurement of the page, and a measured height then moved the chart's card in
/// a second pass.
private struct StripLayout: Layout {
    let tiles: CGFloat
    let chart: CGFloat
    let gap: CGFloat

    private func beside(_ width: CGFloat?) -> Bool {
        guard let width, width.isFinite else { return true }
        return width >= tiles + gap + chart
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? tiles + gap + chart
        if beside(proposal.width) {
            return CGSize(width: width, height: subviews[0].sizeThatFits(ProposedViewSize(width: tiles, height: nil)).height)
        }
        let counts = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        let days = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        return CGSize(width: width, height: counts + gap + days)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        if beside(bounds.width) {
            subviews[0].place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: tiles, height: bounds.height))
            subviews[1].place(at: CGPoint(x: bounds.minX + tiles + gap, y: bounds.minY), anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width - tiles - gap, height: bounds.height))
        } else {
            let counts = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
            subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: counts))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + counts + gap), anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height - counts - gap))
        }
    }
}

