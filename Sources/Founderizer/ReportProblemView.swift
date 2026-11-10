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
/// The screen is read once, when the window opens, so the name in "Sent with it" stays the screen he pressed it on
/// and does not follow him around the app while he types.
struct ReportProblemView: View {
    @Bindable var store: FleetStore
    @Environment(\.dismiss) private var dismiss
    @State private var model = ReportProblemModel()
    @State private var text = ""
    @AppStorage("reportEmail") private var email = ""

    private var report: ProblemReport { ProblemReport(text: text, email: email, facts: model.facts) }

    var body: some View {
        FleetPage("Report a problem") {
            Group {
                trouble
                // **A heading over its box, where every heading of the page stands** (the margins of 30 October 2026, row
                // 10): as a block of a card's rows, the heading and the box stood 14 pt in from the column's edges.
                VStack(alignment: .leading, spacing: FleetSpace.inside) {
                    Text("What happened, or what should be better").font(FormMetrics.heading).foregroundStyle(FleetStyle.text)
                        .frame(minHeight: FormMetrics.headingRow).padding(.leading, 2).accessibilityAddTraits(.isHeader)
                    // The one field look of a box of several lines (`fleetTextBox`; fix round 3, item 56).
                    TextEditor(text: $text).font(FormMetrics.text).fleetTextBox().frame(minHeight: 130)
                        .accessibilityIdentifier("report-text")
                }
                FormSection("Sent with it",
                            footer: "Nothing of your fleet's work leaves this Mac: no task, no message, no file.") {
                    FormRow("Answer to", detail: "We write back here and keep nothing else.") {
                        TextField(text: $email, prompt: Text(verbatim: "")) { Text("you@example.com") }
                            .fieldPlaceholder("you@example.com", shows: email.isEmpty).fleetField().frame(maxWidth: 260)
                            .accessibilityIdentifier("report-email")
                    }
                    // A short value is the row's own control at the right. A long one — the checks, an error —
                    // takes the width and wraps: a value cut off with an ellipsis is a value he did not read,
                    // and nothing may leave this Mac that he has not read.
                    ForEach(model.facts.filter { $0.value.count <= 48 }) { fact in
                        FormRow(fact.name) {
                            Text(fact.value).foregroundStyle(FleetStyle.muted).textSelection(.enabled)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    ForEach(model.facts.filter { $0.value.count > 48 }) { fact in
                        FormBlock(fact.name) {
                            Text(fact.value).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
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
        .onChange(of: text) { _, _ in model.copied = false }
    }

    /// What Founderizer can see, and nothing that is right. While it reads for the first time, one line says so, as
    /// every page's wait does (`LoadingLine`: nothing for a second, then the words moving, never a spinner), at the
    /// height of the row it stands for, so nothing under it moves when the answer comes; Check again keeps what the
    /// last check found until the new one answers. A clear fleet is one line too, with no list of the checks that
    /// passed.
    @ViewBuilder private var trouble: some View {
        // **The count line has its place from the first frame** (fix round 3, item 10): the heading moved up 9.5 pt when
        // "5 things look wrong." came.
        FormSection("What Founderizer can see", detail: model.trouble?.summary ?? " ") {
            if model.reading && model.trouble == nil {
                LoadingLine("Checking your fleet…").frame(minHeight: 44)
            } else if let trouble = model.trouble, !trouble.isClear {
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
            } else if model.trouble != nil {
                FormRow("Nothing to put right from here", symbol: "checkmark.circle",
                        detail: "Tell us below and we read it.") { EmptyView() }
            } else {
                FormRow("Founderizer could not read your fleet", symbol: "exclamationmark.circle",
                        detail: "Tell us below anyway.") { EmptyView() }
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
    /// **True from the window's first frame**, which comes before its first check begins: that frame drew "Founderizer
    /// could not read your fleet" in a 56-pt row for 24 ms, and the card then lost 12 pt (the polish of 30 October 2026).
    private(set) var reading = true
    private(set) var sending = false
    private(set) var reference: String?
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
        let screen = self.screen ?? ProblemReport.screenName(String(describing: store.destination))
        self.screen = screen
        let hub = store.hub, client = HubClient()
        var health: FleetHealth?, machines: [MachineStatus] = [], servers: [ServerEntry] = [], releases: ReleaseState?
        if let database = store.state?.db {
            async let releaseRead = try? client.releases(hub: hub, database: database)
            async let healthRead = try? client.health(hub: hub, database: database)
            async let machineRead = try? client.machines(hub: hub, database: database)
            async let serverRead = try? client.servers(hub: hub, database: database)
            let (gotReleases, gotHealth, gotMachines, gotServers) = await (releaseRead, healthRead, machineRead, serverRead)
            releases = gotReleases; health = gotHealth
            machines = gotMachines?.machines ?? []; servers = gotServers?.servers ?? []
        }
        channel = releases?.channel
        fleet = releases?.entitlement.fleet
        revision = releases?.revision ?? health?.revision
        // Each server's checks, under the server's own name, by the rule of its own page: a closer look of this launch.
        let checklists = FleetTrouble.checklists(of: machines, servers: servers) { store.look(machine: $0) }
        let found = FleetTrouble.read(connectionError: store.connectionError, storageError: store.storageError,
                                      isFresh: store.isFresh, state: store.state, health: health,
                                      machines: machines, servers: servers, checklists: checklists,
                                      at: health?.time ?? store.state?.time ?? Date().timeIntervalSince1970)
        trouble = found
        facts = ProblemReport.facts(app: ProblemReport.appVersion(), system: ProblemReport.systemVersion(),
                                    fleet: fleet, hub: revision, screen: screen,
                                    trouble: store.connectionError
                                        ?? store.storageError.map { [$0, store.storageCause].compactMap { $0 }.joined(separator: " ") })
            + [ProblemReport.Fact(name: "Checks", value: found.reportLine)]
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
        } catch {
            // A send that failed leaves the words where they are and says the other way out, which never needs us.
            // Our own words for a refusal stand in the line; the system's words for no answer are behind it.
            let said = error is URLError ? "The report did not reach us."
                : (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if error is URLError { cause = error.localizedDescription }
            failure = "\(said) Copy report and mail it to support@founderizer.com."
        }
    }
}
