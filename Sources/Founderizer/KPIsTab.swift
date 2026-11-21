import FleetCore
import SwiftUI

/// **An agent's KPIs** (section 8.2 of the KPI design, `~/dev/founderizer-plans/agent-kpis-spec.md`: the picture that
/// the owner saw on 20 November 2026, and his "Fanstastic, create the feature spec first, and adversely review" to
/// "Build this KPI design, with the KPIs tab as shown?"). One card for each active KPI, two or three across and one where
/// the page is narrow: its name, its newest value that counts (red while it is off target; a dash until one counts) and
/// its level, its last 8 weeks as columns with the level's dashed line, and the dates of the first and the last week.
/// A column, a mark and the name say more on hover. Nothing else: no subtitle, no explanation, no footer and no control,
/// because the agent that gives the agent its tasks sets a KPI, and the owner changes one in words to the fleet manager.
///
/// It reads `GET /ui/kpis?agent=` when it opens and again when the hub's change count moves (`HubState.token`).
struct KPIsTab: View {
    let store: FleetStore
    let agent: String
    /// The reading is the store's (`FleetStore.reading`): what he read last shows in the first frame when he comes back,
    /// and it is read before the agent's chat first opens (`PagePrefetch`).
    private var list: AgentKPIs? {
        get { store.reading("kpis.\(agent)") } nonmutating set { store.keep(newValue, as: "kpis.\(agent)") }
    }
    @State private var failure: String?
    private static let unread = String(l10n: "The KPIs could not be read. They are read again when the hub answers.")

    /// The KPIs, read before the agent's sections first open (`PagePrefetch`).
    static let prefetch = PagePrefetch(agent: { "kpis.\($0)" }, feature: AgentKPIs.feature) {
        try await HubClient().kpis(hub: $0, database: $1, agent: $2)
    }

    var body: some View {
        let shown = list.flatMap { $0.db == store.state?.db ? $0 : nil }
        FleetPage(AgentTab.kpis.heading, board: true) {
            // A reading that the hub no longer gives is no current one: its failure stands in its place (UI-PATTERNS,
            // "never an old reading as current"), unless the window's notice already says that the hub is down.
            if let failure, !store.hubNoticeShows {
                FormSection { FormRow(failure, symbol: "exclamationmark.triangle") }
            } else if let shown {
                KPIGrid(kpis: shown.kpis)
            } else {
                LoadingLine(String(l10n: "Reading the KPIs…"))
            }
        }
        .task(id: "\(store.hub)/\(store.state?.db ?? "")/\(agent)") { await read() }
    }

    /// The hub's count of state changes, which a KPI's change moves (`LiveToken.state`); nil before a reading.
    private var changes: UInt64? { LiveToken(store.state?.token)?.state }

    /// Reads the KPIs when the tab opens and again each time the hub's state count moves: a look every 3 seconds, which
    /// asks the hub only when that count moved or the last read failed. A read that fails says so once its reads have
    /// failed one whole break (`FleetStore.pageReadsFailedABreak`), and is read again until it answers.
    private func read() async {
        guard let database = store.state?.db else { return }
        let hub = store.hub, start = ContinuousClock.now
        var seen: UInt64?, done = false, failedSince: ContinuousClock.Instant?
        while !Task.isCancelled {
            let count = changes
            if !done || count != seen {
                let first = list == nil
                do {
                    let fresh = try await HubClient().kpis(hub: hub, database: database, agent: agent)
                    if first { await store.settle(since: start) }
                    guard !Task.isCancelled, store.hub == hub, store.state?.db == database else { return }
                    list = fresh; failure = nil; failedSince = nil; seen = count; done = true
                } catch {
                    guard !Task.isCancelled else { return }
                    if first { await store.settle(since: start) }
                    done = false
                    failedSince = failedSince ?? .now
                    if store.pageReadsFailedABreak(failedSince: failedSince) { failure = HubError.said(error) ?? Self.unread }
                }
            }
            do { try await store.nap(3) } catch { return }
        }
    }
}

/// The cards of the KPIs, in a grid of two or three across, and one where the page is narrow.
struct KPIGrid: View {
    let kpis: [KPI]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: KPICard.least), spacing: KPICard.gap, alignment: .top)],
                  alignment: .leading, spacing: KPICard.gap) {
            ForEach(kpis) { kpi in KPICard(kpi: kpi) }
        }
    }
}

/// One KPI's card.
struct KPICard: View {
    let kpi: KPI
    @Environment(\.colorSchemeContrast) private var contrast

    static let least: CGFloat = 300, gap: CGFloat = 12
    private static let chartHeight: CGFloat = 84, columnGap: CGFloat = 6, stub: CGFloat = 3, dot: CGFloat = 4
    /// The least height of a column that counts: above the stub, so a value of 0 is no week without a value.
    private static let leastColumn: CGFloat = 6
    /// The height of the row of dots, which is their hover's reach.
    private static let dotRow: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: kpi.name).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).lineLimit(1)
                .help(setBy)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // A dash until a value counts, muted, so that "– ≤ 2 h" reads as no value and never as a minus
                Text(verbatim: kpi.shownValue ?? "–").font(FormMetrics.pageTitle).monospacedDigit()
                    .foregroundStyle(kpi.shownValue == nil ? FleetStyle.muted
                                     : kpi.isOff ? FleetTask.MarkTint.failed.color : FleetStyle.text)
                Text(verbatim: kpi.levelWords).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(valueWords)
            chart.padding(.top, 6)
            // The first week's start and the last week's end: the hub's weeks end at the time of its read, so the last
            // date is today's, and the start of the last week made its data look a week old.
            HStack {
                Text(verbatim: day(kpi.weeks.first?.start))
                Spacer(minLength: 8)
                Text(verbatim: day(kpi.weeks.last.map { $0.start + 7 * 86_400 }))
            }
            .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(FleetStyle.surface, in: RoundedRectangle(cornerRadius: FormMetrics.radius))
        .overlay(RoundedRectangle(cornerRadius: FormMetrics.radius)
            .strokeBorder(FleetStyle.hairline(0.08), lineWidth: FleetStyle.edgeWidth(contrast)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kpi-\(kpi.id)")
    }

    /// The weeks as columns on one scale, the level as a dashed line over them, and under a week with changes one dot.
    private var chart: some View {
        let top = kpi.scaleTop
        return VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: Self.columnGap) {
                ForEach(kpi.weeks.indices, id: \.self) { index in column(kpi.weeks[index], top: top) }
            }
            .frame(height: Self.chartHeight, alignment: .bottom)
            .overlay(alignment: .bottom) {
                GeometryReader { box in
                    let y = box.size.height * (1 - CGFloat(min(max(kpi.number / top, 0), 1)))      // inside the chart
                    Path { line in
                        line.move(to: CGPoint(x: 0, y: y))
                        line.addLine(to: CGPoint(x: box.size.width, y: y))
                    }
                    // light enough to stand over a gray column too, not only between them
                    .stroke(FleetStyle.text.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            HStack(spacing: Self.columnGap) {
                ForEach(kpi.weeks.indices, id: \.self) { index in marks(kpi.weeks[index]) }
            }
            .frame(height: Self.dotRow)
        }
    }

    /// One week: its value that counts, as high as its value on the card's one scale, in neutral gray, or red when it is
    /// off target; a week with no value that counts is the short gray stub. Gray for every agent, never the agent's own
    /// colour (the owner, 21 November 2026, "Gray", to the two pictures of a coral agent): coral, amber and rose stood
    /// next to the red of off target, so a good week read as a bad one.
    private func column(_ week: KPI.Week, top: Double) -> some View {
        let counted = kpi.counted(week)
        let height = counted.map { max(Self.leastColumn, Self.chartHeight * CGFloat(max($0, 0) / top)) } ?? Self.stub
        let fill = counted.map { kpi.isOff($0) ? FleetTask.MarkTint.failed.color : FleetStyle.text.opacity(0.55) }
            ?? FleetStyle.muted.opacity(0.5)
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: min(2, height / 2)).fill(fill).frame(height: height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .help(weekWords(week))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(weekWords(week))
    }

    /// The dot under a week with changes, which lists them on hover; none under the other weeks.
    @ViewBuilder private func marks(_ week: KPI.Week) -> some View {
        let changes = kpi.marks(in: week)
        if changes.isEmpty {
            Color.clear.frame(maxWidth: .infinity)
        } else {
            Circle().fill(FleetStyle.muted).frame(width: Self.dot, height: Self.dot)
                .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                .help(changes.map { "\(day($0.at)): \($0.words)" }.joined(separator: "\n"))
                .accessibilityLabel(changes.map(\.words).joined(separator: ". "))
        }
    }

    /// "Week of 14 Nov: 82%", with the value that did not count yet said so, a week with no value, and a value that
    /// counts and is off target said in words too: the red is no word for VoiceOver.
    private func weekWords(_ week: KPI.Week) -> String {
        guard let value = week.value else { return String(l10n: "Week of \(day(week.start)): no value") }
        let amount = KPI.amount(value, kpi.unit)
        if !week.counts { return String(l10n: "Week of \(day(week.start)): \(amount), before it counted") }
        return kpi.isOff(value) ? String(l10n: "Week of \(day(week.start)): \(amount), off target")
            : String(l10n: "Week of \(day(week.start)): \(amount)")
    }

    /// The value and its level as VoiceOver says them: "76%, off target, level ≥ 90%", "No value yet, level ≤ 2 h".
    private var valueWords: String {
        guard let shown = kpi.shownValue else { return String(l10n: "No value yet, level \(kpi.levelWords)") }
        return kpi.isOff ? String(l10n: "\(shown), off target, level \(kpi.levelWords)")
            : String(l10n: "\(shown), level \(kpi.levelWords)")
    }

    /// "Set by Support Lead, 14 Nov."
    private var setBy: String {
        String(l10n: "Set by \(kpi.setter_role ?? kpi.setter.agentLabel), \(day(kpi.created)).")
    }

    private func day(_ time: Double?) -> String {
        guard let time else { return "" }
        return Date(timeIntervalSince1970: time).formatted(.dateTime.day().month(.abbreviated))
    }
}
