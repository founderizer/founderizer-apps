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
/// write that the hub did not confirm stands at the card's foot with its Retry and Discard (`PendingBar`), and under it
/// the box of his feedback on the job, with his messages about it over the bar (`FeedbackBox`, `FeedbackRows`).
struct JobDetail: View {
    @Bindable var store: FleetStore
    let level: JobLevel
    let state: HubState

    /// His feedback on the job, to the job's agent where its chat can read the job (`HubState.feedback(onJob:)`), on a
    /// hub that takes it; else nil.
    private var feedback: Feedback? {
        state.ui_features?.contains("message_about") == true ? state.feedback(onJob: level) : nil
    }
    /// His feedback that this card saw go, until the reading holds the hub's copy (`keepsFeedbackSent`).
    @State private var feedbackSent: PendingRequest?

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
                // a key request's form is the card's, outside its two builds (`keptKeyForm`, `fleetModal`)
                NeedRequestCard(store: store, need: need)
                    .environment(\.keptKeyForm, need.asksForSecret ? store.keptKeyForm(for: need.id) : nil)
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
            // His feedback on the job, between its tasks and the box, from the frame he sends it (`FeedbackRows`).
            // No selection of their words here: the card of a job has no thread to select in.
            FeedbackRows(store: store, messages: state.messages(aboutJob: level), state: state, feedback: feedback,
                         sent: feedbackSent, selection: nil)
            // **An answer that the hub did not confirm, at the card's foot**, with its Retry and Discard: the window's
            // own request line is under the card's dim, as for the task level (`TaskDetail`).
            if store.pending != nil, !store.sending {
                PendingBar(store: store).clipShape(RoundedRectangle(cornerRadius: FormMetrics.radius))
            }
            // **His feedback on the job, at the card's foot** (design part 2), to the job's agent where its chat can
            // read the job (`HubState.feedback(onJob:)`), on a hub that takes it.
            if let feedback { FeedbackBox(store: store, feedback: feedback) }
        }
        .padding(22).frame(width: FormMetrics.formWidth)
        .keepsFeedbackSent($feedbackSent, store: store, feedback: feedback)
    }

    /// **How it ended, and when**, or where it stands while it goes on: its mark, its words, and under them what its
    /// agent recorded; the day and time at the right. While it goes on, the task that says where it stands speaks for
    /// it, in the mark and the words of its own row under it: one that waits for him, else one in work now, else the
    /// open one that moved last (`JobLevel.standing`, which the badge of his message about the job shows too).
    private var statusRow: some View {
        let standing = level.standing(in: state)
        let lead = standing.lead
        let detail = level.recorded ?? (lead?.mark(in: state).inWork == true ? lead?.doing : nil)
        return HStack(alignment: .top, spacing: 0) {
            RowMark { StandingMarkView(mark: standing.mark, size: Self.mark, store: store) }.accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(standing.words).font(FormMetrics.title).foregroundStyle(level.result?.end == .failed ? EndedRow.failedWords : FleetStyle.text)
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
    /// than the task that gave it; a failure that later work of the job took over has a muted mark, as on the board
    /// (`JobLevel.replaced`). It opens the task level over this job, also by an assistive app's press (VoiceOver's
    /// VO-Space, `AXPress`): the row's one element of its words is no button's own, so it takes the row's action as its
    /// default action, as a card of the board does.
    private func taskRow(_ line: WorkItem.Line, wait: OwnerWait?) -> some View {
        let task = line.task, mark = task.mark(in: state)
        let standing: String = if case .request? = wait { String(l10n: "Waits for you") } else { wait?.words ?? mark.words }
        let when = task.isTerminal ? ChatStamp.words(task.delivered ?? task.checked_at ?? task.activityTime) : standing
        let detail = [task.owner.agentLabel, task.isTerminal ? task.failedResult : nil, when].compactMap { $0 }
            .joined(separator: " · ")
        let open = { store.show(.task(task.id), inCard: true) }
        return Button(action: open) {
            HStack(spacing: 0) {
                RowMark {
                    if wait != nil { Image(systemName: "hand.raised.fill").font(IconMetrics.symbol(Self.mark)).foregroundStyle(.orange) }
                    else if mark.inWork && store.isFresh { WorkMark(size: Self.mark, moves: store.marksMove) }
                    // a failure that later work of the job took over is muted, as on the board: it is no news
                    else { Image(systemName: mark.symbol).font(IconMetrics.symbol(Self.mark))
                        .foregroundStyle(task.tint(in: state, replaced: level.replaced.contains(task.id)).color) }
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
        .accessibilityAction(.default, open)
        .accessibilityIdentifier("work-task-\(task.id)")
    }

    /// The size of every mark of the card, a form row's (`FormRow`).
    private static let mark: CGFloat = 15
    /// How far a subtask stands in under the task that gave it: one mark's column and its gap.
    private static let step = FormMetrics.markColumn + FormMetrics.markGap
}

/// **The mark of where a task or a job stands** (`StandingMark`), as the board draws it: a task's symbol in its colour,
/// which turns in the green of work while it is work now and the reading is current (`marksMove`); the orange hand of
/// what waits for him; how a job ended, the board's green check of a result that succeeded and its red of one that did
/// not; and the muted dotted circle of a job that goes on with no task that says where. The job level's state row and
/// the badge of his message about a task or a job (`AboutBadgeView`) draw it.
struct StandingMarkView: View {
    let mark: StandingMark
    let size: CGFloat
    let store: FleetStore

    var body: some View {
        switch mark {
        case .task(let symbol, let tint, let inWork):
            if inWork && store.isFresh { WorkMark(size: size, moves: store.marksMove) }
            else { Image(systemName: symbol).font(IconMetrics.symbol(size)).foregroundStyle(tint.color) }
        case .waits: Image(systemName: "hand.raised.fill").font(IconMetrics.symbol(size)).foregroundStyle(.orange)
        case .ended(.done): Image(systemName: "checkmark.circle.fill").font(IconMetrics.symbol(size)).foregroundStyle(FleetTask.MarkTint.checked.color)
        case .ended(.failed): Image(systemName: "exclamationmark.circle.fill").font(IconMetrics.symbol(size)).foregroundStyle(FleetTask.MarkTint.failed.color)
        case .ended(.quiet): Image(systemName: "circle").font(IconMetrics.symbol(size)).foregroundStyle(FleetStyle.muted)
        case .open: Image(systemName: "circle.dotted").font(IconMetrics.symbol(size)).foregroundStyle(FleetStyle.muted)
        }
    }
}
