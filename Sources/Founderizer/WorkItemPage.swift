import FleetCore
import SwiftUI

/// **The page of one thing of an agent's work** (the owner, 17 November 2026: "let me go to the detail page if
/// clicked. Also on the detail page I should see different levels: in this case, 'resolved ticket xxxx' and then
/// inside, the specific tasks performed", and his "Yes, as drawn" to its pictures). A row of the card Work of an
/// agent's chat panel opens it (`Destination.work`). Its title is the thing's name, a ticket's number or an
/// incident's title, with the back link to the chat that it came from. Under it, one card says how it ended and when,
/// with what its agent recorded (a ticket's symptom and the part of the system, in the words of the owner's lists, or
/// the agent's own note), or that it waits for him, works now or waits; then its tasks, in the order they began, each
/// subtask under the task that gave it, one step further in. A task opens its thread. A thing with no task (a case
/// that the Fleet Manager closed itself) has no card of tasks.
struct WorkItemPage: View {
    @Bindable var store: FleetStore
    let agent: String
    let key: WorkItem.Key

    var body: some View {
        let back = FleetBack(agent.agentLabel) { store.destination = .agent(agent) }
        if let state = store.state, let item = state.workItem(key) {
            FleetPage(item.title, back: back) {
                FormSection { statusRow(item, state: state) }
                let lines = item.lines
                if !lines.isEmpty {
                    // A task that waits for him says so as his panel and the agent's dot say it (`ownerWaits`).
                    let waits = state.ownerWaits(of: lines.map(\.task).filter { !$0.isTerminal })
                    FormSection(String(l10n: "Tasks")) {
                        ForEach(lines) { line in taskRow(line, wait: waits[line.task.id], state: state) }
                    }
                }
            }
        } else {
            // The hub lists this work no more (a case of the Fleet Manager's own closed 72 hours ago): the chat that the
            // page came from takes its place, as no step of the history, and Back and Forward pass over such a page
            // (`FleetStore.canOpen`).
            Color.clear.onAppear { store.standIn(.agent(agent)) }
        }
    }

    /// **How it ended, and when**, or where it stands while it goes on: its mark, its words, and under them what its
    /// agent recorded; the day and time at the right. While it goes on, the task that says where it stands speaks for
    /// it, in the mark and the words of its own row under it: one that waits for him, else one in work now, else the
    /// open one that moved last.
    private func statusRow(_ item: WorkItem, state: HubState) -> some View {
        let open = item.isOver ? [] : item.tasks.filter { !$0.isTerminal }
        let waits = state.ownerWaits(of: open)
        let lead = open.first { waits[$0.id] != nil } ?? open.first { $0.mark(in: state).inWork }
            ?? open.max { ($0.activityTime, $0.id) < ($1.activityTime, $1.id) }
        let wait = lead.flatMap { waits[$0.id] }
        let mark = lead?.mark(in: state)
        let words: String = if let result = item.result { result.words }
            else if case .request? = wait { String(l10n: "Waits for you") }
            else if let wait { wait.words }
            else { mark?.words ?? String(l10n: "Waiting") }
        let detail = Self.recorded(item) ?? (mark?.inWork == true ? lead?.doing : nil)
        return HStack(alignment: .top, spacing: 0) {
            RowMark {
                if let end = item.result?.end {
                    Self.endMark(end)
                } else if wait != nil {
                    Image(systemName: "hand.raised.fill").font(IconMetrics.symbol(Self.mark)).foregroundStyle(.orange)
                } else if let lead, let mark {
                    if mark.inWork && store.isFresh { WorkMark(size: Self.mark, moves: store.marksMove) }
                    else { Image(systemName: mark.symbol).font(IconMetrics.symbol(Self.mark)).foregroundStyle(lead.tint(in: state).color) }
                } else {
                    Image(systemName: "circle.dotted").font(IconMetrics.symbol(Self.mark)).foregroundStyle(FleetStyle.muted)
                }
            }.accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(words).font(FormMetrics.title).foregroundStyle(item.result?.end == .failed ? EndedRow.failedWords : FleetStyle.text)
                if let detail, !detail.isEmpty {
                    Text(detail).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            if let at = item.endedAt {
                Text(ChatStamp.words(at)).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).help(fleetDate(at))
            }
        }
        .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 10)
        .frame(minHeight: FormMetrics.twoLineRow)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("work-status")
    }

    /// One task of it: its mark, its title on one line, and under it its agent and its end, or its state while it is
    /// open (what it waits for from him, as his panel says it, when it waits for him); a subtask one step further in
    /// than the task that gave it. It opens the task's thread.
    private func taskRow(_ line: WorkItem.Line, wait: OwnerWait?, state: HubState) -> some View {
        let task = line.task, mark = task.mark(in: state)
        let standing: String = if case .request? = wait { String(l10n: "Waits for you") } else { wait?.words ?? mark.words }
        let when = task.isTerminal ? ChatStamp.words(task.delivered ?? task.checked_at ?? task.activityTime) : standing
        let detail = [task.owner.agentLabel, task.isTerminal ? task.failedResult : nil, when].compactMap { $0 }
            .joined(separator: " · ")
        return Button { store.destination = .task(task.id) } label: {
            HStack(spacing: 0) {
                RowMark {
                    if wait != nil { Image(systemName: "hand.raised.fill").font(IconMetrics.symbol(Self.mark)).foregroundStyle(.orange) }
                    else if mark.inWork && store.isFresh { WorkMark(size: Self.mark, moves: store.marksMove) }
                    else { Image(systemName: mark.symbol).font(IconMetrics.symbol(Self.mark)).foregroundStyle(task.tint(in: state).color) }
                }.accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title).font(FormMetrics.text).foregroundStyle(FleetStyle.text).lineLimit(1)
                    Text(detail).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).lineLimit(1)
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.right").font(IconMetrics.symbol(11, weight: .semibold)).foregroundStyle(FleetStyle.muted)
            }
            .padding(.leading, FormMetrics.rowInset + CGFloat(line.depth) * Self.step)
            .padding(.trailing, FormMetrics.rowInset).padding(.vertical, 10)
            .frame(minHeight: FormMetrics.twoLineRow).contentShape(Rectangle())
        }
        .buttonStyle(FleetRowButtonStyle())
        .help([task.title, detail].joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([task.title, detail].joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("work-task-\(task.id)")
    }

    /// **What its agent recorded when it closed its case**: a ticket's symptom and the part of the system, in the words
    /// of the owner's lists ("Listing data wrong · Listing sync"), else the agent's own note; nil for work of no case.
    static func recorded(_ item: WorkItem) -> String? {
        guard let c = item.dutyCase, !c.isOpen else { return nil }
        if let facts = c.facts { return ["symptom", "component"].compactMap { facts[$0] }.joined(separator: " · ") }
        return c.note
    }

    /// The mark of a thing that ended: the board's green check of a result that succeeded, its red of one that did not.
    @ViewBuilder static func endMark(_ end: WorkItem.End) -> some View {
        switch end {
        case .done: Image(systemName: "checkmark.circle.fill").font(IconMetrics.symbol(mark)).foregroundStyle(FleetTask.MarkTint.checked.color)
        case .failed: Image(systemName: "exclamationmark.circle.fill").font(IconMetrics.symbol(mark)).foregroundStyle(FleetTask.MarkTint.failed.color)
        case .quiet: Image(systemName: "circle").font(IconMetrics.symbol(mark)).foregroundStyle(FleetStyle.muted)
        }
    }

    /// The size of every mark of the page, a form row's (`FormRow`).
    private static let mark: CGFloat = 15
    /// How far a subtask stands in under the task that gave it: one mark's column and its gap.
    private static let step = FormMetrics.markColumn + FormMetrics.markGap
}
