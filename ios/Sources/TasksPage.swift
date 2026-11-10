import FleetCore
import SwiftUI

/// Tasks: the work that stopped, the open tasks, then the tasks that ended, with their state, their owner and their
/// last activity (MOBILE-APP.md 10). These are the heads of the compact read; the task itself comes when the owner
/// opens it.
///
/// **The work that stopped is the first group** (the owner's yes of 28 October 2026 to the map of D-4): the holds and
/// the outcomes that nobody knows stood on Fleet, a tab of their own, which went.
struct TasksPage: View {
    let store: MobileStore

    var body: some View {
        List {
            if store.readsTheHub {
                Section { LoadingLine("Reading the hub…").listRowBackground(Color.clear) }
            }
            if !store.openHolds.isEmpty || !store.openOutcomes.isEmpty { stopped }
            if !store.openTasks.isEmpty {
                Section { rows(store.openTasks) } header: { GroupHeading("Open") }
                .brandRows()
            }
            if !store.endedTasks.isEmpty {
                Section { rows(store.endedTasks) } header: { GroupHeading("Ended") }
                .brandRows()
            }
        }
        .listStyle(.insetGrouped)
        .brandPage()
        .overlay {
            // One title and no second line (D-2); a hub that does not answer says so once, over the page.
            if store.openTasks.isEmpty && store.endedTasks.isEmpty && store.openHolds.isEmpty && store.openOutcomes.isEmpty
                && store.snapshot != nil && store.showsCurrent {
                ContentUnavailableView("No tasks yet", systemImage: "checklist")
            }
        }
        .refreshable { await store.refresh() }
        .tabRootPage()
        .hubBanner(store)
    }

    private func rows(_ tasks: [MobileTaskHead]) -> some View {
        ForEach(tasks) { task in
            NavigationLink(value: task.id) { TaskRow(task: task, words: store.stateWord(task), mark: store.mark(task), now: store.hubNow) }
        }
    }

    /// What stops work now: a hold of the hub that is not released, and an action whose outcome nobody knows.
    private var stopped: some View {
        Section {
            ForEach(store.openHolds) { hold in
                MarkColumn {
                    DetailRow(title: [store.head(hold.task)?.title, hubWords(hold.kind)].compactMap { $0 }.joined(separator: " · "),
                              detail: hold.detail ?? "The hub holds this task.",
                              value: hubWords(hold.state), valueColor: Brand.warning)
                }
            }
            ForEach(store.openOutcomes) { outcome in
                MarkColumn {
                    DetailRow(title: outcome.title,
                              detail: outcome.note ?? "The outcome of this action is not known.",
                              value: "Not known", valueColor: Brand.warning)
                }
            }
        } header: {
            GroupHeading("Work that stopped")
        }
        .brandRows()
    }
}

/// One task in a list: its number and title, its state, its owner and when it last did something.
struct TaskRow: View {
    let task: MobileTaskHead
    /// Its one state word (`TaskWords`).
    let words: String
    /// Its mark, the Mac's (`MobileStore.mark`).
    let mark: (symbol: String, color: Color)
    let now: Double
    /// The state line names the task's agent; an agent's own page, which names it already, leaves it out.
    var namesOwner = true
    /// The mark's column grows with the mark: a fixed 22 points let the mark cover the title's first letters at the
    /// largest text size ("◌Draft").
    @ScaledMetric(relativeTo: .title3) private var markWidth: CGFloat = 22
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // **At the accessibility sizes the mark stands over the title** (T-38, fix round 1), so the title has the
        // whole row: beside the mark and the chevron its words broke inside ("No-vember", "news-letter").
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        layout {
            Image(systemName: mark.symbol)
                .font(.title3).symbolRenderingMode(.hierarchical)
                .foregroundStyle(mark.color)
                .frame(width: typeSize.isAccessibilitySize ? nil : markWidth)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title).fixedSize(horizontal: false, vertical: true)
                TaskStateLine(id: task.id, owner: namesOwner ? task.owner : nil, words: words,
                              activity: task.activityTime, now: now)
            }
        }
        .padding(.vertical, 3)
        // A whole number of points, as every row of a grouped list (margins pass, fault 8).
        .wholePoints()
    }
}

/// **A row whose words stand on the column of the task rows' titles** (fix round 2, item 79): the mark's place, empty,
/// before them, so "Work that stopped" starts at the same x as "Open" and "Ended" (it started 34 points to the left).
/// At the accessibility sizes the task rows stack their mark over the title, and this row has no empty place.
private struct MarkColumn<Content: View>: View {
    @ViewBuilder let content: Content
    @ScaledMetric(relativeTo: .title3) private var markWidth: CGFloat = 22
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if !typeSize.isAccessibilitySize { Color.clear.frame(width: markWidth, height: 1) }
            content
        }
    }
}

/// The facts under a task's title: its number, its owner (where the page does not name it), its state and its last
/// activity.
struct TaskStateLine: View {
    let id: Int
    let owner: String?
    let words: String
    let activity: Double
    let now: Double

    var body: some View {
        MetaLine(parts: [owner.map(agentName) ?? "", words, fleetAge(activity, now: now)])
    }
}

extension MobileStore {
    /// A task's one state word against what this phone read last: the fleet's holds and its agent's usage limit.
    func stateWord(_ head: MobileTaskHead) -> String {
        head.stateWord(holds: openHolds, limited: agent(head.owner)?.limit != nil)
    }

    /// The task itself, on its page: the same function, with the stall and the lost session that it carries.
    func stateWord(_ task: FleetTask) -> String {
        task.stateWord(holds: openHolds, limited: agent(task.owner)?.limit != nil)
    }

    /// **A task's mark, the Mac's, on every screen of the phone** (fix round 3, item 27): its symbol, in the brand's green
    /// for work and a checked result, orange where it needs someone, red for a result that failed, muted otherwise.
    func mark(_ head: MobileTaskHead) -> (symbol: String, color: Color) {
        let unknown = openOutcomes.contains { $0.task == head.id }, limited = agent(head.owner)?.limit != nil
        let mark = head.mark(holds: openHolds, limited: limited, outcomeUnknown: unknown)
        // The board's own rule for its colour (`FleetTask.tint`), from the same mark.
        let tint: FleetTask.MarkTint = unknown ? .attention
            : head.isTerminal && !openHolds.contains(where: { $0.task == head.id && $0.state != "released" })
                ? (head.accepted == 1 && head.state == "completed" ? .checked : head.failedResult != nil ? .failed : .quiet)
                : mark.inWork ? .work : mark.attention ? .attention : .quiet
        return (mark.symbol, Self.color(tint))
    }

    /// **One mark for a task on every screen** (fix round 3b): FleetCore's `FleetTask.mark` and its `tint`, as the
    /// board draws them, with the task's outcome that is not known first — T-437 was an orange "?" on Needs you and a
    /// grey pause elsewhere.
    func mark(_ task: FleetTask) -> (symbol: String, color: Color) {
        let unknown = openOutcomes.contains { $0.task == task.id }, limited = agent(task.owner)?.limit != nil
        return (task.mark(holds: openHolds, limited: limited, outcomeUnknown: unknown).symbol,
                Self.color(task.tint(holds: openHolds, limited: limited, outcomeUnknown: unknown)))
    }

    /// The tint in the brand's colours: green for work and a checked result, orange where it needs someone, red for a
    /// result the board badges red (Canceled too), muted otherwise.
    static func color(_ tint: FleetTask.MarkTint) -> Color {
        switch tint {
        case .work, .checked: Brand.online
        case .attention: Brand.warning
        case .failed: .red
        case .quiet: .secondary
        }
    }
}

extension MobileTaskHead {
    /// **Its one state word, the Mac's** (`TaskWords.state` in FleetCore, which the Mac's panel, its thread and the
    /// phone all use; fix round 2, item 29): a hold's word while a hold stands ("Paused", "Stopping…", "Stop not
    /// confirmed"), "Usage limit" while its agent's usage limit holds open work, a stall, a lost session, a checked
    /// result, who it waits for, and its own state. **The hold comes first, also before a result** (review B4i): a stop
    /// that its helper has not confirmed says "Stopping…" over "Canceled", as the Mac's thread says it. The phone's list
    /// said "Working" for a paused, a limited and a stalled task that its page and the Mac called otherwise. A hub from
    /// before the stall fields sends none of them, and the row then says what the head alone knows.
    func stateWord(holds: [TaskHold], limited: Bool) -> String {
        let hold = holds.first { $0.task == id && $0.state != "released" }
        return TaskWords.state(state, accepted: accepted, requester: requester, waitingOn: waiting_on,
                               stalled: stalled_since != nil || (nudge_level ?? 0) > 0,
                               reconnecting: missing_since != nil,
                               hold: hold.map { TaskWords.Hold(kind: $0.kind, state: $0.state) }, limited: limited)
    }

    /// **The Mac's mark of a task, from its head** (FleetCore's `FleetTask.mark(holds:limited:)`, rule for rule; fix round
    /// 3, item 27): its symbol, its one state word, whether it needs someone, and whether it is work now — the hold
    /// first, then a result, the usage limit, a stall, a lost session, a question or a sign-in, a wait, and its state. The
    /// phone drew a paused, a stalled and a limited task with the green circle of work.
    func mark(holds: [TaskHold], limited: Bool, outcomeUnknown: Bool = false)
        -> (symbol: String, words: String, attention: Bool, inWork: Bool) {
        // An outcome that is not known comes first (fix round 3b, as FleetCore's).
        if outcomeUnknown { return ("questionmark.circle", "Outcome not known: check it", true, false) }
        let words = stateWord(holds: holds, limited: limited)
        if let hold = holds.first(where: { $0.task == id && $0.state != "released" }) {
            return hold.state == "not_confirmed" ? ("exclamationmark.circle", words, true, false) : ("pause.circle", words, false, false)
        }
        if isTerminal {
            // The board's result look, as FleetCore's (fix round 3b): a filled check, a filled "!" for a result the
            // board badges red, Canceled included, and a muted circle for one that waits for its check.
            if accepted == 1 && state == "completed" { return ("checkmark.circle.fill", words, false, false) }
            if failedResult != nil { return ("exclamationmark.circle.fill", words, state != "canceled", false) }
            return ("circle", words, false, false)
        }
        if limited { return ("hourglass", words, true, false) }
        if stalled_since != nil || (nudge_level ?? 0) > 0 { return ("exclamationmark.circle", words, true, false) }
        if missing_since != nil { return ("arrow.triangle.2.circlepath", words, true, false) }
        switch state {
        case "input-required": return ("questionmark.circle", words, true, false)
        case "auth-required": return ("key", words, true, false)
        default: break
        }
        if let waiting = waiting_on, !waiting.isEmpty { return ("hourglass", words, true, false) }
        switch state {
        case "working": return ("circle.dotted", words, false, true)
        case "submitted": return ("clock", words, false, false)
        default: return ("circle", words, false, false)
        }
    }
}
