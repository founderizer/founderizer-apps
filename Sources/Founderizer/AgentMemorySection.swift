import FleetCore
import SwiftUI

/// One agent's memory, read and nothing else: how it works, and under it the lessons it keeps.
///
/// The owner's yes of 25 October 2026: "One Memory page: Rename Notes to Memory. Show 'How it works' and, under it,
/// the agent's lessons." The notes card is the one the Notes page drew, without its footer. Both halves are
/// the agent's own words about its own work, written in its own sessions, so this section has no editor and the
/// hub serves no owner write for either.
///
/// A lesson is untrusted agent text: it is drawn as plain text, never as Markdown, with its tag and its age. A mark
/// stands at its right only where the hub has news about it (contradicted, stale, a dead end), with its words on hover.
///
/// It is a section of a page: the page around it brings the header, the column and the scroll.
struct AgentMemorySection: View {
    let store: FleetStore
    let agent: String
    /// **One group of a page under one heading** (D-5: Memory is the last group of the agent's Behaviour): the notes and
    /// the lessons stand under it, card under card, without a heading of their own. nil keeps a heading over each.
    var titled: String? = nil
    /// The notes and the lessons are the store's (`FleetStore.reading`): what he read last shows in the first frame when
    /// he comes back, and the reads that start then change only what changed.
    private var notes: AgentNotes? {
        get { store.reading("memory.notes.\(agent)") } nonmutating set { store.keep(newValue, as: "memory.notes.\(agent)") }
    }
    @State private var notesFailure: String?
    private var memory: AgentMemory? {
        get { store.reading("memory.lessons.\(agent)") } nonmutating set { store.keep(newValue, as: "memory.lessons.\(agent)") }
    }
    @State private var memoryFailure: String?
    @State private var earlierOpen = FleetDetailsToggle.asked

    /// The notes and the lessons, read before the section first opens (`PagePrefetch`).
    static let prefetch = [
        PagePrefetch(agent: { "memory.notes.\($0)" }, feature: AgentNotes.feature) { try await HubClient().notes(hub: $0, database: $1, agent: $2) },
        PagePrefetch(agent: { "memory.lessons.\($0)" }, feature: AgentMemory.feature) { try await HubClient().memory(hub: $0, database: $1, agent: $2) },
    ]

    init(store: FleetStore, agent: String, titled: String? = nil) {
        self.store = store
        self.agent = agent
        self.titled = titled
    }

    private var features: [String] { store.state?.ui_features ?? [] }
    private var notesOffered: Bool { features.contains(AgentNotes.feature) }
    /// A hub without the lessons shows the notes card only.
    private var lessonsOffered: Bool { features.contains(AgentMemory.feature) }

    /// The words of a half that was not read. **While the hub does not answer nothing is read**, so a half that has no
    /// reading yet says so then, and never "Reading the memory…" for as long as the hub is down.
    private var notesFailed: String? {
        notesFailure ?? (notes == nil && store.connectionError != nil ? Self.notesUnread : nil)
    }
    private var lessonsFailed: String? {
        memoryFailure ?? (memory == nil && store.connectionError != nil ? Self.lessonsUnread : nil)
    }
    private static let notesUnread = "The notes could not be read. Open this section again to retry."
    private static let lessonsUnread = "The lessons could not be read. Open this section again to retry."
    /// **A half with no reading says nothing while the window's notice says the outage** (`FleetStore.hubNoticeShows`;
    /// fix round 3, item 33: it is said once, over the page): its line said a second time that the hub does not answer.
    private var notesQuiet: Bool { notes == nil && notesFailed != nil && store.hubNoticeShows }
    private var lessonsQuiet: Bool { memory == nil && lessonsFailed != nil && store.hubNoticeShows }

    var body: some View {
        let spacing = titled == nil ? FleetSpace.block : FleetSpace.inside
        VStack(alignment: .leading, spacing: spacing) {
            if let titled {
                Text(titled).font(FormMetrics.heading).foregroundStyle(FleetStyle.text)
                    .frame(minHeight: FormMetrics.headingRow).padding(.leading, 2).accessibilityAddTraits(.isHeader)
            }
            // The two halves come in one frame: one line for the section while either read is out (C5.1).
            if notesOffered && notes == nil && notesFailed == nil || lessonsOffered && memory == nil && lessonsFailed == nil {
                LoadingLine("Reading the memory…")
            } else {
                // Under the group's one heading, a quiet half takes no room: the group is its heading alone.
                if notesOffered && !(notesQuiet && titled != nil) { notesBlock }
                // **A block under the notes' Details line** (margins row 31): 22 points, as two blocks of a page stand.
                // At the group's 10 the lessons' card read as what Details opens.
                if lessonsOffered && !(lessonsQuiet && titled != nil) {
                    lessonsCard.padding(.top, notesOffered && hasEarlier ? FleetSpace.block - spacing : 0)
                }
            }
        }
        .font(FleetStyle.body)
        .task(id: "\(store.hub)/\(store.state?.db ?? "")/\(agent)/\(notesOffered)/\(lessonsOffered)") { await read() }
    }

    // MARK: How it works

    /// The notes have earlier versions: Details stands under their card.
    private var hasEarlier: Bool { notes?.earlier.isEmpty == false }

    private var notesBlock: some View {
        VStack(alignment: .leading, spacing: FleetSpace.inside) {
            // A heading over each card, and the same empty card under each, as Lessons has; under the group's one
            // heading, none.
            FormSection(titled == nil ? "How it works" : nil) {
                if let notesFailed, !store.hubNoticeShows {
                    FormRow(notesFailed, symbol: "exclamationmark.triangle")
                } else if let notes {
                    if let said = notes.said {
                        VStack(alignment: .leading, spacing: 9) {
                            words(said)
                            if let line = Self.wrote(notes.versions.first) {
                                Text(line).font(FormMetrics.detail).foregroundStyle(FleetStyle.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.horizontal, FormMetrics.rowInset).padding(.vertical, 12)
                    } else if titled == nil {
                        // A group of a part shows its heading alone when it holds nothing (D-5).
                        FormEmpty("No notes yet", symbol: "square.and.pencil")
                    }
                }
            }
            if let earlier = notes?.earlier, !earlier.isEmpty {
                FleetDetailsToggle(open: $earlierOpen, identifier: "agent-memory-earlier")
                if earlierOpen {
                    FormSection("Earlier versions") {
                        ForEach(earlier) { past in
                            FormBlock("Version \(past.revision)", detail: Self.wrote(past)) { words(past.text) }
                        }
                    }
                }
            }
        }
    }

    /// The agent's own text, as text: it is untrusted display content, so nothing here reads it as anything else.
    private func words(_ text: String) -> some View {
        Text(verbatim: text).font(FormMetrics.text).foregroundStyle(FleetStyle.text)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// When a version was written and what it changed. Not the hub's numbers of the task or the case it was written
    /// in (3 November 2026: "I dont want these codes").
    private static func wrote(_ version: AgentNotes.Version?) -> String? {
        guard let version else { return nil }
        var parts: [String] = []
        if let at = version.at { parts.append(fleetDate(at)) }
        if let why = version.why?.trimmingCharacters(in: .whitespacesAndNewlines), !why.isEmpty { parts.append(why) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Lessons

    private var lessonsCard: some View {
        FormSection(titled == nil ? "Lessons" : nil) {
            if let lessonsFailed, !store.hubNoticeShows {
                FormRow(lessonsFailed, symbol: "exclamationmark.triangle")
            } else if let memory {
                if memory.lessons.isEmpty {
                    if titled == nil { FormEmpty("No lessons yet", symbol: "lightbulb") }
                } else {
                    let now = store.state?.time ?? Date().timeIntervalSince1970
                    ForEach(memory.lessons) { lesson in LessonRow(lesson: lesson, now: now) }
                }
            }
        }
    }

    // MARK: Reading

    /// Reads both halves. A first reading waits until a loading line that showed has stood half a second
    /// (`FleetStore.settle`).
    private func read() async {
        guard let database = store.state?.db else { return }
        let hub = store.hub, start = ContinuousClock.now
        if notesOffered { await readNotes(hub: hub, database: database, since: start) }
        if lessonsOffered { await readLessons(hub: hub, database: database, since: start) }
    }

    private func readNotes(hub: URL, database: String, since start: ContinuousClock.Instant) async {
        let first = notes == nil
        do {
            let fresh = try await HubClient().notes(hub: hub, database: database, agent: agent)
            if first { await store.settle(since: start) }
            guard !Task.isCancelled, store.hub == hub, store.state?.db == database else { return }
            notes = fresh; notesFailure = nil
        } catch {
            guard !Task.isCancelled else { return }
            if first { await store.settle(since: start) }
            notesFailure = HubError.said(error) ?? Self.notesUnread
        }
    }

    private func readLessons(hub: URL, database: String, since start: ContinuousClock.Instant) async {
        let first = memory == nil
        do {
            let fresh = try await HubClient().memory(hub: hub, database: database, agent: agent)
            if first { await store.settle(since: start) }
            guard !Task.isCancelled, store.hub == hub, store.state?.db == database else { return }
            memory = fresh; memoryFailure = nil
        } catch {
            guard !Task.isCancelled else { return }
            if first { await store.settle(since: start) }
            memoryFailure = HubError.said(error) ?? Self.lessonsUnread
        }
    }
}

/// One lesson: its text, a muted line with its tag and its age, and at its right the hub's news about it, only where
/// there is some (the owner, 25 October 2026: "Yes: show a mark at the right of a lesson only when it is
/// contradicted, stale or a dead end, with the words on hover").
private struct LessonRow: View {
    let lesson: AgentMemory.Lesson
    let now: Double

    private var line: String {
        let tag = lesson.about.trimmingCharacters(in: .whitespacesAndNewlines)
        let age = lesson.at.map { activityAge($0, now: now) }
        return [tag.isEmpty ? nil : tag, age].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        FormRow(lesson.text, detail: line) {
            HStack(spacing: 2) {
                ForEach(lesson.news, id: \.self) { news in LessonMark(news: news) }
            }
        }
        .accessibilityIdentifier("lesson-\(lesson.id)")
    }
}

/// One piece of news about a lesson, as a mark with its words behind it. Contradicted is the one to look at, so it
/// is the app's orange cross; stale and a dead end are facts worth knowing, and stay muted.
private struct LessonMark: View {
    let news: LessonNews

    private var symbol: String {
        switch news {
        case .deadEnd: "nosign"
        case .stale: "hourglass"
        case .contradicted: MarkState.bad.symbol
        }
    }

    private var tint: Color {
        switch news {
        case .contradicted: MarkState.bad.tint
        case .deadEnd, .stale: FleetStyle.muted
        }
    }

    var body: some View {
        Image(systemName: symbol).font(IconMetrics.symbol(12)).foregroundStyle(tint)
            .frame(width: IconMetrics.small, height: IconMetrics.small)
            .contentShape(Rectangle())
            .help(news.words)
            .accessibilityLabel(news.words)
    }
}
