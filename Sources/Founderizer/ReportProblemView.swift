import AppKit
import FleetCore
import SwiftUI

/// Report a problem: the window the Help menu opens, from wherever he is when something is wrong.
///
/// **It is its own window and not a card over the page**, because the page is the evidence. A sheet in the middle
/// of the screen covers the very thing he is trying to describe, and he cannot look from one to the other. A
/// window stands beside it, which is also how a Mac has always taken feedback.
///
/// **It answers before it asks.** The first thing the window does is say what Founderizer can see is wrong and
/// what puts it right — the hub, a machine that went quiet, a provider signed out, an update that failed, and the
/// `fix` line `verify` itself wrote for each check that failed. A fix that is work on a machine comes with a block
/// to paste into the agent he already runs. Writing to us is the step after that, when the checks say nothing and
/// he still has a problem; and what they said goes with the report, which is the one thing that makes support
/// possible for a product where we hold nothing of his.
///
/// **It says nothing that another line says, and nothing that is right** (the owner, 25 November 2026, of this window:
/// "it is TOO large, it needs to be much more compact, less text"): a fleet with nothing wrong has no "What Founderizer
/// can see" at all, because the Checks fact says what the checks found; the facts are one short line each; and no line
/// explains a control.
///
/// The screen is read once, when the window opens, so the name in "Sent with it" stays the screen he pressed it on
/// and does not follow him around the app while he types.
struct ReportProblemView: View {
    @Bindable var store: FleetStore
    @Environment(\.dismiss) private var dismiss
    @State private var model = ReportProblemModel()
    @State private var text = ""
    @AppStorage("reportEmail", store: AppDefaults.store) private var email = ""
    /// The text that the owner's own agent put into the box (`prepare_problem_report`), while the box still holds it
    /// whole (`ProblemReport.AgentDraft`): the report then says, as one more fact, that an agent wrote it.
    @State private var draft = ProblemReport.AgentDraft()
    /// The window's first check has run for a page's quiet second (`LoadingLine.quiet`): only then does "What
    /// Founderizer can see" stand with its loading line, so a clear fleet's quick check never shows it at all.
    @State private var checkIsSlow = false

    /// **Every fact that goes, and so every fact that shows**: the lines under "Sent with it" and the report read this
    /// one list, so that no fact can go that the owner did not see.
    private var facts: [ProblemReport.Fact] {
        model.facts + (draft.isAgents ? [ProblemReport.writtenByAgent] : [])
    }

    private var report: ProblemReport { ProblemReport(text: text, email: email, facts: facts) }

    var body: some View {
        FleetPage("Report a problem") {
            Group {
                if troubleShows { trouble }
                // **A heading over its box, where every heading of the page stands** (the margins of 30 October 2026, row
                // 10): as a block of a card's rows, the heading and the box stood 14 pt in from the column's edges.
                VStack(alignment: .leading, spacing: FleetSpace.inside) {
                    Text("What happened, or what should be better").font(FormMetrics.heading).foregroundStyle(FleetStyle.text)
                        .frame(minHeight: FormMetrics.headingRow).padding(.leading, 2).accessibilityAddTraits(.isHeader)
                    // The one field look of a box of several lines (`fleetTextBox`; fix round 3, item 56).
                    TextEditor(text: $text).font(FormMetrics.text).fleetTextBox().frame(minHeight: 130)
                        .accessibilityIdentifier("report-text")
                }
                FormSection("Sent with it") {
                    FormRow("Answer to") {
                        TextField(text: $email, prompt: Text(verbatim: "")) { Text("you@example.com") }
                            .fieldPlaceholder("you@example.com", shows: email.isEmpty).fleetField().frame(maxWidth: 260)
                            .accessibilityIdentifier("report-email")
                    }
                    factLines
                }
                status
                HStack(spacing: 8) {
                    Button("Send", systemImage: "paperplane") { Task { await model.send(report, store: store) } }
                        .buttonStyle(FleetPrimaryButtonStyle())
                        .disabled(!report.isReady || model.sending)
                        .accessibilityIdentifier("report-send")
                    Button(model.copied ? "Copied" : "Copy report") {
                        copyMessage(report.lines); model.copied = true
                    }.buttonStyle(FleetOutlineButtonStyle()).disabled(report.trimmedText.isEmpty)
                    Spacer()
                    if model.reference != nil {
                        Button("Done") { dismiss() }.buttonStyle(FleetOutlineButtonStyle()).keyboardShortcut(.cancelAction)
                    }
                }
            }
        }
        // **No bar over the page, as on the main window** (the margins of 30 October 2026, row 11): the window's title
        // stood in a bar over the page's own title. The band over the page holds the window's three buttons, and the
        // page's title stands where every page's stands.
        .padding(.top, FleetSpace.lights)
        .background(FleetStyle.canvas)
        .foregroundStyle(FleetStyle.text)
        .font(FleetStyle.body)
        .tint(FleetStyle.accent)
        .ignoresSafeArea(.container, edges: .top)
        .windowButtonsCentred(inBand: FleetSpace.lights)
        .task { await model.read(store: store) }
        .task {
            try? await Task.sleep(for: LoadingLine.quiet)
            checkIsSlow = true
        }
        .onChange(of: text) { _, now in
            model.copied = false
            draft.changed(to: now)
        }
        .onChange(of: store.reportAsk?.id, initial: true) { _, _ in take(store.reportAsk) }
    }

    /// **A text of the owner's own agent** (`prepare_problem_report`), **or the app's own words** of the problem that
    /// a button reports (the manager band's Report a problem): it goes into the box only when the box is free for it
    /// (`ProblemReport.AgentDraft.isFree`: empty, such a text of before unchanged, or the unchanged text of a report
    /// that was sent; the app's words never go over an agent's text). Text that the owner wrote or changed is never
    /// written over: the ask is answered with that, and nothing changes.
    private func take(_ ask: ReportAsk?) {
        guard let ask, ask.outcome == nil else { return }
        guard draft.isFree(box: text, sent: model.reference == nil ? nil : model.sentText, byAgent: ask.byAgent) else {
            store.reportAsk?.outcome = .ownText
            return
        }
        model.newDraft()
        text = ask.text
        draft.took(ask.text, byAgent: ask.byAgent)
        store.reportAsk?.outcome = .shown
    }

    /// "What Founderizer can see" stands while it sees something wrong, and while the window's first check has run
    /// past a page's quiet second. A clear fleet has none of it: the Checks fact says what the checks found.
    private var troubleShows: Bool {
        if let trouble = model.trouble { return !trouble.isClear }
        return model.reading && checkIsSlow
    }

    /// What Founderizer can see, and nothing that is right. A first check that is still on its way after a page's
    /// quiet second has one line that says so, as every page's wait does (`LoadingLine`: the words moving, never a
    /// spinner); Check again keeps what the last check found until the new one answers.
    @ViewBuilder private var trouble: some View {
        FormSection("What Founderizer can see") {
            if let trouble = model.trouble {
                ForEach(trouble.findings) { finding in
                    FormBlock(finding.title, detail: finding.says) {
                        VStack(alignment: .leading, spacing: 9) {
                            if let fix = finding.shownFix {
                                Text(fix).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            HStack(spacing: 8) {
                                if finding.takesAnAgent {
                                    Button(model.promptCopied == finding.id ? "Copied" : "Copy a prompt for your agent") {
                                        model.copyPrompt(for: finding)
                                    }.buttonStyle(FleetOutlineButtonStyle()).help(TroublePrompt.says)
                                }
                                if let machine = finding.machine {
                                    // **The button names the page it opens** (fix round 3c, as on System status), and
                                    // opens it by that name: an agent can have the name of another server.
                                    Button("Open \(finding.server ?? machine.capitalized)") {
                                        model.open(machine: finding.server ?? machine, store: store)
                                    }.buttonStyle(FleetOutlineButtonStyle())
                                }
                            }
                        }
                    }
                }
            } else {
                LoadingLine(String(l10n: "Checking your fleet…"), waits: false).frame(minHeight: FormMetrics.row)
            }
        } accessory: {
            // **Its words, its size and its place from the first frame** (T-01, T-13): it went grey for the window's
            // first check, 22–52 ms, and changed its width to "Checking…". A press while a check is on its way waits for
            // that check and then checks once more (`ReportProblemModel.read`).
            Button("Check again") { Task { await model.read(store: store, again: true) } }
                .buttonStyle(FleetOutlineButtonStyle())
                .accessibilityIdentifier("report-check-again")
        }
    }

    /// **Every fact that goes, one short line each, in full** (the owner, 25 November 2026: "much more compact, less
    /// text"): its name and its value, as the report carries them. A long value — the checks, an error — wraps in its
    /// column: a value cut off with an ellipsis is a value he did not read, and nothing may leave this Mac that he has
    /// not read. Each fact was a row of 44 points, and a long one a block of its own.
    private var factLines: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: FormMetrics.markGap, verticalSpacing: 3) {
            ForEach(facts) { fact in
                GridRow {
                    Text(verbatim: fact.name).font(FormMetrics.detailTitle).foregroundStyle(FleetStyle.text)
                    Text(verbatim: fact.value).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }

    /// One line at a time: what the site answered, what refused the send, or what the form still needs.
    @ViewBuilder private var status: some View {
        if let reference = model.reference {
            Label("Sent. Your reference is \(reference), and we answer at \(email).", systemImage: "checkmark.circle")
                .font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).textSelection(.enabled)
        } else if let failure = model.failure {
            Text(failure).font(FormMetrics.detail).foregroundStyle(.orange)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .help(model.cause ?? "").accessibilityValue(model.cause ?? "")
        } else if model.sending {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Sending…").font(FormMetrics.detail).foregroundStyle(FleetStyle.muted) }
        } else if let refusal = report.refusal {
            Text(refusal).font(FormMetrics.detail).foregroundStyle(.orange)
        }
    }
}

@MainActor @Observable
final class ReportProblemModel {
    private(set) var facts: [ProblemReport.Fact] = []
    private(set) var trouble: FleetTrouble?
    /// **True from the window's first frame**, which comes before its first check begins, so that a first check that
    /// runs past a page's quiet second shows its line (the polish of 30 October 2026: that frame drew a row for 24 ms).
    private(set) var reading = true
    private(set) var sending = false
    private(set) var reference: String?
    /// The text of the report that `reference` is for: an agent's new text may take its place only while the box
    /// still holds exactly this.
    private(set) var sentText: String?
    private(set) var failure: String?
    /// The system's own words for a send that got no answer: behind the line, never in it.
    private(set) var cause: String?
    var copied = false
    /// The finding whose prompt is on the clipboard now.
    private(set) var promptCopied: String?
    /// The screen he pressed Report on, read once so it does not follow him about while he types.
    private var screen: String?
    /// The checks: a press while one is on its way waits for it, and one more runs after it (`RunAgain`).
    private let checks = RunAgain()
    /// The channel of this fleet's own hub, which our own is the fallback for.
    private var channel: String?
    private var fleet: String?
    private var revision: String?

    /// Read what this Mac already knows: the bundle and the system from here, the fleet and the channel from the
    /// hub's releases, its revision and its own warnings from its health, each machine from `/ui/machines`, each server
    /// from `/ui/servers`, also one with no agent, which `/ui/machines` does not list, and what a closer look of this
    /// launch found at each server, which needs no SSH and no call. A hub that does not answer leaves its facts as "Not
    /// reported" and becomes the first thing the screen says is wrong — it never holds the form up, because he can
    /// still tell us what happened.
    func read(store: FleetStore, again: Bool = false) async {
        guard again || facts.isEmpty else { return }
        await checks.run { await self.check(store: store, again: again) }
    }

    private func check(store: FleetStore, again: Bool) async {
        reading = true
        defer { reading = false }
        if again { await store.refresh() }
        // The card over the window is the screen that he sees: a task's, or a thing's of an agent's work, by the names
        // that their pages had ("Task", "Work"); a job of the board names the board under it.
        let shown: String = switch store.detail?.shown {
        case .task(let id)?: String(describing: DetailPlace.task(id))
        case .work(let agent, let key)?: String(describing: DetailPlace.work(agent, key))
        default: String(describing: store.destination)
        }
        let screen = self.screen ?? ProblemReport.screenName(shown)
        self.screen = screen
        let hub = store.hub, client = HubClient()
        var health: FleetHealth?, machines: [MachineStatus] = [], servers: [ServerEntry] = [], releases: ReleaseState?
        var diagnostics: HubDiagnostics?
        if let database = store.state?.db {
            // The hub's own faults and refused calls, only from a hub that has the route (UI-API.md 1.167).
            let readsFaults = store.state?.ui_features?.contains(HubDiagnostics.feature) == true
            async let releaseRead = try? client.releases(hub: hub, database: database)
            async let healthRead = try? client.health(hub: hub, database: database)
            async let machineRead = try? client.machines(hub: hub, database: database)
            async let serverRead = try? client.servers(hub: hub, database: database)
            async let faultRead = readsFaults ? try? client.diagnostics(hub: hub, database: database) : nil
            let (gotReleases, gotHealth, gotMachines, gotServers) = await (releaseRead, healthRead, machineRead, serverRead)
            releases = gotReleases; health = gotHealth
            machines = gotMachines?.machines ?? []; servers = gotServers?.servers ?? []
            diagnostics = await faultRead
        }
        channel = releases?.channel
        fleet = releases?.entitlement.fleet
        revision = releases?.revision ?? health?.revision
        // Each server's checks, under the server's own name, by the rule of its own page: a closer look of this launch.
        let checklists = FleetTrouble.checklists(of: machines, servers: servers) { store.look(machine: $0) }
        // A stop of Turn on or Turn off of the connected apps, which its row's Report a problem opened this window for.
        let connectStop: (stop: ConnectStop, turn: ConnectTurn)? = {
            if case .stopped(let stop, let turn) = store.connectSwitch().run { return (stop, turn) }
            return nil
        }()
        let macError = store.connectionError
            ?? store.storageError.map { [$0, store.storageCause].compactMap { $0 }.joined(separator: " ") }
            // the hub's own words of the stop, which no row of the page shows
            ?? connectStop.map { [$0.stop.words, $0.stop.said].filter { !$0.isEmpty }.joined(separator: " ") }
        // The hub's own faults (C0 and E3, the owner's yes of 14 November 2026 to their pictures): one fault, while this
        // Mac has no error of its own, is the "Last error"; more, or a refused call, is the "Hub errors" row. Where a
        // row says them, the hub's warning about them (E1) is no block and no Checks line here: one error, said once.
        let hubRows = diagnostics?.rows(macHasItsOwnError: macError != nil) ?? (lastError: nil, hubErrors: nil)
        let said = diagnostics?.said(hubRows) ?? []
        let found = FleetTrouble.read(connectionError: store.connectionError, storageError: store.storageError,
                                      isFresh: store.isFresh, state: store.state, health: health,
                                      machines: machines, servers: servers, checklists: checklists,
                                      at: health?.time ?? store.state?.time ?? Date().timeIntervalSince1970,
                                      connectStop: connectStop, leaving: said)
        trouble = found
        facts = ProblemReport.facts(app: ProblemReport.appVersion(), system: ProblemReport.systemVersion(),
                                    fleet: fleet, hub: ProblemReport.hubRelease(releases, revision: revision),
                                    screen: screen, trouble: macError ?? hubRows.lastError)
            + (hubRows.hubErrors.map { [ProblemReport.Fact(name: "Hub errors", value: $0)] } ?? [])
            + [ProblemReport.Fact(name: "Checks", value: found.reportLine)]
    }

    /// A new text in the box: what an earlier send left (its reference, its failure) is gone.
    func newDraft() {
        reference = nil; sentText = nil; failure = nil; cause = nil; copied = false
    }

    func copyPrompt(for finding: Trouble) {
        copyMessage(TroublePrompt.text(for: finding, fleet: fleet, revision: revision))
        promptCopied = finding.id
    }

    /// Opens the machine's own page in the main window, where its checks and its controls are.
    func open(machine: String, store: FleetStore) {
        store.destination = .server(machine)
        NSApp.windows.first { $0.title == "Founderizer" }?.makeKeyAndOrderFront(nil)
    }

    func send(_ report: ProblemReport, store: FleetStore) async {
        guard report.isReady, !sending else { return }
        sending = true; failure = nil; cause = nil
        defer { sending = false }
        do {
            reference = try await ProblemReportClient().send(report, channel: channel, fleet: fleet).reference
            sentText = report.text
        } catch {
            // A send that failed leaves the words where they are and says the other way out, which never needs us.
            // Our own words for a refusal stand in the line; the system's words for no answer are behind it.
            let said = error is URLError ? String(l10n: "The report did not reach us.")
                : (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if error is URLError { cause = error.localizedDescription }
            failure = String(l10n: "\(said) Copy report and mail it to support@founderizer.com.")
        }
    }
}
