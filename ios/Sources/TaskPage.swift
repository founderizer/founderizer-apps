import FleetCore
import SwiftUI

/// One task in full: what it is, what "done when" asks, its progress notes as a thread, and its result with the
/// requester's check. The task and its notes come from `GET /ui/mobile/task/<id>`, one page of notes at a time, so
/// the head that the list shows is replaced by the task itself as soon as the hub answers. Pause, Stop and Steer come
/// in phase 4 (MOBILE-APP.md 13).
struct TaskPage: View {
    let store: MobileStore
    let id: Int
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The column of the head's mark, as on a task's row: it grows with the mark.
    @ScaledMetric(relativeTo: .title3) private var markWidth: CGFloat = 22

    private var page: MobileTaskPage? { store.taskPage(id) }

    var body: some View {
        List {
            if let page {
                Section { head(page.task) }
                .brandRows()
                fields(page.task)
                notes(page.notes)
                stopped(page)
                result(page.task)
            } else {
                // The list's head, while the task itself is on its way.
                if let head = store.head(id) {
                    Section { summary(head) }
                    .brandRows()
                }
                // Where the task's sections will stand: nothing for a second, then the page's words. **While the hub
                // does not answer, nothing is on its way** (T-13): no spinner that turns for ever. **The line over the
                // page says it once** (polish pass): the page said it again under it, with another subject ("Your hub
                // did not answer." over "Founderizer cannot read the task now."). The page's own words stand only
                // where no line over the page says why.
                if !store.readCanCome {
                    if store.unavailableWords == nil {
                        Section {
                            Text("Founderizer cannot read the task now.")
                                .font(.footnote).foregroundStyle(Brand.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .listRowBackground(Color.clear)
                                .accessibilityIdentifier("task-not-read")
                        }
                    }
                } else if store.head(id) != nil {
                    Section {
                        LoadingLine("Reading the task…")
                            .listRowBackground(Color.clear)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .brandPage()
        .overlay {
            // One title and no second line (D-2): a hub that does not answer says so once, over the page.
            if page == nil, store.head(id) == nil, store.readCanCome {
                ContentUnavailableView("This task is not here", systemImage: "questionmark.circle")
            }
        }
        .task(id: id) {
            store.beginWait(task: id)
            await store.refresh()
        }
        .refreshable { await store.refresh() }
        .navigationTitle(store.head(id)?.title ?? "Task")
        .navigationBarTitleDisplayMode(.inline)
        .hubBanner(store)
    }

    /// The head of the list, while the task itself is on its way: the same word as its row (`TaskWords.state`).
    private func summary(_ task: MobileTaskHead) -> some View {
        headBlock(mark: store.mark(task).symbol, color: store.mark(task).color, title: task.title) {
            TaskStateLine(id: task.id, owner: task.owner, words: store.stateWord(task),
                          activity: task.activityTime, now: store.hubNow)
        }
    }

    /// The task itself knows more than its head: a stalled agent, a helper that is reconnecting, a usage limit. Its
    /// word is its row's, from the one function (`TaskWords.state`, FleetCore), so the list and the page never say
    /// two things.
    private func head(_ task: FleetTask) -> some View {
        headBlock(mark: store.mark(task).symbol, color: store.mark(task).color, title: task.title) {
            TaskStateLine(id: task.id, owner: task.owner, words: store.stateWord(task),
                          activity: task.activityTime, now: store.hubNow)
            if let reason = task.stalled_reason {
                fact(reason, symbol: "exclamationmark.circle")
            }
            // **Only while the limit holds this task** (fix round 2, item 32): a task that ended is held by nothing,
            // and its page said its agent's limit in orange. **Its end only** (the lead's call on item 32): the head
            // over it says "Usage limit", and the line said it again with the year.
            if !task.isTerminal, let limit = store.agent(task.owner)?.limit {
                fact("Until \(comingTime(limit.until, now: store.hubNow))\(limit.reset_known ? "" : " (estimate)")",
                     symbol: "clock")
            }
        }
    }

    /// An orange fact under the title: its symbol, then its words, on the title's left edge.
    private func fact(_ words: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(words).fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote).foregroundStyle(Brand.warning)
    }

    /// What the page opens with: the task's mark, its title, and the quiet facts under it.
    ///
    /// **One left edge for the title and every fact under it, as a task's row on Tasks** (margins pass, fault 2): the
    /// mark in its 22-point column, 12 points before the words. The state line stood under the mark, the title 10
    /// points after a mark of its own width, and the orange lines after a label's own icon column: four left edges in
    /// one card.
    private func headBlock<Content: View>(mark: String, color: Color, title: String,
                                          @ViewBuilder facts: () -> Content) -> some View {
        // At the accessibility sizes the mark stands over the title, so the title has the whole width (T-38).
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        return layout {
            Image(systemName: mark).font(.title3)
                .symbolRenderingMode(.hierarchical).foregroundStyle(color)
                .frame(width: typeSize.isAccessibilitySize ? nil : markWidth)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                facts()
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wholePoints()
    }

    @ViewBuilder private func fields(_ task: FleetTask) -> some View {
        Section {
            FieldRow(title: "What it asks", value: task.details)
            FieldRow(title: "Done when", value: task.done_when)
            if !task.goal.isEmpty { FieldRow(title: "Goal", value: task.goal) }
            if let why = task.why, !why.isEmpty { FieldRow(title: "Why this agent", value: why) }
            // The Mac's words for the same rows: "Asked by" and "Result check".
            LabeledContent("Asked by", value: agentName(task.requester)).wholePoints()
            LabeledContent("Attempt", value: "\(task.attempt)").wholePoints()
            LabeledContent("Started", value: fleetDate(task.started)).wholePoints()
        } header: {
            GroupHeading("The task")
        }
        .brandRows()
    }

    /// The agent's own notes. A task with none has no Progress card: the agent writes one at each real step, so
    /// an empty card says only that it has not got there yet, which the task's own state above already says.
    @ViewBuilder private func notes(_ notes: [ProgressNote]) -> some View {
        if !notes.isEmpty {
            Section {
                ForEach(notes) { note in
                    VStack(alignment: .leading, spacing: 4) {
                        MetaLine(parts: [agentName(note.agent), fleetTime(note.ts)])
                        Text(verbatim: note.text).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } header: {
                GroupHeading("Progress · \(notes.count)")
            }
            .brandRows()
        }
    }

    /// What stops this task now: a hold that is not released, or an action whose outcome nobody knows.
    @ViewBuilder private func stopped(_ page: MobileTaskPage) -> some View {
        let holds = page.holds.filter { $0.state != "released" }
        let outcomes = page.outcomes.filter { $0.state == "unknown" }
        if !holds.isEmpty || !outcomes.isEmpty {
            Section {
                ForEach(holds) { hold in
                    DetailRow(title: hubWords(hold.kind), detail: hold.detail ?? "The hub holds this task.",
                              value: hubWords(hold.state), valueColor: Brand.warning)
                }
                ForEach(outcomes) { outcome in
                    DetailRow(title: outcome.title, detail: outcome.note ?? "The outcome of this action is not known.",
                              value: "Not known", valueColor: Brand.warning)
                }
            } header: {
                GroupHeading("Work that stopped")
            }
            .brandRows()
        }
    }

    /// What the task delivered, once it has delivered something. A task still in work has no Result card at all:
    /// "No result yet" under a task whose state already says Working is a row that carries no news.
    @ViewBuilder private func result(_ task: FleetTask) -> some View {
        if task.delivered != nil || task.accepted != nil {
            resultSection(task)
        }
    }

    private func resultSection(_ task: FleetTask) -> some View {
        Section {
            LabeledContent("Result check") {
                Text(task.checkStatus).foregroundStyle(task.accepted == 1 ? Brand.online : Brand.muted)
            }
            .wholePoints()
            if let what = task.what, !what.isEmpty { FieldRow(title: "What was done", value: what) }
            // `where_` is never opened as an address: it is text (MOBILE-APP.md 10).
            if let output = task.where_, !output.isEmpty { FieldRow(title: "Where the output is", value: output) }
            if let how = task.how, !how.isEmpty { FieldRow(title: "How it was checked", value: how) }
            if let note = task.check_note, !note.isEmpty { FieldRow(title: "Result check", value: note) }
            if let outcome = task.outcome, !outcome.isEmpty { FieldRow(title: "Outcome", value: outcomeWords(outcome)) }
        } header: {
            GroupHeading("Result")
        }
        .brandRows()
    }

    /// The hub's outcome in the state's own words (T-12): "Canceled", never the hub's "canceled".
    private func outcomeWords(_ outcome: String) -> String {
        switch outcome {
        case "completed": "Completed"
        case "failed": "Failed"
        case "rejected": "Rejected"
        case "canceled": "Canceled"
        default: outcome.capitalizedFirst
        }
    }
}

