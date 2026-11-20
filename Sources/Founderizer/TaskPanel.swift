import FleetCore
import SwiftUI

/// **The panel at the right of a task's thread, in the cards of an agent's chat panel** (the owner's "Yes, build it" of
/// 17 November 2026 to the pictures of the Task page; `AgentStatusPanel` is the chat's). Its head names the thread by
/// the task's title, over the panel's scroll, because a name that scrolls out of reach is no name (`FleetView`). Under
/// it: one card of the agent that does the task (its glyph, role and name, which open its chat), the task's state with
/// its Pause and Stop, who asked for it, and its attempt after a restart, with its project, its schedule, the task it
/// follows and the task it is part of where it has them; then Done when; Runs on, the AI provider with the model that
/// it used and the server with its Terminal; and, while the task has them, its subtasks, its child agents and the
/// files it changed. Each row is the chat panel's row: one mark column, words of 13 and 12 points, and the chevron of a
/// row that opens a page. It replaced a list of label-over-value pairs that said the state three times ("Checked",
/// "Accepted by …" and the thread's own row) and the model in four rows.
///
/// **Nothing in it waits for the thread's reads**: its Pause and Stop stood under the thread from the first frame, and
/// stand here from the first frame too. What only the thread's reading knows comes in place or at the panel's end: the
/// model joins the provider's row, and the child agents and the changed files are its last cards.
struct TaskPanel: View {
    @Bindable var store: FleetStore
    let task: FleetTask
    /// The read of the machines failed, in the hub's words, and none was kept.
    @State private var readError: String?
    /// The read of the machines has answered or failed in this visit.
    @State private var readEnded = false
    /// The machines' read has gone on for a second: only then does its row say so (`readingRow`).
    @State private var slow = false
    /// The pointer is on the server's row: its one fill (`serverRow`).
    @State private var serverHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var state: HubState? { store.state }
    /// The server of the task's agent, from the machines' reading that the store keeps (`FleetStore.reading`), which an
    /// agent's chat panel and a server's page read too: its row stands from the panel's first frame.
    private var machine: MachineStatus? { (store.reading("machines") as MachineList?)?.machines.first { $0.agent == task.owner } }
    /// Whether a name is an agent that the hub lists: only such a name wears a glyph (`AgentNamed`'s rule).
    private func listed(_ name: String) -> Bool { state?.agents.contains { $0.name == name } == true }
    /// The one size of every mark in the panel's rows, the chat panel's.
    private static let mark: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(task.title).font(FormMetrics.title).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.top, FleetSpace.underBand + FleetSpace.lights).padding(.bottom, 14)
                .accessibilityIdentifier("task-name")
            Rule()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) { content }
                    .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 16)
            }
        }
        // Its cards a step lighter than the rail, as the chat panel's (fix round 2 of that panel).
        .environment(\.cardFill, FleetStyle.chrome)
        .background(FleetStyle.rail)
        .task(id: "\(store.hub)/\(state?.db ?? "")/\(store.isFresh)") { await readMachines() }
    }

    @ViewBuilder private var content: some View {
        FormSection {
            agentRow
            stateRow
            askedRow
            if task.attempt > 1 || task.restarts > 0 { row(attemptWords, symbol: "arrow.clockwise") }
            if let project = task.project, !project.isEmpty { twoLines(project, line: String(l10n: "Project"), symbol: "folder", opens: false) }
            if task.trigger_id != nil { scheduleRow }
            if let follows = task.follows {
                taskRow(follows, missing: String(l10n: "An earlier task"), line: String(l10n: "Follow-up to"), symbol: "arrow.turn.down.right")
            }
            if let parent = task.parent {
                taskRow(parent, missing: String(l10n: "Parent task"), line: String(l10n: "Parent task"), symbol: "arrow.turn.left.up")
            }
        }
        section(String(l10n: "Done when")) {
            Text(task.done_when).font(FormMetrics.text).foregroundStyle(FleetStyle.text).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 12)
        }
        section(String(l10n: "Runs on")) {
            if let provider = providerWords { providerRow(provider) }
            serverRow
        }
        let subtasks = (state?.tasks ?? []).filter { $0.parent == task.id }
        if !subtasks.isEmpty {
            section(String(l10n: "Subtasks")) {
                ForEach(subtasks) { child in subtaskRow(child) }
            }
        }
        if !store.taskChildren.isEmpty {
            section(String(l10n: "Child agents")) {
                ForEach(store.taskChildren.prefix(20)) { child in childRow(child) }
                if store.taskChildren.count > 20 { row(String(l10n: "More agents in the task thread"), symbol: "ellipsis", muted: true) }
            }
        }
        if !store.taskFiles.isEmpty {
            section(String(l10n: "Changed files")) {
                ForEach(store.taskFiles) { change in fileRow(change) }
            }
        }
    }

    // MARK: the first card

    /// **The agent that does the task, as the head of its chat panel**: at the size of its row in the sidebar (the
    /// owner, 20 November 2026: "make the agent card the same size as the row on the left, so it is consistent"), its
    /// glyph at the list's size, moving while it works, its name and role on one line (`AgentNameLine`), and the chevron
    /// of a row that opens a page: its chat, where he talks to it.
    /// Why the requester gave the task to this agent is its hover. An agent that the hub no longer lists keeps its words
    /// alone, and opens nothing: its chat would take a message for nobody.
    @ViewBuilder private var agentRow: some View {
        if let agent = state?.agents.first(where: { $0.name == task.owner }) {
            Button { store.destination = .agent(task.owner) } label: {
                HStack(spacing: 0) {
                    // the name in the column of the words of the marked rows under it, as in the sidebar's row
                    HStack(spacing: FormMetrics.markColumn + FormMetrics.markGap - GlyphSize.list) {
                        AgentAvatar(name: agent.name, presence: presence(agent), size: GlyphSize.list, moves: store.marksMove)
                        agentNames
                    }
                    Spacer(minLength: 12)
                    chevron
                }
                .padding(.horizontal, FormMetrics.rowInset).frame(height: 50)
            }
            .buttonStyle(FleetRowButtonStyle())
            .help(task.why ?? "")
            .accessibilityLabel([AgentNames.shared.under(task.owner), task.owner.agentLabel].compactMap { $0 }.joined(separator: ", "))
            .accessibilityHint(String(l10n: "Opens its chat"))
            .accessibilityIdentifier("task-agent")
        } else {
            HStack(spacing: 0) { agentNames; Spacer(minLength: 12) }
                .padding(.horizontal, FormMetrics.rowInset).frame(height: 50)
                .help(task.why ?? "")
        }
    }

    /// The agent's name and role on one line, as its row in the sidebar: one word where the role says the name.
    private var agentNames: some View {
        AgentNameLine(agent: task.owner).font(FormMetrics.text).foregroundStyle(FleetStyle.text)
    }

    /// The agent's status as its chat panel works it out, so its glyph moves here as it moves there.
    private func presence(_ agent: FleetAgent) -> AgentPresence {
        let open = state?.tasks.filter { $0.owner == agent.name && !$0.isTerminal } ?? []
        return agent.presence(isFresh: store.isFresh, serverTime: state?.time ?? 0, openTasks: open, holds: state?.holds ?? [],
                              waits: state?.ownerWaits(of: open) ?? [:], request: state?.ownKeyRequest(of: agent.name),
                              thinking: store.thinks(agent.name))
    }

    /// **The task's state, its mark and its one word** (`FleetTask.mark`, the board's, in its one order: an outcome that
    /// nobody knows first, then his hold), with Pause, Stop or Resume at its end while it is not over (`TaskHoldControls`),
    /// and how long ago it ended once it is. When it was last active is the row's hover, with the word of his hold where
    /// an outcome that nobody knows stands before it ("Stopped", "Stop not confirmed"). A task that only its agent's park
    /// holds says until when, as the board says it (`parkedUntil`); one that also waits on something says that wait. The
    /// mark turns, in the green of work, only by a current reading of this wake
    /// (`marksMove`), and rests green before the hub's first answer after a wake.
    private var stateRow: some View {
        let mark = task.mark(in: state), tint = task.tint(in: state)
        let held = state?.holds?.contains { $0.task == task.id && $0.state != "released" } == true
        let unknown = state?.outcomeUnknown(task.id) == true
        let until = unknown ? nil : task.parkedUntil(in: state)
        let hover = [unknown && held ? task.stateWord(in: state) : nil,
                     task.last_activity.map { String(l10n: "Last activity \(fleetDate($0))") }].compactMap { $0 }
        return HStack(spacing: 0) {
            RowMark {
                if mark.inWork && store.isFresh { WorkMark(size: Self.mark, moves: store.marksMove) }
                else { Image(systemName: mark.symbol).font(IconMetrics.symbol(Self.mark)).foregroundStyle(tint.color) }
            }.accessibilityHidden(true)
            Text(until.map { String(l10n: "Until \(fleetComingTime($0, now: state?.time ?? Date().timeIntervalSince1970))") } ?? mark.words)
                .font(FormMetrics.text).foregroundStyle(FleetStyle.text).lineLimit(1)
            Spacer(minLength: 8)
            if TaskHoldControls.shows(task, in: state) {
                TaskHoldControls(store: store, task: task)
            } else if let time = task.checked_at ?? task.delivered ?? task.last_activity {
                Text(messageAge(time)).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).help(fleetDate(time))
            }
        }
        .padding(.horizontal, FormMetrics.rowInset).frame(minHeight: FormMetrics.row)
        .help(hover.joined(separator: "\n"))
        .accessibilityIdentifier("task-state")
    }

    /// Who asked for the task: him, also for what he asked an agent for in its chat, where the hub makes the agent's line
    /// its requester (`FleetTask.ownersWords`; the requester still checks the result, as the thread's result line says);
    /// else an agent with its glyph, or an agent that the hub no longer lists by its words alone.
    private var askedRow: some View {
        let his = task.requester == "owner" || task.ownersWords != nil
        return HStack(spacing: 0) {
            RowMark {
                if his {
                    Image(systemName: "person.crop.circle").font(IconMetrics.symbol(Self.mark)).foregroundStyle(FleetStyle.muted)
                } else if listed(task.requester) {
                    AgentGlyph(name: task.requester, size: GlyphSize.inline)
                }
            }.accessibilityHidden(true)
            Text(his ? String(l10n: "Asked by you") : String(l10n: "Asked by \(task.requester.agentLabel)"))
                .font(FormMetrics.text).foregroundStyle(FleetStyle.text).lineLimit(1)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, FormMetrics.rowInset).frame(minHeight: FormMetrics.row)
    }

    /// "Attempt 2 · Restarted 1 time": a row only after a restart (D-2: "Attempt 1 · 0 restarts" stood on every task).
    private var attemptWords: String {
        [task.attempt > 1 ? String(l10n: "Attempt \(task.attempt)") : nil,
         task.restarts > 0 ? (task.restarts == 1 ? String(l10n: "Restarted \(task.restarts) time") : String(l10n: "Restarted \(task.restarts) times")) : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// The wake-up rule that started the task, by its schedule ("Every 30 min") when this Mac has read the rules, else
    /// the word alone. The rule's number and the run's are the hub's own rows (a run's counts the runs of every rule of
    /// the fleet), and say nothing to him.
    private var scheduleRow: some View {
        let rule = (store.reading("triggers.list") as TriggerList?)?.triggers.first { $0.id == task.trigger_id }
        return twoLines(rule?.shortSchedule ?? String(l10n: "Schedule"), line: rule == nil ? nil : String(l10n: "Schedule"),
                        symbol: "clock", opens: false)
    }

    /// A task that this one follows or is part of: its title, what it is to this one, and the chevron that opens it.
    private func taskRow(_ id: Int, missing: String, line: String, symbol: String) -> some View {
        let other = state?.tasks.first { $0.id == id }
        return Button { store.destination = .task(id) } label: {
            twoLines(other?.title ?? missing, line: other == nil ? nil : line, symbol: symbol, opens: true)
        }
        .buttonStyle(FleetRowButtonStyle()).opensTask(id, store: store)
    }

    // MARK: Runs on

    /// The AI provider of this attempt and the model that it used last, as the provider names it on the agent's server
    /// ("Claude Code · Opus 5.5"; `ModelWords`), with every model that the attempt used. Before the thread's reading the
    /// row has the agent's own provider, and its model joins it in place when the reading comes.
    private var providerWords: (runtime: String, words: String, uses: [RuntimeModelUse])? {
        let runtimes = store.taskRuntimes[task.attempt].map { $0.sorted() } ?? []
        let uses = store.taskModels.filter { $0.attempt == task.attempt }
        guard let runtime = runtimes.first ?? state?.agents.first(where: { $0.name == task.owner })?.runtime else { return nil }
        let model = uses.last?.model.map { ModelWords.shown($0, options: machine?.models?.options ?? []) }
        let providers = (runtimes.isEmpty ? [runtime] : runtimes).map(providerName).joined(separator: ", ")
        return (runtime, [providers, model].compactMap { $0 }.joined(separator: " · "), uses)
    }

    /// The provider's own icon and its words; what each session of the attempt asked for and used is the hover, and an
    /// orange mark at the end says that the provider used other settings than the ones asked for, in any of them.
    private func providerRow(_ provider: (runtime: String, words: String, uses: [RuntimeModelUse])) -> some View {
        HStack(spacing: 0) {
            // An app icon has a margin of its own inside its square: at 18 points it stands as large as the 14-point
            // symbols of the rows under and over it (the chat panel's account row).
            RowMark { ProviderIcon(runtime: provider.runtime, size: Self.mark + 4) }.accessibilityHidden(true)
            Text(provider.words).font(FormMetrics.text).foregroundStyle(FleetStyle.text).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if provider.uses.contains(where: \.differs) {
                Image(systemName: "exclamationmark.circle").font(IconMetrics.symbol(Self.mark)).foregroundStyle(.orange)
                    .help(String(l10n: "The AI provider used other settings"))
            }
        }
        .padding(.horizontal, FormMetrics.rowInset).frame(minHeight: FormMetrics.row)
        .help(provider.uses.isEmpty ? provider.words : provider.uses.map(modelHelp).joined(separator: "\n\n"))
        .accessibilityIdentifier("task-provider")
    }

    /// What one session asked for and used, which no row says, its models by their provider's names (`ModelWords`).
    private func modelHelp(_ use: RuntimeModelUse) -> String {
        let named = { (model: String) in ModelWords.shown(model, options: machine?.models?.options ?? []) }
        return ["\(String(l10n: "Model requested")): \(use.requestedModel.map(named) ?? automaticChoice)",
         "\(String(l10n: "Model used")): \(use.model.map(named) ?? String(l10n: "Not reported"))",
         "\(String(l10n: "Reasoning requested")): \(use.requestedEffort.map(reasoningName) ?? automaticChoice)",
         "\(String(l10n: "Reasoning used")): \(use.effort.map(reasoningName) ?? String(l10n: "Not reported"))"].joined(separator: "\n")
    }

    /// **The agent's server, as the chat panel's row** (`AgentStatusPanel.machineRow`): its name opens its page, and an
    /// old reading is grey with its time on hover; **its Terminal and its Screen Sharing stand in the row before its
    /// chevron**, as a server's own page draws an agent's line (`ServersPage.agentLine`), so the words of a connection
    /// that failed under them make the row taller and cover nothing. They stood over the facts as "Open server".
    @ViewBuilder private var serverRow: some View {
        if let machine {
            let old = readError != nil || !store.isFresh
            let open = { store.destination = .server(machine.machine) }
            HStack(spacing: 0) {
                Button(action: open) {
                    HStack(spacing: 0) {
                        RowMark { Image(systemName: "desktopcomputer").font(IconMetrics.symbol(Self.mark)).foregroundStyle(FleetStyle.muted) }
                            .accessibilityHidden(true)
                        Text(machine.machine).font(FormMetrics.text).foregroundStyle(old ? FleetStyle.muted : FleetStyle.text).lineLimit(1)
                        Spacer(minLength: 8)
                    }
                    .padding(.leading, FormMetrics.rowInset).padding(.vertical, 11).frame(minHeight: FormMetrics.row)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(old ? String(l10n: "Last reading \(fleetDate(machine.reported_at)) · Open its server") : String(l10n: "Open its server"))
                .accessibilityIdentifier("task-server")
                if machine.sshURL != nil || machine.screenSharingConnection != nil || machine.screenSharingURL != nil {
                    MachineAccessButtons(reading: machine, fresh: store.isFresh && machine.isCurrent(at: Date().timeIntervalSince1970))
                        .labelStyle(.iconOnly).padding(.horizontal, 10)
                }
                // The chevron is the row's click too, and no control of its own: one stop for the keyboard.
                chevron.padding(.trailing, FormMetrics.rowInset).frame(minHeight: FormMetrics.row).contentShape(Rectangle())
                    .onTapGesture(perform: open)
            }
            // **One fill under the whole row**, as `FleetRowButtonStyle` draws it under a row that is one button: the
            // icons are controls of their own, so the row cannot be one button.
            .background(RoundedRectangle(cornerRadius: FormMetrics.inner)
                .fill(Color.white.opacity(serverHovered ? 0.035 : 0))
                .padding(.horizontal, 6).padding(.vertical, 3))
            .onHover { serverHovered = $0 }
        } else if let readError, !store.hubNoticeShows {
            row(readError, symbol: "desktopcomputer", muted: true)
        } else if store.isFresh && !readEnded && state?.ui_features?.contains("machines") == true {
            // Its read is on its way: the one loading look of the app, as the chat panel's (`AgentStatusPanel.readingRow`).
            // Never while the hub does not answer.
            readingRow
        } else {
            row(state?.ui_features?.contains("machines") == true ? String(l10n: "Server not reported") : String(l10n: "No server reading"),
                symbol: "desktopcomputer", muted: true)
        }
    }

    /// **The machines' read, in the one loading look of the app** (`LoadingLine`, the chat panel's `readingRow`): its
    /// place empty for the first second, then "Reading…" moving, muted, in the row's text slot, and still words under
    /// Reduce Motion.
    private var readingRow: some View {
        HStack(spacing: 0) {
            RowMark { Image(systemName: "desktopcomputer").font(IconMetrics.symbol(Self.mark)).foregroundStyle(FleetStyle.muted) }
            if slow {
                Group {
                    if reduceMotion { Text("Reading…").font(FormMetrics.detail).foregroundStyle(FleetStyle.muted) }
                    else { ShimmeringWords(text: String(l10n: "Reading…")) }
                }.transition(.opacity)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 11).frame(minHeight: FormMetrics.row)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: slow)
        .accessibilityElement(children: .ignore).accessibilityLabel("Reading")
        .task {
            try? await Task.sleep(for: LoadingLine.quiet)
            slow = true
        }
    }

    // MARK: the lists

    /// A subtask by its own mark and word, as the board draws a task; it opens.
    private func subtaskRow(_ child: FleetTask) -> some View {
        let mark = child.mark(in: state), tint = child.tint(in: state)
        return Button { store.destination = .task(child.id) } label: {
            HStack(spacing: 0) {
                RowMark { Image(systemName: mark.symbol).font(IconMetrics.symbol(Self.mark)).foregroundStyle(tint.color) }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(child.title).font(FormMetrics.text).foregroundStyle(FleetStyle.text).lineLimit(1)
                    Text(mark.words).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).lineLimit(1)
                }
                Spacer(minLength: 8)
                chevron
            }
            .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 9).frame(minHeight: FormMetrics.row).contentShape(Rectangle())
        }
        .buttonStyle(FleetRowButtonStyle()).help(child.title).opensTask(child.id, store: store)
    }

    /// **A child agent by what it was asked** (`StepWords.childTitle`), and its thread in the task's column on a click.
    /// One that failed wears the board's red mark; one that ended is muted, because the green check is a result that its
    /// requester checked, which no child's is.
    private func childRow(_ child: TaskChild) -> some View {
        Button { store.childThreadRequest = child.id } label: {
            HStack(spacing: 0) {
                RowMark {
                    switch child.status {
                    case "failed":
                        Image(systemName: "exclamationmark.circle.fill").font(IconMetrics.symbol(Self.mark))
                            .foregroundStyle(FleetTask.MarkTint.failed.color)
                    case "completed":
                        Image(systemName: "checkmark.circle").font(IconMetrics.symbol(Self.mark)).foregroundStyle(FleetStyle.muted)
                    default:
                        Image(systemName: "circle.dotted").font(IconMetrics.symbol(Self.mark)).foregroundStyle(FleetStyle.muted)
                    }
                }.accessibilityHidden(true)
                Text(child.name).font(FormMetrics.text).foregroundStyle(FleetStyle.text).lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right").font(IconMetrics.symbol(11, weight: .semibold)).foregroundStyle(FleetStyle.muted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, FormMetrics.rowInset).frame(minHeight: FormMetrics.row).contentShape(Rectangle())
        }
        .buttonStyle(FleetRowButtonStyle()).help(String(l10n: "Open child thread · Attempt \(child.id.attempt)"))
    }

    /// **A changed file from its repository's root** (`StepWords.inRepository`), the lines it added and removed at the
    /// row's end, and its repository and what was done on hover; a path outside the agents' clones shows whole. The last
    /// report of each file counts, as before: the counts are no diff of the repository.
    private func fileRow(_ change: FileChange) -> some View {
        let place = StepWords.inRepository(change.path)
        return HStack(spacing: 0) {
            RowMark { Image(systemName: "doc.text").font(IconMetrics.symbol(Self.mark)).foregroundStyle(FleetStyle.muted) }
                .accessibilityHidden(true)
            Text(verbatim: place?.path ?? change.path).font(FormMetrics.text).foregroundStyle(FleetStyle.text)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                if let added = change.added { Text("+\(added)").foregroundStyle(.green) }
                if let removed = change.removed { Text("−\(removed)").foregroundStyle(.orange) }
            }.font(FormMetrics.detail).monospacedDigit()
        }
        .padding(.horizontal, FormMetrics.rowInset).frame(minHeight: FormMetrics.row)
        .help([place?.repository, Self.actionWords(change.action)].compactMap { $0 }.joined(separator: " · "))
    }

    /// What was done to a file, in his words: the runtime's own word ("modify") was English in every language. Each key
    /// names its file, so a word of another thing never takes its Spanish.
    private static func actionWords(_ action: String) -> String? {
        switch action {
        case "add": String(localized: "Added (a file)", defaultValue: "Added", bundle: Localized.bundle, locale: Localized.digits)
        case "modify": String(localized: "Changed (a file)", defaultValue: "Changed", bundle: Localized.bundle, locale: Localized.digits)
        case "delete": String(localized: "Deleted (a file)", defaultValue: "Deleted", bundle: Localized.bundle, locale: Localized.digits)
        case "move": String(localized: "Moved (a file)", defaultValue: "Moved", bundle: Localized.bundle, locale: Localized.digits)
        default: nil
        }
    }

    // MARK: parts

    /// A name over one card of rows: the muted name of the group, then the card of the app's forms (the chat panel's).
    private func section<Rows: View>(_ title: String, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(FormMetrics.text).foregroundStyle(FleetStyle.muted).padding(.leading, 2)
                .accessibilityAddTraits(.isHeader)
            FormSection { rows() }
        }
    }

    /// One row: a muted mark in the column every mark stands in, and its words.
    private func row(_ text: String, symbol: String, muted: Bool = false) -> some View {
        HStack(spacing: 0) {
            RowMark { Image(systemName: symbol).font(IconMetrics.symbol(Self.mark)).foregroundStyle(FleetStyle.muted) }
                .accessibilityHidden(true)
            Text(text).font(FormMetrics.text).foregroundStyle(muted ? FleetStyle.muted : FleetStyle.text)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, FormMetrics.rowInset).frame(minHeight: FormMetrics.row)
        .help(text)
    }

    /// A row of two lines: its words, and under them a muted word that says what they are; the chevron where it opens.
    private func twoLines(_ text: String, line: String?, symbol: String, opens: Bool) -> some View {
        HStack(spacing: 0) {
            RowMark { Image(systemName: symbol).font(IconMetrics.symbol(Self.mark)).foregroundStyle(FleetStyle.muted) }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(FormMetrics.text).foregroundStyle(FleetStyle.text).lineLimit(1)
                if let line { Text(line).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).lineLimit(1) }
            }
            Spacer(minLength: 8)
            if opens { chevron }
        }
        .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 9).frame(minHeight: FormMetrics.row).contentShape(Rectangle())
        .help([text, line].compactMap { $0 }.joined(separator: " · "))
        .accessibilityElement(children: .combine)
    }

    /// The chevron of a row that opens a page of its own, as on People and Conversations.
    private var chevron: some View {
        Image(systemName: "chevron.right").font(IconMetrics.symbol(11, weight: .semibold)).foregroundStyle(FleetStyle.muted)
            .frame(width: Self.chevronWidth).accessibilityHidden(true)
    }
    private static let chevronWidth: CGFloat = 10

    /// The machines, read once for each reading's generation while the panel shows, into the reading that the store
    /// keeps; a failed read leaves the last one, and its words where none was kept. Their read before any chat opens
    /// (`PagePrefetch`) usually has them already. **One break of the hub says nothing** (17 November 2026, the rule of
    /// the task's server access before this panel): a read that fails is made again every 3 seconds, and its words come
    /// only once this visit's reads have failed one whole break (`FleetStore.pageReadsFailedABreak`); until then the row
    /// is as it was, or says that its read is on its way. It reads again every 3 seconds until a read answers.
    private func readMachines() async {
        guard store.isFresh, let database = state?.db, state?.ui_features?.contains("machines") == true else { return }
        let hub = store.hub
        var failedSince: ContinuousClock.Instant?
        while !Task.isCancelled {
            do {
                let list = try await HubClient().machines(hub: hub, database: database)
                guard !Task.isCancelled, store.hub == hub, store.state?.db == database else { return }
                store.keep(list, as: "machines"); readError = nil; readEnded = true
                return
            } catch {
                guard !Task.isCancelled else { return }
                failedSince = failedSince ?? .now
                // It reads on after that too, as the chat panel's row does: the gray goes as soon as the hub is back.
                if store.pageReadsFailedABreak(failedSince: failedSince) {
                    readError = HubError.said(error) ?? String(l10n: "Server access is unavailable.")
                    readEnded = true
                }
            }
            do { try await store.nap(3) } catch { return }
        }
    }
}
