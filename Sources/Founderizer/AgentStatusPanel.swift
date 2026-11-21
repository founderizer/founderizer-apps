import FleetCore
import SwiftUI

/// The right sidebar of an agent's chat: the basics of its status, in the cards of the app's forms (the owner,
/// 27 October 2026, of four drawn proposals: "something like #2, do not add that orange clock!"). The first card is
/// the agent, its name and role on one line at the size of its sidebar row, with its status on its avatar, and the
/// whole card opens Agent details. Under
/// it, each with its name over its card: its usage limits (Usage: the used share of each window of its account, from
/// the newest reading of that account) and what it runs on (Runs on: the account under its provider's own icon, which
/// opens the agent's Runs on, and the machine, which opens its server). One size of mark and two sizes of text run
/// down the whole panel; the marks of Usage and Runs on are muted, and the marks of Asked wear a task mark's colours. The panel always shows, and the fleet's own reading every three seconds
/// keeps it current.
///
/// **It has no Activity card** (the owner, 6 November 2026: "i want to remove this panel, and keep tasks internal or
/// maybe in a new section called Tasks", and his yes to the mockup the same day). An agent's tasks are its Tasks part
/// (`AgentTab.tasks`), and what it wrote to other agents is a chat under its People › Conversations
/// (`AgentConversationPage`). The panel reads only the machines, so its cards stand in its first frame.
///
/// **Asked: the things that he asked this agent for** (`AskedCard`; the owner, 15 November 2026: "a super short summary
/// of the status ... on the right sidebar ... I am not interested in the specific individual tasks to be done but in the
/// thing I asked for to be done", and to its picture, "Both places"). It is not the Activity card again: no task and no
/// message between agents is in it, only his own messages that became work, one row each. A thing that waits for him
/// has the orange raised hand of a request that stops work; one that is in progress has the mark of work, which turns
/// only while a turn of it runs, and says which other agent works on it and what its turn does; one that ended shows
/// its checked result one time, until he leaves this chat, a failed one with its red word. **Every other open one only
/// waits, and stands under them as its row in the chat does** (`ChatAskLine`): muted, in the Tasks board's words, and
/// a click opens its task (the owner, 17 November 2026, of the row "2 waiting", which opened Tasks for all agents and
/// not these things: "if it's only 3 elements you could have shown them there directly!"). **Four or more are one row
/// with their number**, which opens them in place under it and closes them again, its chevron turned down while they
/// are open (his "Yes, fold them" to the pictures of four, closed and open). **Its last row is always View all**, which
/// opens Tasks with this agent chosen, where each thing that he asked it is one card, in the board's period (his words of
/// the same day: "I also want a way to see them - so I see the tasks page but filtered by agent, maybe after the fold
/// always add like a button/link to View all?", and his "Yes, build it" to its picture). A row that comes or goes
/// fades, and the rows that show keep the order in which he asked. The card is not there while there is nothing to
/// say. It reads the fleet's own state, so it stands in the panel's first frame.
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
    /// When the first of the reads that failed in a row failed: one break of them says nothing (`saysFailed`).
    @State private var readFailedSince: ContinuousClock.Instant?
    /// The machines' reads have failed one whole break, or the fleet's state is old (`FleetStore.pageReadingIsOld`;
    /// 17 November 2026): only then is the last reading gray, and "Server not reported" said.
    private var saysFailed: Bool { readFailed && store.pageReadingIsOld(failedSince: readFailedSince) }
    /// A machine reading came, or the reads failed one whole break.
    private var machineRead: Bool { machines != nil || saysFailed }
    /// The read has gone on for a second: only then does the row say so.
    @State private var slow = false
    /// He opened the row of the things that only wait, in the card Asked, to their own rows.
    @State private var showsWaits = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var time: Double { store.state?.time ?? 0 }
    private var features: [String] { store.state?.ui_features ?? [] }
    /// **What he has seen of the things that ended, in the card Asked**, as JSON: for each fleet and agent
    /// ("<fleet's id>/<agent>") the time of the newest end that its card showed him, and for each fleet
    /// ("<fleet's id>/") the hub's time when this Mac first drew the card for it, so that a Mac that reads a fleet for
    /// the first time does not show that fleet's whole past. One number for each agent: it does not grow with the
    /// asks. This Mac keeps it: what he has seen here is no fact of the fleet.
    @AppStorage("askedSeen", store: AppDefaults.store) private var seenAsks = ""
    private var seenTimes: [String: Double] {
        get { (try? JSONDecoder().decode([String: Double].self, from: Data(seenAsks.utf8))) ?? [:] }
        nonmutating set { seenAsks = (try? JSONEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) } ?? seenAsks }
    }

    var body: some View {
        let asked = askedCard(agent)
        let work = store.state.map { WorkCard($0, agent: agent, asks: store.asks) }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let current = store.state?.agents.first(where: { $0.name == agent }) { content(current, asked: asked, work: work) }
                else { Text("This hub does not list \(agent.agentLabel).").font(FormMetrics.detail).foregroundStyle(FleetStyle.muted) }
            }.padding(.horizontal, 16).padding(.top, FleetSpace.underBand + FleetSpace.lights).padding(.bottom, 16)
                // **A row of Asked that comes or goes fades, and the cards under it move with it**, not in one frame:
                // the column stays, so the change of the card's rows is its to move. Nothing moves under Reduce Motion.
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2),
                           value: asked.rows.map(\.id) + askedWaitKeys(asked) + (work.map(Self.workKeys) ?? []))
        }
        // Its cards a step lighter than a page's, so they stand out from the rail they stand on (fix round 2).
        .environment(\.cardFill, FleetStyle.chrome)
        .background(FleetStyle.rail)
        .task(id: "\(store.hub)/\(store.state?.db ?? "")/\(agent)") { await poll() }
        .task {
            try? await Task.sleep(for: LoadingLine.quiet)
            slow = true
        }
        // What ended and showed here, he has seen once he leaves this chat, for another agent's or for another page:
        // the panel of another agent is another view (`FleetView` gives it its agent as its id).
        .onDisappear { see() }
        .onChange(of: store.state?.db, initial: true) { _, fleet in
            if let fleet, time > 0, seenTimes["\(fleet)/"] == nil { seenTimes["\(fleet)/"] = time }
        }
    }

    /// The card Asked of one agent, from the fleet's state as it is now.
    private func askedCard(_ agent: String) -> AskedCard {
        guard let state = store.state else { return AskedCard([], agent: agent, after: .infinity) }
        let seen = seenTimes
        // A fleet that this Mac has not drawn the card for yet shows nothing that ended.
        return AskedCard(store.asks, agent: agent,
                         after: max(seen["\(state.db)/"] ?? .infinity, seen["\(state.db)/\(agent)"] ?? -.infinity),
                         state: state)
    }

    /// He has seen what ended in this agent's card.
    private func see() {
        guard let fleet = store.state?.db, let ended = askedCard(agent).endedAt else { return }
        seenTimes["\(fleet)/\(agent)"] = ended
    }

    /// The machines' readings, read before any chat opens (`PagePrefetch`).
    static let prefetch = PagePrefetch("machines", feature: "machines") { try await HubClient().machines(hub: $0, database: $1) }

    @ViewBuilder private func content(_ agent: FleetAgent, asked: AskedCard, work: WorkCard?) -> some View {
        let state = store.state
        let open = state?.tasks.filter { $0.owner == agent.name && !$0.isTerminal } ?? []
        let presence = agent.presence(isFresh: store.isFresh, serverTime: time, openTasks: open, holds: state?.holds ?? [],
                                      waits: state?.ownerWaits(of: open) ?? [:], request: state?.ownKeyRequest(of: agent.name),
                                      thinking: store.thinks(agent.name))
        let bar = UsageBar.bars(for: state?.agents ?? [], time: time, isFresh: store.isFresh)[agent.name]
        FormSection { agentRow(agent, presence: presence) }
        if !asked.isEmpty { section(AskedCard.title) { askedRows(asked) }.transition(.opacity) }
        if let work, !work.isEmpty { section(WorkCard.title) { workRows(work) }.transition(.opacity) }
        // A local model has no account limits: the account's own row says Local model, and a card that could only say
        // so again is not drawn.
        if bar?.isLocalModel != true { section(String(l10n: "Usage")) { usage(bar) } }
        section(String(l10n: "Runs on")) {
            accountRow(agent)
            machineRow
        }
    }

    /// **The agent and its status, and the way into its details.** The whole card is the button, with the chevron
    /// of a row that opens a page of its own; it took the place of an Agent details capsule under the name.
    ///
    /// **Its name and role on one line, at the size of its row in the sidebar** (the owner, 20 November 2026: "make
    /// the agent card the same size as the row on the left, so it is consistent"): the glyph at the list's size, the
    /// shared `AgentNameLine` ("Nova · Customer Support") in the row's text, 50 points high, as `ChatRow`. The status
    /// is the dot on its avatar, as on every other row of the app, with its words on hover; an agent with no role keeps
    /// its status words under its name.
    private func agentRow(_ agent: FleetAgent, presence: AgentPresence) -> some View {
        let words = store.isFresh ? presence.label : AgentPresence.unknown.label
        return Button(action: openDetails) {
            HStack(spacing: 0) {
                // The name begins in the column of the words of the marked rows under it, as in the sidebar's row.
                HStack(spacing: FormMetrics.markColumn + FormMetrics.markGap - GlyphSize.list) {
                    // The avatar keeps the look of the last reading while it is old (`presence`); the words say it is old.
                    AgentAvatar(name: agent.name, presence: presence, size: GlyphSize.list, moves: store.marksMove)
                    VStack(alignment: .leading, spacing: 2) {
                        AgentNameLine(agent: agent.name).font(FormMetrics.text).foregroundStyle(FleetStyle.text)
                        if AgentNames.shared.roles[agent.name] == nil {
                            Text(words).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 12)
                chevron
            }
            .padding(.horizontal, FormMetrics.rowInset).frame(height: 50)
        }
        .buttonStyle(FleetRowButtonStyle())
        // "Last reading" says the state is old; when it was read is on hover, as every old reading of the panel.
        .help(store.isFresh ? "\(words) · Agent details" : "Last reading \(fleetDate(time)) · Agent details")
        .accessibilityLabel([AgentNames.shared.under(agent.name), agent.name.agentLabel, words].compactMap { $0 }
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
                        Text("\(Int(window.used_percent.rounded()))%").monospacedDigit().rolls(Int(window.used_percent.rounded()))
                            .frame(height: Self.line).padding(.vertical, room)
                            .foregroundStyle(stale ? FleetStyle.muted : FleetStyle.text).help(words)
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
            .font(FormMetrics.text)
            .padding(.horizontal, FormMetrics.rowInset)
        } else {
            row(String(l10n: "Not reported"), muted: true).help(bar?.problem ?? "")
        }
    }

    /// The hover words of one window: its full name and used share, the date and time it resets, and the age of an old
    /// reading and the end of a hold where there is one.
    private func usageWords(_ window: UsageWindow, reading: AccountLimits, old: Bool, limit: RuntimeLimit?) -> String {
        var words = String(l10n: "\(window.label): \(window.used_percent.formatted(.number.precision(.fractionLength(0...1))))% used")
        if let resets = window.resets_at { words += " · " + String(l10n: "resets \(fleetDate(ResetLine.minute(resets)))") }
        if old { words += " · " + String(l10n: "last reading \(fleetDate(reading.collected_at))") }
        if let limit { words += " · " + String(l10n: "limited until \(fleetComingTime(limit.until, now: time))") }
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
            row(agent.local_model == true ? String(l10n: "Local model") : address ?? provider, opens: true) {
                ProviderIcon(runtime: agent.runtime, size: Self.mark + 4)
            }
        }
        .buttonStyle(FleetRowButtonStyle())
        .help((address.map { "\(provider) · \($0)" } ?? provider) + " · " + String(l10n: "Open Runs on"))
        .accessibilityIdentifier("panel-account")
    }

    /// The machine the agent runs on: its name, and the whole row opens its server. Its system, its readings and its
    /// checks are on that server's own page.
    @ViewBuilder private var machineRow: some View {
        if let machine, features.contains("machines") {
            // **After a failed read the last words stay, grey, with the reading's time on hover** (T-14), as every old
            // reading of this panel: the notice over the page says that the hub does not answer.
            let old = saysFailed || !store.isFresh
            Button { store.destination = .server(machine.machine) } label: {
                row(machine.machine, symbol: "desktopcomputer", muted: old, opens: true)
            }.buttonStyle(FleetRowButtonStyle())
                .help(old ? "Last reading \(fleetDate(machine.reported_at)) · Open its server" : "Open its server")
                .accessibilityIdentifier("panel-server")
        } else if !features.contains("machines") || machineRead || !store.isFresh {
            // Never "Reading…" while the hub does not answer: nothing is being read.
            row(!features.contains("machines") ? String(l10n: "No server reading") : String(l10n: "Server not reported"), symbol: "desktopcomputer", muted: true)
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
                    else { ShimmeringWords(text: String(l10n: "Reading…")) }
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

    /// **The rows of Asked**: one for each thing with news, then the things that only wait (`AskedCard.waits`): their
    /// own rows while they are three or fewer, else one row with their number, which opens them under it and closes them
    /// again, as the "more" of the Tasks board's Ended does; then View all. The row with their number opened Tasks for
    /// all agents, the whole fleet's board and not these things (the owner, 17 November 2026: "it takes me to the
    /// entire Tasks page, without any filter at all"): View all opens it with this agent chosen.
    @ViewBuilder private func askedRows(_ card: AskedCard) -> some View {
        ForEach(card.rows) { row in askedRow(row).transition(.opacity) }
        if !card.waitsInRows {
            Button { showsWaits.toggle() } label: {
                self.row(AskedCard.waitingWords(card.waiting), muted: true, opens: true, opened: showsWaits) {
                    Color.clear.frame(width: 1, height: 1)
                }
            }
            .buttonStyle(FleetRowButtonStyle())
            .accessibilityValue(showsWaits ? String(localized: "Open (a state)", defaultValue: "Open", bundle: Localized.bundle,
                                                    locale: Localized.digits) : String(l10n: "Closed"))
            .accessibilityIdentifier("panel-asked-waiting")
        }
        if card.waitsInRows || showsWaits {
            ForEach(card.waits) { row in askedRow(row).transition(.opacity) }
        }
        // Tasks keeps the agent chosen for its next visit, as its own filter does, and has this chat's back link.
        Button { AppDefaults.store.set(agent, forKey: "activityAgent"); store.destination = .activityFrom(agent) } label: {
            self.row(String(l10n: "View all"), muted: true, opens: true) { Color.clear.frame(width: 1, height: 1) }
        }
        .buttonStyle(FleetRowButtonStyle())
        .accessibilityIdentifier("panel-asked-all")
    }

    /// What of the card Asked's things that only wait shows, for its fade: their rows, and the row of their number.
    private func askedWaitKeys(_ card: AskedCard) -> [String] {
        (card.waitsInRows || showsWaits ? card.waits.map { "wait-\($0.id)" } : []) + (card.waitsInRows ? [] : ["waiting"])
    }

    /// One thing that he asked for: its mark, its name on one line, and under it one muted line that says where it
    /// stands. The row opens the request that it waits on, on Needs you, else its task. **One that only waits says
    /// why as its row in the chat says it** (`ChatAskLine`): until when its work is parked, in the Tasks board's words
    /// ("Resumes at 15:00"), else its task's state word.
    private func askedRow(_ row: AskedCard.Row) -> some View {
        let line = row.until.map { fleetResumes($0, now: time) } ?? row.line
        let words = row.until == nil ? row.words : line
        let open = {
            if let request = row.request { store.selectedNeed = request; store.destination = .needs }
            else if let task = row.task { store.show(.task(task)) }
        }
        return Button(action: open) {
            HStack(spacing: 0) {
                RowMark {
                    switch row.mark {
                    // The orange raised hand of a request that stops work (`NeedsBoard`), and the board's own marks.
                    case .waitsForOwner: Image(systemName: "hand.raised.fill").font(IconMetrics.symbol(Self.mark)).foregroundStyle(.orange)
                    case .working:
                        // The mark turns only while its task is work now (`moves`); else it stands still, muted.
                        if row.moves { WorkMark(size: Self.mark, moves: store.marksMove) }
                        else { Image(systemName: "circle.dotted").font(IconMetrics.symbol(Self.mark)).foregroundStyle(FleetStyle.muted) }
                    case .done: Image(systemName: "checkmark.circle.fill").font(IconMetrics.symbol(Self.mark)).foregroundStyle(FleetTask.MarkTint.checked.color)
                    case .failed: Image(systemName: "exclamationmark.circle.fill").font(IconMetrics.symbol(Self.mark)).foregroundStyle(FleetTask.MarkTint.failed.color)
                    // What only waits: its task's mark at rest, muted, as the board draws a task that waits.
                    case .quiet(let symbol, _):
                        if row.moves { WorkMark(size: Self.mark, moves: store.marksMove) }
                        else { Image(systemName: symbol).font(IconMetrics.symbol(Self.mark)).foregroundStyle(FleetStyle.muted) }
                    }
                }.accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(FormMetrics.text).foregroundStyle(FleetStyle.text).lineLimit(1)
                    if !line.isEmpty {
                        // The word of a result that did not succeed is red, as on the board; every other line is muted.
                        Text(line).font(FormMetrics.detail).lineLimit(1)
                            .foregroundStyle(row.mark == .failed ? EndedRow.failedWords : FleetStyle.muted)
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 9)
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(FleetRowButtonStyle())
        .help([row.title, words].filter { !$0.isEmpty }.joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([row.title, words].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        // The element of its words is no button's own: VoiceOver's press (AXPress) did nothing while a click opened it
        .accessibilityAction(.default, open)
        .accessibilityIdentifier("panel-asked-\(row.id)")
    }

    /// **The rows of Work** (`WorkCard`; the owner's "Yes, as drawn" of 17 November 2026): each task that waits for him,
    /// each thing that a turn works on now by its name, then the newest things that ended, each with how it ended and
    /// how long ago. A row of a thing opens it in the card over the window (`openWork`).
    @ViewBuilder private func workRows(_ card: WorkCard) -> some View {
        ForEach(card.waits) { wait in
            // The orange raised hand of a request that stops work, as Asked draws it, and it opens what Asked's opens.
            workRow(title: wait.title, line: wait.line, id: "wait-\(wait.id)") {
                if let request = wait.request { store.selectedNeed = request; store.destination = .needs }
                else { store.show(.task(wait.id)) }
            } mark: {
                Image(systemName: "hand.raised.fill").font(IconMetrics.symbol(Self.mark)).foregroundStyle(.orange)
            }.transition(.opacity)
        }
        ForEach(card.working) { row in
            workRow(title: row.title, line: row.words, id: "now-\(Self.key(row.id))", opensPage: true) {
                openWork(row.id)
            } mark: {
                // It turns only by a current reading of this wake (`marksMove`), and rests green before the hub's
                // first answer after a wake: motion says that the work goes on now (UI-PATTERNS, "Statuses must be
                // true").
                if store.isFresh { WorkMark(size: Self.mark, moves: store.marksMove) }
                else { Image(systemName: "circle.dotted").font(IconMetrics.symbol(Self.mark)).foregroundStyle(FleetStyle.muted) }
            }.transition(.opacity)
        }
        ForEach(card.ended) { row in
            // How it ended and how long ago, "Drafted · 50 min ago"; a result that did not succeed is red, as on Asked.
            let line = [row.words, row.endedAt.map { activityAge($0, now: time) } ?? ""].filter { !$0.isEmpty }
                .joined(separator: " · ")
            workRow(title: row.title, line: line, id: "ended-\(Self.key(row.id))", failed: row.end == .failed, opensPage: true) {
                openWork(row.id)
            } mark: {
                switch row.end {
                case .done: Image(systemName: "checkmark.circle.fill").font(IconMetrics.symbol(Self.mark)).foregroundStyle(FleetTask.MarkTint.checked.color)
                case .failed: Image(systemName: "exclamationmark.circle.fill").font(IconMetrics.symbol(Self.mark)).foregroundStyle(FleetTask.MarkTint.failed.color)
                default: Image(systemName: "circle").font(IconMetrics.symbol(Self.mark)).foregroundStyle(FleetStyle.muted)
                }
            }.transition(.opacity)
        }
    }

    /// **A thing of the work in the card over the window** (`HubState.detail(of:agent:)`): the job level of a thing
    /// that has a case or more than one task (`JobDetail`), else the task level of its one task.
    private func openWork(_ key: WorkItem.Key) {
        if let place = store.state?.detail(of: key, agent: agent) { store.show(place) }
    }

    /// One row of Work, as one row of Asked: its mark, its title on one line, and one line under it, muted, or red
    /// for a result that did not succeed. A row of a thing, which opens its card over the window, ends in the chevron of
    /// a row that opens something of its own, as the picture of 17 November 2026 drew it.
    private func workRow<Mark: View>(title: String, line: String, id: String, failed: Bool = false, opensPage: Bool = false,
                                     open: @escaping () -> Void, @ViewBuilder mark: () -> Mark) -> some View {
        Button(action: open) {
            HStack(spacing: 0) {
                RowMark { mark() }.accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(FormMetrics.text).foregroundStyle(FleetStyle.text).lineLimit(1)
                    if !line.isEmpty {
                        Text(line).font(FormMetrics.detail).lineLimit(1)
                            .foregroundStyle(failed ? EndedRow.failedWords : FleetStyle.muted)
                    }
                }
                Spacer(minLength: 8)
                if opensPage { chevron }
            }
            .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 9)
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(FleetRowButtonStyle())
        .help([title, line].filter { !$0.isEmpty }.joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, line].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, open)        // VoiceOver's press opens it, as a click does
        .accessibilityIdentifier("panel-work-\(id)")
    }

    /// A thing of the work in a row's name: "case-906", "task-12".
    private static func key(_ key: WorkItem.Key) -> String {
        switch key {
        case .dutyCase(let id): "case-\(id)"
        case .task(let id): "task-\(id)"
        }
    }

    /// What of the card Work comes or goes, for its fade.
    private static func workKeys(_ card: WorkCard) -> [String] {
        card.waits.map { "work-wait-\($0.id)" } + card.working.map { "work-now-\(key($0.id))" }
            + card.ended.map { "work-ended-\(key($0.id))" }
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
    /// opens a page of its own, or its rows in place.
    private func row(_ text: String, symbol: String? = nil, muted: Bool = false, opens: Bool = false) -> some View {
        row(text, muted: muted, opens: opens, marked: symbol != nil) {
            if let symbol { Image(systemName: symbol).font(IconMetrics.symbol(Self.mark)).foregroundStyle(FleetStyle.muted) }
        }
    }

    /// The same row with a mark of its own, such as a provider's icon; `marked: false` leaves the mark's column out.
    /// `opened`: a row that opens its rows in place under it has them open, and its chevron turns down, as the "more"
    /// of the Tasks board's Ended.
    private func row<Mark: View>(_ text: String, muted: Bool = false, opens: Bool = false, opened: Bool = false,
                                 marked: Bool = true, @ViewBuilder mark: () -> Mark) -> some View {
        HStack(spacing: 0) {
            if marked { RowMark { mark() }.accessibilityHidden(true) }
            Text(text).font(FormMetrics.text).foregroundStyle(muted ? FleetStyle.muted : FleetStyle.text)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if opens { chevron.rotationEffect(.degrees(opened ? 90 : 0)) }
        }
        .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 11)
        .frame(minHeight: 44)
    }

    /// The chevron of a row that opens a page of its own, as on People and Conversations, or its rows in place, turned
    /// down while they are open.
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
                    if let list { machines = list; readFailed = false; readFailedSince = nil }
                    else { readFailed = true; readFailedSince = readFailedSince ?? .now }
                }
            }
            guard !Task.isCancelled else { return }
            // 3 s after a read that failed, as the lists do: the gray goes as soon as the hub is back.
            do { try await store.nap(readFailed ? 3 : machineRead ? 30 : 5) } catch { return }
        }
    }
}
