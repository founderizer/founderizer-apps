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
                Section { LoadingLine(String(l10n: "Reading the hub…")).listRowBackground(Color.clear) }
            }
            if !store.openHolds.isEmpty || !store.openOutcomes.isEmpty { stopped }
            if !store.openTasks.isEmpty {
                Section { rows(store.openTasks) } header: { GroupHeading(String(localized: "Open (a lane)", defaultValue: "Open", bundle: Localized.bundle, locale: Localized.digits)) }
                .brandRows()
            }
            if !store.endedTasks.isEmpty {
                Section { rows(store.endedTasks) } header: { GroupHeading(String(l10n: "Ended")) }
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
                              detail: hold.detail ?? String(l10n: "The hub holds this task."),
                              value: hubWords(hold.state), valueColor: Brand.warning)
                }
            }
            ForEach(store.openOutcomes) { outcome in
                MarkColumn {
                    DetailRow(title: outcome.title,
                              detail: outcome.note ?? String(l10n: "The outcome of this action is not known."),
                              value: String(l10n: "Not known"), valueColor: Brand.warning)
                }
            }
        } header: {
            GroupHeading(String(l10n: "Work that stopped"))
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
    /// **The usage limit that holds a task now, by FleetCore's one rule** (`TaskLimit`, owner API 1.330): `own`, the
    /// task's own `limit`, on a hub that sends it, else the `limit` of its agent `owner`, from `snapshot`.
    nonisolated static func limit(_ own: RuntimeLimit?, owner: String, in snapshot: MobileSnapshot?) -> RuntimeLimit? {
        TaskLimit.holding(task: own, agent: snapshot?.agents.first { $0.name == owner }?.limit,
                          served: TaskLimit.served(snapshot?.ui_features))
    }

    /// The usage limit that holds a task now, by what this phone read last: a head, and the task itself on its page.
    func limit(of head: MobileTaskHead) -> RuntimeLimit? { Self.limit(head.limit, owner: head.owner, in: snapshot) }
    func limit(of task: FleetTask) -> RuntimeLimit? { Self.limit(task.limit, owner: task.owner, in: snapshot) }

    /// **The line under a task's title on its page while a usage limit holds it**: its end only ("Until 16:00", or with
    /// "(estimate)" when the provider gave no reset time), from the rule of every limit (`limit(_:owner:in:)`); nil for
    /// a task that ended, which nothing holds (fix round 2, item 32), and for one that no limit holds.
    nonisolated static func untilLine(_ task: FleetTask, in snapshot: MobileSnapshot?, now: Double) -> String? {
        guard !task.isTerminal, let limit = limit(task.limit, owner: task.owner, in: snapshot) else { return nil }
        let until = comingTime(limit.until, now: now)
        return limit.reset_known ? String(l10n: "Until \(until)") : String(l10n: "Until \(until) (estimate)")
    }
    func untilLine(_ task: FleetTask) -> String? { Self.untilLine(task, in: snapshot, now: hubNow) }

    /// A task's one state word against what this phone read last: the fleet's holds and the usage limit that holds it.
    func stateWord(_ head: MobileTaskHead) -> String {
        head.stateWord(holds: openHolds, limited: limit(of: head) != nil)
    }

    /// The task itself, on its page: the same function, with the stall and the lost session that it carries.
    func stateWord(_ task: FleetTask) -> String {
        task.stateWord(holds: openHolds, limited: limit(of: task) != nil)
    }

    /// **A task's mark, the Mac's, on every screen of the phone** (fix round 3, item 27): its symbol, in the brand's green
    /// for work and a checked result, orange where it needs someone, red for a result that failed, muted otherwise.
    func mark(_ head: MobileTaskHead) -> (symbol: String, color: Color) {
        let unknown = openOutcomes.contains { $0.task == head.id }, limited = limit(of: head) != nil
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
        let unknown = openOutcomes.contains { $0.task == task.id }, limited = limit(of: task) != nil
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
