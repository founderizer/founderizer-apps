import FleetCore
import SwiftUI

private typealias TaskMark = (symbol: String, words: String, attention: Bool, inWork: Bool)

/// Tasks: the tasks on a board of four columns (Needs you, In progress, Waiting, Done), for all agents or one, in a
/// period of days. Needs you also has the manager's open requests. Each column scrolls by itself and makes only the cards that show, so hundreds of tasks stay fast.
/// A card opens the task's page. The board changes with each hub reading; the two filters stay for the next start.
///
/// It was Activity, under the Dashboard; the owner's map of 28 October 2026 (D-4) names it Tasks, as the iPhone does,
/// and gives it the Goals button the Dashboard had, the one way into Goals from the sidebar's pages.
///
/// **The same board is an agent's own Tasks part** (`scope`, `AgentTab.tasks`; the owner's yes of 6 November 2026 to its
/// mockup, in place of the Activity card of the chat's panel): that agent's tasks only, so it has the Period filter and
/// no Agent filter, no Goals button, and no agent's name on its cards.
struct ActivityBoard: View {
    @Bindable var store: FleetStore
    /// The agent whose own Tasks part this board is, or nil for the board of the main sidebar.
    var scope: String? = nil
    /// The agent filter of the main sidebar's board: an agent's name, or empty for all agents.
    @AppStorage("activityAgent") private var chosen = ""
    @AppStorage("activityPeriod") private var periodName = ActivityPeriod.week.rawValue
    private var period: ActivityPeriod { ActivityPeriod(rawValue: periodName) ?? .week }
    /// A request that the owner opened from the Needs you column: its detail and its answer, over the board.
    @State private var openNeed: OwnerNeed?
    /// The narrowest lane: a card keeps its agent's name and number, and a request its "From Manager", on one line.
    /// A window too narrow for four shows as many whole lanes as fit, and the board scrolls sideways one lane at a time.
    private static let laneWidth: CGFloat = 150
    private static let spacing: CGFloat = 12
    /// The agent whose tasks show: the part's own, else the one of the filter; empty for all agents.
    private var agent: String { scope ?? chosen }

    var body: some View {
        let state = store.state
        let board = state?.activity(agent: agent.isEmpty ? nil : agent, period: period) ?? [:]
        let needs = state?.activityNeeds(agent: agent.isEmpty ? nil : agent) ?? []
        FleetPage(scope == nil ? "Tasks" : AgentTab.tasks.heading, fills: true, wide: true) {
            filters(state?.activityAgents(saved: chosen) ?? [])
            if let state, !board.isEmpty || !needs.isEmpty { lanes(board, needs: needs, state: state) }
            else {
                empty(hasTasks: state?.tasks.contains { agent.isEmpty || $0.owner == agent } == true)
                Spacer(minLength: 0)
            }
        } actions: {
            if scope == nil, state?.ui_features?.contains("goals") == true {
                Button("Goals") { store.destination = .goals }.buttonStyle(FleetOutlineButtonStyle())
                    .accessibilityIdentifier("tasks-goals")
            }
        }
        .fleetModal(item: $openNeed) { need in
            NeedSheet(store: store, need: need) { openNeed = nil }
        }
        // `-openNeed <id>` opens one request's card, so that screen can be looked at without clicking to it (the
        // Dashboard's, which went).
        .task(id: store.state?.db) {
            guard scope == nil, let asked = UserDefaults.standard.string(forKey: "openNeed"), let id = Int(asked) else { return }
            openNeed = store.state?.needs.first { $0.id == id } ?? store.state?.needs.first
        }
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

    private func lanes(_ board: [ActivityColumn: [FleetTask]], needs: [OwnerNeed], state: HubState) -> some View {
        let holds = (state.holds ?? []).filter { $0.state != "released" }
        let unknown = Set((state.outcomes ?? []).filter { $0.state == "unknown" }.map(\.task))
        let limits = Dictionary(state.agents.compactMap { agent in agent.limit.map { (agent.name, $0) } }) { first, _ in first }
        let goals = Dictionary((state.goals ?? []).map { ($0.id, $0.title) }) { first, _ in first }
        let count = CGFloat(ActivityColumn.allCases.count)
        return GeometryReader { proxy in
            // **Lanes shrink to the window, and a lane is never cut** (T-17): the lanes that show share the whole
            // width, and the scroll stops at a lane's edge. At 960 the third lane stood half under the window's edge.
            let shown = max(1, min(count, ((proxy.size.width + Self.spacing) / (Self.laneWidth + Self.spacing)).rounded(.down)))
            let width = (proxy.size.width - Self.spacing * (shown - 1)) / shown
            let row = HStack(alignment: .top, spacing: Self.spacing) {
                ForEach(ActivityColumn.allCases) { column in
                    lane(column, board[column] ?? [], needs: column == .needsYou ? needs : [], now: state.time) { task in
                        // In Needs you, an outcome that is not known says so; the task can have ended.
                        let mark = column == .done ? nil : column == .needsYou && unknown.contains(task.id)
                            ? ("questionmark.circle", "Outcome not known: check it", true, false) : mark(task, holds: holds, limits: limits)
                        return ActivityCard(task: task, mark: mark, word: task.stateWord(holds: holds, limited: limits[task.owner] != nil),
                                            held: holds.contains { $0.task == task.id }, namesOwner: scope == nil,
                                            goal: goal(task, titles: goals), age: activityAge(task.activityTime, now: state.time)) {
                            store.destination = .task(task.id)
                        }.opensTask(task.id, store: store)
                    }.frame(width: width)
                }
            }.scrollTargetLayout().frame(height: proxy.size.height)
            if shown == count { row } else { ScrollView(.horizontal) { row }.scrollTargetBehavior(.viewAligned) }
        }
    }

    private func lane<Card: View>(_ column: ActivityColumn, _ tasks: [FleetTask], needs: [OwnerNeed], now: Double,
                                  card: @escaping (FleetTask) -> Card) -> some View {
        // **A lane's heading as every heading over a card** (margins row 23): 2 points in, in the 28-point heading row, 10
        // over its lane (`FormSection`). It stood 4 in, with its baseline 11 over the lane where a section's stands 19.
        VStack(alignment: .leading, spacing: FleetSpace.inside) {
            HStack(spacing: 6) {
                Text(column.title).font(FormMetrics.heading).foregroundStyle(FleetStyle.text)
                Text("\(tasks.count + needs.count)").font(FormMetrics.detail).monospacedDigit().foregroundStyle(FleetStyle.muted)
            }.frame(minHeight: FormMetrics.headingRow).padding(.leading, 2)
                .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
            ScrollView {
                LazyVStack(spacing: 8) {
                    // The manager's open requests come first: the owner answers them on the Needs you page.
                    ForEach(needs) { need in
                        NeedCard(need: need, age: activityAge(need.raised, now: now)) { openNeed = need }
                    }
                    ForEach(tasks) { card($0) }
                    if tasks.isEmpty && needs.isEmpty {
                        Text(column == .needsYou ? "Nothing needs you" : "No tasks").font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                            .padding(.vertical, 18)
                    }
                }.padding(8)
            }
            .background(FleetStyle.rail, in: RoundedRectangle(cornerRadius: FormMetrics.radius))
            .overlay(RoundedRectangle(cornerRadius: FormMetrics.radius).strokeBorder(FleetStyle.line, lineWidth: 0.5))
        }.accessibilityElement(children: .contain).accessibilityIdentifier("activity-column-\(column.rawValue)")
    }

    /// The state mark of an open task: FleetCore's one order of a task's mark and word (`FleetTask.mark`, review B5), with
    /// its agent's usage limit, which is the board's hourglass and "Usage limit", never the green of work.
    private func mark(_ task: FleetTask, holds: [TaskHold], limits: [String: RuntimeLimit]) -> TaskMark {
        task.mark(holds: holds, limited: limits[task.owner] != nil)
    }

    /// The goal of a task: the title of its hub goal, or the goal text that its requester gave.
    private func goal(_ task: FleetTask, titles: [Int: String]) -> (label: String, help: String)? {
        if let id = task.goal_id { return (titles[id] ?? "Goal", "Goal" + (titles[id].map { " · \($0)" } ?? "")) }
        let text = task.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : (text, "Goal · \(text)")
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

/// One open request of the manager in Needs you: its title, who raised it, its number and its age. A click opens it
/// over the board, with its detail and its answer; the window also leads to the Needs you page.
private struct NeedCard: View {
    let need: OwnerNeed
    let age: String
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // The mark in the glyph's width, so the title begins where "From Manager" does (margins row 22).
                    Image(systemName: "questionmark.circle").font(IconMetrics.symbol(11.5)).foregroundStyle(.orange)
                        .frame(width: GlyphSize.inline, alignment: .leading)
                    Text(need.title).font(FormMetrics.title).foregroundStyle(FleetStyle.text).lineLimit(3).multilineTextAlignment(.leading)
                }
                // No request number beside who asked (D-2): the title names the request.
                HStack(spacing: 6) {
                    AgentGlyph(name: need.by, size: GlyphSize.inline, ground: FleetStyle.surface)
                    Text("From \(need.by.agentLabel)").lineLimit(1)
                    Spacer(minLength: 4)
                }
                Text(age).lineLimit(1)
            }
            .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
            .padding(11).frame(maxWidth: .infinity, alignment: .leading)
            .background(FleetStyle.surface, in: RoundedRectangle(cornerRadius: FormMetrics.radius))
            .overlay(RoundedRectangle(cornerRadius: FormMetrics.radius).strokeBorder(Color.orange.opacity(hovered ? 0.5 : 0.3), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
        .help("\(need.title)\nOpen it here and answer it")
        .accessibilityLabel("\(need.title), from \(need.by.agentLabel), needs your answer, \(age)")
        .accessibilityIdentifier("activity-need-\(need.id)")
    }
}

/// One task on the board: its title, its agent, the time of its last activity and its goal. An open task has its state
/// mark before the title. A result that is not a success has a red badge; an accepted result has a check mark. On an
/// agent's own board every card is that agent's, so no card names it (`namesOwner`).
private struct ActivityCard: View {
    let task: FleetTask
    /// nil for a task that ended.
    let mark: TaskMark?
    /// **The task's one state word** (`TaskWords`, hold first; review B4/B8, fix round 2): its hover and VoiceOver said
    /// "Accepted by Manager" where its thread says "Checked", and "Canceled" for a stop the helper had not confirmed,
    /// which its thread calls "Stopping…".
    let word: String
    /// The owner's hold on it is not released yet.
    let held: Bool
    /// The card names its agent under its title: on every board but an agent's own.
    let namesOwner: Bool
    let goal: (label: String, help: String)?
    let age: String
    let open: () -> Void
    @State private var hovered = false
    @Environment(\.colorSchemeContrast) private var contrast

    private var words: String { mark?.words ?? word }
    /// The red of a result that failed, light enough to read on the board's card.
    private static let failedWords = Color(red: 1, green: 0x6B / 255, blue: 0x6B / 255)

    @ViewBuilder private var result: some View {
        if mark == nil && held {
            // An ended task whose stop is not confirmed yet: its word, and no result before the stop is.
            Text(word).lineLimit(1).fixedSize()
        } else if let failed = task.failedResult {
            // **#FF6B6B, which reads at 4.64:1 on its capsule** (fix round 3, item 57): the system red read at 3.75:1.
            Text(failed).font(FormMetrics.detailTitle).foregroundStyle(Self.failedWords).lineLimit(1).fixedSize()
                .padding(.horizontal, 7).padding(.vertical, 2).background(Color.red.opacity(0.16), in: Capsule())
        } else if task.accepted == 1 {
            Image(systemName: "checkmark.circle.fill").font(IconMetrics.symbol(13)).foregroundStyle(.green)
        }
    }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // Work in the green of work, a task that needs him orange, and every other mark muted: a state is
                    // never violet (the owner's yes of 28 October 2026, D-8).
                    // **The mark in the width of the agent's glyph under it** (margins row 22): the title begins where
                    // the agent's name does, whatever the mark. It stood 2.5 points left of the name, 6 after the hourglass.
                    if let mark {
                        Group {
                            if mark.inWork { WorkMark(size: 11.5) }
                            else { Image(systemName: mark.symbol).font(IconMetrics.symbol(11.5)).foregroundStyle(mark.attention ? Color.orange : FleetStyle.muted) }
                        }.frame(width: GlyphSize.inline, alignment: .leading)
                    }
                    Text(task.title).font(FormMetrics.title).foregroundStyle(FleetStyle.text).lineLimit(3).multilineTextAlignment(.leading)
                }
                if namesOwner {
                    HStack(spacing: 6) {
                        // The glyph with its dot, as everywhere it stands for the agent (D-8 item 2).
                        AgentGlyph(name: task.owner, size: GlyphSize.inline, ground: FleetStyle.surface)
                        Text(task.owner.agentLabel).lineLimit(1)
                        Spacer(minLength: 4)
                    }
                }
                if let goal {
                    Text(goal.label).font(FormMetrics.detail).lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(FleetStyle.bubble, in: Capsule()).help(goal.help)
                }
                // The time and the result on one line; in a narrow column the result goes on a line of its own.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        Text(age).lineLimit(1)
                        Spacer(minLength: 4)
                        result
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        result
                        Text(age).lineLimit(1)
                    }
                }
            }
            .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
            .padding(11).frame(maxWidth: .infinity, alignment: .leading)
            .background(FleetStyle.surface, in: RoundedRectangle(cornerRadius: FormMetrics.radius))
            // The form cards' edge, which Increase Contrast raises to 4:1 (fix round 3c, HIG; T-41): it kept 1.2–1.4:1.
            .overlay(RoundedRectangle(cornerRadius: FormMetrics.radius)
                .strokeBorder(FleetStyle.hairline(hovered ? 0.16 : 0.08), lineWidth: FleetStyle.edgeWidth(contrast)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
        .help("\(task.title)\n\(words)")
        .accessibilityLabel([task.title, namesOwner ? task.owner.agentLabel : nil, words, age].compactMap { $0 }
            .joined(separator: ", ") + (goal.map { ", goal \($0.label)" } ?? ""))
        .accessibilityIdentifier("activity-task-\(task.id)")
    }
}
