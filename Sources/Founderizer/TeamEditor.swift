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
                // **The lines as a graph** (`ReportingGraph`; the owner's "Yes, build it" of 14 November 2026 to its
                // three pictures): one card, and no footer that explains the page (D-2). It was a form row for each
                // agent, with a select for its role and one for the agent it reports to.
                if let original {
                    FormSection {
                        ReportingGraph(input: $input, original: original, allowsLeads: allowsLeads, state: store.state,
                                       isFresh: store.isFresh)
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

    /// Reads team.json. The first reading of a page that opened at `start` waits until a loading line that showed has
    /// stood half a second (`FleetStore.settle`). **One break of the hub says nothing** (17 November 2026): a read that
    /// fails is made again every 3 seconds, and the page says that it could not read only once its own reads have
    /// failed one whole break (`FleetStore.pageReadsFailedABreak`).
    private func read(since start: ContinuousClock.Instant? = nil) async {
        guard contextMatches, let database else { return }
        loading = true; defer { loading = false }
        var failedSince: ContinuousClock.Instant?
        while !Task.isCancelled, contextMatches {
            guard let words = await readOnce(database: database, since: start) else { return }
            failedSince = failedSince ?? .now
            if store.pageReadsFailedABreak(failedSince: failedSince) { error = words; return }
            do { try await store.nap(3) } catch { return }
        }
    }

    /// One read of team.json; the words of its failure, or nil.
    private func readOnce(database: String, since start: ContinuousClock.Instant?) async -> String? {
        let first = original == nil
        do {
            let result = try await HubClient().team(hub: hub, database: database)
            if first, let start { await store.settle(since: start) }
            guard !Task.isCancelled, contextMatches else { return nil }
            latest = result
            // A form with no change takes the newest reading as its base: the one kept from an earlier visit, that it
            // opened on, is no conflict.
            if original == nil || input.lines == original?.lines { original = result; input = TeamLinesInput(lines: result.lines) }
            else if original?.sha256 == result.sha256 { original = result }
            error = nil
            return nil
        } catch {
            if first, let start { await store.settle(since: start) }
            return HubError.said(error) ?? Self.unavailable
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
