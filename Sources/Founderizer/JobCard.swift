import FleetCore
import SwiftUI

/// **One job on the Tasks board: one card, in plain words, with its tasks inside** (`Job`; the owner, 18 November 2026:
/// "I dont really want to see the detailed tasks being performed by each agent. I want to see what each agent is doing
/// ... Still use cards, but maybe expandable on that same page ... a higher level that shows the task eli5 title, and
/// then for example a subheader with 4 tasks working - 1 waiting - 3 done that can be expanded", and "Yes, build it" to
/// its picture). From the top:
///
/// - **Its name**, which its agent wrote for him, and at the top right **how long it has stood in its column** ("for
///   2 h"; the owner, 19 November 2026: "show how long they've been sitting in a column since they started", then
///   "something like "for X hours" or "for Y minutes"", `Job.columnSince`), or for a card of Done how long ago it ended,
///   in the place of a card of Needs you ("20 min ago"). The time is whole, and the name gives way; in a lane under
///   `EndedRow.narrow` the time stands under the name, which would keep a few letters a line beside it.
/// - **What it needs from him, in orange** ("Needs you: " and the request's title, or the words of an outcome, a stop
///   or a sign-in): a click on a request's line opens that request on Needs you.
/// - **In Done, its result in plain words**, at most three lines (`Job.result`): he reads the answer on the card and
///   need not look for it in a chat. Its name is lighter once he has opened the card (`read`).
/// - **Its counts line** ("1 working · 1 waiting · 1 done", the tasks that did not succeed in red while the job is
///   open or did not succeed, and muted on a job that succeeded in the end; a task that ended badly and that later
///   work took over is in no group), only for a job of two tasks or more: a click opens its tasks in the card, in the
///   order that they began, each with its mark, its title, its agent's glyph and name, and how long ago it came into
///   its state, or the time until which it is parked; a click on one opens that task.
/// - **Its agent**, and at the end of that line why it waits ("Resumes at 10:00", "Waiting for Fleet Manager"), or the red
///   word of a result that did not succeed.
///
/// The whole card opens the job in the detail card over the window (`Job.detail`): the job level for a job of several
/// tasks or one that waits on his request, else the task level of its one task. A task's row in it opens the task
/// level.
struct JobCard: View {
    @Bindable var store: FleetStore
    let job: Job
    let state: HubState
    /// The card names the job's agent under its name: on every board but an agent's own.
    let showsAgent: Bool
    /// Why a job that waits for somebody else waits; nil for none.
    let why: String?
    /// Its state in words, for its hover and for VoiceOver.
    let words: String
    /// The card stands in Working, and its task in work is work now: its agent's glyph moves (`AgentGlyph.moves`).
    var works = false
    /// A card in Done: it shows its result's words.
    var ended = false
    /// A card in Done that he has opened: its name is lighter.
    var read = false
    /// The width of its lane. Under `EndedRow.narrow` its time stands under its name; under `rowLine` each task's agent
    /// and time stand under the task's title. So nothing pushes the card past its lane, and a row keeps room for its
    /// title and its agent's name.
    var lane: CGFloat = .infinity
    /// The card shows its tasks.
    let isOpen: Bool
    let toggle: () -> Void
    let open: () -> Void
    @State private var hovered = false
    /// The pointer is down on the card: it ends with the press, however that ends.
    @GestureState private var pressed = false

    /// The orange line: what it waits for from him.
    private var needs: String? {
        guard let wait = job.wait else { return nil }
        if case .request(_, let title) = wait { return String(l10n: "Needs you: \(title)") }
        return wait.words
    }

    /// How long it has stood in its column ("for 2 h"), or for a card of Done how long ago it ended ("20 min ago").
    private var age: String {
        ended ? activityAge(job.endedAt, now: state.time)
            : activityFor(JobColumns.shared.times.since(job, hub: state.db), now: state.time)
    }

    /// The narrowest lane in which a task's row keeps its title, its agent's glyph and name and its time on one line:
    /// a title of about 25 characters beside "Shop DevOps Manager · 49 min ago" (a render of the owner's board at 560
    /// and 900 points wide, 19 November 2026, and a review of it at 1440).
    static let rowLine: CGFloat = 420

    /// Opens the request that it waits on, on Needs you, where he answers it; nil when it waits for none.
    private var openRequest: (() -> Void)? {
        guard case .request(let id, _) = job.wait else { return nil }
        return { store.selectedNeed = id; store.destination = .needs }
    }

    /// The tasks of it that wait for him: their rows have the orange hand, and no time until which they are parked.
    private var waits: Set<Int> { Set(state.ownerWaits(of: job.tasks).keys) }

    /// What a task's row says at its end: until when its agent parked it while nothing else holds it and it does not
    /// wait for him, else how long ago it came into its state.
    private func when(_ task: FleetTask, waits: Bool) -> String {
        (waits ? nil : task.parkedUntil(in: state)).map { fleetResumes($0, now: state.time) }
            ?? activityAge(task.stateSince, now: state.time)
    }

    var body: some View {
        let counts = job.countWords
        VStack(alignment: .leading, spacing: 8) {
            let name = Text(job.title).font(read ? FormMetrics.text : FormMetrics.title)
                .foregroundStyle(read ? FleetStyle.muted : FleetStyle.text).lineLimit(2).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Whole, never cut: the name gives way, as on a card of Needs you.
            let when = Text(age).monospacedDigit().foregroundStyle(read ? FleetStyle.muted : FleetStyle.text).lineLimit(1).fixedSize()
            if lane < EndedRow.narrow {
                VStack(alignment: .leading, spacing: 4) { name; when }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) { name; when }
            }
            if let needs {
                // Orange is what needs him (D-8), and here it is words, because the words are the news.
                if let openRequest {
                    Button(action: openRequest) {
                        Text(needs).lineLimit(2).multilineTextAlignment(.leading).padding(.vertical, IconMetrics.reach).contentShape(Rectangle())
                    }.buttonStyle(.plain).padding(.vertical, -IconMetrics.reach).foregroundStyle(.orange)
                        .help("Open this request on Needs you").accessibilityIdentifier("job-request-\(job.id)")
                } else {
                    Text(needs).lineLimit(2).foregroundStyle(.orange)
                }
            }
            if ended, job.failed == nil, let result = job.result {
                Text(result).foregroundStyle(read ? FleetStyle.muted : FleetStyle.text.opacity(0.8)).lineLimit(3)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }
            if let counts {
                Button(action: toggle) {
                    HStack(spacing: 5) {
                        if !counts.plain.isEmpty { Text(counts.plain).lineLimit(1) }
                        if !counts.plain.isEmpty, counts.failed != nil { Text(verbatim: "·") }
                        // Red only for a result that did not succeed: not on the card of a job that succeeded in the end.
                        if let failed = counts.failed {
                            Text(failed).foregroundStyle(job.showsResult ? FleetStyle.muted : EndedRow.failedWords).lineLimit(1)
                        }
                        Image(systemName: "chevron.right").font(IconMetrics.symbol(9, weight: .semibold))
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                    }.monospacedDigit().padding(.vertical, IconMetrics.reach).contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.vertical, -IconMetrics.reach)
                    .help(isOpen ? Text("Hide the tasks") : Text("Show the tasks")).accessibilityIdentifier("job-tasks-\(job.id)")
                if isOpen { tasks }
            }
            if showsAgent || why != nil || (ended && job.failed != nil) {
                HStack(spacing: 6) {
                    if showsAgent {
                        // The glyph with its dot, as everywhere it stands for the agent (D-8 item 2).
                        AgentGlyph(name: job.agent, size: GlyphSize.inline, moves: works,
                                   ground: hovered ? FleetStyle.lifted : FleetStyle.surface)
                        Text(job.agent.agentLabel).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if ended, let word = job.failed?.failedResult {
                        EndedRow.badge(word)
                    } else if let why {
                        Text(why).lineLimit(1).layoutPriority(1)
                    }
                }
            }
        }
        .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
        .modifier(BoardCardLook(hovered: hovered))
        .pressScale(pressed)
        // The whole card opens the job; the request's line, the counts line and a task's row are buttons of their own,
        // which take their own click.
        .onTapGesture(perform: open)
        .simultaneousGesture(DragGesture(minimumDistance: 0).updating($pressed) { _, down, _ in down = true })
        .onHover { hovered = $0 }
        // The keyboard reaches a card as it reaches a button (`ActivityCard`): Return or Space opens the job.
        .focusable(interactions: .activate)
        .contentShape(.focusEffect, RoundedRectangle(cornerRadius: FormMetrics.radius))
        .onKeyPress(keys: [.return, .space], phases: .down) { _ in open(); return .handled }
        .help(Text(verbatim: "\(job.title)\n\(words)"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([job.title, age, showsAgent ? job.agent.agentLabel : nil, needs ?? words,
                             // as much of the result as the card shows, and not a whole report
                             ended && job.failed == nil ? job.result.map { String($0.prefix(280)) } : nil,
                             counts.map { [$0.plain, $0.failed].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ") }]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, open)
        .accessibilityActions {
            if let openRequest { Button("Open the request", action: openRequest) }
            if counts != nil {
                if isOpen { Button("Hide the tasks", action: toggle) } else { Button("Show the tasks", action: toggle) }
            }
            // The card is one element for VoiceOver, so each task of an open card is an action of it, with what its
            // row says.
            if isOpen {
                ForEach(job.lines) { task in
                    Button([task.title, task.owner.agentLabel, when(task, waits: waits.contains(task.id))].joined(separator: ", ")) {
                        store.show(.task(task.id))
                    }
                }
            }
        }
        .accessibilityIdentifier("activity-\(job.id.replacingOccurrences(of: " ", with: "-"))")
    }

    /// Its tasks, under a hairline: the order that they began, with none that somebody canceled (`Job.lines`).
    private var tasks: some View {
        let waits = self.waits
        return VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(FleetStyle.line).frame(height: 1).padding(.bottom, 4)
            ForEach(job.lines) { task in row(task, waits: waits.contains(task.id)) }
        }
    }

    /// One task of it: its mark, its title on one line, and its agent's glyph and name with how long ago it came into
    /// its state (`FleetTask.stateSince`; the owner, 19 November 2026: "dont just show the agent icon on each row, show
    /// its name too and the time it's been in that state"), or until when its agent parked it while nothing else holds
    /// it (`FleetTask.parkedUntil`: under a hold or its agent's usage limit its mark says that, and that time would not
    /// be true; nor while it waits for him, when its mark is the orange hand, as the Task page and the chat's row say no
    /// such time then). The title gives way first, then the name; in a lane under `rowLine` the agent and the time
    /// stand under the title, and where they do not fit there the name goes first, then the time is cut. **A failure
    /// that later work took over has a muted mark** (`Job.replaced`): it is no news, and its job counts it in no group;
    /// a result that succeeded keeps its own mark. It opens the task's thread.
    private func row(_ task: FleetTask, waits: Bool) -> some View {
        let mark = task.mark(in: state)
        let tint: FleetTask.MarkTint = task.endedBadly && job.replaced.contains(task.id) ? .quiet : task.tint(in: state)
        let when = self.when(task, waits: waits)
        let title = Text(task.title).font(FormMetrics.text).foregroundStyle(task.isTerminal ? FleetStyle.muted : FleetStyle.text)
            .lineLimit(1)
        let time = Text(when).monospacedDigit().lineLimit(1).fixedSize()
        let glyph = AgentGlyph(name: task.owner, size: GlyphSize.inline, dot: false)
        return Button { store.show(.task(task.id)) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Group {
                    if waits { Image(systemName: "hand.raised.fill").font(IconMetrics.symbol(Self.mark)).foregroundStyle(.orange) }
                    else if mark.inWork && store.isFresh { WorkMark(size: Self.mark, moves: store.marksMove) }
                    else { Image(systemName: mark.symbol).font(IconMetrics.symbol(Self.mark)).foregroundStyle(tint.color) }
                }.frame(width: 16).accessibilityHidden(true)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                if lane < Self.rowLine {
                    VStack(alignment: .leading, spacing: 3) {
                        title
                        // The first of these that fits the lane: the name goes before the time, and the time
                        // alone is cut where even it does not fit ("Until Thu 12:12 PM" in the narrowest lane).
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 5) { glyph; Text(task.owner.agentLabel).lineLimit(1).fixedSize(); Text(verbatim: "·"); time }
                            HStack(spacing: 5) { glyph; time }
                            Text(when).monospacedDigit().lineLimit(1)
                        }
                    }.padding(.vertical, 4)
                    // The whole width of the row is its button: a click beside short words would open the card's task.
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    title
                    Spacer(minLength: 6)
                    // Before the title: the title gives way first, then the name.
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        glyph.alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                        Text(task.owner.agentLabel).lineLimit(1)
                        Text(verbatim: "·")
                        time
                    }.layoutPriority(1)
                }
            }
            .frame(minHeight: Self.rowHeight).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: "\(task.title)\n\(task.owner.agentLabel) · \(waits ? String(l10n: "Waits for you") : mark.words) · \(when)"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([task.title, task.owner.agentLabel, waits ? String(l10n: "Waits for you") : mark.words, when].joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("job-task-\(task.id)")
    }

    /// The size of a task's mark in a card, a little under a form row's.
    private static let mark: CGFloat = 13
    private static let rowHeight: CGFloat = 26
}

/// The kept column times of the cards (`ColumnTimes`), which the store writes at each reading of the hub and each card
/// reads.
@MainActor @Observable final class JobColumns {
    static let shared = JobColumns()
    private(set) var times = ColumnTimes()

    func note(_ state: HubState?) {
        if let state { times.note(state) }
    }
}

