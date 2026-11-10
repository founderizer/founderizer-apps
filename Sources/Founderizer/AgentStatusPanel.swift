import FleetCore
import SwiftUI

/// The right sidebar of an agent's chat: the basics of its status, in the cards of the app's forms (the owner,
/// 27 October 2026, of four drawn proposals: "something like #2, do not add that orange clock!"). The first card is
/// the agent with its name under its role and its status on its avatar, and the whole card opens Agent details. Under
/// it, each with its name over its card: its usage limits (Usage: the used share of each window of its account, from
/// the newest reading of that account) and what it runs on (Runs on: the account under its provider's own icon, which
/// opens the agent's Runs on, and the machine, which opens its server). One size of mark, one muted colour for it, and
/// two sizes of text run down the whole panel. The panel always shows, and the fleet's own reading every three seconds
/// keeps it current.
///
/// **It has no Activity card** (the owner, 6 November 2026: "i want to remove this panel, and keep tasks internal or
/// maybe in a new section called Tasks", and his yes to the mockup the same day). An agent's tasks are its Tasks part
/// (`AgentTab.tasks`), and what it wrote to other agents is a chat under its People › Conversations
/// (`AgentConversationPage`). The panel reads only the machines, so its cards stand in its first frame.
struct AgentStatusPanel: View {
    @Bindable var store: FleetStore
    let agent: String
    let openDetails: () -> Void
    /// The machines' readings, as this panel, a server's page or an agent's setup read them last
    /// (`FleetStore.reading`): the machine row of every agent's panel shows at once, also the first time its chat opens.
    private var machines: MachineList? {
        get { store.reading("machines") } nonmutating set { store.keep(newValue, as: "machines") }
    }
    private var machine: MachineStatus? { machines?.machines.first { $0.agent == agent } }
    /// The read of this visit failed and none was kept: "Not reported" in place of the wait.
    @State private var readFailed = false
    /// A machine reading came, or the read failed.
    private var machineRead: Bool { machines != nil || readFailed }
    /// The read has gone on for a second: only then does the row say so.
    @State private var slow = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var time: Double { store.state?.time ?? 0 }
    private var features: [String] { store.state?.ui_features ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let current = store.state?.agents.first(where: { $0.name == agent }) { content(current) }
                else { Text("This hub does not list \(agent.agentLabel).").font(FormMetrics.detail).foregroundStyle(FleetStyle.muted) }
            }.padding(.horizontal, 16).padding(.top, FleetSpace.underBand + FleetSpace.lights).padding(.bottom, 16)
        }
        // Its cards a step lighter than a page's, so they stand out from the rail they stand on (fix round 2).
        .environment(\.cardFill, FleetStyle.chrome)
        .background(FleetStyle.rail)
        .task(id: "\(store.hub)/\(store.state?.db ?? "")/\(agent)") { await poll() }
        .task {
            try? await Task.sleep(for: LoadingLine.quiet)
            slow = true
        }
    }

    /// The machines' readings, read before any chat opens (`PagePrefetch`).
    static let prefetch = PagePrefetch("machines", feature: "machines") { try await HubClient().machines(hub: $0, database: $1) }

    @ViewBuilder private func content(_ agent: FleetAgent) -> some View {
        let state = store.state
        let presence = agent.presence(isFresh: store.isFresh, serverTime: time,
                                      openTasks: state?.tasks.filter { $0.owner == agent.name && !$0.isTerminal } ?? [],
                                      holds: state?.holds ?? [])
        let bar = UsageBar.bars(for: state?.agents ?? [], time: time, isFresh: store.isFresh)[agent.name]
        FormSection { agentRow(agent, presence: presence) }
        // A local model has no account limits: the account's own row says Local model, and a card that could only say
        // so again is not drawn.
        if bar?.isLocalModel != true { section("Usage") { usage(bar) } }
        section("Runs on") {
            accountRow(agent)
            machineRow
        }
    }

    /// **The agent and its status, and the way into its details.** The whole card is the button, with the chevron
    /// of a row that opens a page of its own; it took the place of an Agent details capsule under the name.
    ///
    /// **Its name under its role** (the owner, 3 November 2026: "the subtitle I mentioned below the agent name too";
    /// and 10 November 2026: the role, team.json `title`, is an agent's main label). The status is then the dot on its
    /// avatar, as on every other row of the app, with its words on hover; an agent with no role keeps its status words
    /// there.
    private func agentRow(_ agent: FleetAgent, presence: AgentPresence) -> some View {
        let words = store.isFresh ? presence.label : AgentPresence.unknown.label
        return Button(action: openDetails) {
            HStack(spacing: 0) {
                // The head's avatar is the `hero` step, 48 points (the lead's call on T-04 against B-BRAND-4: a panel's
                // or a profile's avatar is 44–64, Grok Bot's panel about 55), so the name stands after it, a mark's gap
                // away, and not in the column of the rows' words under it.
                HStack(spacing: FormMetrics.markGap) {
                    // The avatar keeps the look of the last reading while it is old (`presence`); the words say it is old.
                    AgentAvatar(name: agent.name, presence: presence, size: GlyphSize.hero, moves: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.name.agentLabel).font(FormMetrics.title).foregroundStyle(FleetStyle.text).lineLimit(1)
                        // **Its name under its role** (the owner, 10 November 2026); no line where the role says the name
                        // already ("Fleet Manager"), and an agent with no role keeps its status words there.
                        if let name = AgentNames.shared.under(agent.name) {
                            Text(name).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).lineLimit(1)
                        } else if AgentNames.shared.roles[agent.name] == nil {
                            Text(words).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 12)
                chevron
            }
            .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 11)
        }
        .buttonStyle(FleetRowButtonStyle())
        // "Last reading" says the state is old; when it was read is on hover, as every old reading of the panel.
        .help(store.isFresh ? "\(words) · Agent details" : "Last reading \(fleetDate(time)) · Agent details")
        .accessibilityLabel([agent.name.agentLabel, AgentNames.shared.under(agent.name), words].compactMap { $0 }
            .joined(separator: ", "))
        .accessibilityHint("Opens Agent details")
        .accessibilityIdentifier("agent-details")
    }

    /// **Each window of the account: its name, a bar and the used share**, in one grid, so the bars of a card begin
    /// at one place. An old reading is gray and gives its time on hover; no line and no mark of its own say it
    /// (27 October 2026: "do not add that orange clock!"). A hold of the hub for the agent's usage limit is the status
    /// under the agent's name, Limited, and when it ends is on hover here only: that is a clock time he never acts on
    /// (21 October 2026: "what does back at 13:30 mean?? does not make sense, we dont need that! just say Usage Limit
    /// and the progress bar"). When a window resets is under its bar (`ResetLine`; the owner, 10 November 2026: "could
    /// we show somewhere too WHEN it resets?", and his yes to "↻ 15:00" under every bar): the name, the bar and the share
    /// stay on one line, and the row holds the two lines in its middle. Without a window there is no bar: Not
    /// reported, never 0%.
    @ViewBuilder private func usage(_ bar: UsageBar?) -> some View {
        if let reading = bar?.reading, !reading.windows.isEmpty {
            let old = !store.isFresh || reading.isStale(at: time)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
                ForEach(Array(reading.ownWindows(at: time).enumerated()), id: \.element.id) { index, window in
                    if index > 0 { Rule() }
                    let stale = old || window.resetIsPast(at: time)
                    let words = usageWords(window, reading: reading, old: old, limit: bar?.limit)
                    let resets = ResetLine.time(window, now: time) != nil
                    // One room over the first line and under the last: 44 points for one line, as every row of the
                    // panel, and two lines in the middle of a row of 56 (a grid does not grow a row for a cell's
                    // alignment guide, so the cells start at the top, each with the same room over it).
                    let room = resets ? Self.resetRoom : (FormMetrics.row - Self.line) / 2
                    GridRow(alignment: .top) {
                        Text(window.shortTitle).lineLimit(1).frame(height: Self.line).padding(.vertical, room)
                            .foregroundStyle(stale ? FleetStyle.muted : FleetStyle.text).help(words)
                        // The bar stands in the middle of the line of the name and the share, and the reset under it.
                        VStack(alignment: .leading, spacing: 2) {
                            AllowanceMeter(used: window.used_percent, stale: stale, width: nil).frame(height: Self.line)
                            if resets { ResetLine(window: window, now: time) }
                        }
                        .padding(.vertical, room)
                        .help(words)
                        Text("\(Int(window.used_percent.rounded()))%").monospacedDigit()
                            .frame(height: Self.line).padding(.vertical, room)
                            .foregroundStyle(stale ? FleetStyle.muted : FleetStyle.text).help(words)
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
            .font(FormMetrics.text)
            .padding(.horizontal, FormMetrics.rowInset)
        } else {
            row("Not reported", muted: true).help(bar?.problem ?? "")
        }
    }

    /// The hover words of one window: its full name and used share, the date and time it resets, and the age of an old
    /// reading and the end of a hold where there is one.
    private func usageWords(_ window: UsageWindow, reading: AccountLimits, old: Bool, limit: RuntimeLimit?) -> String {
        var words = "\(window.label): \(window.used_percent.formatted(.number.precision(.fractionLength(0...1))))% used"
        if let resets = window.resets_at { words += " · resets \(fleetDate(ResetLine.minute(resets)))" }
        if old { words += " · last reading \(fleetDate(reading.collected_at))" }
        if let limit { words += " · limited until \(fleetComingTime(limit.until, now: time))" }
        return words
    }

    /// The account the agent runs on, under its provider's own icon (the owner, 3 November 2026: "conversation right
    /// sidebar should show the ai provider icon"): its address, or the provider's name where no address is read, or
    /// Local model. **The whole row opens the agent's Runs on**, as the machine's opens its server ("why is server
    /// clickable but not the account used?"): its AI provider, its account and its usage are there. The provider and
    /// the address are on hover.
    private func accountRow(_ agent: FleetAgent) -> some View {
        let address = AccountEmail(limits: agent.accountLimits, at: time, fresh: store.isFresh, features: features)
            .flatMap { email -> String? in
                switch email {
                case .current(let value), .old(let value): value
                case .unknown: nil
                }
            }
        let provider = providerName(agent.runtime)
        return Button(action: openDetails) {
            // An app icon has a margin of its own inside its square: at 18 points it stands as large as the 14-point
            // symbols of the rows under and over it.
            row(agent.local_model == true ? "Local model" : address ?? provider, opens: true) {
                ProviderIcon(runtime: agent.runtime, size: Self.mark + 4)
            }
        }
        .buttonStyle(FleetRowButtonStyle())
        .help((address.map { "\(provider) · \($0)" } ?? provider) + " · Open Runs on")
        .accessibilityIdentifier("panel-account")
    }

    /// The machine the agent runs on: its name, and the whole row opens its server. Its system, its readings and its
    /// checks are on that server's own page.
    @ViewBuilder private var machineRow: some View {
        if let machine, features.contains("machines") {
            // **After a failed read the last words stay, grey, with the reading's time on hover** (T-14), as every old
            // reading of this panel: the notice over the page says that the hub does not answer.
            let old = readFailed || !store.isFresh
            Button { store.destination = .server(machine.machine) } label: {
                row(machine.machine, symbol: "desktopcomputer", muted: old, opens: true)
            }.buttonStyle(FleetRowButtonStyle())
                .help(old ? "Last reading \(fleetDate(machine.reported_at)) · Open its server" : "Open its server")
                .accessibilityIdentifier("panel-server")
        } else if !features.contains("machines") || machineRead || !store.isFresh {
            // Never "Reading…" while the hub does not answer: nothing is being read.
            row(!features.contains("machines") ? "No server reading" : "Server not reported", symbol: "desktopcomputer", muted: true)
        } else {
            readingRow
        }
    }

    /// **The machine's read, in the one loading look of the app** (`LoadingLine`): its place empty for the first
    /// second, then "Reading…" moving, muted, in the row's text slot, and still words under Reduce Motion. It was a
    /// still "Reading…" of its own, and a blank row VoiceOver could not name.
    private var readingRow: some View {
        HStack(spacing: 0) {
            RowMark { Image(systemName: "desktopcomputer").font(IconMetrics.symbol(Self.mark)).foregroundStyle(FleetStyle.muted) }
            if slow {
                Group {
                    if reduceMotion { Text("Reading…").font(FormMetrics.detail).foregroundStyle(FleetStyle.muted) }
                    else { ShimmeringWords(text: "Reading…") }
                }.transition(.opacity)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 11)
        .frame(minHeight: 44)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: slow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reading")
    }

    // MARK: parts

    /// The one size of every mark in the panel's rows.
    private static let mark: CGFloat = 14

    /// The height of one line of the rows' words: a window's bar stands in the middle of it.
    private static let line = NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 13)).rounded(.up)
    /// The room over and under a window whose reset is under its bar: the two lines in the middle of a row about as
    /// high as `FormMetrics.twoLineRow`.
    private static let resetRoom: CGFloat = 11

    /// A name over one card of rows: the muted name of the group, then the card of the app's forms.
    private func section<Rows: View>(_ title: String, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(FormMetrics.text).foregroundStyle(FleetStyle.muted).padding(.leading, 2)
                .accessibilityAddTraits(.isHeader)
            FormSection { rows() }
        }
    }

    /// One row of a card: a muted mark in the column every mark stands in, its text, and the chevron of a row that
    /// opens a page of its own.
    private func row(_ text: String, symbol: String? = nil, muted: Bool = false, opens: Bool = false) -> some View {
        row(text, muted: muted, opens: opens, marked: symbol != nil) {
            if let symbol { Image(systemName: symbol).font(IconMetrics.symbol(Self.mark)).foregroundStyle(FleetStyle.muted) }
        }
    }

    /// The same row with a mark of its own, such as a provider's icon; `marked: false` leaves the mark's column out.
    private func row<Mark: View>(_ text: String, muted: Bool = false, opens: Bool = false, marked: Bool = true,
                                 @ViewBuilder mark: () -> Mark) -> some View {
        HStack(spacing: 0) {
            if marked { RowMark { mark() }.accessibilityHidden(true) }
            Text(text).font(FormMetrics.text).foregroundStyle(muted ? FleetStyle.muted : FleetStyle.text)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if opens { chevron }
        }
        .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 11)
        .frame(minHeight: 44)
    }

    /// The chevron of a row that opens a page of its own, as on People and Conversations.
    private var chevron: some View {
        Image(systemName: "chevron.right").font(IconMetrics.symbol(11, weight: .semibold)).foregroundStyle(FleetStyle.muted)
            .accessibilityHidden(true)
    }

    /// Reads the agent's machine every 30 seconds while the chat shows, and every 5 seconds until the first answer. The
    /// machines are read before any chat opens.
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
            do { try await store.nap(machineRead ? 30 : 5) } catch { return }
        }
    }
}
