import FleetCore
import SwiftUI

/// Tasks: the tasks on a board of three columns (In progress, Waiting, Ended), for all agents or one, in a period of
/// days. Each column scrolls by itself and makes only the cards that show, so hundreds of tasks stay fast. A card opens
/// the task's page. The board changes with each hub reading; the two filters stay for the next start.
///
/// **The owner's yes of 11 November 2026 to its picture** ("I like the tasks one … yes, build it"), after "I like
/// simple things! not too much information! AI does a lot of things, so this need to be a very clean page that's easy
/// to read": a column is its heading and its cards on the page, with no box around them; a card is the task's title
/// and its agent; a task that waits for him says what for in orange, and stands first in Waiting; Ended shows only the
/// results that did not succeed, and one row opens the others. It had four columns in boxes: Needs you repeated the
/// Needs you page, and a week's hundred checked results stood one card each over the few that failed.
///
/// It was Activity, under the Dashboard; the owner's map of 28 October 2026 (D-4) names it Tasks, as the iPhone does.
///
/// **The same board is an agent's own Tasks part** (`scope`, `AgentTab.tasks`; the owner's yes of 6 November 2026 to its
/// mockup, in place of the Activity card of the chat's panel): that agent's tasks and the things that he asked it, so it
/// has the Period filter and no Agent filter, and no agent's name on its cards.
///
/// **For all agents, one card is one thing that he asked for** (`HubState.board`; his "Both places" of 15 November 2026
/// to its picture, after "I am not interested in the specific individual tasks to be done but in the thing I asked for
/// to be done"): the name of what he asked for, and under it the agent that he asked. The tasks of it are behind the
/// card, which opens the one that matters now: the task that waits for him, else the task in work, else the open one
/// that moved last, else the one that moved last (`Ask.lead`). A task that no message of his began is a card of its own, as before.
///
/// **The board of one agent shows the things that he asked that agent for in the same way** (his "Yes, build it" of 17
/// November 2026 to its picture: View all of the card Asked in an agent's chat panel opens Tasks with that agent
/// chosen): one card for each, whoever does their tasks, and the agent's other tasks a card each, its work on what he
/// asked another agent too. The Fleet Manager owns no task of its own, so its board showed nothing.
struct ActivityBoard: View {
    @Bindable var store: FleetStore
    /// The agent whose own Tasks part this board is, or nil for the board of the main sidebar.
    var scope: String? = nil
    /// The agent filter of the main sidebar's board: an agent's name, or empty for all agents.
    @AppStorage("activityAgent") private var chosen = ""
    @AppStorage("activityPeriod") private var periodName = ActivityPeriod.week.rawValue
    private var period: ActivityPeriod { ActivityPeriod(rawValue: periodName) ?? .week }
    /// Ended shows the tasks behind its "more" row.
    @State private var showsRest = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The rows of several tasks that show their tasks, by the row's newest task.
    @State private var openRows: Set<Int> = []
    /// The narrowest lane: a card keeps its agent's name on one line. A window too narrow for three shows as many whole
    /// lanes as fit, and the board scrolls sideways one lane at a time.
    private static let laneWidth: CGFloat = 150
    /// Between two lanes: more than between two cards, because no box parts the lanes.
    private static let spacing: CGFloat = 24
    /// The agent whose tasks show: the part's own, else the one of the filter; empty for all agents.
    private var agent: String { scope ?? chosen }
    /// Which list the lanes show: the hub, the period and the agent. When it changes, no card moves (`lane`).
    private var listed: String { "\(store.hub)/\(periodName)/\(agent)" }

    var body: some View {
        let state = store.state
        let board = items(state)
        FleetPage(scope == nil ? String(l10n: "Tasks") : AgentTab.tasks.heading, fills: true, wide: true) {
            filters(state?.activityAgents(saved: chosen) ?? [])
            if let state, !board.isEmpty { lanes(board, state: state) }
            else {
                empty(hasTasks: state?.tasks.contains { agent.isEmpty || $0.owner == agent } == true
                                || store.asks.contains { $0.agent == agent })
                Spacer(minLength: 0)
            }
        } actions: { EmptyView() }
    }

    /// The board's cards: one for each thing that he asked for and one for every other task, of all agents or of one
    /// (`HubState.board`).
    private func items(_ state: HubState?) -> [ActivityColumn: [BoardItem]] {
        guard let state else { return [:] }
        return state.board(period: period, agent: agent.isEmpty ? nil : agent)
    }

    /// The period and the agent: two dropdowns on one line. An agent's own board has the period alone.
    private func filters(_ agents: [String]) -> some View {
        HStack(spacing: 8) {
            FleetSelect("Period", selection: Binding(get: { period }, set: { periodName = $0.rawValue }),
                        options: ActivityPeriod.allCases.map { FleetOption($0, $0.title, mark: .symbol("calendar")) })
                .help("Show the tasks of one period").accessibilityIdentifier("activity-period")
            if scope == nil {
                FleetSelect("Agent", selection: $chosen, options: [FleetOption("", "All agents", mark: .symbol("person.2"))] + agents.map {
                    FleetOption($0, $0.agentLabel, mark: .agent($0, state: store.state, isFresh: store.isFresh))
                }).help("Show the tasks of one agent").accessibilityIdentifier("activity-agent")
            }
            Spacer(minLength: 0)
        }
    }

    private func lanes(_ board: [ActivityColumn: [BoardItem]], state: HubState) -> some View {
        let holds = (state.holds ?? []).filter { $0.state != "released" }
        let limited = Set(state.agents.filter { $0.limit != nil }.map(\.name))
        let waits = state.ownerWaits, subtasks = state.subtaskWaits
        let ended = EndedTasks(items: board[.done] ?? [])
        let count = CGFloat(ActivityColumn.allCases.count)
        return GeometryReader { proxy in
            // **Lanes shrink to the window, and a lane is never cut** (T-17): the lanes that show share the whole
            // width, and the scroll stops at a lane's edge.
            let shown = max(1, min(count, ((proxy.size.width + Self.spacing) / (Self.laneWidth + Self.spacing)).rounded(.down)))
            let width = (proxy.size.width - Self.spacing * (shown - 1)) / shown
            let row = HStack(alignment: .top, spacing: Self.spacing) {
                lane(.inProgress, count: board[.inProgress]?.count ?? 0, ids: (board[.inProgress] ?? []).map(\.id)) {
                    ForEach(board[.inProgress] ?? []) { item in
                        // **The glyph of a card in this lane moves while its agent works** (`works`; the owner's yes of 17
                        // November 2026), as that agent's glyph does in the sidebar: the lane looked as Waiting does.
                        // Only a card whose own task is in work: one that says that it stalled or lost its session
                        // rests, also while its agent works on another task.
                        Group {
                            switch item {
                            case .task(let task):
                                // A task in work says nothing more; one that stalled or lost its session says so.
                                let word = task.stateWord(holds: holds, limited: limited.contains(task.owner))
                                card(task, wait: nil, state: state, why: word == TaskWords.working ? nil : word, works: word == TaskWords.working)
                            case .ask(let ask):
                                // As a task in work: nothing more, unless its task in work stalled or lost its session.
                                let word = ask.working?.stateWord(holds: holds, limited: limited.contains(ask.working?.owner ?? ""))
                                askCard(ask, state: state, why: word == TaskWords.working ? nil : word, works: word == TaskWords.working)
                            }
                        }.transition(.laneCard)
                    }
                }.frame(width: width)
                lane(.waiting, count: board[.waiting]?.count ?? 0, ids: (board[.waiting] ?? []).map(\.id)) {
                    ForEach(board[.waiting] ?? []) { item in
                        Group {
                        switch item {
                        case .task(let task):
                            let reason = waits[task.id] == nil
                                ? why(task, holds: holds, limited: limited.contains(task.owner), subtasks: subtasks[task.id], now: state.time) : nil
                            // Its hover and VoiceOver say what the card says, never "Working" (`words`).
                            card(task, wait: waits[task.id], state: state, why: reason, words: subtasks[task.id] != nil ? reason : nil)
                        case .ask(let ask):
                            // Why it waits, when it does not wait for him: the earliest time until which a task of it
                            // is parked, else the word of its open task that moved last.
                            let lead = ask.open.filter { $0.parked_until != nil }.min { ($0.parked_until ?? 0) < ($1.parked_until ?? 0) } ?? ask.open.first
                            askCard(ask, state: state, why: ask.wait != nil ? nil : lead.map {
                                why($0, holds: holds, limited: limited.contains($0.owner), subtasks: subtasks[$0.id], now: state.time)
                            })
                        }
                        }.transition(.laneCard)
                    }
                }.frame(width: width)
                lane(.done, count: board[.done]?.count ?? 0, ids: ended.failedRows.map { "\($0.id)" }) {
                    endedRows(ended, state: state, narrow: width < EndedRow.narrow)
                }.frame(width: width)
            }.scrollTargetLayout().frame(height: proxy.size.height)
            if shown == count { row } else { ScrollView(.horizontal) { row }.scrollTargetBehavior(.viewAligned) }
        }
    }

    /// One lane: its heading with its count, and its cards on the page itself. **No box around a lane** (the owner's yes
    /// of 11 November 2026): cards stood in a box of their own colour, and an empty lane was a tall empty box.
    ///
    /// **A card that leaves a lane goes at once, and the cards under it close its room over 0.2 s; a card that comes
    /// fades in over the same time** (`ids`, the lane's cards in their order; `AnyTransition.laneCard`; the owner's yes
    /// of 17 November 2026): a task that started stood in its new lane in one frame, and the cards under its old place
    /// jumped. The fleet is read every three seconds, so this happens while he looks. Its count rolls (`rolls`).
    /// **Only a card that changes its lane moves**: with another period, another agent or another hub the lane is
    /// another list, and stands at once (`listed`), as the sidebar's rows of another hub do.
    private func lane<Cards: View>(_ column: ActivityColumn, count: Int, ids: [String] = [], @ViewBuilder cards: () -> Cards) -> some View {
        // **A lane's heading as every heading over a card** (margins row 23): 2 points in, in the 28-point heading row, 10
        // over its first card (`FormSection`).
        VStack(alignment: .leading, spacing: FleetSpace.inside) {
            HStack(spacing: 6) {
                Text(column.title).font(FormMetrics.heading).foregroundStyle(FleetStyle.text)
                Text("\(count)").font(FormMetrics.detail).monospacedDigit().foregroundStyle(FleetStyle.muted).rolls(count)
            }.frame(minHeight: FormMetrics.headingRow).padding(.leading, 2)
                .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) { cards() }.padding(.bottom, FleetSpace.bottom)
                    .transaction(value: listed) { $0.animation = nil }
                    .animation(reduceMotion ? nil : FleetMotion.lane, value: ids)
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("activity-column-\(column.rawValue)")
    }

    /// One open task's card. `wait`: what it waits for from the owner; `why`: why any other task waits; `words`: its
    /// state in words for its hover and VoiceOver where they are not its state word (a task that waits for subtasks).
    private func card(_ task: FleetTask, wait: OwnerWait?, state: HubState, why: String? = nil, words: String? = nil,
                      works: Bool = false) -> some View {
        var request: (() -> Void)?
        if case .request(let id, _) = wait {
            // The request itself, on Needs you, where he answers it.
            request = { store.selectedNeed = id; store.destination = .needs }
        }
        return ActivityCard(title: task.title, identifier: "activity-task-\(task.id)", requestIdentifier: "activity-request-\(task.id)",
                            owner: scope == nil ? task.owner : nil, ownerLine: wait?.words, why: why,
                            words: wait?.words ?? words ?? task.stateWord(in: state), works: works, openRequest: request) {
            store.destination = .task(task.id)
        }.opensTask(task.id, store: store)
    }

    /// **One thing that he asked for, on one card**, with the look of a task's card: its name, under it the agent that
    /// he asked, what it waits for from him in orange, or `why` it waits at the end of the agent's line. The card opens
    /// the task of it that matters now (`Ask.lead`); the other tasks of it are in that task's thread and in Ended.
    @ViewBuilder private func askCard(_ ask: Ask, state: HubState, why: String?, works: Bool = false) -> some View {
        if let lead = ask.lead {
            ActivityCard(title: ask.title, identifier: "activity-ask-\(ask.id)", requestIdentifier: "activity-ask-request-\(ask.id)",
                         owner: scope == nil ? ask.agent : nil, ownerLine: ask.wait?.words, why: why,
                         words: ask.wait?.words ?? why ?? lead.stateWord(in: state), works: works, openRequest: request(ask)) {
                store.destination = .task(lead.id)
            }.opensTask(lead.id, store: store)
        }
    }

    /// Opens the request that a thing he asked for waits on, on Needs you, where he answers it; nil when it waits for none.
    private func request(_ ask: Ask) -> (() -> Void)? {
        guard case .request(let id, _) = ask.wait else { return nil }
        return { store.selectedNeed = id; store.destination = .needs }
    }

    /// Why a task waits, at the end of its agent's line: until when its agent parked it, else its one state word
    /// ("Waiting for Fleet Manager", "Usage limit", "Paused", "Queued"). **A task that waits for its subtasks names their
    /// agents** ("Waiting for Web-Dev", 14 November 2026) where its state word would say "Working": a hold, a usage
    /// limit and a stall keep their own word.
    private func why(_ task: FleetTask, holds: [TaskHold], limited: Bool, subtasks: [String]?, now: Double) -> String {
        if let until = task.parked_until, !holds.contains(where: { $0.task == task.id }), !limited {
            return String(l10n: "Until \(fleetComingTime(until, now: now))")
        }
        let word = task.stateWord(holds: holds, limited: limited)
        if let subtasks, word == TaskWords.working { return HubState.subtaskWords(subtasks) }
        return word
    }

    /// **Ended: the results that did not succeed, and one row that opens the others** by day, the runs of one schedule
    /// as one row.
    @ViewBuilder private func endedRows(_ ended: EndedTasks, state: HubState, narrow: Bool) -> some View {
        // A task, or one thing that he asked for under its own name, with the task of it that did not succeed.
        ForEach(ended.failedRows) { row in
            EndedRow(title: row.title, owner: scope == nil ? row.owner : nil, badge: row.task.failedResult, stacked: narrow) {
                store.destination = .task(row.task.id)
            }.opensTask(row.task.id, store: store).accessibilityIdentifier("activity-task-\(row.task.id)")
                // A result that did not succeed comes into Ended as a card comes into its lane (`laneCard`).
                .transition(.laneCard)
        }
        if ended.rest > 0 {
            Button { showsRest.toggle() } label: {
                HStack(spacing: 6) {
                    Text(ended.failed.isEmpty ? "Show all" : "\(ended.rest) more")
                    Image(systemName: "chevron.right").font(IconMetrics.symbol(9, weight: .semibold))
                        .rotationEffect(.degrees(showsRest ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .font(FormMetrics.text).foregroundStyle(FleetStyle.muted)
                .padding(.horizontal, EndedRow.inset).frame(minHeight: EndedRow.height).contentShape(Rectangle())
            }
            .buttonStyle(FleetRowButtonStyle())
            .accessibilityValue(showsRest ? String(localized: "Open (a state)", defaultValue: "Open", bundle: Localized.bundle,
                                                            locale: Localized.digits) : String(l10n: "Closed")).accessibilityIdentifier("activity-ended-more")
            if showsRest {
                ForEach(ended.days) { day in
                    Text(Self.dayWords(day.start, now: state.time)).font(FormMetrics.detailTitle).foregroundStyle(FleetStyle.muted)
                        .padding(.leading, EndedRow.inset).frame(minHeight: FormMetrics.headingRow, alignment: .bottomLeading)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(day.groups) { group in restRows(group, state: state) }
                }
            }
        }
    }

    /// One row of the tasks behind "more": one task, or several as one row with their number, which opens them.
    @ViewBuilder private func restRows(_ group: EndedTasks.Group, state: HubState) -> some View {
        let owner = scope == nil ? group.owner : nil
        if let task = group.tasks.first, group.tasks.count == 1 {
            // A task that waits for its check, or that somebody canceled, says so; a checked result says nothing.
            EndedRow(title: group.title, owner: owner, note: task.accepted == 1 ? nil : task.stateWord(in: state)) {
                store.destination = .task(task.id)
            }.opensTask(task.id, store: store).accessibilityIdentifier("activity-task-\(task.id)")
        } else {
            let open = openRows.contains(group.id)
            EndedRow(title: group.title, owner: owner, note: "×\(group.tasks.count)") {
                if open { openRows.remove(group.id) } else { openRows.insert(group.id) }
            }.accessibilityValue(open ? String(localized: "Open (a state)", defaultValue: "Open", bundle: Localized.bundle, locale: Localized.digits) : String(l10n: "Closed")).accessibilityIdentifier("activity-runs-\(group.id)")
            if open {
                ForEach(group.tasks) { task in
                    EndedRow(title: task.title, owner: nil, note: messageTime(task.activityTime), indent: true) {
                        store.destination = .task(task.id)
                    }.opensTask(task.id, store: store).accessibilityIdentifier("activity-task-\(task.id)")
                }
            }
        }
    }

    /// A day of Ended in words: Today, Yesterday, else the weekday and the date ("Mon 9 Nov").
    static func dayWords(_ start: Double, now: Double, calendar: Calendar = .current) -> String {
        let day = Date(timeIntervalSince1970: start), today = calendar.startOfDay(for: Date(timeIntervalSince1970: now))
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: day), to: today).day ?? 0
        if days == 0 { return String(l10n: "Today") }
        if days == 1 { return String(l10n: "Yesterday") }
        return day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    @ViewBuilder private func empty(hasTasks: Bool) -> some View {
        FormSection {
            if hasTasks {
                // No button in the empty board (D-2): the two filters over it are the way out.
                FormEmpty("No tasks", symbol: "line.3.horizontal.decrease.circle")
            } else {
                FormEmpty("No tasks yet", symbol: "tray")
            }
        }
    }
}

/// One open task on the board: its title, and under it its agent. **A task that waits for the owner says what for in
/// orange** (the request's title, or the words of an outcome or a stop), and a click on a request's line opens that
/// request on Needs you; any other waiting task says why at the end of its agent's line, muted ("Until 10:00"). On an
/// agent's own board every card is that agent's, so no card names it (`owner` nil). **The same card stands in the lane
/// of Needs you** for a task that only the owner can move (`NeedsBoard`).
struct ActivityCard: View {
    /// The task's title, or the name of the thing that he asked for.
    let title: String
    /// The card's name for a check of the app, and the name of its request's line.
    let identifier: String
    let requestIdentifier: String
    /// The card names its agent under its title: on every board but an agent's own.
    let owner: String?
    /// What it waits for from the owner, or nil.
    let ownerLine: String?
    /// Why a task that waits for somebody else waits, or nil.
    let why: String?
    /// Its state in words, for its hover and for VoiceOver.
    let words: String
    /// The card stands in In progress: its agent's glyph moves while that agent works, as it does in the sidebar
    /// (`AgentGlyph.moves`). It is no new mark: the glyph was there, and stood still.
    var works = false
    /// Opens the request it waits on, where `ownerLine` is a request's title.
    let openRequest: (() -> Void)?
    let open: () -> Void
    @State private var hovered = false
    /// The pointer is down on the card: it ends with the press, however that ends.
    @GestureState private var pressed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(FormMetrics.title).foregroundStyle(FleetStyle.text).lineLimit(2).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let ownerLine {
                // Orange is what needs him (D-8), and here it is words, because the words are the news.
                if let openRequest {
                    Button(action: openRequest) {
                        Text(ownerLine).lineLimit(1).padding(.vertical, IconMetrics.reach).contentShape(Rectangle())
                    }.buttonStyle(.plain).padding(.vertical, -IconMetrics.reach).foregroundStyle(.orange)
                        .help("Open this request on Needs you").accessibilityIdentifier(requestIdentifier)
                } else {
                    Text(ownerLine).lineLimit(1).foregroundStyle(.orange)
                }
            }
            if owner != nil || why != nil {
                HStack(spacing: 6) {
                    if let owner {
                        // The glyph with its dot, as everywhere it stands for the agent (D-8 item 2).
                        AgentGlyph(name: owner, size: GlyphSize.inline, moves: works,
                                   ground: hovered ? FleetStyle.lifted : FleetStyle.surface)
                        Text(owner.agentLabel).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if let why { Text(why).lineLimit(1).layoutPriority(1) }
                }
            }
        }
        .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
        .modifier(BoardCardLook(hovered: hovered))
        .pressScale(pressed)
        // The whole card opens the task; the request's line in it is a button of its own, which takes its own click.
        .onTapGesture(perform: open)
        // The press, for the card's smaller size while the pointer is down (`pressScale`): beside the tap, never in
        // its place.
        .simultaneousGesture(DragGesture(minimumDistance: 0).updating($pressed) { _, down, _ in down = true })
        .onHover { hovered = $0 }
        // **The keyboard reaches a card as it reaches a button** (review of 11 November 2026): it is no `Button`, because
        // a button inside a button takes no click of its own, so it takes the focus of keyboard navigation itself, and
        // Return or Space opens the task.
        .focusable(interactions: .activate)
        .contentShape(.focusEffect, RoundedRectangle(cornerRadius: FormMetrics.radius))
        .onKeyPress(keys: [.return, .space], phases: .down) { _ in open(); return .handled }
        .help("\(title)\n\(words)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, owner?.agentLabel, words].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, open)
        .accessibilityActions { if let openRequest { Button("Open the request", action: openRequest) } }
        .accessibilityIdentifier(identifier)
    }
}

/// **The look of a card of a board's lane**, on Tasks and on Needs you: the surface of a form card with its edge, 14 and
/// 12 points of room, and under the pointer a brighter edge and a fill one step over the surface. `selected`: the card
/// of the request at hand on Needs you, on the fill of a selected row (`FleetStyle.bubble`) with a stronger edge.
///
/// **The pointer's fill comes at once and goes over 0.15 s** (the owner's yes of 17 November 2026): the edge alone went
/// from 8% to 16% white, which a large screen hardly shows.
struct BoardCardLook: ViewModifier {
    var selected = false
    let hovered: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? FleetStyle.bubble : hovered ? FleetStyle.lifted : FleetStyle.surface,
                        in: RoundedRectangle(cornerRadius: FormMetrics.radius))
            // The form cards' edge, which Increase Contrast raises to 4:1 (fix round 3c, HIG; T-41).
            .overlay(RoundedRectangle(cornerRadius: FormMetrics.radius)
                .strokeBorder(FleetStyle.hairline(selected ? 0.26 : hovered ? 0.16 : 0.08), lineWidth: FleetStyle.edgeWidth(contrast)))
            .contentShape(RoundedRectangle(cornerRadius: FormMetrics.radius))
            .animation(hovered || reduceMotion ? nil : FleetMotion.pointerOut, value: hovered)
    }
}

/// One row of Ended: the agent's glyph, the task's title on one line, and at its end the red word of a result that did
/// not succeed (`badge`) or a quiet note (`note`: how many runs, a time, "Canceled"). No card: what ended is a list
/// he reads, and the cards are the work that is open. **The requests that ended are the same rows** in the lane of
/// Needs you (`NeedsBoard`), where the one he opened keeps a soft fill (`selected`).
struct EndedRow: View {
    let title: String
    /// The agent whose glyph stands before the title: on every board but an agent's own, and not on a run of a row.
    let owner: String?
    var badge: String? = nil
    var note: String? = nil
    /// The row whose request shows beside the lane.
    var selected = false
    /// A run under its row: its words begin where the row's title does.
    var indent = false
    /// In a narrow lane the red word stands under the title, which keeps the row's width: beside it, in the narrowest
    /// window, a title was cut to one letter ("D… Not accepted").
    var stacked = false
    let open: () -> Void

    static let height: CGFloat = 36, inset: CGFloat = 10
    /// A lane under this width stacks a row's red word under its title.
    static let narrow: CGFloat = 300
    /// The red of a result that failed, light enough to read on its capsule (fix round 3, item 57: 4.64:1). The card
    /// Asked of a chat's panel writes the word of a failed result in it too.
    static let failedWords = Color(red: 1, green: 0x6B / 255, blue: 0x6B / 255)

    /// The red word of a result that did not succeed, on its capsule.
    private func word(_ badge: String) -> some View {
        Text(badge).font(FormMetrics.detailTitle).foregroundStyle(Self.failedWords).lineLimit(1).fixedSize()
            .padding(.horizontal, 7).padding(.vertical, 2).background(Color.red.opacity(0.16), in: Capsule())
    }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let owner {
                    AgentGlyph(name: owner, size: GlyphSize.inline, dot: false)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(FormMetrics.text).foregroundStyle(indent ? FleetStyle.muted : FleetStyle.text).lineLimit(1)
                    if stacked, let badge { word(badge) }
                }.padding(.leading, indent ? GlyphSize.inline + 8 : 0)
                Spacer(minLength: 4)
                if !stacked, let badge { word(badge) }
                if let note { Text(note).font(FormMetrics.detail).monospacedDigit().foregroundStyle(FleetStyle.muted).lineLimit(1).fixedSize() }
            }
            .padding(.horizontal, Self.inset).padding(.vertical, stacked && badge != nil ? 7 : 0)
            .frame(minHeight: Self.height).contentShape(Rectangle())
        }
        .buttonStyle(FleetRowButtonStyle())
        // The fill of a pressed row, in the row's own shape (`FleetRowButtonStyle`), while its request shows.
        .background {
            if selected {
                RoundedRectangle(cornerRadius: FormMetrics.inner).fill(Color.white.opacity(0.06))
                    .padding(.horizontal, 6).padding(.vertical, 3)
            }
        }
        .help(title)
        .accessibilityLabel([title, owner?.agentLabel, badge, note].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
