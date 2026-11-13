import FleetCore
import FleetMark
import SwiftUI

/// An agent's own page: its mark, its name and its state, then its usage limit (Usage) and where it runs (Runs on). The
/// name over its chat opens it (the owner's yes of 28 October 2026 to D-5), as a chat app opens a contact from the name
/// over the conversation; it took the place of the agent's row on Fleet, a tab that went (D-4).
///
/// **It has no Activity group** (the owner, 6 November 2026, of the Mac's panel: "i want to remove this panel, and keep
/// tasks internal", and his yes to the same for this page): an agent's tasks are on Tasks, as before.
struct AgentPage: View {
    let store: MobileStore
    let agent: String
    @ScaledMetric(relativeTo: .title) private var scaledMark: CGFloat = 64
    private var markSize: CGFloat { min(scaledMark, 96) }

    private var entry: MobileAgent? { store.agent(agent) }
    private var state: AgentState {
        guard let entry, let snapshot = store.snapshot else { return .unknown }
        return entry.mobileState(in: snapshot, isFresh: store.showsCurrent, thinking: store.thinks(agent))
    }
    /// The windows of the newest usage reading that carry a share, by the Mac's rule (`AccountLimits.ownWindows`): a
    /// window the provider scoped to one model ("7 days (Fable)") only once something is spent in it. An untouched one
    /// is a row that says things are fine, and it stood as a second "7 d".
    private var windows: [MobileUsageWindow] {
        entry?.usage.filter { window in
            guard let percent = window.percent else { return false }
            return percent > 0 || window.label?.range(of: #"\([^)]*\)"#, options: .regularExpression) == nil
        } ?? []
    }

    var body: some View {
        List {
            Section { head }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 0, trailing: 16))
            // The manager's own warning stood over the agents on Fleet: it is about this agent's session.
            if entry?.role == "manager", let warning = store.snapshot?.manager_warning {
                Section {
                    // The mark in the column of a task's mark, as a row of Tasks has it (margins pass, fault 11,
                    // review B).
                    MarkedLine(symbol: "exclamationmark.triangle.fill", markColor: Brand.warning,
                               words: "The manager needs attention: \(hubWords(warning.kind)) since \(fleetDate(warning.since)).",
                               wordsColor: Brand.warning)
                        .font(.footnote)
                        .accessibilityIdentifier("manager-warning")
                }
                .brandRows()
            }
            // A group stands only while it has something to say.
            if entry?.limit != nil || !windows.isEmpty {
                Section { usage } header: { GroupHeading("Usage") }
                    .brandRows()
            }
            if let entry {
                Section {
                    HStack(spacing: 10) {
                        ProviderLogo.image(entry.runtime)?.resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                            .frame(width: 24, height: 24).accessibilityHidden(true)
                        Text(providerName(entry.runtime))
                    }
                    if let machine = entry.machine, !machine.isEmpty { Text(verbatim: machine) }
                } header: {
                    GroupHeading("Runs on")
                }
                .brandRows()
            }
        }
        .listStyle(.insetGrouped)
        .brandPage()
        .refreshable { await store.refresh() }
        // The name stands on the page, under the mark: the bar carries Back and no second copy of it.
        .navigationTitle(agentName(agent))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .toolbar(.hidden, for: .tabBar)
        .hubBanner(store)
    }

    /// The mark, the role (or the name of an agent with no role), the name under the role, and the state, in the middle
    /// of the page: the agent's panel of the Mac (the owner, 10 November 2026: the role is an agent's main label).
    private var head: some View {
        VStack(spacing: 4) {
            AgentMark(name: agent, state: state, size: markSize)
                .padding(.bottom, 6)
            // Semibold, the headings' weight (fix round 2, item 80): the page had three weights, the name in bold.
            Text(agentName(agent)).font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            if let name = AgentNames.shared.under(agent) {
                Text(name).font(.subheadline).foregroundStyle(Brand.muted)
            }
            Text(state.words).font(.subheadline).foregroundStyle(state.wordColor)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// The hub's hold for the usage limit, then each window of the newest reading (the 5 hours and the 7 days, as the
    /// Mac shows them) as its name, a bar and its share, on the Mac's one scale (`UsageBar.Level`): **muted below the
    /// high level, orange from it, red at the limit** (the lead's call on T-08: green means working only), grey for a
    /// reading that is not current, no fill at 0 %. A window without a share is not drawn: a missing reading is never
    /// 0 %. **When the window resets hangs under its bar**, as on the Mac (the owner, 10 November 2026: "could we show
    /// somewhere too WHEN it resets?", and his yes to "↻ 15:00" under every bar): the mark and the coming time, muted;
    /// nothing where the hub has no reset or it has passed. The name, the bar and the share stay on one line.
    @ViewBuilder private var usage: some View {
        if let limit = entry?.limit {
            // Its end by the Mac's rule for a time to come, as the task page and the chat's line say it (item 32).
            Text("Usage limit until \(comingTime(limit.until, now: store.hubNow))").foregroundStyle(Brand.warning)
        }
        ForEach(windows.indices, id: \.self) { index in
            let window = windows[index]
            let percent = window.percent ?? 0
            HStack(spacing: 12) {
                Text(window.shortLabel)
                Spacer(minLength: 8)
                let filled = CGFloat(min(100, max(0, percent))) / 100
                VStack(alignment: .leading, spacing: 6) {
                    Capsule().fill(.quaternary)
                        .frame(width: 96, height: 4)
                        .overlay(alignment: .leading) {
                            Capsule().fill(store.showsCurrent ? level(percent) : Color.secondary)
                                .frame(width: 96 * filled, height: 4)
                                .opacity(filled > 0 ? 1 : 0)
                        }
                    if let resets = resetTime(window) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.clockwise").font(.caption2.weight(.medium))
                            Text(resets).monospacedDigit()
                        }
                        .font(.caption).foregroundStyle(Brand.muted).lineLimit(1)
                        .accessibilityElement(children: .ignore).accessibilityLabel("Resets \(resets)")
                    }
                }
                // The row's line is the bar's middle: the name and the share stand on it, and the reset hangs under it.
                .alignmentGuide(VerticalAlignment.center) { _ in 2 }
                Text("\(percent)%").foregroundStyle(Brand.muted).monospacedDigit()
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// When a window resets, by the rule for a time to come and to the nearest minute, as the Mac says it
    /// (`ResetLine.minute`: a reading's 14:59:59.9 is 15:00): nil without a reset, or once it has passed.
    private func resetTime(_ window: MobileUsageWindow) -> String? {
        guard let resets = window.resets_at, resets > store.hubNow else { return nil }
        return comingTime((resets / 60).rounded() * 60, now: store.hubNow)
    }

    private func level(_ percent: Int) -> Color {
        switch UsageBar.Level(percent: percent) {
        case .low: Brand.muted
        case .high: .orange
        case .full: .red
        }
    }
}
