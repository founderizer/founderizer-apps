import FleetCore
import SwiftUI

/// One opening of the search card: a new one each time, so the card starts empty.
struct SearchRequest: Identifiable { let id = UUID() }

/// **Search, in a card over the dimmed window** (the owner's yes of 28 October 2026 to D-4: "a magnifier (and ⌘K)
/// opening a 460 × 370 card over the dimmed window — a field, then matching agents (glyph, name, last line) and tasks
/// (mark, title, T-n), Return opens the first"). With nine agents and hundreds of tasks nothing found a thing by its
/// name. The card is the app's one modal (`fleetModal`): a click outside it and Esc close it.
///
/// The field has the keyboard as the card opens. Return opens the highlighted row, which is the first one until the
/// arrow keys move it; a click opens any row. An agent opens its chat, a task its thread.
struct SearchPalette: View {
    @Bindable var store: FleetStore
    let close: () -> Void
    @State private var query = ""
    /// The row Return opens, counted over the agents and then the tasks.
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    /// The card's size, the mockup's.
    static let size = CGSize(width: 460, height: 370)

    private enum Found: Identifiable {
        case agent(FleetAgent)
        case task(FleetTask)
        var id: String {
            switch self {
            case .agent(let agent): "agent \(agent.name)"
            case .task(let task): "task \(task.id)"
            }
        }
    }

    var body: some View {
        let agents = matchingAgents
        let tasks = matchingTasks
        let found = agents.map(Found.agent) + tasks.map(Found.task)
        VStack(spacing: 0) {
            // **One mark column and one words column down the card** (margins row 13): the magnifier where the rows'
            // marks and "Agents" stand, 22 points in, and the words 34 after it (`RowMark`), where the names and the
            // tasks' titles begin. They stood at 19.5 and 46, the rows' marks at 24.5 and their words at 55 and 56.5.
            HStack(spacing: 0) {
                RowMark {
                    Image(systemName: "magnifyingglass").font(IconMetrics.symbol(15)).foregroundStyle(FleetStyle.muted)
                }.accessibilityHidden(true)
                // Its placeholder in the muted words that read (it was 2.29:1; `fieldPlaceholder`), and Esc closes the
                // card from the field that has the keyboard, as a click outside it does (D-4).
                TextField(text: $query, prompt: Text(verbatim: "")) { Text("Search") }
                    .fieldPlaceholder("Search", shows: query.isEmpty)
                    .textFieldStyle(.plain).font(ChatStyle.font).foregroundStyle(FleetStyle.text)
                    .focused($focused)
                    .onExitCommand { close() }
                    .onSubmit { if found.indices.contains(highlighted) { open(found[highlighted]) } }
                    .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(found.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
                    .accessibilityIdentifier("search-field")
            }
            .padding(.horizontal, 22).frame(height: 44)
            Rule().padding(.top, 4).padding(.bottom, 8)
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !agents.isEmpty {
                            label("Agents").padding(.top, 4).padding(.bottom, 6)
                            ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                                agentRow(agent, highlighted: highlighted == index).id(index)
                            }
                        }
                        if !tasks.isEmpty {
                            label("Tasks").padding(.top, agents.isEmpty ? 4 : 12).padding(.bottom, 4)
                            ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                                taskRow(task, highlighted: highlighted == agents.count + index).id(agents.count + index)
                            }
                        }
                    }.padding(.bottom, 8)
                }
                .scrollIndicators(.hidden)
                .onChange(of: highlighted) { _, row in scroll.scrollTo(row) }
            }
        }
        .padding(.top, 8)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
        .font(FleetStyle.body).foregroundStyle(FleetStyle.text)
        .onChange(of: query) { _, _ in highlighted = 0 }
        .task { focused = true }
        .accessibilityIdentifier("search-card")
    }

    // MARK: what matches

    /// The words the owner typed, without the room around them.
    private var words: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The agents whose name holds the words, in the sidebar's order: the ones he pinned first, then the hub's.
    private var matchingAgents: [FleetAgent] {
        let listed = store.state?.agents ?? []
        let ordered = ChatList.order(listed.map(\.name), pinned: store.pinned).compactMap { name in listed.first { $0.name == name } }
        guard !words.isEmpty else { return ordered }
        return ordered.filter { AgentNames.shared.matches($0.name, words) }      // its role or its name
    }

    /// The tasks whose title or number holds the words, the one that moved last first. With nothing typed, the newest
    /// ones: the card is as quick to open a recent task as an agent.
    private var matchingTasks: [FleetTask] {
        let tasks = (store.state?.tasks ?? []).sorted { ($0.activityTime, $0.id) > ($1.activityTime, $1.id) }
        guard !words.isEmpty else { return Array(tasks.prefix(20)) }
        let number = words.uppercased().hasPrefix("T-") ? String(words.dropFirst(2)) : words
        return Array(tasks.filter { $0.title.localizedStandardContains(words) || String($0.id) == number }.prefix(50))
    }

    // MARK: rows

    private func label(_ words: String) -> some View {
        Text(words).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).padding(.horizontal, 22)
            .accessibilityAddTraits(.isHeader)
    }

    /// An agent: its glyph, its name, and the newest thing it did, as its row in the sidebar says it.
    private func agentRow(_ agent: FleetAgent, highlighted: Bool) -> some View {
        let preview = ChatList.preview(agent.name, last: store.chatTimeline.entries(for: agent.name, limit: 1).last,
                                       tasks: store.state?.tasks ?? [])
        return SearchRow(highlighted: highlighted, height: 48) { open(.agent(agent)) } content: {
            // The `row` step, 22 pt, with its dot (D-8; fix round 2: a search avatar is 18–24, and this was 28).
            RowMark { AgentGlyph(name: agent.name, size: GlyphSize.row, ground: highlighted ? FleetStyle.bubble : FleetStyle.canvas) }
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name.agentLabel).font(FormMetrics.title).lineLimit(1)
                if let preview {
                    Text(preview).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityLabel([agent.name.agentLabel, preview].compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("search-agent-\(agent.name)")
    }

    /// A task: its state as a mark and its title. Its number still finds it (T-61, or 61), and the row does not show it
    /// (3 November 2026: "I dont want these codes"). A task in work has its mark in the green of work, as on
    /// the Tasks board (D-8: a state is never violet), still here, where the card is for finding and not for watching.
    /// **An ended task wears the board's result look** (fix round 3, item 21): its mark's colour is the one tint of every
    /// screen (`FleetTask.tint`), the green of a checked result and the red of the board's badges, where ⌘K drew a muted
    /// outline check and an orange "!".
    private func taskRow(_ task: FleetTask, highlighted: Bool) -> some View {
        // **One order for every task's mark** (`FleetTask.mark`, review B5): a limited task was green work here while
        // its thread said "Usage limit", and a result not accepted a muted circle where the board has a red badge.
        let mark = task.mark(in: store.state)
        return SearchRow(highlighted: highlighted, height: 40) { open(.task(task)) } content: {
            RowMark { Image(systemName: mark.symbol).font(IconMetrics.symbol(14)).foregroundStyle(task.tint(in: store.state).color) }
            Text(task.title).font(FormMetrics.text).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 12)
        }
        .help(task.title)
        .accessibilityLabel(task.title)
        .accessibilityIdentifier("search-task-\(task.id)")
    }

    private func open(_ found: Found) {
        switch found {
        case .agent(let agent): store.destination = .agent(agent.name)
        case .task(let task): store.destination = .task(task.id)
        }
        close()
    }
}

/// One row of the search card: the whole row is the button, with the sidebar's soft fill under the pointer and its
/// stronger one on the row that Return opens.
private struct SearchRow<Content: View>: View {
    let highlighted: Bool
    let height: CGFloat
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            // No spacing of its own: a row's mark stands in `RowMark`, which keeps its words 34 points after it.
            HStack(spacing: 0) { content }
                .padding(.horizontal, 14).frame(height: height)
                .background(RoundedRectangle(cornerRadius: FormMetrics.inner)
                    .fill(highlighted ? FleetStyle.bubble : hovered ? Color.white.opacity(0.04) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
        .padding(.horizontal, 8)
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }
}
