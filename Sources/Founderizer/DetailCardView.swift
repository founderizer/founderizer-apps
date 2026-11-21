import FleetCore
import SwiftUI

/// **A task or a job, as one card over the window** (the owner, 20 November 2026, of the Tasks board: "we should
/// probably consider showing the cards here as modals once clicked instead of moving pages", and 21 November 2026:
/// "task details to open as a modal, as I already mentioned yesterday and hasn't been done yet, even for the tasks
/// page!"; `FleetStore.detail`). The page under it stays as it is: its scroll, its filter, its open rows. Two levels in
/// one card: the job level (`JobDetail`), and the task level (`TaskDetail`), which a row of the job level opens in the
/// same card, with the back link to that job. Done and a click on the dimmed window close it; Esc goes back from a
/// task that came from a job to that job, and closes every other card (`FleetStore.detailBack`), and one control of
/// the card takes it at a time: Done, the back link, or the open check of a result. Each reading draws it from its own
/// tasks (`FleetStore.detailLevels`, worked out once for each reading), never from what the press that opened it saw.
struct DetailCardView: View {
    @Bindable var store: FleetStore
    let card: DetailCard

    var body: some View {
        Group {
            if let state = store.state, let levels = store.detailLevels {
                if let id = card.shown.task, let task = state.tasks.first(where: { $0.id == id }) {
                    TaskDetail(store: store, task: task, state: state, back: levels.under?.title)
                } else if let level = levels.shown {
                    JobDetail(store: store, level: level, state: state)
                }
            }
        }
        // The card stands in a window of its own, which takes none of the main window's own looks.
        .font(FleetStyle.body).foregroundStyle(FleetStyle.text).tint(FleetStyle.accent)
    }
}

/// **The task level of the detail card**: the Task page as a card. At the left the task's thread (`TaskView`) with,
/// under it, the check of a result that nobody knows (`TaskOutcomeCheck`) and the guidance box (`TaskSteering`), as the
/// page had them; at the right the task's facts (`TaskPanel`), 340 points wide, with Done at their top right. At the top
/// left, only when it came from a job level, the back link to that job, on one line. The thread scrolls inside its
/// column and gives way to what stands under it; the card itself never scrolls, and is built once (`fleetModal`'s card
/// of a fixed size). **The card says itself what the window says under its dim**: a write that the hub did not confirm
/// stands over the guidance box with its Retry and Discard (`PendingBar`), and the thread and the facts say their own
/// reads that failed.
struct TaskDetail: View {
    @Bindable var store: FleetStore
    let task: FleetTask
    let state: HubState
    /// The name of the job level that it came from, for its back link, or nil.
    let back: String?
    /// The check of a result that nobody knows has its form open: its Cancel takes Esc (`OutcomeFormOpen`).
    @State private var checking = false

    /// The card's size where the window has room for it (design 1.1): 1,120 by 1,040 points, else the window's room.
    static let size = CGSize(width: 1120, height: 1040)
    /// The facts' column.
    static let facts: CGFloat = 340
    /// **The room over the first thing of each column**, the thread's first row and the head of the facts, as the
    /// other cards over the page keep 22 points inside their edge (`SecretsPage`, `KnowledgePage`).
    static let top: CGFloat = 22

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                // **The back link stands on a line of its own over the thread**, which scrolls and fades under it, not
                // behind it: over the scroll, the words of the rows read through the link's.
                if let back {
                    FleetBack(back, escapes: !checking) { store.detailBack() }.lineLimit(1)
                        .padding(.top, Self.top).padding(.horizontal, FleetSpace.margin)
                        .accessibilityIdentifier("detail-back")
                }
                TaskView(store: store, task: task, state: state, hub: store.hub, isFresh: store.isFresh,
                         top: back == nil ? Self.top : FleetSpace.underBand)
                    .id("\(store.hub)/\(task.id)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                // **Under the thread, its guidance box alone, as a chat has its composer** (the owner's yes of 17
                // November 2026 to the pictures of the Task page): its Pause and Stop are in its facts' state row
                // (`TaskHoldControls`). Only the check of a result that nobody knows stands over the box, and only
                // while it is his: while the task runs or waits for its next session, its agent checks first
                // (`TaskOutcome.waitsOnOwner`).
                if state.ui_features?.contains("task_controls") == true, state.outcomeUnknown(task.id) {
                    // **Room under it where no guidance box stands under it** (the margins of 30 October 2026, row 7).
                    let boxUnder = !task.isTerminal && state.ui_features?.contains("task_steering") == true
                        && TaskSteering.shows(task, in: state)
                    TaskOutcomeCheck(store: store, task: task)
                        .id("\(store.hub)/\(task.id)")
                        .chatColumn().padding(.top, 8).padding(.bottom, boxUnder ? 0 : FleetSpace.under)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // The window's request line stands under the card's dim: the card has its own, over the box.
                if store.pending != nil, !store.sending { PendingBar(store: store) }
                if !task.isTerminal, state.ui_features?.contains("task_steering") == true {
                    TaskSteering(store: store, task: task).id("\(store.hub)/\(task.id)/\(task.attempt)")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onPreferenceChange(OutcomeFormOpen.self) { open in checking = open; store.detailHoldsEscape = open }
            Rule(vertical: true)
            // Done takes Esc only where nothing else of the card takes it: the back link, or the open check's Cancel.
            TaskPanel(store: store, task: task, escapes: back == nil && !checking) { store.closeDetail() }
                .id("\(store.hub)/\(task.id)")
                .frame(width: Self.facts)
        }
        .accessibilityIdentifier("task-detail")
    }
}
