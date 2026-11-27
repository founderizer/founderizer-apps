import FleetCore
import SwiftUI

/// The gap between activity rows. An agent message's footer takes its height from it, and every other row gets the
/// same height below it, so each gap stays 15 points.
private let activitySpacing = ChatStyle.rowSpacing, activityFooter = AgentReply.footer(compact: true)

/// **What a task thread read last** (`GET /ui/tasks/<id>/events`), kept by the store for its hub generation
/// (`FleetStore.reading`), so a task opened again draws its thread and its panel in their first frame and reads on
/// from where it stopped. A thread used to start empty at every visit and arrive in three steps (0, +138 and +242 ms
/// on the fixture), while its panel inserted "Runtime used" above its other rows. What the panel shows of it — the
/// files the task changed, its child agents, the runtimes and models it used — is worked out once for each page that
/// comes, not at each draw.
struct TaskActivity {
    /// The name the store keeps one task's reading under.
    static func name(_ task: Int) -> String { "task.activity.\(task)" }
    private(set) var timeline = ActivityTimeline()
    /// The newest event read: the next read asks only for what came after it.
    private(set) var cursor = 0
    /// The scripts that were on screen with one of their calls. They stay rows, so no row goes away while events arrive.
    private(set) var keptScripts: Set<Int> = []
    /// The rows of the thread's own level, so a reader who scrolled up keeps the earlier rows he reads.
    private(set) var topRows = 0
    private(set) var files: [FileChange] = []
    private(set) var children: [TaskChild] = []

    /// One page of events after `cursor`.
    mutating func append(_ page: RuntimePage) {
        if !page.events.isEmpty {
            keptScripts.formUnion(timeline.rows.openScriptsWithRows)
            timeline.append(page.events)
            topRows = timeline.rows.filter { $0.event.parent == nil }.shown(keeping: keptScripts).count
            files = timeline.changedFiles
            // A child by what it was asked (`StepWords.childTitle`), else by its kind ("general-purpose").
            children = timeline.rows.compactMap { row in
                guard let agent = row.subagent, let key = row.event.toolKey else { return nil }
                return TaskChild(id: key, name: StepWords.childTitle(row.event.title) ?? agent.name, status: row.status)
            }
        }
        cursor = page.next
    }
}

/// A task thread is what the agent **said**, in one order: its messages, the notes it reported, the owner's
/// guidance, a permission that stopped it, an error — and, where it worked, one row that says how many steps it
/// took. The steps themselves open from that row and are unchanged.
///
/// Three kinds of row left the thread (owner direction, 18 October 2026: "messages are so confusing… I dont like
/// showing so much"). A **Fleet tool call** (`fleet: report_progress`, `deliver_result`, `read_messages`, …) is
/// the agent operating Fleet, and Fleet already draws what it did — the note, the result, the question — so the
/// call was the same fact a second time. A **permission that was allowed** says only that work the thread already
/// shows was allowed to run; one that waits or was refused stays, because it stops the task. A **thought** is the
/// model talking to itself, so it goes in with the steps.
struct RuntimeActivity: View {
    /// What the thread read last: the task's view reads it (`TaskView`) and the store keeps it (`TaskActivity`).
    let activity: TaskActivity
    /// Why the last read failed, in the hub's words, or nil.
    let error: String?
    let task: Int
    let attempt: Int
    /// The attempt that a confirmed hold of this task ended, while that hold holds the task.
    var stoppedAttempt: Int? = nil
    let terminal: Bool
    let isFresh: Bool
    @Binding var followsLatest: Bool
    let steers: [TaskSteer]
    /// What the agent reported as it worked, in the thread at the time it wrote it.
    var notes: [ProgressNote] = []
    /// The permissions of this task. Only the ones that wait or were refused become rows.
    var permissions: [FleetPermission] = []
    @Binding var childRequest: RuntimeToolKey?
    /// The rows whose words can be selected (`ChatSelection`): the task's view keeps it, with its scroll view.
    let selection: ChatSelection
    /// When the task began: the time of the row over the thread's first, for its first stamp (`ChatStamp`).
    var startedAt: Double? = nil
    /// The reading of the server of the task's agent, and the hub's time: an error's row reads from them whether its
    /// provider is signed out there now (`RuntimeErrorLine`).
    var machine: MachineStatus? = nil
    var time: Double = 0
    /// The task's agent: one on a local model signs in nowhere, so its own provider is never "signed out".
    var agent: FleetAgent? = nil
    /// The usage limit that holds this task now, as the task's own mark says it, or nil: the row of that limit's
    /// record stays orange for that time (`ActivityTimeline.stands`).
    var limit: RuntimeLimit? = nil
    /// Opens the sign-in of a provider on that server, for "Sign in again" on an error's row; nil on a hub that has
    /// no sign-in, and then the row has its words alone.
    var signIn: ((String) -> Void)? = nil
    /// The store, which opens and saves the files of a guidance (`MessageFilesView`); nil shows none.
    var store: FleetStore? = nil
    @State private var visibleCount = 80
    @State private var childPath: [RuntimeToolKey] = []

    private var timeline: ActivityTimeline { activity.timeline }
    private var keptScripts: Set<Int> { activity.keptScripts }
    private var topRows: [ShownRow] { timeline.rows.filter { $0.event.parent == nil }.shown(keeping: keptScripts) }

    /// Everything that was said, in one order, with the work between two of them as one `steps` row.
    ///
    /// The work keeps the thread's own order, which is the only order the runtime guarantees, and each thing that
    /// was said takes its place in it by the time the hub stamped on it. So a note written in the middle of the
    /// work stands in the middle of the work, and the run it interrupted becomes two rows rather than one that
    /// quietly spans it. An event the runtime sent without a time is held at the time of the row before it, so an
    /// unstamped call can never jump to the front of the thread.
    private var entries: [ThreadEntry] {
        var said: [ThreadEntry] = steers.map(ThreadEntry.steer) + notes.map(ThreadEntry.note)
            + permissions.filter(\.needsReading).map(ThreadEntry.permission)
        said.sort { $0.time < $1.time }
        var composed: [ThreadEntry] = [], work: [ShownRow] = [], spoken = 0, clock = 0.0
        func flush() { if !work.isEmpty { composed.append(.steps(work)); work = [] } }
        func say(until moment: Double) {
            while spoken < said.count, said[spoken].time <= moment {
                flush()
                composed.append(said[spoken])
                spoken += 1
            }
        }
        for shown in topRows where !shown.row.isFleetTool && !StepWords.isToolSearch(shown.row.event.title) {
            clock = max(clock, shown.time)
            say(until: clock)
            if shown.row.isSpoken {
                flush()
                composed.append(.said(shown))
            } else {
                work.append(shown)
            }
        }
        flush()
        say(until: .infinity)
        return composed
    }
    var body: some View {
        Group {
            if let key = childPath.last { childThread(key) } else { thread }
        }
        .onChange(of: childRequest) { _, key in
            if let key, timeline.rows.contains(where: { $0.event.toolKey == key && $0.subagent != nil }) { openChild(key) }
            childRequest = nil
        }
        // Rows that come while he reads further up add to what shows, so the rows he reads stay where they are.
        .onChange(of: activity.topRows) { before, now in
            if !followsLatest, now > before { visibleCount += now - before }
        }
    }

    /// A child agent's thread, in place of the task's own thread. Back goes one level up.
    private func childThread(_ key: RuntimeToolKey) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Button { childPath.removeLast() } label: {
                    Label("Back", systemImage: "arrow.left").font(FormMetrics.text).foregroundStyle(FleetStyle.muted).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("child-thread-back")
                // The child by what it was asked, as its row in the thread and in the panel names it.
                let call = timeline.rows.first { $0.event.toolKey == key }
                Text(StepWords.childTitle(call?.event.title) ?? call?.subagent?.name ?? String(l10n: "Agent thread")).font(FormMetrics.heading).lineLimit(2)
                Spacer()
                Text("Attempt \(key.attempt)").font(ChatStyle.detail).foregroundStyle(FleetStyle.muted)
            }
            ChildActivity(rows: timeline.children(of: key), timeline: timeline, kept: keptScripts, ended: ended, open: openChild,
                          errorLine: errorLine, selection: selection).id(key)
        }
    }

    private var thread: some View {
        VStack(alignment: .leading, spacing: activitySpacing - activityFooter) {
            if let error { Label(error, systemImage: "exclamationmark.circle").font(ChatStyle.detail).foregroundStyle(.orange).padding(.bottom, activityFooter) }
            if !isFresh { Text("Offline · last activity").font(ChatStyle.detail).foregroundStyle(.orange).padding(.bottom, activityFooter) }
            let all = entries
            if all.count > visibleCount {
                Button("Earlier activity", systemImage: "arrow.up") { visibleCount += 80 }
                    .buttonStyle(.plain).foregroundStyle(FleetStyle.muted).font(ChatStyle.detail).padding(.bottom, activityFooter)
            }
            ForEach(Array(all.enumerated()).suffix(visibleCount), id: \.element.id) { index, entry in
                Group {
                // **The chat's stamps** (the owner's yes of 17 November 2026 to the pictures of the Task page): the
                // day and the time over a row that comes an hour or a day after the one before it.
                if let time = Self.stamp(all, at: index, startedAt: startedAt) { ChatStamp(time: time) }
                switch entry {
                case .said(let shown):
                    RuntimeRow(row: shown.row, script: shown.script, children: childRows(shown.row), ended: ended(shown.row), open: openChild,
                               errorLine: errorLine(shown.row), signIn: signIn)
                case .steps(let rows):
                    StepsRow(rows: rows, children: childRows, ended: ended, open: openChild).padding(.bottom, activityFooter)
                case .note(let note): AgentReply(text: note.text, time: note.ts, compact: true)
                case .permission(let permission):
                    FoldRow(title: permission.tool, symbol: "hand.raised",
                            status: permission.decision ?? String(l10n: "Waiting"), statusColor: .orange, chat: true) {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(permission.input).font(ChatStyle.code).selectableWords()
                                .fixedSize(horizontal: false, vertical: true)
                            if let reason = permission.reason { Text(reason).selectableWords() }
                        }
                    }.padding(.bottom, activityFooter)
                case .steer(let steer):
                    VStack(alignment: .trailing, spacing: 5) {
                        // an AI session's guidance in the outline, with its mark, as in his chat (`OwnerHand`)
                        OwnerBubble(text: steer.text, hand: steer.look(features: store?.state?.ui_features))
                        // Its files under its bubble, as a chat message's are (owner API 1.223).
                        if let store, let files = steer.attachments, !files.isEmpty {
                            MessageFilesView(store: store, files: files, plain: true)
                        }
                        Text("Guidance · Attempt \(steer.attempt) · \(steer.deliveryLabel(currentAttempt: attempt))")
                            .font(ChatStyle.detail).foregroundStyle(FleetStyle.muted).help(fleetDate(steer.read_at ?? steer.created))
                    }.padding(.bottom, activityFooter)
                }
                }
                // A long thread had a hidden text field for each text of every row (`ChatWordsSelection`).
                .wordsSelectable(in: selection, row: entry.id)
            }
            // The plan the agent wrote for itself is for watching work that runs, so it stands open under the latest
            // activity (the owner's yes of 4 November 2026 to its mockup). A finished task is read by its result, so
            // the plan goes rather than outliving the work it planned.
            if !terminal, !timeline.plan.isEmpty { LivePlan(entries: timeline.plan) }
        }
    }
    /// The time of the stamp over the entry at `index`, or nil: its own time when it comes an hour or a day after the end
    /// of the newest entry before it that has a time (a run of steps ends with its last step), or after the task began
    /// (`ChatStamp`'s rule). A row with no time has none, and stops none under it.
    private static func stamp(_ entries: [ThreadEntry], at index: Int, startedAt: Double?) -> Double? {
        let time = entries[index].time
        guard time > 0, let previous = entries[..<index].last(where: { $0.end > 0 })?.end ?? startedAt, previous > 0
        else { return nil }
        return ChatStamp.time(time, after: previous)
    }
    private func childRows(_ row: ActivityRow) -> [ActivityRow] { row.subagent == nil ? [] : row.event.toolKey.map { timeline.children(of: $0) } ?? [] }
    /// **What an error's row says, and whether it is orange** (`RuntimeErrorLine`; the owner's "Yes, build it" of 18 and
    /// of 19 November 2026): "is signed out", and orange, only on the error that the current attempt of a task that is
    /// still open stops at (`ActivityTimeline.stands`), because both are about now; the row of the usage limit that
    /// holds the task now (`limit`). An error of a child's thread says "reported an error", in grey.
    private func errorLine(_ row: ActivityRow) -> RuntimeErrorLine? {
        guard row.event.type == "error" else { return nil }
        return RuntimeErrorLine(error: row.event, runtimes: timeline.runtimes[row.event.attempt] ?? [], machine: machine,
                                standsLast: !terminal && timeline.stands(row, attempt: attempt, limit: limit, task: task),
                                time: time, own: agent?.runtime, localModel: agent?.local_model == true)
    }
    private func ended(_ row: ActivityRow) -> Bool { row.endedWithoutResult(current: attempt, stopped: stoppedAttempt) }
    private func openChild(_ key: RuntimeToolKey) { if !childPath.contains(key) { childPath.append(key) } }
}

/// One row of a task thread. `said` is one of the agent's own rows; `steps` is a run of work between two of them.
private enum ThreadEntry: Identifiable {
    case said(ShownRow), steps([ShownRow]), note(ProgressNote), permission(FleetPermission), steer(TaskSteer)
    var id: String {
        switch self {
        case .said(let row): "event-\(row.id)"
        case .steps(let rows): "steps-\(rows.first?.id ?? 0)"
        case .note(let note): "note-\(note.id)"
        case .permission(let value): "permission-\(value.id)"
        case .steer(let value): "steer-\(value.id)"
        }
    }
    var time: Double {
        switch self {
        case .said(let row): row.time
        case .steps(let rows): rows.first?.time ?? 0
        case .note(let note): note.ts
        case .permission(let value): value.created
        case .steer(let value): value.created
        }
    }
    /// When it ended: a run of steps with its last step, every other row when it came.
    var end: Double {
        if case .steps(let rows) = self { return rows.map(\.time).max() ?? 0 }
        return time
    }
}

extension FleetPermission {
    /// A permission the runtime allowed says only that work the thread already shows was allowed to run. One that
    /// waits holds the task up, and a refusal is why it stopped: those two are the thread's business.
    var needsReading: Bool { decision == nil || decision == "deny" }
}

private extension ActivityRow {
    /// What the agent said: its messages to the owner, an error, and the notice that the record was cut short.
    var isSpoken: Bool { ["agent_message", "error", "truncated"].contains(event.type) }

    /// Fleet's own tools, which are the agent working Fleet and not the owner's machines. Each one already has its
    /// row in the app, so the call is the same fact twice. The five that reach outside the fleet are not in that
    /// set — a sign-in, a login, a saved key, a handover and an API request are real actions and stay steps.
    var isFleetTool: Bool {
        guard let title = event.title, title.hasPrefix("fleet: ") else { return false }
        return !["sign_in", "hand_over", "create_login", "save_key", "call_api"].contains(String(title.dropFirst(7)))
    }
}

/// A row of a thread as it shows. Codex runs its tools from a script (`exec`): the hub records the script, and each
/// call that the script made. The calls are the rows. A script that completed takes the place of its first call: the
/// row shows the call, and gives the script and the script's own result on demand. `id` stays the script's, so the row
/// keeps its place and an open detail stays open.
private struct ShownRow: Identifiable {
    let id: Int
    let row: ActivityRow
    var script: ActivityRow?
    var time: Double { (script ?? row).event.ts ?? 0 }
}

private extension ActivityRow {
    var isScript: Bool { event.type == "tool_call" && event.title?.hasPrefix("exec:") == true }
    var scriptIsOpen: Bool { lastEventID == id || !["completed", "failed"].contains(status ?? "") }
    /// A call that the hub recorded at its end: a tool row that is no script and no agent.
    var isCall: Bool { event.type == "tool_call" && !isScript && subagent == nil && ["completed", "failed"].contains(event.status ?? "") }
    var thread: ActivityThread { .init(attempt: event.attempt, session: event.session, parent: event.parent) }
}
private struct ActivityThread: Hashable { let attempt: Int, session: String, parent: String? }

private extension Array where Element == ActivityRow {
    /// The rows of one thread list as they show, in the same order. A script folds only when the record is clear: it
    /// is completed with "Script completed", the hub recorded one row or more between its first event and its last
    /// update, each of those rows is a call, and no earlier script of its thread was open when it started. Each other
    /// script stays a row as before: failed, stopped, not ended, without a call, or open together with another
    /// script. So does a script in `kept`.
    func shown(keeping kept: Set<Int>) -> [ShownRow] {
        var places: [Int: ActivityRow] = [:], folded: Set<Int> = [], ends: [ActivityThread: Int] = [:]
        for (index, script) in enumerated() where script.isScript {
            let thread = script.thread, overlaps = ends[thread, default: 0] > script.id
            // A progress update does not end a script.
            ends[thread] = Swift.max(ends[thread, default: 0], script.scriptIsOpen ? .max : script.lastEventID)
            guard !overlaps, !kept.contains(script.id), script.status == "completed", script.output?.hasPrefix("Script completed") == true else { continue }
            // The rows are in the order of their event IDs, so the rows that the hub recorded during the script come
            // directly after it.
            let recorded = self[(index + 1)...].prefix { $0.id < script.lastEventID }.filter { $0.thread == thread }
            guard let first = recorded.first, recorded.allSatisfy(\.isCall) else { continue }
            places[script.id] = first; folded.insert(first.id)
        }
        return compactMap { row in
            folded.contains(row.id) ? nil : ShownRow(id: row.id, row: places[row.id] ?? row, script: places[row.id] == nil ? nil : row)
        }
    }
    /// The scripts that have not ended and already have a later row in their thread: the two are on screen now.
    var openScriptsWithRows: [Int] {
        enumerated().filter { index, script in
            script.isScript && script.scriptIsOpen && self[(index + 1)...].contains { $0.thread == script.thread }
        }.map(\.element.id)
    }
}

/// One run of work, as one row: "14 steps", with "1 running" while a step of it runs and "2 failed" in orange. The
/// steps themselves are the rows this app has always drawn, in the agent's own words (`StepWords`), and they open from
/// here. **What runs now is the thread's live line** (the owner's yes of 17 November 2026 to the pictures of the Task
/// page): this row named the running step by its call's title, a shell command of up to four lines.
private struct StepsRow: View {
    let rows: [ShownRow]
    let children: (ActivityRow) -> [ActivityRow]
    let ended: (ActivityRow) -> Bool
    let open: (RuntimeToolKey) -> Void

    /// The steps the runtime has not finished, in an attempt that is still running.
    private var running: Int {
        rows.map(\.row).filter { $0.event.type == "tool_call" && !["completed", "failed"].contains($0.status ?? "") && !ended($0) }.count
    }
    private var failures: Int { rows.filter { $0.row.status == "failed" }.count }
    private var title: String { rows.count == 1 ? String(l10n: "1 step") : String(l10n: "\(rows.count) steps") }
    /// "1 running" while a step runs, muted, as the running step's words were; else the failures, in orange. One word
    /// in one colour: "1 failed · 1 running" stood all in orange.
    private var status: String {
        if running > 0 { return String(l10n: "\(running) running") }
        return failures == 0 ? "" : failures == 1 ? String(l10n: "1 failed") : String(l10n: "\(failures) failed")
    }

    var body: some View {
        FoldRow(title: title, symbol: "list.bullet.indent",
                status: status, statusColor: running > 0 || failures == 0 ? FleetStyle.muted : .orange, chat: true) {
            VStack(alignment: .leading, spacing: activitySpacing - activityFooter) {
                ForEach(rows) { shown in
                    RuntimeRow(row: shown.row, script: shown.script, children: children(shown.row),
                               ended: ended(shown.row), open: open)
                }
            }
        }.accessibilityIdentifier("thread-steps-\(rows.first?.id ?? 0)")
    }
}

private struct ChildActivity: View {
    let rows: [ActivityRow]
    let timeline: ActivityTimeline
    let kept: Set<Int>
    let ended: (ActivityRow) -> Bool
    let open: (RuntimeToolKey) -> Void
    /// What an error's row says (`RuntimeActivity.errorLine`).
    let errorLine: (ActivityRow) -> RuntimeErrorLine?
    let selection: ChatSelection
    @State private var visibleCount = 80
    var body: some View {
        // A child's thread is already one level in: its steps stay a plain list, without Fleet's own calls and
        // without its searches for tools.
        let shown = rows.shown(keeping: kept).filter { !$0.row.isFleetTool && !StepWords.isToolSearch($0.row.event.title) }
        // The task view scrolls; this thread is part of it.
        VStack(alignment: .leading, spacing: activitySpacing - activityFooter) {
            if rows.isEmpty { Text("Waiting for agent activity.").foregroundStyle(FleetStyle.muted).padding(.bottom, activityFooter) }
            if shown.count > visibleCount { Button("Earlier activity") { visibleCount += 80 }.buttonStyle(.plain).padding(.bottom, activityFooter) }
            ForEach(shown.suffix(visibleCount)) { item in
                RuntimeRow(row: item.row, script: item.script, children: item.row.subagent == nil ? [] : item.row.event.toolKey.map { timeline.children(of: $0) } ?? [],
                           ended: ended(item.row), open: open, errorLine: errorLine(item.row))
                    .wordsSelectable(in: selection, row: "child-\(item.id)")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RuntimeRow: View {
    let row: ActivityRow
    /// The script whose place this call takes.
    var script: ActivityRow?
    let children: [ActivityRow]
    /// The call has no finish and its attempt is over (`endedWithoutResult`): it does not show as running.
    var ended = false
    let open: (RuntimeToolKey) -> Void
    /// What an error's row says (`RuntimeErrorLine`); nil for every other row.
    var errorLine: RuntimeErrorLine? = nil
    /// Opens the sign-in of a provider on the agent's server, for the row's "Sign in again".
    var signIn: ((String) -> Void)? = nil
    /// An agent message has its footer; every other shown row gets the same height below it.
    var body: some View {
        switch row.event.type {
        case "agent_message": AgentReply(text: row.event.text ?? "", time: row.event.ts, compact: true)
        case "agent_thought", "tool_call", "plan", "error", "truncated": content.padding(.bottom, activityFooter)
        default: EmptyView()
        }
    }
    @ViewBuilder private var content: some View {
        switch row.event.type {
        case "agent_thought":
            FoldRow(title: String(l10n: "Thinking"), symbol: "sparkle", chat: true) { Text(verbatim: row.event.text ?? "").selectableWords() }
        case "tool_call":
            // **A step in the agent's own words** (`StepWords`), a child by what it was asked; the call itself, a
            // command or a path, stands first inside it.
            let words = row.subagent.map { StepWords.childTitle(row.event.title) ?? $0.name }
                ?? StepWords.of(row.event, locations: row.locations) ?? toolTitle(row.event.title)
            FoldRow(title: words, symbol: row.subagent == nil ? toolSymbol(row.event.kind) : "person.crop.square", status: ended ? String(l10n: "Result unknown") : toolStatus(row.status), statusColor: row.status == "failed" ? .orange : FleetStyle.muted, chat: true) {
                VStack(alignment: .leading, spacing: 10) {
                    if row.subagent == nil, let title = row.event.title, words != title {
                        Text(verbatim: title).font(ChatStyle.code).selectableWords()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(row.locations.enumerated()), id: \.offset) { _, location in
                        Label { Text(verbatim: location.path).selectableWords() } icon: { Image(systemName: "doc.text") }
                            .font(ChatStyle.detail).foregroundStyle(FleetStyle.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    if row.output != nil || row.subagent == nil {
                        Text(verbatim: row.output ?? "No output reported.").font(ChatStyle.code).selectableWords()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let script {
                        // The script that made this call: its line, and its own result on demand.
                        Text(verbatim: script.event.title ?? "exec").font(ChatStyle.code).foregroundStyle(FleetStyle.muted)
                            .selectableWords().fixedSize(horizontal: false, vertical: true)
                        FoldRow(title: String(l10n: "Script result"), symbol: "terminal") {
                            Text(verbatim: script.output ?? "No output reported.").font(ChatStyle.code).selectableWords()
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if row.subagent != nil, let key = row.event.toolKey {
                        VStack(alignment: .leading, spacing: 8) {
                            // Its newest three rows in the thread's own words: no Fleet call and no search for tools,
                            // and a step by the agent's line for it (`StepWords`), as the child's own thread draws them.
                            ForEach(children.filter { !$0.isFleetTool && !StepWords.isToolSearch($0.event.title) }.suffix(3)) { child in
                                Text(StepWords.of(child.event, locations: child.locations) ?? child.event.title ?? child.event.text
                                     ?? child.event.message ?? String(l10n: "Activity"))
                                    .font(ChatStyle.detail).lineLimit(2).foregroundStyle(FleetStyle.muted)
                            }
                            Button("Open agent thread", systemImage: "arrow.up.right") { open(key) }.buttonStyle(.plain).font(ChatStyle.detail)
                        }.padding(.leading, 12).overlay(alignment: .leading) { Rectangle().fill(FleetStyle.line).frame(width: 1) }
                    }
                }
            }.id(script?.id ?? row.id)
        case "plan": RuntimePlan(entries: row.event.entries ?? [])
        case "error":
            // **Plain words, the provider's own under the pointer, and the one thing that he can do** (`RuntimeErrorLine`;
            // the owner, 18 November 2026, of "workspace routing discovery unauthorized (401)" here: "I dont know what
            // it means or what I can do about it"). Orange only while the thread stops at it; grey once it is a record
            // (his words of 19 November 2026: "that task still shows an orange error label, probably not updated").
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(errorLine?.says ?? row.event.message ?? String(l10n: "Runtime error"), systemImage: "exclamationmark.circle")
                    .foregroundStyle(errorLine?.stands == false ? FleetStyle.muted : .orange).help(errorLine?.raw ?? "")
                if let runtime = errorLine?.signIn, let signIn {
                    Button("Sign in again") { signIn(runtime) }.buttonStyle(.plain).foregroundStyle(FleetStyle.link)
                        .accessibilityIdentifier("task-sign-in-again")
                }
            }
        default: Text("The worker reached its activity record limit.").font(ChatStyle.detail).foregroundStyle(FleetStyle.muted)
        }
    }
}

private func toolTitle(_ title: String?) -> String {
    guard let title else { return String(l10n: "Tool") }
    if title.hasPrefix("exec:") { return String(l10n: "Run tools") }
    if title.hasPrefix("fleet: ") { return String(title.dropFirst(7)).replacingOccurrences(of: "_", with: " ").capitalized }
    return title
}
private func toolSymbol(_ kind: String?) -> String {
    switch kind {
    case "read": "doc.text"
    case "search": "magnifyingglass"
    case "edit", "move", "delete": "pencil"
    case "execute": "terminal"
    case "fetch": "globe"
    default: "square.stack.3d.up"
    }
}
private func toolStatus(_ status: String?) -> String {
    switch status { case "completed": String(l10n: "Done"); case "failed": String(l10n: "Failed"); case "in_progress": String(l10n: "Running"); default: String(l10n: "Waiting") }
}

/// A plan as a row of a subagent's thread: one of the plans it wrote, folded.
private struct RuntimePlan: View {
    let entries: [RuntimeEvent.PlanEntry]
    var body: some View {
        FoldRow(title: String(l10n: "Plan"), symbol: "checklist", chat: true) { PlanSteps(entries: entries) }
    }
}

/// The plan of the work that runs, open: the box of an open fold (`FoldRow`) with no fold over it.
private struct LivePlan: View {
    let entries: [RuntimeEvent.PlanEntry]
    var body: some View {
        PlanSteps(entries: entries).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(FleetStyle.surface, in: RoundedRectangle(cornerRadius: FormMetrics.inner))
    }
}

private struct PlanSteps: View {
    let entries: [RuntimeEvent.PlanEntry]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                Label(entry.content, systemImage: entry.status == "completed" ? "checkmark.circle" : entry.status == "in_progress" ? "circle.dotted" : "circle")
                    .foregroundStyle(entry.status == "completed" ? FleetStyle.muted : FleetStyle.text)
            }
        }
    }
}

/// A task's guidance, under its thread. **It is the chat's composer** (one kind, one look: the capsule of one line at
/// rest that grows upward, `ComposerCapsule`), up to five lines. **Its plus sends files with the guidance** (owner API
/// 1.223; the owner's "Yes, build it" of 19 November 2026 to the pictures): the chat's plus, its chips over the line,
/// and a file dropped on the task's thread or a picture pasted with Cmd+V, all where its composer takes files
/// (`FleetStore.guidanceComposer`). Send needs words too: the hub keeps a guidance's words as its record. **A key in it
/// waits for his choice, as in the chat's composer** (`KeyHoldBanner`): one that he pastes is not pasted, and one that he
/// types holds Send, until he saves it as a secret or keeps it. Until 22 November 2026 it sent such words to the agent
/// with no question (a reader of the Windows app's key hold found it).
struct TaskSteering: View {
    @Bindable var store: FleetStore
    let task: FleetTask
    /// The box's key in the store, for its words (`guidanceDrafts`) and its files.
    private var key: String { FleetStore.stageKey(task: task.id, database: store.state?.db ?? "") }
    /// Its words: the store's draft, which `finish` empties when the hub confirms this guidance, also at a later read.
    private var text: String {
        get { store.guidanceDrafts[key] ?? "" }
        nonmutating set { store.guidanceDrafts[key] = newValue.isEmpty ? nil : newValue }
    }
    /// The box's whole capsule gives its field the cursor (`ComposerCapsule`).
    @FocusState private var focused: Bool
    /// He chose "Keep it" or "Paste it anyway" for the key in these words: no second question while it is in them.
    @State private var keyAllowed = false
    private var allowed: Bool { Self.shows(task, in: store.state) }
    /// The agent that gave the task, which gets a copy of each guidance; nil for one that is no agent of the fleet.
    private var copyReader: String? {
        task.requester != task.owner && store.state?.agents.contains { $0.name == task.requester } == true ? task.requester : nil
    }
    /// The box shows: the task is in a working state and no hold of the owner's holds it.
    static func shows(_ task: FleetTask, in state: HubState?) -> Bool {
        ["submitted", "working", "input-required", "auth-required"].contains(task.state) &&
        state?.holds?.contains { $0.task == task.id && $0.state != "released" } != true
    }
    var body: some View {
        // **No box while it cannot send** (T-12, fix round): a paused or stopped task, or one in no working state,
        // showed the box with "Resume the task to send guidance" in it — an instruction in a field that took nothing.
        // Its controls over it say Paused, with Resume where he can.
        if allowed { box }
    }

    private var box: some View {
        let composer = store.guidanceComposer(for: task)
        // the box's key, taken now: a hub that changes under it must not change the key that its close clears
        let key = self.key
        // A file that its rule takes no more (the agent's Shell box went off after he picked it) holds Send, with the
        // rule's words, until he takes it out with its x.
        let refusal = composer.flatMap(store.refusedFileWords)
        // The chat's Send: only while it can send (`SendSlot`), in the violet of what he presses (D-8), and not while
        // a file of it still goes up.
        let canSend = store.canWrite && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= 4000
            && composer.map { !store.filesAreWaiting(for: $0) } != false && refusal == nil
        let words = Binding(get: { text }, set: { text = $0 })
        return ComposerCapsule(focus: $focused) {
            // The files that wait, and what is wrong with one, over the line, as in the chat's composer.
            if let composer {
                StagedFilesStrip(store: store, composer: composer)
                if let line = refusal ?? store.fileError(for: composer) {
                    Text(line).font(ChatStyle.detail).foregroundStyle(.orange).help(store.fileCause(for: composer) ?? "")
                }
            }
            if let held = store.heldKey, held.composer == key {
                // the agent that gave the task gets a copy of each guidance (the hub's steer), so the question names it
                KeyHoldBanner(hold: held.hold, agent: task.owner, copyTo: copyReader) { saveHeldKey(held, words: words) } goOn: {
                    keepHeldKey(held, words: words)
                }
            }
        } line: {
            if let composer { AttachFilesButton(store: store, composer: composer) }
            TextField("Guide this task…", text: words, axis: .vertical)
                .focused($focused)
                .accessibilityIdentifier("task-guidance")
                // The same keys as the chat composer: Return sends, Shift+Return makes a new line.
                .onKeyPress(keys: [.return], phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    guard canSend else { return .handled }
                    send()
                    return .handled
                }
                .composerField(alone: composer == nil, lines: 1...5)
                .onChange(of: text) { _, now in heldKeyCheck(now) }
            SendSlot(shows: canSend) {
                Button { send() } label: { SendMark() }
                    .buttonStyle(FleetIconButtonStyle(filled: true)).help("Send this guidance to the task")
                    .accessibilityLabel("Send task guidance").keyboardShortcut(.return, modifiers: .command)
                    .accessibilityIdentifier("task-guidance-send")
                    .disabled(!canSend)
            }
        }
        .pasteAttachments(store: store, composer: focused ? composer : nil)
        .keyPasteGuard(store: store, composer: focused && SecretEntryView.isOffered(by: store) ? key : nil)
        .stageDroppedFiles(store: store, composer: composer)
        .chatColumn().padding(.top, 10).padding(.bottom, FleetSpace.under)
        .onChange(of: store.secretRefusals) { _, _ in text = "" }
        .onChange(of: key) { _, _ in keyAllowed = false }
        // The question of a key goes with the box, so no other box waits behind it.
        .onDisappear { if store.heldKey?.composer == key { store.heldKey = nil } }
    }

    /// The hub's confirmation empties the box (`finish`); a file that went up an hour ago goes up again first, because
    /// the hub may have let it go and given its number to another file (`freshFiles`).
    private func send() {
        if SecretEntryView.isOffered(by: store) && !keyAllowed && KeyInText.contains(text) {
            store.heldKey = HeldKey(composer: key, hold: .text)
            return
        }
        let sent = text, composer = store.guidanceComposer(for: task)
        Task {
            var files: [Int] = []
            if let composer {
                guard let fresh = await store.freshFiles(for: composer) else { return }
                files = fresh
            }
            await store.command(.steer(task: task.id, attempt: task.attempt), note: sent, attachments: files)
        }
    }

    /// Words that hold a key, however they came in, get the question once; words without one end it.
    private func heldKeyCheck(_ now: String) {
        guard SecretEntryView.isOffered(by: store) else { return }
        if !KeyInText.contains(now) {
            keyAllowed = false
            if store.heldKey == HeldKey(composer: key, hold: .text) { store.heldKey = nil }
        } else if !keyAllowed && store.heldKey == nil {
            store.heldKey = HeldKey(composer: key, hold: .text)
        }
    }

    /// "Save it as a secret": the key goes into the secure form over the page and out of his words, and the task's agent
    /// gets the secret's name in its chat where he has one. A paste reads the clipboard again now.
    private func saveHeldKey(_ held: HeldKey, words: Binding<String>) {
        store.heldKey = nil
        var cut: String?
        if held.hold == .paste { cut = KeyCut.onClipboard() }
        else if let split = KeyCut.split(words.wrappedValue) { words.wrappedValue = split.rest; cut = split.key }
        // told only where he has a chat with the agent, as a request's card does: a tell that cannot go held the form open
        store.secretForm = SecretPreset(tell: store.canChat(with: task.owner) ? task.owner : nil, key: cut,
                                        kept: SecretValueKept())
    }

    /// "Paste it anyway" or "Keep it": his choice, and no second question while the key is in his words.
    private func keepHeldKey(_ held: HeldKey, words: Binding<String>) {
        store.heldKey = nil
        keyAllowed = true
        if held.hold == .paste, let pasted = NSPasteboard.general.string(forType: .string) { words.wrappedValue += pasted }
    }
}

/// **Pause, Stop and Resume of a task, at the end of its state row in the task's panel** (`TaskPanel`; the owner's
/// "Yes, build it" of 17 November 2026 to the pictures of the Task page): they stood on a line of their own over the
/// guidance box, with the state word that the panel says too. Under the thread there is now only the box, as a chat
/// has only its composer. Each control is the one it was: the same holds decide which shows.
struct TaskHoldControls: View {
    @Bindable var store: FleetStore
    let task: FleetTask
    private var hold: TaskHold? { store.state?.holds?.first { $0.task == task.id && $0.state != "released" } }
    private var unknown: Bool { store.state?.outcomes?.contains { $0.task == task.id && $0.state == "unknown" } == true }

    /// Whether the row has a control: a task that is not over, on a hub that takes controls.
    static func shows(_ task: FleetTask, in state: HubState?) -> Bool {
        !task.isTerminal && state?.ui_features?.contains("task_controls") == true
    }

    var body: some View {
        HStack(spacing: 4) {
            if let hold {
                if hold.state == "stopped" {
                    let goal = store.state?.goals?.first(where: { $0.id == task.goal_id })
                    if let goal, goal.state == "paused" {
                        // **Its goal is paused: the button resumes the goal, which resumes its tasks** (11
                        // November 2026, when the Goals page went: "Goal controls" led there). The hub refuses
                        // a resume of the task alone ("Resume the goal, not the task.").
                        Button("Resume goal", systemImage: "play") {
                            Task { await store.command(.goalState(id: goal.id, revision: goal.revision, action: .resume)) }
                        }.buttonStyle(FleetOutlineButtonStyle()).help("Its goal is paused. This resumes the goal and its tasks.")
                    } else if goal == nil || goal?.state == "active" {
                        // **No Resume on a task whose goal is done or dropped** (review of 11 November 2026):
                        // the hub refuses it ("Reopen the goal to work on it again."), and the Fleet Manager
                        // cancels such a task.
                        // One word (fix round 2): "Check and resume" when a result is not known, which the
                        // hub checks before the task goes on.
                        Button("Resume", systemImage: "play") {
                            send(unknown ? .resume_check : .resume)
                        }.buttonStyle(FleetOutlineButtonStyle()).accessibilityIdentifier("task-resume")
                    }
                }
                // The owner's Stop takes over the stop of a requester's restart, so the hub starts no new session.
                if hold.state == "not_confirmed" || hold.kind == "pause" || hold.isAgentStop { controlButton(String(l10n: "Stop"), symbol: "stop", action: .stop) }
            } else {
                controlButton(String(l10n: "Pause"), symbol: "pause", action: .pause)
                controlButton(String(l10n: "Stop"), symbol: "stop", action: .stop)
            }
        }.font(FormMetrics.detail).disabled(!store.canWrite)
    }
    private func send(_ action: ControlAction) { Task { await store.command(.control(task: task.id, action: action)) } }
    private func controlButton(_ title: String, symbol: String, action: ControlAction) -> some View {
        IconButton(symbol: symbol, words: title, tint: FleetStyle.text) { send(action) }
            .accessibilityIdentifier("task-\(action.rawValue)")
    }
}

/// **A result that nobody knows, checked under the thread**: the one form a task thread holds, as a request's card is
/// a form in a chat (UI-PATTERNS, "A conversation also takes no card"). The list of the actions whose outcome is not
/// known, then the check of one of them in its place; the task's Pause and Stop are in its panel (`TaskHoldControls`).
struct TaskOutcomeCheck: View {
    @Bindable var store: FleetStore
    let task: FleetTask
    @State private var resolving: TaskOutcome?
    @State private var finding: OutcomeFinding?
    @State private var note = ""
    /// He chose "Keep it" or "Paste it anyway" for the key in the note: no second question while it is in it.
    @State private var keyAllowed = false
    @FocusState private var noteFocused: Bool
    /// The rows that the owner checks, each by its own rule (`HubState.ownerOutcomes`): a row whose check is with an
    /// agent stays out of his form, also beside one that is his.
    private var unknown: [TaskOutcome] { store.state?.ownerOutcomes.filter { $0.task == task.id } ?? [] }
    /// The note's key for the guard of a key: the task's agent reads the note when the task runs again (the hub's
    /// outcome lines), so a key in it waits for his choice, as in the chat's composer (`KeyHoldBanner`).
    private func noteKey(_ outcome: TaskOutcome) -> String { "outcome:\(store.state?.db ?? ""):\(outcome.id)" }

    var body: some View {
        if let outcome = resolving, unknown.contains(where: { $0.id == outcome.id }) {
            form(outcome).preference(key: OutcomeFormOpen.self, value: true)
        } else if !unknown.isEmpty {
            list
        }
    }

    /// The check of one result, in place of the list; no sheet. Its Cancel takes Esc, and the card around it gives
    /// Esc to it alone while it is open (`OutcomeFormOpen`).
    private func form(_ outcome: TaskOutcome) -> some View {
        // one key for the form, taken now: a hub that changes under it (its database gone) must not change the key
        // that its close clears
        let heldID = noteKey(outcome)
        return Group {
            FormSection("Check the result", detail: String(l10n: "Confirm what happened before the task repeats an action.")) {
                FormRow(outcome.title) {
                    FleetSelect("Result", selection: $finding, options: [
                        FleetOption(.done, "Completed", mark: .symbol("checkmark.circle")),
                        FleetOption(.not_done, "Did not happen", mark: .symbol("xmark.circle")),
                    ], placeholder: String(l10n: "Choose a result")).accessibilityIdentifier("outcome-result")
                }
                FormBlock("How you checked", detail: String(l10n: "Optional.")) {
                    if let held = store.heldKey, held.composer == heldID {
                        KeyHoldBanner(hold: held.hold, agent: task.owner) { saveHeldKey(held) } goOn: { keepHeldKey(held) }
                    }
                    // The one field look (`.fleetField`, T-30), where the stock bezel stood; its placeholder the muted
                    // words, with or without the cursor (`fieldPlaceholder`; fix round 3, item 55).
                    TextField(text: $note, prompt: Text(verbatim: "")) { Text("How you checked") }
                        .fieldPlaceholder(String(l10n: "How you checked"), shows: note.isEmpty).fleetField(focus: $noteFocused)
                        .accessibilityIdentifier("outcome-note")
                        .onChange(of: note) { _, now in heldKeyCheck(now, outcome) }
                }
                FormRow("", warning: store.pending != nil ? String(l10n: "A saved request waits. Check it below.") : nil) {
                    HStack(spacing: 8) {
                        Button("Cancel") { resolving = nil }.buttonStyle(FleetOutlineButtonStyle()).keyboardShortcut(.cancelAction)
                        Button("Save finding") {
                            guard let finding else { return }
                            if SecretEntryView.isOffered(by: store) && !keyAllowed && KeyInText.contains(note) {
                                store.heldKey = HeldKey(composer: heldID, hold: .text)
                                return
                            }
                            Task { await store.command(.outcome(id: outcome.id, finding: finding), note: note); if store.pending == nil { resolving = nil } }
                        }.buttonStyle(FleetPrimaryButtonStyle()).disabled(finding == nil || !store.canWrite || note.count > 2000)
                            .accessibilityIdentifier("outcome-save")
                    }
                }
            }
        }
        .keyPasteGuard(store: store, composer: noteFocused && SecretEntryView.isOffered(by: store) ? heldID : nil)
        // The question of a key goes with the form, so no other box waits behind it.
        .onDisappear { if store.heldKey?.composer == heldID { store.heldKey = nil } }
    }

    /// A note that holds a key, however it came in, gets the question once; one without a key ends it.
    private func heldKeyCheck(_ now: String, _ outcome: TaskOutcome) {
        guard SecretEntryView.isOffered(by: store) else { return }
        let mine = HeldKey(composer: noteKey(outcome), hold: .text)
        if !KeyInText.contains(now) {
            keyAllowed = false
            if store.heldKey == mine { store.heldKey = nil }
        } else if !keyAllowed && store.heldKey == nil {
            store.heldKey = mine
        }
    }

    /// "Save it as a secret": the key goes into the secure form over the page and out of the note, and the task's agent
    /// gets the secret's name in its chat where he has one. A paste reads the clipboard again now.
    private func saveHeldKey(_ held: HeldKey) {
        store.heldKey = nil
        var cut: String?
        if held.hold == .paste { cut = KeyCut.onClipboard() }
        else if let split = KeyCut.split(note) { note = split.rest; cut = split.key }
        store.secretForm = SecretPreset(tell: store.canChat(with: task.owner) ? task.owner : nil, key: cut,
                                        kept: SecretValueKept())
    }

    /// "Paste it anyway" or "Keep it": his choice, and no second question while the key is in the note.
    private func keepHeldKey(_ held: HeldKey) {
        store.heldKey = nil
        keyAllowed = true
        if held.hold == .paste, let pasted = NSPasteboard.general.string(forType: .string) { note += pasted }
    }

    /// The actions whose outcome is not known, each a row that opens its check.
    private var list: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Check before repeating", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
            ForEach(unknown) { outcome in
                // The row clicks in 26 points and more, over and under its words (`IconMetrics.reach`, T-21):
                // its line of 14 points was all that took the click. The card keeps its rhythm.
                Button { finding = nil; note = ""; keyAllowed = false; resolving = outcome } label: {
                    HStack { Text(outcome.title).lineLimit(2); Spacer(); Image(systemName: "chevron.right").font(IconMetrics.symbol(9)) }
                        .padding(.vertical, IconMetrics.reach).contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.vertical, -IconMetrics.reach).disabled(!store.canWrite)
                    .accessibilityIdentifier("outcome-\(outcome.id)")
            }
        }.font(FormMetrics.detail).padding(12).background(FleetStyle.surface, in: RoundedRectangle(cornerRadius: FormMetrics.inner))
    }
}

/// **The check of a result has its form open** (`TaskOutcomeCheck`): the card around it gives Esc to the form's Cancel
/// alone (`TaskDetail`), so one Esc ends the check and never drops it with the card's level.
struct OutcomeFormOpen: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
