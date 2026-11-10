import FleetCore
import SwiftUI

/// What the fleet is working towards, in the agents' own words. No goal is written on this page: the owner says
/// what he wants in the chat with the manager, and the manager writes it down with `update_goal` and keeps it
/// moving. So this is a reading — where each goal stands, its next step, its tasks and what was said about it. It
/// says nothing of what a goal is and how one is made (D-2, the owner's yes of 28 October 2026 to cut the lines that
/// explain): the page's name and its rows say it.

struct GoalsView<TaskRow: View>: View {
    @Bindable var store: FleetStore
    @ViewBuilder let taskRow: (FleetTask) -> TaskRow
    @State private var expanded = Set<Int>()

    private var goals: [FleetGoal] {
        (store.state?.goals ?? []).sorted { ($0.isOpen ? 0 : 1, -$0.id) < ($1.isOpen ? 0 : 1, -$1.id) }
    }
    private var other: [FleetTask] { (store.state?.tasks ?? []).filter { $0.goal_id == nil } }

    var body: some View {
        FleetPage("Goals") {
            LazyVStack(alignment: .leading, spacing: FleetSpace.block) {
                FormSection {
                    if goals.isEmpty { FormEmpty("No goals yet", symbol: "flag") }
                    ForEach(goals) { goal in
                        Button { toggle(goal.id) } label: { row(goal) }
                            .buttonStyle(.plain)
                            .help(goal.marker?.detail ?? goal.title)
                            .accessibilityLabel(goal.title)
                            .accessibilityValue(goal.marker?.detail ?? "In order.")
                            .accessibilityIdentifier("goal-\(goal.id)")
                        if expanded.contains(goal.id) { contents(goal) }
                    }
                }
                if !other.isEmpty {
                    FormSection("Other work") {
                        ForEach(other.sorted { $0.id > $1.id }) { task in
                            taskRow(task).padding(.horizontal, FormMetrics.rowInset)
                        }
                    }
                }
            }
        }
    }

    /// One goal: its name, where it stands, and whether something is not in order.
    ///
    /// The whole row is already one button that opens the goal, so a `StateMark` in it would be a button inside a
    /// button — the same shape a duty row has, and the same answer. The symbol says it, the orange sentence this
    /// row used to print is gone, and the marker reaches him on the pointer and through VoiceOver off the row
    /// itself. The state word stays: it is a value, which no mark can carry. Its number does not (D-2): the title names
    /// the goal.
    private func row(_ goal: FleetGoal) -> some View {
        FormRow(goal.title, symbol: goal.marker == nil ? "checkmark.seal" : "exclamationmark.triangle",
                detail: goal.state.capitalized) {
            Image(systemName: expanded.contains(goal.id) ? "chevron.down" : "chevron.right")
                .font(IconMetrics.symbol(12)).foregroundStyle(FleetStyle.muted)
        }
    }

    private func contents(_ goal: FleetGoal) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if !goal.text.isEmpty { MessageText(text: goal.text) }
            if let next = goal.next_step {
                HStack {
                    Text(next.text)
                    if let id = next.task {
                        // The click reaches over and under the words (`IconMetrics.reach`, T-21: it was 15 pt high),
                        // as the panel's Parent task link does, and the line does not move for it.
                        Button { store.destination = .task(id) } label: {
                            Text("Open task").padding(.vertical, IconMetrics.reach).contentShape(Rectangle())
                        }.buttonStyle(.plain).padding(.vertical, -IconMetrics.reach).foregroundStyle(FleetStyle.link)
                            .opensTask(id, store: store)
                    }
                }
            } else if let wake = goal.wake_at {
                Label("Next review \(fleetDate(wake))", systemImage: "clock")
                    .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
            }
            if goal.spent > 0 { Text(spending(goal)).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted) }
            HStack(spacing: 8) {
                if goal.isOpen {
                    action(goal.state == "paused" ? .resume : .pause, goal: goal)
                    FleetSelect("More goal actions", options: [
                        FleetOption(GoalAction.done, "Mark done", mark: .symbol("checkmark.circle")),
                        FleetOption(GoalAction.drop, "Drop goal", subtitle: "Stops its tasks and asks the manager to cancel them.", mark: .symbol("xmark.circle")),
                    ]) { run($0, goal: goal) } label: { Image(systemName: "ellipsis").frame(height: 15) }.help("More goal actions")
                } else { action(.reopen, goal: goal) }
                Spacer()
            }.buttonStyle(FleetOutlineButtonStyle()).font(FormMetrics.detail).disabled(!store.canWrite)
            let tasks = (store.state?.tasks ?? []).filter { $0.goal_id == goal.id }
            ForEach(["submitted", "working", "input-required", "auth-required", "completed", "failed", "canceled", "rejected"], id: \.self) { state in
                let group = tasks.filter { $0.state == state }
                if !group.isEmpty {
                    Text(state.replacingOccurrences(of: "-", with: " ").capitalized).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                    ForEach(group) { task in taskRow(task) }
                }
            }
            if let result = goal.result, !result.isEmpty { MessageText(text: result) }
            DisclosureGroup("History") { GoalHistory(store: store, goalID: goal.id, updated: goal.updated) }
                .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
        }.padding(.horizontal, FormMetrics.rowInset).padding(.bottom, 14)
    }

    /// Money is the owner's: a goal carries a budget only where he set one, and the manager asks for every spend
    /// beyond it. The line appears once something was recorded against the goal.
    private func spending(_ goal: FleetGoal) -> String {
        guard let money = goal.limits.money else { return "Recorded spending \(goal.spent.description)" }
        return "Recorded spending \(goal.spent.description) / \(money.amount.description) \(money.currency)"
    }

    private func toggle(_ id: Int) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
    private func action(_ action: GoalAction, goal: FleetGoal) -> some View {
        Button(action.rawValue.capitalized) { run(action, goal: goal) }.help(action == .pause ? "Pauses this goal and its open tasks." : "")
    }
    private func run(_ action: GoalAction, goal: FleetGoal) {
        Task { await store.command(.goalState(id: goal.id, revision: goal.revision, action: action)) }
    }
}

private struct GoalHistory: View {
    @Bindable var store: FleetStore
    let goalID: Int
    let updated: Double
    /// The goal's history as it was read last, kept by the store (`FleetStore.reading`): it shows at once when he opens
    /// it again, and the read that starts then changes only what changed.
    private var detail: GoalDetail? {
        get { store.reading("goals.detail.\(goalID)") } nonmutating set { store.keep(newValue, as: "goals.detail.\(goalID)") }
    }
    @State private var error: String?
    /// What stopped the read. While the hub does not answer nothing is read, so a history not read yet says it is
    /// unavailable then, and never "Reading the history…" for as long as the hub is down.
    private var failure: String? {
        error ?? (detail == nil && store.connectionError != nil ? Self.unavailable : nil)
    }
    private static let unavailable = "Goal history is unavailable."
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let detail {
                ForEach(detail.spends) { spend in
                    Text("\(spend.amount.description) \(spend.currency) · \(spend.what)")
                }
                ForEach(detail.history.reversed()) { event in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.detail).textSelection(.enabled)
                        Text("\(event.by) · \(fleetDate(event.ts))").font(FormMetrics.detail)
                    }
                }
                if detail.history.isEmpty && detail.spends.isEmpty { Text("No history yet") }
            } else if failure == nil { LoadingLine("Reading the history…") }
            // Not while the window's notice says the outage (`FleetStore.hubNoticeShows`; fix round 3, item 33: it is
            // said once); `failure` still keeps "Reading the history…" away while the hub is down.
            if let failure, !store.hubNoticeShows { Text(failure).foregroundStyle(.orange) }
        }.padding(.vertical, 10)
        .task(id: "\(store.hub)/\(store.state?.db ?? "")/\(updated)") {
            guard let db = store.state?.db, store.isFresh else { return }
            let hub = store.hub, start = ContinuousClock.now
            // The first reading waits until a loading line that showed has stood half a second (`FleetStore.settle`).
            let first = detail == nil
            do {
                let reading = try await HubClient().goal(hub: hub, database: db, id: goalID)
                if first { await store.settle(since: start) }
                guard !Task.isCancelled, store.hub == hub, store.state?.db == db else { return }
                detail = reading; error = nil
            } catch {
                if first { await store.settle(since: start) }
                self.error = HubError.said(error) ?? Self.unavailable
            }
        }
    }
}
