import FleetCore
import SwiftUI

struct TeamEditor: View {
    @Bindable var store: FleetStore
    @State private var original: TeamSnapshot?
    /// The newest reading of team.json is the store's (`FleetStore.reading`), shared by every page that reads it: the
    /// form opens on it, and the read that starts then changes only what changed.
    private var latest: TeamSnapshot? {
        get { store.reading("team.snapshot") } nonmutating set { store.keep(newValue, as: "team.snapshot") }
    }
    @State private var input = TeamLinesInput(lines: [])
    @State private var loading = false
    @State private var error: String?
    private let hub: URL
    private let database: String?
    private var contextMatches: Bool { store.hub == hub && store.state?.db == database }
    private var conflict: Bool { latest != nil && latest?.sha256 != original?.sha256 }
    private var allowsLeads: Bool { store.state?.ui_features?.contains("leads") == true }
    private var problem: String? { original.flatMap { input.problem(against: $0, allowsLeads: allowsLeads) } }

    /// team.json, read before the page first opens (`PagePrefetch`).
    static let prefetch = PagePrefetch("team.snapshot", feature: "reporting_lines") { try await HubClient().team(hub: $0, database: $1) }

    /// The reporting lines, in the Settings page. A saved change becomes the new base of the form. The form opens on
    /// the reading kept last, in its first frame.
    init(store: FleetStore) {
        self.store = store; hub = store.hub; database = store.state?.db
        let kept: TeamSnapshot? = store.reading("team.snapshot")
        _original = State(initialValue: kept)
        _input = State(initialValue: TeamLinesInput(lines: kept?.lines ?? []))
    }

    var body: some View {
        FleetPage("Reporting lines") {
            if original != nil {
                Group {
                    // No footer that explains the page (D-2).
                    FormSection {
                        ForEach(input.lines.indices, id: \.self) { index in member(index) }
                    }
                }
                if let problem { Text(problem).font(FormMetrics.detail).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                if conflict, let latest {
                    Text("The team changed. Load the current version before saving.").font(FormMetrics.detail).foregroundStyle(.orange)
                    DisclosureGroup("Current reporting lines") {
                        // Each agent's glyph, with its dot, before its row, as on the rows above (the owner, 30 October
                        // 2026: "Yes, in all agent lists").
                        ForEach(latest.lines) { line in
                            HStack(spacing: 0) {
                                RowMark { AgentGlyph(name: line.agent, size: GlyphSize.inline) }
                                Text("\(line.agent.agentLabel) · \(line.role.capitalized) → \(line.reports_to?.agentLabel ?? String(l10n: "Owner"))")
                            }
                        }
                    }.font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                    Button("Use current version") {
                        if case .teamLines = store.pending?.command, store.pending?.refusal != nil { store.discardRefused() }
                        original = latest; input = TeamLinesInput(lines: latest.lines); error = nil
                    }.buttonStyle(FleetOutlineButtonStyle())
                }
            } else if failure == nil, contextMatches {
                LoadingLine(String(l10n: "Reading the reporting lines…"))
            }
            if !contextMatches { Text("The connection changed. Open this tab again.").font(FormMetrics.detail).foregroundStyle(.orange) }
            // Not while the window's notice says the outage (`FleetStore.hubNoticeShows`; fix round 3, item 33: it is said
            // once, over the page). `failure` still keeps "Reading the reporting lines…" away while the hub is down.
            if let failure, !store.hubNoticeShows { Text(failure).font(FormMetrics.detail).foregroundStyle(.orange) }
            if store.pending != nil { Text(store.sendError ?? String(l10n: "Waiting for the saved request. Check it at the bottom of the window.")).font(FormMetrics.detail).foregroundStyle(.orange) }
            if !conflict, case .teamLines = store.pending?.command, store.pending?.refusal != nil {
                Button("Discard refused request") {
                    store.discardRefused()
                    Task { await read() }
                }.buttonStyle(FleetOutlineButtonStyle()).disabled(!contextMatches)
            }
        } actions: {
            // **Save in the page's header**, where every page has its buttons (the owner, 13 November 2026: "review all
            // other pages for the same issues!!"): under one row for each agent, a large team scrolled to it. Only
            // while a change waits and can go: never grey (the owner: "dont show the send button if it's not
            // clickable").
            if original != nil, problem == nil, input.lines != original?.lines, store.canWrite, !loading, !conflict, contextMatches {
                Button("Save") { Task { await save() } }
                    .buttonStyle(FleetOutlineButtonStyle())
                    .accessibilityIdentifier("save-team-lines")
            }
            // Pressed while a read is on its way, it reads once more: a read is no reason to disable it (C4.2).
            IconButton(symbol: "arrow.clockwise", words: String(l10n: "Check for team changes")) { Task { await read() } }
                .disabled(!contextMatches)
                .accessibilityLabel("Refresh reporting lines")
        }
        .font(FleetStyle.body).foregroundStyle(FleetStyle.text).background(FleetStyle.canvas)
            .task { await read(since: .now) }
            .onChange(of: store.secretRefusals) { _, _ in
                input = TeamLinesInput(lines: [])
                original = nil; Task { await read() }
            }
    }

    /// What stopped the read. While the hub does not answer nothing is read, so lines not read yet say they are
    /// unavailable then, and never "Reading the reporting lines…" for as long as the hub is down.
    private var failure: String? { error ?? (original == nil && store.connectionError != nil ? Self.unavailable : nil) }
    private static let unavailable = String(l10n: "Team settings are unavailable. Check the connection, then refresh.")

    /// One agent: its role, and the manager or lead that it reports to. The manager reports to the owner.
    @ViewBuilder private func member(_ index: Int) -> some View {
        let line = input.lines[index]
        let tasks = original?.open_tasks[line.agent] ?? 0
        // **Each agent's glyph, with its dot, before its name** (the owner, 30 October 2026: "Yes, in all agent lists"), as
        // the sidebar and the item cards draw an agent: the names begin 50 points in, in both layouts of a row.
        if line.role == "manager" {
            FormRow(line.agent.agentLabel, mark: AgentGlyph(name: line.agent, size: GlyphSize.inline)) {
                Text("Manager · reports to you").foregroundStyle(FleetStyle.muted)
            }
        } else {
            let detail = tasks > 0 ? (tasks == 1 ? String(l10n: "1 open task · role locked") : String(l10n: "\(tasks) open tasks · role locked")) : nil
            // **Nothing is cut in a narrow window, and a row is as high as its words** (T-17): the name, its line and
            // the role with its "reports to" stand side by side only while each fits on its own one line; otherwise
            // the role and "reports to" go on a line of their own under the name, and no word stands one letter a
            // line. Beside the controls the row's line wrapped in half the room left, and the row kept the height of
            // a wrap it did not draw: 103–113 pt at 960, with about 30 pt of blank over and under its words.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 0) {
                    RowMark { AgentGlyph(name: line.agent, size: GlyphSize.inline) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(line.agent.agentLabel).font(FormMetrics.title).foregroundStyle(FleetStyle.text)
                        if let detail { Text(detail).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted) }
                    }.fixedSize().padding(.vertical, 10)
                    Spacer(minLength: 16)
                    lines(index).fixedSize().padding(.vertical, 8)
                }
                .font(FormMetrics.text).padding(.horizontal, FormMetrics.rowInset)
                .frame(minHeight: detail == nil ? FormMetrics.row : FormMetrics.twoLineRow)
                .accessibilityElement(children: .contain)
                VStack(alignment: .leading, spacing: 0) {
                    FormRow(line.agent.agentLabel, mark: AgentGlyph(name: line.agent, size: GlyphSize.inline), detail: detail)
                    // Under the name, where it begins, as a form row puts a control that does not fit beside its title.
                    lines(index).padding(.leading, FormMetrics.rowInset + FormMetrics.markColumn + FormMetrics.markGap)
                        .padding(.trailing, FormMetrics.rowInset).padding(.bottom, 11)
                }
            }
        }
    }

    /// The agent's role and the agent it reports to.
    private func lines(_ index: Int) -> some View {
        let line = input.lines[index]
        let tasks = original?.open_tasks[line.agent] ?? 0
        return HStack(spacing: 8) {
            // A role that cannot change now is its value, as plain row text: never a select that does nothing.
            if allowsLeads && tasks == 0 {
                FleetSelect("\(line.agent.agentLabel) role", selection: $input.lines[index].role, options: [
                    FleetOption("worker", "Worker", mark: .symbol("person")),
                    FleetOption("lead", "Lead", subtitle: String(l10n: "Gives tasks to the agents that report to it"), mark: .symbol("person.2")),
                ])
            } else {
                Text(line.role == "lead" ? "Lead" : "Worker").foregroundStyle(FleetStyle.muted)
            }
            Text("reports to").font(FormMetrics.detail).foregroundStyle(FleetStyle.muted).fixedSize()
            // **One width for every "reports to" select of the card, the widest** (margins row 25): each one stands
            // over one select of each choice of the card, drawn hidden, so "reports to" ends at one x in every row, as
            // a column does, from the first frame. Nova's "Atlas" put it 23 points right of the others' "Manager".
            ZStack(alignment: .leading) {
                ForEach(reportsSamples, id: \.self) { sample in reportsTo(sample).hidden().accessibilityHidden(true) }
                reportsTo(index)
            }
        }
    }

    /// The agent a line reports to. A manager or lead that is no longer one shows as the placeholder, so the owner
    /// chooses again.
    private func reportsTo(_ index: Int) -> some View {
        let line = input.lines[index]
        return FleetSelect("\(line.agent.agentLabel) reports to", selection: $input.lines[index].reports_to,
                           options: input.lines.filter { $0.agent != line.agent && ["manager", "lead"].contains($0.role) }.map {
            FleetOption(Optional($0.agent), $0.agent.agentLabel, subtitle: $0.role.capitalized,
                        mark: .agent($0.agent, state: store.state, isFresh: store.isFresh))
        }, placeholder: line.reports_to.map { String(l10n: "\($0.agentLabel) · choose a lead") } ?? String(l10n: "Choose a lead"))
    }

    /// The first line of each choice that the card's "reports to" selects show: one select of each, drawn hidden under
    /// every one of them (`lines`), gives each the width of the widest. Lines that report to one agent show one label.
    private var reportsSamples: [Int] {
        var seen = Set<String?>()
        return input.lines.indices.filter { input.lines[$0].role != "manager" && seen.insert(input.lines[$0].reports_to).inserted }
    }

    /// Reads team.json. The first reading of a page that opened at `start` waits until a loading line that showed has
    /// stood half a second (`FleetStore.settle`).
    private func read(since start: ContinuousClock.Instant? = nil) async {
        guard contextMatches, let database else { return }
        loading = true; defer { loading = false }
        let first = original == nil
        do {
            let result = try await HubClient().team(hub: hub, database: database)
            if first, let start { await store.settle(since: start) }
            guard !Task.isCancelled, contextMatches else { return }
            latest = result
            // A form with no change takes the newest reading as its base: the one kept from an earlier visit, that it
            // opened on, is no conflict.
            if original == nil || input.lines == original?.lines { original = result; input = TeamLinesInput(lines: result.lines) }
            else if original?.sha256 == result.sha256 { original = result }
            error = nil
        } catch {
            if first, let start { await store.settle(since: start) }
            self.error = HubError.said(error) ?? Self.unavailable
        }
    }
    private func save() async {
        guard let original, problem == nil, contextMatches else { return }
        do {
            if await store.command(.teamLines(sha256: original.sha256), note: try input.payload()) {
                // The saved lines become the new base of the form.
                self.original = nil; await read()
            } else { await read() }
        } catch { self.error = String(l10n: "Check the reporting lines before saving.") }
    }
}
