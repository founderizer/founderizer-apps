import FleetCore
import SwiftUI

/// **The job level of the detail card** (design "Task details as a card over the page", 21 November 2026): one job over
/// the window, 680 points wide and as high as its content, which scrolls when the window is lower (`fleetModal`). A card
/// of the Tasks board and a thing of an agent's work, a ticket or an incident with its tasks, from a row of the card
/// Work of that agent's chat panel, are the same few facts (`JobLevel`). It was the page of one thing (the owner, 17
/// November 2026: "let me go to the detail page if clicked. Also on the detail page I should see different levels: in
/// this case, 'resolved ticket xxxx' and then inside, the specific tasks performed", and his "Yes, as drawn" to its
/// pictures), and is a card since the owner's words of 20 and 21 November 2026 ("showing the cards here as modals once
/// clicked instead of moving pages"; "task details to open as a modal ... even for the tasks page!").
///
/// From the top: its name, with Done at the right; a job that waits on an open request of his has that request's own
/// card first (`NeedRequestCard`, as on Needs you, with its options and its answer box), and every other job one card
/// that says how it ended and when, with what its agent recorded (a ticket's symptom and the part of the system, in the
/// words of the owner's lists, or the agent's own note), or that it works now or waits; then its tasks, in the order
/// they began, each subtask under the task that gave it, one step further in. A task opens the task level in the same
/// card, over this job. A thing with no task (a case that the Fleet Manager closed itself) has no card of tasks. A
/// write that the hub did not confirm stands at the card's foot with its Retry and Discard (`PendingBar`).
struct JobDetail: View {
    @Bindable var store: FleetStore
    let level: JobLevel
    let state: HubState

    /// The request that it waits on, while the hub lists it open.
    private var need: OwnerNeed? { level.request.flatMap { id in store.openNeeds.first { $0.id == id } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Text(level.title).font(FormMetrics.title).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                // Esc closes the job level, also while the cursor is in a request's answer box: in the card's window a
                // button's key goes before the field's, which passes Esc on to the window (`FleetStore.detailEscape`).
                Button("Done") { store.closeDetail() }.buttonStyle(FleetOutlineButtonStyle()).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("detail-done")
            }
            if let need {
                NeedRequestCard(store: store, need: need)
            } else {
                FormSection { statusRow }
            }
            let lines = level.lines
            if !lines.isEmpty {
                // A task that waits for him says so as his panel and the agent's dot say it (`ownerWaits`).
                let waits = state.ownerWaits(of: lines.map(\.task).filter { !$0.isTerminal })
                FormSection(String(l10n: "Tasks")) {
                    ForEach(lines) { line in taskRow(line, wait: waits[line.task.id]) }
                }
            }
            // **An answer that the hub did not confirm, at the card's foot**, with its Retry and Discard: the window's
            // own request line is under the card's dim, as for the task level (`TaskDetail`).
            if store.pending != nil, !store.sending {
                PendingBar(store: store).clipShape(RoundedRectangle(cornerRadius: FormMetrics.radius))
            }
        }
        .padding(22).frame(width: FormMetrics.formWidth)
        .accessibilityIdentifier("job-detail")
    }

    /// **How it ended, and when**, or where it stands while it goes on: its mark, its words, and under them what its
    /// agent recorded; the day and time at the right. While it goes on, the task that says where it stands speaks for
    /// it, in the mark and the words of its own row under it: one that waits for him, else one in work now, else the
    /// open one that moved last.
    private var statusRow: some View {
        let open = level.open
        let waits = state.ownerWaits(of: open)
        let lead = open.first { waits[$0.id] != nil } ?? open.first { $0.mark(in: state).inWork }
            ?? open.max { ($0.activityTime, $0.id) < ($1.activityTime, $1.id) }
        let wait = lead.flatMap { waits[$0.id] }
        let mark = lead?.mark(in: state)
        let words: String = if let result = level.result { result.words }
            else if case .request? = wait { String(l10n: "Waits for you") }
            else if let wait { wait.words }
            else { mark?.words ?? String(l10n: "Waiting") }
        let detail = level.recorded ?? (mark?.inWork == true ? lead?.doing : nil)
        return HStack(alignment: .top, spacing: 0) {
            RowMark {
                if let end = level.result?.end {
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
                Text(words).font(FormMetrics.title).foregroundStyle(level.result?.end == .failed ? EndedRow.failedWords : FleetStyle.text)
                if let detail, !detail.isEmpty {
                    Text(detail).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            if let at = level.endedAt {
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
    /// than the task that gave it. It opens the task level over this job.
    private func taskRow(_ line: WorkItem.Line, wait: OwnerWait?) -> some View {
        let task = line.task, mark = task.mark(in: state)
        let standing: String = if case .request? = wait { String(l10n: "Waits for you") } else { wait?.words ?? mark.words }
        let when = task.isTerminal ? ChatStamp.words(task.delivered ?? task.checked_at ?? task.activityTime) : standing
        let detail = [task.owner.agentLabel, task.isTerminal ? task.failedResult : nil, when].compactMap { $0 }
            .joined(separator: " · ")
        return Button { store.show(.task(task.id), inCard: true) } label: {
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
        .opensTask(task.id, store: store)
        .help([task.title, detail].joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([task.title, detail].joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("work-task-\(task.id)")
    }

    /// The mark of a thing that ended: the board's green check of a result that succeeded, its red of one that did not.
    @ViewBuilder static func endMark(_ end: WorkItem.End) -> some View {
        switch end {
        case .done: Image(systemName: "checkmark.circle.fill").font(IconMetrics.symbol(mark)).foregroundStyle(FleetTask.MarkTint.checked.color)
        case .failed: Image(systemName: "exclamationmark.circle.fill").font(IconMetrics.symbol(mark)).foregroundStyle(FleetTask.MarkTint.failed.color)
        case .quiet: Image(systemName: "circle").font(IconMetrics.symbol(mark)).foregroundStyle(FleetStyle.muted)
        }
    }

    /// The size of every mark of the card, a form row's (`FormRow`).
    private static let mark: CGFloat = 15
    /// How far a subtask stands in under the task that gave it: one mark's column and its gap.
    private static let step = FormMetrics.markColumn + FormMetrics.markGap
}
