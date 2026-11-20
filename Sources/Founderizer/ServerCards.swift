import AppKit
import FleetCore
import SwiftUI

/// **The measures and the words of a server's agents' lines** (`AgentUsageLine`), which a server's own page draws
/// (`ServerPage`). Settings › Servers listed a card for each server with these lines until 20 November 2026, when the
/// owner chose the style of the Agents page for it ("It should be exactly the same style!"; `ServersTable`).
@MainActor enum ServerCards {
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

    /// A figure's column: "100%" in the line's 12-pt figures, or the widest head in the app's language ("Memory";
    /// "Memoria" in Spanish), whichever is wider.
    static let figureWidth: CGFloat = max(width("100%", figures: true), width(String(l10n: "CPU")), width(String(l10n: "Memory")),
                                          width(String(l10n: "Disk"))).rounded(.up)

    /// The parts of a server page's agent lines, with the words of these columns measured in the lines' 12 points.
    static func parts(_ columns: [String]) -> ServerCardLayout.Parts {
        ServerCardLayout.Parts(percent: Double(width("100%", figures: true).rounded(.up)),
                               label: Double((columns.map { width($0) }.max() ?? 0).rounded(.up)),
                               figures: Double(figureWidth * 3 + 12 * 2),
                               accountLeast: Double(width("founder@").rounded(.up)))
    }

    /// The widest role of a server's agents, at most 200 points.
    static func roleWidth(_ names: [String]) -> Double {
        Double(min(200, (names.map { width($0.agentLabel) }.max() ?? 0).rounded(.up)))
    }

    /// The widest account of a server's agents, at most 280 points.
    static func accountWidth(_ names: [String], store: FleetStore) -> Double {
        let agents = names.compactMap { name in store.state?.agents.first { $0.name == name } }
        return Double(min(280, (agents.map { width(shown(AgentAccount($0, store: store))) }.max() ?? 0)
            .rounded(.up)))
    }

    /// The words of an account's column: its address, or "Local model"; nothing without an address.
    static func shown(_ account: AgentAccount?) -> String {
        account.map { $0.name == $0.provider ? "" : $0.name } ?? ""
    }

    private static func width(_ words: String, figures: Bool = false) -> CGFloat {
        let font = figures ? NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular) : NSFont.systemFont(ofSize: 12)
        return (words as NSString).size(withAttributes: [.font: font]).width
    }
}

/// **One agent on one line, in the columns of a server's own page** (the owner's choice C1 of 13 November 2026, for the
/// Servers cards then): its glyph and its role; the provider's logo, at one place on every line (the owner: "VERY
/// IMPORTANTLY the ai provider logos ALIGNED too!"); on a wide line its account; and its windows, each under its head.
/// The account is on the logo's hover too, and it is the only place of it on a compact line. No words where a figure is
/// missing: an empty cell, with the reason on the logo's hover. Settings › Servers draws its agents as the Agents page
/// does since 20 November 2026 (`ServersTable`).
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
                    ProviderIcon(runtime: agent.runtime, provider: agent.modelProvider, size: CGFloat(parts.logo))
                        .help(agent.modelProvider == nil ? ServerCards.accountHelp(account, bar: bar) : account.help)
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
                Text("\(Int(window.used_percent.rounded()))%").monospacedDigit().rolls(Int(window.used_percent.rounded()))
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
