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
            children = timeline.rows.compactMap { row in
                guard let agent = row.subagent, let key = row.event.toolKey else { return nil }
                return TaskChild(id: key, name: agent.name, status: row.status)
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
        for shown in topRows where !shown.row.isFleetTool {
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
                Text(timeline.rows.first { $0.event.toolKey == key }?.subagent?.name ?? "Agent thread").font(FormMetrics.heading).lineLimit(2)
                Spacer()
                Text("Attempt \(key.attempt)").font(ChatStyle.detail).foregroundStyle(FleetStyle.muted)
            }
            ChildActivity(rows: timeline.children(of: key), timeline: timeline, kept: keptScripts, ended: ended, open: openChild).id(key)
        }
    }

    private var thread: some View {
        VStack(alignment: .leading, spacing: activitySpacing - activityFooter) {
            if let error { Label(error, systemImage: "exclamationmark.circle").font(ChatStyle.detail).foregroundStyle(.orange).padding(.bottom, activityFooter) }
            if !isFresh { Text("Offline · last activity").font(ChatStyle.detail).foregroundStyle(.orange).padding(.bottom, activityFooter) }
            if entries.count > visibleCount {
                Button("Earlier activity", systemImage: "arrow.up") { visibleCount += 80 }
                    .buttonStyle(.plain).foregroundStyle(FleetStyle.muted).font(ChatStyle.detail).padding(.bottom, activityFooter)
            }
            ForEach(entries.suffix(visibleCount)) { entry in
                switch entry {
                case .said(let shown): RuntimeRow(row: shown.row, script: shown.script, children: childRows(shown.row), ended: ended(shown.row), open: openChild)
                case .steps(let rows):
                    StepsRow(rows: rows, children: childRows, ended: ended, open: openChild).padding(.bottom, activityFooter)
                case .note(let note): AgentReply(text: note.text, time: note.ts, compact: true)
                case .permission(let permission):
                    FoldRow(title: permission.tool, symbol: "hand.raised",
                            status: permission.decision ?? "Waiting", statusColor: .orange, chat: true) {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(permission.input).font(ChatStyle.code).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            if let reason = permission.reason { Text(reason).textSelection(.enabled) }
                        }
                    }.padding(.bottom, activityFooter)
                case .steer(let steer):
                    VStack(alignment: .trailing, spacing: 5) {
                        OwnerBubble(text: steer.text)
                        Text("Guidance · Attempt \(steer.attempt) · \(steer.deliveryLabel(currentAttempt: attempt))")
                            .font(ChatStyle.detail).foregroundStyle(FleetStyle.muted).help(fleetDate(steer.read_at ?? steer.created))
                    }.padding(.bottom, activityFooter)
                }
            }
            // The plan the agent wrote for itself is for watching work that runs, so it stands open under the latest
            // activity (the owner's yes of 4 November 2026 to its mockup). A finished task is read by its result, so
            // the plan goes rather than outliving the work it planned.
            if !terminal, !timeline.plan.isEmpty { LivePlan(entries: timeline.plan) }
        }
    }
    private func childRows(_ row: ActivityRow) -> [ActivityRow] { row.subagent == nil ? [] : row.event.toolKey.map { timeline.children(of: $0) } ?? [] }
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

/// One run of work, as one row: "14 steps", or the step that runs now while it runs. The steps themselves are the
/// rows this app has always drawn, and they open from here.
private struct StepsRow: View {
    let rows: [ShownRow]
    let children: (ActivityRow) -> [ActivityRow]
    let ended: (ActivityRow) -> Bool
    let open: (RuntimeToolKey) -> Void

    /// The step the runtime has not finished, in an attempt that is still running.
    private var running: ActivityRow? {
        rows.map(\.row).last { $0.event.type == "tool_call" && !["completed", "failed"].contains($0.status ?? "") && !ended($0) }
    }
    private var failures: Int { rows.filter { $0.row.status == "failed" }.count }
    private var title: String {
        if let running { return toolTitle(running.event.title) }
        return rows.count == 1 ? "1 step" : "\(rows.count) steps"
    }
    private var status: String {
        if running != nil { return rows.count == 1 ? "Running" : "Step \(rows.count) · Running" }
        return failures == 0 ? "" : failures == 1 ? "1 failed" : "\(failures) failed"
    }

    var body: some View {
        FoldRow(title: title, symbol: running.map { toolSymbol($0.event.kind) } ?? "list.bullet.indent",
                status: status, statusColor: failures == 0 ? FleetStyle.muted : .orange, chat: true) {
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
    @State private var visibleCount = 80
    var body: some View {
        // A child's thread is already one level in: its steps stay a plain list, without Fleet's own calls.
        let shown = rows.shown(keeping: kept).filter { !$0.row.isFleetTool }
        // The task view scrolls; this thread is part of it.
        VStack(alignment: .leading, spacing: activitySpacing - activityFooter) {
            if rows.isEmpty { Text("Waiting for agent activity.").foregroundStyle(FleetStyle.muted).padding(.bottom, activityFooter) }
            if shown.count > visibleCount { Button("Earlier activity") { visibleCount += 80 }.buttonStyle(.plain).padding(.bottom, activityFooter) }
            ForEach(shown.suffix(visibleCount)) { item in
                RuntimeRow(row: item.row, script: item.script, children: item.row.subagent == nil ? [] : item.row.event.toolKey.map { timeline.children(of: $0) } ?? [],
                           ended: ended(item.row), open: open)
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
            FoldRow(title: "Thinking", symbol: "sparkle", chat: true) { Text(verbatim: row.event.text ?? "").textSelection(.enabled) }
        case "tool_call":
            FoldRow(title: row.subagent?.name ?? toolTitle(row.event.title), symbol: row.subagent == nil ? toolSymbol(row.event.kind) : "person.crop.square", status: ended ? "Result unknown" : toolStatus(row.status), statusColor: row.status == "failed" ? .orange : FleetStyle.muted, chat: true) {
                VStack(alignment: .leading, spacing: 10) {
                    if let title = row.event.title, toolTitle(title) != title {
                        Text(verbatim: title).font(ChatStyle.code).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(row.locations.enumerated()), id: \.offset) { _, location in
                        Label { Text(verbatim: location.path).textSelection(.enabled) } icon: { Image(systemName: "doc.text") }
                            .font(ChatStyle.detail).foregroundStyle(FleetStyle.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    if row.output != nil || row.subagent == nil {
                        Text(verbatim: row.output ?? "No output reported.").font(ChatStyle.code).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let script {
                        // The script that made this call: its line, and its own result on demand.
                        Text(verbatim: script.event.title ?? "exec").font(ChatStyle.code).foregroundStyle(FleetStyle.muted)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        FoldRow(title: "Script result", symbol: "terminal") {
                            Text(verbatim: script.output ?? "No output reported.").font(ChatStyle.code).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if row.subagent != nil, let key = row.event.toolKey {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(children.suffix(3)) { child in
                                Text(child.event.title ?? child.event.text ?? child.event.message ?? "Activity")
                                    .font(ChatStyle.detail).lineLimit(2).foregroundStyle(FleetStyle.muted)
                            }
                            Button("Open agent thread", systemImage: "arrow.up.right") { open(key) }.buttonStyle(.plain).font(ChatStyle.detail)
                        }.padding(.leading, 12).overlay(alignment: .leading) { Rectangle().fill(FleetStyle.line).frame(width: 1) }
                    }
                }
            }.id(script?.id ?? row.id)
        case "plan": RuntimePlan(entries: row.event.entries ?? [])
        case "error": Label(row.event.message ?? "Runtime error", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
        default: Text("The worker reached its activity record limit.").font(ChatStyle.detail).foregroundStyle(FleetStyle.muted)
        }
    }
}

private func toolTitle(_ title: String?) -> String {
    guard let title else { return "Tool" }
    if title.hasPrefix("exec:") { return "Run tools" }
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
    switch status { case "completed": "Done"; case "failed": "Failed"; case "in_progress": "Running"; default: "Waiting" }
}

/// A plan as a row of a subagent's thread: one of the plans it wrote, folded.
private struct RuntimePlan: View {
    let entries: [RuntimeEvent.PlanEntry]
    var body: some View {
        FoldRow(title: "Plan", symbol: "checklist", chat: true) { PlanSteps(entries: entries) }
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
/// rest that grows upward, `ComposerCapsule`), with no plus, because its route carries text only, and up to five lines.
struct TaskSteering: View {
    @Bindable var store: FleetStore
    let task: FleetTask
    @State private var text = ""
    /// The box's whole capsule gives its field the cursor (`ComposerCapsule`).
    @FocusState private var focused: Bool
    private var allowed: Bool { Self.shows(task, in: store.state) }
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
        // The chat's Send: only while it can send (`SendSlot`), in the violet of what he presses (D-8).
        let canSend = store.canWrite && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= 4000
        return ComposerCapsule(focus: $focused) {
            TextField("Guide this task…", text: $text, axis: .vertical)
                .focused($focused)
                .accessibilityIdentifier("task-guidance")
                // The same keys as the chat composer: Return sends, Shift+Return makes a new line.
                .onKeyPress(keys: [.return], phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    guard canSend else { return .handled }
                    send()
                    return .handled
                }
                .composerField(alone: true, lines: 1...5)
            SendSlot(shows: canSend) {
                Button { send() } label: { SendMark() }
                    .buttonStyle(FleetIconButtonStyle(filled: true)).help("Send this guidance to the task")
                    .accessibilityLabel("Send task guidance").keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSend)
            }
        }
        .chatColumn().padding(.top, 10).padding(.bottom, FleetSpace.under)
        .onChange(of: store.secretRefusals) { _, _ in text = "" }
    }

    private func send() {
        let sent = text
        Task { if await store.command(.steer(task: task.id, attempt: task.attempt), note: sent), text == sent { text = "" } }
    }
}

struct TaskControls: View {
    @Bindable var store: FleetStore
    let task: FleetTask
    @State private var resolving: TaskOutcome?
    @State private var finding: OutcomeFinding?
    @State private var note = ""
    private var hold: TaskHold? { store.state?.holds?.first { $0.task == task.id && $0.state != "released" } }
    private var unknown: [TaskOutcome] { store.state?.outcomes?.filter { $0.task == task.id && $0.state == "unknown" } ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !task.isTerminal {
                HStack(spacing: 12) {
                    if let hold {
                        // The hold's word is the task's one state word (`TaskWords`, review B5), not a copy of it.
                        Label(task.stateWord(in: store.state),
                              systemImage: hold.state == "not_confirmed" ? "exclamationmark.circle" : "pause.circle")
                            .foregroundStyle(hold.state == "not_confirmed" ? .orange : FleetStyle.muted)
                        Spacer()
                        if hold.state == "stopped" {
                            if let goalID = task.goal_id, store.state?.goals?.first(where: { $0.id == goalID })?.state != "active" {
                                Button("Goal controls") { store.destination = .goals }
                                    .buttonStyle(FleetOutlineButtonStyle()).help("Resume its goal before its task.")
                            } else {
                                // One word (fix round 2): "Check and resume" when a result is not known, which the
                                // hub checks before the task goes on.
                                Button("Resume", systemImage: "play") {
                                    send(unknown.isEmpty ? .resume : .resume_check)
                                }.buttonStyle(FleetOutlineButtonStyle())
                            }
                        }
                        // The owner's Stop takes over the stop of a requester's restart, so the hub starts no new session.
                        if hold.state == "not_confirmed" || hold.kind == "pause" || hold.isAgentStop { controlButton("Stop", symbol: "stop", action: .stop) }
                    } else {
                        // The panel's word for the task (`stateWord`): "Usage limit" while its agent's usage limit holds it.
                        Text(task.stateWord(in: store.state)).foregroundStyle(FleetStyle.muted)
                        Spacer()
                        controlButton("Pause", symbol: "pause", action: .pause)
                        controlButton("Stop", symbol: "stop", action: .stop)
                    }
                }.font(FormMetrics.detail).disabled(!store.canWrite)
            }
            if let outcome = resolving, unknown.contains(where: { $0.id == outcome.id }) {
                // The check of one result, in place of the list; no sheet.
                FormSection("Check the result", detail: "Confirm what happened before the task repeats an action.") {
                    FormRow(outcome.title) {
                        FleetSelect("Result", selection: $finding, options: [
                            FleetOption(.done, "Completed", mark: .symbol("checkmark.circle")),
                            FleetOption(.not_done, "Did not happen", mark: .symbol("xmark.circle")),
                        ], placeholder: "Choose a result").accessibilityIdentifier("outcome-result")
                    }
                    FormBlock("How you checked", detail: "Optional.") {
                        // The one field look (`.fleetField`, T-30), where the stock bezel stood; its placeholder the muted
                        // words, with or without the cursor (`fieldPlaceholder`; fix round 3, item 55).
                        TextField(text: $note, prompt: Text(verbatim: "")) { Text("How you checked") }
                            .fieldPlaceholder("How you checked", shows: note.isEmpty).fleetField()
                    }
                    FormRow("", warning: store.pending != nil ? "A saved request waits. Check it below." : nil) {
                        HStack(spacing: 8) {
                            Button("Cancel") { resolving = nil }.buttonStyle(FleetOutlineButtonStyle()).keyboardShortcut(.cancelAction)
                            Button("Save finding") {
                                guard let finding else { return }
                                Task { await store.command(.outcome(id: outcome.id, finding: finding), note: note); if store.pending == nil { resolving = nil } }
                            }.buttonStyle(FleetPrimaryButtonStyle()).disabled(finding == nil || !store.canWrite || note.count > 2000)
                        }
                    }
                }
            } else if !unknown.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    Label("Check before repeating", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                    ForEach(unknown) { outcome in
                        // The row clicks in 26 points and more, over and under its words (`IconMetrics.reach`, T-21):
                        // its line of 14 points was all that took the click. The card keeps its rhythm.
                        Button { finding = nil; note = ""; resolving = outcome } label: {
                            HStack { Text(outcome.title).lineLimit(2); Spacer(); Image(systemName: "chevron.right").font(IconMetrics.symbol(9)) }
                                .padding(.vertical, IconMetrics.reach).contentShape(Rectangle())
                        }.buttonStyle(.plain).padding(.vertical, -IconMetrics.reach).disabled(!store.canWrite)
                    }
                }.font(FormMetrics.detail).padding(12).background(FleetStyle.surface, in: RoundedRectangle(cornerRadius: FormMetrics.inner))
            }
        }
    }
    private func send(_ action: ControlAction) { Task { await store.command(.control(task: task.id, action: action)) } }
    private func controlButton(_ title: String, symbol: String, action: ControlAction) -> some View {
        IconButton(symbol: symbol, words: title, tint: FleetStyle.text) { send(action) }
            .accessibilityIdentifier("task-\(action.rawValue)")
    }
}
